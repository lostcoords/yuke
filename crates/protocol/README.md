# protocol

The yuke protocol: JSON-RPC 2.0 messages between a yuke server and its clients. The messages take conventions of the
Agent Client Protocol (ACP): `"jsonrpc": "2.0"`, `noun/verb` methods, camelCase fields, and snake_case kinds. The protocol
is not ACP: for example, it has `session/input` in place of `session/prompt`, and a tool update uses a saved call position rather than a provider call id.

- Requests: `initialize`, `session/new`, `session/fork`, `session/load`, `session/input`, `session/set_settings`.
- Notifications: `session/cancel` from a client. `session/update`, `notice`, and `extension/event` from the server.
- `notice` is a message for the user, for the whole process or one session. `extension/event` is an event of a plugin.
  The plugin chooses its kind and its data, and it puts a version in the data when the shape changes. A client ignores
  an extension that it does not know. Neither is part of session history.
- `session/update` carries a saved event with its event number (`seq`), or a live update of a running turn.
- Live model updates belong to a draft and retain native block ids and boundaries. They exclude provider replay state.
- `draft_committed` carries one `eventNumber` and an array of original draft block ids, in saved block order.
  Array index `i` maps to block index `i` in that commit. A client replaces the whole draft.
- `draft_discarded` removes a draft without a confirmed replacement. It never removes saved history.
- `turn_unconfirmed` discards provisional tool state when the turn has no confirmed terminal commit. Reload the journal.
- Tool updates use `{ eventNumber, blockIndex }` within the enclosing session. The position names the saved call block.
- Saved commits still contain model context data. A visible-history projection is separate from that raw journal.
- An input has a source: `user`, or a `plugin` with a name. The inputs of yuke itself use names that start with `host:`.
- An input holds the content that the user saw. It holds model content only when the model reads other blocks.
- A saved commit starts with the model blocks of its consumed inputs. `consumed` gives the id, the source, and the block
  count of each input. It gives the content that the user saw only when that content differs.
- Each type holds one message. The protocol has no batches.

The session types of the messages (`SessionId`, `SessionSettings`, `SessionEvent`, and others) are the types that
`yuke-agent` and its stores save, so a client reads what the store saves.

## TypeScript

`bindings/` holds the TypeScript declarations of the messages, made by ts-rs from the Rust types. A test fails when the
files differ from the types. Write them again after a change of a type:

```sh
YUKE_WRITE_BINDINGS=1 mise exec -- cargo test -p yuke-protocol
```

The test exports a `u64` as a TypeScript `number`, because serde writes it as a JSON number. A `number` keeps an
integer exact up to 2^53; event numbers and ids stay far below that. The `ts` feature of `yuke-ai` and `yuke-engine`
gives their types to ts-rs. It is off by default, so only this test builds ts-rs.
