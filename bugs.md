# Bugs

Status: current.

Known defects to fix. Newest first. The client (`src/tui/`) and the wire types (`lib/wire/`) are
separate; this file tracks DAEMON-side and cross-layer defects the client cannot fix alone.

## Note: a faulted session has no wire representation

**Severity:** low. **Area:** `src/daemon/run_task.zig`, `src/daemon/session_events.zig`, `lib/wire/session.zig`.

A failed terminal commit calls `faultSlot` (`run_task.zig:572`), which keeps the durable open marker so
startup `recoverOpen` closes the run. That part is correct. But the daemon emits no `run.done`, and
`finishSlot` then reports the session as idle. A connected client shows the run as still active forever.
`rt.faulted` also blocks the queue drain and eviction, so the session stays wedged until a restart.

**Effect:** a client spinner that never resolves, plus one leaked `SessionRuntime` per faulted session.

**Fix:** needs a protocol decision first. `wire.session.SessionActivity.state` is a closed set with no
faulted variant, so either add one, or recover in process instead of at the next start. A retry does not
help: the database is single-connection WAL, so a failed commit means disk or I/O failure, not lock
contention.

## Note: the database sets no busy_timeout

**Severity:** low. **Area:** `src/database/database.zig`.

`applyPragmas` sets `synchronous`, `wal_autocheckpoint`, `cache_size` and `foreign_keys`
(`database.zig:118-136`), but never `busy_timeout`. One process with one connection makes `SQLITE_BUSY`
close to unreachable today, which is why nothing has failed.

**Effect:** none observed. The mux and async child sessions both raise concurrency, so the margin gets
thinner.

**Fix:** one pragma. Cheap insurance, not urgent.

## Daemon: no authentication, and the permission value is inert

**Severity:** high. **Area:** `src/daemon/http.zig`, `src/daemon/run_task.zig`, `src/tools/exec.zig`.

The front door runs `admit` and nothing else (`http.zig:78`). `admit` compares the `Origin` and the
`Host` against the bind address, which stops a browser that DNS rebinding tricked. It authenticates
no caller. `docs/networking-plan.md` names the chain as `mark-private -> admit -> auth`, and the
`auth` stage is not ported.

Any process that opens `127.0.0.1:9853` can therefore create a session and run `exec`, which runs
`/bin/sh` (`src/tools/exec.zig`). The session carries a `permission` value of `strict`, `normal`, or
`yolo`; `handlers.zig:542` stores it and no tool and no run path ever reads it.

**Effect:** the daemon offers unauthenticated arbitrary code execution to every local process. The
permission model that the wire and the schema both describe does not exist.

**Fix:** two separate pieces. Port the front-door `auth` middleware and attach the authenticated
principal to `Connection`, so a later relay or proxy path fails closed. Then make the tools honor
`permission`. Both must land before any remote transport does.

## Wire v2: every downstream consumer is stale

**Severity:** high. **Area:** `../yuke-ts-sdk`, `../yuke-cloud`, `../yuke-client`.

Stage 6 batched every client-visible change into one daemon release, and nothing downstream moved.
`../yuke-ts-sdk/src/generated/types.ts` still declares `ProviderState` as `ready | needs_login` and a
`ModelInfo` with no `selector`; its checked-in `schema/wire.json` carries the same old contract, and
the SDK generator reads that file. `../yuke-cloud/config/wire.json` is another vendored copy, loaded
at boot by `config/initializers/wire.rb`. `../yuke-client` sends `model.id` where the daemon now needs
`model.selector`, so a model pick cannot resolve, and it compares a stored selector against `m.id`,
so reasoning levels and context metadata read as unknown.

**Effect:** the restructure is not shippable. A current client cannot select a model.

The device-code-only change widened it again: `AuthFlow.browser`, `AuthLoginResultBrowser`, and
`max_auth_url_bytes` are gone, and `../yuke-client/src/lib/settings/pages/ProviderSettingsPage.svelte`
still reads `result.auth_url` behind a `result.type === 'browser'` test that can no longer be true.

