package http_server

import "base:runtime"
import "core:log"
import "core:mem"
import "core:nbio"
import "core:net"
import "core:strconv"
import "core:strings"
import "core:time"
import dt "core:time/datetime"
import http "libs:http"

Status :: http.Status
Header :: http.Header

// Synchronous `listen` failures.
Error :: enum {
    None,
    Invalid_Options,
    Out_Of_Memory,
    Listen_Failed,
}

// Errors returned before a response takes ownership of its inputs.
Response_Error :: enum {
    None,
    Invalid_Header,
    Out_Of_Memory,
}

// Listen and request-reading options. Zero-valued fields default in `listen`.
Options :: struct {
    // Dotted IPv4 bind address (no scheme). Defaults to `127.0.0.1`.
    host:             string,

    // TCP port to bind. Zero requests an ephemeral port.
    port:             int,

    // Hard cap on connections not yet answered or hijacked.
    max_connections:  int,

    // Exact ceiling on the request head, including its terminating CRLF pair.
    max_head_bytes:   int,

    // Size of the reusable socket receive buffer.
    recv_chunk_bytes: int,

    // Absolute request-head deadline and per-response write timeout.
    request_timeout:  time.Duration,

    // Absolute deadline on a whole `receive_body` transfer. The per-recv idle timeout
    // alone cannot bound it: one byte per interval keeps a connection slot forever.
    body_timeout:     time.Duration,
}

// One validated request handed to `On_Request`. All fields borrow the connection
// and remain valid only for the callback.
Request :: struct {
    head:           http.Request_Head,

    // Target up to `?`, always leading-slash origin form. Split once by the driver.
    path:           string,

    // Target after `?`, empty when absent. Still percent-encoded.
    query:          string,

    // Bytes read past the head: for a bodyless route the leading pipelined/upgrade
    // bytes; for a body-bearing route the leading bytes of the request body.
    trailing:       []byte,

    // Declared request-body length from Content-Length (0 when absent). The handler
    // enforces its own size cap on this before opting into `receive_body`.
    content_length: i64,

    // Bytes arrived past the declared body: a pipelined follow-up request is waiting.
    // A route either refuses it or lets the close discard it — except a hijacking
    // route, which keeps them; for an upgrade they are the peer's eager first frame.
    pipelined:      bool,
}

// Fired once per connection. The handler must respond, hijack, or opt into streaming
// the request body with `receive_body` before returning.
On_Request :: #type proc(c: ^Conn, req: Request)

// Sink for one bounded request-body chunk. `chunk` borrows the recv buffer and is
// valid only for the call. Returning false aborts the transfer: the server finalizes
// the connection and fires `On_Body_End` with `ok = false`. Called zero or more times
// before `On_Body_End`.
On_Body_Chunk :: #type proc(c: ^Conn, user_data: rawptr, chunk: []byte) -> bool

// Fired exactly once to close out a `receive_body`. `ok = true` means the whole
// declared body was delivered and the connection is back in a state to `respond`;
// `ok = false` means the transfer failed (short body, peer reset, timeout, or a sink
// abort) and the connection is already being finalized — the callback must free its
// own state but must not touch the connection.
On_Body_End :: #type proc(c: ^Conn, user_data: rawptr, ok: bool)

// Server lifecycle: Idle -> Serving -> Closing -> Closed.
Server_State :: enum {
    Idle,
    Serving,
    Closing,
    Closed,
}

// A one-request HTTP/1.1 front door driven by a caller-owned nbio loop.
Server :: struct {
    // @private
    // Borrowed event loop; the caller owns and runs it.
    loop:              ^nbio.Event_Loop,

    // @private
    // Backs the connection map and every owned `Conn`; outlives `destroy`.
    allocator:         mem.Allocator,

    // Bound listen socket; exposed so callers can inspect an ephemeral port.
    socket:            net.TCP_Socket,

    // Address the listen socket is bound to, as `Options.host` resolved it.
    bind_address:      net.IP4_Address,

    // @private
    // Current lifecycle state; see `Server_State`.
    state:             Server_State,

    // @private
    listen_closed:     bool,

    // Set after the listen socket and every owned connection are closed.
    shutdown_complete: bool,

    // @private
    // Resolved connection cap copied from `Options` in `listen`.
    max_connections:   int,

    // @private
    // Resolved request-head ceiling copied from `Options` in `listen`.
    max_head_bytes:    int,

    // @private
    // Resolved recv-buffer size copied from `Options` in `listen`.
    recv_chunk_bytes:  int,

    // @private
    // Resolved head deadline and write timeout copied from `Options` in `listen`.
    request_timeout:   time.Duration,

    // @private
    // Resolved whole-body transfer deadline copied from `Options` in `listen`.
    body_timeout:      time.Duration,

    // @private
    // Owned connections, keyed by the ticket that outlives them.
    conns:             map[Ticket]^Conn,

    // @private
    // Monotonic ticket source; incremented before use so zero is never issued.
    next_ticket:       Ticket,

    // @private
    // In-flight accept operation; nil when disarmed.
    accept_op:         ^nbio.Operation,

    // @private
    // Per-connection request callback.
    on_request:        On_Request,

    // Opaque application pointer available through `c.server.user_data`.
    user_data:         rawptr,
}

// Per-connection lifecycle: Reading -> Responding -> Closed, or Reading -> Hijacked.
// A body-bearing route may take the Reading -> Receiving_Body -> Reading -> Responding
// path while `receive_body` streams the request body. A handler answering from work it
// started elsewhere inserts Reading -> Deferred -> Responding; `conn_can_respond` is the
// one place that says which of these states still owes the peer an answer.
Conn_State :: enum {
    Reading,
    Receiving_Body,
    Deferred,
    Responding,
    Hijacked,
    Closed,
}

// A connection identity that outlives the connection. Handed to work that may finish
// after the connection is gone — an offloaded filesystem task, for example — so it can
// ask whether there is still anyone to answer instead of holding a dangling `^Conn`.
// Never reused, so a stale ticket resolves to `nil` rather than to a later connection.
// Zero is not a connection and always resolves to `nil`.
Ticket :: distinct u64

