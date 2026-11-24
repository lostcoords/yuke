---
description: Connect local MCP servers over stdio and remote MCP servers over HTTP, and approve the servers of a project.
---

# MCP servers

yuke supports local MCP servers over stdio and remote MCP servers over Streamable HTTP. A remote server can take an API key in a header, or it can need an OAuth login.
yuke does not support the older SSE transport.

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

A local server entry uses `command`, `args`, `env`, `cwd`, and `enabled`. The file key stays `cwd` because other tools share this format. `enabled: false` keeps the server off. The command starts directly, without a shell. A relative `cwd` starts in the session folder.

A remote server entry uses `url`, `headers`, and `enabled`. yuke sends the headers on each request to the server:

```json
{
  "mcpServers": {
    "context7": {
      "url": "https://mcp.context7.com/mcp",
      "headers": { "CONTEXT7_API_KEY": "${CONTEXT7_API_KEY}" }
    }
  }
}
```

An entry needs exactly one of `command` and `url`. yuke reads `"type": "http"` and ignores it, so an entry of another tool works as it is. A header name or value that HTTP does not allow fails that server.

The command, arguments, environment values, `cwd`, URL, and header values expand `${NAME}` and `${NAME:-default}`. The default applies when the variable is not set and when it is empty. A variable without a value and without a default fails that server.

Both files accept `//` and `/* */` comments. yuke ignores a field that it does not know, on purpose: a file that other tools read can hold their own fields.

User servers start without a question. Project servers need approval: yuke asks with the options "Start" and "Don't start". The question shows each server as the file writes it: its command line or URL, and its folder, environment variables, and headers. yuke keeps a "Start" answer in `mcp-trust` in the [data folder](config.md), for that folder and that list of servers. A change of the list asks again. yuke does not keep "Don't start", so it asks again in the next session. Without an answering client, such as in `yuke -p`, only a kept approval starts project servers.

## OAuth login

A remote server that answers a request with `401` and names its OAuth metadata has the state `needsLogin`. yuke follows the MCP authorization spec of 2025-11-25: the login uses the authorization code flow with PKCE, and yuke keeps the tokens in `mcp-auth.json` in the [data folder](config.md). A token that ends soon refreshes before the next request. A login that the server ends, or that you remove, puts the server back in `needsLogin`.

In the TUI, run `/mcp`. The list shows each server of the session with its state: connected with its tool count, connecting, needs login, failed with its error, disabled, or not trusted. Choose a server that needs a login. A dialog names the host of the login page, and it has these keys:

- `o` opens the login page in your browser.
- `u` copies the URL of the login page.
- `p` takes the address that the browser ended on. Use it when the browser runs on another computer, for example over SSH, because that browser cannot reach yuke.
- `esc` cancels the login.

After you approve, the browser goes to a page on 127.0.0.1 that yuke serves, and the dialog closes with a notice. `/mcp logout SERVER` removes the stored login of a server, and the server then needs a login again. With `yuke -p`, a server that needs a login gives a notice that names `/mcp`, and the run goes on without its tools.

A client of the [protocol](rpc.md#mcp-servers) uses `mcp/login`.

An entry can set `oauth` when the authorization server needs a fixed client or a fixed redirect:

```json
{
  "mcpServers": {
    "tracker": {
      "url": "https://mcp.tracker.test/mcp",
      "oauth": { "clientId": "abc123", "callbackPort": 19876 }
    }
  }
}
```

- `clientId` is the client id that the authorization server gave to yuke. Without it, yuke uses its client id document when the authorization server accepts one, and else it registers a client at each login. An authorization server with neither needs this field.
- `callbackPort` is the port of the redirect on 127.0.0.1. Without it, the port is free.

An entry with an `authorization` header uses no OAuth.

## Tools

A connected tool has a name such as `mcp__docs__search`. MCP tools are deferred: the model finds them through tool search before use. A server failure does not stop other servers.
