# Test Report

**Run date:** 2026-10-16 · **Environment:** Linux (Debian 13), 2 vCPU / 1.9 GB,
Swift 6.0.3, Python 3.13. **No macOS, no Xcode, no network access during tests.**

Every number below was produced by a command in this repository. Nothing is
estimated. Tests are labelled **mocked** (no external service involved) or **live**
(a real remote service was contacted) — in this environment every test is mocked,
because no credential and no network are available, and that is stated rather than
glossed over.

## 1. Swift engine suite — 107 tests, 0 failures

```
cd ios && swift build --build-tests && swift test --skip-build
→ Executed 107 tests, with 0 failures (0 unexpected) in 1.306 (1.306) seconds
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
| Generated Xcode project | structural analysis of `project.pbxproj` | 162 objects, 21 groups, 63 Swift sources referenced by the app target (24 app + 39 engine), 0 undefined object ids, balanced braces and parentheses |
| Project freshness | `python3 scripts/generate_xcode_project.py --check` | up to date |
| Repository validation | `./scripts/validate_project.sh` | **81 checks, 0 failures** |
| IPA verifier accepts a valid unsigned IPA | synthetic well-formed bundle | exit 0, "structurally valid and unsigned" |
| IPA verifier rejects a broken IPA | synthetic malformed bundle | exit 1 with 8 named failures |
| Artwork generation | `python3 scripts/generate_app_icon.py` | icon-1024 (opaque), icon-180, hero-1200×630, lockup-512 + app catalog icon; pixel values sampled |

## 4. Not covered by automated tests (and why)

| Area | Why | How it will be covered |
|---|---|---|
| SwiftUI compilation and view behaviour | No macOS/Xcode in this environment | First `xcodebuild` run; then the manual checklist in `DEFINITION_OF_DONE.md` §3 |
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
