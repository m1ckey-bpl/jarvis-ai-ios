# Definition of Done — status report

**Date:** 2026-10-16 · **Scope:** everything in this repository.
**Rule applied throughout:** a claim is "verified" only when it names a command
whose output was observed. Anything that could not be executed in this environment
is labelled *not verified here*, with the reason and the exact command you can run.

## 1. Verified in this environment

| # | Requirement | Evidence (observed) | Status |
|---|---|---|---|
| 1 | Engine builds from clean | `cd ios && swift build --build-tests` → `Build complete!` | ✅ verified |
| 2 | Engine test suite passes | `swift test --skip-build` → `Executed 107 tests, with 0 failures (0 unexpected) in 1.306s` — Context 6, Integration 16, Security 13, Provider 13, Reminder 17, Memory 13, ToolEngine 14, Orchestrator 15 | ✅ verified |
| 3 | Backend test suite passes | `cd backend && python3 -m pytest -q` → 112 tests across 8 files, 0 failures | ✅ verified |
| 4 | Backend starts and self-checks | `python3 -m app.main --check` → JSON report: schema version 2, 11 tools registered, capability report, `"ok": true` | ✅ verified |
| 5 | Backend refuses insecure configuration | `JARVIS_HOST=0.0.0.0 JARVIS_BACKEND_TOKEN= python3 -m app.main --check` → exit 2, refuses to start | ✅ verified |
| 6 | Every Swift file parses | `swiftc -parse` over all 72 app/engine/test files → clean | ✅ verified |
| 7 | Generated Xcode project is structurally valid | 162 objects, 63 Swift file references, 21 groups, 0 undefined references, balanced delimiters, `rootObject` present | ✅ verified |
| 8 | App icon and artwork generated | `python3 scripts/generate_app_icon.py` → icon-1024, icon-180, hero-1200x630, lockup-512, app-catalog icon; pixel profile sampled (specular (200,251,255), mid (108,150,182), lower (38,72,97)) | ✅ verified |
| 9 | IPA verifier accepts a valid unsigned IPA | synthetic well-formed bundle → `RESULT: the IPA is structurally valid and unsigned` (exit 0) | ✅ verified |
| 10 | IPA verifier rejects a broken IPA | malformed bundle → 8 named failures, exit 1 | ✅ verified |
| 11 | Repository validation passes | 82 checks: layout, 11 screens present, asset catalog, Info.plist usage strings, project freshness, 73 Swift files, secrets scan, .gitignore coverage, backend layout/compile, docs | ✅ verified (after the fixes in §5) |
| 12 | No secrets in the repository | validator's credential-pattern scan; only the four declared synthetic fixtures are excluded (`.secretsignore`), and each must carry the `synthetic-credential-fixture` marker inside the file or the build fails | ✅ verified |
| 13 | Prompt-injection defence works | `SecurityTests` (13 tests) + backend `test_injection_scan_and_wrapping` | ✅ verified |
| 14 | Memory persistence, correction chain, retrieval and export work | `MemoryTests` (13) + backend `test_memory.py` (15) | ✅ verified |
| 15 | Context budgeting and compaction work | `ContextTests` (6) | ✅ verified |
| 16 | Reminder parsing, recurrence and time zones work | `ReminderTests` (17) + backend `test_scheduler.py` (13) | ✅ verified |
| 17 | Tool authorization, validation and audit work | `ToolEngineTests` (14) + backend `test_tools.py` (13) | ✅ verified |
| 18 | Provider error handling and streaming decode work | `ProviderTests` (13) | ✅ verified |
| 19 | Integration clients work against recorded responses | `IntegrationTests` (16) + backend `test_integrations.py` (12) | ✅ verified |
| 20 | Orchestrator, confirmation broker and local routing work | `OrchestratorTests` (15) + backend `test_agent.py` (13) | ✅ verified |
| 21 | API surface behaves (auth, limits, routing, errors) | backend `test_api.py` (26), including a real-socket test and CORS allow-list behaviour | ✅ verified |
| 22 | Migrations are versioned and idempotent | backend `test_migrations_are_versioned_and_idempotent`, `test_migration_failure_is_reported_not_ignored` | ✅ verified |
| 23 | Zero-cost policy is documented and encoded | `docs/FREE_TIER_POLICY.md` with the 2026-10-16 verification date; `ProviderCatalog.verificationDate` | ✅ documented |
| 24 | Engineering memory exists and is current | `agent-memory/` — six files, constitution R1–R16, decisions D1–D16, issues K1–K12, backlog G1–G20/M1–M12 | ✅ verified |

