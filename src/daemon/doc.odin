/*
The daemon package is the accept-side counterpart to `src/client`: it binds the
`libs:websocket` server reactor to the `wire` toolkit and speaks the v1 hello
exchange.

Logging uses `core:log` through `context.logger`. Libraries and the daemon emit
messages; the process that drives `nbio.run` / `run_until` owns the logger (nbio
callbacks inherit that context). Never log bearer tokens or Authorization values.

One port serves everything. `front_door.odin` routes the strict bodyless HTTP/1.1
requests accepted by `libs:http/server`. When a token is configured, every route
first requires exactly one credential source: `Authorization: Bearer` or `?token=`.
It then routes `GET /ws` into the WebSocket server and streams
`GET /blob/<hash>` from `blob_dir`. The 64-lowercase-hex hash grammar keeps request
paths inside that directory. Every other path is a 404 and every other method a 405.

The transport (`libs:websocket`) is a single-threaded `core:nbio` callback
reactor; this driver never runs the loop. On each upgraded connection it waits
for the client's `client.hello`, replies with a `hello` snapshot, and reaches
Ready. A request that arrives after Ready is routed to its handler: the four
read-only methods (`session.list`, `catalog.list`, `workspace.describe`,
`workspace.browse`) run real handlers, and every other method is answered with an
`Unknown_Method` error rather than silently dropped. With no store or catalog yet,
`session.list` returns an empty page and `catalog.list` the empty revision; the
workspace methods read the real filesystem.

Per-connection state machine (the inverse of the client's):

  Awaiting_Hello -> Ready -> Closed

  - The first frame must be a Text frame decoding to `Client_Frame.(Client_Hello)`
    with `protocol == PROTOCOL_VERSION`. On success the daemon emits a
    `Server_Hello` and transitions Ready. A bad protocol version closes with
    `CLOSE.unsupported_protocol`.
  - A binary frame, a second `client.hello` once Ready, a `Request` before Ready,
    a decode/validate failure, or trailing bytes after the JSON value all close the
    connection with `CLOSE.protocol_error`.
  - A well-formed `Request` after Ready is routed and answered with a `response`
    (a handled method) or an `error` (an unhandled method, or a per-method failure
    such as a bad workspace path).

Ownership:

  - Each accepted connection owns a `Conn` allocated in the transport `on_open` and
    freed in the terminal callback (`on_close`/`on_error`). It holds a per-frame
    `scratch` arena, `free_all`'d after each inbound frame; wire values decoded into
    it are non-owning borrows valid only for that frame.
  - The one datum retained from `client.hello` is the client identity (`name`,
    `version`), kept as owned `strings.clone`s into the connection allocator for
    logging/identity and freed with the `Conn`. Nothing else survives the frame.
  - `Daemon.daemon_version`, `blob_dir`, and `auth_token` are owned clones freed by
    `daemon_destroy`.
*/

package daemon
