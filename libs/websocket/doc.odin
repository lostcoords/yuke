/*
package websocket is an RFC 6455 WebSocket client (ws:// only, no TLS).

The package is split into a sans-IO protocol layer and an nbio reactor driver:

  - `frame.odin`: the frame codec. `parse_header` decodes a header from a buffer
    without blocking; it reports `.Need_More` when the buffer is incomplete.
    Client writes are always masked; a masked server frame is a protocol error.
  - `decoder.odin`: the message reassembler. Feed bytes with `decoder_feed` and
    drain complete messages via `decoder_next`. Data frames reassemble across
    fragments; control frames pass through whole. It only classifies frames —
    replying (pong to ping, close acknowledgement) is I/O and belongs to the driver.
  - `handshake.odin`: the HTTP upgrade handshake. Request building and response
    parsing are separate buffer-based steps; `parse_upgrade_response` reports
    `.Need_More` until the full header block is buffered and never consumes bytes
    past the `\r\n\r\n` terminator.
  - `client.odin`: the nbio reactor driver that wires the codec to a socket. It
    borrows an event loop and never runs it, so a caller can multiplex the client
    under their own `nbio.run`. Single-threaded: writes are serialized through a
    one-frame-at-a-time send queue (no mutex).
*/
package websocket
