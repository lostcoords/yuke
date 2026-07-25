package websocket

import "core:crypto"
import "core:encoding/base64"
import "core:mem"
import "core:nbio"
import "core:net"
import "core:slice"
import "core:testing"
import "core:thread"
import "core:time"
import http "libs:http/server"
import ts "libs:testsupport"

// --- Server driver tests ------------------------------------------------------
//
// These drive the EXISTING nbio client (`client_connect`) against the server
// (`server_adopt`, fed by a `libs:http` front door) on ONE shared
// `nbio.Event_Loop`, in-process, no worker threads — accept, upgrade, and framing
// all interleave on a single loop. One test (masked-frame requirement) needs a raw
// non-WebSocket peer, so it uses a blocking raw TCP client on a worker thread while
// the server runs the loop on the main thread — the mirror image of
// `client_test.odin`.

// Shared server-side observations, reached from the server callbacks as
// `conn.server.user_data`. Counters catch a callback firing more than once.
Srv_Server_Obs :: struct {
    // Number of connections that reached Open.
    open_count:     int,

    // Reassembled bytes of every received message, concatenated.
    message:        [dynamic]byte,

    // Number of on_message calls (a control frame must never surface here).
    message_count:  int,

    // Kind of the most recent inbound message (echo kind-fidelity check).
    last_kind:      Message_Kind,

    // Number of on_close calls.
    close_count:    int,

    // Close code reported to the most recent on_close.
    last_close:     Close_Code,

    // Number of on_error calls.
    error_count:    int,

    // Error reported to the most recent on_error.
    last_error:     Server_Error,

    // Total terminal callbacks (close + error) observed across the run.
    terminal_count: int,
}

// The shared server-level observations behind a connection.
srv_obs :: proc(conn: ^Server_Conn) -> ^Srv_Server_Obs {
    return (^Srv_Server_Obs)(conn.server.user_data)
}

// Server callback: echo each message back in the same kind, and record it.
srv_echo_on_message :: proc(conn: ^Server_Conn, kind: Message_Kind, data: []byte) {
    o := srv_obs(conn)
    append(&o.message, ..data)
    o.message_count += 1
    o.last_kind = kind

    if kind == .Binary {
        server_send_binary(conn, data)
    } else {
        server_send_text(conn, data)
    }
}

srv_server_on_open :: proc(conn: ^Server_Conn) {
    o := srv_obs(conn)
    o.open_count += 1
}

srv_server_on_close :: proc(conn: ^Server_Conn, code: Close_Code) {
    o := srv_obs(conn)
    o.close_count += 1
    o.last_close = code
    o.terminal_count += 1
}

srv_server_on_error :: proc(conn: ^Server_Conn, err: Server_Error) {
    o := srv_obs(conn)
    o.error_count += 1
    o.last_error = err
    o.terminal_count += 1
}

// The echo callback set used by the round-trip tests.
srv_echo_callbacks :: proc() -> Server_Callbacks {
    return Server_Callbacks {
        on_open = srv_server_on_open,
        on_message = srv_echo_on_message,
        on_close = srv_server_on_close,
        on_error = srv_server_on_error,
    }
}

// Tick the loop a bounded number of times so an already-terminated connection's
// deferred teardown (socket close completion) runs before assertions.
srv_settle :: proc(n: int) {
    for _ in 0 ..< n {
        nbio.tick(time.Millisecond)
    }
}

// Recover the ephemeral port `srv_serve` bound, for dialing the client half.
srv_bound_port :: proc(f: ^http.Server) -> int {
    return http.bound_port(f)
}

srv_server_empty :: proc(s: ^Server) -> bool {
    return len(s.conns) == 0
}

// Test front door: validate the upgrade request and hand the socket to the server.
// A request that is not a valid upgrade is refused with a 400 — routing, auth, and
// every other status belong to the application (see `src/daemon/front_door.odin`).
srv_on_request :: proc(c: ^http.Conn, req: http.Request) {
    s := (^Server)(c.server.user_data)

    ureq, result, _, status := parse_upgrade_request(req.head.bytes)
    if status != .Ready || result != .Ok {
        http.respond_text(c, .Bad_Request, "expected a websocket upgrade")
        return
    }

    if !server_can_adopt(s) {
        http.respond_text(c, .Service_Unavailable, "at capacity")
        return
    }

    socket, loop := http.hijack(c)
    if _, err := server_adopt(s, socket, ureq.key, req.trailing); err != .None {
        nbio.close(socket, l = loop)
    }
}

// Stand up a server plus the front door that feeds it, both on `loop`. Binds an
// OS-assigned ephemeral port; recover it with `srv_bound_port` after this returns.
srv_serve :: proc(
    s: ^Server,
    f: ^http.Server,
    loop: ^nbio.Event_Loop,
    callbacks: Server_Callbacks,
    user_data: rawptr,
    options: Server_Options = {},
    allocator := context.allocator,
) -> http.Error {
    init_err := server_init(s, loop, options, callbacks, user_data, allocator)
    assert(init_err == .None, "test websocket server should initialize")

    return http.listen(f, loop, {host = "127.0.0.1", port = 0}, srv_on_request, s, allocator)
}

