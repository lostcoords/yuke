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
`workspace.browse`) run real handlers, and every other method is answered with an
`Unknown_Method` error rather than silently dropped. With no store or catalog yet,
`session.list` returns an empty page and `catalog.list` the empty revision; the
workspace methods read the real filesystem.

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
    `daemon_destroy`.
*/

package daemon
