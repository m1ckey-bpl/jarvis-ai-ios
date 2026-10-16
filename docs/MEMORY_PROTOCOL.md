# Memory Protocol

Two memories exist in this project, and they have different rules.

* **Runtime memory** — what the assistant remembers about you, stored on your device.
* **Engineering memory** — `agent-memory/*.md`, what an engineer (human or agent)
  must read at the start of a session and update at the end.

## Part A — Runtime memory

### A1. Record shape

| Field | Purpose |
|---|---|
| `id`, `createdAt`, `updatedAt`, `lastAccessedAt`, `accessCount` | identity and freshness |
| `kind` | `fact`, `preference`, `goal`, `importantDate`, `decision`, `task`, `instruction`, `inference`, `correction`, `summary` |
| `text` | the record, in one sentence, in the user's own phrasing where possible |
| `subject`, `tags` | light structure for filtering |
| `source` | `user`, `assistant`, `importedExternal`, `system` |
| `confidence`, `importance` | ranking inputs, 0…1 |
| `expiresAt`, `status`, `supersededBy` | retention and the correction chain |
| `locked`, `provenance` | instruction pinning and where the record came from |

### A2. What is worth storing

Store: stable facts, working preferences, explicit instructions, goals, decisions,
important dates, and corrections. Do **not** store: questions, hypotheticals,
third-party statements ("my colleague thinks…"), one-off logistics that belong in
a reminder, or anything the user asked to keep out.

`MemoryExtractor` applies these rules with per-kind confidence ceilings
(instruction 0.95, fact/decision 0.88, date 0.85, preference 0.82, goal 0.75) and
refuses the excluded categories outright. Never invent a memory: a record must come
from something the user actually said or an explicit tool call.

### A3. Kinds and precedence

`instruction` outranks everything and is pinned into the context window whether or
not it matches the query. `correction` supersedes the record it replaces (the
original is kept with `status = superseded` so the change is auditable).
`inference` carries the lowest weight and is never allowed to contradict an
instruction or a correction.

### A4. Retrieval

Score = `0.42 × keyword + 0.16 × recency + 0.14 × kindWeight + 0.10 × confidence +
0.10 × importance + 0.04 × accessFrequency + (0.04 × semantic)`, with a 30-day
recency half-life, a 0.12 minimum score, a 0.9 penalty for untrusted sources, and
pinned instructions always considered. Keyword matching uses normalised tokens with
stop-word removal; the bundled `HashingEmbedder` is lexical only and labelled as
such, so semantic scoring contributes only when a richer embedder is configured.

Retrieval failure is disclosed: if the store throws, the assistant still answers,
but the UI shows that memory could not be read for that turn.

### A5. Natural-language commands

`remember …`, `what do you remember`, `recall … about <subject>`, `what did I say
about <date>`, `that's wrong … / correct …`, `forget …`, `export my memory`.
These are handled locally by `LocalIntentRouter`, appear in the transcript as
system rows, and never require a provider. Destructive commands ("forget
everything") ask for confirmation first.

### A6. Memory and prompt injection

Content from Gmail, the web, files or any other external source is wrapped by
`PromptInjectionGuard` in `<<<UNTRUSTED_EXTERNAL_CONTENT source="…">>>` markers with
a SECURITY NOTICE, stored with `source = importedExternal` when it becomes a
record, and penalised in retrieval. Untrusted text cannot create an instruction,
authorize a tool, or request a secret — and the system prompt says so explicitly.

### A7. Retention, correction, export

Summaries expire after 30 days by default; explicit TTLs are honoured; everything
else persists until the user removes it. Corrections keep history. Export supports
JSON, Markdown and CSV, and the Memory Center can erase every record (or all local
data) in one action.

## Part B — Engineering memory

`agent-memory/` is the contract for anyone continuing this work:

| File | Rule |
|---|---|
| `PROJECT_CONSTITUTION.md` | Read first, never silently modified; requirements R1–R16 |
| `CURRENT_STATE.md` | Read at session start; rewritten at session end ("what is being worked on right now") |
| `DECISIONS.md` | Append-only decision log (D1…); supersede, never delete |
| `TASK_BACKLOG.md` | Milestones and remaining work, with status |
| `KNOWN_ISSUES.md` | Honest list of limitations and open risks |
| `SESSION_HANDOFF.md` | Exact next steps for the following session |

Workflow: **read all six at the start, update all six at the end, and never claim
work that was not done.** When an instruction conflicts with the constitution, the
resolution order in the constitution applies and the conflict is recorded.
