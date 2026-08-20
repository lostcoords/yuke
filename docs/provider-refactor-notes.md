# Provider / SSE / tiers / memory — design notes

Running design notes, not a plan or a spec. Captures the direction discussed plus
research into how other harnesses (opencode, codex, crush, aider, litellm,
OpenRouter) handle the same problems. Each section marks **Keep** (already good),
**Change**, **Add**, and **Open** (undecided) so the eventual work is scoped, not
prescribed.

Scope: (1) provider request-builder + JSON refactor, (2) SSE decode refactor,
(3) a one-shot `complete` primitive + `llm.complete` JS API + auto-titles,
(4) model tiers (large/medium/small) with fallback lists, (5) DB schema review +
sessions-as-memory + a `yuke db query` CLI.

---

## 1. Provider request-builder + JSON refactor (enables Anthropic moving-tail cache)

### What we have
- Two JSON interfaces in `libs/json`: the structured `Emitter` (used by
  `src/wire`) and a low-level streaming writer (`write_raw`/`write_string`/…)
  used by the three provider request builders.
- The three builders — `anthropic_request.odin` (613), `openai_chat_request.odin`
  (703), `openai_responses_request.odin` (450) = **1,766 LOC** — each walk
  `request.messages` and emit provider JSON via **single-pass forward-only**
  literal fragments (`write_raw(",\"system\":")`), duplicating the mapping logic
  (role-coalesce, tool_use→tool_result reorder, empty-skip, `replay_thinking`
  gating) per provider.
- The system prompt is a bare JSON string (`anthropic_request.odin:116`); no
  `cache_control` anywhere. Every Anthropic turn re-pays full input price (the
  read-side cache accounting is already wired, so hits *would* show in the gauge).

### The key observation
The request body is **fully buffered** into a `strings.Builder` before send, so
the forward-only writer buys **no runtime benefit** (unlike the response SSE
decoder, which must stream). Forward-only is a premature optimization that both
inflates LOC and structurally blocks tail-caching: to mark "the last content
block of the last message" with `cache_control` you must know which block is last
*before* closing it, which a forward-only writer cannot.

### Change / Add — materialize a block IR
Rewrite the builders around a normalized **block IR** (`[]Message` of `[]Block`:
text / thinking / redacted / tool_use / tool_result / image), built once from
`wire.Message`, then a thin per-provider serializer.
- **Shared (the LOC win):** the `wire.Message → IR` pass (role-coalesce,
  tool reorder, empty-skip, thinking-replay gating) — one copy instead of three.
- **Stays per-provider (relocated, not deleted):** the serializer, because the
  dialects genuinely differ (Anthropic content-blocks vs OpenAI-chat
  `messages`+`tool_calls` vs Responses `items`). Net effect: one shared IR-builder
  + three *small* serializers, meaningfully fewer than 1,766 LOC, and every
  serializer gets random access. **Do not oversell a 3→1 collapse** — the mapping
  complexity relocates into the IR + serializer, it does not vanish.
- **Arena:** the IR lives in the **scratch arena**, bulk-freed by watermark
  rewind — no per-block free, no new arena type. It lets us *delete* the
  forward-writer bookkeeping (`message_count`/`block_count`/manual separators).
- **Free side-benefit:** a materialized IR makes image/multimedia blocks trivial
  (`anthropic_write_image_block` + `Media_Source` are already half-built at
  `anthropic_request.odin:522`), de-risking the planned multimedia work.

### Anthropic prompt caching, the two breakpoints
- **Stable prefix (easy — do first, even before the rewrite):** switch `system`
  from a bare string to block-array form with `cache_control:{type:ephemeral}`.
  Tools precede `system` in Anthropic's hierarchy, so **one marker caches
  tools+system**. ~3 lines + updating `anthropic_request_test` encoding expects.
- **Moving tail (the reason for the block IR):** mark the last content block of the
  last message so growing history caches incrementally (prior reads at 0.1×, only
  the delta writes). Trivial once the IR exists (`blocks[last].cache_control = …`).
  Prefer the block-IR over the deferred-close hack.
- **Open gate:** does the `minimax` compat endpoint accept `cache_control` blocks
  or 400/ignore? Real `api.anthropic.com` is safe. Gate enablement on catalog
  cache pricing or an `api.anthropic.com` allowlist; default off for compat. No
  auth edge cases — Anthropic is always `Api_Key` (see [[no-anthropic-oauth]]).

---

## 2. SSE decode refactor

