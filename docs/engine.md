# Engine

Model tools, hooks, config, subagents, and MCP can run in every mode. Register them outside `ctx.inject(["tui"], ...)`. Only their commands and dialogs need the TUI.

## Model tools

See [Tools](tools.md) for `ctx.tools.define` and the result contract.

## Engine hooks

Use `ctx.hook(point, handler)`. Search `HookPayloads` and `HookReplacements` in `yuke.d.ts` before you write a handler.

A handler can:

```js
// Continue.
ctx.hook("input.before", () => undefined);

// Block.
ctx.hook("tool.before", (call) => {
  if (call.name === "exec" && call.arguments.includes("rm -rf /")) {
    return { block: "refused by the profile" };
  }
});

// Replace the complete replacement value, not a patch.
ctx.hook("tools.select", (payload) => ({
  replace: { tools: payload.tools.filter((name) => name !== "exec") },
}));

// Await an approval before the action continues.
ctx.hook("tool.before", async (call) => {
  if (call.name !== "exec") return undefined;
  const ok = await ctx.interaction.confirm("Allow exec?", call.arguments);
  return ok ? undefined : { block: "exec was not approved" };
});
```

Handlers run in registration order. Each handler reads the changes from earlier handlers. A handler can be async, and the engine waits for it. A throw blocks the action and reports a fault.

A payload can contain context that its replacement omits. Return the full shape from `HookReplacements`, not the full payload and not one changed field. For example, a `request.build` replacement must include `model`, `system`, `tools`, and `max_output_tokens`.

| Point | When | Complete `replace` value |
|---|---|---|
| `tools.select` | a run chooses tools | `{ tools }` |
| `tool.before` | before a tool call; `arguments` is JSON text | `{ name, arguments }` |
| `tool.after` | after a tool call | `ToolOutcome` |
| `prompt.build` | the system prompt builds | `{ sections }` |
| `request.build` | before a model request | `{ model, system, tools, max_output_tokens }` |
| `request.send` | before the raw HTTP request | `{ url, headers, body }` |
| `compaction.prompt` | a compaction starts | `{ prompt }` |
| `input.before` | input enters a session | `{ content }` |

`tools.select`, `tool.before`, `request.build`, `prompt.build`, and `compaction.prompt` include context such as `session_id`, `depth`, `agent_name`, and `workspace`. Use it to scope a hook. Hooks run in the TUI, `yuke -p`, and `yuke --rpc` when the profile registers them outside a TUI injection.

## Config and prompt

Call `defineConfig(patch)` in `index.js`. An unknown key throws.

| Key | Default | Meaning |
|---|---|---|
| `systemPrompt` | `null` | Replace the base prompt. `${workspace}`, `${session_id}`, and `${agent_name}` expand. |
| `colors` | `"auto"` | The palette depth: `"auto"` follows `COLORTERM`, `"truecolor"` forces 24-bit colors, `"256"` forces the 256-color palette. |
| `mouse.copyOnSelect` | `true` | Copy a mouse selection. |
| `mouse.scrollLines` | `3` | Lines per wheel step, 1 to 20. |
| `keymap.chordMs` | `1000` | Milliseconds to wait for the next chord key, 1 to 10000. |

Use `prompt.build` to add text while you keep the built-in prompt. Search `PromptBuild` and `PromptSection` for the exact shape.

## Subagents

The optional `agents` plugin adds child sessions and three model tools. This is a complete `index.js`:

```js
import { plugins } from "yuke";
import { agents } from "yuke:plugins";

plugins.use(agents({
  catalog: {
    research: {
      description: "Inspect the requested area and report evidence.",
      model: "provider/model", // Replace this selector, or omit it to inherit the parent model.
      prompt: "Do not edit files.",
      tools: ["read", "exec", "skill"],
    },
    edit: {
      description: "Make one focused code change and verify it.",
      tools: ["read", "write", "edit", "exec", "skill"],
    },
  },
  default: "research",
  maxDepth: 2,
  maxConcurrent: 4,
  maxRounds: 30,
}));
```

Each catalog key names a child kind. It matches `^[a-z][a-z0-9_-]{0,63}$`; `root` is reserved.

| Row field | Meaning |
|---|---|
| `description` | Tells the parent model when to choose this kind. |
| `model` | Selects the child model. Without it, the child uses the parent model. |
| `prompt` | Appends instructions after the fixed child policy. |
| `tools` | Restricts the child to a nonempty unique subset of `read`, `write`, `edit`, `exec`, and `skill`. |

A restricted `tools` row also removes the spawn tools from that child. Omit `tools` to keep the normal loadout. `default` selects the row when `spawn_agent` omits `agent`. A one-row catalog needs no `default`.

| Limit | Behavior |
|---|---|
| `maxDepth` | Defaults to `1`. The root is depth zero. At the limit, spawn tools are absent. |
| `maxConcurrent` | Defaults to `8`. It counts active descendants across the tree, not the root. Extra runs wait in the durable queue. |
| `maxRounds` | Caps each child run. Without it, the plugin sets no child round cap. A capped run reports partial output. |

All three values are positive 32-bit integers.

### Spawn tools

