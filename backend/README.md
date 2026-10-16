# JARVIS companion backend

**Optional.** The iOS app is fully functional on its own: memory, reminders, tools,
voice and provider calls all run on the device. This backend exists only for the
things a phone cannot or should not do:

| Capability | Why it needs a server |
|---|---|
| Google OAuth code exchange | Keeps the OAuth **client secret** off the device (PKCE is used on-device too) |
| Server-held privileged keys (WhatsApp Business, Instagram Graph, web search) | Secrets never ship inside an IPA |
| Scheduled dispatch when the phone is asleep | Background execution on iOS is not guaranteed |
| Multi-device memory sync (opt-in) | When you want two devices to share one memory store |
| Audit trail of tool runs | Tamper-resistant record of what was executed |

Everything here is **zero-cost**: pure Python standard library, SQLite for storage,
no paid service, no cloud dependency. It runs on any free-tier host or on your own
machine.

## Run it

```bash
cd backend
cp ../.env.example .env          # edit values; never commit .env
JARVIS_BACKEND_TOKEN="$(python3 -c 'import secrets;print(secrets.token_urlsafe(32))')" \
  python3 -m app.main --host 127.0.0.1 --port 8787
```

Safety default: without `JARVIS_BACKEND_TOKEN` the server binds to loopback only and
**all** authenticated routes return `503 backend_misconfigured`. It never starts
insecurely because a variable was forgotten.

## Test it

```bash
cd backend
python3 -m pytest -q          # no network access required; providers are stubbed
```

## Endpoints

| Method | Path | Auth | Purpose |
|---|---|---|---|
| GET | `/health` | none | Liveness + which optional features are configured (no secrets) |
| GET | `/v1/memory` | bearer | List / search memory records |
| POST | `/v1/memory` | bearer | Create a memory record |
| DELETE | `/v1/memory/{id}` | bearer | Forget a record |
| GET | `/v1/memory/export` | bearer | Export all records (json/csv/markdown) |
| POST | `/v1/chat` | bearer | Provider-proxied completion; the server may hold the provider key |
| GET | `/v1/tools` | bearer | Tool catalogue with risk class and required scope |
| POST | `/v1/tools/{name}` | bearer | Execute a tool **after server-side authorization** |
| GET | `/v1/reminders/due` | bearer | Reminders due since a timestamp, with retry/backoff state |
| POST | `/v1/reminders` | bearer | Schedule a server-side reminder (for dispatch when the phone sleeps) |
| GET | `/v1/integrations/oauth/google/start` | bearer | Begin Google OAuth (PKCE, state) |
| POST | `/v1/integrations/oauth/google/callback` | bearer | Exchange the code; stores refresh token server-side |
| POST | `/v1/integrations/whatsapp/send` | bearer | WhatsApp Business Cloud API send |
| GET | `/v1/integrations/instagram/profile` | bearer | Instagram Graph profile read (professional accounts) |
| POST | `/v1/integrations/search` | bearer | Web search through your own free search key |
| GET | `/v1/admin/audit` | bearer | Recent tool executions and auth failures |

The model never authorizes anything: `POST /v1/tools/{name}` re-checks the risk
class, the configured policy and the caller's scope on the server before acting.
