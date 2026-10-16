#!/usr/bin/env bash
# Repository validation: required files, structural integrity, and a secrets scan.
# Designed to run on Linux CI and on a developer machine, with or without Xcode.
#
#   ./scripts/validate_project.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
FAILURES=0
CHECKS=0

pass() { CHECKS=$((CHECKS + 1)); printf '  ok    %s\n' "$1"; }
fail() { CHECKS=$((CHECKS + 1)); FAILURES=$((FAILURES + 1)); printf '  FAIL  %s\n' "$1"; }
section() { printf '\n== %s ==\n' "$1"; }

require_file() {
  if [[ -f "$1" ]]; then pass "$1"; else fail "$1 is missing"; fi
}
require_dir() {
  if [[ -d "$1" ]]; then pass "$1/"; else fail "$1/ is missing"; fi
}

section "required layout"
for path in agent-memory/PROJECT_CONSTITUTION.md agent-memory/CURRENT_STATE.md agent-memory/DECISIONS.md \
            agent-memory/TASK_BACKLOG.md agent-memory/KNOWN_ISSUES.md agent-memory/SESSION_HANDOFF.md \
            docs/PRODUCT_SPEC.md docs/ARCHITECTURE.md docs/DESIGN_SYSTEM.md docs/MEMORY_PROTOCOL.md \
            docs/SECURITY.md docs/FREE_TIER_POLICY.md docs/BUILD_GUIDE.md docs/INTEGRATIONS.md \
            docs/TROUBLESHOOTING.md docs/DEFINITION_OF_DONE.md \
            scripts/validate_project.sh scripts/run_tests.sh scripts/build_unsigned_ipa.sh \
            scripts/verify_unsigned_ipa.sh scripts/generate_app_icon.py scripts/generate_xcode_project.py \
            ios/Package.swift ios/JarvisApp/Info.plist ios/JarvisApp.xcodeproj/project.pbxproj \
            ios/JarvisApp.xcodeproj/xcshareddata/xcschemes/JarvisApp.xcscheme \
            backend/app/main.py backend/app/api.py backend/app/security.py backend/app/memory.py \
            backend/app/tools.py backend/app/agent.py backend/app/integrations.py backend/app/scheduler.py \
            backend/README.md backend/requirements.txt .env.example .gitignore README.md; do
  require_file "$path"
done
require_dir ios/JarvisApp/Resources/Assets.xcassets/AppIcon.appiconset
for directory in App Features Design Screens Support Resources; do
  require_dir "ios/JarvisApp/$directory"
done
require_dir ios/JarvisCore/Sources/JarvisCore
require_dir ios/JarvisTests
require_dir backend/tests

section "app screens (the 11 required surfaces)"
declare -A screens=(
  [AssistantHomeView]=assistant
  [ConversationHistoryView]=history
  [MemoryCenterView]=memory
  [TasksView]=reminders
  [ConnectedServicesView]=services
  [ToolHistoryView]=tool-history
  [ProjectAgentView]=coding-agent
  [SettingsView]=settings
  [ProviderSettingsView]=providers
  [PermissionSetupView]=permissions
  [RecoveryView]=recovery
)
for view in "${!screens[@]}"; do
  if grep -rqs "struct $view" ios/JarvisApp; then pass "screen: $view (${screens[$view]})"; else fail "screen $view not found"; fi
done

section "asset catalog and icon"
if python3 - <<'PY'
import json, pathlib, sys
root = pathlib.Path("ios/JarvisApp/Resources/Assets.xcassets")
problems = []
try:
    root_manifest = json.loads((root / "Contents.json").read_text())
    if root_manifest["info"]["version"] != 1:
        problems.append("root Contents.json has an unexpected version")
except Exception as error:  # noqa: BLE001
    problems.append(f"root Contents.json unreadable: {error}")
icon = root / "AppIcon.appiconset"
try:
    manifest = json.loads((icon / "Contents.json").read_text())
    if not manifest["images"]:
        problems.append("AppIcon has no images")
    for image in manifest["images"]:
        if not (icon / image["filename"]).exists():
            problems.append(f"missing icon file {image['filename']}")
        if image.get("size") != "1024x1024":
            problems.append("the marketing icon must be 1024x1024")
except Exception as error:  # noqa: BLE001
    problems.append(f"AppIcon manifest unreadable: {error}")
for name in ("AccentColor", "LaunchBackground"):
    if not (root / f"{name}.colorset" / "Contents.json").exists():
        problems.append(f"{name} colorset is missing")
print("\n".join(problems))
sys.exit(1 if problems else 0)
PY
then pass "asset catalog structure and icon files"; else fail "asset catalog problems (see above)"; fi

