# yuke-protocol

The types that a yuke server and its clients speak: JSON-RPC 2.0 messages with serde, in the conventions of the Agent
Client Protocol. The session types of the messages (`SessionId`, `SessionSettings`, `SessionEvent`, and others) are the
types that `yuke-agent` and its stores save, so a client reads what the store saves.

The crate holds no server and no transport. The behavior of the server (the transports, the requests, the updates, the
errors, and the compatibility rules) is in the guide `docs/guide/rpc.md` (Embed with RPC).

## Modules

- Messages: `Request`, `Response`, `Notification`, `ClientRequest`, `ServerRequest`, and the params and results of each
  method.
- Sessions: ids, settings, rows, titles, and the saved events.
- Updates: the live updates of a running turn, and the updates of jobs, questions, and MCP servers.
- Constants: `PROTOCOL_VERSION`, and the error codes as constants of `ResponseError`.

## TypeScript

`bindings/` holds the TypeScript declarations of the messages, made by ts-rs from the Rust types. A test fails when the
files differ from the types. Write them again after a change of a type:

```sh
YUKE_WRITE_BINDINGS=1 mise exec -- cargo test -p yuke-protocol
```

`ClientRequestResults.ts` maps each client method to its result type, from the same table as `ClientRequest`. A
`Response` holds a bare `result`, so a client reads its type from the method of the request. In Rust, the server
answers with a `ServerResult`, so the compiler checks each answer against the table.

`constants.ts` holds `PROTOCOL_VERSION` and `ErrorCode`, the error codes of the table in the guide.

Each variant of a union holds a type of its own name, so a client can name the type of one update, as `ToolStarted`.
Each import names its file with the `.ts` extension, so Node and Bun load the files as they are. The docs speak of
the JSON: a test turns each rustdoc link into code text, and drops a link in parentheses to a Rust path.

The test exports a `u64` as a TypeScript `number`, because serde writes it as a JSON number. A `number` keeps an
integer exact up to 2^53; event numbers and ids stay far below that. The `ts` feature of `yuke-ai` and `yuke-engine`
gives their types to ts-rs. It is off by default, so only this test builds ts-rs.