## 2. Not verified here — no macOS or Xcode in this environment

| # | Item | Why not | How you verify it (exact command) |
|---|---|---|---|
| 25 | The SwiftUI app target compiles | ⚠️ **now verified** — the app layer compiled, linked and passed Xcode's bundle validation on a `macos-14` runner (`** BUILD SUCCEEDED **`, CI run #5). Its first compile found 9 errors with one root cause (a missing `import UIKit`), all fixed. | re-run any time: push, or `gh workflow run ios.yml` |
| 26 | The unsigned `.ipa` is produced | ⚠️ **now verified** — `JarvisApp-1.0.0-unsigned.ipa` built by CI run #5 (`3,611,746` bytes, SHA-256 `d109ff09b9f26b92a64c12e4d23618ef72a62da01f9c05e076a64cf9bc7aaa33`) and rebuilt for the tag by run #6 (`3,611,884` bytes, SHA-256 `24314b544679151e34dc8d9e2f018436a11bd68fad4dd05abc4d22e7ef40deeb`, attached to release `v1.0.0`). Both were downloaded and re-verified on Linux by `verify_unsigned_ipa.sh`; each checksum matches the one the workflow published | `./scripts/build_unsigned_ipa.sh` on a Mac, or download the run artifact / the `v1.0.0` release asset |
| 27 | Runtime behaviour on a device: orb states, haptics, VoiceOver, Dynamic Type, Reduce Motion, safe areas | Requires a device or simulator | Run the app and walk the checklist in §3 |
| 28 | Live provider calls with a real key | No key is present by design (and no key will ever be committed) | Settings ▸ AI Providers ▸ "Test connection" |
| 29 | Live OAuth against Google/Meta | Requires your own cloud projects and consent screens | Settings ▸ Permissions and `backend/README.md` §OAuth |
| 30 | WhatsApp Business / Instagram Graph sends | Require your Meta Business account | `POST /v1/integrations/whatsapp/send` with `userApproved: true` |
| 31 | Reminder notifications firing in the foreground/background | Requires a device | Create a reminder two minutes out and wait |
| 32 | GitHub Actions green on a runner | ⚠️ **now verified** — *Validate repository* #5 green (82 checks), *iOS* #5 green: engine tests 107/0 on `macos-14`, unsigned IPA built, verified and uploaded (3.4 MB artifact) | `gh workflow run ios.yml` |

## 3. Manual acceptance checklist (10 minutes on a device)

1. **Cold start** — onboarding appears once, then the assistant greeting: time of
   day, memory count, and (if unset) the provider prompt.
2. **Memory** — "remember that I prefer concise answers" → a system row confirms the
   record; ask "what do you remember" → the fact returns without a provider call.
3. **Retrieval transparency** — the composer shows "Using N remembered details";
   tap it and confirm those records are the ones in the Memory tab.
4. **Correction** — Memory ▸ Correct a record → the replacement appears and the
   original is marked superseded (visible with "include inactive").
5. **Forget** — "forget that …" → confirmation, then the record disappears.
6. **Reminder** — "remind me tomorrow at 9am to review notes" → Tasks shows the
   reminder with "repeats"/notification state and the creation message says whether
   a notification was actually scheduled.
7. **Confirmation gate** — ask JARVIS to send an email or delete a memory record:
   the confirmation card appears, shows the risk class and the exact arguments, and
   declining leaves the record untouched.
8. **Tool log** — Tool history shows the run with redacted arguments, the outcome,
   the risk class and the duration.
