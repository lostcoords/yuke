---
description: Define session tools with checked arguments, model results, cancellation, and background jobs.
---

# Tools

A model tool is an operation that the model can call. Register it with `s.tools.add` in the named `session` export. Each session gets its own registrations, in the TUI and in headless modes.

## Definition

This entry module defines `count_words` in each session:

<<< @/guide/examples/plugin.js

`Tool<S>` from `yuke:tools` defines the contract:

| Field | Meaning |
|---|---|
| `name` | 1 to 64 letters, digits, `_`, or `-` |
| `description` | When the model must use the tool and what it does |
| `inputSchema` | An `ObjectSchema` for the arguments |
| `concurrency` | Required: `serial` or `parallel` |
| `deferLoading` | Optional: keep the tool out of requests until tool search finds it |
| `hints` | Optional: display title, subject, and output preview |
| `execute(args, context)` | Return a `ToolExecuteResult` or a promise for one |

A serial call runs alone among the calls of one model answer. Parallel calls can run together. This setting does not serialize work across sessions.

A name that does not match `^[a-zA-Z0-9_-]{1,64}$` throws a `TypeError`. The engine reserves `tool_search` and `tool_call`, and a plugin cannot use them.

A tool with the name of an existing tool replaces it in this session. The last definition wins. A replacement of another plugin's tool sends an info notice. The built-in tools `read`, `write`, `edit`, `exec`, and `stop` work the same way. `s.tools.remove(name)` removes a name from the tool list of this session, and a later definition restores it. A failed session setup withdraws the tools and hooks that the plugin registered in that session.

`add` and `remove` return a remover. The remover of a definition reveals the previous definition of that name. Session close removes each registration automatically. The next turn uses the new tool list. A tool-list change can invalidate the provider's prompt cache.

## Arguments

The host validates model arguments before `execute`. It infers the argument types from an inline schema. A schema constant can use `as const satisfies ObjectSchema` to preserve its field types.

The supported schema types are `string`, `boolean`, `integer`, `number`, `array`, and `object`. Numeric schemas accept `minimum` and `maximum`. String and numeric schemas accept `enum`. Arrays need `items`; objects need `properties` and can list `required` fields.

Objects reject fields outside `properties`, with or without `additionalProperties: false`. An optional field with `null` counts as absent. yuke checks only the keywords above. The model still sees another keyword, and yuke ignores it. See `Schema`, `ObjectSchema`, and `Infer` in `yuke:tools` for the exact types.

Validate semantic limits that the schema does not express. Do not repeat the host's type checks inside `execute`.

## Result

Return a string, or a `ToolExecuteResult` object:

<<< @/snippets/tools/result.ts

| Field | Meaning |
|---|---|
| `text` | Required text for the model |
| `isError` | Optional error flag; defaults to `false` |
| `media` | Optional media items for the model |
| `display` | Optional display blocks for the user, in place of the text |

A media item has `mimeType` and either `path` or `bytes: Uint8Array`. A relative path starts in the folder of the call. The host copies returned bytes. An error result retains its media.

Display blocks can show results such as diffs without adding that display to the model's context. Keep the display consistent with the result text. See `DisplayBlock` in `yuke:tools` for its variants.

A result is a string or an object with `text`. Return structured data as text with `JSON.stringify(data)`.

There is no automatic output cap for plugin tools. Return bounded text that the model needs. The built-in `read` and `exec` tools apply their own output limits.

## Errors

Throw an `Error` when the call fails. The model receives an error result with its message. Write a message that tells the model what to do next.

Return `{ text, isError: true }` when the failed output is useful evidence, such as a compiler log. A [tool.after hook](engine.md#engine-hooks) can change the result before the model reads it.

## Context and cancellation

`ToolContext` supplies:

| Member | Use |
|---|---|
| `sessionId` | Identify the session. |
| `callId` | Identify the call within the session. |
| `cwd` | Read the workspace folder at the start of the call. Relative paths and commands start here. |
| `signal` | Stop work when the call ends or the turn cancels it. |
| `output(text)` | Stream text to the user, not the model. |
| `jobs.run(options, work)` | Run work that can move to a background job. |

Pass `context.signal` to cancellable I/O. After cancellation, the host still waits for `execute` to settle. Stop the work when the signal aborts.

For processes, use `Command` from `yuke:process`. Its constructor takes the program and an options object with a required absolute `cwd`, such as `context.cwd`, and an optional `signal`. Its `output()` method waits for completion.

## Background jobs

Use `context.jobs.run({ id, label, background? }, work)` for work inside a tool. The call waits unless `background` is `true` or the user moves the work to the background. The answer is `{ kind: "completed", report }` or `{ kind: "background", id }`.

Use the signal passed to `work`, not `context.signal`. The call ends when work moves to the background, but the job must continue. Work can return `{ status, text }` to report its end, or `undefined` for no report.

Use `s.jobs.start({ id, label }, work)` to start a session job without a tool call. Job IDs must be unique among the running jobs of that session. Background starts reject in `yuke -p`.

The built-in `stop` tool and a session handle's `stopJob(id)` stop a job and await its work. A requested stop sends no completion report. Session close and reload also stop plugin jobs and await their work.
