/*
The client package binds a text-frame transport to the `wire` toolkit and correlates
each request with its typed response.

The driver runs over anything that can carry text frames: `client_open` takes a
`Transport` the caller chose, and no backend type appears in the driver's API. The
bundled factory is fallible `ws_create` (`ws://` on `core:nbio`; dials on `open`).
It sends an `initialize` request, waits for its result, then routes each server frame by
shape: a response (`result` or `error`) reaches the `Response_Proc` its request registered
with `client_send_request`, while notifications and connection-wide events (readiness,
broadcasts, termination) reach the `Client_Callbacks` sink. `client_handle_text` is
the pure routing core and is unit-tested directly with no socket.

The package is layered as:

  - `transport.odin`: `Transport` ops bag, `Close_Code`, and the WS backend (`ws_create`).
  - `client.odin`: the daemon client driver — the state machine, request/response
    correlation, and frame routing.
  - `session_replica.odin`: owned state for one session — a committed-message
    window plus an active draft. Every value is copied out of frame arenas so each
    region frees independently, and a resync snapshot installs transactionally.
    Imports `wire` only; no IO or runtime.

Lifetime contract:

  - The `wire.Initialize_Result`, `wire.Response`, `wire.Notification`, and
    unknown-notification `method` handed to a callback borrow the transport message buffer
    and the per-message `scratch` arena. They are valid ONLY for the duration of that
    callback. A consumer that retains one MUST deep-copy the data it needs into its own
    allocator before returning — exactly how a `session_replica` consumer will use a
    notification.
  - The driver itself retains NO borrowed frame data: `pending` stores only the
    `Method_Name` enum and the caller's completion; handshake scalars are copied by value,
    and `daemon_version` is an owned `strings.clone`.
  - A registered `Response_Proc` fires at most once. Requests still outstanding when
    the connection closes or errors are dropped with `pending`, so any `user_data`
    they own must be reclaimed from the terminal callback, not from the completion.
  - `scratch` is `free_all`'d after every message; `pending`, the `daemon_version`
    clone, and `scratch` are released by `client_destroy`, which also destroys the
    transport `client_open` took ownership of.

Terminal contract:

  `client_destroy` is safe exactly once `c.state == .Closed`. `on_close`
  always fires at `.Closed` and is the terminal callback. A transport failure
  instead fires `on_error(.Transport_Failed)` at `.Closed` (no `on_close` follows it). Every
  other `on_error` — a driver protocol error (`.Bad_Initialize`/`.Bad_Frame`/
  `.Out_Of_Memory`) or a per-frame diagnostic
  (`.Unknown_Response`/`.Decode_Failed`) — fires while the connection is still
  open or closing; never `client_destroy` from those.
*/

package client
