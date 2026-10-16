# Integrations

Every integration uses a documented provider API or an Apple framework. Where no
official API exists for an action, JARVIS says so and offers the closest legitimate
alternative. Nothing here is simulated.

## 1. Summary

| Integration | Channel | What JARVIS can do | What it explicitly cannot do |
|---|---|---|---|
| GitHub | REST API v3 (+ OAuth device flow) | List repositories and issues, read files, create issues, create a branch, commit a document, open a pull request | Merge, force-push, rewrite history, run your build |
| Gmail | Google Gmail API (OAuth 2.0 + PKCE, `gmail.readonly`, `gmail.send`) | Search, read, create drafts, send with confirmation | Read without consent, or bypass Google's own security controls |
| Instagram | Meta Graph API v21.0 | Read a professional account's profile | Read or send DMs, automate personal accounts, scrape |
| WhatsApp | Official compose deep links on device; WhatsApp Business Platform (Cloud API) on the server | Compose a message for you to send; template/service sends from a Business number | Read your personal chats, send from a personal number automatically |
| Apple Calendar & Reminders | EventKit | Read upcoming events, create events you ask for | Touch your data without permission |
| Notifications | UserNotifications | Local, time-zone aware reminders, one-off and recurring | Assume background execution |
| Music | System media frameworks | Report and control playback where the OS allows | — |
| Web search | Your own search API key (e.g. Brave) | Search and summarise results, with results marked untrusted | Scrape search engines |
| Companion backend | Your own deployment | Server-side OAuth exchange, privileged keys, scheduled dispatch, audit trail | Anything the app can already do on-device |

## 2. GitHub

* **Auth:** personal access token (`repo`, `read:user`) stored in the Keychain, or
  the OAuth device flow, which needs no client secret.
* **Reads:** `GET /user/repos`, `GET /repos/{owner}/{repo}/issues`,
  `GET /repos/{owner}/{repo}/contents/{path}`, `GET /repos/{owner}/{repo}/git/ref/heads/{branch}`.
* **Writes (each individually confirmed):** create issue, create branch from a head SHA,
  commit a file with `PUT /repos/{owner}/{repo}/contents/{path}`, open a pull request.
* **Coding agent flow:** draft a plan from your instruction → create a branch
  (reused, never force-updated, if it exists) → commit `docs/jarvis-agent/plan-<timestamp>.md`
  → open a pull request against the default branch. Every step is reported; a
  failure stops the sequence and is shown with the provider's own message.

## 3. Gmail

Requested scopes are the minimum needed for the features you enable. The app can
perform the OAuth exchange itself, but a deployed backend is the recommended path
because it keeps the client secret off the device. Tokens are refreshed on demand;
a failed refresh produces an actionable message ("reconnect the account") instead of
a silent failure. Sending is `irreversible` risk and therefore always confirmed.

## 4. Instagram

The Graph API exposes professional accounts only. JARVIS offers profile reads and
explains, in the UI and in this document, that direct-message access and
personal-account automation are not available through official channels. It does
not offer a workaround.

## 5. WhatsApp

Two legitimate paths, both official:

1. **On device:** a `whatsapp://send?phone=…&text=…` (or `wa.me`) deep link opens
   WhatsApp with your message composed. JARVIS reports `sent = false`, because it
   cannot know whether you sent it — it never claims otherwise.
2. **On a server:** the WhatsApp Business Platform (Cloud API) with your own
   Business number, phone-number id and token. Sending is `irreversible` and always
   confirmed. Only template/service conversations permitted by Meta are possible.

Reading personal chats is not offered by any path, because no official API
provides it.

## 6. Apple Calendar and Reminders

EventKit, on device, with just-in-time permission requests. Calendar reads power
schedule questions; event creation is `modifying` risk and confirmed. JARVIS keeps
its own reminders in its own store and does not edit your Apple Reminders without
an explicit request.

## 7. Web search and web fetch

Search runs through your own free search key. Results are wrapped as
`UNTRUSTED_EXTERNAL_CONTENT` before they can reach the model, and `web.fetch`
refuses loopback, link-local and cloud-metadata addresses so a URL cannot be used
to probe your own network.

## 8. Adding an integration

1. Implement the client in `ios/JarvisCore/Sources/JarvisCore/Integrations/`
   using `IntegrationHTTP` (or the app layer's `Support/` if it needs a platform
   framework).
2. Register a tool in `Tools/IntegrationTools.swift` with the correct `RiskClass`,
   `requiredCapabilities` and `confirmationPolicy`.
3. Register a capability in `AppEnvironment.registerCapabilities()` with an honest
   starting state, and refresh it in `refreshCapabilities()`.
4. Add tests under `ios/JarvisTests/` using `MockTransport` — never a live call.
5. Document it here, including what it cannot do. State the limitation in the UI
   too: the Services screen shows the same wording.
