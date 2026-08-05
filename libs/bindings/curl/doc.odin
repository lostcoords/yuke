/*
package curl is a minimal Odin binding to libcurl plus a streaming driver that
runs libcurl's multi interface on a `core:nbio` event loop.

Three layers, one package:

  - `c.odin`: the raw FFI. `@(private)` `c_*` procedures, the `CURLcode` and
    `CURLMcode` enums, the subset of `CURLoption` this driver sets, and the
    typed `setopt_long` / `setopt_str` / `setopt_ptr` / `setopt_write_cb`
    wrappers. `curl_easy_setopt` is variadic and therefore type-unsafe, so the
    wrappers are its only callers; importers see none of this.

  - `socket.odin`: `Socket`, a `Connect_Only` connection. libcurl performs the TCP
    and TLS handshake on its own multi handle, then hands over raw
    `socket_send`/`socket_recv`. The handle stays added to that multi for the
    socket's whole life — removing it destroys the connection — but a connected
    socket needs no pumping at all, so the dial's timer is dropped once it lands and
    an idle socket costs nothing on the loop.

  - `curl.odin`: `Client` and `Transfer`. A `Client` owns the multi handle and
    one re-armed `nbio.timeout` that calls `curl_multi_perform` and drains
    `curl_multi_info_read`. The timer is armed when the first transfer starts
    and disarmed when the last one ends, so an idle client costs nothing.

Threading: everything runs on the loop thread. Easy handles are never shared,
never touched from another thread, and the write and header callbacks fire
directly on the loop, so response bytes reach the caller with no copy and no
cross-thread ownership.

Borrowing: `On_Body` chunks and `On_Header` lines borrow libcurl's own buffer
and are valid for the call only; `Result.message` borrows the transfer's error
buffer the same way. Copy anything that must outlive the callback. In the other
direction every request field — URL, header lines, and the POST body (via
`CURLOPT_COPYPOSTFIELDS`) — is copied by libcurl during `transfer_start`, so the
caller may release the request and its body once `transfer_start` returns.

Addresses are pinned: libcurl and the pump timer hold the `Client` and each live
`Transfer` by address, so neither may be moved, copied, or reallocated once
started. A caller embedding a `Transfer` in its own struct must keep that struct
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
