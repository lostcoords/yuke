package websocket

import "core:crypto"
import "core:encoding/base64"
import "core:fmt"
import "core:mem"
import "core:nbio"
import "core:net"
import "core:strings"
import "core:time"

// Ceiling on the buffered upgrade response; bounds `handshake_buf` against a
// server that never sends `\r\n\r\n`.
MAX_HANDSHAKE_RESPONSE_BYTES :: 64 << 10

// Connection lifecycle: Dialing -> Upgrading -> Open -> Closing -> Closed.
Client_State :: enum {
    // Freshly zeroed; not yet connecting.
    Idle,

    // TCP connect in flight.
    Dialing,

    // Awaiting the 101 upgrade response.
    Upgrading,

    // Handshake complete; exchanging application messages.
    Open,

    // Close frame queued; draining the send queue before TCP close.
    Closing,

    // Fully torn down; no further callbacks will run.
    Closed,
}

// Terminal failure reasons surfaced to `On_Error`.
Client_Error :: enum {
    // No error.
    None,

    // `host`/`path` rejected before any I/O (empty host or injectable control byte).
    Invalid_Options,

    // Host could not be parsed as an IP or resolved via DNS.
    Resolve_Failed,

    // TCP connect failed or timed out.
    Dial_Failed,

    // The HTTP upgrade did not complete with a valid 101.
    Handshake_Failed,

    // A framing/reassembly rule was violated by the peer.
    Protocol_Violation,

    // A socket write failed.
    Send_Failed,

    // A socket read failed.
    Recv_Failed,

    // A handshake step exceeded its timeout.
    Timed_Out,

    // The client is not in a state that accepts this operation.
    Not_Open,
}

// Connect and protocol options. Zero-valued fields default in `client_connect`.
Options :: struct {
    // Hostname or dotted IPv4 address (no brackets, no scheme).
    host:              string,

    // TCP port.
    port:              int,

    // Request path including the leading `/`.
    path:              string,

    // Reject any single inbound frame larger than this many bytes.
    max_frame_bytes:   int,

    // Reject any reassembled inbound message larger than this many bytes.
    max_message_bytes: int,

    // Size of the buffer handed to each socket receive.
    recv_chunk_bytes:  int,

    // Timeout applied to the TCP connect and each handshake read/write.
    handshake_timeout: time.Duration,
}

// Fired once the upgrade succeeds and the connection is Open.
On_Open :: #type proc(c: ^Client)

// Fired for each complete message. `data` is borrowed for the call only; copy it
// if it must outlive the callback.
On_Message :: #type proc(c: ^Client, kind: Message_Kind, data: []byte)

// Fired once when the connection closes, with the reported (or synthesized) code.
On_Close :: #type proc(c: ^Client, code: Close_Code)

// Fired once on terminal failure. The connection is Closed when this runs.
On_Error :: #type proc(c: ^Client, err: Client_Error)

// Application callbacks. Any field may be nil.
Callbacks :: struct {
    on_open:    On_Open,
    on_message: On_Message,
    on_close:   On_Close,
    on_error:   On_Error,
}