// Bring both halves down and reclaim them. Safe to call once per server.
srv_teardown_server :: proc(t: ^testing.T, s: ^Server, f: ^http.Server) {
    http.shutdown(f)
    server_shutdown(s)

    if !ts.nbio_run_until(t, &s.shutdown_complete, "WebSocket server shutdown") {
        return
    }

    if !ts.nbio_run_until(t, &f.shutdown_complete, "HTTP front-door shutdown") {
        return
    }

    server_destroy(s)
    http.destroy(f)
}

// --- 1 & 2. Handshake + echo round-trip (text and binary) ---------------------

// A client that sends one message on open, echoes are recorded, then closes on
// the first echo. `kind` selects text vs binary.
Srv_Echo_Client :: struct {
    // Payload to send once open.
    payload:    []byte,

    // Binary rather than text.
    binary:     bool,

    // Bytes received back from the server.
    echoed:     [dynamic]byte,

    // Kind of the echoed message.
    echo_kind:  Message_Kind,

    // on_open fired.
    opened:     bool,

    // Terminal reached.
    done:       bool,

    // Close code reported to the client.
    close_code: Close_Code,

    // Terminal error, if any.
    err:        Client_Error,
}

srv_echo_client_on_open :: proc(c: ^Client) {
    ec := (^Srv_Echo_Client)(c.user_data)
    ec.opened = true
    if ec.binary {
        client_send_binary(c, ec.payload)
    } else {
        client_send_text(c, ec.payload)
    }
}

srv_echo_client_on_message :: proc(c: ^Client, kind: Message_Kind, data: []byte) {
    ec := (^Srv_Echo_Client)(c.user_data)
    append(&ec.echoed, ..data)
    ec.echo_kind = kind
    client_close(c)
}

srv_echo_client_on_close :: proc(c: ^Client, code: Close_Code) {
    ec := (^Srv_Echo_Client)(c.user_data)
    ec.close_code = code
    ec.done = true
}

srv_echo_client_on_error :: proc(c: ^Client, err: Client_Error) {
    ec := (^Srv_Echo_Client)(c.user_data)
    ec.err = err
    ec.done = true
}

srv_echo_client_callbacks :: proc() -> Callbacks {
    return Callbacks {
        on_open = srv_echo_client_on_open,
        on_message = srv_echo_client_on_message,
        on_close = srv_echo_client_on_close,
        on_error = srv_echo_client_on_error,
    }
}

// Drive one echo exchange over a shared loop and assert both sides agree; shared by
// the text and binary variants.
srv_run_echo :: proc(t: ^testing.T, binary: bool) {
    defer free_all(context.temp_allocator)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    sobs: Srv_Server_Obs
    sobs.message = make([dynamic]byte, context.temp_allocator)

    s: Server
    f: http.Server
    testing.expect_value(t, srv_serve(&s, &f, loop, srv_echo_callbacks(), &sobs), http.Error.None)

    port := srv_bound_port(&f)

    ec: Srv_Echo_Client
    ec.payload = binary ? []byte{0x00, 0x01, 0x02, 0xff, 0xfe} : transmute([]byte)string("hello server")
    ec.binary = binary
    ec.echoed = make([dynamic]byte, context.temp_allocator)

    c: Client
    cerr := client_connect(
        &c,
        loop,
        {host = "127.0.0.1", port = port, path = "/ws"},
        srv_echo_client_callbacks(),
        &ec,
        context.temp_allocator,
    )
    testing.expect_value(t, cerr, Client_Error.None)

    if !ts.nbio_run_until(t, &ec.done, "echo client completion") {
        return
    }

    client_destroy(&c)

    // Let the server-side connection finish its deferred teardown.
    srv_settle(16)

    testing.expect(t, ec.opened, "client on_open should fire")
    testing.expect_value(t, ec.err, Client_Error.None)
    testing.expect_value(t, string(ec.echoed[:]), string(ec.payload))
    testing.expect_value(t, ec.echo_kind, binary ? Message_Kind.Binary : Message_Kind.Text)

    testing.expect_value(t, sobs.open_count, 1)
    testing.expect_value(t, sobs.message_count, 1)
    testing.expect_value(t, sobs.last_kind, binary ? Message_Kind.Binary : Message_Kind.Text)
    testing.expect_value(t, string(sobs.message[:]), string(ec.payload))
    // The client initiated the close; the server observed exactly one terminal.
    testing.expect_value(t, sobs.terminal_count, 1)
    testing.expect_value(t, sobs.close_count, 1)

    srv_teardown_server(t, &s, &f)
}

@(test)
test_server_echo_text :: proc(t: ^testing.T) {
    srv_run_echo(t, false)
}

