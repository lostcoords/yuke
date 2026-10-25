# protocol

The yuke protocol: JSON-RPC 2.0 messages between a yuke server and its clients. The messages take conventions of the
Agent Client Protocol (ACP): `"jsonrpc": "2.0"`, `noun/verb` methods, camelCase fields, and snake_case kinds. The protocol
is not ACP: for example, it has `session/input` in place of `session/prompt`, and a tool update uses a saved call position rather than a provider call id.

- Transports: each message is one line. `yuke --rpc` serves one client on stdin and stdout. The end of stdin ends the
  server. `yuke --rpc --listen unix://PATH` serves the clients of a Unix socket, one at a time. The sessions, turns,
  and jobs outlive each client. `yuke --rpc --connect unix://PATH` joins stdin and stdout to such a socket.
- A new client of the socket replaces the active client. The socket has mode 0600, so each process of the user can
  connect. The server holds `PATH.lock`, so a second server on the path fails.
- SIGINT, SIGTERM, and SIGHUP end the server. The active client gets the updates of the shutdown.
- Requests: `initialize`, `session/new`, `session/fork`, `session/load`, `session/close`, `session/input`,
  `session/remove_input`, `session/set_settings`, `session/list`, `session/get`, `session/remove`, `job/list`,
  `job/stop`, `credential/update`, `interaction/respond`, `mcp/list`, `profile/reload`.
- `session/list` gives the saved sessions in pages, newest event first, of every folder or of one `cwd`. A page has
  50 rows, or `limit` from 1 to 100. Its `nextCursor` continues the same list. The pages are no snapshot: a session
  that moves to the front between two pages comes only in a new list. `session/get` gives the row of one session.
- `session/remove` deletes a saved session with its events, pending inputs, and blobs. Its forks stay. It fails for an
  open session, so a client closes it first with `session/close`. That method stops the turn and needs
  `stopJobs: true` when jobs run. It fails with -32003 while another writer holds the session.
- A row holds the saved facts (model, folder, preview, times, fork source) and the activity now: `closed`, `idle`, or
  `running`. The preview is the trimmed user text of the first message input with text, at most 200 characters.
- `profile/reload` loads the plugins of `config.json` and the providers of `providers.json` again. The open sessions
  stay open, and their jobs go on. It fails while a turn runs, and a failure keeps the old plugins and providers. The
  next request of an open session can miss the prompt cache when the reload changes its tools.
- Each connection starts with `initialize`. Its `instanceId` is the id of the server process. A client that
  reconnects and gets another id talks to a new process, so the turns and jobs of the old process are gone. The client
  then loads each session again.
- `credential/update` gives the server an `accessToken` for a provider with a login flow. An orchestrator can refresh
  one account and update many servers. The server keeps the token only in memory and never refreshes it. It uses the
  token from the next model request on, also in a running turn. After the first update, the server never uses the
  stored login of the provider.
- A session is open after `session/new`, `session/fork`, or `session/load`, until `session/close` or the shutdown
  of the server. Many sessions can be open at once. The requests that use a live session need an open session, and
  `session/load` opens a closed one.
- The background jobs of a session run while the session is open. `job/list` lists them. A `job` update holds the
  whole job at its start and at its end. `job/stop` waits for the end, and its `job` update comes first.
  `session/close` fails while jobs run, unless it has `stopJobs: true`. A job that ends by itself also sends an input
  from `host:jobs`, after its `job` update.
- Notifications: `session/cancel` from a client. `session/update` and `notice` from the server.
- `notice` is a message for the user, for the whole process or one session. It is not part of session history.
- `session/update` carries a saved event with its event number (`seq`), or a live update of a running turn.
- The queue: `input_accepted` and `input_removed` are live updates. A queued input leaves the queue when a saved
  commit names it in `consumed`, or when `input_removed` names it.
- Turns: `session/input` starts a turn when the session is idle. During a turn, an input joins the turn at its next
  round. A `state` update tells when a turn runs. `session/load` starts no turn.
- During a turn, a client can add and remove inputs, cancel the turn, close the session, and list and stop jobs. The
  settings (model, request settings, folder) do not change: `session/set_settings` fails while a turn
  runs or input waits.
- `session/load` sends the session as updates: the saved events, a `state` update, an `input_accepted` for each
  pending input, a `job` update for each running job, an `interaction_requested` for each open question, and an
  `mcp_server` update for each MCP server. Then come the live updates of the load time that these do not hold, and the
  empty answer. A client applies the updates
  in order. It drops a saved event that it has (by `seq`), an `input_accepted` that it has (by `inputId`), and an
  `interaction_requested` that it has (by `interactionId`). The server disconnects a client that falls behind. On
  stdin and stdout, that ends the server. On a socket, the client connects and loads again.
- A notice that comes while no client is connected goes to stderr. The server drops the session updates of that
  interval. The store keeps the saved events, and `session/load` sends them again.
- Live model updates belong to a draft and retain native block ids and boundaries. They exclude provider replay state.
- `draft_committed` carries one `eventNumber` and an array of original draft block ids, in saved block order.
  Array index `i` maps to block index `i` in that commit. A client replaces the whole draft.
- `draft_discarded` removes a draft without a confirmed replacement. It never removes saved history.
- `turn_unconfirmed` discards provisional tool state when the turn has no confirmed terminal commit. Reload the journal.
  Before the next turn, the server ends a turn that the store holds as open, and sends that commit as a saved event.
- Tool updates use `{ eventNumber, blockIndex }` within the enclosing session. The position names the saved call block.
- Saved commits still contain model context data. A visible-history projection is separate from that raw journal.
- An input has a source: `user`, or a `plugin` with a name. The inputs of yuke itself use names that start with `host:`.
- An input has a kind: `message` for a text of a person, or `notification` for a notice that no person wrote. A client
  shows a notification as a notice. The model reads a notification in `<system_notification plugin="name">`.
- After a cancelled or failed turn, the next turn gets a notification from `host:session` after its other inputs.
- An input holds the content that the user saw. It holds model content only when the model reads other blocks.
- A saved commit starts with the model blocks of its consumed inputs. `consumed` gives the id, the source, the kind, and
  the block count of each input. It gives the content that the user saw only when that content differs.
- Questions: a plugin or yuke asks the user with an `interaction_requested` live update: a `confirm`, a `select`, or
  an `input`, with its `source`. The client answers with `interaction/respond`, or with `canceled`. A wrong kind, an
  option that the question lacks, or an unknown id fails the request. An `interaction_closed` update ends each
  question: an answer, an abort of the asker, or the close of the session. A run without a client (`yuke -p`) answers
  each question with no answer.
- MCP servers: each open session runs the servers of the user config and of `.mcp.json` in its folder. An
  `mcp_server` live update holds the whole state of one server, with its `source` (`user` or `project`): `connecting`,
  `connected` with its tool count, `failed` with its error, `disabled`, or `untrusted`. `mcp/list` gives each server
  of a session.
- Project servers start only after the user confirms them. yuke asks with a `confirm` from `host:mcp`, and keeps a
  yes for that folder and that list of servers.
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