// One accepted connection owned by its `Server` until response or hijack.
Conn :: struct {
    // Owning server.
    server:            ^Server,

    // Borrowed event loop.
    loop:              ^nbio.Event_Loop,

    // Allocator backing all owned storage.
    allocator:         mem.Allocator,

    // @private
    // Identity that outlives this connection; read through `conn_ticket`. See `Ticket`.
    ticket:            Ticket,

    // @private
    // TCP socket; owned until `hijack` or finalize.
    socket:            net.TCP_Socket,

    // @private
    // Current lifecycle state; see `Conn_State`.
    state:             Conn_State,

    // @private
    // Accumulates request-head bytes until the terminating CRLFCRLF.
    head_buf:          [dynamic]byte,

    // @private
    // Byte offset already scanned for the terminator; avoids rescanning appends.
    scanned:           int,

    // @private
    // Bytes of `head_buf` consumed by the request head; the remainder is the leading
    // request body during a body receive.
    head_consumed:     int,

    // @private
    // Set for a HEAD request: responses carry their headers but no content
    // (RFC 9110 §9.3.2).
    head_request:      bool,

    // @private
    // Declared request-body bytes still to deliver during a body receive.
    body_remaining:    i64,

    // @private
    // Application body sink; nil outside a body receive.
    body_on_chunk:     On_Body_Chunk,

    // @private
    // Application body completion callback; nil outside a body receive. Non-nil is the
    // single signal that a `receive_body` is owed an end notification.
    body_on_end:       On_Body_End,

    // @private
    // Opaque application pointer threaded to the body callbacks.
    body_user:         rawptr,

    // @private
    // Reusable recv scratch, sliced into each recv operation.
    recv_buf:          []byte,

    // @private
    // Headers for whatever response eventually goes out, including a router fallback, a
    // deferred answer, and the `hijack` handoff. Names and values are owned clones.
    pending:           [dynamic]Header,

    // @private
    // Owned serialized response head.
    resp_head:         []byte,

    // @private
    // Owned body: caller copy for `respond`, or failure text for a rejected file.
    resp_body:         []byte,

    // @private
    // Owned serialized extra-header bytes.
    resp_extra:        []byte,

    // @private
    // Two-slot gather for the head and optional body send.
    send_bufs:         [2][]byte,

    // @private
    // File handle for `sendfile`; owned only when `owns_file` is set.
    file:              nbio.Handle,

    // @private
    // True once `respond_file` took ownership; the file is closed on finalize.
    owns_file:         bool,

    // @private
    // Owned clone of the file response's content type.
    file_content_type: string,

    // @private
    // Owned failure body, consumed if the stat rejects the file.
    file_failure_body: []byte,

    // @private
    // Status emitted when the file is rejected.
    file_failure:      Status,

    // @private
    // Status emitted on a successful file send.
    file_status:       Status,

    // @private
    // Upper bound on accepted file size.
    file_max_bytes:    i64,

    // @private
    // Statted size sent via `sendfile`.
    file_bytes:        int,

    // @private
    // Outstanding resource-close completions before release.
    close_pending:     int,

    // @private
    // In-flight recv operation; nil when not armed.
    recv_op:           ^nbio.Operation,

    // @private
    // In-flight head/body send; nil when not armed.
    send_op:           ^nbio.Operation,

    // @private
    // In-flight head or body deadline; nil when cancelled or fired.
    timeout_op:        ^nbio.Operation,

    // @private
    // In-flight stat/sendfile; nil when not armed.
    file_op:           ^nbio.Operation,
}

// Bind and arm the accept loop. The caller owns and runs `loop`.
listen :: proc(
    s: ^Server,
    loop: ^nbio.Event_Loop,
    options: Options,
    on_request: On_Request,
    user_data: rawptr = nil,
    allocator := context.allocator,
) -> Error {
    if s == nil || loop == nil || on_request == nil {
        return .Invalid_Options
    }

    opts := options
    if opts.host == "" {
        opts.host = "127.0.0.1"
    }
    if opts.max_connections == 0 {
        opts.max_connections = 512
    }
    if opts.max_head_bytes == 0 {
        opts.max_head_bytes = 64 << 10
    }
    if opts.recv_chunk_bytes == 0 {
        opts.recv_chunk_bytes = 8 << 10
    }
    if opts.request_timeout == 0 {
        opts.request_timeout = 10 * time.Second
    }
    if opts.body_timeout == 0 {
        opts.body_timeout = 60 * time.Second
    }

    if opts.port < 0 ||
       opts.port > 65535 ||
       opts.max_connections <= 0 ||
       opts.max_head_bytes < 4 ||
       opts.recv_chunk_bytes <= 0 ||
       opts.request_timeout <= 0 ||
       opts.body_timeout <= 0 {
        return .Invalid_Options
    }

    addr, ok := net.parse_ip4_address(opts.host)
    if !ok {
        return .Invalid_Options
    }

    conns, aerr := make(map[Ticket]^Conn, opts.max_connections, allocator)
    if aerr != nil {
        return .Out_Of_Memory
    }

    socket, listen_err := nbio.listen_tcp({address = addr, port = opts.port}, 1000, loop)
    if listen_err != nil {
        delete(conns)
        return .Listen_Failed
    }

    s^ = {}
    s.loop = loop
    s.allocator = allocator
    s.socket = socket
    s.bind_address = addr
    s.state = .Serving
    s.max_connections = opts.max_connections
    s.max_head_bytes = opts.max_head_bytes
    s.recv_chunk_bytes = opts.recv_chunk_bytes
    s.request_timeout = opts.request_timeout
    s.body_timeout = opts.body_timeout
    s.conns = conns
    s.on_request = on_request
    s.user_data = user_data

    assert(s.max_connections > 0, "connection cap must be positive")
    assert(s.max_head_bytes >= 4, "max_head_bytes must fit the \\r\\n\\r\\n terminator")
    assert(s.recv_chunk_bytes > 0, "recv_chunk_bytes must be positive")

    arm_accept(s)
    log.debugf("http_server: listening on %s:%d max_connections=%d", opts.host, opts.port, opts.max_connections)

    return .None
}

// Stop accepting and close every owned connection. Idempotent and asynchronous.
shutdown :: proc(s: ^Server) {
    assert(s != nil, "shutdown needs a server")

    if s.state != .Serving {
        return
    }

    log.debug("http_server: shutdown started")
    s.state = .Closing
    if s.accept_op != nil {
        nbio.remove(s.accept_op)
        s.accept_op = nil
    }

    nbio.close_poly(s.socket, s, on_listen_closed, s.loop)
    for _, c in s.conns {
        if c.state != .Hijacked {
            conn_finalize(c)
        }
    }

    maybe_finish_shutdown(s)
}

// Release the connection map after shutdown completes.
destroy :: proc(s: ^Server) {
    assert(s != nil, "destroy needs a server")
    assert(len(s.conns) == 0, "destroy before all connections released")
    assert(s.state == .Idle || s.state == .Closed, "destroy while server is active")

    delete(s.conns)
    s^ = {}
}