@(test)
test_server_echo_binary :: proc(t: ^testing.T) {
    srv_run_echo(t, true)
}

// --- Raw blocking TCP peer harness (worker thread) ----------------------------
//
// For the ping and masked-frame tests the peer is deliberately NOT the nbio client,
// so it runs blocking `core:net` calls on a worker thread while the server drives
// the loop on the main thread.

// Observations a raw peer records for the test to read after `thread.join`.
Raw_Peer :: struct {
    // Port to connect to.
    port:          int,

    // The raw peer ran its script without an unexpected setup failure.
    ok:            bool,

    // The server closed the connection (recv returned 0 or errored) after the peer's
    // offending frame/request.
    server_closed: bool,

    // For the ping peer: a Pong was read back from the server.
    got_pong:      bool,
    pong:          [64]byte,
    pong_len:      int,
}

// Connect a blocking TCP socket to loopback:port.
raw_dial :: proc(port: int) -> (net.TCP_Socket, bool) {
    endpoint := net.Endpoint {
        address = net.IP4_Loopback,
        port    = port,
    }

    sock, err := net.dial_tcp(endpoint)
    if err != nil {
        return {}, false
    }

    // Bound thread cleanup even if the server and its shutdown path both fail.
    if net.set_option(sock, .Receive_Timeout, ts.NBIO_WAIT_DEADLINE + time.Second) != nil {
        net.close(sock)
        return {}, false
    }

    return sock, true
}

// Client half of the upgrade over a blocking socket; validates the server's 101
// using the package's own handshake primitives.
raw_upgrade :: proc(sock: net.TCP_Socket, allocator := context.temp_allocator) -> bool {
    key_raw: [SEC_WEBSOCKET_KEY_BYTES]byte
    crypto.rand_bytes(key_raw[:])
    key_encoded: [SEC_WEBSOCKET_KEY_ENCODED_BYTES]byte
    base64.encode_into_buf(key_encoded[:], key_raw[:])

    request := build_upgrade_request("/ws", "127.0.0.1:0", key_encoded[:], "", allocator)
    if _, serr := net.send_tcp(sock, request); serr != nil {
        return false
    }

    buf: [4096]byte
    n := 0
    for n < len(buf) {
        got, rerr := net.recv_tcp(sock, buf[n:])
        if rerr != nil || got == 0 {
            return false
        }

        n += got
        result, _, status := parse_upgrade_response(buf[:n], key_encoded[:])
        if status == .Ready {
            return result == .Ok
        }
    }

    return false
}

// --- 3. Server auto-Pong on a client ping -------------------------------------

// Raw peer: upgrade, send a masked Ping (hand-rolled via `encode_frame` with a mask
// key, as a real client would), then read back the server's unmasked Pong.
raw_ping_peer :: proc(p: ^Raw_Peer) {
    defer free_all(context.temp_allocator)

    sock, ok := raw_dial(p.port)
    if !ok {
        return
    }
    defer net.close(sock)

    if !raw_upgrade(sock) {
        return
    }

    key: [MASK_KEY_BYTES]byte
    crypto.rand_bytes(key[:])
    ping := encode_frame(true, .Ping, transmute([]byte)string("ping!"), key, context.temp_allocator)
    if _, serr := net.send_tcp(sock, ping); serr != nil {
        return
    }

    // Read back the server's Pong with a client-role decoder (rejects masking, which
    // a server never applies).
    dec: Decoder
    decoder_init(&dec, 1 << 20, 1 << 20, .Client, context.temp_allocator)
    defer decoder_destroy(&dec)

    buf: [4096]byte
    for {
        msg, has, derr := decoder_next(&dec, context.temp_allocator)
        if derr != .None {
            return
        }

        if has {
            if msg.kind == .Pong {
                p.got_pong = true
                p.pong_len = copy(p.pong[:], msg.data)
            }

            break
        }

        n, rerr := net.recv_tcp(sock, buf[:])
        if rerr != nil || n == 0 {
            return
        }

        decoder_feed(&dec, buf[:n])
    }

    p.ok = true
}

// A client ping is answered with a Pong echoing its payload; the application's
// on_message never sees it.
@(test)
test_server_auto_pong :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    sobs: Srv_Server_Obs
    sobs.message = make([dynamic]byte, context.temp_allocator)

    s: Server
    f: http.Server
    testing.expect_value(t, srv_serve(&s, &f, loop, srv_echo_callbacks(), &sobs), http.Error.None)

    port := srv_bound_port(&f)

    p := Raw_Peer {
        port = port,
    }
    peer := thread.create_and_start_with_poly_data(&p, raw_ping_peer)
    defer {
        thread.join(peer)
        thread.destroy(peer)
    }

    if !ts.nbio_run_until(t, peer, thread.is_done, "auto-Pong peer completion") {
        srv_teardown_server(t, &s, &f)
        thread.join(peer)
        return
    }

    thread.join(peer)

    if !ts.nbio_run_until(t, &s, srv_server_empty, "auto-Pong connection teardown") {
        srv_teardown_server(t, &s, &f)
        return
    }

    testing.expect(t, p.got_pong, "server should auto-Pong the client's Ping")
    testing.expect_value(t, string(p.pong[:p.pong_len]), "ping!")
    testing.expect_value(t, sobs.message_count, 0)

    srv_teardown_server(t, &s, &f)
}

