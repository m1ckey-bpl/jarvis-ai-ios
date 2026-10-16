# Security

## 1. Threat model

| Threat | Mitigation |
|---|---|
| Secrets extracted from the app or the repository | No key is bundled. Provider and integration credentials live in the iOS Keychain or in the operator's environment. The repository is scanned in CI for credential-shaped strings. |
| Secrets extracted from the IPA | The build contains no signing material, and the verification step fails the build if `_CodeSignature`, a provisioning profile, entitlements or credential-shaped strings are found in the bundle. |
| Prompt injection from email, web pages or files | Eight pattern families are detected; external text is wrapped in untrusted markers with a security notice; untrusted records are penalised in retrieval and can never be instructions or authorise tools. |
| A model taking a consequential action on its own | The model can only propose. The tool executor validates arguments, checks capability and permission state, and routes anything at or above `communicating` to the human. The backend repeats that authorization independently. |
| Token or key leakage through logs | Logging passes through a redactor that removes bearer tokens, `sk-`/`gsk_`/`AIza`/`ghp_`/`EAA` shapes and any `token`/`secret`/`password` field. Tool arguments and errors are redacted before they are written to the run log. |
| Malicious or accidental data loss | Destructive actions (delete memory, erase all data, cancel reminders, close a repository action) require an explicit confirmation that names what will be affected. Corrections keep the superseded record. |
| Server-side exposure | The backend refuses to bind to a public interface without an auth token, refuses a public bind without explicit TLS acknowledgement, rate-limits per identity, caps request bodies, and only echoes CORS origins from an allow-list. |
| Path traversal / SSRF through tools | `web.fetch` blocks loopback, link-local and metadata addresses. Tool arguments are validated against declared types, ranges and enums; unknown arguments are rejected. |
| Third-party content changing the assistant's rules | The system prompt states that untrusted content is data, not instructions, and that no message can change those rules. |

## 2. Where secrets live

| Secret | Location | Never |
|---|---|---|
| Provider API keys | iOS Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`) | in `UserDefaults`, logs, screenshots, the repo, the IPA |
| GitHub token | iOS Keychain | — |
| Google refresh token | Keychain on device; encrypted in the backend database when the server performs the exchange | never in the client if the server holds it |
| Google client secret | Backend environment only | never in the iOS app or this repository |
| WhatsApp / Instagram / search keys | Backend environment, or the Keychain if you choose to call the API directly | — |
| Backend auth token | Backend environment; entered by the user in the app's setup screen | — |

Non-secret configuration (chosen provider, model, endpoint override) is stored in
`UserDefaults` under `ai.jarvis.provider.settings`.

## 3. OAuth

Google uses authorization code + PKCE. The app can perform the flow itself; when a
backend is deployed it performs the exchange so the client secret stays on the
server. GitHub uses either a personal access token or the OAuth device flow, which
requires no client secret. Every flow requests the minimum scope needed for the
feature you enabled, and the app explains the scope before you grant it.

## 4. Tool authorization rules

1. Every tool declares `risk`, `requiredCapabilities`, `requiredPermissions`,
   `timeoutSeconds` and a `confirmationPolicy`.
2. `ToolExecutor` rejects unknown parameters, coerces and range-checks values,
   caps arrays, and refuses to run when a required capability or permission is not
   available.
3. Anything at or above the confirmation threshold — and every `communicating` or
   `irreversible` action, regardless of policy — asks the user. A 300-second
   timeout is treated as a decline, never as consent.
4. The run is written to `tool_runs` with redacted arguments, the outcome, the risk
   class, whether the user confirmed, and the duration. `verified` distinguishes an
   action the service confirmed from one the tool merely reported.
5. Failures are surfaced to the user *and* to the model, so a reply can never claim
   success that did not happen.

## 5. Privacy

* Memories, conversations, reminders and tool logs are stored only in the app's
  container on your device.
* When you send a message, the app transmits that message plus the memories it
  selected for it to the provider you configured. Nothing else leaves the device
  unless you enable an integration or deploy the optional backend.
* The microphone is active only while dictation is explicitly running; on-device
  recognition is requested where the device supports it.
* No analytics, no telemetry, no third-party SDKs.
* "Erase all local data" deletes memory, conversations, reminders, tool logs and
  every stored key from the device.

## 6. Repository hygiene

* `.gitignore` excludes `.env`, `*.ipa`, `*.mobileprovision`, `*.p12`, key files,
  the SwiftPM `.build` directory, Python caches, local databases and Xcode user
  state.
* `.env.example` documents every variable with placeholder values only.
* `scripts/validate_project.sh` scans for credential-shaped strings, refuses a
  tracked `.env`, and refuses tracked build artefacts. Two test fixtures contain
  synthetic key shapes in order to prove redaction works; they are listed in
  `.secretsignore` with the marker `synthetic-credential-fixture`, which the
  validator requires before honouring an exclusion.
* CI never receives secrets: the workflows use no `secrets.` context at all, which
  is itself asserted by the repository validator.

## 7. Reporting a problem

There is no security contact for a project you run yourself. If you find an issue,
record it in `agent-memory/KNOWN_ISSUES.md` with reproduction steps, and add a
failing test that demonstrates it before fixing it.

## 8. Known limitations (stated, not hidden)

* `HashingEmbedder` provides lexical similarity only; it is not semantic search.
* Keychain protection is `AfterFirstUnlockThisDeviceOnly`: strong, but a device
  that is unlocked once after boot has the key material available to the app.
* The backend's at-rest encryption for stored refresh tokens is keystream
  encryption keyed by the server token. It protects against a leaked database file;
  it is not a substitute for platform disk encryption.
* Enterprise/MDM environments can inspect app containers; JARVIS cannot defend
  against a compromised device.
