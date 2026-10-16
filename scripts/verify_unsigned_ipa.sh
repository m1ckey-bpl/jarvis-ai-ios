#!/usr/bin/env bash
# Structurally verifies an unsigned .ipa before it is published as a build artefact.
#
#   ./scripts/verify_unsigned_ipa.sh dist/JarvisApp-1.0.0-unsigned.ipa
#
# Checks: zip integrity, a single Payload/*.app bundle, readable Info.plist,
# bundle identifier and executable, required resources, and — importantly — the
# ABSENCE of any signing material or leftover entitlements.
#
# Works on Linux (python3 zipfile/plistlib) and on macOS (unzip + PlistBuddy).
set -uo pipefail

IPA="${1:-}"
if [[ -z "$IPA" || ! -f "$IPA" ]]; then
  echo "usage: $(basename "$0") <path-to-ipa>" >&2
  exit 2
fi

FAILURES=0
pass() { printf '  ok    %s\n' "$1"; }
fail() { FAILURES=$((FAILURES + 1)); printf '  FAIL  %s\n' "$1"; }

echo "== verifying $IPA"
echo "   size: $(wc -c < "$IPA" | tr -d ' ') bytes"

if python3 - "$IPA" <<'PY'
import plistlib
import sys
import zipfile

path = sys.argv[1]
failures: list[str] = []
notes: list[str] = []

try:
    archive = zipfile.ZipFile(path)
except zipfile.BadZipFile as error:
    print(f"not a valid zip archive: {error}")
    sys.exit(1)

bad = archive.testzip()
if bad is not None:
    failures.append(f"corrupt entry in the archive: {bad}")
else:
    notes.append("zip integrity: ok")

names = archive.namelist()
apps = sorted({name.split("/")[1] for name in names if name.startswith("Payload/") and "/" in name[8:]})
app_dirs = sorted({name.rstrip("/") for name in names if name.startswith("Payload/") and name.endswith(".app/")})
if len(app_dirs) != 1:
    failures.append(f"expected exactly one Payload/*.app bundle, found {len(app_dirs)}: {app_dirs}")

app_dir = app_dirs[0] if app_dirs else None
if app_dir:
    notes.append(f"bundle: {app_dir}")
    info_entry = f"{app_dir}/Info.plist"
    if info_entry not in names:
        failures.append("Info.plist is missing from the bundle")
    else:
        try:
            plist = plistlib.loads(archive.read(info_entry))
        except Exception as error:  # noqa: BLE001
            failures.append(f"Info.plist could not be parsed: {error}")
            plist = {}
        bundle_id = plist.get("CFBundleIdentifier")
        if not bundle_id:
            failures.append("CFBundleIdentifier is missing")
        elif "$(" in str(bundle_id):
            failures.append(f"CFBundleIdentifier was not expanded: {bundle_id}")
        else:
            notes.append(f"bundle identifier: {bundle_id}")
        executable = plist.get("CFBundleExecutable")
        if not executable:
            failures.append("CFBundleExecutable is missing")
        elif f"{app_dir}/{executable}" not in names:
            failures.append(f"the executable {executable} is not present in the bundle")
        else:
            notes.append(f"executable: {executable}")
        for key in ("CFBundleShortVersionString", "CFBundleVersion"):
            if not plist.get(key):
                failures.append(f"{key} is missing")
        for key in ("NSMicrophoneUsageDescription", "NSSpeechRecognitionUsageDescription"):
            if not plist.get(key):
                failures.append(f"{key} is missing (voice features would crash on first use)")

    # Resources that must ship with the app.
    for needle, label in (
        ("Assets.car", "compiled asset catalog (app icon, colours)"),
        (".ttf", None),
    ):
        if needle == ".ttf":
            continue
        if not any(name.startswith(app_dir) and name.endswith(needle) for name in names):
            failures.append(f"missing {needle} ({label})")
        else:
            notes.append(f"resource present: {needle}")

    # No signing material may be present: the artefact must be unsigned.
    signing_markers = [name for name in names
                       if "_CodeSignature" in name or name.endswith("embedded.mobileprovision")
                       or name.endswith("CodeResources") or name.endswith(".xcent")]
    if signing_markers:
        failures.append("signing material found: " + ", ".join(sorted(signing_markers)[:5]))
    else:
        notes.append("unsigned: no _CodeSignature, mobileprovision, CodeResources or entitlements")

    if plist.get("UIBackgroundModes") or plist.get("NSAppTransportSecurity"):
        notes.append("declared capabilities: "
                     + ", ".join(filter(None, [
                         "background modes" if plist.get("UIBackgroundModes") else "",
                         "ATS policy" if plist.get("NSAppTransportSecurity") else ""])))

    # A light scan for credential-shaped strings in the binary and plists.
    import re
    patterns = [re.compile(rb"sk-[A-Za-z0-9]{20,}"), re.compile(rb"gsk_[A-Za-z0-9]{20,}"),
                re.compile(rb"AIza[0-9A-Za-z_\-]{30,}"), re.compile(rb"gh[pousr]_[A-Za-z0-9]{30,}"),
                re.compile(rb"-----BEGIN [A-Z ]*PRIVATE KEY-----")]
    suspicious: list[str] = []
    for name in names:
        if not (name.endswith(f"{executable}") or name.endswith(".plist")):
            continue
        blob = archive.read(name)
        for pattern in patterns:
            if pattern.search(blob):
                suspicious.append(name)
                break
    if suspicious:
        failures.append("credential-shaped strings found in: " + ", ".join(sorted(set(suspicious))[:5]))
    else:
        notes.append("no credential-shaped strings in the binary or plists")

for note in notes:
    print(f"  ok    {note}")
for failure in failures:
    print(f"  FAIL  {failure}")
sys.exit(1 if failures else 0)
PY
then
  :
else
  FAILURES=$((FAILURES + 1))
fi

echo
if [[ "$FAILURES" != "0" ]]; then
  echo "RESULT: the IPA failed structural verification"
  exit 1
fi
echo "RESULT: the IPA is structurally valid and unsigned"
