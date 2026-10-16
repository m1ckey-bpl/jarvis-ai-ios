# TASK BACKLOG — jarvis-ai-ios

Status legend: `DONE` (implemented **and** verified) · `IMPL` (implemented, verification pending) ·
`WIP` · `TODO` · `BLOCKED` (external dependency) · `ACCEPTED-LIMIT` (documented, user-visible limitation)
Priority: P0 = release gate · P1 = important · P2 = nice-to-have

---

## Milestones (execution order)

| # | Milestone | Status | Evidence |
|---|---|---|---|
| 1 | Repository + specification | DONE | repo tree, `README.md`, `docs/PRODUCT_SPEC.md`, `agent-memory/*` |
| 2 | Design system | DONE (implemented, parse-checked) | `ios/JarvisApp/Design/*`, `docs/DESIGN_SYSTEM.md`, `assets/` |
| 3 | Functional app (11 screens) | IMPL | 11 screens + onboarding + recovery, parse-checked; SwiftUI compile pending (K11) |
| 4 | AI backend (providers, agent loop) | DONE (engine + backend) | `JarvisCore/Providers`, `JarvisCore/Agent`, `backend/app/agent`; 107 + 112 tests |
| 5 | Persistent memory | DONE | `JarvisCore/Memory`, `backend/app/memory`; migration idempotency and retrieval tested |
| 6 | Voice (speech in / speech out) | IMPL | `JarvisVoice` wrappers, permission flow, honest "unavailable" states; needs a device |
| 7 | Reminders | DONE (engine) / IMPL (delivery) | `RecurrenceRule`, natural-language parser, `NotificationScheduler`; 17 tests; on-device delivery unverified |
| 8 | Tool engine | DONE | registry, risk classes, confirmation gate, redacted run log; 14 + 13 tests |
| 9 | Integrations (official channels only) | DONE (clients) / IMPL (live) | GitHub, Gmail, WhatsApp, Instagram, search, Calendar/Reminders; 16 + 12 tests, all mocked |
| 10 | Automated testing | DONE | `docs/TEST_REPORT.md`, `scripts/run_tests.sh`, `scripts/validate_project.sh` |
| 11 | Unsigned IPA | DONE | `build_unsigned_ipa.sh`, `verify_unsigned_ipa.sh` (both directions proven with synthetic archives), `ios.yml` job; no real IPA yet (no macOS) |
| 12 | Final audit | DONE | `docs/DEFINITION_OF_DONE.md` — 24 verified / 8 unverified, each with its command |

## Release gate (Definition of Done)

| # | Requirement | Status |
|---|---|---|
| G21 | Fix what the first device build found: key-save must activate the provider, the tab bar must not cover content, and the UI must have the face and depth the user asked for | **DONE (1.1.0)** — see `docs/TEST_REPORT.md` §7: activation-on-save, `VStack` layout with 44 pt targets, `JarvisFace` with speech-driven lips, spatial layer |
| G22 | Re-verify on the device with the 1.1.0 IPA | **OPEN — blocked on the user's signing step.** The two acceptance-critical steps: paste a real key → List models → Run test; and tap the last control on every screen |
| G23 | Tag `v1.1.0` and attach the rebuilt IPA + checksum to a Release | **OPEN — next action after the CI run for this push is green** |
| G1 | GitHub repo contains the source code | DONE — public repository, `main` + tag `v1.0.0` |
| G2 | Spec + engineering memory committed | DONE |
| G3 | Native iOS project exists | DONE — compiles under Xcode 15.4 (CI #5) |
| G4 | Liquid Glass design system implemented | DONE (compiles; visual review on device pending) |
| G5 | Custom app icon included | DONE — generated, opaque 1024², in the asset catalog |
| G6 | Artwork/backgrounds included | DONE (native rendering + generated hero/lockup) |
| G7 | Main assistant screen functional | IMPL — compiles; runtime behaviour is K13 |
| G8 | Backend architecture implemented | DONE (112 pytest tests) |
| G9 | AI provider integration works with a configured provider | IMPL — needs the user's key; the live check is the in-app connection test |
| G10 | Persistent memory implemented & tested | DONE |
| G11 | Context management + session continuity | DONE |
| G12 | Reminders implemented & tested | DONE (engine); delivery needs a device |
| G13 | Tool execution validated & permission-controlled | DONE |
| G14 | Integrations only where supported | IMPL — official-channel clients implemented; live authorisation is the user's step |
| G15 | Automated tests executed with recorded results | DONE — `docs/TEST_REPORT.md` (219 tests total) |
| G16 | Build workflow documented | DONE — `docs/BUILD_GUIDE.md` |
| G17 | Unsigned IPA generation attempted in an appropriate environment | DONE — built by CI run #5 on `macos-14` |
| G18 | Generated IPA structurally verified | DONE — SHA-256 `d109ff09b9f26b92…`, confirmed independently |
| G19 | Documentation set complete and consistent | DONE — 13 documents under `docs/` |
| G20 | GitHub Actions workflows defined and free-tier safe | DONE — all three run green; no `secrets.` context; public repo keeps macOS minutes free |

## Backlog — next up

| # | Task | Priority | Blocked by |
|---|---|---|---|
| T1 | First `xcodebuild` and fix any SwiftUI type errors | DONE (CI #3–#5) | — |
| T2 | Produce and verify the real unsigned IPA; record its SHA-256 in the DoD | DONE | — |
| T3 | Push the repository, watch all three workflows | DONE | — |
| T4 | Work the 14-step device checklist | P1 | T2 + your signing method |
| T5 | Live provider smoke test (Groq or Google AI Studio key) | P1 | your key |
| T6 | Live OAuth round trip for Gmail (needs your Google Cloud project) | P2 | your credentials |
| T7 | Improve recurring-reminder DST coverage with more edge cases | P2 | none |
| T8 | Add a settings export/import of the whole local store (backup/restore) | P2 | none |

## Completed this session (for the record)

Repository validation (82 checks), secrets-scan exclusion policy with in-file markers, three CI
workflows, twelve documents plus the root README, `docs/TEST_REPORT.md`, `JarvisApp` app layer
(24 files), assistant/onboarding/recovery screens, asset pipeline, IPA build + verify scripts,
and this memory refresh (D11–D16, K11–K12).

## Still open

| # | Task | Priority | Blocked by |
|---|---|---|---|
| T4 | Sign the IPA with your own method, install it, walk the 14-step checklist | P0 | your signing method |
| T5 | Live provider smoke test (Groq key — free, no card) | P1 | your key |
| T6 | Live OAuth round trip for Gmail | P2 | your Google Cloud project |
| T7 | More DST edge cases for recurring reminders | P2 | — |
| T8 | Export/import of the whole local store (backup and restore) | P2 | — |