// One WebSocket connection on an nbio loop. Owns its buffers; free with
// `client_destroy` once Closed.
Client :: struct {
    // Borrowed event loop; the driver submits ops to it but never runs it.
    loop:              ^nbio.Event_Loop,

    // Allocator backing every owned buffer below; must outlive the client.
    allocator:         mem.Allocator,

    // Connected socket; valid from the dial completion onward.
    socket:            net.TCP_Socket,

    // Whether `socket` was acquired; guards teardown from `close(0)` when the
    // dial failed before one existed.
    has_socket:        bool,

    // Lifecycle state.
    state:             Client_State,

    // Sans-IO reassembler fed by every receive.
    decoder:           Decoder,

    // Reused destination for each socket receive.
    recv_buf:          []byte,

    // Base64 Sec-WebSocket-Key sent, checked against the response accept.
    key_encoded:       [SEC_WEBSOCKET_KEY_ENCODED_BYTES]byte,

    // Accumulates the HTTP upgrade response until its header block is complete.
    handshake_buf:     [dynamic]byte,

    // Owned upgrade-request bytes, freed once the send completes.
    request_buf:       []byte,

    // Owned `Host:` header value (`host:port`).
    host_header:       string,

    // Owned request path.
    path:              string,

    // Inbound single-frame cap (mirrors the decoder's cap for send-side checks).
    max_frame_bytes:   int,

    // Inbound reassembled-message cap.
    max_message_bytes: int,

    // Timeout for the connect and handshake phases.
    handshake_timeout: time.Duration,

    // Encoded frames waiting to be written, in order; each is owned.
    send_queue:        [dynamic][]byte,

    // The frame currently being written, owned until its send completes.
    in_flight:         []byte,

    // True while a send is in flight; gates the one-frame-at-a-time queue.
    sending:           bool,

    // Set once a close frame is queued; finalize the TCP close after it drains.
    want_close:        bool,

    // Close code to report to `On_Close` after teardown completes.
    close_code:        Close_Code,

    // Error to report via `On_Error`; `.None` selects `On_Close` instead. Latched
    // before teardown so the terminal callback can fire on socket close.
    terminal_error:    Client_Error,

    // Outstanding op handles, one per lane (recv and send overlap while Open).
    // Cleared at the top of their own callback; teardown removes the rest.
    dial_op:           ^nbio.Operation,
    recv_op:           ^nbio.Operation,
    send_op:           ^nbio.Operation,

    // Application callbacks.
    cbs:               Callbacks,

    // Opaque application pointer; retrieve with `client_user_data`.
    user_data:         rawptr,
}

// Begin connecting. Resolves the endpoint and submits the TCP dial; the rest of
// the handshake runs on the loop. Sync failures (resolve) return directly; async
// failures arrive via `on_error`.
client_connect :: proc(
    c: ^Client,
    loop: ^nbio.Event_Loop,
    options: Options,
    callbacks: Callbacks,
    user_data: rawptr = nil,
    allocator := context.allocator,
) -> Client_Error {
    opts := options
    if opts.path == "" {
        opts.path = "/"
    }
    if opts.max_frame_bytes == 0 {
        opts.max_frame_bytes = 1 << 20
    }
    if opts.max_message_bytes == 0 {
        opts.max_message_bytes = 1 << 20
    }
    if opts.recv_chunk_bytes == 0 {
        opts.recv_chunk_bytes = 64 << 10
    }
    if opts.handshake_timeout == 0 {
        opts.handshake_timeout = 10 * time.Second
    }

    // `host`/`path` are spliced verbatim into the request, so reject anything that
    // could inject a header line (see `build_upgrade_request`).
    if opts.host == "" || has_control_byte(opts.host) || has_control_byte(opts.path) {
        return .Invalid_Options
    }

    endpoint, ok := resolve_endpoint(opts.host, opts.port)
    if !ok {
        return .Resolve_Failed
    }

    c^ = {}
    c.loop = loop
    c.allocator = allocator
    c.state = .Dialing
    c.max_frame_bytes = opts.max_frame_bytes
    c.max_message_bytes = opts.max_message_bytes
    c.handshake_timeout = opts.handshake_timeout
    c.cbs = callbacks
    c.user_data = user_data

    decoder_init(&c.decoder, opts.max_frame_bytes, opts.max_message_bytes, allocator)
    c.recv_buf = make([]byte, opts.recv_chunk_bytes, allocator)
    c.handshake_buf = make([dynamic]byte, allocator)
    c.send_queue = make([dynamic][]byte, allocator)
    c.host_header = fmt.aprintf("%s:%d", opts.host, opts.port, allocator = allocator)
    c.path = strings.clone(opts.path, allocator)

    c.dial_op = nbio.dial_poly(endpoint, c, on_dial, c.handshake_timeout, loop)

    return .None
}

// True when `s` holds an ASCII control byte (C0 or DEL); such a byte in
// `host`/`path` would inject a header line.
has_control_byte :: proc(s: string) -> bool {
    for b in transmute([]byte)s {
        if b < 0x20 || b == 0x7f {
            return true
        }
    }

    return false
}

// Release every owned buffer. Call after Closed (post `On_Close`/`On_Error`).
// Does not touch the borrowed loop.
client_destroy :: proc(c: ^Client) {
    decoder_destroy(&c.decoder)
    delete(c.recv_buf, c.allocator)
    delete(c.handshake_buf)

    if c.request_buf != nil {
        delete(c.request_buf, c.allocator)
    }

    for frame in c.send_queue {
        delete(frame, c.allocator)
    }
    delete(c.send_queue)

    if c.in_flight != nil {
        delete(c.in_flight, c.allocator)
    }

    delete(c.host_header, c.allocator)
    delete(c.path, c.allocator)
    c^ = {}
}

