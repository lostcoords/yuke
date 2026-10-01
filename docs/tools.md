# Tools

A model tool is a function that the model calls. Define it with `ctx.tools.define(definition)` outside `ctx.inject(["tui"], ...)`, so it exists in every mode.

## Definition

`definition` is `ToolDefinition`: `name`, `description`, `parameters`, `execute(args, signal, toolCtx)`, and optional `defer`.

- `name` is 1 to 64 characters of a-z, A-Z, 0-9, `_`, or `-`.
- `description` tells the model when to call the tool. Use the imperative mood. State each limit the model must know.
- `parameters` is a JSON Schema object. It needs `type: "object"` and `properties`. Set `additionalProperties: false`.
- `defer: true` waits for a `tool_search` tool to load the tool. Without a search tool, the engine loads it at once.
- A tool that `index.js` defines at startup replaces a built-in tool with the same name: `read`, `write`, `edit`, `exec`, `jobs`, or `skill`.

## Arguments

`args` is any JSON that the model wrote. Check each field before use. Throw an error for a missing or wrong field. Do not use a default in its place.

## Result

`execute` returns a promise. The promise resolves to one of these values:

| Value | Result |
|---|---|
| a string | The model reads the string. |
| `undefined` | The model reads empty output. |
| a `ToolOutcome` | The model reads `output`, `media`, and `tools_added`. The UI also shows `diff`. |

`ToolOutcome` is `{ output, is_error?, diff?, media?, tools_added? }`. `diff` is a list of `{ path, hunks }` with unified diff lines. An unknown key makes the call an error. An error result shows `output` only. A `tool.after` hook replaces the result with a `ToolOutcome`. The engine ignores the `name` and `arguments` keys of that replacement.

Any other value is an error. Return JSON data as a string: `JSON.stringify(data)`.

## Errors

Throw an `Error` when the call fails. The model reads its `message` and nothing else.

- Write a message that tells the model what to do next.
- Return `{ output, is_error: true }` when the output of a failed call is evidence, such as the log of a failed build.

## Context

- `toolCtx.output(text)` streams live output to the user. The model does not read it.
- `toolCtx.workspaceRoot` is the session root.
- `toolCtx.sessionId`, `toolCtx.messageId`, and `toolCtx.partId` name the transcript part that holds the call.

## Cancellation

The host aborts `signal` when the call stops. Pass `signal` to `fetch` and `exec`. `spawn` takes no signal, so kill its child when the signal aborts.

[`examples/plugin.js`](examples/plugin.js) defines a complete model tool.