| Tool | Arguments | Result and behavior |
|---|---|---|
| `spawn_agent` | `{ message, agent? }` | Starts or queues a new child and returns one line with its session ID. It does not wait for completion. |
| `send_agent_input` | `{ child, message }` | Sends a follow-up to the child session ID. The child keeps its transcript. |
| `stop_agent` | `{ child }` | Stops the current child run and drops its queued input. It returns one line that names the stopped run and the count of dropped inputs, if any. It keeps the transcript. Completed side effects remain. |

`message` must be nonempty. `agent` must name a catalog row. `child` must be the 32-character session ID of a direct child of the calling parent.

A child uses the parent workspace in a separate session and transcript. It reports completion, cancellation, and failure to the parent. A failed or capped run marks its output as partial. A report waits while its parent is busy. It starts a parent follow-up after the parent becomes idle and capacity is available. A follow-up creates a new run in the same child transcript and produces another report.

`/agents` shows the root and all descendants of the current session. It can switch to a child or stop its work. Disposing the plugin removes its tools and restores the previous depth and concurrency limits. Existing sessions and durable queued records remain.

See [`examples/agents.js`](examples/agents.js) and search `AgentRow` and `AgentsOptions` for exact types.

## MCP servers

The optional `mcp` plugin connects local stdio and remote HTTP servers. Search `ServerConfig`, `OAuthConfig`, and `McpOptions` in `yuke.d.ts` for exact fields.

### Local server in `index.js`

```js
import { plugins } from "yuke";
import { mcp } from "yuke:plugins";

plugins.use(mcp({
  servers: {
    docs: {
      type: "stdio",
      command: "docs-mcp",
      args: ["--stdio"],
      env: { DOCS_ROOT: "${HOME}/docs" },
      cwd: "${HOME}",
    },
  },
}));
```

The command starts directly from its argument array. It does not use a shell. `env` adds or replaces child environment values.

### Profile `.mcp.json`

Place this file next to profile `index.js`:

```json
{
  "mcpServers": {
    "docs": {
      "type": "stdio",
      "command": "docs-mcp",
      "args": ["--stdio"],
      "env": { "DOCS_ROOT": "${HOME}/docs" }
    }
  }
}
```

### Workspace `.mcp.json`

A workspace file uses the same envelope. Commit only commands that are safe for every user of the workspace:

```json
{
  "mcpServers": {
    "project": {
      "type": "stdio",
      "command": "project-mcp",
      "args": ["--root", "."]
    }
  }
}
```

yuke asks the user before it starts each workspace server. The decision belongs to that workspace, server name, and command or URL identity. A changed identity asks again. Do not bypass this prompt. `/mcp-reset-trust` forgets workspace decisions and stops those servers until the user trusts them again. A frontend that cannot ask does not start an untrusted server.

### Remote server, headers, and OAuth

```json
{
  "mcpServers": {
    "remote-docs": {
      "type": "http",
      "url": "https://mcp.example.com/mcp",
      "headers": { "X-Tenant": "${MCP_TENANT}" },
      "oauth": {
        "clientId": "yuke-profile",
        "scopes": ["mcp:tools"]
      }
    }
  }
}
```

Remote `type` can be `http` for Streamable HTTP or `sse` for the legacy transport. Yuke uses OAuth by default unless `oauth` is `false` or the headers set `Authorization`. `oauth` can set `clientId`, `clientSecret`, and `scopes`. Do not put a client secret in a workspace file or in git.

For a fixed bearer token, keep the value in the process environment:

```json
{
  "url": "https://mcp.example.com/mcp",
  "headers": { "Authorization": "Bearer ${MCP_TOKEN}" },
  "oauth": false
}
```

`command`, `args`, `env` values, `cwd`, `url`, and header values expand `${NAME}` and `${NAME:-default}`. A missing variable without a default fails that server. The config file contains the variable name, not its credential value.

### Loading and observable states

Sources have first-name precedence:

1. `servers` in `index.js`;
2. profile `.mcp.json`;
3. workspace `.mcp.json`.

Trusted servers connect when the plugin loads. `/mcp` shows each server state, transport era, tool list, and public failure text. A bad entry or failed server does not stop other servers. An HTTP 401 can put a server in `needs auth`; use `/mcp-login [name]`. `/mcp-logout <name>` forgets its grant and reconnects. OAuth grants and trust records live in yuke's private data directory, not in `.mcp.json`.

A connected tool is named `mcp_<server>_<tool>`. Unsupported name characters become `_`; long names get a stable suffix. `/mcp` shows the server's original tool names. MCP tools are deferred by default. The plugin exposes `tool_search` while at least one server is connected, and a search loads matching tools. Set `alwaysLoad: true` on a server to make its tools eager.

| Command | Purpose |
|---|---|
| `/mcp` | Show server states and tools. |
| `/mcp-login [name]` | Start browser OAuth for one remote server. Without a name, use the first server that needs auth. |
| `/mcp-logout <name>` | Forget one remote grant and reconnect. |
| `/mcp-reset-trust` | Forget workspace trust decisions. |

`enabled: false` disables one server. `startupMs` and `callMs` set plugin defaults in milliseconds. A server `timeout` replaces the call timeout. See [`examples/mcp.js`](examples/mcp.js) for a complete profile example.
