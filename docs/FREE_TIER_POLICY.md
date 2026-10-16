# Free-Tier Policy

JARVIS is built to cost nothing to run. This document records what was verified,
when, and what could change — because free tiers are commercial offers and they do
move.

**Verification date: 2026-10-16.** Every number below was checked on that date
against the provider's own documentation. Treat every figure as *observed*, not
*guaranteed*: re-check before you rely on it, and see §5 for what to do when a
limit changes.

## 1. Zero-cost rules the code enforces

1. No API key ships in the app or the repository.
2. No billing is ever enabled, and no plan is ever upgraded, by any code path.
3. No payment method is requested, stored or referenced anywhere in this project.
4. When a free tier is exhausted, JARVIS reports the limit and stops. It never
   falls back to a paid model.
5. Provider entries carry a `hasFreeTier` flag and a human note, and the catalogue
   records the date its terms were last verified (`ProviderCatalog.verificationDate`).

## 2. Inference providers (no credit card required)

| Provider | Default model | Free limits (2026-10-16) | Notes |
|---|---|---|---|
| **Groq** (primary) | `openai/gpt-oss-120b` | ~30 requests/min, 1,000 requests/day, 8,000 tokens/min, 200,000 tokens/day per model | OpenAI-compatible at `https://api.groq.com/openai/v1`. Card not required. Groq removed the Llama models from its free plan in August 2026 — do not use the legacy `llama-3.3-70b-versatile` ids. |
| **Google AI Studio / Gemini** (secondary) | `gemini-2.5-flash` | Flash and Flash-Lite families are free with per-project limits published inside AI Studio | Card not required. **Data caveat:** on the free tier, prompts may be used to improve Google products outside the EEA/UK; do not send anything you would not share. Pro models are not free. |
| **OpenRouter** (tertiary) | `openrouter/auto` | `:free` models: ~20 requests/min, 50 requests/day without credit; failed calls still count | Only the `:free` roster is zero-cost, and it rotates. The 1,000/day tier requires a one-time $10 credit purchase, which this project excludes. |
| **Ollama / LM Studio** (local) | `llama3.2` (example) | Unlimited, because it runs on your own hardware | No key, no quota, no internet. A phone cannot reach your computer's `localhost`: point the endpoint at your LAN address or a tunnel. |
| **Custom OpenAI-compatible** | your choice | whatever you have | Any endpoint that speaks `/chat/completions`. |

Failover is deliberate rather than automatic: configure one provider, and if it is
rate-limited, JARVIS tells you and you switch in Settings. It never silently spends
someone else's quota.

## 3. Search, integrations and hosting

| Service | Free position (2026-10-16) | What JARVIS does |
|---|---|---|
| Brave Search API | Free tier with a monthly query allowance, key required | Used only if you add a key; otherwise `web.search` reports `requiresConfiguration` |
| GitHub REST API | Free for personal use with a token (5,000 requests/hour authenticated) | Repositories, issues, files, plan commits, pull requests |
| Google Gmail API | Free within Google's quota model; a Google Cloud project is free | Read/draft/send with your consent; a backend keeps the client secret off the device |
| Instagram Graph API | Free for professional accounts | Profile reads only; no personal-account automation |
| WhatsApp | Business Platform has a free conversation allowance for user-initiated service conversations; the API itself is free to use | Device-side compose via official deep links; server-side sends only through the Business Platform |
| Apple Calendar / Reminders | EventKit, on device, free | No service, no quota |
| GitHub Actions | **Public repositories**: unlimited standard minutes including macOS for the free plan as of this date. Private repositories: 2,000 Linux minutes/month; macOS minutes are consumed at a 10× multiplier and will exhaust the allowance quickly. | The iOS workflow in this repo targets public-repo, macOS-runner builds — verify your own plan before relying on it |
| Backend hosting | Many providers offer a free web-service tier (often with cold starts and monthly hour caps) | The backend is stdlib-only Python, so it runs on the smallest free tier or on your own machine. No database service is required: storage is a SQLite file. |

## 4. Where the cost could creep in (and how this project avoids it)

| Risk | Avoidance |
|---|---|
| A free tier being withdrawn | The catalogue is data, not code: edit `ProviderCatalog.entries`, or use any OpenAI-compatible endpoint |
| A provider starting to charge for overage | JARVIS has no billing integration at all, so overage cannot be incurred silently; the request fails and you see why |
| A free tier requiring a card | Only card-free options are listed as defaults; anything requiring a card is explicitly excluded |
| CI minutes | Workflows are short, cached where useful, and limited to what the free tier permits; macOS jobs only run for the iOS workflow |
| A "free" host hibernating | The app never depends on a backend; server-dependent features report `requiresBackend` until it answers |

## 5. If a free tier stops being free

1. The provider's entry in `ProviderCatalog` is where your choice lives — change
   the model or the provider in Settings with no code change.
2. `docs/INTEGRATIONS.md` lists the alternatives for each integration.
3. Record the change in `agent-memory/DECISIONS.md`, including the date you
   verified it, so the next person does not repeat the check.
