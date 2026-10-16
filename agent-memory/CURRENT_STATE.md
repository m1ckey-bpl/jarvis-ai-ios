# CURRENT STATE — jarvis-ai-ios

**Last updated:** 2026-10-16 · **Updated by:** the build session

## Status in one line

**Shipped.** The engine (107 tests), the backend (112 tests) and the repository
validation (82 checks) are green; the SwiftUI app compiles under Xcode 15.4 on a free
`macos-14` runner; the unsigned IPA exists, is verified and is published as a GitHub
Release asset. What has never been exercised is anything that needs a **device** or a
**live credential** (runtime behaviour, provider calls, OAuth, notifications).

## The artefact

| | |
|---|---|
| File | `JarvisApp-1.0.0-unsigned.ipa` — run #5 artifact: 3,611,746 bytes, in the workspace at `~/JARVIS-unsigned-ipa/` |
| | release `v1.0.0` asset (rebuilt, run #6): 3,611,884 bytes, in the same folder |
| SHA-256 | `d109ff09b9f26b92a64c12e4d23618ef72a62da01f9c05e076a64cf9bc7aaa33` (artifact) · `24314b544679151e34dc8d9e2f018436a11bd68fad4dd05abc4d22e7ef40deeb` (release) — both verified, both matching their published checksum |
| Built by | CI run #5 — https://github.com/m1ckey-bpl/jarvis-ai-ios/actions/runs/38907603168 |
| Bundle | `ai.jarvis.assistant`, minimum iOS 17.0, arm64 |
| Download | https://github.com/m1ckey-bpl/jarvis-ai-ios/releases/tag/v1.0.0 (permanent), or the run artifact (90 days) |
| Signing | **unsigned** — no certificate, no profile, no entitlements; the user signs it |

## Verified right now

* **Engine** (`ios/JarvisCore`): 107 tests / 0 failures — on Linux locally *and* on
  `macos-14` in CI.
* **Backend** (`backend/`, stdlib-only): 112 tests / 0 failures, `--check` startup OK,
  refuses an insecure public bind.
* **App layer** (`ios/JarvisApp`, 24 files): compiles, links and passes Xcode's bundle
  validation; `** BUILD SUCCEEDED **`.
* **Project file**: generated, parsed by a real old-style-plist parser, every reference
  resolves, freshness asserted in CI.
* **IPA**: zip integrity, `Payload/JarvisApp.app`, bundle id, `Assets.car`, app icon,
  five usage strings, no signing material, no credential-shaped strings; SHA-256
  recomputed independently and equal to the workflow's.
* **CI**: three workflows; *Validate repository* and *iOS* green; *Backend* dispatched
  manually and green. No `secrets.` reference in any workflow.

## The four defects CI found (all fixed, all in the record)

1. A test the Linux toolchain accepted but Xcode 16 rejected (captured mutable state).
2. The generated `project.pbxproj` was unreadable (`TARGETED_DEVICE_FAMILY = 1,2;`).
3. A missing `import UIKit` in `Services.swift` — the app layer's only compile error.
4. `build_unsigned_ipa.sh` mishandled a relative `--output` when packaging.

Details: `docs/TEST_REPORT.md` §6.

## Still unverified (needs hardware or accounts)

1. **On-device behaviour**: orb states, haptics, VoiceOver, Dynamic Type, Reduce Motion,
   notifications firing — the checklist in `docs/DEFINITION_OF_DONE.md` §3.
2. **Live provider call** (needs the user's key) and **live OAuth** (Google/Meta).
3. Anything that depends on a real free-tier quota or a sleeping backend host.

## Immediate next steps

1. User signs the IPA and runs the §3 checklist; results replace the *not verified* rows.
2. First live provider smoke test in Settings ▸ AI Providers.
3. Optional: work the P2 backlog items in `TASK_BACKLOG.md`.
