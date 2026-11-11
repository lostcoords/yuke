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

User servers start without a question. Project servers need approval. Saved approval identifies the real folder and the parsed project server config; a config change can require approval again. A refusal leaves project servers untrusted. Without an answering client, they do not start.

## Start and states

The host starts servers for each session. A server failure does not stop other servers. Session updates report server state changes, and `SessionHandle.mcpServers()` reads their current states.

Connected tools use names such as `mcp__docs__search`. Unsupported name characters become `_`; long or colliding names can get a hash suffix. MCP tools are deferred: the model finds them through tool search before use.