// --- 3b. Ping flood exhausts the send queue ------------------------------------

// Force every auto-Pong onto the queue without draining it, so accounting alone
// decides when the control reserve is exceeded — not real socket send timing.
srv_ping_flood_on_open :: proc(conn: ^Server_Conn) {
    o := srv_obs(conn)
    o.open_count += 1
    conn.sending = true
}

// Raw peer: upgrade, then flood 3 masked max-size (125-byte) Pings without ever
// reading a reply. The server auto-Pongs each; with `sending` forced true above,
// none is ever flushed, so pending bytes only grow. See
// `test_server_ping_flood_send_queue_full` for the byte budget that makes the
// third Pong overflow the queue.
raw_ping_flood_peer :: proc(p: ^Raw_Peer) {
    defer free_all(context.temp_allocator)

    sock, ok := raw_dial(p.port)
    if !ok {
        return
    }
    defer net.close(sock)

    if !raw_upgrade(sock) {
        return
    }

    payload: [125]byte
    for i in 0 ..< len(payload) {
        payload[i] = byte(i)
    }

    for _ in 0 ..< 3 {
        key: [MASK_KEY_BYTES]byte
        crypto.rand_bytes(key[:])
        ping := encode_frame(true, .Ping, payload[:], key, context.temp_allocator)
        if _, serr := net.send_tcp(sock, ping); serr != nil {
            return
        }
    }

    // The server must fail the connection once the third Pong cannot fit; the
    // peer observes a closed socket, exactly like the unmasked-frame case.
    buf: [256]byte
    for {
        n, rerr := net.recv_tcp(sock, buf[:])
        if rerr != nil || n == 0 {
            p.server_closed = true
            break
        }
    }

    p.ok = true
}

// With the send queue floored at `max_frame_bytes + MAX_HEADER_BYTES` (the
// smallest legal budget) and max-size 125-byte Pings, the resulting 127-byte
// Pongs fill `conn_enqueue`'s control-reserved limit after two: the first two
// queue, the third overflows it. The server must fail the connection through
// the ordinary `Send_Queue_Full` terminal path — no crash, no tripped
// accounting assert, just a graceful close.
@(test)
test_server_ping_flood_send_queue_full :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    sobs: Srv_Server_Obs
    sobs.message = make([dynamic]byte, context.temp_allocator)

    cbs := Server_Callbacks {
        on_open    = srv_ping_flood_on_open,
        on_message = srv_echo_on_message,
        on_close   = srv_server_on_close,
        on_error   = srv_server_on_error,
    }

    s: Server
    f: http.Server
    testing.expect_value(
        t,
        srv_serve(&s, &f, loop, cbs, &sobs, {max_frame_bytes = 125, max_send_queue_bytes = 125 + MAX_HEADER_BYTES}),
        http.Error.None,
    )

    port := srv_bound_port(&f)

    p := Raw_Peer {
        port = port,
    }
    peer := thread.create_and_start_with_poly_data(&p, raw_ping_flood_peer)
    defer {
        thread.join(peer)
        thread.destroy(peer)
    }

    if !ts.nbio_run_until(t, peer, thread.is_done, "ping-flood peer completion") {
        srv_teardown_server(t, &s, &f)
        thread.join(peer)
        return
    }

    thread.join(peer)

    if !ts.nbio_run_until(t, &s, srv_server_empty, "ping-flood connection teardown") {
        srv_teardown_server(t, &s, &f)
        return
    }

    testing.expect(t, p.server_closed, "server should close once the send queue cannot fit another Pong")
    testing.expect_value(t, sobs.error_count, 1)
    testing.expect_value(t, sobs.last_error, Server_Error.Send_Queue_Full)

    srv_teardown_server(t, &s, &f)
}

// --- 4. Masked-frame requirement (server rejects an unmasked client frame) ----

// Raw peer: upgrade, then send an UNMASKED text frame (illegal for a client). The
// server must reject and close it; the peer observes a closed socket.
raw_unmasked_peer :: proc(p: ^Raw_Peer) {
    defer free_all(context.temp_allocator)

    sock, ok := raw_dial(p.port)
    if !ok {
        return
    }
    defer net.close(sock)

    if !raw_upgrade(sock) {
        return
    }

    // Hand-roll an unmasked text frame: FIN|Text, mask bit clear, 3-byte payload.
    frame := [?]byte{0x81, 0x03, 'a', 'b', 'c'}
    if _, serr := net.send_tcp(sock, frame[:]); serr != nil {
        return
    }

    // The server must fail the connection; the peer sees the socket close.
    buf: [256]byte
    for {
        n, rerr := net.recv_tcp(sock, buf[:])
        if rerr != nil || n == 0 {
            p.server_closed = true
            break
        }
    }

    p.ok = true
}

