# SESSION HANDOFF — jarvis-ai-ios

**Left off at:** 2026-10-16, end of the second cycle.
**State:** v1.0.0 was installed on a real iPhone and produced three honest defects; all
three are fixed in **1.1.0**. The engine suite is **127 tests**, the repository validation
is **83 checks**, CI **iOS #11 is green** (the 1.1.0 app compiled and linked on `macos-14`
for the first time, after three red runs that each caught one real SDK-level mistake), and
`JarvisApp-1.1.0-unsigned-ipa` is published on the `v1.1.0` Release with its checksum. The
one thing left is the human step below.

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
# 1. Everything checkable without macOS (expect: 83 checks / 0 failures, 127 Swift tests, 112 python)
./scripts/validate_project.sh
./scripts/run_tests.sh

# 2. Already done for 1.1.0: CI iOS #11 green, tag v1.1.0 pushed, Release published.
#    Re-run only after a new commit (the ios workflow compiles, packages, verifies, uploads).

# 3. On a Mac, if one is available (same result, no CI round trip)
python3 scripts/generate_xcode_project.py --check
./scripts/build_unsigned_ipa.sh && ./scripts/verify_unsigned_ipa.sh dist/*.ipa
```

Then the human step, which is the only thing standing between this and "done": sign
`JarvisApp-1.1.0-unsigned.ipa` with your own method, install it, and run
`docs/DEFINITION_OF_DONE.md` §3. The two steps that matter most for this cycle are
**paste a real key → List models → Run test** (does the Active-provider card name the
provider you chose?) and **tap the last control on every screen** (does anything still hide
behind the tab bar?).

## Things that will bite you if you forget them

* **The GitHub token supplied for this cycle is not in the repository or its git config** —
  it was used through a one-shot `http.extraheader`, and the remote URL is plain HTTPS. The
  user should revoke it now that the IPA is delivered; a fine-grained token limited to
  `Contents: read/write` is enough for future pushes. A sandbox restore drops `.git/config`,
  so the remote may need re-adding: `https://github.com/m1ckey-bpl/jarvis-ai-ios.git`.
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
