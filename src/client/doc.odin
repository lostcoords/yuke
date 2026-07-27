/*
The client package binds the async `libs:websocket` reactor to the `wire` toolkit
and correlates each request with its typed response.

The transport (`libs:websocket`) is a single-threaded `core:nbio` callback reactor;
this driver never runs the loop. It sends an `initialize` request, waits for its
result, then routes each server frame by shape: a response (`result` or `error`)
reaches the `Response_Proc` its request registered with `client_send_request`, while
notifications and connection-wide events (readiness, broadcasts, termination) reach
the `Client_Callbacks` sink. `client_handle_text` is the pure routing core and is
unit-tested directly with no socket.

The package is layered as:

  - `client.odin`: the daemon client driver — the state machine, request/response
    correlation, and frame routing.
  - `session_replica.odin`: owned state for one session — a committed-message
    window plus an active draft. Every value is copied out of frame arenas so each
    region frees independently, and a resync snapshot installs transactionally.
    Imports `wire` only; no IO or runtime.

Lifetime contract:

  - The `wire.Response`, `wire.Notification`, and unknown-notification `method` handed to a
    callback borrow the transport message buffer and the per-message `scratch`
    arena. They are valid ONLY for the duration of that callback. A consumer that
    retains one MUST deep-copy it (e.g. `wire.notification_clone`) into its own
    allocator before returning — exactly how a `session_replica` consumer will use it.
  - The driver itself retains NO borrowed frame data: `pending` stores only the
    `Method_Name` enum and the caller's completion, and the sole retained handshake
    datum, `daemon_version`, is an owned `strings.clone`.
  - A registered `Response_Proc` fires at most once. Requests still outstanding when
    the connection closes or errors are dropped with `pending`, so any `user_data`
    they own must be reclaimed from the terminal callback, not from the completion.
  - `scratch` is `free_all`'d after every message; `pending`, the `daemon_version`
    clone, and `scratch` are released by `client_destroy`.

Terminal contract:

  `client_destroy` is safe exactly once `c.state == .Closed`. `on_close`
  always fires at `.Closed` and is the terminal callback. A transport failure
  instead fires `on_error(.Ws_Error)` at `.Closed` (no `on_close` follows it). Every
  other `on_error` — a driver protocol error (`.Bad_Initialize`/`.Bad_Frame`/
  `.Out_Of_Memory`) or a per-frame diagnostic
  (`.Unknown_Response`/`.Decode_Failed`) — fires while the connection is still
  open or closing; never `client_destroy` from those.
*/

package client
