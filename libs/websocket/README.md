# libs/websocket

A yuke-agnostic RFC 6455 **WebSocket** implementation for Odin, split into a
sans-IO protocol core and a thin [`core:nbio`](https://pkg.odin-lang.org/core/nbio/)
reactor driver. `package websocket`; imported via the `libs` collection as
`import ws "libs:websocket"`.

The **sans-IO core serves both directions**: a `Role` (`.Client` / `.Server`)
selects the RFC 6455 §5.1 masking discipline at each surface — framing, the
streaming decoder, and the HTTP upgrade handshake all have client and server
halves. There is **one nbio driver** (`conn.odin`) shared by two roles:
`client.odin` (dial) and `server.odin` (adopt an upgraded socket); each embeds the
driver's `Conn_Core` as its first field. The server-direction sans-IO primitives
also stand on their own for a blocking or custom-reactor server that doesn't want
the nbio driver.

The server driver **owns no listener**. The sans-I/O HTTP grammar lives in
[`libs/http`](../http); its deliberately small nbio driver lives in
[`libs/http/server`](../http/server). That front door binds the port, reads the
request head, routes it, and hands the socket over with `server_adopt`. One port
therefore serves `/ws` alongside plain HTTP routes, and routing, authorization,
and every non-101 status stay in the application where they belong.

`ws://` only — there is no TLS. For `wss://`, terminate TLS in a proxy in front
of the daemon and connect to it over plaintext loopback.

## Why sans-IO

`core:nbio` is a single-threaded callback reactor: you submit `recv`/`send` and
are called back on `nbio.tick`, then resubmit. A parser that called `recv` itself
would block the reactor, so the protocol logic here never touches a socket. It
operates on byte buffers and reports `.Need_More` instead of waiting. The same
core can therefore drive a blocking loop or the evented driver, and it composes
with a terminal loop, timers, or a Lua VM sharing one `nbio.run`.

```
Layer 1  frame.odin · decoder.odin · handshake.odin   pure, no net/nbio; both roles
Layer 2  conn.odin                                     nbio driver over Layer 1; both roles
Layer 3  client.odin                                   client role (dial, upgrade request)
Layer 3  server.odin                                   server role (adopt, 101, conn table)
```

## Quick start (nbio driver)

The driver borrows an event loop and never runs it — you own `nbio.run`. Odin
proc literals cannot capture, so callbacks reach your state through
`c.user_data` (the `rawptr` you pass to `client_connect`).

```odin
package main

import "core:fmt"
import "core:nbio"
import ws "libs:websocket"

App :: struct {
    done: bool,
}

main :: proc() {
    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    app: App

    callbacks := ws.Callbacks {
        on_open = proc(c: ^ws.Client) {
            ws.client_send_text(c, transmute([]byte)string(`{"type":"client.hello"}`))
        },
        on_message = proc(c: ^ws.Client, kind: ws.Message_Kind, data: []byte) {
            // `data` is borrowed for this call only — copy anything you keep.
            fmt.printfln("recv %v: %s", kind, string(data))
            ws.client_close(c)
        },
        on_close = proc(c: ^ws.Client, code: ws.Close_Code) {
            a := (^App)(c.user_data)
            a.done = true
        },
        on_error = proc(c: ^ws.Client, err: ws.Client_Error) {
            a := (^App)(c.user_data)
            fmt.eprintfln("ws error: %v", err)
            a.done = true
        },
    }

    c: ws.Client
    err := ws.client_connect(
        &c,
        loop,
        ws.Options{host = "127.0.0.1", port = 7880, path = "/ws"},
        callbacks,
        &app,
    )

    if err != .None {
        fmt.eprintfln("connect setup failed: %v", err)
        return
    }

    nbio.run_until(&app.done)
    ws.client_destroy(&c)
}
```

## Driver API

| Procedure | Purpose |
|---|---|
| `client_connect(c, loop, options, callbacks, user_data=nil, allocator=context.allocator) -> Client_Error` | Validate the options, set up owned state, resolve the endpoint, and submit the dial. Returns immediately; the handshake runs on the loop. Only a synchronous setup failure — `.Invalid_Options` (empty host, or a control byte in `host`/`path`) or `.Resolve_Failed` — is returned directly; every later failure arrives via `on_error`. |
| `client_send_text(c, data) -> Client_Error` | Queue a text message. `.Not_Open` unless the connection is Open. |
| `client_send_binary(c, data) -> Client_Error` | Queue a binary message. |
| `client_close(c, code=.Normal_Closure) -> Client_Error` | Begin a graceful close. Waits for the peer's Close after this endpoint's Close is sent, bounded by `close_timeout`. |
| `client_abort(c, err)` | Terminal fallback for an internal failure that makes a correct frame impossible; closes immediately and reports `on_error`. |
| `client_destroy(c)` | Free every owned buffer. Call once the connection has reached Closed (after `on_close`/`on_error`). |

### Options

Zero-valued fields fall back to the defaults shown.

| Field | Default | Meaning |
|---|---|---|
| `host` | — | Hostname or dotted IPv4 (no scheme, no brackets). |
| `port` | — | TCP port. |
| `path` | `"/"` | Request path, leading `/`. |
| `extra_headers` | `""` | Extra request headers, spliced verbatim: `name: value\r\n` lines (e.g. `Authorization: Bearer …`). |
| `max_frame_bytes` | 1 MiB | Reject any single inbound frame larger than this. |
| `max_message_bytes` | 1 MiB | Reject any reassembled message larger than this. |
| `recv_chunk_bytes` | 64 KiB | Size of each receive buffer. |
| `handshake_timeout` | 10 s | Timeout for the connect and each individual handshake read/write. |
| `max_send_queue_bytes` | max(1 MiB, one maximum frame) | Maximum application-frame bytes owned by the send queue. One control-frame reserve is kept outside this limit. |
| `close_timeout` | 5 s | Maximum wait for the peer's Close once a close handshake starts. |

The accumulated HTTP upgrade response is additionally capped at a fixed
**64 KiB** (`MAX_HANDSHAKE_RESPONSE_BYTES`). `handshake_timeout` is a *per-read*
timer, so a server that stalls mid-response is caught the moment it stops
sending; a server that dribbles bytes forever without ever sending `\r\n\r\n` is
caught by the byte cap. Between them the handshake always terminates. Exceeding
either fails with `.Handshake_Failed` (or `.Timed_Out`).

### Callbacks

All fields may be nil. Every terminal path fires exactly one of `on_close` /
`on_error`, and the connection is Closed when it does.

- `on_open(c)` — the upgrade succeeded; the connection is Open.
- `on_message(c, kind, data)` — one complete `Text`/`Binary` message. **`data` is
  borrowed for the duration of the call**; the driver frees it on return, so copy
  anything that must outlive the callback. Ping/Pong/Close are handled internally
  and never surface here.
- `on_close(c, code)` — closed with the reported (or synthesized) code. When the
  peer initiates the close its code is echoed back; if the peer sent an
  **empty** close body the reply is also empty-bodied (the synthesized
  `.No_Status_Rcvd`/1005 is reported to you but never put on the wire, per
  RFC 6455 §7.4.1), and a dropped TCP connection surfaces as `.Abnormal_Closure`.
- `on_error(c, err)` — terminal `Client_Error`.

Before either terminal callback fires the driver cancels every outstanding
operation and closes the socket, so it is safe to call `client_destroy` directly
from within `on_close`/`on_error` and keep ticking the loop: no later completion
will touch the `Client` or its freed buffers.

## Server driver

`server_init` readies a server (no I/O); `server_adopt` takes over a socket whose
upgrade request the caller already validated with `parse_upgrade_request`, writes
the 101, and fires `on_open` from the loop. There is exactly one way to start a
connection, so a front door is not optional.

```odin
import http_server "libs:http/server"

// In the front door's request handler, once the head is buffered:
upgrade, result, _, status := ws.parse_upgrade_request(req.head.bytes)
if status != .Ready || result != .Ok {
    http_server.respond_text(c, .Bad_Request, "expected an upgrade")
    return
}

// Refuse while the front door still owns the socket, so a full server answers a
// status instead of dropping the connection.
if !ws.server_can_adopt(&s) {
    http_server.respond_text(c, .Service_Unavailable, "at capacity")
    return
}

socket, loop := http_server.hijack(c)                           // the socket is now ours
if _, err := ws.server_adopt(&s, socket, upgrade.key, req.trailing); err != .None {
    nbio.close(socket, l = loop)                               // refused: still ours to close
}
```

`src/daemon/front_door.odin` is the reference handler — same shape, plus global
authorization and blob routing.

| Procedure | Purpose |
|---|---|
| `server_init(s, loop, options, callbacks, user_data=nil, allocator=context.allocator) -> Server_Error` | Validate options and ready the server without doing I/O. |
| `server_can_adopt(s) -> bool` | Whether `server_adopt` has room. Check it before hijacking so a refusal can still be an HTTP status. |
| `server_adopt(s, socket, key, pipelined=nil, response_headers=nil) -> (^Server_Conn, Server_Error)` | Take ownership of `socket` and write the 101. `key` and optional response headers are consumed during the call; pipelined frame bytes are copied. Ownership transfers only on `.None`. |
| `server_send_text/binary(conn, data) -> Server_Error` | Queue a message. `.Not_Open` unless Open. |
| `server_close(conn, code=.Normal_Closure) -> Server_Error` | Begin a graceful close, waiting for the peer up to `close_timeout`. |
| `server_abort(conn, err)` | Terminal fallback for an internal failure that makes a correct frame impossible; closes immediately and reports `on_error`. |
| `server_shutdown(s)` / `server_destroy(s)` | Close every connection, then reclaim once `s.shutdown_complete`. |

`socket` must already be associated with the server's loop — an nbio accept does
that; anything else needs `nbio.associate_socket` first. `on_open` never fires
before `server_adopt` returns, so the returned connection is safe to attach state
to immediately.

Both opaque pointers are plain fields: `conn.user_data` per connection (assign it
directly — the driver only stores it, so free any owned state from
`on_close`/`on_error`), and `conn.server.user_data` for the server-level pointer
passed to `server_init`.

## The loop contract

The driver is a citizen of a **borrowed** loop:

- It submits ops with the loop you pass and **never** calls `nbio.run`/`tick` —
  you drive the loop, and may multiplex other work on it.
- It never blocks the reactor: every step is a completion callback.
- Writes go through an ordered send queue, so frames never interleave on the
  wire. The reactor's single thread makes a mutex unnecessary. Queued frames
  are drained into bounded vectored sends (`SEND_BATCH_BYTES` 256 KiB /
  `SEND_BATCH_FRAMES` 512 per submission, shared by both roles) rather than
  one syscall per frame; an oversized frame is still sent by itself.
- The socket has `TCP_Nodelay` set (both the client's dialed socket and each
  connection the server adopts), so small frames aren't held by the
  kernel's delayed-ACK/Nagle interaction.
- Run everything (this client, terminal input, a Lua VM) on the **same** thread as
  the loop; nothing here is thread-safe across loops.

## Ownership

- The `Client` owns all its buffers (receive buffer, reassembly buffers, send
  queue, handshake scratch, host/path). `client_destroy` releases them; it does
  not touch the borrowed loop.
- `data` handed to `on_message` is owned by the driver and freed after the call.
- The sans-IO `encode_frame` and `decoder_next` return caller-owned slices; free
  with `delete(slice, allocator)`. The driver does this for you.

## Using the sans-IO core directly

To drive a different transport (a blocking socket, a test, another reactor), skip
`client.odin` and use Layer 1:

The `Role` you pass to `decoder_init` (and the presence of a masking key on the
encode side) picks the direction. A **client** reads unmasked server frames and
writes masked frames; a **server** reads masked client frames (the decoder
unmasks them for you) and writes unmasked frames.

```odin
// Decode (client): feed received bytes, drain complete messages.
d: ws.Decoder
ws.decoder_init(&d, max_frame_bytes = 1 << 20, max_message_bytes = 1 << 20, role = .Client)
defer ws.decoder_destroy(&d)

ws.decoder_feed(&d, received_bytes)
for {
    msg, has, err := ws.decoder_next(&d)
    if err != .None { /* fail the connection */ break }
    if !has { break }                 // need more bytes
    defer delete(msg.data)
    // dispatch msg.kind / msg.data; reply to Ping/Close yourself
}

// Encode a masked client frame to write: supply a random masking key.
key: [ws.MASK_KEY_BYTES]byte
// fill key with crypto.rand_bytes
frame := ws.encode_frame(true, .Text, payload, key)
defer delete(frame)

// Server direction: decode masked client frames with role = .Server, and encode
// unmasked server frames by passing nil for the key.
sd: ws.Decoder
ws.decoder_init(&sd, max_frame_bytes = 1 << 20, max_message_bytes = 1 << 20, role = .Server)
server_frame := ws.encode_frame(true, .Text, payload, nil)   // mask bit clear
```

For the handshake, a server validates the client's request and answers:

```odin
req, result, consumed, status := ws.parse_upgrade_request(buf)
if status == .Ready && result == .Ok {
    resp := ws.build_upgrade_response(transmute([]byte)req.key)   // 101 Switching Protocols
    defer delete(resp)
    // write resp; feed buf[consumed:] (any pipelined frame) to a .Server decoder
}
```

Refusing a bad upgrade is the front door's job, not this package's: answer
`http_server.respond_text(c, .Bad_Request, …)` (or whatever your transport
writes) and close.

`parse_header`, `make_header`, `parse_close`, `make_sec_websocket_accept`,
`build_upgrade_request`, `parse_upgrade_response`, `parse_upgrade_request`, and
`build_upgrade_response` are all pure and available for a hand-rolled handshake or
transport, in either direction.

## Build & test

```sh
make test-ws     # run the package tests
make fmt         # format (covers libs/)
```

Tests are offline. `client_test.odin` spins a blocking loopback server on a worker
thread and drives the nbio client against it (dial → real handshake → receive →
clean close); `server_test.odin` drives that same client against the server behind
a `libs:http/server` front door, all on one loop.

## Limitations (v1)

- `ws://` only; no TLS.
- On a protocol violation the driver TCP-closes rather than first sending a close
  frame with the specific status code.
- DNS resolution is blocking (it runs once, before the loop).
- Outbound messages are sent as a single frame (no automatic fragmentation).