// The opaque pointer supplied to `client_connect`.
client_user_data :: proc(c: ^Client) -> rawptr {
    return c.user_data
}

// Queue a text message. Fails unless the connection is Open.
client_send_text :: proc(c: ^Client, data: []byte) -> Client_Error {
    return send_data_frame(c, .Text, data)
}

// Queue a binary message. Fails unless the connection is Open.
client_send_binary :: proc(c: ^Client, data: []byte) -> Client_Error {
    return send_data_frame(c, .Binary, data)
}

// Begin a graceful close with `code`. Queues a close frame; TCP close and
// `On_Close` follow once the send queue drains. No-op unless Open.
client_close :: proc(c: ^Client, code := Close_Code.Normal_Closure) {
    if c.state != .Open {
        return
    }

    begin_close(c, code, code)
}

// Encode and queue a data frame, masking with a fresh random key.
send_data_frame :: proc(c: ^Client, opcode: Op_Code, data: []byte) -> Client_Error {
    if c.state != .Open {
        return .Not_Open
    }

    frame := encode_masked(c, opcode, data)
    enqueue_frame(c, frame)

    return .None
}

// Resolve `host` to an endpoint: literal IPv4 first, else DNS. DNS is blocking,
// acceptable since connect runs before the loop.
resolve_endpoint :: proc(host: string, port: int) -> (net.Endpoint, bool) {
    if addr, ok := net.parse_ip4_address(host); ok {
        return net.Endpoint{address = addr, port = port}, true
    }

    ep4, err := net.resolve_ip4(host)
    if err != nil {
        return {}, false
    }

    ep4.port = port

    return ep4, true
}

// True when a recv failed by timing out. `net.Recv_Error` is a TCP/UDP union, so
// the timeout lives in the TCP arm.
recv_timed_out :: proc(e: net.Recv_Error) -> bool {
    tcp, ok := e.(net.TCP_Recv_Error)

    return ok && tcp == .Timeout
}

// True when a send failed specifically because it timed out.
send_timed_out :: proc(e: net.Send_Error) -> bool {
    tcp, ok := e.(net.TCP_Send_Error)

    return ok && tcp == .Timeout
}

// Dial completion: capture the socket, then send the upgrade request.
on_dial :: proc(op: ^nbio.Operation, c: ^Client) {
    c.dial_op = nil

    if op.dial.err != nil {
        // No socket was acquired; `fail` must not close a zero-value fd.
        fail(c, .Dial_Failed)
        return
    }

    c.socket = op.dial.socket
    c.has_socket = true
    c.state = .Upgrading

    key_raw: [SEC_WEBSOCKET_KEY_BYTES]byte
    crypto.rand_bytes(key_raw[:])
    base64.encode_into_buf(c.key_encoded[:], key_raw[:])

    c.request_buf = build_upgrade_request(c.path, c.host_header, c.key_encoded[:], "", c.allocator)
    c.send_op = nbio.send_poly(
        c.socket,
        [][]byte{c.request_buf},
        c,
        on_upgrade_sent,
        {},
        true,
        c.handshake_timeout,
        c.loop,
    )
}

// Upgrade request sent: free it and start reading the response.
on_upgrade_sent :: proc(op: ^nbio.Operation, c: ^Client) {
    c.send_op = nil

    if op.send.err != nil {
        fail(c, send_timed_out(op.send.err) ? .Timed_Out : .Handshake_Failed)
        return
    }

    delete(c.request_buf, c.allocator)
    c.request_buf = nil

    c.recv_op = nbio.recv_poly(
        c.socket,
        [][]byte{c.recv_buf},
        c,
        on_handshake_recv,
        false,
        c.handshake_timeout,
        c.loop,
    )
}

