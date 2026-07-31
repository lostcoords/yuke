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

// Client lifecycle: Dialing -> Upgrading -> Open -> Closing -> Closed. The driver
// state machine is shared with the server; see `Conn_State`.
Client_State :: Conn_State

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
    // Shared connection driver. Must stay first: the driver recovers this client
    // from a `^Conn_Core`.
    using core:        Conn_Core,

    // @private
    // Base64 Sec-WebSocket-Key sent, checked against the response accept.
    key_encoded:       [SEC_WEBSOCKET_KEY_ENCODED_BYTES]byte,

    // @private
    // Accumulates the HTTP upgrade response until its header block is complete.
    handshake_buf:     [dynamic]byte,

    // @private
    // Owned upgrade-request bytes, freed once the send completes.
    request_buf:       []byte,

    // @private
    // Owned `Host:` header value (`host:port`).
    host_header:       string,

    // @private
    // Owned request path.
    path:              string,

    // @private
    // Owned extra request headers, spliced into the upgrade request.
    extra_headers:     string,

    // @private
    // Timeout for the connect and handshake phases.
    handshake_timeout: time.Duration,

    // @private
    // Application callbacks.
    cbs:               Callbacks,
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
    c.role = .Client
    c.loop = loop
    c.allocator = allocator
    c.state = .Dialing
    c.message = client_message
    c.terminal = client_terminal
    c.max_frame_bytes = opts.max_frame_bytes
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
    assert(c.dial_op == nil, "client_destroy with dial outstanding")
    assert(c.recv_op == nil, "client_destroy with recv outstanding")
    assert(c.send_op == nil, "client_destroy with send outstanding")
    assert(c.close_timeout_op == nil, "client_destroy with close timeout outstanding")
    assert(c.pending_send_bytes == send_queue_bytes(c.send_queue[:], c.send_batch[:]), "pending send byte mismatch")

    decoder_destroy(&c.decoder)
    delete(c.recv_buf, c.allocator)
    delete(c.handshake_buf)

    delete(c.request_buf, c.allocator)

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
    assert(c != nil, "client_send_text needs a client")

    return client_error(conn_send_data_frame(&c.core, .Text, data))
}

// Queue a binary message. Fails unless the connection is Open.
client_send_binary :: proc(c: ^Client, data: []byte) -> Client_Error {
    assert(c != nil, "client_send_binary needs a client")

    return client_error(conn_send_data_frame(&c.core, .Binary, data))
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

    return client_error(conn_begin_close(&c.core, code, code))
}

// Fail a live connection when the application cannot continue safely. This is the
// terminal fallback for an internal allocation or queueing failure; it skips the
// close handshake, closes the transport, and reports `err` through `on_error`.
client_abort :: proc(c: ^Client, err: Client_Error) {
    assert(c != nil, "client_abort needs a client")
    assert(err != .None && err != .Not_Open, "client_abort needs a terminal error")

    conn_fail(&c.core, conn_error_from_client(err))
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
        // No socket was acquired; teardown must not close a zero-value fd.
        log.debugf("websocket client: dial failed: %v", op.dial.err)
        conn_fail(&c.core, .Dial_Failed)
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
        conn_fail(&c.core, .Out_Of_Memory)
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
        conn_fail(&c.core, send_timed_out(op.send.err) ? .Timed_Out : .Handshake_Failed)
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
        conn_fail(&c.core, recv_timed_out(op.recv.err) ? .Timed_Out : .Handshake_Failed)
        return
    }

    if op.recv.received == 0 {
        conn_fail(&c.core, .Handshake_Failed)
        return
    }

    if _, aerr := append(&c.handshake_buf, ..c.recv_buf[:op.recv.received]); aerr != nil {
        conn_fail(&c.core, .Out_Of_Memory)
        return
    }

    // Bound the buffer against a server that never sends `\r\n\r\n`.
    if len(c.handshake_buf) > MAX_HANDSHAKE_RESPONSE_BYTES {
        conn_fail(&c.core, .Handshake_Failed)
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
        conn_fail(&c.core, .Handshake_Failed)
        return
    }

    c.state = .Open

    // The server may pipeline the first frame right after the terminator; feed
    // those trailing bytes to the decoder before reading.
    leftover := c.handshake_buf[consumed:]
    if len(leftover) > 0 {
        if decoder_feed(&c.decoder, leftover) != nil {
            conn_fail(&c.core, .Out_Of_Memory)
            return
        }
    }

    if c.cbs.on_open != nil {
        c.cbs.on_open(c)
    }

    if !conn_drain_decoder(&c.core) {
        return
    }

    // `on_open` or a pipelined frame may have begun a close; only read on if Open.
    if c.state == .Open {
        conn_start_recv(&c.core)
    } else if c.state == .Closing {
        conn_ensure_close_recv(&c.core)
    }
}

// Message dispatch adapter. `data` is borrowed for the call only; the driver frees
// it when this returns.
@(private)
client_message :: proc(core: ^Conn_Core, kind: Message_Kind, data: []byte) {
    #assert(offset_of(Client, core) == 0)
    assert(core != nil && core.role == .Client, "client message dispatch on a non-client core")

    c := (^Client)(core)
    if c.cbs.on_message != nil {
        c.cbs.on_message(c, kind, data)
    }
}

// Terminal dispatch adapter: the driver core hands back the connection it was
// given, which is this client because `core` is its first field.
@(private)
client_terminal :: proc(core: ^Conn_Core) {
    assert(core != nil && core.role == .Client, "client terminal dispatch on a non-client core")

    c := (^Client)(core)
    if core.terminal_error != .None {
        if c.cbs.on_error != nil {
            c.cbs.on_error(c, client_error(core.terminal_error))
        }

        return
    }

    if c.cbs.on_close != nil {
        c.cbs.on_close(c, core.close_code)
    }
}