9. **Voice** — tap the microphone: the orb enters Listening, the waveform reacts to
   your voice, stopping sends the transcript and returns to Thinking.
10. **Provider absent** — remove the key: the assistant says what to do instead of
    pretending to think; the orb shows the error state with a recovery action.
11. **Offline** — enable aeroplane mode: memory commands and reminders still work;
    provider calls report a network error.
12. **Recovery screen** — force an error (fill the device's storage, or edit a
    database path in a debug build) and confirm the screen names the real error and
    offers the diagnostics.
13. **Accessibility** — enable Reduce Motion (animations collapse), set the text size
    to the largest setting (nothing truncates), turn VoiceOver on (orb state, rows
    and disabled reasons are announced).
14. **Erase** — Settings ▸ Erase all local data → everything is gone, and the app
    returns to an honest first-run state.

## 4. Remaining risks (also tracked in `agent-memory/KNOWN_ISSUES.md`)

* The SwiftUI layer has never been compiled: type errors in views are possible even
  though every file parses cleanly. First Xcode build is the real gate.
* `HashingEmbedder` is lexical, not semantic. Retrieval quality on paraphrases will
  be lower than a real embedding model would give.
* Retrieval quality is not measured against a labelled set; the ranking weights are
  reasoned, not tuned.
* The backend has no integration test against a live provider or a live Meta/Google
  endpoint (by design: no credentials are involved in CI).
* Rate-limit handling is verified against simulated 429 responses, not a real quota
  exhaustion.
* Free-tier terms are verified as of 2026-10-16 and can change without notice.

## 5. Honourable mentions — what changed during this build because of evidence

These were found by running things, not by review, and are recorded so the record
is not prettier than the history:

* `SSEParser` dropped the final event when a stream ended without a blank line —
  fixed with an explicit EOF flush.
* Retrieval matched stop words, so "what do you know about me" could rank noise
  above records — fixed by excluding stop words from search terms.
* `AgentOrchestrator.reminderEngine` was `weak` and silently `nil`, so reminders
  created through the model never scheduled — fixed to a strong reference.
* `ContextManager` truncated the transcript before compacting, so the summary never
  saw the full conversation — fixed to summarise the full transcript.
* `ConfirmationBroker` could lose an early decision when the user approved before
  the request was registered, which then hung for the full timeout — fixed with an
  early-decision buffer.
* `DateTimeParser` read the wrong capture group for "6pm" (parsed as 06:00) — fixed
  with an explicit pattern table.
* The title extractor stripped the word "my" from reminder titles — fixed.
* `JarvisError.providerQuotaExceeded` reported itself as non-retryable even with a
  `Retry-After` header — fixed.
* The generated `project.pbxproj` referenced **zero** Swift files in its first
  revision (empty groups); the generator was rewritten and its output is now
  validated for object counts and dangling references.
* The icon artwork gained grey halos around its highlights because Pillow's blur on
  RGBA drags colour toward the transparent surround — fixed by blurring the alpha
  channel only.
* The **first macOS CI run** rejected a test line the Linux toolchain accepted:
  `mutation of captured var 'confirmation' in concurrently-executing code`. Fixed with a
  lock-protected box in the tests (`Box` in `TestSupport.swift`). Local checks could not
  have found this — only a different toolchain did.
* **The app layer's first real compile** (CI #3) found one missing `import UIKit` in
  `Services.swift` — nine errors, one root cause — and nothing else. `swiftc -parse`
  could never have seen it.
* **`build_unsigned_ipa.sh` failed to package the artefact** (CI #4, after
  `** BUILD SUCCEEDED **`) because `--output dist` was treated as relative to the build
  directory: `zip I/O error: No such file or directory`. The path is now anchored to the
  caller's directory, and `scripts/test_ipa_packaging.sh` reproduces the packaging path
  on Linux with a simulated `xcodebuild`, so the next such bug is caught locally.