// Address the listen socket actually bound, so callers compare against what is served
// rather than re-deriving it from their options.
bound_address :: proc(s: ^Server) -> (addr: net.Address, ok: bool) {
    assert(s != nil, "bound_address needs a server")

    ep, err := net.bound_endpoint(s.socket)
    if err != nil {
        return nil, false
    }

    return ep.address, true
}

// TCP port of the bound listen socket. Useful after `listen` with port 0.
bound_port :: proc(s: ^Server) -> int {
    assert(s != nil, "bound_port needs a server")

    ep, err := net.bound_endpoint(s.socket)
    if err != nil {
        return 0
    }

    return ep.port
}

// Answer the request, aborting if the response cannot be built. `body` is copied, so
// caller-supplied response bytes need not outlive this call. Any header beyond the
// framing fields comes from `conn_add_header`.
respond :: proc(c: ^Conn, status: Status, content_type: string, body: []byte) {
    abort_failed_response(c, try_respond(c, status, content_type, body))
}

// `respond`, reporting the failure instead of aborting. Nothing was written, so the
// connection can still be answered.
@(require_results)
try_respond :: proc(c: ^Conn, status: Status, content_type: string, body: []byte) -> Response_Error {
    assert(c != nil, "respond needs a connection")
    assert(conn_can_respond(c), "respond on an answered connection")

    extra, response_err := serialize_pending_headers(c)
    if response_err != .None {
        return response_err
    }

    // A HEAD response advertises the length it would have sent; `conn_send_head_and_body`
    // is what withholds the content, so this only avoids a pointless copy.
    body_copy: []byte
    if len(body) > 0 && !c.head_request {
        aerr: runtime.Allocator_Error
        body_copy, aerr = make([]byte, len(body), c.allocator)
        if aerr != nil {
            delete(extra, c.allocator)
            return .Out_Of_Memory
        }
        copy(body_copy, body)
    }

    head, aerr := build_response_head(status, content_type, len(body), extra, c.allocator)
    if aerr != nil {
        delete(extra, c.allocator)
        delete(body_copy, c.allocator)
        return .Out_Of_Memory
    }

    c.resp_extra = extra
    c.resp_head = head
    c.resp_body = body_copy
    conn_begin_response(c)
    conn_send_head_and_body(c)

    return .None
}

// `respond` with a `text/plain` body.
respond_text :: proc(c: ^Conn, status: Status, text: string) {
    respond(c, status, "text/plain; charset=utf-8", transmute([]byte)text)
}

// `try_respond` with a `text/plain` body.
@(require_results)
try_respond_text :: proc(c: ^Conn, status: Status, text: string) -> Response_Error {
    return try_respond(c, status, "text/plain; charset=utf-8", transmute([]byte)text)
}

// Redirect to `location` with an empty body, aborting if the response cannot be built.
// `status` must carry a target (RFC 9110 §15.4); the target may not also be pending,
// since two `Location` fields would be ambiguous.
respond_redirect :: proc(c: ^Conn, status: Status, location: string) {
    abort_failed_response(c, try_respond_redirect(c, status, location))
}

// `respond_redirect`, reporting the failure instead of aborting.
@(require_results)
try_respond_redirect :: proc(c: ^Conn, status: Status, location: string) -> Response_Error {
    assert(c != nil, "respond_redirect needs a connection")
    assert(conn_can_respond(c), "respond_redirect on an answered connection")
    assert(http.status_is_redirect(status), "respond_redirect needs a redirect that carries a target")

    if len(location) == 0 || !http.field_value_valid(location) {
        return .Invalid_Header
    }

    if header_present(c.pending[:], "location") {
        return .Invalid_Header
    }

    try_conn_add_header(c, "Location", location) or_return

    return try_respond(c, status, "", nil)
}

// Answer from an open file, aborting if the response cannot be built. Ownership of `file`
// always transfers. An invalid, unavailable, or oversized file receives the supplied small
// failure response.
respond_file :: proc(
    c: ^Conn,
    status: Status,
    content_type: string,
    file: nbio.Handle,
    max_file_bytes: i64,
    failure_status: Status,
    failure_text: string,
) {
    err := try_respond_file(c, status, content_type, file, max_file_bytes, failure_status, failure_text)
    if err == .None {
        return
    }

    nbio.close(file, l = c.loop)
    abort_failed_response(c, err)
}

// `respond_file`, reporting the failure instead of aborting. Ownership of `file` transfers
// only on `.None`; the post-transfer stat keeps `Content-Length` and `max_file_bytes`
// describing the same open file.
@(require_results)
try_respond_file :: proc(
    c: ^Conn,
    status: Status,
    content_type: string,
    file: nbio.Handle,
    max_file_bytes: i64,
    failure_status: Status,
    failure_text: string,
) -> Response_Error {
    assert(c != nil, "respond_file needs a connection")
    assert(conn_can_respond(c), "respond_file on an answered connection")
    assert(max_file_bytes >= 0, "file response needs a non-negative byte cap")

    if !http.field_value_valid(content_type) {
        return .Invalid_Header
    }

    extra, response_err := serialize_pending_headers(c)
    if response_err != .None {
        return response_err
    }

    owned_content_type, aerr := strings.clone(content_type, c.allocator)
    if aerr != nil {
        delete(extra, c.allocator)
        return .Out_Of_Memory
    }

    failure_body: []byte
    failure_body, aerr = make([]byte, len(failure_text), c.allocator)
    if aerr != nil {
        delete(extra, c.allocator)
        delete(owned_content_type, c.allocator)
        return .Out_Of_Memory
    }
    copy(failure_body, transmute([]byte)failure_text)

    c.resp_extra = extra
    c.file_content_type = owned_content_type
    c.file_failure_body = failure_body
    c.file_failure = failure_status
    c.file_status = status
    c.file_max_bytes = max_file_bytes
    c.file = file
    c.owns_file = true
    conn_begin_response(c)
    c.file_op = nbio.stat_poly(file, c, conn_on_file_stat, c.loop)

    return .None
}

// Hand the socket to another protocol. The caller becomes responsible for closing it,
// and for emitting `headers` itself — nothing in the `respond*` path runs for a hijacked
// connection. `headers` borrows the connection, as the returned trailing bytes do, and is
// valid only until the handler returns.
hijack :: proc(c: ^Conn) -> (socket: net.TCP_Socket, loop: ^nbio.Event_Loop, headers: []Header) {
    assert(c != nil && c.state == .Reading, "hijack on an answered connection")

    conn_cancel_timeout(c)
    c.state = .Hijacked
    log.debug("http_server: connection hijacked")

    return c.socket, c.loop, c.pending[:]
}

