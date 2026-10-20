# mcp

The MCP client of yuke, on [rmcp](https://crates.io/crates/rmcp). Each open session runs its own servers.

- The user servers are in `mcp.json` in the config folder, beside `config.json`. The file allows `//` and `/* */`
  comments.
- The format is the `mcpServers` object of other agents: `{ "mcpServers": { "git": { "command": "uvx", "args":
  ["mcp-server-git"] } } }`. An entry can have `env`, `cwd` (from the session folder), and `"enabled": false`.
- `${NAME}` and `${NAME:-default}` in the command, the arguments, the environment values, and the folder take the
  value of the environment variable `NAME`. An empty value takes the default.
- yuke starts stdio servers only. An entry with a `url` fails with a message.
- Each tool of a server is a deferred tool named `mcp__<server>__<tool>`. A name over 64 characters, or a name that an
  earlier tool has, ends in a hash.
- A turn waits until each server has started. A cancel of a call sends `notifications/cancelled` to the server.
- The tests need the feature `test-server`, which builds the MCP server of the tests.
