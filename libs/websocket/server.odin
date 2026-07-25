package websocket

import "base:runtime"
import "core:log"
import "core:mem"
import "core:nbio"
import "core:net"
import "core:time"
import http "libs:http"

// Server lifecycle: Serving -> Closing -> Closed.
Server_State :: enum {
    // Adopting connections.
    Serving,

    // `server_shutdown` was called; every live connection is draining.
    Closing,

    // Every connection released; safe to `server_destroy`.
    Closed,
}

// Per-connection lifecycle: Upgrading -> Open -> Closing -> Closed. A connection
// whose 101 never lands goes Upgrading -> Closed without surfacing.
Conn_State :: enum {
    // The 101 response is in flight.
    Upgrading,

    // 101 written; exchanging application messages.
    Open,

    // Close handshake in progress; waiting for our Close write and the peer's Close.
    Closing,

    // Fully torn down; no further callbacks will run and the connection is freed.
    Closed,
}

// Terminal failure reasons surfaced to `On_Server_Error`, plus the synchronous
// `server_adopt` refusals; only a connection that reached Open (fired `on_open`)
// surfaces a terminal callback.
Server_Error :: enum {
    // No error.
    None,

    // `server_adopt` at `max_connections`; the caller still owns the socket.
    Too_Many_Connections,

    // `server_adopt` could not allocate; the caller still owns the socket.
    Out_Of_Memory,

    // Server options or required pointers are invalid.
    Invalid_Options,

    // An outbound message exceeds the configured frame limit.
    Message_Too_Large,

    // Enqueuing would exceed the configured outbound-memory bound.
    Send_Queue_Full,

    // The requested close status is invalid on the wire.
    Invalid_Close_Code,

    // A framing/reassembly rule was violated by the peer.
    Protocol_Violation,

    // A socket write failed.
    Send_Failed,

    // A socket read failed.
    Recv_Failed,

    // The connection is not Open, so the send was refused.
    Not_Open,
}

// Protocol options. Zero-valued fields default in `server_init`.
Server_Options :: struct {
    // Reject any single inbound frame larger than this many bytes.
    max_frame_bytes:      int,

    // Reject any reassembled inbound message larger than this many bytes.
    max_message_bytes:    int,

    // Size of the buffer handed to each socket receive.
    recv_chunk_bytes:     int,

    // Hard cap on live connections; `server_adopt` past it is refused (fail closed).
    max_connections:      int,

    // Timeout applied to the 101 write.
    handshake_timeout:    time.Duration,

    // Maximum application-frame bytes pending per connection.
    max_send_queue_bytes: int,

    // Maximum wait for the peer's Close after a close handshake begins.
    close_timeout:        time.Duration,
}

// Fired once a connection completes its upgrade and the 101 has been written.
On_Server_Open :: #type proc(conn: ^Server_Conn)

// Fired for each complete message. `data` is borrowed for the call only and freed
// after; copy it to retain it.
On_Server_Message :: #type proc(conn: ^Server_Conn, kind: Message_Kind, data: []byte)

// Fired once when an Open connection closes, with the reported (or synthesized)
// code. `conn` is freed after this returns; do not retain it.
On_Server_Close :: #type proc(conn: ^Server_Conn, code: Close_Code)

// Fired once on terminal failure of an Open connection. `conn` is freed after this
// returns; do not retain it.
On_Server_Error :: #type proc(conn: ^Server_Conn, err: Server_Error)

// Fired when the send queue drains empty while Open, so a backpressure-aware
// producer can refill from the send-completion point instead of buffering a whole
// stream up front. Server-only — the client driver has no analogue.
On_Server_Drain :: #type proc(conn: ^Server_Conn)

// Per-connection application callbacks. Any field may be nil.
Server_Callbacks :: struct {
    on_open:    On_Server_Open,
    on_message: On_Server_Message,
    on_close:   On_Server_Close,
    on_error:   On_Server_Error,
    on_drain:   On_Server_Drain,
}

