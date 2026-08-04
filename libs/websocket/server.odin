package websocket

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
    // @private
    // Shared connection driver. Must stay first: the driver recovers this connection
    // from a `^Conn_Core`. Its lifecycle runs Upgrading -> Open -> Closing -> Closed;
    // a connection whose 101 never lands goes Upgrading -> Closed without surfacing.
    using core:   Conn_Core,

    // Owning server; used to remove from `conns` and free at release.
    server:       ^Server,

    // @private
    // Whether `on_open` fired; a connection that dies while Upgrading releases
    // without a terminal callback.
    opened:       bool,

    // @private
    // Owned 101 response bytes, freed once its send completes.
    response_buf: []byte,
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
    assert(s.max_frame_bytes > 0, "max_frame_bytes must be positive")
    assert(s.max_message_bytes > 0, "max_message_bytes must be positive")
    assert(s.recv_chunk_bytes > 0, "recv_chunk_bytes must be positive")
    assert(s.max_connections > 0, "max_connections must be positive")
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
    c.role = .Server
    c.server = s
    c.loop = s.loop
    c.allocator = s.allocator
    c.socket = socket
    c.has_socket = true
    c.state = .Upgrading
    c.message = conn_message
    c.terminal = conn_terminal
    c.drained = conn_drained

    // The shared driver reads its limits from the core only, so each connection
    // snapshots the server's at adopt time.
    c.max_frame_bytes = s.max_frame_bytes
    c.max_send_queue_bytes = s.max_send_queue_bytes
    c.close_timeout = s.close_timeout

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
            if close_err := conn_begin_close(&conn.core, Close_Code.Going_Away, .Going_Away); close_err != .None {
                conn_fail(&conn.core, close_err)
            }

        case .Upgrading:
            conn_finalize_close(&conn.core, .Going_Away)

        case .Idle, .Dialing:
            unreachable()

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
    assert(conn != nil, "server_send_text needs a connection")

    return server_error(conn_send_data_frame(&conn.core, .Text, data))
}

// Queue a binary message on `conn`. Fails unless the connection is Open.
server_send_binary :: proc(conn: ^Server_Conn, data: []byte) -> Server_Error {
    assert(conn != nil, "server_send_binary needs a connection")

    return server_error(conn_send_data_frame(&conn.core, .Binary, data))
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

    return server_error(conn_begin_close(&conn.core, code, code))
}

// Fail an adopted connection when the application cannot continue safely. This is
// the terminal fallback for an internal allocation or queueing failure; it skips the
// close handshake, closes the transport, and reports `err` through `on_error`.
server_abort :: proc(conn: ^Server_Conn, err: Server_Error) {
    assert(conn != nil, "server_abort needs a connection")
    assert(err != .None && err != .Not_Open, "server_abort needs a terminal error")

    conn_fail(&conn.core, conn_error_from_server(err))
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
        conn_fail(&conn.core, .Send_Failed)
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

    if !conn_drain_decoder(&conn.core) {
        return
    }

    // `on_open` or a pipelined frame may have begun a close; only read on if Open.
    if conn.state == .Open {
        conn_start_recv(&conn.core)
    } else if conn.state == .Closing {
        conn_ensure_close_recv(&conn.core)
    }
}

// Message dispatch adapter. `data` is borrowed for the call only; the driver frees it
// when this returns.
@(private)
conn_message :: proc(core: ^Conn_Core, kind: Message_Kind, data: []byte) {
    #assert(offset_of(Server_Conn, core) == 0)
    assert(core != nil && core.role == .Server, "server message dispatch on a non-server core")

    conn := (^Server_Conn)(core)
    if conn.server.cbs.on_message != nil {
        conn.server.cbs.on_message(conn, kind, data)
    }
}

// Terminal dispatch adapter: the driver core hands back the connection it was given,
// which is this one because `core` is its first field. Releases the connection after
// the callback; the application must not retain it.
@(private)
conn_terminal :: proc(core: ^Conn_Core) {
    assert(core != nil && core.role == .Server, "server terminal dispatch on a non-server core")

    conn := (^Server_Conn)(core)
    if conn.opened {
        if core.terminal_error != .None {
            if conn.server.cbs.on_error != nil {
                conn.server.cbs.on_error(conn, server_error(core.terminal_error))
            }
        } else if conn.server.cbs.on_close != nil {
            conn.server.cbs.on_close(conn, core.close_code)
        }
    }

    conn_release(conn)
}

// Drain adapter: the send queue emptied while Open, so a backpressure-aware producer
// can refill from the send-completion point.
@(private)
conn_drained :: proc(core: ^Conn_Core) {
    assert(core != nil && core.role == .Server, "server drain dispatch on a non-server core")

    conn := (^Server_Conn)(core)
    if conn.server.cbs.on_drain != nil {
        conn.server.cbs.on_drain(conn)
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

    delete(conn.response_buf, conn.allocator)

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
