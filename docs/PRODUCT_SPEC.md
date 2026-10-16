# JARVIS — Product Specification

> Status: implemented. This document describes the product as built, not an
> aspiration. Where something is deliberately out of scope, it says so.

## 1. What JARVIS is

JARVIS is a native iOS assistant that runs on the phone. It keeps a durable,
inspectable memory of what you tell it, schedules reminders that respect your time
zone, speaks and listens, and can act through tools — but only through official
provider APIs, and only with your consent for anything consequential.

Three commitments shape every decision in this repository:

1. **It does not pretend.** If a capability is not configured or not permitted,
   JARVIS says so, explains what to do about it, and stops. There are no fake
   connectors, no simulated successes and no invented data.
2. **It is zero-cost.** The app ships without any key, never enables billing and
   never silently falls back to a paid model.
3. **Your memory is yours.** Memories, conversations, reminders and tool logs live
   in the app's own container. Nothing is uploaded to a server operated by this
   project — there is no such server, except the optional one you deploy yourself.

## 2. People and jobs

| Person | Job to be done | What JARVIS provides |
|---|---|---|
| The owner (primary) | "Remember this for me and bring it back later." | Dual memory: durable records, ranked retrieval, natural-language memory commands, export and correction |
| The owner | "Remind me at the right time." | Time-zone aware local notifications, one-off and recurring, editable and cancellable |
| The owner | "Do a small task for me." | A tool engine with risk classes; anything consequential asks first |
| The owner | "Work on my project." | A coding agent that reads a repository, drafts a plan, and applies it on a branch as a pull request |
| A reviewer | "Is this real?" | Every claim in this repo maps to code, a test, or a documented manual step |

## 3. Required screens (all implemented)

| # | Screen | Implementation | Notes |
|---|---|---|---|
| 1 | Assistant Home | `Screens/AssistantHomeView.swift` | State-reactive orb (idle/listening/thinking/speaking/executing/awaiting confirmation/error), transcript, composer, status rail, confirmation card |
| 2 | Conversation History | `Screens/ConversationHistoryView.swift` | Session list, full-text search, per-session view, delete |
| 3 | Memory Center | `Screens/MemoryCenterView.swift` | Search, kind filters, correct / forget / export / erase-all |
| 4 | Reminders & Tasks | `Screens/TasksView.swift` | Natural-language creation, scope filters, edit, complete, cancel, permission banner |
| 5 | Connected Services | `Screens/ConnectedServicesView.swift` | Every integration with its honest state and what it can/cannot do |
| 6 | Tool Execution History | `Screens/ToolHistoryView.swift` | Per-run detail: arguments (redacted), result, risk, confirmation, duration |
| 7 | Project & Coding Agent | `Screens/ProjectAgentView.swift` | Repository picker, branch, plan drafting, run log, issue creation |
| 8 | Settings | `Screens/SettingsView.swift` | Navigation hub, erase-all-data, build/system info |
| 9 | API & Provider Config | `Screens/ProviderSettingsView.swift` | Provider catalogue, Keychain key entry, model/endpoint override, real connection test |
| 10 | Permission / Connection Setup | `Screens/PermissionSetupView.swift` | Just-in-time requests with per-permission state and an iOS Settings deep link |
| 11 | Error & Recovery | `Screens/RecoveryView.swift` | Real error, plain-language explanation, next steps, copyable diagnostics |

First-run onboarding (`Screens/OnboardingView.swift`) covers what works without
setup, what needs a free key, and the memory preference.

## 4. Assistant behaviour

* **Local-first routing.** Memory commands, the time, and reminders are answered by
  `LocalIntentRouter` with no network call at all. Only everything else goes to a
  provider.
* **Streaming.** Replies stream token by token; the user can cancel mid-turn and
  the turn is abandoned cleanly.
* **Voice.** Dictation starts only on an explicit tap, prefers on-device
  recognition, shows a live level derived from measured audio, and stops on tap.
  Spoken replies can be interrupted at any time.
* **States.** Every screen implements loading, empty, error and success states.
  Buttons that cannot work are disabled and explain why.

## 5. Memory (summary — see MEMORY_PROTOCOL.md)

Five kinds of record that matter (fact, preference, instruction, goal/decision,
date), each with timestamps, confidence, importance, provenance and retention.
Retrieval scores keyword relevance, recency, kind weight and confidence, with
semantic similarity where an embedder is available (`HashingEmbedder` is lexical
only and is labelled as such). Explicit instructions outrank anything inferred and
cannot be overridden by content from email, files or the web.

## 6. Reminders

Natural-language parsing ("in 20 minutes", "tomorrow at 9am", "every Sunday at
6pm", "24/12"), a one-time or recurring local notification per reminder, explicit
confirmation when a notification is actually scheduled, and a visible failure
message when it is not. JARVIS never assumes it can run in the background: the
optional backend exists for that, and the app says so.

## 7. Tools and confirmations

Twenty-four built-in tools plus integration tools, each declaring parameters,
risk class (`safe` < `modifying` < `communicating` < `irreversible`), required
capabilities, a timeout and a confirmation policy. The model may propose; the
engine validates arguments, checks capability and permission state, routes
confirmation to the user, executes with a timeout and writes a redacted audit row.
The backend repeats this authorization independently — a model cannot grant itself
permission in either place.

## 8. Integrations

Gmail (Google OAuth), Instagram (Graph API, professional accounts only), WhatsApp
(official compose deep links on device; Business Platform on the server), GitHub
(REST + device flow), Apple Calendar and Reminders (EventKit), music, and web
search through your own free search key. Where an official API does not exist for
an action, the app states that plainly instead of imitating it.

## 9. Non-goals

* No unofficial access to WhatsApp personal chats, no scraping of Instagram DMs.
* No payment features: JARVIS cannot spend money, and it will not be given the
  ability to do so.
* No background execution guarantees; no always-listening microphone.
* No cloud account, telemetry or analytics.
* No Android or web client in this repository.

## 10. Acceptance criteria

The project's Definition of Done — including which items are verified and which
require your own device or Apple credentials — is `docs/DEFINITION_OF_DONE.md`.
