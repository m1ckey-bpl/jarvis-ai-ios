# SESSION HANDOFF — jarvis-ai-ios

**Left off at:** 2026-10-16. Engine and backend are green; the app layer is written
and parse-checked; the Xcode build has never run.

## Read these first (in order)

1. `agent-memory/PROJECT_CONSTITUTION.md` — the rules (R1–R16) that override style
   preferences. Never edit silently.
2. `agent-memory/CURRENT_STATE.md` — where the work actually stands.
3. `docs/DEFINITION_OF_DONE.md` — what is verified vs. what still needs a Mac.
4. `docs/TEST_REPORT.md` — the recorded evidence, with the mocked/live distinction.

## Exact next actions

```bash
# 1. Sanity: everything that can be checked without macOS
./scripts/validate_project.sh          # expect: 82 checks, 0 failures
./scripts/run_tests.sh                 # expect: swift 107/0, python 112 passed

# 2. Publish (no credentials in this repo, none needed)
git remote add origin <your-repo-url>
git push -u origin main                # macOS runner then compiles JarvisApp for the first time

# 3. When a Mac is available (or via the CI artifact)
python3 scripts/generate_xcode_project.py --check
./scripts/build_unsigned_ipa.sh
./scripts/verify_unsigned_ipa.sh dist/*.ipa
```

## Things that will bite you if you forget them

* **No macOS here.** Never write "the app builds" or "the IPA exists" — it does not
  yet. `swiftc -parse` is syntax only.
* **`swift test` can hang** if an orphaned `swift-test`/`xctest` process holds the
  build lock; `scripts/run_tests.sh` clears them, and `pgrep -af 'swift|xctest'`
  diagnoses it.
* **The Xcode project is generated.** Edit the tree (or
  `scripts/generate_xcode_project.py`), regenerate, and never hand-patch
  `project.pbxproj`; CI checks freshness with `--check`.
* **Secrets.** No key may be committed, logged, screenshotted or bundled. The only
  permitted credential-shaped strings are the four files listed in `.secretsignore`,
  each of which must carry the `synthetic-credential-fixture` marker.
* **`AgentOrchestrator.reminderEngine` must stay a strong reference** (a weak one
  silently became `nil`, so model-created reminders never scheduled).
* **`SSEParser.flush()` must keep being called at EOF**, or the last stream event is
  dropped — including `data: [DONE]`.
* **Don't reintroduce `latestSummary` on `ConversationStore`**, and don't make
  `ContextManager.summarizer` private — the app layer calls both paths.
* **Don't add `-q` to the backend pytest invocation** — `backend/pytest.ini` already
  sets `addopts = -q`, and quiet level 2 suppresses the "N passed" line, which makes
  `run_tests.sh` print `python: unknown`. Use `python3 -m pytest` (or
  `-o addopts=` when you want the classic summary banner).
* **Phrasing matters in orchestrator tests**: "remind me …" is answered locally with
  no provider call, so provider/tool-loop tests must use phrasing that falls through
  to the model ("please schedule something for …").

## Workspace facts

* Swift 6.0.3 at `/opt/swift/usr/bin` (not snapshotted; reinstall if missing).
* Build products live in `ios/.build` (git-ignored, excluded from snapshots).
* Backend data dir defaults to `backend/data` (git-ignored).
* `docs/`, `agent-memory/` and `scripts/` are all current as of this session.
