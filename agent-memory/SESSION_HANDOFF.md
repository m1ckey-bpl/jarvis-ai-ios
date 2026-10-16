# SESSION HANDOFF — jarvis-ai-ios

**Left off at:** 2026-10-16, end of the second cycle.
**State:** v1.0.0 was installed on a real iPhone and produced three honest defects; all
three are fixed in **1.1.0**, the engine suite is now **127 tests**, the repository
validation is **82 checks**, and both are green locally. The repository was pushed so CI
can compile the new app layer — **watch that run before claiming anything about 1.1.0**.

## Read these first (in order)

1. `agent-memory/PROJECT_CONSTITUTION.md` — the rules (R1–R16) that override style
   preferences. Never edit silently.
2. `agent-memory/CURRENT_STATE.md` — where the work actually stands.
3. `docs/TEST_REPORT.md` — the evidence; **§7** is the device-defect cycle.
4. `docs/DEFINITION_OF_DONE.md` — verified vs. still unverified, and §3 is the device
   checklist the next human runs.

## Where this left off

The user installed `JarvisApp-1.0.0-unsigned.ipa` and reported: the API key paste "does
not work", some buttons are hidden or do not respond, the UI is "too basic", and they want
an animated speaking face plus a spatial UI. Diagnosis and fixes:

| Report | Real cause | Fix (all in 1.1.0) |
|---|---|---|
| Key "does not work" | The key was saved but the **provider never was**, so either no provider was active ("I can't reach a language model yet") or the key was sent to the previously saved provider (Groq → `401 Invalid API Key`) | Saves now activate the provider they describe; the test activates what is on screen; an Active-provider card states what will be used; **List models** asks the provider what the key can actually use; a copyable Diagnostics block reports endpoint, model, key fingerprint, HTTP status and the provider's own words |
| Hidden / dead buttons | The tab bar was an **overlay** over the content, so the composer, the approve/decline pair and the last rows of long forms sat beneath it | Content and bar are siblings in a `VStack`; ≥44 pt targets with explicit `contentShape` throughout |
| "Too basic" | True | Original animated face (`JarvisFace`) whose mouth is driven by the speech synthesiser's own word callbacks, plus a spatial layer (`SpatialScene`) with CoreMotion parallax, depth tokens and state-reactive light |
| First viseme tests failed | The shape came from the first matching letter, so "Jarvis" was a fricative ("j") | Vowels decide the shape; consonant shapes only for words without vowels |

## Exact next actions

```bash
# 1. Everything checkable without macOS (expect: 82 checks / 0 failures, 127 Swift tests, 112 python)
./scripts/validate_project.sh
./scripts/run_tests.sh

# 2. The run for this push must be green before anything is claimed about 1.1.0
#    (it is the app layer's first compile each cycle — iOS #3 and #4 each found one real bug)

# 3. When it is green: publish the durable artefact
git tag -a v1.1.0 -m "JARVIS 1.1.0 — provider activation fix, layout fix, animated face, spatial UI"
git push origin v1.1.0        # CI rebuilds the IPA and attaches it to a Release

# 4. On a Mac, if one is available (same result, no CI round trip)
python3 scripts/generate_xcode_project.py --check
./scripts/build_unsigned_ipa.sh && ./scripts/verify_unsigned_ipa.sh dist/*.ipa
```

Then the human step: sign `JarvisApp-1.1.0-unsigned.ipa` with the user's own method,
install, and run `docs/DEFINITION_OF_DONE.md` §3 — the two steps that matter most for this
cycle are **paste a real key → List models → Run test** and **tap the last control on
every screen**.

## Things that will bite you if you forget them

* **This sandbox loses `.git/config` and file modes between turns.** Set the commit
  identity inline (`git -c user.name=… -c user.email=… commit`) and `chmod +x scripts/*.sh`
  before committing, or CI's `./scripts/…` invocations stop being executable. A missing
  `+x` shows up as `verify_unsigned_ipa.sh: Permission denied` inside the packaging check.
* **Never hand-quote a value in the pbxproj generator.** Everything goes through
  `plist_quote`; a bare `1,2` is a syntax error in that grammar and Xcode refuses the whole
  project (`Old-style plist parser: missing semicolon…`). `--verify` and
  `validate_project.sh` catch it.
* **The Xcode project is generated.** Edit the tree, regenerate, never hand-patch
  `project.pbxproj`; `--check` fails if it is stale (67 Swift sources at 1.1.0).
* **Version lives in the generator**, not in `Info.plist` (the plist uses
  `$(MARKETING_VERSION)`): `scripts/generate_xcode_project.py`, then regenerate.
* **`build_unsigned_ipa.sh` anchors a relative `--output`** to the caller's directory;
  `zip` runs inside the build directory — that is what broke CI #4.
* **No macOS here — but CI has one.** Compilability claims must cite a workflow run;
  `swiftc -parse` is syntax only and has already missed four real defects.
* **`swift test` can hang** if an orphaned `swift-test`/`xctest` holds the build lock;
  `run_tests.sh` clears them and `pgrep -af 'swift|xctest'` diagnoses it.
* **Don't add `-q` to the backend pytest call** — `backend/pytest.ini` already sets
  `addopts = -q`, and quiet level 2 suppresses the "N passed" line, which makes
  `run_tests.sh` print `python: unknown`.
* **Secrets.** No key may be committed, logged, screenshotted or bundled. The only
  permitted credential-shaped strings are the files listed in `.secretsignore`, each
  carrying the `synthetic-credential-fixture` marker. The GitHub token the user provided
  for this cycle was used only for repo creation, push, tagging and artefact download; it
  is **not** stored in this repository or its git config, and should be revoked by the
  user once the IPA is delivered.
* **`AgentOrchestrator.reminderEngine` must stay a strong reference**; **`SSEParser.flush()`
  must keep being called at EOF**; **don't add `-q` twice**; **don't reproduce the provider
  settings bug** by making any save path conditional again (`D19`).
* **Phrasing matters in orchestrator tests**: "remind me …" is answered locally with no
  provider call, so provider/tool-loop tests must use phrasing that falls through to the
  model ("please schedule something for …").

## Workspace facts

* Swift 6.0.3 at `/opt/swift/usr/bin` (not snapshotted; reinstall if missing).
* Build products live in `ios/.build` (git-ignored, excluded from snapshots).
* Backend data dir defaults to `backend/data` (git-ignored).
* `docs/`, `agent-memory/` and `scripts/` are current as of this session; the six memory
  files were updated at the end of it, per the constitution.