// Stream the request body to the handler instead of responding immediately. Called
// once from within `On_Request` for a body-bearing route: each received slice is
// delivered to `on_chunk`, and `on_end` fires exactly once when the whole declared
// body arrives (`ok = true`, connection back in `Reading` so the handler can `respond`)
// or the transfer fails (`ok = false`, connection already finalizing). The server caps
// each recv at the declared remainder, so it never reads into a following request and
// only ever holds one recv buffer of body in memory. The caller must have already
// bounded `req.content_length` against its own size limit.
receive_body :: proc(c: ^Conn, user_data: rawptr, on_chunk: On_Body_Chunk, on_end: On_Body_End) {
    assert(c != nil && c.state == .Reading, "receive_body on an answered connection")
    assert(on_chunk != nil && on_end != nil, "receive_body needs both callbacks")
    assert(c.body_on_end == nil, "receive_body called twice on one request")

    // Replace the head deadline with one covering the whole transfer. The per-recv
    // idle timeout resets on every byte, so only this bounds total time.
    conn_cancel_timeout(c)
    c.timeout_op = nbio.timeout_poly(c.server.body_timeout, c, conn_on_timeout, c.loop)

    c.state = .Receiving_Body
    c.body_on_chunk = on_chunk
    c.body_on_end = on_end
    c.body_user = user_data

    // The bytes past the head are the leading body bytes; deliver those before any
    // further recv so a body that fully arrived with the head completes at once.
    trailing := c.head_buf[c.head_consumed:]
    if len(trailing) > 0 {
        take := int(min(i64(len(trailing)), c.body_remaining))
        if take > 0 && !deliver_body_chunk(c, trailing[:take]) {
            return
        }
    }

    if c.body_remaining == 0 {
        body_complete(c)
        return
    }

    arm_body_recv(c)
}

// Whether this connection still owes the peer an answer. The single definition of that
// question: `respond*` accept exactly these states, and `conn_resolve` hands back only a
// connection satisfying it.
conn_can_respond :: proc(c: ^Conn) -> bool {
    assert(c != nil, "answerability needs a connection")

    switch c.state {
    case .Reading, .Deferred:
        return true

    case .Receiving_Body, .Responding, .Hijacked, .Closed:
        return false
    }

    return false
}

// Whether `pending` will still be read, which is the whole request phase: a body receive
// accumulates headers just as the handler does. Wider than `conn_can_respond` on purpose.
// A hijacked connection already handed its headers to the adopting protocol.
@(private)
conn_can_add_header :: proc(c: ^Conn) -> bool {
    assert(c != nil, "header legality needs a connection")

    switch c.state {
    case .Reading, .Receiving_Body, .Deferred:
        return true

    case .Responding, .Hijacked, .Closed:
        return false
    }

    return false
}

// Add a header to whatever response this connection eventually sends, so a pre-match step
// can mark every downstream response without every response site repeating it. `name` and
// `value` are cloned, so neither need outlive this call. `false` means the connection was
// aborted and the caller must stop rather than answer.
conn_add_header :: proc(c: ^Conn, name: string, value: string) -> (ok: bool) {
    if err := try_conn_add_header(c, name, value); err != .None {
        log.errorf("http_server: response header %s rejected: %v", name, err)
        abort(c)

        return false
    }

    return true
}

// `conn_add_header`, reporting the refusal instead of aborting.
@(require_results)
try_conn_add_header :: proc(c: ^Conn, name: string, value: string) -> Response_Error {
    assert(c != nil, "adding a header needs a connection")
    assert(conn_can_add_header(c), "response header added after the head was built")

    if !http.field_name_valid(name) || !http.field_value_valid(value) || reserved_field(name) {
        return .Invalid_Header
    }

    if header_present(c.pending[:], name) {
        return .Invalid_Header
    }

    owned_name, aerr := strings.clone(name, c.allocator)
    if aerr != nil {
        return .Out_Of_Memory
    }

    owned_value: string
    owned_value, aerr = strings.clone(value, c.allocator)
    if aerr != nil {
        delete(owned_name, c.allocator)
        return .Out_Of_Memory
    }

    if _, aerr = append(&c.pending, Header{name = owned_name, value = owned_value}); aerr != nil {
        delete(owned_name, c.allocator)
        delete(owned_value, c.allocator)
        return .Out_Of_Memory
    }

    return .None
}

// Declare that this request will be answered later, from work the handler has already
// started elsewhere. Without this a handler must respond before returning, because the
// connection is otherwise left with nothing armed and no response owed.
//
// The request deadline is re-armed, so a deferred answer that never arrives finalizes the
// connection rather than holding it forever. Nothing is armed on the socket meanwhile, so
// that deadline is also the only thing that notices a peer disconnecting mid-answer. A
// handler that has deferred must therefore tolerate the connection being gone by the time
// it is ready — resolve a `Ticket` rather than retaining the `^Conn`.
//
// A deferred request may only be answered, never hijacked and never switched to a body
// receive: both belong to the request phase this one has already left.
defer_response :: proc(c: ^Conn) {
    assert(c != nil, "deferring needs a connection")
    assert(c.state == .Reading, "response deferred outside Reading")

    // Whatever deadline is armed measures the wrong thing now: a handler deferring from
    // `on_request` still carries the head deadline, and one deferring from a body-end
    // callback carries none. Replace it either way with a deadline on the answer.
    conn_cancel_timeout(c)

    c.state = .Deferred
    c.timeout_op = nbio.timeout_poly(c.server.request_timeout, c, conn_on_timeout, c.loop)

    assert(c.timeout_op != nil, "deferred response left no deadline armed")
}

// This connection's ticket, for work that may outlive it. See `Ticket`.
conn_ticket :: proc(c: ^Conn) -> Ticket {
    assert(c != nil, "ticket needs a connection")
    assert(c.ticket != 0, "connection was never enrolled")
    return c.ticket
}

// The connection `ticket` names if it can still be answered, otherwise `nil`. Answers the
// only question deferred work may ask about a connection it does not own, and the only
// safe way to ask it: the `^Conn` itself may already be freed.
//
// A finalized connection is deliberately a miss even though it is still in the table
// until its closes complete — it can no longer be answered, so handing it back would only
// invite a response onto a dead socket. Teardown during an in-flight deferral is the
// ordinary case, not an error.
//
// Must be called on the server's loop thread, where releases happen.
conn_resolve :: proc(s: ^Server, ticket: Ticket) -> ^Conn {
    assert(s != nil, "resolve needs a server")

    if ticket == 0 {
        return nil
    }

    c := s.conns[ticket]
    if c == nil {
        return nil
    }

    assert(c.ticket == ticket, "connection table returned a mismatched ticket")

    return conn_can_respond(c) ? c : nil
}