// A WebSocket server on a caller-supplied nbio loop. It owns no listener: an HTTP
// front door reads and validates each upgrade request and hands the socket over with
// `server_adopt`. Set up with `server_init`, stop with `server_shutdown`, reclaim
// with `server_destroy`.
Server :: struct {
    // @private
    // Borrowed event loop; the driver submits ops to it but never runs it.
    loop:                 ^nbio.Event_Loop,

    // @private
    // Allocator backing the connection set and every connection's buffers; must
    // outlive the server.
    allocator:            mem.Allocator,

    // @private
    // Lifecycle state.
    state:                Server_State,

    // Set once every connection is released after `server_shutdown`; a caller may
    // `nbio.run_until(&s.shutdown_complete)`.
    shutdown_complete:    bool,

    // @private
    // Inbound single-frame cap applied to each connection.
    max_frame_bytes:      int,

    // @private
    // Inbound reassembled-message cap applied to each connection.
    max_message_bytes:    int,

    // @private
    // Per-receive buffer size for each connection.
    recv_chunk_bytes:     int,

    // @private
    // Concurrency cap enforced by `server_adopt`.
    max_connections:      int,

    // @private
    // 101-write timeout applied to each connection.
    handshake_timeout:    time.Duration,

    // @private
    // Per-connection outbound-memory bound.
    max_send_queue_bytes: int,

    // @private
    // Per-connection closing-handshake deadline.
    close_timeout:        time.Duration,

    // @private
    // Live connections, keyed by pointer for O(1) removal at release; bounded by
    // `max_connections`, each owned by the server allocator.
    conns:                map[^Server_Conn]bool,

    // @private
    // Per-connection callbacks.
    cbs:                  Server_Callbacks,

    // Opaque application pointer, shared by every connection; a connection callback
    // reaches it as `conn.server.user_data`.
    user_data:            rawptr,
}

// One adopted connection, owned by its `Server`. Allocated by `server_adopt` and
// freed on release; the application never allocates or frees it, and must not retain
// the pointer past a terminal callback.
Server_Conn :: struct {
    // Owning server; used to remove from `conns` and free at release.
    server:             ^Server,

    // @private
    // Borrowed event loop (the server's).
    loop:               ^nbio.Event_Loop,

    // @private
    // Allocator backing every owned buffer below (the server's).
    allocator:          mem.Allocator,

    // @private
    // Adopted socket.
    socket:             net.TCP_Socket,

    // @private
    // Lifecycle state.
    state:              Conn_State,

    // @private
    // Whether `on_open` fired; a connection that dies while Upgrading releases
    // without a terminal callback.
    opened:             bool,

    // @private
    // Server-role reassembler; unmasks each inbound payload in place.
    decoder:            Decoder,

    // @private
    // Reused destination for each socket receive.
    recv_buf:           []byte,

    // @private
    // Owned 101 response bytes, freed once its send completes.
    response_buf:       []byte,

    // @private
    // Encoded frames waiting to be written, in order; each is owned.
    send_queue:         [dynamic][]byte,

    // @private
    // In-flight coalesced-send frames, in order, each owned until the vectored send
    // completes. Empty when idle; capacity is reused across sends (no allocation
    // once warm).
    send_batch:         [dynamic][]byte,

    // @private
    // True while a send is in flight.
    sending:            bool,

    // @private
    // Bytes owned by `send_queue` + `send_batch`.
    pending_send_bytes: int,

    // @private
    // Whether this endpoint's Close frame finished writing.
    close_sent:         bool,

    // @private
    // Whether a valid peer Close frame was received.
    close_received:     bool,

    // @private
    // Close code to report to `on_close` after teardown completes.
    close_code:         Close_Code,

    // @private
    // Error to report via `on_error`; `.None` selects `on_close`. Ignored unless `opened`.
    terminal_error:     Server_Error,

    // @private
    // Outstanding op handles (recv/send overlap while Open); cleared in their own
    // callback, teardown removes the rest.
    recv_op, send_op:   ^nbio.Operation,

    // @private
    // Closing-handshake deadline.
    close_timeout_op:   ^nbio.Operation,

    // @private
    // Guards exactly one terminal callback.
    terminal_fired:     bool,

    // Opaque per-connection pointer, assigned directly (nil until set). The driver
    // never touches it; free any owned state from `on_close`/`on_error`.
    user_data:          rawptr,
}