section "Info.plist contents"
if python3 - <<'PY'
import plistlib, sys
with open("ios/JarvisApp/Info.plist", "rb") as handle:
    plist = plistlib.load(handle)
required = ["NSMicrophoneUsageDescription", "NSSpeechRecognitionUsageDescription",
            "NSCalendarsFullAccessUsageDescription", "NSRemindersFullAccessUsageDescription",
            "NSLocalNetworkUsageDescription"]
missing = [key for key in required if not plist.get(key)]
if missing:
    print("missing usage descriptions: " + ", ".join(missing)); sys.exit(1)
if plist.get("CFBundlePackageType") != "APPL":
    print("CFBundlePackageType must be the literal APPL when GENERATE_INFOPLIST_FILE = NO"); sys.exit(1)
if plist.get("CFBundleIdentifier") != "$(PRODUCT_BUNDLE_IDENTIFIER)":
    print("CFBundleIdentifier should come from the build settings"); sys.exit(1)
sys.exit(0)
PY
then pass "Info.plist is well-formed with all usage strings"; else fail "Info.plist validation failed"; fi

section "generated Xcode project"
if command -v python3 >/dev/null 2>&1 && python3 scripts/generate_xcode_project.py --check >/dev/null 2>&1; then
  pass "ios/JarvisApp.xcodeproj matches the file tree"
else
  fail "the project file is out of date; run scripts/generate_xcode_project.py"
fi
# The project file is parsed with a real old-style-plist parser, not with regexes:
# the first macOS CI run failed on `TARGETED_DEVICE_FAMILY = 1,2;` (an unquoted
# comma is structural in that grammar), which balanced-brace and dangling-reference
# checks cannot see. See docs/TEST_REPORT.md.
if python3 scripts/generate_xcode_project.py --verify ios/JarvisApp.xcodeproj/project.pbxproj >/dev/null 2>&1
then pass "project.pbxproj parses as an old-style plist with every reference resolving"
else fail "project.pbxproj does not parse or has unresolved references: $(python3 scripts/generate_xcode_project.py --verify ios/JarvisApp.xcodeproj/project.pbxproj 2>&1 | head -3)"; fi

section "swift sources"
swift_files=$(find ios -name '*.swift' -not -path '*/.build/*' | wc -l | tr -d ' ')
if [[ "$swift_files" -ge 70 ]]; then pass "$swift_files Swift files"; else fail "only $swift_files Swift files found"; fi
if grep -rqs "fatalError(\"unimplemented\|TODO: implement\|placeholder implementation" ios --include=*.swift; then
  fail "unimplemented stubs found in ios/ sources"
else
  pass "no unimplemented stubs in ios/ sources"
fi
if command -v swiftc >/dev/null 2>&1 || [[ -x /opt/swift/usr/bin/swiftc ]]; then
  SWIFTC="$(command -v swiftc || echo /opt/swift/usr/bin/swiftc)"
  parse_failures=0
  while IFS= read -r file; do
    if ! "$SWIFTC" -parse "$file" >/tmp/jarvis-parse.log 2>&1; then
      fail "parse error in $file"; parse_failures=$((parse_failures + 1))
    fi
  done < <(find ios/JarvisApp ios/JarvisCore/Sources ios/JarvisTests -name '*.swift')
  [[ "$parse_failures" == "0" ]] && pass "every Swift file parses"
else
  printf '  ok    swiftc not installed; parse check skipped\n'
fi

# Payload-carrying enum cases cannot be compared with `==`. SwiftUI cannot be compiled in
# this environment, so this specific mistake — which CI found once, in JarvisFace.swift,
# with a misleading error about PencilSqueezeGesturePhase — is checked textually instead.
bad_state_compare="$(grep -rnE "state (==|!=) \.(failed|executing|thinking|awaitingConfirmation)\b" ios --include='*.swift' \
    | grep -vE ':[0-9]+:[[:space:]]*//' || true)"   # prose may discuss it; code may not do it
if [[ -n "$bad_state_compare" ]]; then
  fail "== comparison against a payload-carrying AssistantState case: $(echo "$bad_state_compare" | head -2 | tr '\n' ' ')"
else
  pass "no == comparison against a payload-carrying AssistantState case"
fi

section "unsigned IPA path (no macOS needed)"