// Tear down a connection that cannot be answered (for example after allocation
// failure). This is the only valid fallback after a `try_respond*` call.
abort :: proc(c: ^Conn) {
    assert(c != nil && c.state != .Hijacked, "abort on an invalid connection")

    conn_finalize(c)
}

// Shared tail of the `respond*` wrappers.
@(private)
abort_failed_response :: proc(c: ^Conn, err: Response_Error) {
    if err == .None {
        return
    }

    log.errorf("http_server: response failed: %v", err)
    abort(c)
}

// Re-arm accept; no-op when not `Serving`.
@(private)
arm_accept :: proc(s: ^Server) {
    assert(s != nil, "arm_accept needs a server")

    if s.state != .Serving {
        return
    }

    assert(s.accept_op == nil, "accept already armed")
    s.accept_op = nbio.accept_poly(s.socket, s, on_accept, nbio.NO_TIMEOUT, s.loop)
}

// Accept completion: drop the new socket on shutdown, otherwise start a
// connection and re-arm accept.
@(private)
on_accept :: proc(op: ^nbio.Operation, s: ^Server) {
    assert(op == s.accept_op, "accept completion does not match stored operation")
    s.accept_op = nil

    if s.state != .Serving {
        if op.accept.err == nil {
            nbio.close(op.accept.client, l = s.loop)
        }

        return
    }

    if op.accept.err != nil {
        log.errorf("http_server: accept failed: %v", op.accept.err)
    } else {
        conn_start(s, op.accept.client)
    }

    arm_accept(s)
}

// Listen-socket close completion: advance `Closing` once the close is observed.
@(private)
on_listen_closed :: proc(op: ^nbio.Operation, s: ^Server) {
    assert(s.state == .Closing, "listen socket closed outside shutdown")
    assert(!s.listen_closed, "listen socket closed twice")

    s.listen_closed = true
    maybe_finish_shutdown(s)
}

// Advance `Closing` to `Closed` once the listen socket has closed and every owned
// connection has released. The final transition signals `shutdown_complete`.
@(private)
maybe_finish_shutdown :: proc(s: ^Server) {
    assert(s != nil, "shutdown check needs a server")

    if s.state == .Closing && s.listen_closed && len(s.conns) == 0 {
        s.state = .Closed
        s.shutdown_complete = true
        log.debug("http_server: shutdown complete")
    }
}

// Silently drops the socket when the connection cap is reached or any allocation
// fails; otherwise enrolls the new connection and arms the head timeout and recv.
@(private)
conn_start :: proc(s: ^Server, socket: net.TCP_Socket) {
    assert(s.state == .Serving, "connection admitted while server is not serving")
    assert(len(s.conns) <= s.max_connections, "connection table exceeds its cap")

    if len(s.conns) >= s.max_connections {
        log.warnf("http_server: connection cap reached (%d); dropping socket", s.max_connections)
        nbio.close(socket, l = s.loop)
        return
    }

    c, aerr := new(Conn, s.allocator)
    if aerr != nil {
        log.error("http_server: out of memory enrolling connection")
        nbio.close(socket, l = s.loop)
        return
    }

    head_buf: [dynamic]byte
    head_buf, aerr = make([dynamic]byte, 0, min(s.recv_chunk_bytes, s.max_head_bytes), s.allocator)
    if aerr != nil {
        log.error("http_server: out of memory allocating head buffer")
        free(c, s.allocator)
        nbio.close(socket, l = s.loop)
        return
    }

    recv_buf: []byte
    recv_buf, aerr = make([]byte, min(s.recv_chunk_bytes, s.max_head_bytes), s.allocator)
    if aerr != nil {
        log.error("http_server: out of memory allocating recv buffer")
        delete(head_buf)
        free(c, s.allocator)
        nbio.close(socket, l = s.loop)
        return
    }

    s.next_ticket += 1
    assert(s.next_ticket != 0, "ticket source wrapped")

    c^ = {}
    c.server = s
    c.loop = s.loop
    c.allocator = s.allocator
    c.ticket = s.next_ticket
    c.socket = socket
    c.state = .Reading
    c.head_buf = head_buf
    c.recv_buf = recv_buf

    // Most connections never add a header, so record the allocator without allocating.
    c.pending.allocator = c.allocator

    if map_insert(&s.conns, c.ticket, c) == nil {
        log.error("http_server: out of memory inserting connection")
        delete(c.head_buf)
        delete(c.recv_buf, c.allocator)
        free(c, s.allocator)
        nbio.close(socket, l = s.loop)
        return
    }

    c.timeout_op = nbio.timeout_poly(s.request_timeout, c, conn_on_timeout, s.loop)
    conn_start_recv(c)
}

// Arm a recv capped so the head buffer never exceeds `max_head_bytes`.
@(private)
conn_start_recv :: proc(c: ^Conn) {
    assert(c.state == .Reading, "request receive outside Reading")
    assert(c.recv_op == nil, "request receive already armed")

    remaining := c.server.max_head_bytes - len(c.head_buf)
    if remaining <= 0 {
        conn_respond_error(c, .Request_Header_Fields_Too_Large, "request head too large")
        return
    }

    recv_bytes := min(len(c.recv_buf), remaining)
    c.recv_op = nbio.recv_poly(
        c.socket,
        [][]byte{c.recv_buf[:recv_bytes]},
        c,
        conn_on_recv,
        false,
        nbio.NO_TIMEOUT,
        c.loop,
    )
}