// A server rejects an unmasked client frame (RFC 6455 §5.1) by closing the
// connection with a protocol violation.
@(test)
test_server_rejects_unmasked :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    sobs: Srv_Server_Obs
    sobs.message = make([dynamic]byte, context.temp_allocator)

    s: Server
    f: http.Server
    testing.expect_value(t, srv_serve(&s, &f, loop, srv_echo_callbacks(), &sobs), http.Error.None)

    port := srv_bound_port(&f)

    p := Raw_Peer {
        port = port,
    }
    peer := thread.create_and_start_with_poly_data(&p, raw_unmasked_peer)
    defer {
        thread.join(peer)
        thread.destroy(peer)
    }

    if !ts.nbio_run_until(t, peer, thread.is_done, "unmasked-frame peer completion") {
        srv_teardown_server(t, &s, &f)
        thread.join(peer)
        return
    }

    thread.join(peer)

    if !ts.nbio_run_until(t, &s, srv_server_empty, "unmasked-frame connection teardown") {
        srv_teardown_server(t, &s, &f)
        return
    }

    testing.expect(t, p.server_closed, "server should close the connection after the unmasked frame")
    // The connection had opened, so the server surfaced exactly one on_error.
    testing.expect_value(t, sobs.error_count, 1)
    testing.expect_value(t, sobs.last_error, Server_Error.Protocol_Violation)

    srv_teardown_server(t, &s, &f)
}

// --- 5. Client-initiated close, server echoes ---------------------------------

// A client that opens, immediately closes with a code, and records its terminal.
Srv_Closer_Client :: struct {
    opened:     bool,
    done:       bool,
    close_code: Close_Code,
    err:        Client_Error,
}

srv_closer_on_open :: proc(c: ^Client) {
    cc := (^Srv_Closer_Client)(c.user_data)
    cc.opened = true
    client_close(c, .Going_Away)
}

srv_closer_on_close :: proc(c: ^Client, code: Close_Code) {
    cc := (^Srv_Closer_Client)(c.user_data)
    cc.close_code = code
    cc.done = true
}

srv_closer_on_error :: proc(c: ^Client, err: Client_Error) {
    cc := (^Srv_Closer_Client)(c.user_data)
    cc.err = err
    cc.done = true
}

// The client sends Close(1001); the server observes on_close with that code and
// echoes it (its own graceful close completes).
@(test)
test_server_client_close_echo :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    sobs: Srv_Server_Obs
    sobs.message = make([dynamic]byte, context.temp_allocator)

    s: Server
    f: http.Server
    testing.expect_value(t, srv_serve(&s, &f, loop, srv_echo_callbacks(), &sobs), http.Error.None)

    port := srv_bound_port(&f)

    cc: Srv_Closer_Client
    callbacks := Callbacks {
        on_open = srv_closer_on_open,
        on_message = proc(c: ^Client, kind: Message_Kind, data: []byte) {},
        on_close = srv_closer_on_close,
        on_error = srv_closer_on_error,
    }

    c: Client
    cerr := client_connect(&c, loop, {host = "127.0.0.1", port = port, path = "/ws"}, callbacks, &cc)
    testing.expect_value(t, cerr, Client_Error.None)

    if !ts.nbio_run_until(t, &cc.done, "client-close completion") {
        return
    }

    client_destroy(&c)

    srv_settle(16)

    testing.expect(t, cc.opened, "client on_open should fire")
    testing.expect_value(t, cc.err, Client_Error.None)
    testing.expect_value(t, sobs.open_count, 1)
    testing.expect_value(t, sobs.close_count, 1)
    testing.expect_value(t, sobs.last_close, Close_Code.Going_Away)

    srv_teardown_server(t, &s, &f)
}

// --- 6. server_close, client echoes -------------------------------------------

// A client that stays open and records its terminal outcome; the server closes.
Srv_Idle_Client :: struct {
    opened:     bool,
    done:       bool,
    close_code: Close_Code,
    err:        Client_Error,
}

srv_idle_on_open :: proc(c: ^Client) {
    ic := (^Srv_Idle_Client)(c.user_data)
    ic.opened = true
}

srv_idle_on_close :: proc(c: ^Client, code: Close_Code) {
    ic := (^Srv_Idle_Client)(c.user_data)
    ic.close_code = code
    ic.done = true
}

srv_idle_on_error :: proc(c: ^Client, err: Client_Error) {
    ic := (^Srv_Idle_Client)(c.user_data)
    ic.err = err
    ic.done = true
}

