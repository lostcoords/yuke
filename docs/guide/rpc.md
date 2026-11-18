---
description: Embed yuke in your own app over the JSON-RPC protocol on stdio or a Unix socket.
---

# Embed with RPC

`yuke --rpc` serves the yuke protocol on stdin and stdout. Your app starts yuke as a child process, sends `initialize`, and then sends requests and reads updates. Each message is one line of JSON-RPC 2.0. The server ends when its stdin ends.

| Command | Behavior |
|---|---|
| `yuke --rpc` | Serve the protocol on stdin and stdout. |
| `yuke --rpc --listen unix://PATH` | Serve the clients of a Unix socket, one at a time. The sessions outlive each client. |
| `yuke --rpc --connect unix://PATH` | Join stdin and stdout to the server of a Unix socket. |

The protocol reference lists the requests, the updates, and their fields. It is in `~/.local/lib/yuke/protocol/README.md`, with the TypeScript types in `protocol/bindings/`. It is also on [GitHub](https://github.com/lostcoords/yuke/blob/main/crates/protocol/README.md).

Plugins load in this mode, but without the `tui` service. Their tools and engine hooks work as in the terminal UI.