// Scan resumes from three bytes before the last scan point so a CRLFCRLF split
// across recvs is still found. The handler must respond or hijack before
// returning; remaining `Reading` is a contract violation.
@(private)
conn_on_recv :: proc(op: ^nbio.Operation, c: ^Conn) {
    assert(c.state == .Reading, "request receive completed outside Reading")
    assert(op == c.recv_op, "request receive completion does not match stored operation")
    c.recv_op = nil

    if op.recv.err != nil || op.recv.received == 0 {
        conn_finalize(c)
        return
    }

    if _, aerr := append(&c.head_buf, ..c.recv_buf[:op.recv.received]); aerr != nil {
        conn_finalize(c)
        return
    }

    from := max(0, c.scanned - 3)
    found := strings.index(string(c.head_buf[from:]), "\r\n\r\n")
    c.scanned = len(c.head_buf)
    if found < 0 {
        conn_start_recv(c)
        return
    }

    consumed := from + found + 4
    assert(consumed <= c.server.max_head_bytes, "accepted head exceeds configured cap")

    head, status, head_err := http.parse_request_head(c.head_buf[:consumed])
    assert(status == .Ready, "terminator found but parser requested more data")
    if head_err != .None {
        log.debugf("http_server: malformed request head: %v", head_err)
        conn_respond_error(c, .Bad_Request, "malformed request")
        return
    }

    body_length, request_err := http.validate_body(head)
    switch request_err {
    case .None:

    case .Unsupported_Expectation:
        log.debug("http_server: rejecting Expect header")
        conn_respond_error(c, .Expectation_Failed, "expectation not supported")
        return

    case .Invalid_Content_Length, .Unsupported_Transfer_Coding:
        log.debugf("http_server: rejecting body framing: %v", request_err)
        conn_respond_error(c, .Bad_Request, "request body not supported")
        return
    }

    path, query := http.split_target(head.target)

    // Path only: a query can carry a credential (RFC 6750 §5.3) and logs outlive it.
    log.debugf("http_server: request %s %s", head.method, path)

    c.head_consumed = consumed
    c.head_request = head.method == "HEAD"
    c.body_remaining = body_length
    trailing := c.head_buf[consumed:]
    request := Request {
        head           = head,
        path           = path,
        query          = query,
        trailing       = trailing,
        content_length = body_length,
        pipelined      = i64(len(trailing)) > body_length,
    }
    c.server.on_request(c, request)

    switch c.state {
    case .Hijacked:
        conn_release(c)

    case .Receiving_Body, .Deferred, .Responding, .Closed:

    case .Reading:
        assert(false, "request handler must respond, defer, hijack, or receive the body")
    }
}

// Arm one body recv, capped at the declared remainder so it never reads into a
// following request. Each recv carries the request timeout as an idle deadline.
@(private)
arm_body_recv :: proc(c: ^Conn) {
    assert(c.state == .Receiving_Body, "body receive armed outside a body receive")
    assert(c.recv_op == nil, "body receive already armed")
    assert(c.body_remaining > 0, "body receive armed with nothing left to read")

    recv_bytes := int(min(i64(len(c.recv_buf)), c.body_remaining))
    c.recv_op = nbio.recv_poly(
        c.socket,
        [][]byte{c.recv_buf[:recv_bytes]},
        c,
        conn_on_body_recv,
        false,
        c.server.request_timeout,
        c.loop,
    )
}

// Body recv completion: a reset, timeout, or premature EOF finalizes the connection
// (which fires the end callback with `ok = false`); otherwise deliver the chunk and
// either complete or arm the next recv.
@(private)
conn_on_body_recv :: proc(op: ^nbio.Operation, c: ^Conn) {
    assert(c.state == .Receiving_Body, "body receive completed outside a body receive")
    assert(op == c.recv_op, "body receive completion does not match stored operation")
    c.recv_op = nil

    if op.recv.err != nil || op.recv.received == 0 {
        conn_finalize(c)
        return
    }

    assert(i64(op.recv.received) <= c.body_remaining, "body recv delivered past the declared length")
    if !deliver_body_chunk(c, c.recv_buf[:op.recv.received]) {
        return
    }

    if c.body_remaining == 0 {
        body_complete(c)
        return
    }

    arm_body_recv(c)
}

// Feed one non-empty body slice to the sink and account for it. Returns false, after
// finalizing the connection, if the sink rejects the chunk.
@(private)
deliver_body_chunk :: proc(c: ^Conn, chunk: []byte) -> bool {
    assert(c.state == .Receiving_Body, "body chunk delivered outside a body receive")
    assert(len(chunk) > 0, "empty body chunk delivered")
    assert(i64(len(chunk)) <= c.body_remaining, "body chunk exceeds the declared remainder")

    if !c.body_on_chunk(c, c.body_user, chunk) {
        conn_finalize(c)
        return false
    }

    c.body_remaining -= i64(len(chunk))
    return true
}

// The declared body has fully arrived: return to `Reading` and hand control back so
// the completion callback can answer with `respond*`. Clears the body callbacks first
// so the response's later finalize does not re-fire the end callback.
@(private)
body_complete :: proc(c: ^Conn) {
    assert(c.state == .Receiving_Body, "body completion outside a body receive")
    assert(c.body_remaining == 0, "body completion with bytes outstanding")

    conn_cancel_timeout(c)

    on_end := c.body_on_end
    user := c.body_user
    c.body_on_chunk = nil
    c.body_on_end = nil
    c.body_user = nil
    c.state = .Reading

    on_end(c, user, true)
}

// Deadline firing for whichever phase armed it. Reading owes the peer a 408; a body
// transfer that outran its budget is finalized, which fires the end callback with
// `ok = false` so the sink releases what it opened — no response, the peer is still
// mid-body. Any other state has already moved on.
@(private)
conn_on_timeout :: proc(op: ^nbio.Operation, c: ^Conn) {
    assert(op == c.timeout_op, "timeout completion does not match stored operation")
    c.timeout_op = nil

    #partial switch c.state {
    case .Reading:
        log.debug("http_server: request head timed out")
        conn_respond_error(c, .Request_Timeout, "request timed out")

    case .Receiving_Body:
        log.debug("http_server: request body transfer timed out")
        conn_finalize(c)

    case .Deferred:
        // The handler still owes an answer and may yet produce one, so there is no
        // status to send that would not race it. Dropping the connection releases it and
        // leaves the handler's ticket resolving to nothing.
        log.debug("http_server: deferred response timed out")
        conn_finalize(c)
    }
}

// Small text/plain refusal the driver itself originated during the request phase.
@(private)
conn_respond_error :: proc(c: ^Conn, status: Status, text: string) {
    assert(c != nil && c.state == .Reading, "error response outside Reading")

    respond_text(c, status, text)
}

// Cancel the pending deadline and transition `Reading` or `Deferred` to `Responding`.
@(private)
conn_begin_response :: proc(c: ^Conn) {
    assert(conn_can_respond(c), "response began on a connection that cannot answer")

    conn_cancel_timeout(c)
    c.state = .Responding
}

