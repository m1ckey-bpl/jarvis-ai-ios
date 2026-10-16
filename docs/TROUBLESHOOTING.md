# Troubleshooting

Every entry states the symptom, the cause, and the fix — including the cases where
the answer is "this is a deliberate limitation".

## The assistant says no provider is configured

*Cause:* JARVIS ships without a key by design. *Fix:* Settings ▸ AI Providers, pick
Groq or Google AI Studio, paste a free key into the Keychain field, save, then run
"Test connection". The greeting on the Assistant screen shows this state before you
even ask a question.

## "Test connection" fails

| Message | Meaning | Fix |
|---|---|---|
| `provider unauthorized` | The key was rejected | Re-paste it; check for a trailing space; confirm the key is for that provider |
| `quota reached` | The free tier is exhausted | Wait for the reset window, switch models, or switch provider in Settings |
| `provider bad response` | The model id or endpoint is wrong | Use the "Use default" button, or fix the endpoint override |
| `network` | No connectivity, DNS or TLS failure | Check the device's connection; a captive portal blocks TLS |
| `timeout` | The provider did not answer in time | Retry; a very long prompt can exceed the timeout |

## Voice input does nothing

Dictation requires microphone *and* speech-recognition permission, and refuses to
start without both. Check Settings ▸ Permissions: the row shows exactly which
permission is missing and offers a request button plus a deep link into iOS
Settings. If iOS has already recorded a denial, only you can change it.

## A reminder was saved but no notification arrives

The reminder row shows a "no notification" pill and the creation feedback says so
explicitly. Causes: notification permission denied, Focus mode or a Do Not Disturb
schedule, or the notification being scheduled but suppressed by the system. JARVIS
never reports a notification as scheduled unless the scheduler returned an
identifier. Reminders that need to fire while the phone is asleep require the
optional backend and a dispatch target you own.

## Reminders show the wrong time

Check the reminder's time-zone field in the edit sheet. Reminders store the zone
they were created in and fire with `TimeZone` awareness; if you travel, an existing
reminder keeps its original zone until you edit it.

## Memory returns nothing relevant

Retrieval needs lexical overlap for anything that is not pinned. Open the Memory
tab and search with a distinctive word from the record. If a record exists but is
never retrieved, its kind may be `inference` (lowest weight) — correct the record to
raise its standing, or restate it as an instruction.

## "I couldn't read your memory for this turn"

The local SQLite store failed. The assistant continues without memory rather than
guessing. Check free storage, then reinstall if it persists (export first: Memory ▸
export).

## The backend starts but authenticated routes return 503

`JARVIS_BACKEND_TOKEN` is not set. The server deliberately refuses authenticated
work until an operator sets one. Set it, restart, and use the same value in the
app's setup screen.

## The backend refuses to start on a public address

Expected: it requires `JARVIS_BACKEND_TOKEN`, plus either
`JARVIS_REQUIRE_HTTPS=1` or `JARVIS_TRUST_PROXY_TLS=1` to acknowledge that TLS is
terminated in front of the process. Set both deliberately rather than removing the
check.

## `swift test` hangs with no output

An orphaned `swift-test`/`.xctest`/`swift-build` process is holding the build lock.
`scripts/run_tests.sh` clears these before running; manually:
`pgrep -af 'swift|xctest'` then `kill -9 <pid>`.

## The Xcode project is out of date after adding files

Run `python3 scripts/generate_xcode_project.py`. The project is generated from the
file tree; never hand-edit `project.pbxproj`, and CI checks with `--check`.

## The iOS workflow fails on a private repository

macOS runner minutes are consumed at a 10× multiplier and a private repository's
2,000-minute allowance runs out quickly. Make the repository public for CI, or run
the build locally with Xcode. The engine test job alone needs no Xcode.

## The unsigned IPA will not install

Correct: an unsigned IPA is not installable as-is. Sign it with your own method
(Xcode, your own certificate and profile, or the sideloading tool you already use).
This project never installs certificates or generates profiles — by policy.

## Instagram will not read my direct messages

No official API exposes personal-account DMs. JARVIS does not use unofficial ones.
The same is true for reading WhatsApp personal chats.

## A tool ran but the result looks unverified

The tool log distinguishes *verified* (the service confirmed the action) from
*reported* (the tool reported its own outcome). Gmail/WhatsApp sends are verified;
a compose deep link cannot be, and it says `sent = false` for that reason.
