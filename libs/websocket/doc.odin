/*
package websocket is an RFC 6455 WebSocket implementation. A client reaches a server
over `ws://` or `wss://`; the server is `ws://` only and expects TLS, when it is
wanted, to be terminated by a reverse proxy in front of it.

The sans-IO protocol layer serves both directions: `Role` selects client or server
strictness at each surface. One nbio reactor driver (`conn.odin`) sits on top of it,
shared by two roles: a client dialer (`client.odin`) and a server (`server.odin`)
that adopts sockets an HTTP front door has already routed.

Both schemes share every byte of that driver. `pipe.odin` is the one place they
differ: a `Ws` connection reads and writes with nbio directly, while a `Wss`
connection hands the connect and the TLS session to libcurl and moves plaintext
through `curl.socket_send`/`socket_recv`, waiting on `nbio.poll` for readiness.
Choosing `Wss` also brings certificate verification and proxy support, which is much
of why the connect is libcurl's rather than this package's.

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
    `parse_upgrade_request`, or with `parse_upgrade_request_head` when the HTTP head is
    already parsed, and answers with `build_upgrade_response`. Both parsers report
    `.Need_More` until the full header
    block is buffered and never consume bytes past the `\r\n\r\n` terminator, leaving
    pipelined frames for the caller. `make_sec_websocket_accept` is shared.
  - `conn.odin`: the nbio reactor driver, `Conn_Core`, embedded first in both `Client`
    and `Server_Conn` so either converts to a `^Conn_Core`. It borrows an event loop
    and never runs it, so a caller can multiplex a connection under their own
    `nbio.run`. Single-threaded: writes are serialized through an ordered send queue,
    drained in bounded vectored batches (no mutex). It auto-replies to Ping with Pong
    and completes the Close exchange before TCP teardown, with a bounded deadline for
    a peer that never replies. `role` selects masking on the write side; three
    adapters (message, terminal, drain) hand an event back to the owning role.
  - `client.odin`: the client role — dial, upgrade request, response validation, and
    the `Callbacks` surface. Sets `TCP_Nodelay` once connected.
  - `server.odin`: the server role. It owns no listener — `server_adopt` takes a
    socket plus the `Sec-WebSocket-Key` a front door already validated, writes the
    101, and runs the connection from there. It owns the connection table (capped at
    `max_connections`), the shutdown sequence, and per-connection release.
  - `accept.odin`: `accept_upgrade`, the bridge from a `libs:http/server` connection to
    `server_adopt`. It validates the head, refuses with 400 or 503, and otherwise hijacks
    the socket and adopts it, forwarding the connection's pending response headers onto
    the 101. Capacity is checked before the hijack, since a refusal needs a connection
    that can still answer. The only place this package depends on an HTTP driver.
*/
package websocket