// Gather `resp_head` and `resp_body` (when non-empty) into `send_bufs` and arm
// a single send.
@(private)
conn_send_head_and_body :: proc(c: ^Conn) {
    assert(c.state == .Responding, "response send outside Responding")
    assert(c.send_op == nil, "response send already armed")
    assert(len(c.resp_head) > 0, "response head is empty")

    c.send_bufs[0] = c.resp_head
    c.send_bufs[1] = c.resp_body

    // RFC 9110 §9.3.2: a HEAD response keeps its headers and sends no content. Decided
    // here so every response path is covered, not each constructor separately.
    count := 1
    if len(c.resp_body) > 0 && !c.head_request {
        count = 2
    }

    c.send_op = nbio.send_poly(
        c.socket,
        c.send_bufs[:count],
        c,
        conn_on_head_sent,
        {},
        true,
        c.server.request_timeout,
        c.loop,
    )
}

// Stat completion: emit the success or the prepared failure response.
@(private)
conn_on_file_stat :: proc(op: ^nbio.Operation, c: ^Conn) {
    assert(c.state == .Responding, "file stat outside Responding state")
    assert(c.owns_file, "file stat without file ownership")
    assert(op == c.file_op, "file stat completion does not match stored operation")
    c.file_op = nil

    if op.stat.err != nil ||
       op.stat.type != .Regular ||
       op.stat.size < 0 ||
       op.stat.size > c.file_max_bytes ||
       op.stat.size > i64(max(int)) {
        c.resp_body = c.file_failure_body
        c.file_failure_body = nil
        response_head, aerr := build_response_head(
            c.file_failure,
            "text/plain; charset=utf-8",
            len(c.resp_body),
            c.resp_extra,
            c.allocator,
        )
        if aerr != nil {
            conn_finalize(c)
            return
        }

        c.resp_head = response_head
        conn_send_head_and_body(c)
        return
    }

    c.file_bytes = int(op.stat.size)
    response_head, aerr := build_response_head(
        c.file_status,
        c.file_content_type,
        c.file_bytes,
        c.resp_extra,
        c.allocator,
    )
    if aerr != nil {
        conn_finalize(c)
        return
    }

    c.resp_head = response_head
    conn_send_head_and_body(c)
}

// Head-send completion: proceed to `sendfile` if a non-empty owned file is
// pending, else finalize.
@(private)
conn_on_head_sent :: proc(op: ^nbio.Operation, c: ^Conn) {
    assert(c.state == .Responding, "response send completed outside Responding")
    assert(op == c.send_op, "response send completion does not match stored operation")
    c.send_op = nil

    if op.send.err != nil {
        log.warnf("http_server: response send failed: %v", op.send.err)
        conn_finalize(c)
        return
    }

    if !c.owns_file || len(c.resp_body) > 0 || c.file_bytes == 0 || c.head_request {
        conn_finalize(c)
        return
    }

    c.file_op = nbio.sendfile_poly(
        c.socket,
        c.file,
        c,
        conn_on_file_sent,
        nbytes = c.file_bytes,
        timeout = c.server.request_timeout,
        l = c.loop,
    )
}

// sendfile completion: finalize unconditionally; sendfile owns the lifecycle
// for this path.
@(private)
conn_on_file_sent :: proc(op: ^nbio.Operation, c: ^Conn) {
    assert(c.state == .Responding, "file send completed outside Responding state")
    assert(c.owns_file, "file send completed without file ownership")
    assert(op == c.file_op, "file send completion does not match stored operation")
    c.file_op = nil

    if op.sendfile.err != nil {
        log.warnf("http_server: sendfile failed: %v", op.sendfile.err)
    }

    conn_finalize(c)
}

// Cancel the armed head or body deadline, if any.
@(private)
conn_cancel_timeout :: proc(c: ^Conn) {
    if c.timeout_op != nil {
        nbio.remove(c.timeout_op)
        c.timeout_op = nil
    }
}

// Cancel every in-flight operation and arm close on the socket and any owned
// file. `close_pending` counts the outstanding closes; the last one releases.
@(private)
conn_finalize :: proc(c: ^Conn) {
    assert(c.state != .Hijacked, "finalizing a socket owned by the application")

    if c.state == .Closed {
        return
    }

    c.state = .Closed
    if c.recv_op != nil {
        nbio.remove(c.recv_op)
        c.recv_op = nil
    }
    if c.send_op != nil {
        nbio.remove(c.send_op)
        c.send_op = nil
    }
    if c.timeout_op != nil {
        nbio.remove(c.timeout_op)
        c.timeout_op = nil
    }
    if c.file_op != nil {
        nbio.remove(c.file_op)
        c.file_op = nil
    }

    // A connection finalized mid-body still owes its handler the end notification, so
    // it can release the resources the transfer had open. Cleared first so a re-entrant
    // finalize cannot double-fire it.
    if c.body_on_end != nil {
        on_end := c.body_on_end
        user := c.body_user
        c.body_on_chunk = nil
        c.body_on_end = nil
        c.body_user = nil
        on_end(c, user, false)
    }

    assert(c.close_pending == 0, "connection close already armed")
    c.close_pending = 1
    nbio.close_poly(c.socket, c, conn_on_resource_closed, c.loop)
    if c.owns_file {
        c.close_pending += 1
        nbio.close_poly(c.file, c, conn_on_resource_closed, c.loop)
    }
}

// Count down outstanding resource closes and release the connection at zero.
@(private)
conn_on_resource_closed :: proc(op: ^nbio.Operation, c: ^Conn) {
    assert(c.state == .Closed, "resource closed before connection teardown")
    assert(c.close_pending > 0, "unexpected resource-close completion")

    c.close_pending -= 1
    if c.close_pending == 0 {
        conn_release(c)
    }
}

// Release connection-owned memory, drop the connection from the server map,
// then free the `Conn`. Re-checks the shutdown boundary at the end.
@(private)
conn_release :: proc(c: ^Conn) {
    s := c.server
    assert(c.state == .Closed || c.state == .Hijacked, "connection released before teardown")
    assert(s.conns[c.ticket] == c, "releasing a connection the server does not own")
    assert(c.close_pending == 0, "connection released with closes outstanding")

    delete(c.head_buf)
    delete(c.recv_buf, c.allocator)
    delete(c.resp_head, c.allocator)
    delete(c.resp_body, c.allocator)
    delete(c.resp_extra, c.allocator)
    for field in c.pending {
        delete(field.name, c.allocator)
        delete(field.value, c.allocator)
    }
    delete(c.pending)
    delete(c.file_content_type, c.allocator)
    delete(c.file_failure_body, c.allocator)

    delete_key(&s.conns, c.ticket)
    free(c, s.allocator)
    assert(len(s.conns) <= s.max_connections, "connection table exceeds its cap")

    maybe_finish_shutdown(s)
}

