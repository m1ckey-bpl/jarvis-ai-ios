#!/usr/bin/env bash
# Runs every test suite in the repository and reports a single summary.
#
#   ./scripts/run_tests.sh              # Swift engine + Python backend
#   ./scripts/run_tests.sh --swift      # only the Swift (JarvisCore) suite
#   ./scripts/run_tests.sh --python     # only the backend suite
#   ./scripts/run_tests.sh --ios        # additionally build the iOS target (macOS + Xcode only)
#
# The Swift suite runs on Linux and macOS (JarvisCore is Foundation-only). The
# iOS app target needs Xcode; on Linux it is skipped with an explicit notice
# rather than silently reported as passing.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_SWIFT=1; RUN_PYTHON=1; RUN_IOS=0
for arg in "$@"; do
  case "$arg" in
    --swift) RUN_PYTHON=0 ;;
    --python) RUN_SWIFT=0 ;;
    --ios) RUN_IOS=1 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

FAILED=0
summary=()

# ---------------------------------------------------------------- Swift suite --
if [[ "$RUN_SWIFT" == "1" ]]; then
  echo "==> Swift engine tests (JarvisCore)"
  if [[ -n "${SWIFT_BIN:-}" ]]; then
    export PATH="$(dirname "$SWIFT_BIN"):$PATH"
  elif [[ -x /opt/swift/usr/bin/swift ]]; then
    export PATH="/opt/swift/usr/bin:$PATH"
  fi
  if ! command -v swift >/dev/null 2>&1; then
    echo "    swift is not installed; skipping (install Swift 5.9+ or set SWIFT_BIN)"
    summary+=("swift: skipped (no toolchain)")
  else
    # An orphaned xctest/swift-test process holds the build lock and makes runs hang
    # with no output. Clear them first so failures are real.
    if command -v pgrep >/dev/null 2>&1; then
      orphans="$(pgrep -f 'JarvisCorePackageTests|swift-test|swift-build' 2>/dev/null | tr '\n' ' ')"
      if [[ -n "${orphans// /}" ]]; then
        echo "    clearing orphaned build processes: $orphans"
        for pid in $orphans; do kill -9 "$pid" 2>/dev/null || true; done
      fi
    fi
    ( cd "$ROOT/ios" && timeout 900 swift build --build-tests ) || { echo "    BUILD FAILED"; FAILED=1; }
    if ( cd "$ROOT/ios" && timeout 900 swift test --skip-build 2>&1 | tee /tmp/jarvis-swift-tests.log ); then
      execution="$(grep -Eo 'Executed [0-9]+ tests' /tmp/jarvis-swift-tests.log | tail -1)"
      failures="$(grep -Eo 'with [0-9]+ failures' /tmp/jarvis-swift-tests.log | tail -1)"
      summary+=("swift: ${execution:-unknown}, ${failures:-unknown}")
      if ! grep -q "with 0 failures" /tmp/jarvis-swift-tests.log; then FAILED=1; fi
    else
      summary+=("swift: FAILED")
      FAILED=1
    fi
  fi
fi

# --------------------------------------------------------------- iOS app target
if [[ "$RUN_IOS" == "1" ]]; then
  echo "==> iOS app target build"
  if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "    xcodebuild is only available on macOS; skipping"
    summary+=("ios: skipped (not macOS)")
  elif ! command -v xcodebuild >/dev/null 2>&1; then
    echo "    xcodebuild not found; install Xcode or the command line tools"
    summary+=("ios: skipped (no xcodebuild)")
  else
    if ( cd "$ROOT" && xcodebuild -project ios/JarvisApp.xcodeproj -scheme JarvisApp \
           -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
           CODE_SIGNING_ALLOWED=NO build 2>&1 | tee /tmp/jarvis-ios-build.log | tail -25 ); then
      summary+=("ios: built")
    else
      summary+=("ios: BUILD FAILED")
      FAILED=1
    fi
  fi
fi

# ------------------------------------------------------------- Python backend --
if [[ "$RUN_PYTHON" == "1" ]]; then
  echo "==> Backend tests (stdlib-only service)"
  if ! python3 -c "import pytest" >/dev/null 2>&1; then
    echo "    pytest is not installed; run: python3 -m pip install -r backend/requirements-dev.txt"
    summary+=("python: skipped (no pytest)")
  else
    # NB: no extra -q here. pytest.ini already sets `addopts = -q`; passing -q again
    # makes the quiet level 2, which suppresses the "N passed" summary line and left
    # this script reporting "python: unknown" (see docs/DEFINITION_OF_DONE.md §5).
    if ( cd "$ROOT/backend" && timeout 600 python3 -m pytest 2>&1 | tee /tmp/jarvis-backend-tests.log | tail -5 ); then
      passed="$(grep -Eo '[0-9]+ passed' /tmp/jarvis-backend-tests.log | tail -1)"
      summary+=("python: ${passed:-passed (count unavailable)}")
    else
      summary+=("python: FAILED")
      FAILED=1
    fi
    if ( cd "$ROOT/backend" && timeout 120 python3 -m app.main --check --data-dir /tmp/jarvis-selfcheck >/dev/null ); then
      summary+=("backend startup: ok")
    else
      summary+=("backend startup: FAILED")
      FAILED=1
    fi
  fi
fi

echo
echo "==================== summary ===================="
for line in "${summary[@]}"; do echo "  $line"; done
echo "================================================"
if [[ "$FAILED" == "1" ]]; then
  echo "RESULT: FAILURES PRESENT"
  exit 1
fi
echo "RESULT: all executed suites passed"
