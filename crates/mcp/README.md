# mcp

The MCP client of yuke, on [rmcp](https://crates.io/crates/rmcp). Each open session runs its own servers.

- The user servers are in `mcp.json` in the config folder, beside `config.json`. The file allows `//` and `/* */`
  comments.
- The project servers are in `.mcp.json` in the folder of the session. A project server replaces the user server of
  its name. It starts only after the user confirms the list with a question from `host:mcp`. yuke keeps a yes for that
  folder and that list in `mcp-trust` in the data folder; a changed list asks again, and a no asks again next time.
- The format is the `mcpServers` object of other agents: `{ "mcpServers": { "git": { "command": "uvx", "args":
  ["mcp-server-git"] } } }`. An entry can have `env`, `cwd` (from the session folder), and `"enabled": false`.
- An entry with `url` in place of `command` is a remote server over Streamable HTTP. Its `headers` go on each request.
  The requests use the `yuke-http` client of the app, so the servers share its connections. The client opens no GET
  stream.
- A remote server can need OAuth (the MCP authorization spec of 2025-11-25). A `401` answer that leads to protected
  resource metadata ends the start in `McpServerState::NeedsLogin`. An entry can have
  `"oauth": { "clientId": "…", "callbackPort": 19876 }`. A server whose `headers` hold an `authorization` uses no OAuth.
- `Servers::login` starts the login of a server in `NeedsLogin`. It gives a `PendingLogin` with the page of the user,
  and a future that ends after the tokens are stored and the server connects again. The page redirects to a listener
  on 127.0.0.1, or the client gives the address of the redirect to `PendingLogin::complete`. `Servers::logout` removes
  the stored login, and the server goes to `NeedsLogin`.
- The `Auth` of a server lives in its slot. When its login ends while the server runs (a refresh that the server
  refuses), the server stops and goes to `NeedsLogin`.
- The client id comes from `oauth.clientId`, else from the client id document of yuke when the authorization server
  accepts one, else from a new dynamic registration at each login. A public client has no secret.
- `mcp-auth.json` in the data folder holds one login for each server URL. Its lock file is `mcp-auth.lock`. A token
  that ends within one minute refreshes before the request, and a `401` answer with a token refreshes it once. A
  refresh that fails for now keeps the login: the request never left, or the server answered with an error that does
  not end a grant. A token that still lives serves the request then. A refresh that the server refuses, or whose request
  can have left, removes the login.
- The test server answers as an authorization server when `MCP_TEST_OAUTH` is set. The tests play the browser.
- `${NAME}` and `${NAME:-default}` in the command, the arguments, the environment values, the folder, the URL, and the
  header values take the value of the environment variable `NAME`. An empty value takes the default.
- Each tool of a server is a deferred tool named `mcp__<server>__<tool>`. A name over 64 characters, or a name that an
  earlier tool has, ends in a hash.
- The system prompt of each turn names each deferred tool in a `deferred_tools` section, so the model knows what
  `tool_search` can find. The saved prompt of the session does not hold the section. A plugin can change the section
  in `prompt.build`.
- The first turn waits until each server has started, and until the user answers the question of the project. In
  `yuke -p`, no client can answer, so the project servers stay off. A cancel of a call sends `notifications/cancelled` to the server.
- The tests need the feature `test-server`, which builds the MCP server of the tests. With `--http`, that server
  answers over HTTP.
