---
description: Define session tools with checked arguments, model results, cancellation, and background jobs.
---

# Tools

A model tool is an operation that the model can call. Register it with `s.tools.add` in the `session` export of a plugin. Each session gets its own registrations, in the TUI and in headless modes.

## Definition

This entry module defines `count_words` in each session:

<<< @/guide/examples/plugin.js

`Tool<S>` from `yuke:tools` defines the contract. `concurrency` is required. A `serial` call runs alone among the calls of one model answer, and `parallel` calls can run together. `deferLoading: true` keeps the tool out of requests until tool search finds it.

A name must match `^[a-zA-Z0-9_-]{1,64}$`, or `add` throws a `TypeError`. A plugin cannot use `tool_search` or `tool_call`.

A tool with the name of an existing tool replaces it in this session, and the last definition wins. A replacement of another plugin's tool sends an info notice. The built-in tools `read`, `write`, `edit`, `exec`, and `stop` work the same way. `s.tools.remove(name)` removes a name from the tool list of this session.

`add` and `remove` return a remover. Session close removes each registration automatically.

## Arguments

The host validates model arguments before `execute`, and infers their types from an inline schema. A schema constant can use `as const satisfies ObjectSchema` to keep its field types.

The schema types are `string`, `boolean`, `integer`, `number`, `array`, and `object`. Numeric schemas accept `minimum` and `maximum`. String and numeric schemas accept `enum`. Objects reject fields outside `properties`. An optional field with `null` counts as absent. yuke ignores other keywords. See `Schema` in `yuke:tools`.

Do not repeat the host's type checks inside `execute`. Validate only the limits that the schema cannot express.

## Result

Return a string, or a `ToolExecuteResult` object:

<<< @/snippets/tools/result.ts

| Field | Meaning |
|---|---|
| `text` | Required text for the model |
| `isError` | Optional error flag; defaults to `false` |
| `media` | Optional media items for the model, each with `mimeType` and a `path` or `bytes` |
| `display` | Optional display blocks for the user, in place of the text |

Display blocks can show results such as diffs without adding that display to the model's context. See `DisplayBlock` in `yuke:tools`.

## Errors

Throw an `Error` when the call fails. The model receives an error result with its message. Write a message that tells the model what to do next.

Return `{ text, isError: true }` when the failed output is useful evidence, such as a compiler log. A [tool.after hook](engine.md#engine-hooks) can change the result before the model reads it.

## Context and cancellation

`execute` gets a `ToolContext` as its second argument. `cwd` is the workspace folder of the call: relative paths and commands start there. `output(text)` streams text to the user, not the model.

Pass `context.signal` to cancellable I/O. After a cancel, the host still waits for `execute` to settle, so stop the work when the signal aborts.

For processes, use `Command` from `yuke:process`. It needs an absolute `cwd`, such as `context.cwd`, and takes an optional `signal`.

## Background jobs

Use `context.jobs.run({ id, label, background? }, work)` for work inside a tool. The call waits unless `background` is `true` or the user moves the work to the background. The answer is `{ kind: "completed", report }` or `{ kind: "background", id }`.

Use the signal passed to `work`, not `context.signal`, because the job must continue when the call ends. Work can return `{ status, text }` to report its end, or `undefined` for no report.

Use `s.jobs.start({ id, label }, work)` to start a session job without a tool call. A job ID must be unique among the running jobs of the session. Background starts reject in `yuke -p`.

The built-in `stop` tool and the `stopJob(id)` method of a session handle stop a job and await its work. A stopped job sends no report. Session close and reload also stop plugin jobs.