// Server that calls `server_close` from on_open, so the client sees a
// server-initiated close carrying the code.
srv_closing_on_open :: proc(conn: ^Server_Conn) {
    o := srv_obs(conn)
    o.open_count += 1
    server_close(conn, .Internal_Error)
}

// Server shutdown is also legal from `on_open`; it begins a Going Away close and
// waits for the peer Close before releasing the connection.
srv_shutdown_on_open :: proc(conn: ^Server_Conn) {
    o := srv_obs(conn)
    o.open_count += 1
    server_shutdown(conn.server)
}

// `server_close` drives a server-initiated close; the client reports the code and
// echoes, and the server's own close completes with exactly one terminal.
@(test)
test_server_server_close :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    sobs: Srv_Server_Obs
    sobs.message = make([dynamic]byte, context.temp_allocator)

    cbs := Server_Callbacks {
        on_open    = srv_closing_on_open,
        on_message = srv_echo_on_message,
        on_close   = srv_server_on_close,
        on_error   = srv_server_on_error,
    }

    s: Server
    f: http.Server
    testing.expect_value(t, srv_serve(&s, &f, loop, cbs, &sobs), http.Error.None)

    port := srv_bound_port(&f)

    ic: Srv_Idle_Client
    callbacks := Callbacks {
        on_open = srv_idle_on_open,
        on_message = proc(c: ^Client, kind: Message_Kind, data: []byte) {},
        on_close = srv_idle_on_close,
        on_error = srv_idle_on_error,
    }

    c: Client
    cerr := client_connect(&c, loop, {host = "127.0.0.1", port = port, path = "/ws"}, callbacks, &ic)
    testing.expect_value(t, cerr, Client_Error.None)

    if !ts.nbio_run_until(t, &ic.done, "server-close client completion") {
        return
    }

    client_destroy(&c)

    srv_settle(16)

    testing.expect(t, ic.opened, "client on_open should fire")
    testing.expect_value(t, ic.err, Client_Error.None)
    testing.expect_value(t, ic.close_code, Close_Code.Internal_Error)
    testing.expect_value(t, sobs.open_count, 1)
    testing.expect_value(t, sobs.close_count, 1)

    srv_teardown_server(t, &s, &f)
}

@(test)
test_server_shutdown_from_on_open :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    sobs: Srv_Server_Obs
    sobs.message = make([dynamic]byte, context.temp_allocator)

    cbs := Server_Callbacks {
        on_open    = srv_shutdown_on_open,
        on_message = srv_echo_on_message,
        on_close   = srv_server_on_close,
        on_error   = srv_server_on_error,
    }

    s: Server
    f: http.Server
    testing.expect_value(t, srv_serve(&s, &f, loop, cbs, &sobs), http.Error.None)

    port := srv_bound_port(&f)

    ic: Srv_Idle_Client
    callbacks := Callbacks {
        on_open = srv_idle_on_open,
        on_message = proc(c: ^Client, kind: Message_Kind, data: []byte) {},
        on_close = srv_idle_on_close,
        on_error = srv_idle_on_error,
    }

    c: Client
    cerr := client_connect(&c, loop, {host = "127.0.0.1", port = port, path = "/ws"}, callbacks, &ic)
    testing.expect_value(t, cerr, Client_Error.None)

    if !ts.nbio_run_until(t, &ic.done, "shutdown-on-open client completion") {
        return
    }

    client_destroy(&c)

    if !ts.nbio_run_until(t, &s.shutdown_complete, "shutdown-on-open server completion") {
        return
    }

    testing.expect(t, ic.opened, "client on_open should fire before shutdown reaches it")
    testing.expect_value(t, sobs.open_count, 1)
    testing.expect_value(t, sobs.close_count, 1)
    testing.expect_value(t, sobs.last_close, Close_Code.Going_Away)

    srv_teardown_server(t, &s, &f)
}

// --- 7. max_connections enforcement -------------------------------------------

// Second-client observations for the cap test.
Srv_Cap_Client :: struct {
    opened: bool,
    done:   bool,
    err:    Client_Error,
    code:   Close_Code,
}

srv_cap_on_open :: proc(c: ^Client) {
    o := (^Srv_Cap_Client)(c.user_data)
    o.opened = true
}

srv_cap_on_close :: proc(c: ^Client, code: Close_Code) {
    o := (^Srv_Cap_Client)(c.user_data)
    o.code = code
    o.done = true
}

srv_cap_on_error :: proc(c: ^Client, err: Client_Error) {
    o := (^Srv_Cap_Client)(c.user_data)
    o.err = err
    o.done = true
}