### What we have (Keep — it matches the field)
- **Two-layer split:** generic line-framing (`libs/http/sse`, 253 LOC —
  `data:`/CRLF/BOM/1 MiB caps, emits raw `data` strings) + a per-turn
  `Provider_Decoder` union with one arm per protocol
  (`src/provider/decoder.odin`) that turns one event's JSON into neutral
  `Stream_Event`s. This is exactly codex's (`eventsource-stream` → typed decode)
  and opencode's (`sseFraming` → per-protocol reducer) shape. **Do not merge the
  two layers.**
- **Neutral, block-oriented `Stream_Event`:** `Stream_Block_Started` →
  `Stream_Text_Delta`/`Stream_Reasoning_Delta` → `Stream_Block_Stopped{result}` →
  `Stream_Done{usage, stop_reason}`. This mirrors opencode's `LLMEvent`
  (`text/reasoning/tool-input` start/delta/end keyed by block id). codex keeps one
  enum *per provider* (less neutral) — we're on the better shape.
- **We already bound tool-call size** (`MAX_TOOL_CALLS` + arg caps). Both codex and
  opencode have **no** cap on accumulated tool-arg buffers — a real gap in each.
  Our CLAUDE.md "never assert on peer input, degrade with `Validation_Error`" rule
  is the right posture; keep and lean on it.

### Change — align tool-call + error handling with the research
1. **Keep streamed tool-call args as RAW bytes; parse only at block/stream close.**
   Universal across harnesses (opencode `tool-stream.ts`; codex relies on the
   server re-sending the whole item at `.done`). Today we assemble the call inside
   the decoder and emit whole at `Stream_Block_Stopped` — keep emitting whole, but
   the accumulator should hold raw text and defer the parse. Rule: **when a
   provider's terminal event carries the full args, the authoritative echo wins
   over accumulated deltas.** (This is the raw-string-tool-args direction from
   [[sse-json-rework]].)
2. **Graceful degradation on unknown/bad frames.** A malformed single SSE frame →
   skip and continue (never abort the stream); an unknown event `kind` → explicit
   no-op arm (forward-compatible with new server event types); only a
   `response.failed`-equivalent terminates via a typed error. codex does exactly
   this (`continue` on bad JSON, catch-all `trace!` on unknown kinds).
3. **Reasoning stays its own channel; provider peculiarities go in a metadata
   escape hatch, not the neutral union.** Anthropic thinking *signatures* (and
   any future provider extra) belong in a generic per-event metadata field rather
   than growing `Stream_Event`. Both codex (`ReasoningSummaryDelta` vs
   `ReasoningContentDelta`) and opencode (`reasoning-*` + `providerMetadata`)
   resist baking provider specifics into the shared shape.

### Add (when built) — `Tool_Output_Delta` + `Tool_State_Running.output` are ONE feature
Streaming tool output needs an accumulator; that accumulator is exactly what seeds
`Tool_State_Running.output` in `resync_build`. Ship the broadcast and the field
together or a reconnecting client goes blind mid-tool. (See `docs/future.md`.)

### Not a reference
crush vendors SDKs (`fantasy`/`openai-go`/`anthropic-sdk-go`) — no hand-rolled SSE
to study.

---

## 3. One-shot `complete` primitive + `llm.complete` JS API + auto-titles

### The real ask
Sessions have no AI title today (title is derived from the workspace path,
`session.odin:799`). The *primitive* we actually need is a general **"one prompt,
one answer" LLM call outside a session** — titles are just its first consumer, and
it is the hook a future auto-mode would stand on. opencode validates this exactly:
a built-in **hidden title agent** fires after the first user message using
`small_model` (default Haiku).

### What we reuse (most of it already exists)
- **The turn machinery is stateless per call.** `run_begin(service, connection,
  body, sink)` (`run.odin:100`) starts one turn against a resolved connection and
  has no session dependency.
- **`provider.Request` already fits a one-shot** (`system_prompt` + `messages` +
  optional tools + `max_output_tokens`). A one-shot is `{system, [one user
  message], no tools, small max_tokens}` → the **same request builder from §1** →
  body → `run_begin`. Doing §1 and this together is strictly cheaper.
- **Connection/credential resolution exists**: reuse `run_connection_build` /
  `run_credential_bind`.
- **The title broadcast exists**: replace the title source, re-announce via the
  existing `Session_Summary_Changed` (`session.odin:817`). No new broadcast.

### Add — four small pieces
1. **A `complete` unit** (sibling to `run`, **must not** call `session`): resolve
   connection → build minimal `Request` → `run_begin` with a sink that accumulates
   text and fires a callback on done. No session, no persistence, no pump
   broadcast. Reuses the turn arena discipline — **no new arena**.
2. **A wire method** `llm.complete` (deliberate protocol change): params
   `{tier | model, system?, prompt, max_tokens?, temperature?}`, result
   `{text, usage}`. Closed/bounded. Touches `src/wire` + tests + schema regen +
   ts-sdk regen (see [[wire-codec-handrolled-vs-reflection]] for the cost shape).
