# Test Report

**Run date:** 2026-10-16 · **Environment:** Linux (Debian 13), 2 vCPU / 1.9 GB,
Swift 6.0.3, Python 3.13. **No macOS, no Xcode, no network access during tests.**

Every number below was produced by a command in this repository. Nothing is
estimated. Tests are labelled **mocked** (no external service involved) or **live**
(a real remote service was contacted) — in this environment every test is mocked,
because no credential and no network are available, and that is stated rather than
glossed over.

## 1. Swift engine suite — 127 tests, 0 failures

```
cd ios && swift build --build-tests && swift test --skip-build
→ Executed 127 tests, with 0 failures (0 unexpected) in 1.32 (1.32) seconds
```

| Suite | Tests | What it proves | Kind |
|---|---|---|---|
| `ContextTests` | 6 | Token budgeting, compaction of the full transcript, untrusted blocks, ordering of system → memory → summary → turns | mocked |
| `IntegrationTests` | 16 | GitHub/Gmail/WhatsApp/Instagram clients against recorded responses: URL shapes, auth headers, error mapping, `sent = false` for compose-only paths | mocked |
| `SecurityTests` | 13 | Redaction of secrets in logs and tool arguments, injection pattern detection, untrusted wrapping, Keychain-store contract | mocked |
| `ProviderTests` | 13 | SSE decoding including `[DONE]` and EOF flush, tool-call accumulation, 401/403/429/5xx mapping, retry policy and jitter bounds | mocked |
| `ReminderTests` | 17 | Natural-language parsing (relative, weekday, absolute, recurring), time-zone correctness, titled extraction, scheduling receipts, recurring roll-forward, cancellation matching | mocked |
| `MemoryTests` | 13 | Persistence, kinds, correction chains, retention/expiry, ranked retrieval, export formats, migration idempotency | mocked |
| `ToolEngineTests` | 14 | Registry, argument validation/coercion, capability and permission gates, confirmation routing, timeout handling, redacted run log, `verified` semantics | mocked |
| `OrchestratorTests` | 15 | Local intent routing without a provider, streaming turn lifecycle, memory extraction, tool loop, confirmation approval/decline, cancellation, honest unconfigured state | mocked |
| `ModelDiscoveryTests` | 14 | Live model listing: parsing of Gemini and OpenAI-compatible payloads, filtering of non-chat models (whisper/tts/embedding/imagen), deterministic ranking, the key travelling in a header and never in the URL, and the exact HTTP status plus the provider's own wording coming back as a value instead of a thrown-away failure | mocked |
| `VisemeTests` | 6 | The mouth-shape maths behind the face: vowels decide the shape (not the first consonant), no-vowel words fall back to consonant shapes, every shape keeps a visible height, jaw opening is bounded and vowel-driven, punctuation closes the mouth down | mocked |

## 2. Backend suite — 112 tests, 0 failures

```
cd backend && python3 -m pytest -o addopts=
→ 112 passed in 0.67s
```

(`backend/pytest.ini` already sets `addopts = -q`. Passing a second `-q` makes the
quiet level 2, which hides the "N passed" line — that is exactly how
`scripts/run_tests.sh` once printed "python: unknown"; it no longer passes `-q`.)

| File | Tests | What it proves | Kind |
|---|---|---|---|
| `test_config.py` | 7 | Safe defaults; refusal to bind publicly without a token; TLS acknowledgement required; limits validated; capability report contains no secret values | mocked |
| `test_security.py` | 13 | Bearer auth (missing/wrong/correct), constant-time comparison, unconfigured-server refusal, per-identity rate limiting, confirmation and scope gates, redaction, injection scanning and wrapping, append-only audit | mocked |
| `test_memory.py` | 15 | CRUD, validation, pinned instructions, correction chain, deletion, retention, ranked retrieval, strict vs context retrieval, exports, versioned and failing migrations | mocked |
| `test_tools.py` | 13 | Catalogue metadata, provider schema, unknown/required/typed argument rejection, confirmation gate, scope gate, audit outcomes, argument redaction | mocked |
| `test_agent.py` | 13 | Non-tool completion, tool loop with result fed back, high-impact tool blocked without approval, approved execution, model-authored memory marked as assistant, external output wrapped as untrusted, iteration limit, honest "no key" and rate-limit errors | mocked (provider transport stubbed) |
| `test_api.py` | 26 | `/health` public, authenticated routes rejected without a token, 404/405, memory CRUD over HTTP, exports, malformed and oversized bodies, CORS allow-list, tool catalogue and execution, 409 confirmation flow, OAuth start/callback (PKCE, single-use state, encrypted refresh token), chat validation and error mapping, audit endpoint, reminders over HTTP, dispatch without target, real-socket `http.server` test | mocked |
| `test_integrations.py` | 12 | Secret box round-trip and tamper detection, credentials encrypted at rest, search/GitHub/WhatsApp/Instagram behaviour with and without credentials, PKCE exchange, token refresh and failure, RFC 822 Gmail message construction, capability report without secrets | mocked |
| `test_scheduler.py` | 13 | Scheduling, past-time refusal, recurrence validation, one-off completion, recurring roll-forward, cancellation, due windows, exponential backoff then giving up (never silently dropping), delivery recording, audit trail, monthly arithmetic (31 Jan → 28 Feb) | mocked |