Stage 8 widened the gap. Every unimplemented method now answers `not_implemented` (-31022) instead
of `unknown_method`, `auth.logout` is renamed `auth.remove`, and it can answer `unknown_provider`
(-31023). Neither code exists in
the vendored schemas, so a generated consumer cannot name either one.
`docs/async-subagent-design.md` also still tells implementers to expect -32601.

**Fix:** vendor the regenerated `schema/wire.json` into both siblings, regenerate their types, then
make the client carry `selector` for its keys, its equality, and its patch. Correct the design doc.

## TUI: an unavailable provider still offers its models

**Severity:** medium. **Area:** `src/tui/js/defaults.js`, `src/daemon/registry.zig`.

The daemon lists the models of every provider, whatever its state (`registry.zig:108-115`), and the
TUI stores the provider list without reading it (`defaults.js:422-446`). The model picker iterates
every catalog model (`defaults.js:925-951`) with no branch for `needs_credential`, `needs_route`,
`expired`, or `revoked`. Stage 6 widened `ProviderState` from one value to four and no consumer
reads any of them.

**Effect:** a model whose provider has no credential looks selectable. The run then fails through
`run_task.zig:390-393`, so the user gets a failure instead of a reason.

**Fix:** join each model to its provider state, show the reason, and refuse the selection.

## Cloud: a server problem detail reaches a log line unfiltered

**Severity:** low. **Area:** `src/cloud/login.zig`, `src/cloud/protocol.zig`.

The control plane owns `ProblemWire.detail`. `describe` returns it, and login logs it with `{s}`
(`login.zig:185`, `login.zig:237`). The parser bounds the length but rejects no control byte, so a
detail such as `denied\nforged line` writes extra log lines.

**Effect:** a hostile control plane injects log lines that can imitate daemon output.

**Fix:** reject control bytes in the detail at the decode boundary, or log a fixed local string.

## Cloud: the device-code poller retries beyond RFC 8628

**Severity:** low. **Area:** `src/net/poller.zig`, `src/cloud/protocol.zig`.

`classify` retries 429, 409, and 5xx. RFC 8628 stops on any OAuth error other than
`authorization_pending` and `slow_down`, so these are yuke extensions.

**Fix:** record the retry extensions in the protocol document.

## Daemon: the `initialize` handshake is not enforced

**Severity:** medium. **Area:** `src/daemon/rpc.zig` (dispatch), `src/daemon/connection.zig`.

A connection can call `session.*`, `workspace.*`, and every other method without ever sending
`initialize`. The dispatch gates no method on it (`rpc.zig:54`), so a client that skips the handshake
still works. The `initialize` handler is the only place the daemon checks the protocol version
(`rpc.zig:58`, `bad_protocol`), so a client on a different protocol is never detected and the daemon
dispatches its frames anyway. A version mismatch can then silently misread the wire.

**Effect:** no protocol negotiation is enforced. An incompatible client connects and operates. The
yuke TUI currently relies on this by skipping `initialize`.

**Fix:** require `initialize` as the first call on a connection. Reject every other method with a
`not_initialized`/`bad_request` error until the connection initialized and the protocol matched. Then
fix the client to send `initialize` after the WebSocket handshake.

## Daemon: a failed run terminal can commit no error message

**Severity:** medium. **Area:** `src/daemon/run_task.zig`.

A failed run that ends through `commitFinal` commits an assistant message with `finish:"error"` and
`error:{type,message}`, so clients show the failure. But some failed terminals emit only
`run.done{failed}` and commit NO error message — for example the `max_rounds` path through
`finishRunOpen` (~run_task.zig:180), and a daemon abort mid-run.

**Effect:** the shared reducer folds `run.done` through `onCursor`, which advances the sequence and
discards the outcome. A client (the TUI) then shows no failure feedback for those runs, so the user
sees a message with no reply and no reason.

**Repro:** set `max_rounds = 1` on a session that needs a tool round. The run fails, but the transcript
shows no error.

**Fix:** make every failed terminal commit an assistant error message with `finish:"error"` and
`error`, the same as `commitFinal`. Then a failure is always a durable transcript message. (A
client-only alternative is to retain the last `run.done` outcome on the shared reducer and expose it,
but a daemon fix is cleaner and keeps the reducer simple.)