* The **generated `project.pbxproj` could not be read by Xcode at all**:
  `Old-style plist parser: missing semicolon in dictionary on line 570`, because a build
  setting was emitted as `TARGETED_DEVICE_FAMILY = 1,2;` and a comma is structural in that
  grammar. Every value now goes through one quoting rule, and the file is verified with a
  real old-style-plist parser (in the generator *and* in `validate_project.sh`) before it
  can be written or committed. Balanced-brace and dangling-reference checks had passed on
  the broken file — which is exactly why they were not enough.
* **The first real-device build (v1.0.0) reported "the API key does not work."** The key
  was fine; the app was talking to a different provider than the user had just selected.
  `saveKey()` stored the key for the selected provider but never saved which provider was
  selected, and `runTest()` only saved settings when nothing was stored — so a pasted
  Gemini key went to the provider saved earlier (Groq → `401 Invalid API Key`), and with
  nothing saved at all the assistant reported "I can't reach a language model yet". Fixed
  by making every save activate the provider it describes, testing what is on screen
  rather than what happened to be stored, showing which provider is active, and listing
  the models the user's own key can use. The live probes recorded in §2 item 13 proved
  the request shapes were right all along, which is what pointed at state rather than
  transport.
* **The first real-device build also hid its own buttons.** `NavigationShell` placed the
  tab bar as an overlay (`ZStack(alignment: .bottom)`), so the composer, the
  approve/decline pair and the last rows of long forms sat underneath it: visible, but
  unreachable, because the taps hit the bar. Content and bar are now siblings in a
  `VStack`, and every interactive control carries a ≥44 pt hit area with an explicit
  `contentShape`. Both of these were found by the user on a phone, not by any check in
  this repository — a reminder that a green pipeline is a floor, not a ceiling.
* **The first `Viseme` tests failed for a real reason.** The shape function returned on
  the first matching letter, so "Jarvis" got the "j" (fricative) and "stop" got the "s"
  instead of their vowel shapes — a mouth reads a word by its vowel. The initialiser now
  scans for the vowel first; the tests that encoded my wrong expectations were corrected
  rather than deleted, and the corrected expectations are in `TEST_REPORT.md` §7.
* `scripts/run_tests.sh` reported `python: unknown` instead of the test count: it
  passed `-q` on top of the `addopts = -q` in `backend/pytest.ini`, and quiet
  level 2 suppresses pytest's summary line. Fixed by dropping the duplicate flag
  and adding a "count unavailable" fallback — a summary that silently omits the
  number is how a suite gets reported as green without one.

## 6. Addendum — the build, after four red runs

| Run | Result |
|---|---|
| #1 | red — engine build: captured-var error in a test (Linux toolchain had accepted it) |
| #2 | red — `xcodebuild` could not read the generated project (unquoted comma) |
| #3 | red — app layer's first compile: 9 errors, one root cause (missing `import UIKit`) |
| #4 | red — `** BUILD SUCCEEDED **`, then my packaging script mis-handled a relative `--output` |
| **#5** | **green** — 107 engine tests on macOS, app built, unsigned IPA produced, verified, uploaded |
| #6 | green — tag `v1.0.0`: same artefact attached to a GitHub Release (link that does not expire) |

Artefacts: `JarvisApp-1.0.0-unsigned.ipa` — 3,611,746 bytes, SHA-256
`d109ff09b9f26b92a64c12e4d23618ef72a62da01f9c05e076a64cf9bc7aaa33` (run #5 artifact), and 3,611,884 bytes, SHA-256 `24314b544679151e34dc8d9e2f018436a11bd68fad4dd05abc4d22e7ef40deeb`
(run #6, the `v1.0.0` release asset). The two are not byte-identical because the second
was rebuilt from the same commit and zip records timestamps; **each one's checksum
matches the value the workflow published for it**, recomputed independently here.
Bundle `ai.jarvis.assistant`, minimum iOS 17.0, arm64, no `_CodeSignature`, no
provisioning profile, no entitlements.

Still not verified, and unchanged by this: runtime behaviour on a device (§2 items
27–31 — orb states, haptics, VoiceOver, notifications, live provider and OAuth calls).
