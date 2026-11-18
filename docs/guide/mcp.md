---
description: Connect local MCP servers over stdio, and approve the servers of a project.
---

# MCP servers

yuke supports local MCP servers over stdio. It does not support remote HTTP, SSE, or OAuth servers.

## Sources and trust

The user `mcp.json` in the config folder and the session folder's `.mcp.json` each hold an `mcpServers` object. A project entry replaces a user entry with the same name. Plugins do not supply a third MCP config source.

```json
{
  "mcpServers": {
    "docs": {
      "command": "docs-mcp",
      "args": ["--stdio"],
      "env": { "DOCS_ROOT": "${HOME}/docs" }
    }
  }
}
```

A server entry accepts `command`, `args`, `env`, `cwd`, and `enabled`. The command starts directly, without a shell. A relative `cwd` starts in the session folder. The command, arguments, environment values, and folder expand `${NAME}` and `${NAME:-default}`. A missing variable without a default fails that server.

Both files accept `//` and `/* */` comments. An entry with `url` fails with a message, because yuke starts stdio servers only.

User servers start without a question. Project servers need approval: yuke asks one question with the options "Start" and "Don't start". yuke keeps a "Start" answer in `mcp-trust` in the [data folder](config.md), for the real folder and its list of servers. A change of the list asks again. "Don't start" is not kept, so yuke asks again in the next session. Without an answering client, such as in `yuke -p`, project servers do not start.

## Start and states

The host starts servers for each session. A server failure does not stop other servers. Session updates report server state changes, and `SessionHandle.mcpServers()` reads their current states.

Connected tools use names such as `mcp__docs__search`. Unsupported name characters become `_`; long or colliding names can get a hash suffix. MCP tools are deferred: the model finds them through tool search before use.
