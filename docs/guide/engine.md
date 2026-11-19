---
description: Add model tools and engine hooks to a session, and change the prompt.
---

# Engine

A turn takes pending input, builds its system prompt, and requests a model answer. Each model request is a round. Tool results can lead to another round in the same turn.

A plugin adds session behavior through its `session(s)` export. Tools and hooks work in the TUI and in headless modes. Use `s.tools.add` for model tools. See [Tools](tools.md).

## Engine hooks

Use `s.addHook(point, handler)` to change or approve an action. It returns a remover. Each handler gets a frozen event, and the host awaits its result. Return `undefined` for no change. Otherwise, return the answer for that point.

| Point | Event fields besides `signal` | Answer |
|---|---|---|
| `input.before` | `source`, `kind`, `blocks` | `{ deny }`, `{ handled: true }`, or `{ replace: { blocks } }` |
| `prompt.build` | `sections` | `{ sections }` |
| `round.before` | Context counts, context readers, and `sideRequest` | Optional `replace`, `model`, and `settings` |
| `round.retry` | The round fields, plus `failure` and `retries` | The same plan as `round.before` |
| `tool.before` | `call` | `{ deny }` |
| `tool.after` | `call`, `result` | Optional `text`, `isError`, `media`, and `display` |
| `round.after` | `text`, `finishReason`, `continues` | `{ stop: true }` or `{ continue }` |

Handlers run in plugin order, then in registration order. Later handlers see earlier replacements. The `SessionHooks` interface in `yuke:plugins` has the exact contracts.

### Approve a tool call

<<< @/snippets/engine/approve.ts

`call.arguments` is parsed JSON with type `unknown`. The tool's schema check runs after `tool.before`, so check the shape before you read a field. A before hook can deny a call, but cannot change it. The denial text becomes the error result that the model reads.

`s.ask` returns one answer per question, or `undefined` on cancellation, session close, or when no client can answer. This example therefore denies `exec` in `yuke -p`. Pass the hook signal to questions and other cancellable work.

### Change input, prompt, or results

`input.before` runs when a turn takes saved input, not when the client sends it. `replace` changes only what the model reads, and needs at least one block. `deny` removes the input with a notice. `handled` removes it without a notice.

`prompt.build` runs once before each turn. Return the complete section map, and keep the existing sections when you add text:

<<< @/snippets/engine/prompt.ts

Section order is prompt order. The model reads each section except `base` between tags named for its key. The change applies to that turn only. Text that changes every turn reduces prompt-cache reuse.

`tool.after` gets the result after earlier handlers. Its answer changes only the fields that it supplies. Set `display: []` to remove a display that no longer matches changed text.

### Plan or continue a round

`round.before` can return a plan:

- `replace: { head, keep }`: replace the context with `head` followed by the last `keep` blocks. The session saves this replacement.
- `model: { provider, model }`: use another model for this round.
- `settings`: replace request settings for this round. Each field replaces its whole value.

`round.retry` runs after the host's retries for a transient failure stop. An answer retries the round with that plan. No answer lets the failure end the turn. The host sets no limit on retries, so check `retries` to bound a loop.

`round.after` runs after an answer and its tool results. `{ continue: "text" }` gives the text to the model as an input of the plugin, shows it to the user as a notice, and requests another round. `{ stop: true }` ends the turn. Check `continues` to bound a continuation loop.

### Hook failures

A failed handler names its point and plugin. Its effect depends on the point:

- `input.before` removes the input and sends a notice.
- `prompt.build` sends a notice and leaves the input pending.
- `tool.before` stops the call.
- `tool.after` replaces the result with an error without media.
- A round hook ends the turn with an error.

A call that `tool.before` stopped gets no `tool.after` hook. Use [host facts](plugins.md#events) for observation that must not block the engine.
