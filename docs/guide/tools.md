---
description: Define session tools with checked arguments, model results, cancellation, and background jobs.
---

# Tools

A model tool is an operation that the model can call. Register it with `s.tools.define` in the named `session` export. Each session gets its own registrations, in the TUI and in headless modes.

## Definition

This entry module defines `count_words` in each session:

<<< @/guide/examples/plugin.js

`Tool<S>` from `yuke:tools` defines the contract:

| Field | Meaning |
|---|---|
| `name` | 1 to 64 letters, digits, `_`, or `-` |
| `description` | When the model must use the tool and what it does |
| `parameters` | An `ObjectSchema` for the arguments |
| `concurrency` | Required: `serial` or `parallel` |
| `deferLoading` | Optional: keep the tool out of requests until tool search finds it |
| `hints` | Optional: display title, subject, and output preview |
| `execute(args, context)` | Return a result or a promise for a result |

A serial call runs alone among the calls of one model answer. Parallel calls can run together. This setting does not serialize work across sessions.

A duplicate or reserved name throws. Built-in tools hold the names `read`, `write`, `edit`, `exec`, and `stop`. The engine also reserves its tool-search names. A failed session setup removes the tools and hooks that the plugin registered in that session.

`define` returns a remover. Removal frees the name and excludes the tool from the next turn. Session close removes the registration automatically. A tool-list change can invalidate the provider's prompt cache.

## Arguments

The host validates model arguments before `execute`. It infers the argument types from an inline schema. A schema constant can use `as const satisfies ObjectSchema` to preserve its field types.

The supported schema types are `string`, `boolean`, `integer`, `number`, `array`, and `object`. Numeric schemas accept `minimum` and `maximum`. String and numeric schemas accept `enum`. Arrays need `items`; objects need `properties` and can list `required` fields.

Objects reject fields outside `properties`, with or without `additionalProperties: false`. An optional field with `null` counts as absent. An unsupported schema keyword fails the definition. See `Schema`, `ObjectSchema`, and `Infer` in `yuke:tools` for the exact types.

Validate semantic limits that the schema does not express. Do not repeat the host's type checks inside `execute`.

## Result

Return a string, or a `ToolResult` object:

<<< @/snippets/tools/result.ts

| Field | Meaning |
|---|---|
| `text` | Required text for the model |
| `isError` | Optional error flag; defaults to `false` |
| `media` | Optional media items for the model |
| `display` | Optional display blocks for the user, in place of the text |

A media item has `mimeType` and either `path` or `bytes: Uint8Array`. A relative path starts in the folder of the call. The host copies returned bytes. An error result retains its media.

Display blocks can show results such as diffs without adding that display to the model's context. Keep the display consistent with the result text. See `DisplayBlock` in `yuke:tools` for its variants.

Unknown result fields fail the call. `undefined` and `null` are not results. Return structured data as text with `JSON.stringify(data)`.

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
| `folder` | Read the session folder at the start of the call. |
| `signal` | Stop work when the call ends or the turn cancels it. |
| `output(text)` | Stream text to the user, not the model. |
| `jobs.run(options, work)` | Run work that can move to a background job. |

Pass `context.signal` to cancellable I/O. After cancellation, the host still waits for `execute` to settle. Stop the work when the signal aborts.

For processes, use `Command` from `yuke:process`. Its constructor takes an explicit `cwd` and an optional `signal`. Its `output()` method waits for completion.

## Background jobs

Use `context.jobs.run({ id, label, background? }, work)` for work inside a tool. The call waits unless `background` is `true` or the user moves the work to the background. The answer is `{ kind: "completed", report }` or `{ kind: "background", id }`.

Use the signal passed to `work`, not `context.signal`. The call ends when work moves to the background, but the job must continue. Work can return `{ status, text }` to report its end, or `undefined` for no report.

Use `s.jobs.run({ id, label }, work)` to start a session job without a tool call. Job IDs must be unique among the running jobs of that session. Background starts reject in `yuke -p`.

The built-in `stop` tool and a session handle's `stopJob(id)` stop a job and await its work. A requested stop sends no completion report. Session close and reload also stop plugin jobs and await their work.
