/*
The daemon package is the accept-side counterpart to `src/client`: it binds the
`libs:websocket` server reactor to the `wire` toolkit and speaks the v1
`initialize` exchange.

Logging uses `core:log` through `context.logger`. Libraries and the daemon emit
messages; the process that drives `nbio.run` / `run_until` owns the logger (nbio
callbacks inherit that context). Never log bearer tokens or Authorization values.

One port serves everything. `front_door.odin` composes a `libs:http/server` router:
cache-marking, admit, and auth middleware, then `GET /ws`, `GET`/`HEAD`/`PUT` on
`/blob/<hash>`. When a token is configured, middleware requires exactly one credential
source (`Authorization: Bearer` or `?token=`) before any route or method is disclosed.
A credential in the URL marks every response the application reaches private.
`GET /ws` upgrades into the WebSocket server; blob routes stream from or store into
`blob_dir`. The 64-lowercase-hex hash grammar keeps request paths inside that
directory. An unmatched path is a 404; a known path pattern with the wrong method is
a 405 carrying `Allow`.

Provider OAuth (`provider_auth.odin`) is also reactor-owned. WebSocket methods start,
cancel, list, and remove daemon-owned Codex credentials without putting a token on the
wire. Browser login temporarily binds Codex's loopback callback port; device login polls
with the provider-supplied interval. A single timer refreshes durable credentials five
minutes before expiry, merges optional rotated tokens, then offloads the atomic
`auth.json` replacement before publishing the new snapshot. Login, logout, refresh, and
credential writes are mutually exclusive, and shutdown cancels both the timer and any
secret-bearing transfer before destroying curl.

`blob.odin` holds the store behind those routes: the streamed upload, its digest
check against the URL hash, and the atomic publish, whose `fsync` and `rename` run on
a worker pool because neither has an nbio operation. `workspace.odin`, `git.odin`, and
`fs.odin` hold the path, repository, and directory-listing helpers the
`workspace.describe` and `workspace.browse` methods read; those two methods also run
on the shared worker pool (`workspace_jobs.odin`), since `get_absolute_path`, `stat`,
and `readdir` have no nbio operation and are directed by a peer-supplied path — running
them on the reactor would let one request, a FIFO with no writer or a hung mount, stall
every other connection. A completion resolves its connection through the `Conn_Ticket`
registry rather than a stored pointer, so a completion for a connection that has since
closed is simply dropped.

Admission runs before authentication and stops what a browser can be made to send with
an `Origin` header, and DNS-rebound requests naming this daemon by a `Host` other than
an IP literal it can legitimately be reached at. It does not stop a no-`Origin` browser
request — an `<img>` tag, a top-level navigation — from reaching 127.0.0.1: the
(optional, minimum 32 bytes when configured) bearer token is what stands between that
request and the routes. Admissible literals are loopback (including `::1` and
`::ffff:127.0.0.1`), the configured bind address, and the bare name `localhost`. The
unspecified address is rejected: `0.0.0.0` reaches a loopback-bound socket without
receiving the browser local-network gating that `127.0.0.1` does.

The transport (`libs:websocket`) is a single-threaded `core:nbio` callback
reactor; this driver never runs the loop. On each upgraded connection it waits
for the client's `initialize`, replies with an `Initialize_Result` snapshot, and
reaches Ready. A request that arrives after Ready is routed to its handler: the four
read-only methods (`session.list`, `catalog.list`, `workspace.describe`,
`workspace.browse`) plus `subscription.set` and `session.resync` run real handlers, and
every other method is answered with an `Unknown_Method` error rather than silently
dropped. `session.list` (`session_list.odin`) reads the registry: the page, its
continuation, and the total come from `src/daemon/store`, ordered newest first over the
`(updated_at_ms DESC, id DESC)` keyset the schema indexes. The cursor carries the
selection it was minted for, so one replayed against a different scope or population is
`Bad_Request` rather than a position in a set it never described. `revision` stays 0
because a `Session_Revision` counts this daemon's own index changes and a daemon that has
just started has made none; every row reads back idle, which also makes the `active` view
correctly empty rather than stubbed. With no catalog loaded, `catalog.list` still answers
the empty revision; the workspace methods read the real filesystem.

The pump (`pump.odin`) is the daemon's single seq authority and its only fan-out path.
`broadcast` derives the name from the closed payload union, then classifies it
with `wire.broadcast_name_class`. Before anything is minted or written, the frame is
built and checked: a payload that cannot encode (`Encode_Failed`) or one whose encoded
frame exceeds the transport's cap (`Frame_Too_Large`) is refused straight back to the
caller, never logged or sent — a truncated or over-cap row in the log would abort every
subscriber immediately and then fail every future resync of the session. A
`Durable_Gated` one is assigned `high_water + 1`,
written to the `src/daemon/store` log
with its derived marks, and only fanned out once the commit returns — clients never
observe state a crash then erases. `Live_Gated` and `Live_Droppable` are delivered to
subscribed connections and never logged; `Ungated` reaches every ready connection,
bypassing subscriptions and the log both. Send-path shedding applies to
`Live_Droppable` alone: a dropped delta shows up as an offset gap the receiver resyncs
from, whereas any other class failing to send closes the connection instead. A shed
delivery on a subscribed connection also queues `session.deltas_shed`, an advisory
marker sent point to point to that connection alone; it carries a cumulative shed
count, is itself droppable, and is never the recovery mechanism — resync remains that.
A `Seq_Conflict` from the store means our tracked high-water diverged from the log — a
daemon bug with no recovery, so the pump asserts and crashes rather than limping on with
a mark it can no longer trust. Every other store failure, including an append naming a
session with no registry row, drops the cached mark and degrades with `Store_Failed`:
only a genuine divergence of a real mark is a daemon bug. Exhausting the wire's finite
sequence range is an operating limit reported as `Sequence_Exhausted`, not an assertion
failure.

The event store's writer connection is reactor-thread only (`src/daemon/store`'s
discipline). Commits are synchronous SQLite calls under `synchronous=NORMAL`, so they
normally append to the WAL without an `fsync`. SQLite's default per-connection
autocheckpoint policy owns checkpoint scheduling; the daemon adds no maintenance
connection, timer, worker, or WAL-file lifetime control.

`session.resync` (`resync.odin`) is the protocol's only catch-up. Its available input
today is the five durable broadcasts. `message.committed` builds the transcript,
`transcript.truncated` removes its tail while leaving the finalized boundary where it
stands (a discarded id is finalized too), `config.changed` supplies the revisions the
page references, and `run.started` / `run.done` open and close the activity's run. An
open compaction run resyncs as `Activity_State_Compacting`, its reason carried from
`run.started` and no config attached. The session engine will add the live draft, queued
inputs, and authoritative session summary; their current absence is an implementation
boundary, not protocol semantics. `base_seq` is the session's committed high-water; a
session whose high-water is zero has never been written and is `Unknown_Session`. The
durable log must be contiguous from seq 1 for a session that has one: the fold reads
from the first row and treats any gap as `Corrupt_Log`; any future pruning of the log
needs a resync-aware design before rows can be dropped. The high-water read, the fold,
and the send all run to completion on the reactor thread, so the cut is one instant by
construction and no commit can interleave with it. The connection's WebSocket send queue
preserves whole-frame order, making the successful response a barrier: every session
broadcast queued before it is represented by the cut, while every broadcast queued after
it is newer and applies directly. Session state must therefore mutate before its broadcast
is queued. The finished cut is put through `wire.session_resync_result_validate` before it
is sent: a cut that fails, a log row the codec rejects, and a config revision no
`config.changed` announced are all daemon-side faults answered with `Internal`, never
shipped for the client to catch. Everything except the id, message count, and config fields
of the returned session summary is temporary until a session engine owns that state.

The script tier (`js.odin`, `js_fs.odin`) is one QuickJS runtime for the whole daemon,
hung off the `Daemon` and recovered through the runtime and context opaque pointers rather
than a global. Its three safety controls are set at startup — an allocation ceiling, a
stack ceiling, and an interrupt handler whose deadline bounds how long one entry may hold
the reactor — because every other connection waits behind a script that will not yield.
`yuke:fs` is the only host module installed, and only when a `js_root` is configured: with
nothing to root against, containment cannot be decided, so the module refuses to load
rather than reaching an unbounded filesystem. Its calls are read-only and return promises;
the blocking pass runs on the shared worker pool and its completion settles the promise
back on the loop. Containment is decided on the worker, after canonicalization, so `..` and
symlinks are resolved before the prefix test. `<js_root>/yuked.js` is evaluated at startup
when present, and a script that raises is a start failure for the same reason an unusable
`blob_dir` is one. The permission gate `docs/architecture-decisions.md` §5 puts at this
boundary needs a session to gate against and arrives with the tool set; path containment is
what is honest today.

`subscription.set` replaces a connection's subscription set wholesale, bounded by
`LIMITS.max_subscriptions`; the set is stored inline on the `Conn`, so gating allocates
nothing. Liveness (the transport's ping) and gap detection are distinct signals with
distinct recoveries (reconnect versus resync) and are never conflated here.

Per-connection state machine (the inverse of the client's):

  Awaiting_Initialize -> Ready -> Closed

  - The first frame must be a Text frame decoding to an `initialize` `Request` with
    `protocol == PROTOCOL_VERSION`. On success the daemon answers with an
    `Initialize_Result` and transitions Ready. A bad protocol version closes with
    `CLOSE.unsupported_protocol` (4000), distinguishable on the wire from
    `CLOSE.protocol_error` (1002).
  - A binary frame, a second `initialize` once Ready, any other method before Ready,
    a decode/validate failure, or trailing bytes after the JSON value all close the
    connection with `CLOSE.protocol_error`.
  - A well-formed `Request` after Ready is routed and answered with a `result`
    (a handled method) or an `error` (an unhandled method, or a per-method failure
    such as a bad workspace path).

Ownership:

  - Each accepted connection owns a `Conn` allocated in the transport `ws_on_open` and
    freed in the terminal callback (`ws_on_close`/`ws_on_error`). It holds a per-frame
    `scratch` arena, reset (not `free_all`'d — its blocks are retained for the
    connection's later frames) after each inbound frame; wire values decoded into
    it are non-owning borrows valid only for that frame.
  - The one datum retained from `initialize` is the client identity (`name`,
    `version`), kept as owned `strings.clone`s into the connection allocator for
    logging/identity and freed with the `Conn`. Nothing else survives the frame.
  - `Daemon.daemon_version`, `blob_dir`, and `auth_token` are owned clones freed by
    `destroy`. The database path is not retained: `store.open` copies what it
    needs, so the store handle itself records that a database is configured.
  - The store is opened by `start` before the transport adopts anything — a
    damaged or future-versioned database is a start failure, not a per-request one —
    and closed by `destroy` after the worker pool drains, since a drained
    completion runs on this loop and may still reach the front door. The pump's
    tracked high-water marks live and die with the store.
  - The QuickJS context is released after the same drain, and for a sharper reason: an
    in-flight `yuke:fs` job owns the settle functions of a live promise, so a completion
    running after the context was freed would settle into freed memory. `Js_Host.pending`
    counts those jobs and `js_destroy` asserts it reached zero.
*/

package daemon
