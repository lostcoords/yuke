---
description: Connect local MCP servers over stdio, and approve the servers of a project.
---

# MCP servers

yuke supports local MCP servers over stdio. It does not support remote HTTP, SSE, or OAuth servers. A server with a `url` fails alone with the notice "yuke supports only stdio servers, and this entry names a url", and the other servers still start. This lets one `mcp.json` serve other tools too.

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

A server entry uses `command`, `args`, `env`, `cwd`, and `enabled`. The file key stays `cwd` because other tools share this format. `enabled: false` keeps the server off. The command starts directly, without a shell. A relative `cwd` starts in the session folder.

The command, arguments, environment values, and `cwd` expand `${NAME}` and `${NAME:-default}`. The default applies when the variable is not set and when it is empty. A variable without a value and without a default fails that server.

Both files accept `//` and `/* */` comments. yuke ignores a field that it does not know, on purpose: a file that other tools read can hold their own fields.

User servers start without a question. Project servers need approval: yuke asks with the options "Start" and "Don't start". yuke keeps a "Start" answer in `mcp-trust` in the [data folder](config.md), for that folder and that list of servers. A change of the list asks again. yuke does not keep "Don't start", so it asks again in the next session. Without an answering client, such as in `yuke -p`, only a kept approval starts project servers.

## Tools

A connected tool has a name such as `mcp__docs__search`. MCP tools are deferred: the model finds them through tool search before use. A server failure does not stop other servers.
