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
| 11 | Repository validation passes | 81 checks: layout, 11 screens present, asset catalog, Info.plist usage strings, project freshness, 73 Swift files, secrets scan, .gitignore coverage, backend layout/compile, docs | ✅ verified (after the fixes in §5) |
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
| 25 | The SwiftUI app target compiles | SwiftUI, EventKit, Speech, AVFoundation and UserNotifications do not exist on Linux | `xcodebuild -project ios/JarvisApp.xcodeproj -scheme JarvisApp -configuration Debug -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO build` |
| 26 | The unsigned `.ipa` is produced | `xcodebuild` requires macOS | `./scripts/build_unsigned_ipa.sh` |
| 27 | Runtime behaviour on a device: orb states, haptics, VoiceOver, Dynamic Type, Reduce Motion, safe areas | Requires a device or simulator | Run the app and walk the checklist in §3 |
| 28 | Live provider calls with a real key | No key is present by design (and no key will ever be committed) | Settings ▸ AI Providers ▸ "Test connection" |
| 29 | Live OAuth against Google/Meta | Requires your own cloud projects and consent screens | Settings ▸ Permissions and `backend/README.md` §OAuth |
| 30 | WhatsApp Business / Instagram Graph sends | Require your Meta Business account | `POST /v1/integrations/whatsapp/send` with `userApproved: true` |
| 31 | Reminder notifications firing in the foreground/background | Requires a device | Create a reminder two minutes out and wait |
| 32 | GitHub Actions green on a runner | Workflows are written and validated structurally, but have never executed (the repository is committed locally as `main`/`18cf9bd` with no remote yet) | Push the repository and open the Actions tab |

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
* `scripts/run_tests.sh` reported `python: unknown` instead of the test count: it
  passed `-q` on top of the `addopts = -q` in `backend/pytest.ini`, and quiet
  level 2 suppresses pytest's summary line. Fixed by dropping the duplicate flag
  and adding a "count unavailable" fallback — a summary that silently omits the
  number is how a suite gets reported as green without one.
