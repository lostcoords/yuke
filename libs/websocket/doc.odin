/*
package websocket is an RFC 6455 WebSocket implementation (ws:// only, no TLS).

The sans-IO protocol layer serves both directions: `Role` selects client or server
strictness at each surface. Two nbio reactor drivers sit on top of it: a client
dialer (`client.odin`) and a server driver (`server.odin`) that adopts sockets an
HTTP front door has already routed.

  - `frame.odin`: the frame codec. `parse_header(buf, role)` decodes a header from a
    buffer without blocking, reporting `.Need_More` when the buffer is incomplete.
    Masking is direction-strict (RFC 6455 §5.1): a `.Client` reads unmasked frames
    and writes masked ones, a `.Server` reads masked frames (extracting the key) and
    writes unmasked ones. On the write side the masking key's presence carries the
    same distinction — `make_header`/`encode_frame` take a `Maybe` key: supplied for
    a masked client frame, `nil` for an unmasked server frame.
  - `decoder.odin`: the message reassembler. `decoder_init` fixes the `Role`; feed
    bytes with `decoder_feed` and drain complete messages via `decoder_next`. A
    server-role decoder unmasks each payload in place before surfacing it. Data
    frames reassemble across fragments; control frames pass through whole. It only
    classifies frames — replying (pong to ping, close acknowledgement) is I/O and
    belongs to the driver.
  - `handshake.odin`: the HTTP upgrade handshake, both directions. A client builds a
    request with `build_upgrade_request` and validates the reply with
    `parse_upgrade_response`; a server validates the request with
    `parse_upgrade_request` and answers with `build_upgrade_response`. Refusing a bad
    upgrade is the front door's job. Both parsers report `.Need_More` until the full header
    block is buffered and never consume bytes past the `\r\n\r\n` terminator, leaving
    pipelined frames for the caller. `make_sec_websocket_accept` is shared.
  - `client.odin`: the nbio reactor driver that wires the client-role codec to a
    socket. It borrows an event loop and never runs it, so a caller can multiplex the
    client under their own `nbio.run`. Single-threaded: writes are serialized through
    an ordered send queue, drained in bounded vectored batches (no mutex).
  - `server.odin`: the nbio reactor driver that wires the server-role codec to an
    adopted socket. It owns no listener — `server_adopt` takes a socket plus the
    `Sec-WebSocket-Key` a front door already validated, writes the 101, and runs the
    connection from there. It owns the connection table (capped at
    `max_connections`) and a per-connection send queue with the same bounded
    vectored-batch draining as the client driver; auto-replies to Ping with Pong.
    Both drivers complete the Close exchange before TCP teardown, with a bounded
    deadline for a peer that never replies, and set `TCP_Nodelay` on their sockets.
*/
package websocket
