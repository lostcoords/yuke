---
description: Run one task without the terminal UI, in a script or a CI job, and read its answer as text or JSON.
---

# One-shot tasks

`yuke -p` runs one task without the terminal UI. yuke prints the final answer and exits.

## Run a task

A new session needs both a model and a reasoning choice. For example, with `ANTHROPIC_API_KEY` set:

```sh
yuke -p 'Explain how to run the tests. Do not change files.' \
  --model anthropic/claude-sonnet-4-6 --reasoning default
```

`--model` takes `PROVIDER/MODEL`. `--reasoning` takes `default`, `off`, or an effort such as `low` or `high`. See [Providers](providers.md) for the credentials.

## Read the answer as JSON

Add `--json` to get one JSON object with `sessionId`, `end`, and `text`:

- `sessionId` identifies the saved session.
- `end` tells how the turn ended.
- `text` is the last answer.

## Continue a session

To send a follow-up to the newest conversation in this directory:

```sh
yuke -c -p 'Which test should I run first?'
```

To continue a session by its ID, in any folder, use `--resume ID` with `-p`. A continued session keeps its model and reasoning choice unless you replace them. If you pass `--model` on a continued session, also pass `--reasoning`.

## Plugins without a terminal

Plugins load in this mode. Their tools and engine hooks work as in the terminal UI. The TUI service is absent, so terminal commands, keys, and views do not load. See [Plugins](plugins.md).

Some actions need a person to answer:

- A question from `s.ask` gets no answer. A hook that asks before a tool call therefore blocks that call. See [Approve a tool call](engine.md#approve-a-tool-call).
- A tool cannot start a background job. See [Background jobs](tools.md#background-jobs).
- Project MCP servers do not start without approval. See [MCP servers](mcp.md#sources-and-trust).