# The packaging half of build_unsigned_ipa.sh cannot run on Linux, so it is exercised
# with a simulated xcodebuild — this is the check that would have caught the relative
# --output bug before CI did (see docs/TEST_REPORT.md).
if bash scripts/test_ipa_packaging.sh >/tmp/jarvis-ipa-packaging.log 2>&1
then pass "packaging + verification path works with a simulated Xcode"
else fail "packaging path failed: $(tail -3 /tmp/jarvis-ipa-packaging.log | tr '\n' ' ')"; fi

section "secrets scan"
SECRET_REGEX='(sk-[A-Za-z0-9]{20,}|gsk_[A-Za-z0-9]{20,}|AIza[0-9A-Za-z_\-]{30,}|gh[pousr]_[A-Za-z0-9]{30,}|EAA[A-Za-z0-9]{30,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|xox[baprs]-[A-Za-z0-9-]{10,})'
# Declared exclusions: files that deliberately contain synthetic key shapes so that
# redaction itself can be tested. An exclusion only counts if the file carries the
# marker below, so a real leak cannot be hidden behind a list entry.
excludes=()
fixture_ok=1
if [[ -f .secretsignore ]]; then
  while read -r path reason; do
    [[ -z "${path:-}" || "$path" == \#* ]] && continue
    if [[ "$reason" != "synthetic-credential-fixture" ]]; then
      fail ".secretsignore entry $path has no valid reason"; fixture_ok=0; continue
    fi
    if ! grep -q "synthetic-credential-fixture" "$path" 2>/dev/null; then
      fail "$path is excluded from the secrets scan but lacks the synthetic-credential-fixture marker"
      fixture_ok=0; continue
    fi
    excludes+=(--exclude="$(basename "$path")")
    printf '  ok    excluded from scan (declared synthetic fixture): %s\n' "$path"
  done < <(grep -vE '^\s*(#|$)' .secretsignore)
fi
[[ "$fixture_ok" == "1" ]] || true
if grep -rInE "$SECRET_REGEX" --exclude-dir=.git --exclude-dir=.build --exclude-dir=__pycache__ \
     "${excludes[@]}" . >/tmp/jarvis-secrets.log 2>/dev/null; then
  fail "possible secrets committed (see /tmp/jarvis-secrets.log)"; head -5 /tmp/jarvis-secrets.log | sed 's/^/        /'
else
  pass "no credential-shaped strings in the repository"
fi
if git -C . ls-files --error-unmatch .env >/dev/null 2>&1; then
  fail ".env is tracked by git"
else
  pass ".env is not tracked"
fi
if git -C . ls-files 2>/dev/null | grep -qE '\.(ipa|app|mobileprovision|p12|keystore)$|^ios/\.build/|^backend/data/|\.sqlite3$'; then
  fail "build artefacts or credentials are tracked"
else
  pass "no build artefacts or credentials tracked"
fi

section "gitignore coverage"
for pattern in ".env" "*.ipa" "*.xcuserstate" ".build/" "__pycache__/" "data/" "*.sqlite3"; do
  if grep -qF "$pattern" .gitignore; then pass ".gitignore covers $pattern"; else fail ".gitignore does not cover $pattern"; fi
done

section "backend"
if python3 - <<'PY'
import pathlib, sys
root = pathlib.Path("backend/app")
expected = ["__init__.py", "config.py", "errors.py", "http.py", "security.py", "memory.py",
            "tools.py", "agent.py", "integrations.py", "scheduler.py", "api.py", "main.py", "transport.py"]
missing = [name for name in expected if not (root / name).exists()]
if missing:
    print("missing backend modules: " + ", ".join(missing)); sys.exit(1)
if "fastapi" in (pathlib.Path("backend/requirements.txt").read_text().lower()):
    print("the backend must stay dependency-free for zero-cost deployment"); sys.exit(1)
sys.exit(0)
PY
then pass "backend modules present and dependency-free"; else fail "backend layout validation failed"; fi
if python3 -m compileall -q backend/app >/dev/null 2>&1; then pass "backend compiles"; else fail "backend has syntax errors"; fi

section "documentation"
for name in FREE_TIER_POLICY; do
  if grep -q "2026-10-16" "docs/$name.md"; then pass "docs/$name.md records the verification date"; else fail "docs/$name.md is missing the verification date"; fi
done
if grep -rqs "unsigned" docs/BUILD_GUIDE.md scripts/build_unsigned_ipa.sh; then
  pass "unsigned IPA path is documented and scripted"
else
  fail "the unsigned IPA workflow is not documented"
fi

printf '\n================ validation ================\n'
printf 'checks: %s   failures: %s\n' "$CHECKS" "$FAILURES"
if [[ "$FAILURES" != "0" ]]; then printf 'RESULT: FAILED\n'; exit 1; fi
printf 'RESULT: PASSED\n'