// Accumulate and validate the upgrade response. Reads until the header block is
// complete, then transitions to Open and hands off to the read loop.
on_handshake_recv :: proc(op: ^nbio.Operation, c: ^Client) {
    c.recv_op = nil

    if op.recv.err != nil {
        fail(c, recv_timed_out(op.recv.err) ? .Timed_Out : .Handshake_Failed)
        return
    }

    if op.recv.received == 0 {
        fail(c, .Handshake_Failed)
        return
    }

    append(&c.handshake_buf, ..c.recv_buf[:op.recv.received])

    // Bound the buffer against a server that never sends `\r\n\r\n`.
    if len(c.handshake_buf) > MAX_HANDSHAKE_RESPONSE_BYTES {
        fail(c, .Handshake_Failed)
        return
    }

    result, consumed, status := parse_upgrade_response(c.handshake_buf[:], c.key_encoded[:])
    if status == .Need_More {
        c.recv_op = nbio.recv_poly(
            c.socket,
            [][]byte{c.recv_buf},
            c,
            on_handshake_recv,
            false,
            c.handshake_timeout,
            c.loop,
        )

        return
    }

    if result != .Ok {
        fail(c, .Handshake_Failed)
        return
    }

    c.state = .Open

    // The server may pipeline the first frame right after the terminator; feed
    // those trailing bytes to the decoder before reading.
    leftover := c.handshake_buf[consumed:]
    if len(leftover) > 0 {
        decoder_feed(&c.decoder, leftover)
    }

    if c.cbs.on_open != nil {
        c.cbs.on_open(c)
    }

    if !drain_decoder(c) {
        return
    }

    // `on_open` or a pipelined frame may have begun a close; only read on if Open.
    if c.state == .Open {
        start_recv(c)
    }
}

// Submit the next steady-state receive (no timeout; the peer may idle).
start_recv :: proc(c: ^Client) {
    c.recv_op = nbio.recv_poly(c.socket, [][]byte{c.recv_buf}, c, on_recv, false, nbio.NO_TIMEOUT, c.loop)
}

// Receive completion: feed the decoder, dispatch messages, then read again.
on_recv :: proc(op: ^nbio.Operation, c: ^Client) {
    c.recv_op = nil

    if c.state != .Open {
        return
    }

    if op.recv.err != nil {
        fail(c, .Recv_Failed)
        return
    }

    if op.recv.received == 0 {
        // Peer closed the TCP connection without a WebSocket close frame.
        finalize_close(c, .Abnormal_Closure)
        return
    }

    decoder_feed(&c.decoder, c.recv_buf[:op.recv.received])

    if !drain_decoder(c) {
        return
    }

    if c.state == .Open {
        start_recv(c)
    }
}

// Drain buffered messages. Returns false once it has terminated the connection
// (protocol error or close), so the caller stops.
drain_decoder :: proc(c: ^Client) -> bool {
    for {
        msg, has, err := decoder_next(&c.decoder, c.allocator)
        if err != .None {
            fail(c, .Protocol_Violation)
            return false
        }

        if !has {
            return true
        }

        switch msg.kind {
        case .Text, .Binary:
            if c.cbs.on_message != nil {
                c.cbs.on_message(c, msg.kind, msg.data)
            }

            delete(msg.data, c.allocator)

        case .Ping:
            // RFC 6455: answer a ping with a pong echoing its payload.
            enqueue_frame(c, encode_masked(c, .Pong, msg.data))
            delete(msg.data, c.allocator)

        case .Pong:
            delete(msg.data, c.allocator)

        case .Close:
            parsed, perr := parse_close(msg.data)
            had_body := len(msg.data) != 0
            delete(msg.data, c.allocator)
            if perr != .None {
                fail(c, .Protocol_Violation)
                return false
            }

            // Echo the peer's code only when it sent one; an empty body must be
            // answered with an empty-body close, never synthesized 1005 (invalid
            // on the wire, RFC 6455 §7.4.1). The synthesized code is still
            // reported locally.
            wire_code: Maybe(Close_Code)
            if had_body {
                wire_code = parsed.code
            }

            begin_close(c, wire_code, parsed.code)

            return false
        }
    }
}

// Queue a masked close frame and enter Closing. `wire_code` is serialized into
// the body; nil sends an empty-body close (required when echoing a peer that sent
// no code — 1005/1006 must never go on the wire). `report_code` is what `On_Close`
// receives. Idempotent once closing has begun.
begin_close :: proc(c: ^Client, wire_code: Maybe(Close_Code), report_code: Close_Code) {
    if c.state == .Closing || c.state == .Closed {
        return
    }

    c.state = .Closing
    c.want_close = true
    c.close_code = report_code

    body: []byte
    buf: [2]byte
    if code, ok := wire_code.?; ok {
        buf[0] = byte(u16(code) >> 8)
        buf[1] = byte(code)
        body = buf[:]
    }

    enqueue_frame(c, encode_masked(c, .Connection_Close, body))
}

