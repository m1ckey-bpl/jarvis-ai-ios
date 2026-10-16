# CURRENT STATE — jarvis-ai-ios

**Last updated:** 2026-10-16 (second cycle, after the first device build)
**Version in the tree:** 1.1.0 · **CI status:** pushed, run in progress
**One-line summary:** v1.0.0 was installed on a real iPhone and produced three honest
defects; all three are fixed in 1.1.0, the engine grew to 127 tests and the repository
validation to 82 checks — both green locally, with CI running on the push.

## What v1.0.0 looked like on the device

The user's report, verbatim in substance: the UI is "so basic", the Gemini key paste
"does not work", some buttons are hidden or outside the frame, some buttons do not
respond to taps, and they want an animated human face whose lips move while JARVIS
speaks plus a spatial UI.

Three of those were real defects, one was a design gap:

| Report | Root cause | Status |
|---|---|---|
| API key "does not work" | `saveKey()` wrote the key for the **selected** provider but never saved `ProviderSettings`, so no provider was active; `runTest()` only saved settings when nothing was stored, so a pasted Gemini key was sent to the previously saved Groq config → `401 Invalid API Key` | **FIXED** in 1.1.0 |
| Buttons hidden / taps dead | `NavigationShell` laid the tab bar over the content (`ZStack(alignment: .bottom)`), so the composer, approve/decline and the last rows of long forms sat *under* the bar and their taps went to the bar | **FIXED** in 1.1.0 |
| "Too basic", no face | v1.0.0 shipped a state orb and flat cards | **BUILT** in 1.1.0: animated face + spatial layer |
| Viseme shape logic | first test run failed: the shape came from the first matching *letter*, so "Jarvis" was a fricative ("j") and "stop" a fricative ("s") | **FIXED** — the vowel decides the shape now |

## Current numbers (all re-run after the fixes)

| Check | Command | Result |
|---|---|---|
| Repository validation | `bash scripts/validate_project.sh` | **82 checks, 0 failures** |
| Engine tests | `cd ios && swift build --build-tests && swift test --skip-build` | **127 tests, 0 failures** (was 107; +14 model-discovery, +6 viseme) |
| Backend tests | `cd backend && python3 -m pytest` | **112 passed** |
| Packaging path (no macOS needed) | `bash scripts/test_ipa_packaging.sh` | **passes** with a simulated `xcodebuild` |
| Generated Xcode project | `python3 scripts/generate_xcode_project.py --check` | **fresh** — 171 objects, 22 groups, 67 Swift sources |
| App-layer syntax | `swiftc -parse` over all 73 Swift files | **0 failures** |

## What changed in the tree this cycle

* **`ProviderSettingsView`** — every save now activates the provider it describes
  (`saveKeyAndActivate`), "Run test" activates the on-screen configuration first, an
  **Active provider** card shows what the assistant will actually use (with a key
  fingerprint, never the key), a **List models** button asks the provider what the user's
  own key can use, and a copyable **Diagnostics** block reports the endpoint, model, key
  fingerprint, HTTP status and the provider's own words.
* **`ModelDiscovery.swift`** (engine, new) — `probe()` returns models *and* status *and*
  the provider's message, never throwing away the reason; chat models are filtered and
  ranked deterministically; the key travels in a header, never in a URL.
* **`HTTPTransport.mapStatus`** — now quotes the provider's own error message, treats
  Google's `400 INVALID_ARGUMENT: API key not valid` as an authentication problem, and
  turns `404` into "the model name was not found for this key — press List models".
* **`ProviderCatalog`** — free-tier notes corrected for mid-2026 reality (Gemini free =
  Flash/Flash-Lite only, Pro is paid; Groq free = gpt-oss/qwen families, Llama left the
  free plan in August 2026).
* **`JarvisFace.swift`** (new) — original abstract android visage: polished cranium,
  dark visor with two luminescent optics, seven-bar light mouth. The mouth is driven by
  `AVSpeechSynthesizer.willSpeakRangeOfSpeechString` (words → viseme → jaw opening), so
  the lips follow real speech events; `SpeechSynthesizerService` now publishes
  `viseme`, `jawOpen` and `speakingRange`.
* **`Viseme.swift`** (new, in the engine so CI tests it) — vowel-first shape maths.
* **`SpatialScene.swift`** (new) — `MotionParallax` (CoreMotion attitude, smoothed, with
  an honest ambient drift when no sensor / Reduce Motion), `SpatialBackdrop` (three
  parallax strata + state-reactive light bloom), `SpatialSurface`, `.spatial(depth:)`.
* **`NavigationShell`** — content and tab bar are siblings in a `VStack`; 44 pt targets.
* **`AssistantHomeView`** — face replaces the bare orb, live mini-orb in the header,
  44 pt targets throughout; tapping the face interrupts speech.
* **Version** — `MARKETING_VERSION` 1.1.0, `CURRENT_PROJECT_VERSION` 2, so the new
  artefact is `JarvisApp-1.1.0-unsigned.ipa` and cannot be confused with the old one.

## What is still NOT verified

* **The v1.1.0 app has never been compiled.** CI compiles it on this push; until that run
  is green, the new SwiftUI code (face, spatial layer, reworked navigation and provider
  screen) is syntax-checked only. This is the single biggest open risk.
* **Nothing from v1.1.0 has run on a device.** The provider fix, the layout fix, the face
  and the parallax all need one install to confirm.
* **No live provider call has ever been made with a real key.** The request shapes are
  verified against the real endpoints with deliberately invalid keys (HTTP 400/401 with
  the providers' own messages), which is as far as this environment can go.

## Immediate next steps

1. Watch the CI run for this push; fix whatever the macOS compile reports (it is the
   app layer's first compile each cycle — expect something small, as in iOS #3 and #4).
2. Tag `v1.1.0` so the rebuilt IPA lands on a Release with its checksum.
3. Hand the new IPA over; the user signs and installs it, then runs
   `docs/DEFINITION_OF_DONE.md` §3 and — the important one — pastes their real key into
   Settings ▸ AI Providers and presses **List models**, then **Run test**.

## File-by-file quick index

| Path | What it is |
|---|---|
| `ios/JarvisCore` | The engine: providers, discovery, memory, tools, reminders, security (39 sources) |
| `ios/JarvisApp` | The SwiftUI app: 11 screens, design system, face, spatial layer (28 sources) |
| `ios/JarvisTests` | 127 engine tests |
| `backend/` | Optional stdlib-only service: 112 tests |
| `scripts/` | validate, tests, IPA build/verify, packaging harness, project + icon generators |
| `docs/` | 13 documents, including `TEST_REPORT.md` (§7 is this cycle) and `GET_THE_IPA.md` |
| `agent-memory/` | These six files |
