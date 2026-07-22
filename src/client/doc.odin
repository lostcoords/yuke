/*
The client package binds the async `libs:websocket` reactor to the `wire` toolkit
and correlates each request with its typed response.

The transport (`libs:websocket`) is a single-threaded `core:nbio` callback reactor;
this driver never runs the loop. It sends `client.hello`, waits for the server
`hello`, then routes each server frame (`response`/`error`/`broadcast`) to a
`Client_Callbacks` sink. `client_handle_text` is the pure routing core and is
unit-tested directly with no socket.

The package is layered as:

  - `client.odin`: the daemon client driver — the state machine, request/response
    correlation, and frame routing.
  - `session_replica.odin`: owned state for one session — a committed-message
    window plus an active draft. Every value is copied out of frame arenas so each
    region frees independently, and a resync snapshot installs transactionally.
    Imports `wire` only; no IO or runtime.

Lifetime contract:

  - The `wire.Response`, `wire.Broadcast`, and unknown-broadcast `name` handed to a
    callback borrow the transport message buffer and the per-message `scratch`
    arena. They are valid ONLY for the duration of that callback. A consumer that
    retains one MUST deep-copy it (e.g. `wire.broadcast_clone`) into its own
    allocator before returning — exactly how a `session_replica` consumer will use it.
  - The driver itself retains NO borrowed frame data: `pending` stores only the
    `Method_Name` enum, and the sole retained hello datum, `daemon_version`, is an
    owned `strings.clone`.
  - `scratch` is `free_all`'d after every message; `pending`, the `daemon_version`
    clone, and `scratch` are released by `client_destroy`.

Terminal contract:

  `client_destroy` is safe exactly once `client_state(c) == .Closed`. `on_close`
  always fires at `.Closed` and is the terminal callback. A transport failure
  instead fires `on_error(.Ws_Error)` at `.Closed` (no `on_close` follows it). Every
  other `on_error` — a driver protocol error (`.Bad_Hello`/`.Bad_Frame`/
  `.Unexpected_Hello`) or a per-frame diagnostic (`.Unknown_Response`/
  `.Decode_Failed`) — fires while the connection is still open or closing; never
  `client_destroy` from those.
*/

package client
