#!/usr/bin/env bash
# Exercises the unsigned-IPA packaging and verification path WITHOUT macOS.
#
#   ./scripts/test_ipa_packaging.sh
#
# Why this exists: `build_unsigned_ipa.sh` can only run on a Mac, so the packaging
# half was untested until CI ran it — and CI found a real bug in it (`--output dist`
# was treated as relative to the build directory, so `zip` failed with
# "zip I/O error: No such file or directory"). This script substitutes a fake
# `xcodebuild` that produces an app bundle with the shape of a real one, runs the
# real packaging script against it, and asserts the artefact verifies.
#
# It proves: path handling, Payload layout, Info.plist expansion expectations, the
# zip step and the verifier. It cannot prove that Xcode's output matches the fake.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
FAKE_BIN="$WORK/bin"
APP_NAME="JarvisApp"
BUNDLE_ID="ai.jarvis.assistant"
FAILURES=0

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

ok()   { printf '  ok    %s\n' "$1"; }
bad()  { printf '  FAIL  %s\n' "$1"; FAILURES=$((FAILURES + 1)); }

mkdir -p "$FAKE_BIN"

# --- a stand-in for `uname` so the script believes it is on macOS -------------
cat > "$FAKE_BIN/uname" <<'EOF'
#!/bin/sh
echo Darwin
EOF

# --- a stand-in for `xcodebuild` that emits an app bundle --------------------
cat > "$FAKE_BIN/xcodebuild" <<'EOF'
#!/bin/bash
build_dir=""
for argument in "$@"; do
  case "$argument" in CONFIGURATION_BUILD_DIR=*) build_dir="${argument#CONFIGURATION_BUILD_DIR=}" ;; esac
done
app="$build_dir/JarvisApp.app"
mkdir -p "$app"
cat > "$app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>ai.jarvis.assistant</string>
  <key>CFBundleExecutable</key><string>JarvisApp</string>
  <key>CFBundleName</key><string>JARVIS</string>
  <key>CFBundleDisplayName</key><string>JARVIS</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>MinimumOSVersion</key><string>17.0</string>
  <key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
  <key>NSMicrophoneUsageDescription</key><string>JARVIS listens only while you hold the microphone button.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>JARVIS transcribes your voice to answer you.</string>
</dict></plist>
PLIST
: > "$app/Assets.car"
: > "$app/JarvisApp"
printf 'APPL????' > "$app/PkgInfo"
echo "** BUILD SUCCEEDED **"
EOF

chmod +x "$FAKE_BIN/uname" "$FAKE_BIN/xcodebuild"

echo "== packaging path (fake xcodebuild, real scripts) =="
if ! ( cd "$WORK" && PATH="$FAKE_BIN:$PATH" bash "$ROOT/scripts/build_unsigned_ipa.sh" \
        --configuration Release --output dist > "$WORK/build.log" 2>&1 ); then
  bad "build_unsigned_ipa.sh exited non-zero"
  sed -n '1,40p' "$WORK/build.log" | sed 's/^/        /'
else
  ok "build_unsigned_ipa.sh completed"
fi

# The bug that CI found: a relative --output must be anchored to the caller's
# working directory, and the artefact must land there.
IPA="$WORK/dist/$APP_NAME-1.0.0-unsigned.ipa"
if [[ -f "$IPA" ]]; then
  ok "produced $(basename "$IPA") in the requested relative --output directory"
else
  bad "no artefact at dist/$APP_NAME-1.0.0-unsigned.ipa (relative --output handling)"
  find "$WORK" -name '*.ipa' | sed 's/^/        found: /'
fi

echo "== verifier =="
if [[ -f "$IPA" ]]; then
  if bash "$ROOT/scripts/verify_unsigned_ipa.sh" "$IPA" | sed 's/^/        /'; then
    ok "verify_unsigned_ipa.sh accepts the packaged artefact"
  else
    bad "verify_unsigned_ipa.sh rejected a well-formed artefact"
  fi
  if unzip -l "$IPA" | grep -q "Payload/$APP_NAME.app/Info.plist"; then
    ok "the archive contains Payload/$APP_NAME.app/Info.plist"
  else
    bad "the archive is missing Payload/$APP_NAME.app/Info.plist"
  fi
fi

echo
if [[ "$FAILURES" == "0" ]]; then
  echo "RESULT: the packaging and verification path works (with a simulated Xcode)"
  exit 0
fi
echo "RESULT: $FAILURES failure(s)"
exit 1
