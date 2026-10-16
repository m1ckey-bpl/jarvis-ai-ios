# Getting the unsigned IPA — what you do, what I need, what I never need

This is the only part of PROJECT JARVIS that cannot be done from the machine the
rest of the project was built on: producing an `.ipa` requires macOS, and there is
no macOS here. Everything else — the build script, the verification, the workflow —
is already in the repository. What is left is a five-minute action on your side.

---

## 0. The short version

| # | You do this | Where | I need from you |
|---|---|---|---|
| 1 | Create a **public** repository named `jarvis-ai-ios` | github.com → *New repository* | nothing |
| 2 | Push the repository (two commands) | your terminal | nothing |
| 3 | Wait for the *iOS* workflow to finish | repository → **Actions** | the run's outcome: "green" or the **Compile errors** block |
| 4 | Download the artifact | run page → **Artifacts** → `JarvisApp-unsigned-ipa` | optionally: hand me the `.ipa` and I verify it (§5) |
| 5 | Sign it with your own method | your own tooling | nothing — I never ask for signing material |

That is the whole dependency. Steps 1–2 are yours because only you can publish to
your account; steps 3–5 are where I can act again.

---

## 1. Create the repository (public, empty)

**Why public:** free macOS runner minutes are granted only to public repositories.
A private repository puts you on a paid multiplier, which the zero-cost rule forbids.

1. Go to <https://github.com/new>.
2. **Repository name:** `jarvis-ai-ios` · **Visibility:** *Public*.
3. **Do not** add a README, `.gitignore` or licence — the repository must be empty,
   otherwise the first push is rejected as unrelated history.
4. Create it.

Or with the GitHub CLI, if you have it:

```bash
gh repo create jarvis-ai-ios --public --disable-wiki   # creates an empty public repo
```

---

## 2. Push the local repository

```bash
cd jarvis-ai-ios
git remote add origin https://github.com/<YOUR-USERNAME>/jarvis-ai-ios.git
git push -u origin main
```

There is nothing to configure: no certificate, no provisioning profile, no Apple ID,
no environment secret, no billing. The repository contains no credentials by design —
the validator fails the build if a workflow ever references one.

**If git asks for a password**, use a personal access token *for that one push*, or
push over SSH (`git remote set-url origin git@github.com:…`). A token for your own
`git push` never needs to be shown to me, and I will never ask for one.

---

## 3. Watch the workflow

Repository → **Actions** → the *iOS* run → two jobs:

| Job | What it does | Typical time |
|---|---|---|
| `tests` | `swift build --build-tests` + `swift test` on `macos-14` | ~2–4 min |
| `unsigned-ipa` | project freshness check → `build_unsigned_ipa.sh` → SHA-256 → structural verification → upload | ~5–10 min |

**If both jobs are green:** open the job's run page (or *Summary*), scroll to
**Artifacts**, download **`JarvisApp-unsigned-ipa`** (kept 90 days), unzip it, and you
have:

```
JarvisApp-1.0.0-unsigned.ipa      # the app bundle, unsigned, no signing material inside
JarvisApp-unsigned.sha256         # its SHA-256, as printed in the run summary
```

---

## 4. If it fails — this is the expected possibility

The first run is the first time the SwiftUI code is compiled *anywhere*. The engine
(107 tests) and backend (112 tests) are already green, but the app layer was only
syntax-checked here, so type errors are possible. When that happens, the workflow
prints exactly what I need to fix it:

1. Open the failed job → **Summary**.
2. Find the section **Compile errors** (or *Swift engine errors*) — up to 40 unique
   `error:` lines.
3. Copy that block into this conversation. Nothing else is needed — no log files, no
   screenshots, no build artifacts.
4. I fix the code, commit, and you run `git push` again. Repeat until the job is
   green. Two or three rounds is a realistic expectation, not a failure.

Full logs are also uploaded as **`ios-build-diagnostics`** (7 days) if you ever want
to send more than the summary block.

---

## 5. Want me to verify the artifact myself?

Attach the downloaded `.ipa` (or the artifact zip) to this conversation. The verifier
runs on Linux, so I will:

* confirm zip integrity and a single `Payload/JarvisApp.app` bundle;
* read back the bundle identifier (`ai.jarvis.assistant`), version, executable name;
* list the required resources and check the asset catalog compiled in;
* assert the **absence** of `_CodeSignature`, `embedded.mobileprovision` and
  leftover entitlements — i.e. that it really is unsigned;
* recompute the SHA-256 and compare it with the workflow summary.

`./scripts/verify_unsigned_ipa.sh dist/JarvisApp-1.1.0-unsigned.ipa` does the same
on your machine. (The version comes from the project file, so the name changes when the
version does — `1.1.0` is the build that fixes the provider-key bug and the covered
buttons reported from the first device install; `1.0.0` stays available on its own
release page if you ever want to compare.)

---

## 6. Optional: a download link that never expires

Artifacts are deleted after 90 days. For a permanent link:

```bash
git tag -a v1.1.0 -m "JARVIS 1.1.0 — provider activation fix, layout fix, animated face, spatial UI"
git push origin v1.1.0
```

A `v*` tag makes the workflow create a **GitHub Release** and attach the `.ipa` and
its checksum to it. The release page then holds the file indefinitely.

---

## 7. Then sign it yourself

This project never signs, and never asks you to configure signing. Sign the unsigned
IPA with whatever method you already use (Xcode automatic signing, a self-managed
certificate and profile, or your sideloading tool) and install it. `docs/BUILD_GUIDE.md`
§"Signing is yours" spells out what the repository deliberately does not do.

---

## 8. What I will never need from you

Listed explicitly, because the fastest way to lose a private key is to hand it to a
tool that did not need it:

| Never needed | Why |
|---|---|
| Apple ID, password, 2FA codes | unsigned builds require no account of any kind |
| Signing certificate, `.p12`, provisioning profile, UDID | explicitly out of scope — you sign afterwards |
| Payment details, subscription, paid account | the zero-cost rule is absolute |
| Your inference API key (Groq/Google/OpenRouter) | it goes into the app's Settings screen on your device, into Keychain; never into this chat, the repo, a log or the IPA |
| A GitHub personal access token | only your own `git push` needs it, and I am not part of that path |
| A backend host, domain or DNS record | the backend is optional and self-hosted by choice |

The only credentials the project ever expects are the ones **you** type into the app
at runtime, stored in the iOS Keychain, never in the build.

---

## 9. Zero-cost checklist before you push

* [ ] Repository is **public**.
* [ ] Do not enable larger runners or any paid add-on (*Settings → Actions → Runners*
      stays on the free `macos-14` label the workflow requests).
* [ ] No repository secrets are added — none are needed, and the validator fails if a
      workflow ever references one.
* [ ] Optional: *Settings → Actions → General → Workflow permissions* can stay at the
      default *read*; the workflow requests `contents: write` only inside the tag job,
      for the Release attachment.