// Ready the server to adopt connections on `loop`. Does no I/O.
server_init :: proc(
    s: ^Server,
    loop: ^nbio.Event_Loop,
    options: Server_Options,
    callbacks: Server_Callbacks,
    user_data: rawptr = nil,
    allocator := context.allocator,
) -> Server_Error {
    if s == nil || loop == nil {
        return .Invalid_Options
    }

    opts := options
    if opts.max_frame_bytes == 0 {
        opts.max_frame_bytes = 1 << 20
    }
    if opts.max_message_bytes == 0 {
        opts.max_message_bytes = 1 << 20
    }
    if opts.recv_chunk_bytes == 0 {
        opts.recv_chunk_bytes = 64 << 10
    }
    if opts.max_connections == 0 {
        opts.max_connections = 1024
    }
    if opts.handshake_timeout == 0 {
        opts.handshake_timeout = 10 * time.Second
    }
    if opts.max_send_queue_bytes == 0 {
        if opts.max_frame_bytes > max(int) - MAX_HEADER_BYTES {
            return .Invalid_Options
        }

        opts.max_send_queue_bytes = max(1 << 20, opts.max_frame_bytes + MAX_HEADER_BYTES)
    }
    if opts.close_timeout == 0 {
        opts.close_timeout = 5 * time.Second
    }

    if opts.max_frame_bytes <= 0 ||
       opts.max_message_bytes <= 0 ||
       opts.recv_chunk_bytes <= 0 ||
       opts.max_connections <= 0 ||
       opts.handshake_timeout <= 0 ||
       opts.close_timeout <= 0 ||
       opts.max_frame_bytes > max(int) - MAX_HEADER_BYTES ||
       opts.max_send_queue_bytes < opts.max_frame_bytes + MAX_HEADER_BYTES ||
       opts.max_send_queue_bytes > max(int) - SEND_CONTROL_RESERVE_BYTES {
        return .Invalid_Options
    }

    conns, aerr := make(map[^Server_Conn]bool, opts.max_connections, allocator)
    if aerr != nil {
        return .Out_Of_Memory
    }

    s^ = {}
    s.loop = loop
    s.allocator = allocator
    s.state = .Serving
    s.max_frame_bytes = opts.max_frame_bytes
    s.max_message_bytes = opts.max_message_bytes
    s.recv_chunk_bytes = opts.recv_chunk_bytes
    s.max_connections = opts.max_connections
    s.handshake_timeout = opts.handshake_timeout
    s.max_send_queue_bytes = opts.max_send_queue_bytes
    s.close_timeout = opts.close_timeout
    s.conns = conns
    s.cbs = callbacks
    s.user_data = user_data

    assert(s.loop != nil, "server_init needs a loop")
    assert(s.max_frame_bytes > 0 && s.max_message_bytes > 0, "frame caps must be positive")
    assert(s.recv_chunk_bytes > 0 && s.max_connections > 0, "buffer and connection caps must be positive")
    assert(s.max_send_queue_bytes >= s.max_frame_bytes + MAX_HEADER_BYTES, "send queue cannot fit one frame")

    log.debugf("websocket server: init max_connections=%d", s.max_connections)
    return .None
}

// Take ownership of `socket` and finish an upgrade the caller already validated with
// `parse_upgrade_request`. Queues the 101; `on_open` fires from the loop once it
// lands, never before this returns. `key` is the client's `Sec-WebSocket-Key`,
// borrowed for this call; `pipelined` is whatever the peer sent past the header
// terminator and is copied into the decoder. `socket` must already be associated with
// `s.loop` (an nbio accept does that; otherwise `nbio.associate_socket`). Ownership
// transfers only on `.None` — on an error the socket is still the caller's to close.
server_adopt :: proc(
    s: ^Server,
    socket: net.TCP_Socket,
    key: string,
    pipelined: []byte = nil,
    response_headers: []http.Header = nil,
) -> (
    conn: ^Server_Conn,
    err: Server_Error,
) {
    assert(s.state == .Serving, "server_adopt on a server that is not serving")
    assert(len(key) == SEC_WEBSOCKET_KEY_ENCODED_BYTES, "server_adopt needs a validated Sec-WebSocket-Key")
    assert(len(s.conns) <= s.max_connections, "connection table over its cap")

    if len(s.conns) >= s.max_connections {
        log.warnf("websocket server: connection cap reached (%d)", s.max_connections)
        return nil, .Too_Many_Connections
    }

    c, aerr := new(Server_Conn, s.allocator)
    if aerr != nil {
        return nil, .Out_Of_Memory
    }

    c^ = {}
    c.server = s
    c.loop = s.loop
    c.allocator = s.allocator
    c.socket = socket
    c.state = .Upgrading

    if decoder_init(&c.decoder, s.max_frame_bytes, s.max_message_bytes, .Server, s.allocator) != nil {
        free(c, s.allocator)
        return nil, .Out_Of_Memory
    }

    c.recv_buf, aerr = make([]byte, s.recv_chunk_bytes, s.allocator)
    if aerr != nil {
        server_adopt_rollback(c)
        return nil, .Out_Of_Memory
    }

    c.send_queue, aerr = make([dynamic][]byte, s.allocator)
    if aerr != nil {
        server_adopt_rollback(c)
        return nil, .Out_Of_Memory
    }

    c.send_batch, aerr = make([dynamic][]byte, s.allocator)
    if aerr != nil {
        server_adopt_rollback(c)
        return nil, .Out_Of_Memory
    }

    c.response_buf, aerr = build_upgrade_response(transmute([]byte)key, s.allocator, response_headers)
    if aerr != nil {
        server_adopt_rollback(c)
        return nil, .Out_Of_Memory
    }

    // A peer may pipeline its first frame right behind the header terminator.
    if len(pipelined) > 0 && decoder_feed(&c.decoder, pipelined) != nil {
        server_adopt_rollback(c)
        return nil, .Out_Of_Memory
    }

    inserted := map_insert(&s.conns, c, true)
    assert(inserted != nil, "conns was sized for max_connections at init; an under-cap insert cannot allocate")

    // Small control frames must not wait on Nagle; best-effort.
    net.set_option(socket, .TCP_Nodelay, true)

    c.send_op = nbio.send_poly(
        socket,
        [][]byte{c.response_buf},
        c,
        conn_on_response_sent,
        {},
        true,
        s.handshake_timeout,
        c.loop,
    )

    log.debug("websocket server: connection adopted")
    return c, .None
}