// With `max_connections = 1`, a first client opens and stays; a second is refused at
// accept (socket closed before any handshake), so it terminates without ever opening.
@(test)
test_server_max_connections :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    sobs: Srv_Server_Obs
    sobs.message = make([dynamic]byte, context.temp_allocator)

    s: Server
    f: http.Server
    testing.expect_value(
        t,
        srv_serve(&s, &f, loop, srv_echo_callbacks(), &sobs, {max_connections = 1}),
        http.Error.None,
    )

    port := srv_bound_port(&f)

    // First client: open and idle (never closes on its own).
    first: Srv_Idle_Client
    first_cbs := Callbacks {
        on_open = srv_idle_on_open,
        on_message = proc(c: ^Client, kind: Message_Kind, data: []byte) {},
        on_close = srv_idle_on_close,
        on_error = srv_idle_on_error,
    }
    c1: Client
    testing.expect_value(
        t,
        client_connect(&c1, loop, {host = "127.0.0.1", port = port, path = "/ws"}, first_cbs, &first),
        Client_Error.None,
    )

    // Let the first connection reach Open and occupy the single slot.
    if !ts.nbio_run_until(t, &first.opened, "first capped client open") {
        return
    }

    testing.expect(t, first.opened, "first client should open")

    // Second client: the server is at capacity, so it is refused.
    second: Srv_Cap_Client
    second_cbs := Callbacks {
        on_open = srv_cap_on_open,
        on_message = proc(c: ^Client, kind: Message_Kind, data: []byte) {},
        on_close = srv_cap_on_close,
        on_error = srv_cap_on_error,
    }
    c2: Client
    testing.expect_value(
        t,
        client_connect(&c2, loop, {host = "127.0.0.1", port = port, path = "/ws"}, second_cbs, &second),
        Client_Error.None,
    )

    if !ts.nbio_run_until(t, &second.done, "second capped client completion") {
        return
    }

    client_destroy(&c2)

    testing.expect(t, !second.opened, "second client must be refused at the cap")
    // A 503 from the front door, not a dropped connection: the client reads it as an
    // HTTP answer and fails the handshake on it.
    testing.expect_value(t, second.err, Client_Error.Handshake_Failed)
    testing.expect_value(t, len(s.conns), 1)

    // Now close the first client and drain.
    client_close(&c1)

    if !ts.nbio_run_until(t, &first.done, "first capped client completion") {
        return
    }

    client_destroy(&c1)
    srv_settle(16)

    testing.expect_value(t, sobs.open_count, 1)

    srv_teardown_server(t, &s, &f)
}

// --- 8. Connect/close soak under a tracking allocator (leak hunt) -------------

// Repeated connect/handshake/exchange/close cycles must leave zero leaked
// allocations and zero bad frees: the server frees everything it allocates every
// cycle, mirroring `test_client_teardown_uaf`'s rigor.
@(test)
test_server_conn_lifecycle_no_leak :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    track: mem.Tracking_Allocator
    mem.tracking_allocator_init(&track, context.allocator)
    defer mem.tracking_allocator_destroy(&track)
    tracked := mem.tracking_allocator(&track)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    // The accumulator lives in the temp arena, so it isn't counted by the tracked
    // allocator under test; only server/client/driver buffers are audited.
    sobs: Srv_Server_Obs
    sobs.message = make([dynamic]byte, context.temp_allocator)

    s: Server
    f: http.Server
    testing.expect_value(t, srv_serve(&s, &f, loop, srv_echo_callbacks(), &sobs, {}, tracked), http.Error.None)

    port := srv_bound_port(&f)

    ITERATIONS :: 32

    for i in 0 ..< ITERATIONS {
        ec: Srv_Echo_Client
        ec.payload = transmute([]byte)string("cycle")
        ec.echoed = make([dynamic]byte, tracked)

        c: Client
        cerr := client_connect(
            &c,
            loop,
            {host = "127.0.0.1", port = port, path = "/ws"},
            srv_echo_client_callbacks(),
            &ec,
            tracked,
        )
        testing.expect_value(t, cerr, Client_Error.None)

        if !ts.nbio_run_until(t, &ec.done, "lifecycle client completion") {
            return
        }

        client_destroy(&c)

        // Drain the server-side connection's deferred teardown before the next
        // cycle so releases interleave with fresh accepts, not batch at the end.
        if !ts.nbio_run_until(t, &s, srv_server_empty, "lifecycle connection teardown") {
            return
        }

        testing.expectf(t, string(ec.echoed[:]) == "cycle", "cycle %d should echo", i)
        delete(ec.echoed)
    }

    srv_teardown_server(t, &s, &f)

    testing.expect_value(t, sobs.open_count, ITERATIONS)
    testing.expect_value(t, sobs.message_count, ITERATIONS)
    testing.expectf(t, len(track.allocation_map) == 0, "expected zero leaks, got %d", len(track.allocation_map))
    testing.expectf(t, len(track.bad_free_array) == 0, "expected zero bad frees, got %d", len(track.bad_free_array))
}

// --- Send coalescing (batched vectored send) ----------------------------------
//
// Exercise `coalesce_send_batch` end to end: the client enqueues a whole list of
// frames while a send is in flight, so `pump_send` drains them into one vectored
// nbio submission. The server echoes each frame, and the client checks both
// ordering and per-frame integrity across the batched path.

