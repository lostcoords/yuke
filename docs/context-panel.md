# yuke — the `/context` breakdown

Status: plan, not built.
Source of truth: `src/engine/request.zig`, `src/engine/context.zig`, `src/js/app/context.js`.
Last verified: 2026-09-10.

`/context` states one real number and four vague ones. The window shows the input total of the last
turn, and it explains none of it. This plan splits that total into five parts and draws the shares.

## The problem the plan solves

A provider reports one input count for a request. It never reports a split. `context.tokensFor`
estimates a token count from a byte count at `bytes / 3`, and its own comment says the estimate does
not replace a provider tokenizer. So the five parts are estimates and the total is a fact.

Two ways to show that. Raw estimates never sum to the real total, and a user who adds the rows sees
the window disagree with itself. Normalized shares always sum to the total, and each part carries the
accuracy of the estimator. This plan normalizes.

## The five parts

The request holds these blocks, in this order:

1. `system` — the system prompt, the environment block, the project instructions, the skill catalog.
2. `tools` — the tool declarations, as the serializer writes them.
3. `summary` — the newest compaction message, which stands for every message it covers.
4. `messages` — user text, assistant text, and reasoning parts.
5. `tool_results` — tool call arguments and their results.

A sixth row states what is left: `available` is the context window less the input total. That row is
exact, because both values are facts.

The reference design names four parts and folds a compaction summary into the messages. yuke states
it apart. After a compaction the summary is often the largest single block, and a user opens this
window to learn where the history went. Reasoning parts stay inside `messages`, because they belong
to one turn and never dominate.

## Where the split is measured

`src/engine/request.zig:prepare` holds `build.system`, `build.tools`, and `request_ir.blocks` at the
moment it serializes the request. It measures the split there and nowhere else.

The alternative is to measure when the window opens. That reads a projection the request never sent:
a compaction, an edited `AGENTS.md`, or a changed tool set all move it. The window would then show a
real total from one request beside a split from another. The plan refuses that.

## How the split travels

The split describes the request that produced one assistant message, exactly as `tokens` does. It
rides the same path.

- `lib/proto/message.zig` gains `ContextSplit` with five `u64` byte counts, and `Assistant` gains
  `context: ?ContextSplit = null`. The event payload carries it with no further work, because an
  event stores the whole message as JSON.
- `zig build gen-schema` regenerates `schema/proto.json` and `src/js/app/generated/proto.d.ts`.
- Migration `0005` adds five columns to `messages`, beside `tokens_input`. The read model needs them,
  because `session_context` answers the window from the newest assistant row.
- `session_context` exposes them as `ctx_context_*`, next to `ctx_tokens_*`.
- `src/store/message.zig` writes them from `a.context`, exactly as line 119 writes `tokens`.
- The `RunSlot` carries the split from `prepare` to the commit, as it already carries `protocol`.

## What the panel does

`src/js/app/context.js` reads the five byte counts and the input total.

- Each part takes its share of the total bytes, and that share scales to the real input count.
- `available` subtracts the input total from the context window.
- The grid draws one cell per share of the window, in part order, so the eye reads the proportion.
- A row states the part, its token count, and its share.

The window keeps the twelve-column label gutter that `/cache` and `/context` already use. A label
above twelve characters overruns the value beside it.

## Bytes, not tokens

The engine stores byte counts. The panel derives shares from bytes, because `tokensFor` is linear and
a second estimate would add nothing. `Budget.forRequest` adds 1024 tokens of headroom and
`summaryTokens` adds 128, and neither belongs in a window that explains content.

## Order of work

1. `ContextSplit` in the proto, then `zig build gen-schema`.
2. Migration `0005` and the `session_context` columns.
3. The measurement in `prepare`, the carry on `RunSlot`, the write in `src/store/message.zig`.
4. The panel and the grid.
5. The five-part split is estimated; a test states the shares of one known request and no more.

## What this plan does not do

It states no per-message split for the transcript. It states no history of the split across turns.
It never claims the parts are measured, because only the total is.