@(private)
server_adopt_rollback :: proc(conn: ^Server_Conn) {
    assert(conn != nil && conn.state == .Upgrading, "adopt rollback outside Upgrading")
    assert(conn.send_op == nil && conn.recv_op == nil, "adopt rollback after I/O began")

    decoder_destroy(&conn.decoder)
    delete(conn.recv_buf, conn.allocator)
    delete(conn.response_buf, conn.allocator)
    delete(conn.send_queue)
    delete(conn.send_batch)
    free(conn, conn.allocator)
}

// Whether `server_adopt` has room; checked before a hijack, so a refusal can go out
// as an HTTP status.
server_can_adopt :: proc(s: ^Server) -> bool {
    assert(s != nil, "server_can_adopt needs a server")
    assert(len(s.conns) <= s.max_connections, "connection table over its cap")

    return s.state == .Serving && len(s.conns) < s.max_connections
}

// Close every live connection. Idempotent; closing is async (each connection closes
// on the loop), so run until `s.shutdown_complete` before calling `server_destroy`.
server_shutdown :: proc(s: ^Server) {
    assert(s != nil, "server_shutdown needs a server")

    if s.state != .Serving {
        return
    }

    log.debug("websocket server: shutdown started")
    s.state = .Closing

    for conn in s.conns {
        switch conn.state {
        case .Open:
            if close_err := conn_begin_close(conn, Close_Code.Going_Away, .Going_Away); close_err != .None {
                conn.terminal_error = close_err
                conn_finalize(conn)
            }

        case .Upgrading:
            conn.close_code = .Going_Away
            conn_finalize(conn)

        case .Closing, .Closed:
        }
    }

    maybe_finish_shutdown(s)
}

// Release the connection set. Call only after `shutdown_complete`; every connection
// must already be released.
server_destroy :: proc(s: ^Server) {
    assert(s != nil, "server_destroy needs a server")
    assert(len(s.conns) == 0, "server_destroy before all connections released")
    assert(s.state == .Serving || s.state == .Closed, "server_destroy in an invalid state")
    delete(s.conns)
    s^ = {}
}

// Queue a text message on `conn`. Fails unless the connection is Open.
server_send_text :: proc(conn: ^Server_Conn, data: []byte) -> Server_Error {
    return conn_send_data_frame(conn, .Text, data)
}

// Queue a binary message on `conn`. Fails unless the connection is Open.
server_send_binary :: proc(conn: ^Server_Conn, data: []byte) -> Server_Error {
    return conn_send_data_frame(conn, .Binary, data)
}

// Begin a graceful close of `conn` with `code`. Queues a close frame; the TCP
// close and `on_close` follow after the peer replies or the deadline expires.
server_close :: proc(conn: ^Server_Conn, code := Close_Code.Normal_Closure) -> Server_Error {
    assert(conn != nil, "server_close needs a connection")

    if conn.state != .Open {
        return .Not_Open
    }

    if !close_code_valid_on_wire(u16(code)) {
        return .Invalid_Close_Code
    }

    return conn_begin_close(conn, code, code)
}

