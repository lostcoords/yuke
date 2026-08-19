/*
package curl is a minimal Odin binding to libcurl plus a streaming driver that
runs libcurl's multi interface on a `core:nbio` event loop.

Layers:

  - `c.odin`: FFI, codes, options, and the typed setopt wrappers. `curl_easy_setopt`
    is variadic; the wrappers are its only callers.

  - `drive.odin`: one evented Drive for both `Client` and `Socket`. Curl's
    `drive_on_socket`/`drive_on_timer` name the fds and the timeout; Drive arms
    `nbio.poll`/`nbio.timeout` and calls `socket_action`. Each owner reads
    `CURLMSG_DONE` from `after_pump`.

  - `socket.odin`: `Socket`, a `Connect_Only` connection. libcurl does TCP and TLS,
    then `socket_send`/`socket_recv`. The easy handle stays on the multi for the
    socket's life — removing it destroys the connection. After the dial, Drive
    drops watches and curl's timer; an idle socket costs nothing. Curl's connect
    timeout covers DNS, TCP, and the TLS handshake.

  - `curl.odin`: `Client` and `Transfer`. Same Drive. An idle client costs nothing
    on the loop.

`drive_close_socket` must `net.close` the fd before it returns. `nbio.close` only
queues a close until the next tick; that hung a TLS write-resume (`thread.join`
on a server still in recv) and can race a still-armed poll. Disarm watches first.

`socket_destroy` is idempotent: a second call is a no-op. A failed
`socket_connect` leaves the socket Closed, so destroy is a no-op there too.

Pump on the loop thread. `drive_kick` is the start/cancel entry; it defers if a
pump is already running so `On_Done` can start the next transfer.

Threading: everything runs on the loop thread. Easy handles are never shared,
never touched from another thread, and the write and header callbacks fire
directly on the loop, so response bytes reach the caller with no copy and no
cross-thread ownership.

Borrowing: `On_Body` chunks and `On_Header` lines borrow libcurl's own buffer
and are valid for the call only; `Result.message` borrows the transfer's error
buffer the same way. Copy anything that must outlive the callback. In the other
direction every request field — URL, header lines, and the request body (via
`Option.Copy_Post_Fields`) — is copied by libcurl during `transfer_start`, so the
caller may release the request and its body once `transfer_start` returns.

Ownership: the caller allocates each `Transfer` and keeps it for the life of the
owner. This package never frees the struct. It only creates the easy handle and
header list at `transfer_start` and releases them at `On_Done` or
`transfer_cancel`. After that the same struct may be started again.

Addresses are pinned: libcurl and Drive hold the `Client` and each live
`Transfer` by address, so neither may be moved, copied, or reallocated while
live. A caller embedding a `Transfer` in its own struct must keep that struct
in place.

Cancellation has exactly two forms. `On_Body` returning false aborts from inside
a callback; the transfer still completes through `On_Done` with `.Write_Error`.
`transfer_cancel` ends a transfer from outside every callback: the handle is
removed and destroyed synchronously and no callback ever fires again, mirroring
`nbio.remove`'s final-and-silent contract. Calling `transfer_cancel` (or
`transfer_start`) from inside a curl callback is a programmer error — libcurl
forbids mutating the multi handle there — and is asserted.

`curl_global_init` runs exactly once per process from `client_init` and
`curl_global_cleanup` is never called: the library's global state is refcounted,
and tearing it down would break a second client living in the same process.

Linking:
  - Darwin / Linux: system `libcurl`.
  - Windows: a static Schannel build at `libs/bindings/curl/bin/curl.lib`. See
    `libs/bindings/curl/build_static.bat`.
*/
package curl