3. **JS host API on both tiers** — daemon (`yuke:daemon` or new `yuke:llm`) and
   client. QuickJS top-level await already drains host ops, so
   `await llm.complete({tier:"small", prompt})` is native (the host op settles a
   promise; the internal `complete` is a `Run_Op` + sink resolving it).
4. **Auto-title trigger**: on first `Message_Committed`, fire `complete` with the
   `small` tier + a "write a ≤N-word title" system prompt, set title, re-announce.

### Mechanism vs policy (recommendation)
Build `complete` + the wire method + the JS API as the **foundation**; ship
auto-title as a **built-in default that uses it** (works zero-config, like
opencode) while keeping the primitive public so users can build auto-mode in
`yuked.js` (model → decide → `session.send_input` → repeat). Don't hardcode
titling as the only consumer; don't require a user script for it either.

### Open — the one real implementation check
`Run_Service` holds **one shared `provider.Client`** (`run.odin:21`). A
title/utility call spins another `Run_Op`/`Turn` on that same client. **Confirm
the client permits a concurrent transfer** (a curl-multi should) so a background
title runs *alongside* live session turns instead of stalling a real answer. This
gates the whole async-utility design.

### Open — accounting & safety
- Utility-call tokens: probably **not** counted in session usage (it's meta) —
  decide and, if surfaced, track separately.
- `llm.complete` lets any authenticated client spend tokens against daemon-held
  credentials (the client gets *text*, never the key — consistent with our model).
  Bound `max_tokens`, keep params tight; it's gated by the same front-door auth as
  any method.

---

## 4. Model tiers (large / medium / small) with fallback lists

### Direction
Three **named tiers** — `large` / `medium` / `small` (~ Opus / Sonnet / Haiku),
added in `applyConfig()`. Each tier is a **fallback list**, not a single model:
`large: [anthropic-opus, minimax-m3]` so a session always works if the primary is
down. `complete`/titles default to `small`; future agents pick a tier by name.

### Research — this is well-supported, with one correction
- **Correction:** *Sol / Terra / Luna* are **OpenAI's GPT-5.6 model-family product
  names** (flagship/mid/budget), **not** a Codex-harness tier vocabulary — the
  codex repo has zero references. Codex's harness uses arbitrarily-named
  **profiles**. The tier idea is sound; the naming was a model family.
- **Three-role tiers are the norm:** aider `main`/`weak-model`(commit msgs,
  summaries)/`editor-model`; crush `large`/`small` (a 2-value enum); opencode
  `model`+`small_model` ("for tasks like title generation", default Haiku).
- **Fallback lists are the industry pattern** — litellm
  (`fallbacks=[{primary:[backups]}]`) and OpenRouter (`models:[...]` priority
  array). Not in opencode/crush/codex (each tier is a single fixed model), so this
  would put us **ahead** on resilience.

### Design lessons (adopt)
1. **Tier = alias → *ordered list*** (generalize opencode/crush's single-string
   tier to litellm's array). Resolve daemon-side against the catalog + credentials.
2. **Failover only on infra errors** (outage / rate-limit / invalid-key /
   context-overflow), never on content the model dislikes — try the list in order,
   surface the last error only when exhausted. This is what makes "always works"
   honest, and reuses our existing retry policy (`retry_backoff`,
   `error_retryable`).
3. **Agents/utility calls name an alias** (`large`/`medium`/`small`/`inherit`),
   never a raw model string — the single thing that makes multi-agent setup easy
   for non-power users (Claude Code + crush both do this).
4. **Ship a working default `small` fallback chain** so titles work zero-config.
5. **Keep the tier set closed at three**; reserve free-form profiles as an
   advanced escape hatch, not the primary UX (crush's fixed enum is what stayed
   simple; codex's open profiles need the user to already understand the concept).

### Placement
Tier→model resolution must be **daemon-side** (catalog + credentials live there),
so the wire carries a **tier enum** and the daemon resolves it. `applyConfig()` on
the client is where the user selects/displays the three lists; the daemon config
holds the authoritative mapping and **validates each entry against the catalog** at
apply time (a tier pointing at a non-catalog model fails loudly). This is the
config↔catalog tie. Default: fall back to the session model when a tier is unset.

### Why this helps "simple agents"
A smart agent → `large`; a research agent → `large`/`medium`; a thinking agent →
`small`. Naming a tier (not a model) plus a default fallback chain is what lets a
non-power user set up different agents trivially — subagents stop being a
power-user-only feature.

---

## 5. DB schema review + sessions-as-memory + `yuke db query` CLI

### What we have (Keep — it's excellent)
Proper **event-sourcing + projection**, TigerBeetle-grade and heavily SQLite-tuned
with documented rationale:
- `events(session_id, seq, name, payload TEXT-JSON)` is the **log of record**
  (rowid table; payload last to avoid overflow I/O on earlier columns).
- `messages` / `session_configs` / `session_prompts` are **projections
  rebuildable by replay** — scalars + a pointer back to `events.payload`; the
  message body is **not** in a queryable column (kept out of the WITHOUT ROWID
  projection deliberately).
- WITHOUT ROWID keyset pagination, all-DESC indexes incl. id tiebreak, partial
  indexes (`messages_by_model`, `sessions_by_parent/job`), id-minting marks read
  for recovery instead of `MAX(seq)` (a truncating rewind must not reclaim ids).

This is **exactly codex's pattern** (JSONL-of-record + reconstructible SQLite
index) and beats crush's single-JSON-blob-per-row and opencode's JSON-in-column
designs — every harness converges on "don't normalize message internals into
columns", validating our choice. **Do not replace the log + projection core.**

### The gap for "sessions as memory"
Message *bodies* live as JSON in `events.payload`, so metadata is queryable (role,
model, tokens, title) but **content is not** — no "find sessions where we
discussed X". None of the three harnesses ships working cross-session memory
today: crush has intra-session compaction only; opencode reads only the current
session; **codex built a memory-summary pipeline and then deleted it**
(`0006_memories.sql` → `0035_drop_memory_tables.sql`), keeping only `instr()`
substring search over cached `title`/`preview`.

### Add — content search as a separate FTS5 index (not a body column)
- **`messages_fts` external-content FTS5 virtual table**, keyed to the message
  (`session_id, seq` / event rowid), populated by **extracting text from the JSON
  payload at projection time** — the same write path that appends the event and
  updates the `messages` row. **Not a DB trigger** (the searchable text must be
  *extracted* from JSON, not copied verbatim) and **not a body column on
  `messages`** (keeps the projection small, as designed). `unicode61` tokenizer,
  `bm25()`/`snippet()` for ranking.
- **Skip embeddings/vector search for v1.** codex's deleted pipeline is the
  cautionary tale; FTS5 substring/BM25 + metadata filters (session/role/time)
  covers the recall use case codex settled on. Add `sqlite-vec` only if a concrete
  keyword-search failure shows up.

### Add — `yuke db query` CLI (read-only, for humans first)
- **Safe by construction, avoiding opencode's `sql.raw` footgun** (opencode's
  `opencode db [query]` runs arbitrary SQL unrestricted): open a **read-only**
  connection (`PRAGMA query_only=ON` or a separate read-only file handle), **reject
  non-`SELECT`** at the statement level, enforce a **hard row cap + query
  timeout**. WAL already allows a concurrent reader, so the CLI opens the same DB
  file **without touching the daemon reactor**.
- Keep it a **human CLI subcommand** first, not an agent-callable tool, until
  there's a concrete need (matches CLAUDE.md "gate the caller, not the data").
- **If** a memory tool is later exposed to agents, scope it to **search →
  locators** (`session_id, seq, snippet, score`), never raw payload dumps — the
  caller fetches the specific event by id. Mirrors the existing "don't materialize
  ignored broadcasts / no session-ids as array indices" discipline.

### Keep, explicitly
Bodies live **only** in `events.payload`; project only what's proven to need direct
column access. Every examined harness converges on this.

---

## Cross-cutting: the refactors overlap — do the linked ones together

- §1 (block IR) and §3 (`complete`) touch the **same request builder** — sequencing
  them separately duplicates work.
- §1 (block IR) also unblocks **multimedia** (§ image blocks) and the §2
  `Tool_Output_Delta` accumulator shares the raw-args discipline.
- §3 (`complete`) + §4 (tiers) are one feature surface: `complete` takes a tier,
  titles default to `small`.
- §4 (fallback) reuses the existing **retry policy** rather than new machinery.
- The whole set aligns with the stated goal of **fewer lines**: the block IR
  deletes forward-writer bookkeeping and de-duplicates three mapping passes; the
  `complete` primitive reuses turn/connection/broadcast machinery wholesale.

## Open questions to resolve before committing
1. Does `provider.Client` permit **concurrent transfers** (utility call alongside
   session turns)? Gates §3.
2. Does `minimax` accept Anthropic `cache_control`? Gates §1 default-on for compat.
3. Tier config home: daemon-config authoritative + client `applyConfig()` as the
   selector — confirm the sync/validation path.
4. Utility-call **usage accounting**: separate, or ignored?
5. FTS text extraction: which parts contribute (text + reasoning? tool results?)
   and how to bound very large payloads.