// Fail an adopted connection when the application cannot continue safely. This is
// the terminal fallback for an internal allocation or queueing failure; it skips the
// close handshake, closes the transport, and reports `err` through `on_error`.
server_abort :: proc(conn: ^Server_Conn, err: Server_Error) {
    assert(conn != nil, "server_abort needs a connection")
    assert(err != .None && err != .Not_Open, "server_abort needs a terminal error")

    conn_fail(conn, err)
}

// Mark shutdown complete once every connection is released. Called from
// `server_shutdown` and each connection release, so whichever finishes last flips the flag.
@(private)
maybe_finish_shutdown :: proc(s: ^Server) {
    assert(s != nil, "shutdown check needs a server")
    assert(len(s.conns) <= s.max_connections, "connection table over its cap")

    if s.state == .Closing && len(s.conns) == 0 {
        s.state = .Closed
        s.shutdown_complete = true
        log.debug("websocket server: shutdown complete")
    }
}

// 101 sent: enter Open, fire `on_open`, drain any pipelined frames, then start the
// steady-state receive.
@(private)
conn_on_response_sent :: proc(op: ^nbio.Operation, conn: ^Server_Conn) {
    assert(conn.state == .Upgrading, "101 completed on a connection that was not upgrading")
    assert(!conn.opened, "a connection cannot open twice")
    assert(op == conn.send_op, "completion op doesn't match the stored handle")

    conn.send_op = nil

    if op.send.err != nil {
        conn_fail(conn, .Send_Failed)
        return
    }

    delete(conn.response_buf, conn.allocator)
    conn.response_buf = nil

    conn.state = .Open
    conn.opened = true

    if conn.server.cbs.on_open != nil {
        conn.server.cbs.on_open(conn)
    }

    // `on_open` may shut the server down, which finalizes this connection rather
    // than beginning a graceful WebSocket close.
    if conn.state == .Closed {
        return
    }

    if !conn_drain_decoder(conn) {
        return
    }

    // `on_open` or a pipelined frame may have begun a close; only read on if Open.
    if conn.state == .Open {
        conn_start_recv(conn)
    } else if conn.state == .Closing {
        conn_ensure_close_recv(conn)
    }
}

// Submit the next steady-state receive (no timeout; the peer may idle).
@(private)
conn_start_recv :: proc(conn: ^Server_Conn) {
    assert(conn.state == .Open, "steady-state recv on a connection that is not open")
    assert(conn.recv_op == nil, "a receive is already in flight")

    conn.recv_op = nbio.recv_poly(
        conn.socket,
        [][]byte{conn.recv_buf},
        conn,
        conn_on_recv,
        false,
        nbio.NO_TIMEOUT,
        conn.loop,
    )
}

// Receive completion: feed the decoder, dispatch messages, then read again.
@(private)
conn_on_recv :: proc(op: ^nbio.Operation, conn: ^Server_Conn) {
    assert(op == conn.recv_op, "receive completion does not match stored operation")
    conn.recv_op = nil

    if conn.state != .Open && conn.state != .Closing {
        return
    }

    if op.recv.err != nil {
        conn_fail(conn, .Recv_Failed)
        return
    }

    if op.recv.received == 0 {
        conn.close_code = .Abnormal_Closure
        conn_finalize(conn)
        return
    }

    if decoder_feed(&conn.decoder, conn.recv_buf[:op.recv.received]) != nil {
        conn_fail(conn, .Out_Of_Memory)
        return
    }

    if !conn_drain_decoder(conn) {
        return
    }

    if conn.state == .Open {
        conn_start_recv(conn)
    } else if conn.state == .Closing {
        conn_ensure_close_recv(conn)
    }
}