## 3. Structural and static evidence

| Check | Command | Result |
|---|---|---|
| Backend starts and self-checks | `python3 -m app.main --check` | JSON report, `"ok": true`, schema version 2, 11 tools |
| Backend refuses insecure start | `JARVIS_HOST=0.0.0.0 JARVIS_BACKEND_TOKEN= python3 -m app.main --check` | exit 2 with an explanatory message |
| Backend byte-compiles | `python3 -m compileall backend/app` | clean |
| Swift syntax of every file | `swiftc -parse` over 72 files (24 app + 39 engine + 9 test) | clean (syntax only — see limitation below) |
| Generated Xcode project | `python3 scripts/generate_xcode_project.py --verify ios/JarvisApp.xcodeproj/project.pbxproj` — a real old-style-plist parser, not regexes | 162 objects, 21 groups, 63 Swift sources in the app target, 4 build configurations, every reference resolves |
| Project freshness | `python3 scripts/generate_xcode_project.py --check` | up to date |
| Repository validation | `./scripts/validate_project.sh` | **83 checks, 0 failures** |
| IPA verifier accepts a valid unsigned IPA | synthetic well-formed bundle | exit 0, "structurally valid and unsigned" |
| IPA verifier rejects a broken IPA | synthetic malformed bundle | exit 1 with 8 named failures |
| IPA packaging path (Linux, simulated `xcodebuild`) | `./scripts/test_ipa_packaging.sh` | builds, packages and verifies an artefact; asserts a relative `--output` lands where the caller asked |
| Artwork generation | `python3 scripts/generate_app_icon.py` | icon-1024 (opaque), icon-180, hero-1200×630, lockup-512 + app catalog icon; pixel values sampled |

## 4. Not covered by automated tests (and why)

