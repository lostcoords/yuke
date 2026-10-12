# protocol

The yuke protocol: JSON-RPC 2.0 messages between a yuke server and its clients. The messages take conventions of the
Agent Client Protocol (ACP): `"jsonrpc": "2.0"`, `noun/verb` methods, camelCase fields, and snake_case kinds. The protocol
is not ACP: for example, it has `session/input` in place of `session/prompt`, and a tool update carries `callId`.

- Requests: `initialize`, `session/new`, `session/fork`, `session/load`, `session/input`, `session/set_settings`.
- Notifications: `session/cancel` from a client, `session/update` from the server.
- `session/update` carries a saved event with its event number (`seq`), or a live update of a running turn.
- Each type holds one message. The protocol has no batches.

The session types of the messages (`SessionId`, `SessionSettings`, `SessionEvent`, and others) are the types that
`yuke-agent` and its stores save, so a client reads what the store saves.
