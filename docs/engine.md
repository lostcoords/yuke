# Engine: tools, hooks, config, prompt, subagents, MCP

These parts run in every mode: the TUI, `yuke -p`, and `yuke --rpc`. Do not put them in an `inject(["tui"])` block.

## Model tools

`ctx.tools.define(definition)`

- `definition` is `ToolDefinition`: `name`, `description`, `parameters` (a JSON Schema object), `execute(args, signal, toolCtx)`, and `defer?`.
- `args` is any JSON that the model wrote. Check it before use.
- `execute` returns a promise. A string goes to the model as is, and another value goes as JSON. A throw becomes an error result.
- `toolCtx.output(text)` streams live output to the user. `toolCtx.workspaceRoot` is the session root.
- Pass `signal` to `fetch` and `exec`, so an interrupt stops the work. `spawn` takes no signal: call `child.kill()` when the signal aborts.
- A tool that `index.js` defines at startup, outside `inject`, replaces a built-in tool with the same name (`read`, `write`, `edit`, `exec`, `jobs`, `skill`). A later definition of a taken name throws.
- `defer: true` loads the tool only after a tool search names it. It needs a `tool_search` tool in the run, such as the one the `mcp` plugin adds while a server is connected. Without one, the tool loads at once.

## Engine hooks

`ctx.hook(point, handler)`

A handler returns `{ block: reason }` to stop the action, `{ replace: value }` to change it, or nothing to continue. The value is the whole new payload, not a patch. Handlers run in registration order, and each handler reads the value of the one before it. So spread the payload and change only the fields in the table, for example `{ replace: { ...payload, tools } }`: a later handler, such as a built-in one, can read `context`. A throw blocks the action. Search `HookPayloads` and `HookReplacements` in `yuke.d.ts`.

| Point | When | `replace` value |
|---|---|---|
| `tools.select` | a run chooses its tools | `{ tools }` |
| `tool.before` | before a tool call; `arguments` is JSON text | `{ name, arguments }` |
| `tool.after` | after a tool call | the tool result |
| `prompt.build` | the system prompt builds | `{ sections }` |
| `request.build` | before a model request | `{ model, system, tools, max_output_tokens }` |
| `request.send` | the raw HTTP request | `{ url, headers, body }` |
| `compaction.prompt` | a compaction starts | `{ prompt }` |
| `input.before` | the user sends input | `{ content }` |

The payloads of `tools.select`, `tool.before`, `request.build`, `prompt.build`, and `compaction.prompt` have `context` (`session_id`, `depth`, `agent_name`, `workspace`), so a handler can act for one agent or one project only.

## Config

`defineConfig(patch)`

Call it in `index.js`. An unknown key throws.

| Key | Default | Meaning |
|---|---|---|
| `systemPrompt` | `null` (the built-in prompt) | Replaces the base prompt. `${workspace}`, `${session_id}`, and `${agent_name}` expand. |
| `mouse.copyOnSelect` | `true` | Copy a mouse selection. |
| `mouse.scrollLines` | `3` | Lines per wheel step, 1 to 20. |
| `keymap.chordMs` | `1000` | The wait for the next key of a chord, 1 to 10000. |

To add text to the prompt and keep the rest, use the `prompt.build` hook. The section keys are `base` (or `system_prompt`), `instructions`, `skills`, and `environment`.

## Subagents

`agents(options)` from `yuke:plugins`:

```js
plugins.use(agents({
  catalog: {
    research: { description: "Narrow research and simple edits.", tools: ["read", "exec"] },
    review: { description: "Broader work and review.", model: "provider/model" },
  },
  default: "research",
  maxDepth: 2,
}));
```

- Each catalog key names one kind of child. A key matches `^[a-z][a-z0-9_-]{0,63}$`, and `root` is reserved.
- A row sets `description`, `model`, `prompt`, and `tools`. A row without `model` runs on the model of its parent session.
- `tools` is a subset of `read`, `write`, `edit`, `exec`, `skill`.
- `default` names the row that a spawn uses when it names none. A catalog with one row needs no `default`.
- `maxDepth` (default `1`, direct children only) caps the depth below the root. At the limit, the spawn tools are absent.
- `maxConcurrent` (default `8`) caps the active descendants of the whole tree. Extra work waits in a durable queue.
- `maxRounds` caps each child run. A capped run reports its partial output.
- The three limits are positive 32-bit integers. `/agents` shows the agent tree of the current session, switches to an agent, and stops agent work.

## MCP servers

`mcp(options)` from `yuke:plugins`:

```js
plugins.use(mcp({ servers: { docs: { command: "docs-mcp", args: ["--stdio"] } } }));
```

- A server is local (`command`, `args`, `env`, `cwd`) or remote (`url`, `headers`, `oauth`).
- yuke also reads `<profile>/.mcp.json` and `<workspace>/.mcp.json`. The first definition of a name wins: `index.js`, then the profile file, then the workspace file.
- yuke asks the user before it trusts a workspace `.mcp.json`. Do not bypass that question.
- Commands: `mcp:show` (`/mcp`), `mcp:login` (`/mcp-login`), `mcp:logout` (`/mcp-logout`), `mcp:reset-trust` (`/mcp-reset-trust`).
