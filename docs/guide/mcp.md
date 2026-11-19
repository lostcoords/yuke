---
description: Connect local MCP servers over stdio, and approve the servers of a project.
---

# MCP servers

yuke supports local MCP servers over stdio. It does not support remote HTTP, SSE, or OAuth servers. A server with a `url` fails alone, and the other servers still start. This lets one `mcp.json` serve other tools too.

## Sources and trust

The user `mcp.json` in the config folder and the `.mcp.json` in the session folder each hold an `mcpServers` object. A project entry replaces a user entry with the same name.

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

A server entry accepts `command`, `args`, `env`, `cwd`, and `enabled`. The command starts directly, without a shell. A relative `cwd` starts in the session folder. The command, arguments, environment values, and folder expand `${NAME}` and `${NAME:-default}`. A missing variable without a default fails that server. Both files accept `//` and `/* */` comments.

User servers start without a question. Project servers need approval: yuke asks once, with the options "Start" and "Don't start". yuke keeps a "Start" answer in `mcp-trust` in the [data folder](config.md), for that folder and that list of servers. A change of the list asks again. Without an answering client, such as in `yuke -p`, only a kept approval starts project servers.

## Tools

A connected tool has a name such as `mcp__docs__search`. MCP tools are deferred: the model finds them through tool search before use. A server failure does not stop other servers.