// Client observer for the batch tests: sends a fixed list of payloads on open, then
// records every echoed message (cloned) in arrival order.
Srv_Batch_Client :: struct {
    // Payloads to send, in order, once open.
    to_send:  [][]byte,

    // Echoed messages, cloned into the temp arena in arrival order.
    received: [dynamic][]byte,

    // Terminal reached.
    done:     bool,

    // Terminal error, if any.
    err:      Client_Error,
}

// Enqueue every payload synchronously so they pile up behind the first in-flight
// send and coalesce on the next pump.
srv_batch_on_open :: proc(c: ^Client) {
    bc := (^Srv_Batch_Client)(c.user_data)
    for p in bc.to_send {
        client_send_binary(c, p)
    }
}

srv_batch_on_message :: proc(c: ^Client, kind: Message_Kind, data: []byte) {
    bc := (^Srv_Batch_Client)(c.user_data)
    append(&bc.received, slice.clone(data, context.temp_allocator))

    if len(bc.received) == len(bc.to_send) {
        client_close(c)
    }
}

srv_batch_on_close :: proc(c: ^Client, code: Close_Code) {
    bc := (^Srv_Batch_Client)(c.user_data)
    bc.done = true
}

srv_batch_on_error :: proc(c: ^Client, err: Client_Error) {
    bc := (^Srv_Batch_Client)(c.user_data)
    bc.err = err
    bc.done = true
}

srv_batch_callbacks :: proc() -> Callbacks {
    return Callbacks {
        on_open = srv_batch_on_open,
        on_message = srv_batch_on_message,
        on_close = srv_batch_on_close,
        on_error = srv_batch_on_error,
    }
}

// Drive one batch exchange over a shared loop and assert the echoes match the
// inputs one-for-one, in order.
srv_run_batch :: proc(t: ^testing.T, to_send: [][]byte) {
    defer free_all(context.temp_allocator)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    sobs: Srv_Server_Obs
    sobs.message = make([dynamic]byte, context.temp_allocator)

    s: Server
    f: http.Server
    testing.expect_value(t, srv_serve(&s, &f, loop, srv_echo_callbacks(), &sobs), http.Error.None)

    port := srv_bound_port(&f)

    bc: Srv_Batch_Client
    bc.to_send = to_send
    bc.received = make([dynamic][]byte, context.temp_allocator)

    c: Client
    cerr := client_connect(
        &c,
        loop,
        {host = "127.0.0.1", port = port, path = "/ws"},
        srv_batch_callbacks(),
        &bc,
        context.temp_allocator,
    )
    testing.expect_value(t, cerr, Client_Error.None)

    if !ts.nbio_run_until(t, &bc.done, "batch client completion") {
        return
    }

    client_destroy(&c)
    srv_settle(16)

    testing.expect_value(t, bc.err, Client_Error.None)
    testing.expect_value(t, len(bc.received), len(to_send))

    if len(bc.received) == len(to_send) {
        for i in 0 ..< len(to_send) {
            ok := slice.equal(bc.received[i], to_send[i])
            testing.expectf(
                t,
                ok,
                "message %d mismatch (sent %d bytes, got %d)",
                i,
                len(to_send[i]),
                len(bc.received[i]),
            )
        }
    }

    srv_teardown_server(t, &s, &f)
}

@(test)
test_server_batch_coalesces_in_order :: proc(t: ^testing.T) {
    // 64 distinct 1 KiB messages, all enqueued before the first send completes, so
    // they drain into one coalesced vectored send (64 KiB, well under SEND_BATCH_BYTES).
    // Each carries a distinct byte pattern to catch reordering or corruption.
    N :: 64
    payloads := make([][]byte, N, context.temp_allocator)

    for i in 0 ..< N {
        buf := make([]byte, 1024, context.temp_allocator)
        for j in 0 ..< len(buf) {
            buf[j] = byte((i * 7 + j) & 0xff)
        }

        payloads[i] = buf
    }

    srv_run_batch(t, payloads)
}

@(test)
test_server_batch_oversized_frame_alone :: proc(t: ^testing.T) {
    // A payload larger than SEND_BATCH_BYTES sits between two small ones; the
    // coalescer must send it alone (never split/dropped), while the small frames
    // still arrive intact and in order.
    small_a := make([]byte, 512, context.temp_allocator)
    big := make([]byte, SEND_BATCH_BYTES + 4096, context.temp_allocator)
    small_b := make([]byte, 512, context.temp_allocator)

    for j in 0 ..< len(small_a) {
        small_a[j] = byte(0xa0 + (j & 0x0f))
    }

    for j in 0 ..< len(big) {
        big[j] = byte(j & 0xff)
    }

    for j in 0 ..< len(small_b) {
        small_b[j] = byte(0x50 + (j & 0x0f))
    }

    payloads := [][]byte{small_a, big, small_b}

    srv_run_batch(t, payloads)
}
