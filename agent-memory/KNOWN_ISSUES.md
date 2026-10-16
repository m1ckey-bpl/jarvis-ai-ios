# KNOWN ISSUES — jarvis-ai-ios

Severity: S1 blocks delivery · S2 degrades a feature · S3 cosmetic/annoyance
Every entry: symptom · reproduction · root cause (or "under investigation") · workaround · status

---

### K1 — No unsigned IPA can be produced in the Linux agent sandbox · **S1** · OPEN (external)
- **Symptom:** `xcodebuild` unavailable; iOS builds require macOS + Xcode (Apple toolchain is not open-source).
- **Reproduction:** `command -v xcodebuild` → not found (Debian 13 sandbox).
- **Root cause:** Platform limitation, not a project defect.
- **Workaround delivered:** `scripts/build_unsigned_ipa.sh` + `scripts/verify_unsigned_ipa.sh` +
  `.github/workflows/ios-build.yml` (macOS runner, free for public repos) + documented manual commands.
- **Residual risk:** the first CI/macOS run may surface compile errors in the SwiftUI layer (see K2).

### K2 — SwiftUI app layer not compile-verified in this environment · **S2** · OPEN
- **Symptom:** The SwiftUI/UIKit-dependent files compile only with an Apple SDK.
- **Root cause:** SwiftUI is unavailable on Linux (same constraint as K1).
- **Mitigation executed:** (a) all business logic moved into `JarvisCore`, which **is** compiled and tested here;
  (b) app-layer files validated with `swiftc -parse` (syntax) here; (c) conservative API usage (no exotic modifiers);
  (d) CI compile gate; (e) `#if compiler(>=6.2)` guards so newer-SDK APIs cannot break older toolchains.
- **Status:** first `xcodebuild` run is expected to be the true verification. Until then UI is marked IMPL, not DONE.

### K3 — GitHub connector unavailable in this session · **S1 (delivery)** · OPEN (external)
- **Symptom:** `list_connector_tools("github")` → `unsupported`; agent cannot create/push the repository.
- **Workaround:** repository initialised with full history locally; user pushes (or connects GitHub, then agent pushes).
- **Commands for the user:** see `docs/BUILD_GUIDE.md` §"Publish the repository".

### K4 — Free inference tiers can change or rate-limit without notice · **S2** · ACCEPTED (monitored)
- **Symptom:** A provider's free quota may be reduced/removed; requests may return 429.
- **Handling implemented:** provider-agnostic abstraction + multiple providers + exponential backoff with a bounded
  retry count + explicit "quota exhausted / unconfigured" UI states (never a fabricated answer).
- **Policy:** limits verified 2026-10-16 and recorded in `docs/FREE_TIER_POLICY.md`; users may switch providers freely.

### K5 — Instagram personal-account automation is not possible via official APIs · **S3** · ACCEPTED-LIMIT
- **Symptom:** No official free API exposes personal DM reading/"automation".
- **Cause:** Meta's platform policy; Instagram Graph API covers professional accounts and their own content/insights.
- **Handling:** integration is scoped to what is officially permitted (account info, media, insights for
  professional accounts). Read-only, explicitly labelled; no private-DM claims are made anywhere in the product.

### K6 — WhatsApp personal chats cannot be read programmatically · **S3** · ACCEPTED-LIMIT
- **Symptom:** No official API exposes personal WhatsApp message history.
- **Handling:** On-device compose via `whatsapp://send` URL scheme (user-directed), plus the official WhatsApp
  Business Cloud API path for business accounts (requires the user's own Meta business setup). Documented in
  `docs/INTEGRATIONS.md`.

### K7 — Background execution is OS-restricted · **S3** · ACCEPTED-LIMIT
- **Symptom:** The app cannot run continuously; server-style agents cannot live on the phone.
- **Handling:** reminders use `UNUserNotificationCenter` (delivered by iOS itself); anything needing independent
  execution is delegated to the optional backend scheduler (free-tier hosting caveats documented) or surfaced as
  "(requires app open)" where iOS dictates.

### K8 — Backend free-tier hosts sleep/warm-slow · **S3** · ACCEPTED-LIMIT
- **Symptom:** Free instances idle-suspend; first request after idle is slow or fails once.
- **Handling:** the app treats backend features as optional; on cold-start failure it retries once with backoff and
  explains the state; local features keep working. Retention/hosting notes in `docs/FREE_TIER_POLICY.md`.

### K9 — First-launch "unconfigured" experience requires user action · **S3** · BY DESIGN
- **Symptom:** With no inference key, the assistant answers with an explicit setup message, not an AI reply.
- **Rationale:** R14/R15 — never simulate intelligence. The onboarding flow makes setup a 60-second task.

### K10 — `swiftc -parse` is syntax-only · **S3** · OPEN
- **Symptom:** Syntax validation cannot catch SwiftUI type errors.
- **Handling:** treated as a smoke test only; the authoritative check is the macOS build (K2).

### K11 — The SwiftUI app layer has never been compiled · **S1** · OPEN (highest risk)
- **Symptom:** `ios/JarvisApp/**` (24 files, 5,233 lines) has been written and
  `swiftc -parse`-checked, but no SwiftUI/EventKit/Speech/AVFoundation module exists in the
  development environment, so no type checking has occurred. Type errors are therefore possible
  in views, `@State`/`@EnvironmentObject` usage and modifier chains.
- **Impact:** The app cannot be claimed to build until a macOS run. The engine beneath it (107
  tests) and the backend (112 tests) are unaffected.
- **Update 2026-10-16:** the engine and its 107 tests now build and pass on a real
  `macos-14` runner (CI run #2). The *app layer* still has not compiled: the run stopped
  one step earlier, at `xcodebuild` being unable to read the generated project file
  (unquoted comma bug, fixed). So the risk below still stands for the SwiftUI code, and
  the next CI run is its first real type check.
- **Handling:** `docs/DEFINITION_OF_DONE.md` §2 lists this as *not verified here* with the exact
  command; the iOS CI job exists to close it; the manual checklist is written and ready.
- **Next step:** run `xcodebuild -project ios/JarvisApp.xcodeproj -scheme JarvisApp -configuration
  Debug -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO build` and fix what it reports.

### K12 — No live provider, OAuth or integration path has executed · **S2** · BY DESIGN
- **Symptom:** Every provider/OAuth/integration test uses a stubbed transport. No request has ever
  reached Groq, Google, Meta or GitHub from this codebase.
- **Rationale:** No credential may be committed, bundling one is forbidden, and the sandbox has no
  network access for these services. The stubs assert URL shapes, headers, error mapping and the
  absence of secrets in logs — not that the remote service behaves as documented.
- **Handling:** `docs/TEST_REPORT.md` labels every test *mocked*; the connection test in
  Settings ▸ AI Providers is the live check, and `docs/INTEGRATIONS.md` documents each provider's
  requirements.
- **Residual risk:** an API change on a provider side would only surface at the user's first live
  call. The error taxonomy maps such failures to actionable messages rather than silent ones.
