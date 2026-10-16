# Build Guide

Everything below is free. Nothing in this guide requires a paid Apple Developer
account, a payment method, or a purchase.

## 1. What you need

| Task | Requirement |
|---|---|
| Run the engine tests | Swift 5.9+ (Linux or macOS) |
| Build and run the iOS app | macOS with Xcode 15+ and an iOS 17+ device or simulator |
| Build the unsigned IPA | macOS with Xcode (GitHub Actions' free macOS runner works for public repositories) |
| Run the backend | Python 3.11+ (standard library only) |

## 2. Repository layout in one line

`ios/JarvisCore` is the engine (Foundation-only, testable anywhere);
`ios/JarvisApp` is the SwiftUI app; `backend/` is the optional companion service;
`scripts/` holds validation, test, build and verification tooling.

## 3. Engine: build and test (any platform)

```bash
cd ios
swift build --build-tests
swift test --skip-build
```

Expected: `Executed 107 tests, with 0 failures`. Or use `./scripts/run_tests.sh`,
which runs the engine suite and the backend suite together and prints a summary.

## 4. iOS app: build from the generated project

```bash
python3 scripts/generate_xcode_project.py          # regenerate JarvisApp.xcodeproj
open ios/JarvisApp.xcodeproj                       # then ⌘R
```

The project is generated from the file tree, so adding a Swift file never requires
editing `project.pbxproj` by hand. CI checks freshness with `--check`.

For the command line:

```bash
xcodebuild -project ios/JarvisApp.xcodeproj -scheme JarvisApp \
  -configuration Debug -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

## 5. Unsigned IPA

```bash
./scripts/build_unsigned_ipa.sh                 # → dist/JarvisApp-1.0.0-unsigned.ipa
./scripts/verify_unsigned_ipa.sh dist/JarvisApp-1.0.0-unsigned.ipa
```

What the script does: builds with `CODE_SIGNING_ALLOWED=NO`, packages
`Payload/JarvisApp.app` into a zip named `.ipa`, then verifies the archive
structure, the `Info.plist` contents and the **absence** of signing material.

What it never does: install a certificate, create or import a provisioning
profile, touch your Keychain or Apple ID, or modify anything outside the
repository's `build/` and `dist/` directories.

**Signing is yours.** Sign it with Xcode's automatic signing, your own certificate
and profile, or the sideloading method you already use. This is deliberate: the
repository contains no signing material, so no build of it can be tied to an
account it should not be.

### On GitHub Actions

`.github/workflows/ios.yml` runs the engine tests, builds the unsigned IPA, verifies
it, prints a SHA-256 and uploads both as artefacts. It requires no secrets. Free
macOS runner minutes are granted for **public** repositories; for a private
repository, expect the 10× macOS multiplier to consume your monthly allowance
quickly (see `docs/FREE_TIER_POLICY.md`).

## 6. Backend (optional)

```bash
cd backend
python3 -m pip install -r requirements-dev.txt          # pytest, for tests only
JARVIS_BACKEND_TOKEN="$(python3 -c 'import secrets;print(secrets.token_urlsafe(32))')" \
  python3 -m app.main --host 0.0.0.0 --port 8787
```

Runtime dependencies: **none**. Storage: a SQLite file under `JARVIS_DATA_DIR`
(default `./data`, git-ignored). Configuration is environment-only; `.env.example`
lists every variable.

Deploying it to a free host: any host that runs a Python web process works, since the
service is a plain `http.server` application. Set `JARVIS_BACKEND_TOKEN`, then enable
`JARVIS_REQUIRE_HTTPS=1` if TLS is terminated there, or `JARVIS_TRUST_PROXY_TLS=1` if
a proxy handles it. The server refuses to bind publicly without an auth token.

## 7. First run on your device

1. Launch JARVIS; the onboarding explains what works without setup.
2. Settings ▸ AI Providers → pick Groq or Google AI Studio → paste a free key →
   Save → "Test connection".
3. Settings ▸ Permissions → grant microphone/speech (voice), notifications
   (reminders), calendar (schedule questions) — each is optional.
4. Say "remember that I prefer concise answers", then ask "what do you remember".
5. Try "remind me tomorrow at 9am to review my notes", and confirm the notification
   is reported as scheduled.
6. Settings ▸ Connected Services → add GitHub, Google or WhatsApp credentials when
   you want those tools; each row states what it needs and what it cannot do.

## 8. Continuous integration

| Workflow | Runner | What it does |
|---|---|---|
| `validate.yml` | ubuntu-latest | Layout, structure, generated-project freshness, secrets scan, Swift parse check |
| `backend.yml` | ubuntu-latest | Backend tests, startup self-check, refusal of an insecure public bind |
| `ios.yml` | macos-14 | Engine tests on macOS, unsigned IPA build, structural verification, artefact upload |

No workflow uses a repository secret, and `scripts/validate_project.sh` fails the
build if one appears.

## 9. Reproducing the artwork

`python3 scripts/generate_app_icon.py` regenerates the app icon, the 180 pt preview,
the 1200×630 documentation hero and the square lockup from geometry defined in that
script. It needs Pillow and NumPy at authoring time only; the app depends on
neither. Outputs land in `assets/` and in the app's asset catalog.
