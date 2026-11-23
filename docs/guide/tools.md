---
description: Define session tools with checked arguments, model results, cancellation, and background jobs.
---

# Tools

A model tool is an operation that the model can call. Register it with `s.tools.add` in the `session` export of a plugin. Each session gets its own registrations, in the TUI and in headless modes.

yuke has built-in tools too. See [Built-in tools](#built-in-tools).

## Definition

This entry module defines `count_words` in each session:

<<< @/guide/examples/plugin.js

`Tool<S>` from `yuke:tools` defines the contract. `concurrency` is required. A `serial` call runs alone among the calls of one model answer, and `parallel` calls can run together. `deferLoading: true` keeps the tool out of requests until tool search finds it.

A name must match `^[a-zA-Z0-9_-]{1,64}$`, or `add` throws a `TypeError`. A plugin cannot use the names `tool_search` and `tool_call`.

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

Display blocks can show results such as diffs without adding that display to the model's context. See `DisplayBlock` in `yuke:protocol`.

## Errors

Throw an `Error` when the call fails. The model receives an error result with its message. Write a message that tells the model what to do next.

Return `{ text, isError: true }` when the failed output is useful evidence, such as a compiler log. A [tool.after hook](engine.md#engine-hooks) can change the result before the model reads it.

## Context and cancellation

`execute` gets a `ToolContext` as its second argument. `folder` is the workspace folder of the call: relative paths and commands start there. `output(text)` streams text to the user, not the model.

Pass `context.signal` to cancellable I/O. After a cancel, the host still waits for `execute` to settle, so stop the work when the signal aborts.

For processes, use `Command` from `yuke:process`. It needs an absolute `cwd`, such as `context.folder`, and takes an optional `signal`. `output()` runs a program until its end. `spawn()` starts it and gives its pipes as streams while it runs: set `stdin: "piped"` to write its input.

## Background jobs

Use `context.jobs.run({ id, label, background? }, work)` for work inside a tool. The call waits unless `background` is `true` or the user moves the work to the background. The answer is `{ kind: "completed", report }` or `{ kind: "background", id }`.

Use the signal passed to `work`, not `context.signal`, because the job must continue when the call ends. Work can return `{ status, text }` to report its end, or `undefined` for no report.

Use `s.jobs.start({ id, label }, work)` to start a session job without a tool call. A job ID must be unique among the running jobs of the session.

In `yuke -p`, each job start that runs without a call rejects. This covers `s.jobs.start`, `context.jobs.run` with `background: true`, and `exec` with `background: true`. A job that its call waits for still works.

The built-in `stop` tool and the `stopJob(id)` method of a session handle stop a job and await its work. A stopped job sends no report. Session close and reload also stop plugin jobs.

## Built-in tools

yuke gives each session these tools. A plugin can replace a built-in tool of the first group with `s.tools.add`, or remove it with `s.tools.remove`.

| Tool | What it does |
|---|---|
| `read` | Read a file with line numbers. `offset` and `limit` select the lines. One read returns at most 50 KiB. It returns an image file (PNG, JPEG, GIF, or WebP) as an image. |
| `write` | Create a file or replace its content. It makes the missing parent folders. |
| `edit` | Replace an exact string in a file. `old_string` must match once, unless `replace_all` is `true`. The result shows a diff. |
| `exec` | Run a shell command in the workspace folder. It returns the output and the exit status. The default deadline is 120 seconds, and `timeout_ms` raises it up to 600 seconds. `background: true` runs a server or a watcher as a job. |
| `stop` | Stop a background job by its ID. |

The engine adds two more tools. A plugin cannot define them.

| Tool | What it does |
|---|---|
| `tool_search` | Find a deferred tool by keywords. A deferred tool stays out of the requests until the model finds it. MCP tools are deferred. The tool exists only when the session has a deferred tool. |
| `tool_call` | Call a deferred tool that `tool_search` found, by name and arguments. Only a model that has no native tool search gets it. |

Relative paths of `read`, `write`, and `edit` start in the workspace folder. A [hook](engine.md#engine-hooks) can approve or deny each call.