// Encode one masked client frame from a fresh random masking key.
encode_masked :: proc(c: ^Client, opcode: Op_Code, payload: []byte) -> []byte {
    key: [MASK_KEY_BYTES]byte
    crypto.rand_bytes(key[:])

    return encode_frame(true, opcode, payload, key, c.allocator)
}

// Append an owned frame to the send queue and pump the writer.
enqueue_frame :: proc(c: ^Client, frame: []byte) {
    append(&c.send_queue, frame)
    pump_send(c)
}

// Write one queued frame if none is in flight. Finalizes the TCP close when the
// queue empties during Closing.
pump_send :: proc(c: ^Client) {
    // A terminal failure stops the pipeline: never send on a closed socket. The
    // queue and `in_flight` are left for `client_destroy`.
    if c.state == .Closed {
        return
    }

    if c.sending {
        return
    }

    if len(c.send_queue) == 0 {
        if c.state == .Closing && c.want_close {
            finalize_close(c, c.close_code)
        }

        return
    }

    c.in_flight = c.send_queue[0]
    ordered_remove(&c.send_queue, 0)
    c.sending = true
    c.send_op = nbio.send_poly(c.socket, [][]byte{c.in_flight}, c, on_sent, {}, true, nbio.NO_TIMEOUT, c.loop)
}

// Send completion: free the written frame and continue draining the queue.
on_sent :: proc(op: ^nbio.Operation, c: ^Client) {
    c.send_op = nil

    delete(c.in_flight, c.allocator)
    c.in_flight = nil
    c.sending = false

    if op.send.err != nil {
        fail(c, .Send_Failed)
        return
    }

    pump_send(c)
}

// Latch a normal/abnormal close and tear down, reporting `code` via `On_Close`.
finalize_close :: proc(c: ^Client, code: Close_Code) {
    if c.state == .Closed {
        return
    }

    c.state = .Closed
    c.close_code = code
    teardown(c)
}

// Latch a terminal failure and tear down, reporting `err` via `On_Error`.
fail :: proc(c: ^Client, err: Client_Error) {
    if c.state == .Closed {
        return
    }

    c.state = .Closed
    c.terminal_error = err
    teardown(c)
}

// Cancel outstanding ops, close the socket, and fire the terminal callback only
// once the close completes. Deferring it lets the app free buffers from the
// callback: by then the kernel has dropped the recv/send buffers. `nbio.remove`
// stops the callback but not an in-flight kernel read/write of the buffer, so
// firing inline would use-after-free.
teardown :: proc(c: ^Client) {
    cancel_pending_ops(c)

    if c.has_socket {
        nbio.close_poly(c.socket, c, on_teardown_closed, c.loop)

        return
    }

    // Dial failed before a socket existed: nothing outstanding, nothing to close.
    fire_terminal(c)
}

// Socket close completed: canceled recv/send buffers are no longer referenced by
// the kernel, so it is safe to hand control back.
on_teardown_closed :: proc(op: ^nbio.Operation, c: ^Client) {
    fire_terminal(c)
}

// Fire exactly one terminal callback: `On_Error` when a failure was latched,
// otherwise `On_Close`.
fire_terminal :: proc(c: ^Client) {
    if c.terminal_error != .None {
        if c.cbs.on_error != nil {
            c.cbs.on_error(c, c.terminal_error)
        }

        return
    }

    if c.cbs.on_close != nil {
        c.cbs.on_close(c, c.close_code)
    }
}

// Remove each outstanding op so no completion fires into the Client after
// teardown. `nbio.remove` is final and silent: the callback never runs, even if
// its completion was already queued. An op running its own callback has already
// cleared its handle, so it is never removed here.
cancel_pending_ops :: proc(c: ^Client) {
    if c.dial_op != nil {
        nbio.remove(c.dial_op)
        c.dial_op = nil
    }

    if c.recv_op != nil {
        nbio.remove(c.recv_op)
        c.recv_op = nil
    }

    if c.send_op != nil {
        nbio.remove(c.send_op)
        c.send_op = nil
    }
}