| Area | Why | How it will be covered |
|---|---|---|
| SwiftUI compilation and view behaviour | No macOS/Xcode in this environment. CI has since compiled the app layer (iOS #4–#6); the **v1.1.0** view code (animated face, spatial backdrop, reworked navigation and provider screen) has not been compiled anywhere yet | The next `xcodebuild` run; then the manual checklist in `DEFINITION_OF_DONE.md` §3. The view layer intentionally holds no business logic, and everything it depends on (state machine, viseme maths, discovery, error mapping) *is* unit-tested |
| Live provider inference | Requires your key; no key is ever committed or bundled | Settings ▸ AI Providers ▸ "Test connection" |
| Live OAuth (Google/Meta) | Requires your cloud project and consent screens | `docs/INTEGRATIONS.md` + `backend/README.md` |
| Push/delivery of notifications on device | Requires a device and permission grant | Create a reminder two minutes out |
| Real quota exhaustion | Would require consuming a real free tier | Simulated 429 responses are tested; the provider's own message is surfaced |
| Voice pipeline end to end | Requires a microphone and speech permission | Manual: dictation round trip |

## 5. Limitations of this evidence

* `swiftc -parse` checks syntax, not types. A SwiftUI type error can still exist.
* `validate_project.sh` verifies structure and policy, not runtime behaviour.
* The IPA verifier itself is verified with synthetic archives; it has not yet seen a
  real `xcodebuild` product (the Xcode build has never run — see
  `DEFINITION_OF_DONE.md` §2).
* All provider, OAuth and integration tests use stubbed transports. They prove the
  client's behaviour, not the remote service's.

## 6. What the macOS CI runs found (and what was fixed)

Recorded because this is the part that could not be known before a real Mac ran:
the two defects below were invisible to every local check.

| Run | Finding | Fix |
|---|---|---|
| iOS #1 (`macos-14`, Xcode 16 toolchain) | `OrchestratorTests.swift:221/224: error: mutation of captured var 'confirmation' in concurrently-executing code` — the Linux Swift 6.0.3 toolchain compiled the same line happily | a lock-protected `Box` in `TestSupport.swift`, and the two redundant `await`s removed |
| iOS #2 (Xcode 15.4) | `xcodebuild: error: Unable to read project 'JarvisApp.xcodeproj'` — `Old-style plist parser: missing semicolon in dictionary on line 570`. The generated project emitted `TARGETED_DEVICE_FAMILY = 1,2;`, and a comma is structural in that grammar | one quoting rule for every emitted value (`plist_quote`) plus a real old-style-plist parser in the generator, so an unreadable project file can no longer be written or committed |
| iOS #3 (Xcode 15.4) | the app layer compiled for the first time: **9 errors, one root cause** — `Services.swift: cannot find 'UIImpactFeedbackGenerator' in scope` (no `import UIKit`, and that file is the only one without a SwiftUI import to re-export it) | guarded `import UIKit` in `Services.swift` and `RecoveryView.swift` |
| iOS #4 (Xcode 15.4) | **`** BUILD SUCCEEDED **`** — the app compiles, links and validates; the job then failed in *my own* packaging script: `zip I/O error: No such file or directory`, because `--output dist` was relative and `zip` ran inside the build directory | `build_unsigned_ipa.sh` anchors a relative `--output` to the caller's directory, and `scripts/test_ipa_packaging.sh` now reproduces the whole packaging path on Linux with a simulated `xcodebuild` |

Independent confirmation: the generated file also parses with the third-party
`pbxproj` library (`XcodeProject.load`), which mirrors Apple's grammar.

Runs #1–#4 are kept as the record of what was wrong. **Run #5 is green end to end:**
107 engine tests on `macos-14`, the app compiles, and the unsigned IPA is produced,
verified and uploaded — `JarvisApp-1.0.0-unsigned.ipa`, 3,611,746 bytes, SHA-256
`d109ff09b9f26b92a64c12e4d23618ef72a62da01f9c05e076a64cf9bc7aaa33` (confirmed by recomputing it on Linux after download). **Run #6** (tag
`v1.0.0`) rebuilt the package from the same commit and attached it, with its checksum, to
the release: 3,611,884 bytes, SHA-256 `24314b544679151e34dc8d9e2f018436a11bd68fad4dd05abc4d22e7ef40deeb`. The two differ in size because zip
stores timestamps; both were downloaded here, both verified, and both checksums match
what their workflow published. Backend workflow #1 (manual dispatch) is green as well.

```
$ ./scripts/verify_unsigned_ipa.sh JarvisApp-1.0.0-unsigned.ipa
  ok    zip integrity: ok
  ok    bundle: Payload/JarvisApp.app
  ok    bundle identifier: ai.jarvis.assistant
  ok    executable: JarvisApp
  ok    resource present: Assets.car
  ok    unsigned: no _CodeSignature, mobileprovision, CodeResources or entitlements
  ok    declared capabilities: background modes, ATS policy
  ok    no credential-shaped strings in the binary or plists
RESULT: the IPA is structurally valid and unsigned
```

## 7. Second cycle — v1.1.0: what the first device build found

`JarvisApp-1.0.0-unsigned.ipa` was installed and used on a real iPhone. Three of the
four defects below are **user-reported**; none of them were visible to `swiftc -parse`,
to `validate_project.sh`, or to the CI compile, because every one of them is a runtime
behaviour. They are recorded here because a report that only lists passing tests is a
worse report.