// Render the pending headers into the block `build_response_head` splices in.
// `conn_add_header` validated each field as it arrived, so only the head budget is
// enforced here, where the whole set is known.
@(private)
serialize_pending_headers :: proc(c: ^Conn) -> (out: []byte, err: Response_Error) {
    assert(c != nil, "header serialization needs a connection")

    total := 0
    for field in c.pending {
        field_bytes := len(field.name) + 2 + len(field.value) + 2
        if field_bytes > c.server.max_head_bytes - total {
            return nil, .Invalid_Header
        }
        total += field_bytes
    }

    if total == 0 {
        return nil, .None
    }

    aerr: runtime.Allocator_Error
    out, aerr = make([]byte, total, c.allocator)
    if aerr != nil {
        return nil, .Out_Of_Memory
    }

    at := 0
    for field in c.pending {
        at += copy(out[at:], transmute([]byte)field.name)
        at += copy(out[at:], transmute([]byte)string(": "))
        at += copy(out[at:], transmute([]byte)field.value)
        at += copy(out[at:], transmute([]byte)string("\r\n"))
    }
    assert(at == len(out), "serialized header length mismatch")

    return out, .None
}

// Whether `name` already appears among `fields`, compared case-insensitively as HTTP
// field names are.
@(private)
header_present :: proc(fields: []Header, name: string) -> bool {
    for field in fields {
        if strings.equal_fold(field.name, name) {
            return true
        }
    }

    return false
}

// Field names owned by `build_response_head`; callers may not override them.
@(private)
reserved_field :: proc(name: string) -> bool {
    return(
        strings.equal_fold(name, "connection") ||
        strings.equal_fold(name, "content-length") ||
        strings.equal_fold(name, "content-type") ||
        strings.equal_fold(name, "date") ||
        strings.equal_fold(name, "transfer-encoding") \
    )
}

// Assemble a complete response head. Every response carries `Date`,
// `Content-Length`, and `Connection: close`; `content_type` is optional.
@(private)
build_response_head :: proc(
    status: Status,
    content_type: string,
    body_bytes: int,
    extra: []byte,
    allocator: mem.Allocator,
) -> (
    head: []byte,
    err: runtime.Allocator_Error,
) #optional_allocator_error {
    assert(body_bytes >= 0, "negative response body length")
    assert(http.field_value_valid(content_type), "invalid response content type")

    status_text := http.status_line(status)
    content_length_buf: [32]byte
    content_length := strconv.write_int(content_length_buf[:], i64(body_bytes), 10)

    date_buf: [29]byte // 29 bytes is the exact length of the RFC 7231 IMF-fixdate format
    date := http_date(time.now(), &date_buf)

    total :=
        len("HTTP/1.1 ") +
        len(status_text) +
        len("\r\n") +
        len("Date: ") +
        len(date) +
        len("\r\n") +
        len(extra) +
        len("Content-Length: ") +
        len(content_length) +
        len("\r\n") +
        len("Connection: close\r\n") +
        len("\r\n")

    if len(content_type) > 0 {
        total += len("Content-Type: ") + len(content_type) + len("\r\n")
    }

    head = make([]byte, total, allocator) or_return
    at := 0
    at += copy(head[at:], transmute([]byte)string("HTTP/1.1 "))
    at += copy(head[at:], transmute([]byte)status_text)
    at += copy(head[at:], transmute([]byte)string("\r\nDate: "))
    at += copy(head[at:], transmute([]byte)date)
    at += copy(head[at:], transmute([]byte)string("\r\n"))
    at += copy(head[at:], extra)
    if len(content_type) > 0 {
        at += copy(head[at:], transmute([]byte)string("Content-Type: "))
        at += copy(head[at:], transmute([]byte)content_type)
        at += copy(head[at:], transmute([]byte)string("\r\n"))
    }
    at += copy(head[at:], transmute([]byte)string("Content-Length: "))
    at += copy(head[at:], transmute([]byte)content_length)
    at += copy(head[at:], transmute([]byte)string("\r\nConnection: close\r\n\r\n"))
    assert(at == len(head), "response head length mismatch")

    return head, nil
}

// Format `now` as an RFC 7231 IMF-fixdate (always GMT) into a 29-byte buffer.
@(private)
http_date :: proc(now: time.Time, out: ^[29]byte) -> string {
    assert(out != nil, "http_date needs an output buffer")

    datetime, ok := time.time_to_datetime(now)
    if !ok || datetime.year < 0 || datetime.year > 9999 {
        datetime = {{1970, 1, 1}, {0, 0, 0, 0}, nil}
    }

    ordinal, date_err := dt.date_to_ordinal(datetime.date)
    assert(date_err == .None, "time_to_datetime returned an invalid date")
    weekday := dt.day_of_week(ordinal)

    WEEKDAYS := [dt.Weekday]string {
        .Sunday    = "Sun",
        .Monday    = "Mon",
        .Tuesday   = "Tue",
        .Wednesday = "Wed",
        .Thursday  = "Thu",
        .Friday    = "Fri",
        .Saturday  = "Sat",
    }
    MONTHS := [12]string{"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"}

    copy(out[0:3], transmute([]byte)WEEKDAYS[weekday])
    copy(out[3:5], transmute([]byte)string(", "))
    write_two(out[5:7], int(datetime.day))
    out[7] = ' '
    copy(out[8:11], transmute([]byte)MONTHS[int(datetime.month) - 1])
    out[11] = ' '
    write_four(out[12:16], int(datetime.year))
    out[16] = ' '
    write_two(out[17:19], int(datetime.hour))
    out[19] = ':'
    write_two(out[20:22], int(datetime.minute))
    out[22] = ':'
    write_two(out[23:25], int(datetime.second))
    copy(out[25:29], transmute([]byte)string(" GMT"))

    return string(out[:])
}

// Two-digit zero-padded decimal into a 2-byte slice.
@(private)
write_two :: proc(out: []byte, value: int) {
    assert(len(out) == 2, "two-digit output buffer must be 2 bytes")
    assert(value >= 0 && value <= 99, "two-digit value out of range")

    out[0] = byte(value / 10) + '0'
    out[1] = byte(value % 10) + '0'
}

// Four-digit zero-padded decimal into a 4-byte slice.
@(private)
write_four :: proc(out: []byte, value: int) {
    assert(len(out) == 4, "four-digit output buffer must be 4 bytes")
    assert(value >= 0 && value <= 9999, "four-digit value out of range")

    out[0] = byte(value / 1000) + '0'
    out[1] = byte(value / 100 % 10) + '0'
    out[2] = byte(value / 10 % 10) + '0'
    out[3] = byte(value % 10) + '0'
}