// Drain buffered messages, auto-answering control frames. Returns false once it
// has terminated the connection (protocol error or close), so the caller stops.
@(private)
conn_drain_decoder :: proc(conn: ^Server_Conn) -> bool {
    assert(conn.state == .Open || conn.state == .Closing, "decoder drain outside active states")

    for {
        // An application message callback may shut the whole server down. Preserve
        // graceful Closing drains, but stop immediately after hard teardown.
        if conn.state == .Closed {
            return false
        }

        msg, has, err := decoder_next(&conn.decoder, conn.allocator)
        if err != .None {
            conn_fail(conn, err == .Out_Of_Memory ? .Out_Of_Memory : .Protocol_Violation)
            return false
        }

        if !has {
            return true
        }

        switch msg.kind {
        case .Text, .Binary:
            if conn.state == .Open && conn.server.cbs.on_message != nil {
                conn.server.cbs.on_message(conn, msg.kind, msg.data)
            }

            delete(msg.data, conn.allocator)

        case .Ping:
            if conn.state == .Open {
                control_err := conn_enqueue_control(conn, .Pong, msg.data)
                if control_err != .None {
                    delete(msg.data, conn.allocator)
                    conn_fail(conn, control_err)
                    return false
                }
            }
            delete(msg.data, conn.allocator)

        case .Pong:
            delete(msg.data, conn.allocator)

        case .Close:
            parsed, perr := parse_close(msg.data)
            had_body := len(msg.data) != 0
            delete(msg.data, conn.allocator)
            if perr != .None {
                conn_fail(conn, .Protocol_Violation)
                return false
            }

            // Echo the peer's code only when it sent one; an empty body must be
            // answered with an empty-body close, never a synthesized 1005 (invalid
            // on the wire, RFC 6455 §7.4.1). The synthesized code is still reported
            // locally.
            wire_code: Maybe(Close_Code)
            if had_body {
                wire_code = parsed.code
            }

            conn.close_received = true
            conn.close_code = parsed.code
            if conn.state == .Open {
                if close_err := conn_begin_close(conn, wire_code, parsed.code); close_err != .None {
                    conn_fail(conn, close_err)
                }
            } else if conn.close_sent {
                conn_finalize(conn)
            }

            return false
        }
    }
}

// Queue an unmasked close frame and enter Closing. `wire_code` is serialized into
// the body; nil sends an empty-body close (needed when echoing a peer that sent
// none). `report_code` is what `on_close` receives. Idempotent once closing has begun.
@(private)
conn_begin_close :: proc(conn: ^Server_Conn, wire_code: Maybe(Close_Code), report_code: Close_Code) -> Server_Error {
    assert(conn != nil, "conn_begin_close needs a connection")

    if conn.state == .Closing || conn.state == .Closed {
        return .Not_Open
    }

    assert(conn.state == .Open, "close began outside Open")
    assert(!conn.close_sent, "new close already marked sent")
    assert(conn.close_timeout_op == nil, "new close already has a deadline")

    body: []byte
    buf: [2]byte
    if code, ok := wire_code.?; ok {
        buf[0] = byte(u16(code) >> 8)
        buf[1] = byte(code)
        body = buf[:]
    }

    frame, aerr := conn_encode(conn, .Connection_Close, body)
    if aerr != nil {
        return .Out_Of_Memory
    }

    conn.state = .Closing
    conn.close_code = report_code
    if err := conn_enqueue(conn, frame, true); err != .None {
        conn.state = .Open
        return err
    }

    conn.close_timeout_op = nbio.timeout_poly(conn.server.close_timeout, conn, conn_on_close_timeout, conn.loop)
    conn_ensure_close_recv(conn)

    return .None
}

// Encode and queue a data frame. Fails unless the connection is Open.
@(private)
conn_send_data_frame :: proc(conn: ^Server_Conn, opcode: Op_Code, data: []byte) -> Server_Error {
    assert(conn != nil, "conn_send_data_frame needs a connection")
    assert(opcode == .Text || opcode == .Binary, "data frame path given a control opcode")

    if conn.state != .Open {
        return .Not_Open
    }

    if len(data) > conn.server.max_frame_bytes {
        return .Message_Too_Large
    }

    if conn.pending_send_bytes > conn.server.max_send_queue_bytes ||
       len(data) + MAX_HEADER_BYTES > conn.server.max_send_queue_bytes - conn.pending_send_bytes {
        return .Send_Queue_Full
    }

    frame, aerr := conn_encode(conn, opcode, data)
    if aerr != nil {
        return .Out_Of_Memory
    }

    if err := conn_enqueue(conn, frame, false); err != .None {
        return err
    }

    return .None
}

// Encode one unmasked server frame (a server never masks: nil masking key).
@(private)
conn_encode :: proc(
    conn: ^Server_Conn,
    opcode: Op_Code,
    payload: []byte,
) -> (
    frame: []byte,
    err: runtime.Allocator_Error,
) #optional_allocator_error {
    assert(conn != nil, "conn_encode needs a connection")

    return encode_frame(true, opcode, payload, nil, conn.allocator)
}

