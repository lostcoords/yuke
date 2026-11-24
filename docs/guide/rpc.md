---
description: Embed yuke in your own app over the JSON-RPC protocol on stdio or a Unix socket.
---

# Embed with RPC

`yuke --rpc` serves the yuke protocol on stdin and stdout. Your app starts yuke as a child process, sends `initialize`, and then sends requests and reads updates. Each message is one line of JSON-RPC 2.0. The server ends when its stdin ends.

The messages take conventions of the Agent Client Protocol (ACP): `"jsonrpc": "2.0"`, `noun/verb` methods, and camelCase fields. The protocol is not ACP: for example, it has `session/input` in place of `session/prompt`, and a tool update uses a saved call position rather than a provider call id.

This guide is the reference of the protocol: the transports, the requests, the updates, and their fields. The TypeScript types of the messages are in `~/.local/lib/yuke/protocol/bindings/`. The source of the types and of the bindings is [`crates/protocol`](https://github.com/lostcoords/yuke/tree/main/crates/protocol).

Plugins load in this mode without the `tui` service.

## Transports

| Command | Behavior |
|---|---|
| `yuke --rpc` | Serve the protocol on stdin and stdout. |
| `yuke --rpc --listen unix://PATH` | Serve the clients of a Unix socket, one at a time. The sessions outlive each client. |
| `yuke --rpc --connect unix://PATH` | Join stdin and stdout to the server of a Unix socket. |

- Each message is one line. The end of stdin ends the server.
- A server on a socket keeps the sessions, turns, and jobs when a client leaves.
- A new client of the socket replaces the active client. The socket has mode 0600, so each process of the user can connect. The server holds `PATH.lock`, so a second server on the path fails.
- SIGINT, SIGTERM, and SIGHUP end the server. The active client gets the updates of the shutdown.
- Each type holds one message. The protocol has no batches: a line that is no JSON object gets -32600.
- A notice that comes while no client is connected goes to stderr. The server drops the session updates and the extension events of that interval. The store keeps the saved events, and `session/load` sends them again.

## Messages

- Each connection starts with `initialize`. Its `instanceId` is the id of the server process. A client that reconnects and gets another id talks to a new process, so the turns and jobs of the old process are gone. The client then loads each session again.
- Requests: `initialize`, `session/new`, `session/fork`, `session/load`, `session/close`, `session/input`, `session/removeInput`, `session/setSettings`, `session/rename`, `session/list`, `session/get`, `session/remove`, `auth/login`, `auth/cancelLogin`, `auth/logout`, `auth/setApiKey`, `catalog/list`, `job/list`, `job/stop`, `credential/update`, `interaction/respond`, `mcp/list`, `mcp/login`, `mcp/completeLogin`, `mcp/cancelLogin`, `mcp/logout`, `plugin/list`, `plugin/sync`, `plugin/check`, `plugin/apply`, `plugin/find`, `plugin/add`, `plugin/remove`, `profile/reload`, `blob/put`, `blob/get`.
- Notifications from a client: `session/cancel` and `session/background`. `session/background` moves each tool call of the session that waits for a job, such as a running command, to the background, and the turn goes on.
- Notifications from the server: `session/update`, `notice`, `extension/event`, `extension/cancel`, `auth/loginFinished`, and `mcp/loginFinished`.
- Server requests: `extension/request`. A client answers each one. It answers -32601 for a method or an extension that it does not know. The server numbers its requests from 1, apart from the ids of the client.
- `notice` is text for the user, for the whole process or one session. It is not part of session history.
- `profile/reload` loads the plugins of `config.json` and the providers of `providers.json` again. The open sessions stay open. Their process jobs go on, and their plugin jobs stop. It fails while a turn runs, or for a bad `config.json`, `plugins.lock`, or `providers.json`. A failure keeps the old plugins and providers. A plugin that does not load does not fail it, and a `notice` names it. The next request of an open session can miss the prompt cache when the reload changes its tools.

## Sessions

- A session is open after `session/new`, `session/fork`, or `session/load`, until `session/close` or the shutdown of the server. Many sessions can be open at once. The requests that use a live session need an open session, and `session/load` opens a closed one. A plugin can open a session too. A session that no client and no plugin holds closes by itself when it runs no turn: after 30 seconds, or after `sessionIdleMinutes` of `config.json` while a job runs. That close stops its jobs.
- A session row holds the facts of the session (`sessionId`, `model`, `folder`, `title?`, `createdAt`, `updatedAt`, `forkOf?`, `parent?`) and its `state` now: `closed`, `idle`, or `running`. `session/get` gives the row of one session.
- A text message or an explicit rename supplies the title. Initial message text normalizes whitespace and truncates the title to 200 Unicode scalar values. `session/rename { sessionId, title }` changes the title of an open or closed session and answers `{}` without a session update.
- `session/new` can name a `parent`, and each row of the session then holds that `parent`. A `session/list` without `parent` shows only the sessions without a parent. A `session/list` with `parent` shows the children of that session. A `session/remove` removes the children and their children too, and it fails while one of these sessions is open. A fork has no parent. A fork starts with the title `Fork — <source title>` when the source has a title, bounded to 200 Unicode scalar values. A fork without a source title has no title until its first message.
- `session/list` gives the saved sessions in pages, newest event first, of every folder or of one `folder`. A page has 50 rows, or `limit` from 1 to 100. Its `nextCursor` is an opaque text that continues the same list. The pages are no snapshot: a session that moves to the front between two pages comes only in a new list.
- `session/remove` deletes a saved session with its events, pending inputs, and blobs. Its forks stay. It fails for an open session, so a client closes it first with `session/close`. That method stops the turn and the jobs. A removal fails with -32003 while another writer holds the session.
- The settings of a session (model, request settings, folder) do not change during a turn: `session/setSettings` fails while a turn runs or input waits.
- `blob/put { sessionId, data }` decodes the base64 `data` and saves the bytes in a saved session. It answers the blob `{ digest, len }` for a media block of an input. `blob/get { sessionId, blob }` answers the bytes as base64 `{ data }`, also for a closed session. It reads the blob by its digest, and fails with -32007 when the session has no such blob. `session/remove` deletes the blobs.
- `session/load` sends the session as updates: the saved events, a `state` update, an `inputAccepted` for each pending input, a `job` update for each running job, an `interactionRequested` for each open question, and an `mcpServer` update for each MCP server. Then come the live updates of the load time that these do not hold, and the empty answer. A client applies the updates in order. It drops a saved event that it has (by `seq`), an `inputAccepted` that it has (by `inputId`), and an `interactionRequested` that it has (by `interactionId`). The server disconnects a client that falls behind. On stdin and stdout, that ends the server. On a socket, the client connects and loads again.

## Turns and updates

- `session/input` starts a turn when the session is idle. During a turn, an input joins the turn at its next round. A `state` update tells when a turn runs. `session/load` starts no turn.
- During a turn, a client can add and remove inputs, cancel the turn, move its waiting tool calls to the background, close the session, and list and stop jobs.
- `session/update` carries a saved event with its event number (`seq`), or a live update of a running turn.
- The queue: `inputAccepted` and `inputRemoved` are live updates. A queued input leaves the queue when a saved commit names it in `consumed`, or when `inputRemoved` names it.
- Live model updates belong to a draft and retain native block ids and boundaries. They exclude provider replay state.
- `draftCommitted` carries one `eventNumber` and an array of original draft block ids, in saved block order. Array index `i` maps to block index `i` in that commit. A client replaces the whole draft.
- `draftDiscarded` removes a draft without a confirmed replacement. It never removes saved history.
- `turnUnconfirmed` discards provisional tool state when the turn has no confirmed terminal commit. Reload the journal. Before the next turn, the server ends a turn that the store holds as open, and sends that commit as a saved event.
- Tool updates use `{ eventNumber, blockIndex }` within the enclosing session. The position names the saved call block.
- Saved commits still contain model context data. A visible-history projection is separate from that raw journal.
- After a cancelled or failed turn, the next turn gets a notification from `host:session` after its other inputs.

## Inputs

- An input has a source: `user`, or a `plugin` with a name. The inputs of yuke itself use names that start with `host:`.
- An input has a kind: `message` for a text of a person, or `notification` for a notice that no person wrote. A client shows a notification as a notice. The model reads a notification in `<system_notification plugin="name">`.
- An input holds the content that the user saw. It holds model content only when the model reads other blocks.
- A saved commit starts with the model blocks of its consumed inputs. `consumed` gives the id, the source, the kind, and the block count of each input. It gives the content that the user saw only when that content differs.

## Questions

A plugin or yuke asks the user with an `interactionRequested` live update: a `questions` request with its `source`. Each question has options, `other` for a typed answer, or both. The client answers all questions at once with `interaction/respond`, or cancels the whole request with `cancelled`. An answer that does not fit its questions, or an unknown id, fails the request. An `interactionClosed` update ends each request: an answer, an abort of the asker, or the close of the session. A run without a client (`yuke -p`) answers each request with no answer.

## Jobs

The background jobs of a session run while the session is open. `job/list` lists them. A `job` update holds the whole job at its start and at its end. `job/stop` waits for the end, and its `job` update comes first. `session/close` stops the jobs of the session. A client that wants a warning first reads `job/list`. A process job that ends by itself also sends an input from `host:jobs`, after its `job` update. A plugin job sends an input from its plugin only when the plugin ends it with a report. The `state` of a job is `running`, `ended`, or `stopped`. Its `kind` is `process` (`command`, `log`, `exitCode`) or `plugin` (`plugin`).

## Credentials and models

- `auth/login { provider }` starts the device login of a provider with a login flow, and answers its `loginId`, `verificationUrl`, and `userCode` at once. A login in progress of the provider ends as `cancelled` first. The client shows the page and the code. The server polls the provider, saves the login in `auth.json`, and sends `auth/loginFinished { loginId, provider, outcome }`: `succeeded`, `cancelled`, or `failed { error }`.
- `auth/cancelLogin { loginId }` asks a login in progress to stop. A poll that got the approval still saves the login, so the outcome tells what happened. A client that missed the notification, for example after a reconnect, reads the state with `catalog/list`. No answer and no notification holds a token.
- `auth/logout { provider }` removes what yuke stored for a provider: its login or its API key in `auth.json`, and the token of `credential/update`. A login in progress of the provider ends first, and the removal comes after it. yuke revokes no token at the provider. `yuke logout PROVIDER` changes `auth.json` only: a running server keeps a token of `credential/update`.
- `auth/setApiKey { provider, apiKey }` stores the key in `auth.json` for a provider with an API key variable. The new key replaces the stored key and wins over the variable. Each session takes the key at its next turn.
- `credential/update` gives the server an `accessToken` for a provider with a login flow. An orchestrator can refresh one account and update many servers. The server keeps the token only in memory and never refreshes it. It uses the token from the next model request on, also in a running turn. After the first update, the server never uses the stored login of the provider.
- `catalog/list` gives the providers that are ready now, or every provider with `all: true`. Each provider has its state (`ready` with its credential, `needsApiKey` with the variable, or `needsLogin`) and its models: limits, prices, tool support, input kinds, and the reasoning choices with the reasoning settings that a session sends for each. A provider is ready when its API key variable holds UTF-8 text that is not empty, when it has a stored key, a login, or a pushed token, or when it needs no key. The server does not test the credential. A client asks again after `profile/reload`.

## Plugins

- `plugin/list` gives each plugin of `config.json` with its `source`, its `state` on disk, and its `load`. The `source` is the folder text of a local plugin, or the `{ git, folder?, ref? }` object of a Git plugin. The `state` kind is `local`, `notInstalled` with the `commit?` of the lock, or `installed` with its `commit`. The `load` kind is `loaded`, `pending` until the next `profile/reload`, or `failed` with its `error`. It uses no network.
- `plugin/sync` installs the commits of `plugins.lock` and locks each new Git plugin at the commit of its ref.
- `plugin/check { target }` takes `{ "kind": "all" }` or `{ "kind": "names", "names": [...] }`. It installs each new commit of an installed Git plugin, and answers the `changes` with their `log`. It checks the others, and answers each plugin that it cannot check in `failed` with its `error`.
- `plugin/apply { plugins }` writes the `{ source, commit }` of each plugin into `plugins.lock`. It fails for a plugin that the lock does not have.
- `plugin/find { git, ref? }` answers the `plugins` of a repository: the `name` and the `folder?` of each `plugin.json`.
- `plugin/add { git, names?, ref? }` adds those plugins to `config.json` by name, installs them, and locks them. It answers each one with its `name`, `source`, and `commit`. Without `names`, the repository must have one plugin.
- `plugin/remove { name }` removes a plugin from `config.json` and `plugins.lock`.
- Each edit keeps the comments of `config.json`. Git never asks for a password, so a private repository needs a credential helper or an ssh agent. A new commit loads at `profile/reload`.

## Plugin events and requests

- `extension/event` is an event of a plugin, for the whole process or one session. `extension` is the name that the host gives the plugin. The plugin chooses `event` and `data`, and it puts a version in `data` when the shape changes. A client ignores an extension that it does not know. The event is not part of session history, and `session/load` does not send it again. The events and notices of the plugins keep their order, but they have no order against the session updates.
- `extension/request { sessionId, extension, request, data }` is a request of a plugin to the active client. The plugin chooses `request` and `data`, and the client chooses the result or the error. With no client, the request fails at once in the plugin. A new client or a disconnect fails each request that waits, and no client gets it again. The server sets no time limit. The request has no order against the events, the notices, and the session updates.
- `extension/cancel { requestId }` tells the client that the plugin stopped waiting: a cancel of the plugin or the close of its session. The client can stop its work. Its answer is optional, and the server ignores it. An answer and a cancel can cross, so a client ignores a cancel of a request that it answered.

## MCP servers

Each open session runs the servers of the user config and of `.mcp.json` in its folder. An `mcpServer` live update holds the whole state of one server, with its `source` (`user` or `project`). Its `state` has the kind `connecting`, `connected` with its tool count, `failed` with its error, `disabled`, `untrusted`, or `needsLogin` (a remote server that needs an OAuth login). `mcp/list` gives each server of a session.

A client logs in to a server in the state `needsLogin` with these requests. The login of a server uses the browser of the user and a listener of the server on 127.0.0.1:

- `mcp/login { sessionId, server }` answers `{ loginId, url }` at once. A login in progress of the same server ends as `cancelled` first. The client opens `url`. After the approval, the browser goes to the listener, and the server stores the tokens. A client on another computer, for example over SSH, cannot reach the listener.
- `mcp/completeLogin { loginId, redirectUrl }` finishes the login with the address that the browser ended on, for a client that cannot reach the listener. An address that is not the redirect of this login is an error (`-32602`), and the login goes on to wait.
- `mcp/cancelLogin { loginId }` asks a login in progress to stop. A login whose redirect came already finishes: the server stores the tokens, and the outcome is `succeeded`.
- The server sends `mcp/loginFinished { loginId, sessionId, server, outcome }` when the login ends: `succeeded`, `cancelled`, or `failed { error }`. After a success, the server connects again, and the `mcpServer` updates show `connecting` and then `connected` or `failed`. The close of the session ends its login as `cancelled`.
- `mcp/logout { sessionId, server }` removes the stored login of a remote server. A login in progress of the server ends first, as `cancelled`. A server that had a login stops, and its state is `needsLogin`.

A `loginId` that is not in progress, for example after the end of its login, is the error `-32006`. A server that does not exist in the session, a server that needs no login (for `mcp/login`), and a server that is not remote (for `mcp/logout`) are the error `-32602`. A server whose OAuth metadata does not allow a login, and a stored login that does not read or write, are internal errors with the reason as their text.

Project servers start only after the user confirms them. yuke asks one question from `host:mcp`, with the options "Start" and "Don't start", and keeps a start for that folder and that list of servers. See [MCP servers](mcp.md).

## Shapes

- A union of objects has the tag `kind`, as in `{ "kind": "userText", "text": "hi" }`. Only a union of a text and an object, as the `source` of a plugin, has no tag.
- Each method, field, tag value, and enum value is camelCase. A method is `noun/verb`, as in `session/setSettings`.
- A failure is the kind `failed` with the text `error`.
- An absent field is left out. No value is `null`, apart from the `id` of a response to a message without a readable id, as JSON-RPC asks.
- A flag whose absence means `false` is left out when it is `false`.
- A time is in milliseconds since the Unix epoch, and its name ends in `At` (`createdAt`, `expiresAt`). A duration names its unit (`durationMs`, `afterMs`).

## Errors

A request fails with one of these codes. The `message` is text for a person, and a client does not parse it.

| Code   | Constant                | Meaning                                                                 |
| ------ | ----------------------- | ----------------------------------------------------------------------- |
| -32700 | `PARSE_ERROR`           | The line is no JSON.                                                    |
| -32600 | `INVALID_REQUEST`       | The message is no JSON object, or it has no valid `jsonrpc`, `id`, or `method`. |
| -32601 | `METHOD_NOT_FOUND`      | The server has no such method.                                          |
| -32602 | `INVALID_PARAMS`        | The params do not fit the method, or a value of them cannot work.       |
| -32603 | `INTERNAL_ERROR`        | The server failed.                                                      |
| -32002 | `SESSION_NOT_FOUND`     | The session is not open, or the store has no such session.              |
| -32003 | `SESSION_OWNED`         | Another writer holds the session.                                       |
| -32004 | `JOB_NOT_FOUND`         | The session runs no such job.                                           |
| -32005 | `INTERACTION_NOT_FOUND` | The session has no such open question.                                  |
| -32006 | `LOGIN_NOT_FOUND`       | No such login is in progress.                                           |
| -32007 | `BLOB_NOT_FOUND`        | The session has no blob with this digest.                               |
| -32008 | `SESSION_OPEN`          | The session is open, so it cannot be removed. Close it first.           |
| -32009 | `TURN_ACTIVE`           | A turn runs or input waits. Send the request again after the turn ends. |
| -32010 | `TRY_AGAIN`             | Another call opens or closes the session, or a reload runs. Send the request again after it ends. |
| -32011 | `STOPPING`              | The server shuts down.                                                  |
| -32012 | `NOT_INITIALIZED`       | The connection sent no `initialize` yet.                                |

## Compatibility

- A client ignores each field, kind, method, notification, and error code that it does not know.
- A new field, kind, method, notification, or error code does not change `PROTOCOL_VERSION`.
- A removal, a rename, or a change of the meaning or the type of an existing item increases `PROTOCOL_VERSION`.
- `initialize` gives the version that the server selects. A client that does not speak that version disconnects.
