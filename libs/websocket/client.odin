package websocket

import "base:runtime"
import "core:crypto"
import "core:encoding/base64"
import "core:log"
import "core:mem"
import "core:nbio"
import "core:net"
import "core:strconv"
import "core:strings"
import "core:time"
import http "libs:http"

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

    // Close handshake in progress; waiting for our Close write and the peer's Close.
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

    // Driver-owned storage could not be allocated.
    Out_Of_Memory,

    // An outbound message exceeds the configured frame limit.
    Message_Too_Large,

    // Enqueuing would exceed the configured outbound-memory bound.
    Send_Queue_Full,

    // The requested close status is reserved or otherwise invalid on the wire.
    Invalid_Close_Code,

    // The client is not in a state that accepts this operation.
    Not_Open,
}

// Connect and protocol options. Zero-valued fields default in `client_connect`.
Options :: struct {
    // Hostname or dotted IPv4 address (no brackets, no scheme).
    host:                 string,

    // TCP port.
    port:                 int,

    // Request path including the leading `/`.
    path:                 string,

    // Extra request headers, spliced verbatim: a run of `name: value\r\n` lines
    // (e.g. `Authorization: Bearer <token>\r\n`). Empty adds none.
    extra_headers:        string,

    // Reject any single inbound frame larger than this many bytes.
    max_frame_bytes:      int,

    // Reject any reassembled inbound message larger than this many bytes.
    max_message_bytes:    int,

    // Size of the buffer handed to each socket receive.
    recv_chunk_bytes:     int,

    // Timeout applied to the TCP connect and each handshake read/write.
    handshake_timeout:    time.Duration,

    // Maximum bytes owned by queued and in-flight application frames.
    max_send_queue_bytes: int,

    // Maximum wait for the peer's Close after a close handshake begins.
    close_timeout:        time.Duration,
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
    // @private
    // Borrowed event loop; the driver submits ops to it but never runs it.
    loop:                      ^nbio.Event_Loop,

    // @private
    // Allocator backing every owned buffer below; must outlive the client.
    allocator:                 mem.Allocator,

    // @private
    // Connected socket; valid from the dial completion onward.
    socket:                    net.TCP_Socket,

    // @private
    // Whether `socket` was acquired; guards teardown from `close(0)` when the
    // dial failed before one existed.
    has_socket:                bool,

    // @private
    // Lifecycle state.
    state:                     Client_State,

    // @private
    // Sans-IO reassembler fed by every receive.
    decoder:                   Decoder,

    // @private
    // Reused destination for each socket receive.
    recv_buf:                  []byte,

    // @private
    // Base64 Sec-WebSocket-Key sent, checked against the response accept.
    key_encoded:               [SEC_WEBSOCKET_KEY_ENCODED_BYTES]byte,

    // @private
    // Accumulates the HTTP upgrade response until its header block is complete.
    handshake_buf:             [dynamic]byte,

    // @private
    // Owned upgrade-request bytes, freed once the send completes.
    request_buf:               []byte,

    // @private
    // Owned `Host:` header value (`host:port`).
    host_header:               string,

    // @private
    // Owned request path.
    path:                      string,

    // @private
    // Owned extra request headers, spliced into the upgrade request.
    extra_headers:             string,

    // @private
    // Inbound single-frame cap (mirrors the decoder's cap for send-side checks).
    max_frame_bytes:           int,

    // @private
    // Inbound reassembled-message cap.
    max_message_bytes:         int,

    // @private
    // Timeout for the connect and handshake phases.
    handshake_timeout:         time.Duration,

    // @private
    // Maximum application-frame bytes pending in `send_queue` + `send_batch`.
    max_send_queue_bytes:      int,

    // @private
    // Bytes currently owned by `send_queue` + `send_batch`.
    pending_send_bytes:        int,

    // @private
    // Overall deadline for a WebSocket closing handshake.
    close_timeout:             time.Duration,

    // @private
    // Encoded frames waiting to be written, in order; each is owned.
    send_queue:                [dynamic][]byte,

    // @private
    // The frames of the in-flight coalesced send, in order; each is owned until the
    // one vectored send covering the whole batch completes. Empty when idle; the
    // backing capacity is reused across sends (no per-send allocation once warm).
    send_batch:                [dynamic][]byte,

    // @private
    // True while a send is in flight; gates the one-frame-at-a-time queue.
    sending:                   bool,

    // @private
    // Whether this endpoint's Close frame finished writing.
    close_sent:                bool,

    // Whether a valid peer Close frame was received.
    close_received:            bool,

    // @private
    // Close code to report to `On_Close` after teardown completes.
    close_code:                Close_Code,

    // @private
    // Error to report via `On_Error`; `.None` selects `On_Close` instead. Latched
    // before teardown so the terminal callback can fire on socket close.
    terminal_error:            Client_Error,

    // @private
    // Outstanding op handles, one per lane (recv and send overlap while Open).
    // Cleared at the top of their own callback; teardown removes the rest.
    dial_op, recv_op, send_op: ^nbio.Operation,

    // @private
    // Closing-handshake deadline; independent of the steady-state receive.
    close_timeout_op:          ^nbio.Operation,

    // @private
    // Guards exactly one terminal callback.
    terminal_fired:            bool,

    // @private
    // Application callbacks.
    cbs:                       Callbacks,

    // Opaque application pointer; a callback reaches it as `c.user_data`.
    user_data:                 rawptr,
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
    assert(c != nil, "client_connect needs client storage")

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
    if opts.max_frame_bytes > max(int) - MAX_HEADER_BYTES {
        return .Invalid_Options
    }
    if opts.max_send_queue_bytes == 0 {
        opts.max_send_queue_bytes = max(1 << 20, opts.max_frame_bytes + MAX_HEADER_BYTES)
    }
    if opts.close_timeout == 0 {
        opts.close_timeout = 5 * time.Second
    }

    if loop == nil ||
       opts.port <= 0 ||
       opts.port > 65535 ||
       opts.max_frame_bytes <= 0 ||
       opts.max_message_bytes <= 0 ||
       opts.recv_chunk_bytes <= 0 ||
       opts.handshake_timeout <= 0 ||
       opts.max_send_queue_bytes < opts.max_frame_bytes + MAX_HEADER_BYTES ||
       opts.max_send_queue_bytes > max(int) - SEND_CONTROL_RESERVE_BYTES ||
       opts.close_timeout <= 0 {
        return .Invalid_Options
    }

    if opts.host == "" || !http.field_value_valid(opts.host) || !http.request_target_valid(opts.path) {
        return .Invalid_Options
    }

    if !extra_headers_valid(opts.extra_headers) {
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
    c.max_send_queue_bytes = opts.max_send_queue_bytes
    c.close_timeout = opts.close_timeout
    c.cbs = callbacks
    c.user_data = user_data

    if decoder_init(&c.decoder, opts.max_frame_bytes, opts.max_message_bytes, .Client, allocator) != nil {
        client_connect_rollback(c)
        return .Out_Of_Memory
    }

    aerr: runtime.Allocator_Error
    c.recv_buf, aerr = make([]byte, opts.recv_chunk_bytes, allocator)
    if aerr != nil {
        client_connect_rollback(c)
        return .Out_Of_Memory
    }

    c.handshake_buf, aerr = make([dynamic]byte, allocator)
    if aerr != nil {
        client_connect_rollback(c)
        return .Out_Of_Memory
    }

    c.send_queue, aerr = make([dynamic][]byte, allocator)
    if aerr != nil {
        client_connect_rollback(c)
        return .Out_Of_Memory
    }

    c.send_batch, aerr = make([dynamic][]byte, allocator)
    if aerr != nil {
        client_connect_rollback(c)
        return .Out_Of_Memory
    }

    port_buf: [20]byte
    port := strconv.write_int(port_buf[:], i64(opts.port), 10)
    c.host_header, aerr = strings.concatenate({opts.host, ":", port}, allocator)
    if aerr != nil {
        client_connect_rollback(c)
        return .Out_Of_Memory
    }

    c.path, aerr = strings.clone(opts.path, allocator)
    if aerr != nil {
        client_connect_rollback(c)
        return .Out_Of_Memory
    }

    c.extra_headers, aerr = strings.clone(opts.extra_headers, allocator)
    if aerr != nil {
        client_connect_rollback(c)
        return .Out_Of_Memory
    }

    assert(c.pending_send_bytes == 0, "new client has pending send bytes")
    assert(c.max_send_queue_bytes >= c.max_frame_bytes + MAX_HEADER_BYTES, "send queue cannot fit one frame")

    log.debugf("websocket client: dialing %s:%d%s", opts.host, opts.port, opts.path)
    c.dial_op = nbio.dial_poly(endpoint, c, on_dial, c.handshake_timeout, loop)

    return .None
}

@(private)
client_connect_rollback :: proc(c: ^Client) {
    assert(c != nil && c.dial_op == nil, "connect rollback after I/O began")
    assert(!c.has_socket, "connect rollback owns a socket")

    c.state = .Closed
    client_destroy(c)
}

// Whether `extra_headers` is a run of complete `name: value` lines: CRLF-terminated,
// a colon after a non-empty name, no other control byte. Anything else could inject
// a header, a body, or the terminator.
@(private)
extra_headers_valid :: proc(s: string) -> bool {
    rest := s
    for len(rest) > 0 {
        line_end := strings.index(rest, "\r\n")
        if line_end < 0 {
            return false
        }

        line := rest[:line_end]
        colon := strings.index_byte(line, ':')
        if colon <= 0 ||
           !http.field_name_valid(line[:colon]) ||
           !http.field_value_valid(line[colon + 1:]) ||
           upgrade_reserved_header(line[:colon]) {
            return false
        }

        rest = rest[line_end + 2:]
    }

    return true
}

@(private)
upgrade_reserved_header :: proc(name: string) -> bool {
    return(
        strings.equal_fold(name, "host") ||
        strings.equal_fold(name, "upgrade") ||
        strings.equal_fold(name, "connection") ||
        strings.equal_fold(name, "sec-websocket-key") ||
        strings.equal_fold(name, "sec-websocket-version") ||
        strings.equal_fold(name, "content-length") ||
        strings.equal_fold(name, "transfer-encoding") \
    )
}

// Release every owned buffer. Call after Closed (post `On_Close`/`On_Error`).
// Does not touch the borrowed loop.
client_destroy :: proc(c: ^Client) {
    assert(c != nil, "client_destroy needs a client")
    assert(c.state == .Idle || c.state == .Closed, "client_destroy while active")
    assert(c.dial_op == nil && c.recv_op == nil && c.send_op == nil, "client_destroy with I/O outstanding")
    assert(c.close_timeout_op == nil, "client_destroy with close timeout outstanding")
    assert(c.pending_send_bytes == send_queue_bytes(c.send_queue[:], c.send_batch[:]), "pending send byte mismatch")

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

    for frame in c.send_batch {
        delete(frame, c.allocator)
    }
    delete(c.send_batch)

    delete(c.host_header, c.allocator)
    delete(c.path, c.allocator)
    delete(c.extra_headers, c.allocator)
    c^ = {}
}

// Queue a text message. Fails unless the connection is Open.
client_send_text :: proc(c: ^Client, data: []byte) -> Client_Error {
    return send_data_frame(c, .Text, data)
}

// Queue a binary message. Fails unless the connection is Open.
client_send_binary :: proc(c: ^Client, data: []byte) -> Client_Error {
    return send_data_frame(c, .Binary, data)
}

// Begin a graceful close with `code` and wait for the peer Close or deadline.
client_close :: proc(c: ^Client, code := Close_Code.Normal_Closure) -> Client_Error {
    assert(c != nil, "client_close needs a client")

    if c.state != .Open {
        return .Not_Open
    }

    if !close_code_valid_on_wire(u16(code)) {
        return .Invalid_Close_Code
    }

    return begin_close(c, code, code)
}

// Fail a live connection when the application cannot continue safely. This is the
// terminal fallback for an internal allocation or queueing failure; it skips the
// close handshake, closes the transport, and reports `err` through `on_error`.
client_abort :: proc(c: ^Client, err: Client_Error) {
    assert(c != nil, "client_abort needs a client")
    assert(err != .None && err != .Not_Open, "client_abort needs a terminal error")

    fail(c, err)
}

// Encode and queue a data frame, masking with a fresh random key.
@(private)
send_data_frame :: proc(c: ^Client, opcode: Op_Code, data: []byte) -> Client_Error {
    assert(c != nil, "send_data_frame needs a client")
    assert(opcode == .Text || opcode == .Binary, "data frame path given a control opcode")

    if c.state != .Open {
        return .Not_Open
    }

    if len(data) > c.max_frame_bytes {
        return .Message_Too_Large
    }

    if len(data) + MAX_HEADER_BYTES > c.max_send_queue_bytes - c.pending_send_bytes {
        return .Send_Queue_Full
    }

    frame, aerr := encode_masked(c, opcode, data)
    if aerr != nil {
        return .Out_Of_Memory
    }

    if err := enqueue_frame(c, frame, false); err != .None {
        return err
    }

    return .None
}

// Resolve `host` to an endpoint: literal IPv4 first, else DNS. DNS is blocking,
// acceptable since connect runs before the loop.
@(private)
resolve_endpoint :: proc(host: string, port: int) -> (net.Endpoint, bool) {
    if addr, ok := net.parse_ip4_address(host); ok {
        return {address = addr, port = port}, true
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
@(private)
recv_timed_out :: proc(e: net.Recv_Error) -> bool {
    tcp, ok := e.(net.TCP_Recv_Error)

    return ok && tcp == .Timeout
}

// True when a send failed specifically because it timed out.
@(private)
send_timed_out :: proc(e: net.Send_Error) -> bool {
    tcp, ok := e.(net.TCP_Send_Error)

    return ok && tcp == .Timeout
}

// Dial completion: capture the socket, then send the upgrade request.
@(private)
on_dial :: proc(op: ^nbio.Operation, c: ^Client) {
    assert(c.state == .Dialing, "dial completed outside Dialing")
    assert(op == c.dial_op, "dial completion does not match stored operation")
    c.dial_op = nil

    if op.dial.err != nil {
        // No socket was acquired; `fail` must not close a zero-value fd.
        log.debugf("websocket client: dial failed: %v", op.dial.err)
        fail(c, .Dial_Failed)
        return
    }

    c.socket = op.dial.socket
    c.has_socket = true
    c.state = .Upgrading

    // Disable Nagle's algorithm: this driver writes small frames (control frames,
    // partial messages) that must reach the peer promptly rather than being
    // coalesced. A failure here is a performance knob, not fatal; proceed either way
    // (mirrors nbio.listen_tcp's own Reuse_Address set_option, which is likewise
    // best-effort).
    net.set_option(c.socket, .TCP_Nodelay, true)

    key_raw: [SEC_WEBSOCKET_KEY_BYTES]byte
    crypto.rand_bytes(key_raw[:])
    base64.encode_into_buf(c.key_encoded[:], key_raw[:])

    request, aerr := build_upgrade_request(c.path, c.host_header, c.key_encoded[:], c.extra_headers, c.allocator)
    if aerr != nil {
        fail(c, .Out_Of_Memory)
        return
    }
    c.request_buf = request
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
@(private)
on_upgrade_sent :: proc(op: ^nbio.Operation, c: ^Client) {
    assert(c.state == .Upgrading, "upgrade request completed outside Upgrading")
    assert(op == c.send_op, "upgrade send completion does not match stored operation")
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
@(private)
on_handshake_recv :: proc(op: ^nbio.Operation, c: ^Client) {
    assert(c.state == .Upgrading, "upgrade response completed outside Upgrading")
    assert(op == c.recv_op, "upgrade receive completion does not match stored operation")
    c.recv_op = nil

    if op.recv.err != nil {
        fail(c, recv_timed_out(op.recv.err) ? .Timed_Out : .Handshake_Failed)
        return
    }

    if op.recv.received == 0 {
        fail(c, .Handshake_Failed)
        return
    }

    if _, aerr := append(&c.handshake_buf, ..c.recv_buf[:op.recv.received]); aerr != nil {
        fail(c, .Out_Of_Memory)
        return
    }

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
        if decoder_feed(&c.decoder, leftover) != nil {
            fail(c, .Out_Of_Memory)
            return
        }
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
    } else if c.state == .Closing {
        ensure_close_recv(c)
    }
}

// Submit the next steady-state receive (no timeout; the peer may idle).
@(private)
start_recv :: proc(c: ^Client) {
    assert(c.state == .Open, "steady-state recv on a client that is not open")
    assert(c.recv_op == nil, "a receive is already in flight")

    c.recv_op = nbio.recv_poly(c.socket, [][]byte{c.recv_buf}, c, on_recv, false, nbio.NO_TIMEOUT, c.loop)
}

// Receive completion: feed the decoder, dispatch messages, then read again.
@(private)
on_recv :: proc(op: ^nbio.Operation, c: ^Client) {
    assert(op == c.recv_op, "completion op doesn't match the stored handle")

    c.recv_op = nil

    if c.state != .Open && c.state != .Closing {
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

    if decoder_feed(&c.decoder, c.recv_buf[:op.recv.received]) != nil {
        fail(c, .Out_Of_Memory)
        return
    }

    if !drain_decoder(c) {
        return
    }

    if c.state == .Open {
        start_recv(c)
    } else if c.state == .Closing {
        ensure_close_recv(c)
    }
}

// Drain buffered messages. Returns false once it has terminated the connection
// (protocol error or close), so the caller stops.
@(private)
drain_decoder :: proc(c: ^Client) -> bool {
    assert(c != nil && (c.state == .Open || c.state == .Closing), "decoder drain outside active states")

    for {
        if c.state == .Closed {
            return false
        }

        msg, has, err := decoder_next(&c.decoder, c.allocator)
        if err != .None {
            fail(c, err == .Out_Of_Memory ? .Out_Of_Memory : .Protocol_Violation)
            return false
        }

        if !has {
            return true
        }

        switch msg.kind {
        case .Text, .Binary:
            if c.state == .Open && c.cbs.on_message != nil {
                c.cbs.on_message(c, msg.kind, msg.data)
            }

            delete(msg.data, c.allocator)

        case .Ping:
            if c.state == .Open {
                control_err := enqueue_control(c, .Pong, msg.data)
                if control_err != .None {
                    delete(msg.data, c.allocator)
                    fail(c, control_err)
                    return false
                }
            }
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

            c.close_received = true
            c.close_code = parsed.code
            if c.state == .Open {
                if close_err := begin_close(c, wire_code, parsed.code); close_err != .None {
                    fail(c, close_err)
                }
            } else if c.close_sent {
                finalize_close(c, parsed.code)
            }

            return false
        }
    }
}

// Queue a masked close frame and enter Closing. `wire_code` is serialized into
// the body; nil sends an empty-body close (required when echoing a peer that sent
// no code — 1005/1006 must never go on the wire). `report_code` is what `On_Close`
// receives. Idempotent once closing has begun.
@(private)
begin_close :: proc(c: ^Client, wire_code: Maybe(Close_Code), report_code: Close_Code) -> Client_Error {
    assert(c != nil, "begin_close needs a client")

    if c.state == .Closing || c.state == .Closed {
        return .Not_Open
    }

    assert(c.state == .Open, "close began outside Open")
    assert(!c.close_sent, "new close already marked sent")
    assert(c.close_timeout_op == nil, "new close already has a deadline")

    body: []byte
    buf: [2]byte
    if code, ok := wire_code.?; ok {
        buf[0] = byte(u16(code) >> 8)
        buf[1] = byte(code)
        body = buf[:]
    }

    frame, aerr := encode_masked(c, .Connection_Close, body)
    if aerr != nil {
        return .Out_Of_Memory
    }

    c.state = .Closing
    c.close_code = report_code
    if err := enqueue_frame(c, frame, true); err != .None {
        c.state = .Open
        return err
    }

    c.close_timeout_op = nbio.timeout_poly(c.close_timeout, c, on_close_timeout, c.loop)
    ensure_close_recv(c)

    return .None
}

// Encode one masked client frame from a fresh random masking key.
@(private)
encode_masked :: proc(
    c: ^Client,
    opcode: Op_Code,
    payload: []byte,
) -> (
    frame: []byte,
    err: runtime.Allocator_Error,
) #optional_allocator_error {
    assert(c != nil, "encode_masked needs a client")

    key: [MASK_KEY_BYTES]byte
    crypto.rand_bytes(key[:])

    return encode_frame(true, opcode, payload, key, c.allocator)
}

// Append an owned frame to the send queue and pump the writer.
@(private)
enqueue_frame :: proc(c: ^Client, frame: []byte, control: bool) -> Client_Error {
    assert(c != nil, "enqueue_frame needs a client")
    assert(len(frame) >= 2, "queued a frame smaller than its header")
    assert(c.pending_send_bytes == send_queue_bytes(c.send_queue[:], c.send_batch[:]), "pending send byte mismatch")

    limit := c.max_send_queue_bytes
    if control {
        limit += SEND_CONTROL_RESERVE_BYTES
    }

    if c.pending_send_bytes > limit - len(frame) {
        delete(frame, c.allocator)
        return .Send_Queue_Full
    }

    if _, aerr := append(&c.send_queue, frame); aerr != nil {
        delete(frame, c.allocator)
        return .Out_Of_Memory
    }

    c.pending_send_bytes += len(frame)
    assert(
        c.pending_send_bytes == send_queue_bytes(c.send_queue[:], c.send_batch[:]),
        "queued byte accounting mismatch",
    )

    pump_send(c)

    return .None
}

@(private)
enqueue_control :: proc(c: ^Client, opcode: Op_Code, payload: []byte) -> Client_Error {
    assert(opcode == .Pong, "unexpected automatic control opcode")
    assert(len(payload) <= 125, "control payload exceeds protocol maximum")

    frame, aerr := encode_masked(c, opcode, payload)
    if aerr != nil {
        return .Out_Of_Memory
    }

    return enqueue_frame(c, frame, true)
}

// Coalesce the queued frames into one vectored send if none is in flight. Whole
// frames are submitted as iovecs (zero copy); nbio owns the partial-send retry via
// `all`. Finalizes the TCP close when the queue empties during Closing.
@(private)
pump_send :: proc(c: ^Client) {
    // A terminal failure stops the pipeline: never send on a closed socket. The
    // queue and `send_batch` are left for `client_destroy`.
    if c.state == .Closed {
        return
    }

    if c.sending {
        return
    }

    if len(c.send_queue) == 0 {
        if c.state == .Closing {
            c.close_sent = true
            if c.close_received {
                finalize_close(c, c.close_code)
            } else {
                ensure_close_recv(c)
            }
        }

        return
    }

    assert(len(c.send_batch) == 0, "previous batch was not released")

    if coalesce_send_batch(&c.send_queue, &c.send_batch) != nil {
        fail(c, .Out_Of_Memory)
        return
    }
    assert(len(c.send_batch) > 0, "coalesced an empty batch from a non-empty queue")

    c.sending = true
    c.send_op = nbio.send_poly(c.socket, c.send_batch[:], c, on_sent, {}, true, nbio.NO_TIMEOUT, c.loop)
}

// Send completion: free every frame in the batch and continue draining the queue.
@(private)
on_sent :: proc(op: ^nbio.Operation, c: ^Client) {
    assert(c.sending, "send completed while none was in flight")
    assert(op == c.send_op, "completion op doesn't match the stored handle")

    c.send_op = nil

    for frame in c.send_batch {
        assert(len(frame) <= c.pending_send_bytes, "send byte accounting underflow")
        c.pending_send_bytes -= len(frame)
        delete(frame, c.allocator)
    }
    clear(&c.send_batch)
    c.sending = false
    assert(c.pending_send_bytes == send_queue_bytes(c.send_queue[:], c.send_batch[:]), "sent byte accounting mismatch")

    if op.send.err != nil {
        fail(c, .Send_Failed)
        return
    }

    pump_send(c)
}

@(private)
ensure_close_recv :: proc(c: ^Client) {
    assert(c != nil && c.state == .Closing, "closing receive outside Closing")

    if c.close_received || c.recv_op != nil {
        return
    }

    c.recv_op = nbio.recv_poly(c.socket, [][]byte{c.recv_buf}, c, on_recv, false, nbio.NO_TIMEOUT, c.loop)
}

@(private)
on_close_timeout :: proc(op: ^nbio.Operation, c: ^Client) {
    assert(c.state == .Closing, "close deadline completed outside Closing")
    assert(op == c.close_timeout_op, "close deadline does not match stored operation")
    c.close_timeout_op = nil

    finalize_close(c, .Abnormal_Closure)
}

// Latch a normal/abnormal close and tear down, reporting `code` via `On_Close`.
@(private)
finalize_close :: proc(c: ^Client, code: Close_Code) {
    if c.state == .Closed {
        return
    }

    c.state = .Closed
    c.close_code = code
    teardown(c)
}

// Latch a terminal failure and tear down, reporting `err` via `On_Error`.
@(private)
fail :: proc(c: ^Client, err: Client_Error) {
    assert(err != .None, "fail without an error")

    if c.state == .Closed {
        return
    }

    log.debugf("websocket client: fail %v", err)

    c.state = .Closed
    c.terminal_error = err
    teardown(c)
}

// Cancel outstanding ops, close the socket, and fire the terminal callback only
// once the close completes. Deferring it lets the app free buffers from the
// callback: by then the kernel has dropped the recv/send buffers. `nbio.remove`
// stops the callback but not an in-flight kernel read/write of the buffer, so
// firing inline would use-after-free.
@(private)
teardown :: proc(c: ^Client) {
    assert(c != nil && c.state == .Closed, "teardown before Closed")
    assert(c.terminal_error != .None || c.close_code != Close_Code(0), "teardown without terminal outcome")

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
@(private)
on_teardown_closed :: proc(op: ^nbio.Operation, c: ^Client) {
    fire_terminal(c)
}

// Fire exactly one terminal callback: `On_Error` when a failure was latched,
// otherwise `On_Close`.
@(private)
fire_terminal :: proc(c: ^Client) {
    assert(c.state == .Closed, "terminal fired before teardown")
    assert(!c.terminal_fired, "terminal callback fired twice")
    c.terminal_fired = true

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
@(private)
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

    if c.close_timeout_op != nil {
        nbio.remove(c.close_timeout_op)
        c.close_timeout_op = nil
    }
}
