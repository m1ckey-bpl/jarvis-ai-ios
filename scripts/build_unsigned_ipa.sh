#!/usr/bin/env bash
# Builds an UNSIGNED .ipa of the JARVIS iOS app.
#
#   ./scripts/build_unsigned_ipa.sh [--configuration Release] [--output dist]
#
# What this script deliberately never does:
#   * it never installs, imports or generates a signing certificate or profile;
#   * it never touches your Keychain, your Apple ID or your developer account;
#   * it never bypasses platform security.
# It builds with CODE_SIGNING_ALLOWED=NO and packages Payload/JarvisApp.app into a
# zip with the .ipa extension. You sign it afterwards with your own method.
#
# Requires macOS with Xcode. On any other platform it exits with a clear message.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="Release"
OUTPUT_DIR="$ROOT/dist"
SKIP_XCODEGEN_CHECK=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --configuration) CONFIGURATION="$2"; shift 2 ;;
    --output) OUTPUT_DIR="$2"; shift 2 ;;
    --skip-project-check) SKIP_XCODEGEN_CHECK=1; shift ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This script requires macOS with Xcode: xcodebuild cannot produce an iOS app bundle elsewhere." >&2
  echo "On Linux, CI (see .github/workflows/ios.yml) builds the same artefact on a macOS runner." >&2
  exit 3
fi
command -v xcodebuild >/dev/null 2>&1 || { echo "xcodebuild not found: install Xcode." >&2; exit 4; }

PROJECT="$ROOT/ios/JarvisApp.xcodeproj"
SCHEME="JarvisApp"
APP_NAME="JarvisApp"

if [[ "$SKIP_XCODEGEN_CHECK" != "1" ]]; then
  python3 "$ROOT/scripts/generate_xcode_project.py" --check >/dev/null || {
    echo "The Xcode project is out of date; run scripts/generate_xcode_project.py" >&2; exit 5; }
fi

BUILD_DIR="$ROOT/build/unsigned"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR" "$OUTPUT_DIR"

echo "==> Building $SCHEME ($CONFIGURATION) for iphoneos with code signing disabled"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -sdk iphoneos \
  -derivedDataPath "$BUILD_DIR/DerivedData" \
  CONFIGURATION_BUILD_DIR="$BUILD_DIR/Products" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  EXPANDED_CODE_SIGN_IDENTITY="" \
  CODE_SIGN_ENTITLEMENTS="" \
  PROVISIONING_PROFILE_SPECIFIER="" \
  build | tee "$BUILD_DIR/xcodebuild.log" | tail -30

APP_PATH="$BUILD_DIR/Products/$APP_NAME.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "Build did not produce $APP_PATH — see $BUILD_DIR/xcodebuild.log" >&2
  exit 6
fi

echo "==> Packaging Payload/$APP_NAME.app into an unsigned .ipa"
PAYLOAD="$BUILD_DIR/Payload"
rm -rf "$PAYLOAD"
mkdir -p "$PAYLOAD"
cp -R "$APP_PATH" "$PAYLOAD/"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Info.plist" 2>/dev/null || echo 1.0.0)"
IPA_PATH="$OUTPUT_DIR/${APP_NAME}-${VERSION}-unsigned.ipa"
rm -f "$IPA_PATH"
( cd "$BUILD_DIR" && zip -qry "$IPA_PATH" Payload )
echo "==> Wrote $IPA_PATH"

echo "==> Verifying the artefact"
"$ROOT/scripts/verify_unsigned_ipa.sh" "$IPA_PATH"

cat <<EOF

Done. The artefact is unsigned and cannot be installed as-is:

  $IPA_PATH

Sign it with your own method (Xcode automatic signing, a self-managed certificate
and profile, or a sideloading tool you already use). JARVIS ships no credentials
and this build contains no signing material.
EOF