| # | Report | Root cause (found by reading the code path end to end) | Fix | Evidence |
|---|---|---|---|---|
| 1 | "I paste the Gemini API key and it does not work" | `ProviderSettingsView.saveKey()` wrote the key to the Keychain for the **selected** provider but never persisted `ProviderSettings`. With nothing saved, `AgentOrchestrator` had no active provider and answered "I can't reach a language model yet". Worse, `runTest()` used `saveSettingsIfNeeded()`, which saved only when *nothing* was stored — so a previously saved Groq config stayed active and the freshly pasted **Gemini key was sent to Groq**, which answered `401 Invalid API Key`. The app was not broken; it was talking to the wrong provider and hiding the reason | Saving a key now also activates the provider and its model (`saveKeyAndActivate`), every save writes the settings, "Run test" activates the on-screen configuration first so what you test is what runs, and the screen shows which provider is **active** versus which is being edited | `ModelDiscoveryTests` (14) cover the status/word reporting and the header-vs-URL key placement; the wiring itself is compile-verified in CI and needs a device to confirm (see `KNOWN_ISSUES.md` K13) |
| 2 | "Some buttons are hidden / do not respond to taps" | `NavigationShell` laid the custom tab bar out as an **overlay**: `ZStack(alignment: .bottom)` with the tab bar on top of the screen content. Anything a screen put near its bottom edge — the composer's send button, the approve/decline pair on a confirmation card, the last rows of long forms — sat *underneath* the bar: visible, but its taps were delivered to the bar | The content and the bar are now siblings in a `VStack`, so the content area ends where the bar begins. Every interactive control in the shell, the header, the composer and the confirmation card has a ≥44 pt hit area with an explicit `contentShape` | CI compile; device confirmation needed |
| 3 | "The UI is too basic" / "I want an animated face that speaks" | Correct assessment: v1.0.0 shipped a state-reactive orb, no face, no depth | Original animated face (`JarvisFace`): polished-silver cranium, dark visor with two luminescent optics, segmented seven-bar light mouth. The **mouth is driven by `AVSpeechSynthesizer.willSpeakRangeOfSpeechString`** — the letters actually being voiced map to a `Viseme` and a jaw opening, so the lips follow the words and stop when the voice stops; there is no decorative animation loop. Added a spatial layer (`SpatialBackdrop`, `MotionParallax`, `SpatialSurface`): three parallax strata moved by the device's own attitude (CoreMotion), lit by the assistant's state, with Reduce Motion and no-sensor fallbacks that are honest about what they are | `VisemeTests` (6) cover the shape maths. The rendering needs a device |
| 4 | Not user-reported — found while re-running the suite for this cycle | The first `Viseme` tests failed for a real reason: `Viseme(pronouncing:)` returned on the **first** matching letter, so "Jarvis" produced a fricative (the "j") and "stop" a fricative (the "s") instead of their vowel shapes. A mouth reads a word by its vowel | The initialiser now scans for the vowel first and only falls back to consonant shapes for words without one; the tests that encoded my wrong guesses were corrected, not deleted | `VisemeTests`, 6/6 passing |

### 7.1 What it cost to get the app layer compiled (CI runs #8–#11)

Every one of these was invisible to `swiftc -parse`, to `validate_project.sh` and to review,
because SwiftUI cannot be compiled anywhere but macOS. Each was small; each cost a full
CI round trip.

| Run | Finding | Fix |
|---|---|---|
| #8 | `JarvisFace.swift:269/274: error: cannot convert value of type 'AssistantState' to expected argument type 'PencilSqueezeGesturePhase'` and `member 'executing(tool:detail:)' is a function that produces expected type 'AssistantState'` — `state == .failed` and `state == .executing`; both cases carry payloads, so `==` does not exist for them, and the compiler's message names a completely unrelated type | `if case` helpers (`isFailed`, `isExecuting`); plus a validator check that greps for the pattern (comment lines excluded) so a SwiftUI-less toolchain catches it next time |
| #9 | `SpatialScene.swift:55: error: missing argument for parameter 'to' in call` — `startDeviceMotionUpdates(using:withHandler:)` does not exist; the handler variant takes an `OperationQueue` | passed the queue argument |
| #10 | `SpatialScene.swift:56: error: 'nil' is not compatible with expected argument type 'OperationQueue'` — that parameter is non-optional in this SDK | `to: .main` |
| **#11** | **green** — app compiled and linked (the first time any of the v1.1.0 UI has been compiled), unsigned IPA built, verified and uploaded | — |

Run #11 also produced the artefact, and the tag build produced the Release copy:

| Artefact | Size (bytes) | SHA-256 |
|---|---|---|
| workflow artifact, run #11 | 3,770,537 | `37a9af61ab68c7568504883ab07743dcb012ca2827f5ee1c8de53575ead088dd` |
| Release asset for `v1.1.0` | 3,770,566 | `36947e7354718bc96aa260bd8057592ab5a843cdc64b93647975fff6667549cc` |

Both were downloaded again here, each recomputed checksum matched the value its producer
published, and `scripts/verify_unsigned_ipa.sh` accepted both as structurally valid and
unsigned. Bundle `ai.jarvis.assistant`, version **1.1.0** (build 2), `MinimumOSVersion`
17.0, `UIDeviceFamily` [1, 2] (iPhone and iPad), executable `JarvisApp`, no `_CodeSignature`,
no provisioning profile, no entitlements, no credential-shaped strings.
