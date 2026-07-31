/*
The daemon package is the accept-side counterpart to `src/client`: it binds the
`libs:websocket` server reactor to the `wire` toolkit and speaks the v1
`initialize` exchange.

Logging uses `core:log` through `context.logger`. Libraries and the daemon emit
messages; the process that drives `nbio.run` / `run_until` owns the logger (nbio
callbacks inherit that context). Never log bearer tokens or Authorization values.

One port serves everything. `front_door.odin` composes a `libs:http/server` router:
admit and auth middleware, then `GET /ws`, `GET`/`PUT` on `/blob/<hash>`. When a
token is configured, middleware requires exactly one credential source
(`Authorization: Bearer` or `?token=`) before any route or method is disclosed.
`GET /ws` upgrades into the WebSocket server; blob routes stream from or store into
`blob_dir`. The 64-lowercase-hex hash grammar keeps request paths inside that
directory. An unmatched path is a 404; a known path pattern with the wrong method is
a 405 carrying `Allow`.

Admission runs before authentication and refuses what a browser can be made to send:
any `Origin`, and any `Host` that does not address this daemon by IP literal. Admissible
literals are loopback (including `::1` and `::ffff:127.0.0.1`), the configured bind
address, and the bare name `localhost`. The unspecified address is rejected: `0.0.0.0`
reaches a loopback-bound socket without receiving the browser local-network gating that
`127.0.0.1` does.

The transport (`libs:websocket`) is a single-threaded `core:nbio` callback
reactor; this driver never runs the loop. On each upgraded connection it waits
for the client's `initialize`, replies with an `Initialize_Result` snapshot, and
reaches Ready. A request that arrives after Ready is routed to its handler: the four
read-only methods (`session.list`, `catalog.list`, `workspace.describe`,
`workspace.browse`) plus `subscription.set` and `session.resync` run real handlers, and
every other method is answered with an `Unknown_Method` error rather than silently
dropped. With no session engine or catalog loaded yet, `session.list` returns an empty
page and `catalog.list` the empty revision; the workspace methods read the real
filesystem.

The pump (`pump.odin`) is the daemon's single seq authority and its only fan-out path.
`daemon_broadcast` derives the name from the closed payload union, then classifies it
with `wire.broadcast_name_class`. A `Durable_Gated` one is assigned `high_water + 1`,
written to the `src/daemon/store` log
with its derived marks, and only fanned out once the commit returns — clients never
observe state a crash then erases. `Live_Gated` and `Live_Droppable` are delivered to
subscribed connections and never logged; `Ungated` reaches every ready connection,
bypassing subscriptions and the log both. Send-path shedding applies to
`Live_Droppable` alone: a dropped delta shows up as an offset gap the receiver resyncs
from, whereas any other class failing to send closes the connection instead. A
`Seq_Conflict` from the store means our tracked high-water diverged from the log — a
daemon bug with no recovery, so the pump asserts and crashes rather than limping on
with a mark it can no longer trust. Any other store failure instead drops the cached
mark and degrades with `Store_Failed`.
Exhausting the wire's finite sequence range is an operating limit reported as
`Sequence_Exhausted`, not an assertion failure.

The event store's writer connection is reactor-thread only (`src/daemon/store`'s
discipline). Commits are synchronous SQLite calls under `synchronous=NORMAL`, so they
normally append to the WAL without an `fsync`. SQLite's default per-connection
autocheckpoint policy owns checkpoint scheduling; the daemon adds no maintenance
connection, timer, worker, or WAL-file lifetime control.

`session.resync` (`resync.odin`) is the protocol's only catch-up. Its available input
today is the five durable broadcasts. `message.committed` builds
the transcript, `transcript.truncated` removes its
tail while leaving the finalized boundary where it stands (a discarded id is finalized
too), `config.changed` supplies the revisions the page references, and `run.started` /
`run.done` open and close the activity's run. The session engine will add the live
draft, queued inputs, and authoritative session summary; their current absence is an
implementation boundary, not protocol semantics. `base_seq` is the
session's committed high-water; a session whose high-water is zero has never been
written and is `Unknown_Session`. The high-water read, the fold, and the send all run
to completion on the reactor thread, so the cut is one instant by construction and no
commit can interleave with it. The finished cut is put through
`wire.session_resync_result_validate` before it is sent: a cut that fails, a log row the codec
rejects, and a config revision no `config.changed` announced are all daemon-side faults
answered with `Internal`, never shipped for the client to catch. Everything except
the id, message count, and config fields of the returned session summary is temporary
until a session engine owns that state.

`subscription.set` replaces a connection's subscription set wholesale, bounded by
`LIMITS.max_subscriptions`; the set is stored inline on the `Conn`, so gating allocates
nothing. Liveness (the transport's ping) and gap detection are distinct signals with
distinct recoveries (reconnect versus resync) and are never conflated here.

Per-connection state machine (the inverse of the client's):

  Awaiting_Initialize -> Ready -> Closed

  - The first frame must be a Text frame decoding to an `initialize` `Request` with
    `protocol == PROTOCOL_VERSION`. On success the daemon answers with an
    `Initialize_Result` and transitions Ready. A bad protocol version closes with
    `CLOSE.unsupported_protocol`.
  - A binary frame, a second `initialize` once Ready, any other method before Ready,
    a decode/validate failure, or trailing bytes after the JSON value all close the
    connection with `CLOSE.protocol_error`.
  - A well-formed `Request` after Ready is routed and answered with a `result`
    (a handled method) or an `error` (an unhandled method, or a per-method failure
    such as a bad workspace path).

Ownership:

  - Each accepted connection owns a `Conn` allocated in the transport `on_open` and
    freed in the terminal callback (`on_close`/`on_error`). It holds a per-frame
    `scratch` arena, `free_all`'d after each inbound frame; wire values decoded into
    it are non-owning borrows valid only for that frame.
  - The one datum retained from `initialize` is the client identity (`name`,
    `version`), kept as owned `strings.clone`s into the connection allocator for
    logging/identity and freed with the `Conn`. Nothing else survives the frame.
  - `Daemon.daemon_version`, `blob_dir`, and `auth_token` are owned clones freed by
    `daemon_destroy`. The database path is not retained: `store.open` copies what it
    needs, so the store handle itself records that a database is configured.
  - The store is opened by `daemon_start` before the transport adopts anything — a
    damaged or future-versioned database is a start failure, not a per-request one —
    and closed by `daemon_destroy` after the blob worker pool drains, since a drained
    completion runs on this loop and may still reach the front door. The pump's
    tracked high-water marks live and die with the store.
*/

package daemon
