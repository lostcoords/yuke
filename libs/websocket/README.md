# libs/websocket

A yuke-agnostic RFC 6455 **WebSocket client** for Odin, split into a sans-IO
protocol core and a thin [`core:nbio`](https://pkg.odin-lang.org/core/nbio/)
reactor driver. `package websocket`; imported via the `libs` collection as
`import ws "libs:websocket"`.

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
Layer 1  frame.odin · decoder.odin · handshake.odin   pure, no net/nbio
Layer 2  client.odin                                   nbio driver over Layer 1
```

## Quick start (nbio driver)

The driver borrows an event loop and never runs it — you own `nbio.run`. Odin
proc literals cannot capture, so callbacks reach your state through
`client_user_data` (the `rawptr` you pass to `client_connect`).

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
            a := (^App)(ws.client_user_data(c))
            a.done = true
        },
        on_error = proc(c: ^ws.Client, err: ws.Client_Error) {
            a := (^App)(ws.client_user_data(c))
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
| `client_close(c, code=.Normal_Closure)` | Begin a graceful close: queues a close frame, then TCP-closes once the queue drains. No-op unless Open. |
| `client_destroy(c)` | Free every owned buffer. Call once the connection has reached Closed (after `on_close`/`on_error`). |
| `client_user_data(c) -> rawptr` | The opaque pointer passed to `client_connect`. |

### Options

Zero-valued fields fall back to the defaults shown.

| Field | Default | Meaning |
|---|---|---|
| `host` | — | Hostname or dotted IPv4 (no scheme, no brackets). |
| `port` | — | TCP port. |
| `path` | `"/"` | Request path, leading `/`. |
| `max_frame_bytes` | 1 MiB | Reject any single inbound frame larger than this. |
| `max_message_bytes` | 1 MiB | Reject any reassembled message larger than this. |
| `recv_chunk_bytes` | 64 KiB | Size of each receive buffer. |
| `handshake_timeout` | 10 s | Timeout for the connect and each individual handshake read/write. |

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

## The loop contract

The driver is a citizen of a **borrowed** loop:

- It submits ops with the loop you pass and **never** calls `nbio.run`/`tick` —
  you drive the loop, and may multiplex other work on it.
- It never blocks the reactor: every step is a completion callback.
- Writes are serialized through a one-frame-at-a-time send queue, so frames never
  interleave on the wire. The reactor's single thread makes a mutex unnecessary.
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

```odin
// Decode: feed received bytes, drain complete messages.
d: ws.Decoder
ws.decoder_init(&d, max_frame_bytes = 1 << 20, max_message_bytes = 1 << 20)
defer ws.decoder_destroy(&d)

ws.decoder_feed(&d, received_bytes)
for {
    msg, has, err := ws.decoder_next(&d)
    if err != .None { /* fail the connection */ break }
    if !has { break }                 // need more bytes
    defer delete(msg.data)
    // dispatch msg.kind / msg.data; reply to Ping/Close yourself
}

// Encode: build one masked client frame to write.
key: [ws.MASK_KEY_BYTES]byte
// fill key with crypto.rand_bytes
frame := ws.encode_frame(true, .Text, payload, key)
defer delete(frame)
```

`parse_header`, `make_header`, `parse_close`, `make_sec_websocket_accept`,
`build_upgrade_request`, and `parse_upgrade_response` are all pure and available
for a hand-rolled handshake or transport.

## Build & test

```sh
make test-ws     # run the package tests
make fmt         # format (covers libs/)
```

Tests are offline except `client_test.odin`, which spins a blocking loopback
server on a worker thread and drives the nbio client against it (dial → real
handshake → receive → clean close).

## Limitations (v1)

- `ws://` only; no TLS.
- On a protocol violation the driver TCP-closes rather than first sending a close
  frame with the specific status code.
- DNS resolution is blocking (it runs once, before the loop).
- Outbound messages are sent as a single frame (no automatic fragmentation).
