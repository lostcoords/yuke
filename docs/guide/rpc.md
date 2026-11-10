---
description: Embed yuke in your own app over the JSONL protocol on stdio or a Unix socket.
---

# Embed with RPC

`yuke --rpc` serves the yuke protocol on stdin and stdout. Your app starts yuke as a child process, writes requests, and reads updates as JSON lines.

## Start the server

| Command | Behavior |
|---|---|
| `yuke --rpc` | Serve the protocol on stdin and stdout. |
| `yuke --listen unix://PATH` | Serve the clients of a Unix socket, one at a time. The sessions outlive each client. |
| `yuke --connect unix://PATH` | Join stdin and stdout to the server of a Unix socket. |

The [protocol reference](https://github.com/lostcoords/yuke/blob/main/crates/protocol/README.md) lists the requests, the updates, and their fields. For example, `catalog/list` lists the providers, and `auth/set_api_key` stores an API key.

## Plugins in protocol mode

Plugins load in this mode. Their tools and engine hooks work as in the terminal UI. The TUI service is absent, so terminal commands, keys, and views do not load. See [Plugins](plugins.md).

Your app gets what a terminal user sees, and answers what a terminal user answers:

- A question from yuke or from `s.ask` comes as an `interaction_requested` update. The client answers it.
- `s.request` sends an `extension/request` to the active client. The client answers each one.
- `ctx.emit` and `s.emit` send an `extension/event`.
- A notice comes as a `notice` message.