// Append an owned frame to the send queue and pump the writer.
@(private)
conn_enqueue :: proc(conn: ^Server_Conn, frame: []byte, control: bool) -> Server_Error {
    assert(conn != nil, "conn_enqueue needs a connection")
    assert(len(frame) >= 2, "queued a frame smaller than its header")
    assert(
        conn.pending_send_bytes == send_queue_bytes(conn.send_queue[:], conn.send_batch[:]),
        "pending send byte mismatch",
    )

    limit := conn.server.max_send_queue_bytes
    if control {
        limit += SEND_CONTROL_RESERVE_BYTES
    }

    if conn.pending_send_bytes > limit - len(frame) {
        delete(frame, conn.allocator)
        return .Send_Queue_Full
    }

    if _, aerr := append(&conn.send_queue, frame); aerr != nil {
        delete(frame, conn.allocator)
        return .Out_Of_Memory
    }

    conn.pending_send_bytes += len(frame)
    assert(
        conn.pending_send_bytes == send_queue_bytes(conn.send_queue[:], conn.send_batch[:]),
        "queued byte accounting mismatch",
    )

    conn_pump_send(conn)

    return .None
}

@(private)
conn_enqueue_control :: proc(conn: ^Server_Conn, opcode: Op_Code, payload: []byte) -> Server_Error {
    assert(opcode == .Pong, "unexpected automatic control opcode")
    assert(len(payload) <= 125, "control payload exceeds protocol maximum")

    frame, aerr := conn_encode(conn, opcode, payload)
    if aerr != nil {
        return .Out_Of_Memory
    }

    return conn_enqueue(conn, frame, true)
}

// Coalesce queued frames into one vectored send if none is in flight (iovecs, zero
// copy; nbio retries partial sends via `all`); finalizes the TCP close once the
// queue empties during Closing.
@(private)
conn_pump_send :: proc(conn: ^Server_Conn) {
    // Terminal failure stops the pipeline: never send on a closed socket; queue
    // and `send_batch` are left for release.
    if conn.state == .Closed {
        return
    }

    if conn.sending {
        return
    }

    if len(conn.send_queue) == 0 {
        if conn.state == .Closing {
            conn.close_sent = true
            if conn.close_received {
                conn_finalize(conn)
            } else {
                conn_ensure_close_recv(conn)
            }
        }

        return
    }

    assert(len(conn.send_batch) == 0, "previous batch was not released")

    if coalesce_send_batch(&conn.send_queue, &conn.send_batch) != nil {
        conn_fail(conn, .Out_Of_Memory)
        return
    }
    assert(len(conn.send_batch) > 0, "coalesced an empty batch from a non-empty queue")

    conn.sending = true
    conn.send_op = nbio.send_poly(
        conn.socket,
        conn.send_batch[:],
        conn,
        conn_on_sent,
        {},
        true,
        nbio.NO_TIMEOUT,
        conn.loop,
    )
}

// Send completion: free every frame in the batch and continue draining the queue.
@(private)
conn_on_sent :: proc(op: ^nbio.Operation, conn: ^Server_Conn) {
    assert(conn.sending, "send completed while none was in flight")
    assert(op == conn.send_op, "send completion does not match stored operation")

    conn.send_op = nil

    for frame in conn.send_batch {
        assert(len(frame) <= conn.pending_send_bytes, "send byte accounting underflow")
        conn.pending_send_bytes -= len(frame)
        delete(frame, conn.allocator)
    }
    clear(&conn.send_batch)
    conn.sending = false
    assert(
        conn.pending_send_bytes == send_queue_bytes(conn.send_queue[:], conn.send_batch[:]),
        "sent byte accounting mismatch",
    )

    if op.send.err != nil {
        conn_fail(conn, .Send_Failed)
        return
    }

    // Queue drained while Open: signal a streaming producer to refill. It may
    // enqueue here, pumping the next send, so the trailing pump below is a no-op.
    if conn.state == .Open && len(conn.send_queue) == 0 && conn.server.cbs.on_drain != nil {
        conn.server.cbs.on_drain(conn)
    }

    conn_pump_send(conn)
}

@(private)
conn_ensure_close_recv :: proc(conn: ^Server_Conn) {
    assert(conn != nil && conn.state == .Closing, "closing receive outside Closing")

    if conn.close_received || conn.recv_op != nil {
        return
    }

    conn.recv_op = nbio.recv_poly(
        conn.socket,
        [][]byte{conn.recv_buf},
        conn,
        conn_on_recv,
        false,
        nbio.NO_TIMEOUT,
        conn.loop,
    )
}

