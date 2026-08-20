# Future work / known issues

Running notes for deferred work and known bugs. Not a spec.

## Future: surface interrupted turns after a daemon restart

### The problem

When an assistant turn is killed mid-flight by a daemon stop/crash (canonically:
the assistant runs `yuke service stop`, whose `yuke:exec` call SIGTERMs the very
daemon hosting the turn), the turn's streamed content is **discarded** and, on
reopen, the turn is **invisible** — the user sees their prompt with no answer and
no marker that anything was attempted.

Observed live in session `e689919b97545daa` (`~/.local/share/yuke/yuked.db`):
runs 9, 10, 11 each ended `run.done: failed / "the daemon stopped during this
run"` with **zero committed messages**; only run 12 (which did *not* stop the
daemon) survived. The user asked to stop the service three times; three assistant
turns vanished.

### Mechanism (verified against source)

Two record classes live in the `events` log:

- `message.committed` → **projected** into the `messages` table → this is the
  only thing any reopen path reads.
- `run.started` / `run.done` → **broadcasts**, live-only. Durably logged, but
  **nothing projects them** and no wire method returns them.

A turn is durable only once a round's `message.committed` lands. Streaming content
is never persisted as durable state.

- Shutdown discards in-flight turns: `runs_stop` (`src/daemon/session_run.odin:870`)
  cancels the provider op and `run_free`s the live run, which "announces nothing"
  and drops the round draft. The `open_run` marker stays set.
- On restart, `runs_recover` (`session_run.odin:824`) closes each open run with
  `Run_Outcome_Failed{code: .Internal, "the daemon stopped during this run"}` and
  clears the marker. It writes **no message**.

Neither reader surfaces the terminal:

- `session.history` (`store/queries/messages.sql`, `Session_History_Page`) is
  `SELECT … FROM messages JOIN events` — projection only.
- `session.resync` (`src/daemon/resync.odin:61`) builds its snapshot from
  `history_page` + live `session_activity`. Result fields: `item(summary,
  activity)`, `base_seq`, `highest_finalized_message_id`, `messages`, `has_more`,
  `configs`, `active`, `queued`. **None carry a run terminal.** After a restart
  `activity` is idle (the recovered run already terminated), so a fresh resync
  reproduces the same empty view. Comment at `resync.odin:113`: *"a run does not
  outlive the process that started it, so the log can say a run exists but never
  what it is producing."*

The **provider transcript** is the same projection: assembled from
`store.history_page` (`session_run.odin:142`, `:526`), committed messages only. So
the failed run is invisible to the **LLM** too — run 12's request carried four
consecutive `user` messages (23→26) with no assistant turn and no failure marker
between them.

### Is it a bug?

Not persistence corruption — the log is consistent and the failures are durably
recorded. It is a **UX/observability gap**: an interruption that is durably known
is never shown to the human or the model, so it reads as silent deletion.

### Harness landscape (2026 research)

Four strategies:

1. **Append-as-you-go file log — Claude Code, Codex CLI.** Every event (deltas,
   tool calls, results) flushed to JSONL as it happens; partial content of an
   interrupted turn survives on disk; resume reconstructs from transcript.
2. **Persist-partial, no recovery — opencode (closest sibling).** Writes the
   streaming message incrementally but has **zero startup recovery** → orphaned
   `tool_use` w/o `tool_result`, permanent "Thinking", and the orphan poisons the
   next request. Open bugs: opencode #19023, #21326, #16220, #33687.
3. **Persist-partial + synthetic closure — deepseek-harness (gold standard).**
   Durable append-only log keeps every event *including `assistant/chunk`*;
   "a crashed turn is closed, never truncated"; cold start **adds** synthetic
   error results + `turn/end { kind: 'interrupted' }` → transcript shows what
   succeeded, marks what didn't, stays valid/resumable.
4. **Atomic commit-at-round-boundary — yuke (us).** Durable only at
   `message.committed`; partial content never persisted; restart writes
   `run.done: failed` and clears the marker.

#### Where yuke stands

