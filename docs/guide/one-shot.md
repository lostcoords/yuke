---
description: Run one task without the TUI, in a script or a CI job, and read its answer as text or JSON.
---

# One-shot tasks

`yuke -p` runs one task without the TUI. yuke prints the final answer and exits. See [Command line](cli.md) for all flags.

## Run a task

A new session needs both a model and a reasoning level. For example, with `ANTHROPIC_API_KEY` set:

```sh
yuke -p 'Explain how to run the tests. Do not change files.' \
  --model anthropic/claude-sonnet-4-6 --reasoning default
```

`--model` takes `PROVIDER/MODEL`. `--reasoning` takes `default`, `off`, or an effort such as `low` or `high`. See [Providers](providers.md) for the credentials.

## Read the answer as JSON

Add `--json` to get one JSON object with `sessionId`, `end`, and `text`:

```json
{"sessionId":"01010101-0101-0101-0101-010101010101","end":{"kind":"completed","finishReason":"stop"},"text":"done"}
```

- `sessionId` identifies the saved session.
- `end` tells how the turn ended. Its `kind` is `completed`, `stopped`, `cancelled`, or `failed`. A `failed` end also has an `error` text.
- `text` is the last answer.

## Exit status

The exit status is `0` when the turn ends as `completed` or `stopped`. It is `1` when the turn ends as `failed` or `cancelled`, or when yuke cannot start the turn. SIGINT, SIGTERM, and SIGHUP cancel the turn, and the exit status is then 128 plus the signal number. Without `--json`, yuke prints a failure text to stderr.

## Continue a session

To send a follow-up to the newest session in this folder:

```sh
yuke -c -p 'Which test should I run first?'
```

To continue a session by its ID, in any folder, use `--resume ID` (or `-r ID`) with `-p`. A continued session keeps its model and reasoning level unless you replace them. If you pass `--model` on a continued session, also pass `--reasoning`.

## Plugins without a terminal

Plugins load in this mode. Their tools and engine hooks work as in the TUI. Commands, keys, and views of the TUI do not load. See [Plugins](plugins.md).

No person can answer, so some actions do not work:

- A question from `s.ask` gets no answer. A hook that asks before a tool call therefore blocks that call. See [Approve a tool call](engine.md#approve-a-tool-call).
- A job cannot start without a call. `s.jobs.start` rejects, and `exec` with `background: true` returns an error. See [Background jobs](tools.md#background-jobs).
- Project MCP servers start only when an earlier session kept their approval. See [MCP servers](mcp.md#sources-and-trust).