@(private)
conn_on_close_timeout :: proc(op: ^nbio.Operation, conn: ^Server_Conn) {
    assert(conn.state == .Closing, "close deadline completed outside Closing")
    assert(op == conn.close_timeout_op, "close deadline does not match stored operation")
    conn.close_timeout_op = nil
    conn.close_code = .Abnormal_Closure

    conn_finalize(conn)
}

// Latch a terminal failure and tear down, reporting `err` via `on_error` (only if the
// connection had opened).
@(private)
conn_fail :: proc(conn: ^Server_Conn, err: Server_Error) {
    assert(conn != nil, "conn_fail needs a connection")
    assert(err != .None, "conn_fail without an error")

    if conn.state == .Closed {
        return
    }

    conn.terminal_error = err
    conn_finalize(conn)
}

// Enter Closed and tear down. Callers latch `close_code`/`terminal_error` first.
@(private)
conn_finalize :: proc(conn: ^Server_Conn) {
    assert(conn != nil, "conn_finalize needs a connection")

    if conn.state == .Closed {
        return
    }

    conn.state = .Closed
    conn_teardown(conn)
}

// Cancel outstanding ops, close the socket, and fire the terminal callback plus
// release only once the close completes. Deferring past the close mirrors the
// client driver: `nbio.remove` stops the callback but not an in-flight kernel
// read/write of a buffer, so freeing inline would use-after-free.
@(private)
conn_teardown :: proc(conn: ^Server_Conn) {
    assert(conn != nil && conn.state == .Closed, "teardown before Closed")
    assert(conn in conn.server.conns, "teardown of an unowned connection")

    conn_cancel_pending_ops(conn)

    // An adopted connection always owns a socket.
    nbio.close_poly(conn.socket, conn, conn_on_teardown_closed, conn.loop)
}

// Socket close completed: the kernel no longer references the canceled recv/send
// buffers, so it is safe to fire the terminal callback and free the connection.
@(private)
conn_on_teardown_closed :: proc(op: ^nbio.Operation, conn: ^Server_Conn) {
    conn_fire_terminal(conn)
    conn_release(conn)
}

// Fire exactly one terminal callback for an Open connection: `on_error` if a failure
// was latched, else `on_close`. A connection that never opened surfaces nothing.
@(private)
conn_fire_terminal :: proc(conn: ^Server_Conn) {
    assert(conn.state == .Closed, "terminal fired before teardown")
    assert(!conn.terminal_fired, "terminal callback fired twice")
    conn.terminal_fired = true

    if !conn.opened {
        return
    }

    if conn.terminal_error != .None {
        if conn.server.cbs.on_error != nil {
            conn.server.cbs.on_error(conn, conn.terminal_error)
        }

        return
    }

    if conn.server.cbs.on_close != nil {
        conn.server.cbs.on_close(conn, conn.close_code)
    }
}

// Free every owned buffer, drop the connection from the server, and free it;
// advances shutdown if this was the last live connection.
@(private)
conn_release :: proc(conn: ^Server_Conn) {
    s := conn.server
    assert(conn.state == .Closed, "release before teardown")
    assert(conn in s.conns, "releasing a connection the server does not own")
    assert(
        conn.pending_send_bytes == send_queue_bytes(conn.send_queue[:], conn.send_batch[:]),
        "pending send byte mismatch",
    )

    decoder_destroy(&conn.decoder)
    delete(conn.recv_buf, conn.allocator)

    if conn.response_buf != nil {
        delete(conn.response_buf, conn.allocator)
    }

    for frame in conn.send_queue {
        delete(frame, conn.allocator)
    }
    delete(conn.send_queue)

    for frame in conn.send_batch {
        delete(frame, conn.allocator)
    }
    delete(conn.send_batch)

    delete_key(&s.conns, conn)
    free(conn, s.allocator)
    assert(len(s.conns) <= s.max_connections, "connection table over its cap")

    maybe_finish_shutdown(s)
}

// Remove each outstanding op so no completion fires in after teardown. `nbio.remove`
// is final and silent; an op running its own callback already cleared its handle,
// so it's never removed here.
@(private)
conn_cancel_pending_ops :: proc(conn: ^Server_Conn) {
    if conn.recv_op != nil {
        nbio.remove(conn.recv_op)
        conn.recv_op = nil
    }

    if conn.send_op != nil {
        nbio.remove(conn.send_op)
        conn.send_op = nil
    }

    if conn.close_timeout_op != nil {
        nbio.remove(conn.close_timeout_op)
        conn.close_timeout_op = nil
    }
}