- **Safer than opencode.** We *have* startup recovery (`runs_recover`), so
  sessions never brick on a stuck spinner (opencode #19023). Atomic commit means a
  half-message is never written, so we're structurally immune to opencode's
  orphaned-`tool_use` / empty-content corruption class (#21326, #16220).
- **Behind deepseek on transparency.** deepseek keeps partial content and makes
  the interruption a first-class readable event. We discard the content and never
  surface the terminal we already record.

### Recommended direction

Two independent layers; do #1 regardless, decide #2 separately.

1. **Surface the interruption (low cost, high value — deepseek step 4→3).**
   The `run.done: failed / "daemon stopped during this run"` terminal is already
   durably logged. Project it into something `session.resync` / `session.history`
   returns — a synthetic "interrupted" placeholder anchored to the orphaned user
   prompt — analogous to deepseek's `turn/end { kind: 'interrupted' }`. This makes
   the loss visible to the human on reopen; optionally represent it to the model
   so it doesn't see back-to-back user turns.

2. **Preserve partial content (larger, optional).** Would require persisting
   streaming state before the round commits — the exact thing atomic-commit avoids
   to stay corruption-proof. Only worth it if losing seconds-from-committing turns
   matters in practice; weigh against reintroducing opencode's failure modes.

3. **(Optional) Guard the self-stop.** A turn stopping its own daemon can *never*
   persist its own output. Consider deferring `yuke service stop` until the round
   commits, or refusing the daemon-killing command mid-turn.

### Sources

- opencode: #19023 (no startup recovery), #21326 (orphaned tool_use), #16220
  (empty content bricks), #33687 (finish value)
- deepseek-harness session-persistence architecture note (durable log; crashed
  turn closed not truncated; synthetic `interrupted` closure)
- Claude Code "Manage sessions" docs; Codex CLI resume guide; Mastra "Anatomy of
  a coding agent" (conversation lives on the thread, not the process)

---

## UX: TUI auto-spawns the local daemon (hide the always-on requirement)

### The problem

The TUI is useless unless a daemon is already running: today the user must run
`yuke daemon` in the foreground or `yuke service install` (launchd / systemd
--user / Task Scheduler) and keep it alive. Every mainstream comparable
(opencode, codex, crush) instead **embeds the engine in-process by default** and
makes the persistent daemon opt-in; yuke is the only one that is daemon-first.
The friction is purely the *manual* lifecycle, not the architecture.

### Direction (keep the daemon; make it invisible)

On TUI startup: probe the local endpoint; if a daemon is already listening,
**connect to it** (shared — the multi-TUI and relay cases keep working); if
nothing is there, spawn `yuke daemon` (the same binary, existing subcommand) as
a detached child, poll until ready, then connect via the existing local
`Transport`. The client is already transport-agnostic (local WS + relay share
`client_open`), so this is an added connect path, not an engine change. ~200 LOC,
mostly lifecycle policy.

Design points that carry the weight (mechanism is easy):

- **Probe-first keeps one shared server.** Multiple TUIs must detect the running
  daemon and attach to it, not each spawn their own — a race loser treats
  `EADDRINUSE` (or a live UDS) as "someone won, just connect". This preserves the
  shared-session property; per-TUI engines only happen under a future
  embed-in-process mode, which deliberately trades sharing away.
- **Move local transport to a Unix domain socket.** yuke already has
  `front_door_unix.odin` / `front_door_windows.odin` stubs; codex and crush both
  use a UDS for local IPC. A UDS sidesteps the loopback-TCP port-bind race and is
  the field norm for local-only.
- **Version handshake.** A lingering daemon older than the TUI can wire-drift;
  mismatch on connect → client restarts the daemon (also cleans up upgrade churn).
- **Ownership / linger.** Auto-started daemon should linger by default (warm next
  launch, survives client crashes) with an explicit `yuke daemon stop`; reap
  orphans on version mismatch. Matches how awou is run.
- **Failure surfacing.** If the spawned daemon dies on boot (broken `yuked.js`,
  port taken), show *why*, not a bare "can't connect".

North-star (larger, separate): embed `daemon.start` on a second OS thread inside
the TUI process (opencode's model) with an in-process `Transport` backend — one
binary, one process, no orphan, no port, `yuke daemon` standalone + relay
unchanged for remote. Blocker: the daemon currently owns the process (it ticks
its own loop with `TICK_TIMEOUT` to catch POSIX signals because `nbio.wake_up` is
a cross-thread no-op); embedding means it runs on a caller-provided thread and
gives up signal ownership. Bounded, not a rewrite.

## Perf: `session.list` runs one usage query per row

`session_activity()` now reads `Last_Assistant_Usage` per session, so a `session.list`
page is `1 + N` queries (N = page size, default 50 / max 500) where it used to be 1. Each
is an indexed PK-descending scan settling on the first row — sub-ms at default size, so
likely premature to optimize. If it ever matters:

- **Denormalize** last-usage onto the `sessions` row (overwrite on assistant commit, same
  txn as `usage_total`); it then rides the existing `Session_Page` query at O(1). Cost
  moves to the rare truncation/compaction recompute. Cleanest, but a design shift —
  `context_usage` becomes durable session data rather than activity.
- **Fold** it into `Session_Page` as a correlated subquery — one round-trip, still N
  internal scans, always correct across truncation.
- **Drop** `context_usage` from list rows if the list view doesn't need a per-row gauge;
  keep it only on the single-session activity broadcast and resync (already 1 query each).

## Cost: request-side Anthropic prompt caching

yuke never sends `cache_control`, so every Anthropic turn pays full input price. The read
half is already done — `anthropic_prompt_usage` folds `cache_read`/`cache_write` into
`input`, so the gauge would report hits accurately if there were any. This is purely a
request-builder feature; no wire, schema, store, or `types.d.ts` change.

**Scope is Anthropic-only.** OpenAI and xAI cache automatically server-side (no
`cache_control` param; they report `prompt_tokens_details.cached_tokens`, which yuke already
reads). So only the `.Anthropic_Messages` path in `src/provider/anthropic_request.odin` is
in play.

**No auth edge cases.** Anthropic is always `Api_Key` (no Anthropic-OAuth arm, and we will
never add one — ToS). So the OAuth + `cache_control` HTTP 400 bug class other harnesses hit
cannot affect yuke; caching applies uniformly on the Anthropic path.

Two breakpoints give the value, well under Anthropic's max of 4:

- **Stable prefix (easy):** mark the system block. Requires switching the `system` field
  from a bare string to the block-array form
  `[{"type":"text","text":…,"cache_control":{"type":"ephemeral"}}]`. Tools ride along —
  they precede `system` in the hierarchy, so one system marker caches tools+system.
  `anthropic_write_tools` is untouched.
- **Moving tail (awkward):** mark the last content block of the last message so the growing
  conversation is incrementally cached (each turn: prior history reads at 0.1×, only the new
  delta writes). Hard because `Anthropic_Message_Writer` is a single-pass forward-only
  writer that emits each block's closing `}` immediately and never knows which block is last.

The tail difficulty is a design artifact, not a necessity: the request body is fully
buffered into a `strings.Builder` before send (`turn.odin` transmutes the whole string to
bytes), so the forward-only writer buys no runtime benefit here — unlike the response SSE
decoder, which must stream. Other harnesses (opencode, Vercel AI SDK, pi.dev) build a
materialized message array, mark indices (`blocks[last].cacheControl = …`), then serialize;
random access makes the tail trivial.

Implementation options:

- **Deferred-close** on the existing writer: hold back the most-recent block's `}`, flush it
  plain when the next block opens, and inject `cache_control` into the still-open last block
  at final close. Smallest diff, preserves every encoding test, no new type. Slightly hacky.
- **Rewrite to a block model** (`[]Provider_Message` of `[]Block`, then a dumb serializer):
  positional markers become random access and cache_control falls out for free; aligns with
  every other harness. The irreducible mapping complexity (role-coalescing, tool_use→
  tool_result reorder, empty-skip, `replay_thinking` gating) relocates into the build step
  rather than disappearing. Cost: one arena-allocated type + keeping the full
  `anthropic_request_test` suite green (the tests are the accepted/rejected-encoding spec).
  Consider extending to the two OpenAI request builders for a uniform serializer if they
  share the streaming pattern.

**Open gate before defaulting on:** does minimax (the compat endpoint) accept `cache_control`
blocks, or 400/ignore them? Real Anthropic is safe. Gate on catalog cache pricing
(`cost.cache_read`/`cache_write` from models.dev, already decoded) or an `api.anthropic.com`
allowlist; default off for compat until a live request confirms. Enablement lands as an
`Anthropic_Options.cache` field populated in `run_anthropic_options` (`run_request.odin`).

## API gap: no way to list the daemon's known workspaces

The daemon holds a canonical set of known workspaces (`{id, root, title}`), but a
connected client cannot enumerate it after the handshake.

- The `initialize` **result** carries `workspaces: []Workspace`
  (`src/wire/initialize.odin`) — the full known set, sent once at connect.
- The client **discards** it: `src/client/client.odin` retains only scalars from
  the initialize result (protocol version, index revisions, catalog hash, one
  string — see the comment at `client.odin:175`, *"the only retained string"*).
  The array is validated during decode, then dropped.
- No RPC re-fetches it. The workspace methods are `workspace.describe`,
  `.browse`, `.remove`, `.skills` (`src/wire/methods.odin`); `describe`/`browse`
  act on a path the caller already has, none **enumerate**. There is no
  `workspace.list`.

Consequence: a client feature that wants "all known directories" — e.g. a
zoxide-style directory jumper — has no first-class source. The only free proxy is
`session.list`, where each `Session` carries `workspace_path`; deriving the dir
set from sessions misses any known workspace with **no** sessions.

Fix, either of:

- **Retain + expose.** Keep `initialize.workspaces[]` in the `Client` (owned
  clone) and add a native getter (`client.workspaces()`) — cheapest, but the set
  is only as fresh as the last connect.
- **Add `workspace.list`.** A proper RPC returning the current known set — freshest
  and the right long-term surface; more work (wire method + daemon handler +
  `types.d.ts`). Pairs naturally with the deferred "TUI current path (cwd)" model,
  where the jumper wants live workspaces plus recents/frecency.

## Robustness: a deeply nested catalog feed overflows the stack

`catalog.decode` hands each selected provider subtree to `json.parse_value`
(`core:encoding/json`), whose parser is mutually recursive with no depth limit —
`parse_value → parse_object → parse_value`. One stack frame per nesting level against
~8 MB of stack (`ulimit -s`), so on the order of 80k nested brackets exhausts it. That
is ~80 KB of text, far under `FEED_MAX_BYTES` (8 MB), so the size cap is not the
mitigation it looks like. The failure is SIGSEGV, not a `Validation_Error`: the daemon
dies mid-instruction rather than returning `.Invalid_Json`.

Narrowed, not closed. The `json.validate_value` pre-pass over the whole document is
gone, so unselected providers now go through `skip_value` alone, which tracks depth in
an `int` and never recurses. Only selected subtrees still recurse.

Reachability is low today: the body arrives over TLS from models.dev, and
`catalog.refresh` is client-triggered — no startup fetch, no timer — so a hostile feed
cannot crash-loop the daemon. It needs models.dev itself to serve the payload.

Fix is ~20 lines: pre-scan the selected subtree's tokens for depth the way `skip_value`
already does and reject past a cap, then `parse_value` is safe because depth is proven.
Do it the day `MODELS_DEV_URL` stops being a constant — a mirror, a self-hosted feed, or
any configurable catalog source flips this from theoretical to real.

## Robustness: relay reconnect backoff is un-jittered (synchronized reconnect storms)

### The problem

`relay_schedule_reconnect` waits **exactly** `r.backoff` before re-dialing
(`src/daemon/relay.odin:617`), doubling it 1s → 2s → … → 30s (`RELAY_BACKOFF_MIN/MAX`,
`relay.odin:24-25`) and resetting to MIN on a successful park (`relay.odin:699`).
Deterministic, no randomization.

When many daemons drop at the *same instant* — a relay redeploy/restart, a network
partition, or (if `relay.yuke.sh` is ever fronted by a Cloudflare Tunnel) a cloudflared
restart — every daemon was parked, so every one carries `backoff == 1s`. They all wait
exactly 1s and re-dial in lockstep: a synchronized burst of link-ticket fetches against
the control plane (`platform.yuke.sh`) plus simultaneous relay dials. If that round fails
they re-sync at 2s, 4s, … 30s. Load arrives in spikes instead of spread across the
interval. Bounded (caps at 30s, self-limiting) so not fatal, but every correlated
mass-drop becomes a thundering herd on both yuke-cloud and the relay.

### Fix (~5 lines)

Randomize the actual sleep within the backoff window ("full jitter"): sleep a random value
in `[0, r.backoff]` while still doubling `r.backoff` for the growth/cap. Smears the herd
across the interval; the redeem spike becomes a stream. Growth/reset logic unchanged, only
the value handed to `nbio.timeout_poly` at `relay.odin:617`.

### Why it matters regardless of the tunnel

Relay redeploys already drop every parked link at once today, so the synchronized wave
exists now. Tunneling `relay.yuke.sh` would add cloudflared restarts as a second, more
frequent trigger — raising the priority — but jitter is correct on its own.
