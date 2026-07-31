package websocket

import "core:log"
import "core:mem"
import "core:nbio"
import "core:net"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

// Shared state between the loopback server thread and the client test.
Loopback_Args :: struct {
    // Loopback port the OS assigned, published before `listening`.
    port:      int,

    // Set true (atomically) once the server is accepting, so the client waits.
    listening: bool,
}

// A minimal blocking WebSocket server: completes the upgrade, sends one text
// frame "hello", drains the client's close frame, and closes. Runs on its own
// thread so the nbio client can drive the main thread's event loop.
loopback_server :: proc(args: ^Loopback_Args) {
    defer free_all(context.temp_allocator)

    listener, conn, ok := srv_accept(&args.port, &args.listening)
    if !ok {
        return
    }
    defer net.close(listener)
    defer net.close(conn)

    if !srv_upgrade(conn) {
        return
    }

    // Send one unmasked server text frame carrying "hello".
    srv_send_frame(conn, true, .Text, transmute([]byte)string("hello"))

    // Drain whatever the client sends back (its close frame), then let defers close.
    scratch: [512]byte
    net.recv_tcp(conn, scratch[:])
}

// --- Loopback server harness --------------------------------------------------
//
// The tests below drive the nbio client against a blocking server on a worker
// thread. These helpers factor the parts every server variant shares — accept,
// upgrade, framing — so each test proc only spells out its own script. Server
// observations are plain fields written on the worker and read by the test after
// `thread.join`, which establishes the happens-before that makes them visible.

// Fields a server variant records for the test to assert after `thread.join`.
Srv :: struct {
    // Loopback port the OS assigned, published before `listening`.
    port:           int,

    // Published (atomically) once accepting, so the client waits to connect.
    listening:      bool,

    // The server ran its full script without an unexpected I/O failure.
    ok:             bool,

    // A Pong frame was read back from the client (ping auto-reply test).
    got_pong:       bool,

    // Payload the client echoed in its Pong.
    pong:           [64]byte,
    pong_len:       int,

    // A Close frame was read back from the client.
    close_seen:     bool,

    // Length of the client's echoed close body (0 for an empty-body echo).
    close_body_len: int,

    // Status code carried in the client's echoed close body, when present.
    close_code:     u16,

    // Text frames read from the client, in wire order (send-serialization test).
    texts:          [8]Srv_Text,
    text_count:     int,
}

// One captured inbound text payload.
Srv_Text :: struct {
    buf: [128]byte,
    len: int,
}

// Bind an OS-assigned loopback port, publish it through `port` before raising
// `listening`, and accept one connection. The port is never fixed: a hardcoded one
// collides with any other listener on the machine — a second test run, a parallel CI
// job, an orphaned process — and fails the bind rather than the assertion under test.
// The caller closes both returned sockets.
srv_accept :: proc(port: ^int, listening: ^bool) -> (listener: net.TCP_Socket, conn: net.TCP_Socket, ok: bool) {
    l, lerr := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
    if lerr != nil {
        log.errorf("srv_accept: listen failed: %v", lerr)
        return {}, {}, false
    }

    bound, berr := net.bound_endpoint(l)
    if berr != nil {
        log.errorf("srv_accept: bound_endpoint failed: %v", berr)
        net.close(l)
        return {}, {}, false
    }

    // Ordered against the client's `listening` load, so it never reads port 0.
    sync.atomic_store(port, bound.port)
    sync.atomic_store(listening, true)

    c, _, aerr := net.accept_tcp(l)
    if aerr != nil {
        log.errorf("srv_accept: accept on %d failed: %v", bound.port, aerr)
        net.close(l)
        return {}, {}, false
    }

    return l, c, true
}

// A loopback port with nothing listening: bind one, read it back, release it. Beats a
// fixed port, which fails the moment anything happens to be listening there.
srv_dead_port :: proc(t: ^testing.T) -> int {
    l, lerr := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
    if !testing.expect(t, lerr == nil, "should be able to reserve a port") {
        return 0
    }
    defer net.close(l)

    bound, berr := net.bound_endpoint(l)
    testing.expect(t, berr == nil, "reserved port should be readable")

    return bound.port
}

// Read the client's upgrade request through the `\r\n\r\n` terminator into `buf`.
srv_read_request :: proc(conn: net.TCP_Socket, buf: []byte) -> (n: int, ok: bool) {
    for n < len(buf) {
        got, rerr := net.recv_tcp(conn, buf[n:])
        if rerr != nil || got == 0 {
            return n, false
        }

        n += got
        if strings.contains(string(buf[:n]), "\r\n\r\n") {
            return n, true
        }
    }

    return n, false
}

// Validate the client's upgrade request and build the matching 101 response with
// the package's own server-side handshake primitives. ok is false on a malformed
// request. Exercises `parse_upgrade_request` + `build_upgrade_response` from a real
// server caller. The response borrows `allocator`.
srv_build_upgrade_response :: proc(request: []byte, allocator := context.temp_allocator) -> (resp: []byte, ok: bool) {
    req, result, _, status := parse_upgrade_request(request)
    if status != .Ready || result != .Ok {
        return nil, false
    }

    return build_upgrade_response(transmute([]byte)req.key, allocator), true
}

// Read the request and send a valid 101 response. The common successful upgrade.
srv_upgrade :: proc(conn: net.TCP_Socket) -> bool {
    req: [4096]byte
    n, ok := srv_read_request(conn, req[:])
    if !ok {
        return false
    }

    resp, dok := srv_build_upgrade_response(req[:n], context.temp_allocator)
    if !dok {
        return false
    }

    _, serr := net.send_tcp(conn, resp)

    return serr == nil
}

// Build one unmasked server frame (servers never mask). Handles the 7-bit and
// 16-bit length forms, which is all the tests need.
srv_frame_bytes :: proc(fin: bool, opcode: Op_Code, payload: []byte, allocator := context.allocator) -> []byte {
    hdr: [4]byte
    hdr[0] = (fin ? 0x80 : 0) | u8(opcode)
    n := 2
    if len(payload) < PAYLOAD_LEN_16 {
        hdr[1] = u8(len(payload))
    } else {
        hdr[1] = PAYLOAD_LEN_16
        hdr[2] = byte(len(payload) >> 8)
        hdr[3] = byte(len(payload))
        n = 4
    }

    out := make([]byte, n + len(payload), allocator)
    copy(out, hdr[:n])
    copy(out[n:], payload)

    return out
}

// Send one unmasked server frame.
srv_send_frame :: proc(conn: net.TCP_Socket, fin: bool, opcode: Op_Code, payload: []byte) -> bool {
    frame := srv_frame_bytes(fin, opcode, payload, context.temp_allocator)
    _, err := net.send_tcp(conn, frame)

    return err == nil
}

// Write a 2-byte big-endian close status code into `buf` and return it as a body.
srv_close_body :: proc(buf: ^[2]byte, code: u16) -> []byte {
    buf[0] = byte(code >> 8)
    buf[1] = byte(code)

    return buf[:]
}

// Buffered reader for the masked frames the client writes back, built on a
// server-role `Decoder` — the same primitive a real server uses to enforce masking
// and unmask payloads. Zero-initialized at each use site; the decoder is created
// lazily on the first read.
Srv_Frame_Reader :: struct {
    conn:    net.TCP_Socket,
    decoder: Decoder,
    started: bool,
    buf:     [8192]byte,
}

// Read the next whole frame via the server-role decoder, which rejects an unmasked
// frame and unmasks the payload. The returned payload is allocated in the enclosing
// server's temp arena and stays valid until it is freed.
srv_next_frame :: proc(r: ^Srv_Frame_Reader) -> (opcode: Op_Code, payload: []byte, ok: bool) {
    if !r.started {
        decoder_init(&r.decoder, 1 << 20, 1 << 20, .Server, context.temp_allocator)
        r.started = true
    }

    for {
        msg, has, err := decoder_next(&r.decoder, context.temp_allocator)
        if err != .None {
            return .Continuation, nil, false
        }

        if has {
            return message_kind_opcode(msg.kind), msg.data, true
        }

        // Not a whole frame yet; pull more bytes and feed the decoder.
        n, rerr := net.recv_tcp(r.conn, r.buf[:])
        if rerr != nil || n == 0 {
            return .Continuation, nil, false
        }

        decoder_feed(&r.decoder, r.buf[:n])
    }
}

// Map a decoded message kind back to the wire opcode the server tests assert on.
message_kind_opcode :: proc(kind: Message_Kind) -> Op_Code {
    switch kind {
    case .Text:
        return .Text

    case .Binary:
        return .Binary

    case .Ping:
        return .Ping

    case .Pong:
        return .Pong

    case .Close:
        return .Connection_Close
    }

    return .Continuation
}

// Bounded wait for a server thread to begin accepting before the client dials.
// A startup readiness backstop, not protocol synchronization.
srv_wait_listening :: proc(listening: ^bool) -> bool {
    for _ in 0 ..< 500 {
        if sync.atomic_load(listening) {
            return true
        }

        time.sleep(time.Millisecond)
    }

    return false
}

// What the client callbacks record for the test to assert. Reached via
// `c.user_data`; terminal counters catch a callback firing more than once.
Client_Obs :: struct {
    // on_open fired.
    opened:               bool,

    // Reassembled bytes of every received application message, concatenated.
    message:              [dynamic]byte,

    // Count of on_message calls (a control frame must never surface here).
    message_count:        int,

    // Terminal error, if the error path fired.
    err:                  Client_Error,

    // Close code reported to on_close.
    close_code:           Close_Code,

    // Number of terminal callbacks (on_close + on_error); must end at exactly 1.
    terminal_count:       int,

    // `c.state` sampled inside the terminal callback; must be `.Closed`.
    state_at_term:        Client_State,

    // Result of a `client_send_text` attempted after close began.
    send_after_close_err: Client_Error,

    // The connection reached a terminal state.
    done:                 bool,
}

// Terminal-close callback shared by tests that do not destroy from within it.
obs_on_close :: proc(c: ^Client, code: Close_Code) {
    o := (^Client_Obs)(c.user_data)
    o.close_code = code
    o.state_at_term = c.state
    o.terminal_count += 1
    o.done = true
}

// Terminal-error callback.
obs_on_error :: proc(c: ^Client, err: Client_Error) {
    o := (^Client_Obs)(c.user_data)
    o.err = err
    o.state_at_term = c.state
    o.terminal_count += 1
    o.done = true
}

// Record a message without closing (used where no further action is expected).
obs_on_message :: proc(c: ^Client, kind: Message_Kind, data: []byte) {
    o := (^Client_Obs)(c.user_data)
    append(&o.message, ..data)
    o.message_count += 1
}

// Record a message, then begin a graceful close.
obs_on_message_close :: proc(c: ^Client, kind: Message_Kind, data: []byte) {
    o := (^Client_Obs)(c.user_data)
    append(&o.message, ..data)
    o.message_count += 1
    client_close(c)
}

// State the client callbacks report back into. Reached via `c.user_data`
// because Odin proc literals cannot capture.
Loopback_Result :: struct {
    // on_open fired.
    opened:  bool,

    // Bytes of the received text message.
    message: [dynamic]byte,

    // Terminal error, if any.
    err:     Client_Error,

    // The connection reached a terminal state (close or error).
    done:    bool,
}

// End to end over loopback: dial, upgrade with a real accept check, receive a
// server text frame, then close cleanly — all on one nbio loop.
@(test)
test_client_loopback :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    args := Loopback_Args{}
    server := thread.create_and_start_with_poly_data(&args, loopback_server)
    defer {
        thread.join(server)
        thread.destroy(server)
    }

    // Wait (bounded) for the server to start accepting before connecting.
    ready := false
    for _ in 0 ..< 200 {
        if sync.atomic_load(&args.listening) {
            ready = true
            break
        }

        time.sleep(10 * time.Millisecond)
    }
    if !testing.expect(t, ready, "server should start listening") {
        return
    }

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    result: Loopback_Result
    result.message = make([dynamic]byte, context.temp_allocator)

    callbacks := Callbacks {
        on_open = proc(c: ^Client) {
            r := (^Loopback_Result)(c.user_data)
            r.opened = true
        },
        on_message = proc(c: ^Client, kind: Message_Kind, data: []byte) {
            r := (^Loopback_Result)(c.user_data)
            append(&r.message, ..data)
            client_close(c)
        },
        on_close = proc(c: ^Client, code: Close_Code) {
            r := (^Loopback_Result)(c.user_data)
            r.done = true
        },
        on_error = proc(c: ^Client, err: Client_Error) {
            r := (^Loopback_Result)(c.user_data)
            r.err = err
            r.done = true
        },
    }

    c: Client
    cerr := client_connect(
        &c,
        loop,
        {host = "127.0.0.1", port = args.port, path = "/ws"},
        callbacks,
        &result,
        context.temp_allocator,
    )
    testing.expect_value(t, cerr, Client_Error.None)

    nbio.run_until(&result.done)
    client_destroy(&c)

    testing.expect(t, result.opened, "on_open should fire")
    testing.expect_value(t, result.err, Client_Error.None)
    testing.expect_value(t, string(result.message[:]), "hello")
}

// --- 1. Teardown UAF regression ----------------------------------------------

// Server for the teardown regression: complete the upgrade, send nothing (so the
// client sits in steady-state recv), then read the client-initiated close frame.
srv_regression :: proc(s: ^Srv) {
    defer free_all(context.temp_allocator)

    listener, conn, ok := srv_accept(&s.port, &s.listening)
    if !ok {
        return
    }
    defer net.close(listener)
    defer net.close(conn)

    if !srv_upgrade(conn) {
        return
    }

    r := Srv_Frame_Reader {
        conn = conn,
    }
    op, _, fok := srv_next_frame(&r)
    if fok && op == .Connection_Close {
        s.close_seen = true
    }

    s.ok = true
}

// Fired from a next-tick timer — i.e. outside the recv/message callback stack —
// so the close is triggered with a steady-state recv still outstanding.
close_on_tick :: proc(op: ^nbio.Operation, c: ^Client) {
    client_close(c)
}

// Regression for the teardown use-after-free. The connection reaches Open with a
// steady-state recv outstanding; a next-tick timer (not on_message) triggers the
// close; on_close destroys the client immediately and the loop keeps ticking. Run
// under a tracking allocator asserting zero leaks and zero bad frees, and assert
// exactly one terminal callback with no crash on the trailing ticks.
@(test)
test_client_teardown_uaf :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    track: mem.Tracking_Allocator
    mem.tracking_allocator_init(&track, context.allocator)
    defer mem.tracking_allocator_destroy(&track)
    tracked := mem.tracking_allocator(&track)

    s := Srv{}
    server := thread.create_and_start_with_poly_data(&s, srv_regression)
    defer {
        thread.join(server)
        thread.destroy(server)
    }

    if !testing.expect(t, srv_wait_listening(&s.listening), "server should listen") {
        return
    }

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    obs: Client_Obs

    callbacks := Callbacks {
        on_open = proc(c: ^Client) {
            o := (^Client_Obs)(c.user_data)
            o.opened = true
            // Trigger the close from a subsequent tick, not from inside a callback
            // running on the client's own op completion.
            nbio.next_tick_poly(c, close_on_tick, c.loop)
        },
        on_message = obs_on_message,
        on_close = proc(c: ^Client, code: Close_Code) {
            o := (^Client_Obs)(c.user_data)
            o.close_code = code
            o.terminal_count += 1
            // Destroy immediately from the terminal callback (zeroes `c`), then
            // signal done — the loop keeps ticking below.
            client_destroy(c)
            o.done = true
        },
        on_error = obs_on_error,
    }

    c: Client
    cerr := client_connect(&c, loop, {host = "127.0.0.1", port = s.port, path = "/ws"}, callbacks, &obs, tracked)
    testing.expect_value(t, cerr, Client_Error.None)

    nbio.run_until(&obs.done)

    // Keep ticking after the immediate destroy: any completion still referencing
    // the freed client would surface here as a crash or a tracking-allocator fault.
    for _ in 0 ..< 16 {
        nbio.tick(time.Millisecond)
    }

    testing.expect(t, obs.opened, "on_open should fire")
    testing.expect_value(t, obs.terminal_count, 1)
    // The peer reads our Close but drops TCP without echoing one, so RFC 6455
    // requires the locally synthesized abnormal status.
    testing.expect_value(t, obs.close_code, Close_Code.Abnormal_Closure)
    testing.expectf(t, len(track.allocation_map) == 0, "expected zero leaks, got %d", len(track.allocation_map))
    testing.expectf(t, len(track.bad_free_array) == 0, "expected zero bad frees, got %d", len(track.bad_free_array))
}

// --- 2. Dial failure ----------------------------------------------------------

// Connect to a port with no listener: on_error fires exactly once with
// .Dial_Failed, the state is Closed, and destroy is clean. Regresses the old
// close(0) teardown bug — the has_socket guard means the failed dial closes no fd.
@(test)
test_client_dial_failure :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    obs: Client_Obs

    callbacks := Callbacks {
        on_open = proc(c: ^Client) {o := (^Client_Obs)(c.user_data); o.opened = true},
        on_message = obs_on_message,
        on_close = obs_on_close,
        on_error = obs_on_error,
    }

    c: Client
    // Nothing listens on a just-released port, so loopback refuses immediately.
    cerr := client_connect(
        &c,
        loop,
        {host = "127.0.0.1", port = srv_dead_port(t), path = "/ws", handshake_timeout = 2 * time.Second},
        callbacks,
        &obs,
    )
    testing.expect_value(t, cerr, Client_Error.None)

    nbio.run_until(&obs.done)
    client_destroy(&c)

    testing.expect(t, !obs.opened, "on_open must not fire on a failed dial")
    testing.expect_value(t, obs.terminal_count, 1)
    testing.expect_value(t, obs.err, Client_Error.Dial_Failed)
    testing.expect_value(t, obs.state_at_term, Client_State.Closed)
}

// --- 3. Handshake failure (non-101) ------------------------------------------

// Server that reads the upgrade request then answers with a non-101 status.
srv_bad_status :: proc(s: ^Srv) {
    defer free_all(context.temp_allocator)

    listener, conn, ok := srv_accept(&s.port, &s.listening)
    if !ok {
        return
    }
    defer net.close(listener)
    defer net.close(conn)

    req: [4096]byte
    if _, rok := srv_read_request(conn, req[:]); !rok {
        return
    }

    net.send_tcp(conn, transmute([]byte)string("HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n"))
    s.ok = true
}

// A non-101 upgrade response fails with Handshake_Failed exactly once.
@(test)
test_client_handshake_bad_status :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    s := Srv{}
    server := thread.create_and_start_with_poly_data(&s, srv_bad_status)
    defer {
        thread.join(server)
        thread.destroy(server)
    }

    if !testing.expect(t, srv_wait_listening(&s.listening), "server should listen") {
        return
    }

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    obs: Client_Obs

    callbacks := Callbacks {
        on_open = proc(c: ^Client) {o := (^Client_Obs)(c.user_data); o.opened = true},
        on_message = obs_on_message,
        on_close = obs_on_close,
        on_error = obs_on_error,
    }

    c: Client
    cerr := client_connect(&c, loop, {host = "127.0.0.1", port = s.port, path = "/ws"}, callbacks, &obs)
    testing.expect_value(t, cerr, Client_Error.None)

    nbio.run_until(&obs.done)
    client_destroy(&c)

    testing.expect(t, !obs.opened, "on_open must not fire on a failed handshake")
    testing.expect_value(t, obs.terminal_count, 1)
    testing.expect_value(t, obs.err, Client_Error.Handshake_Failed)
    testing.expect_value(t, obs.state_at_term, Client_State.Closed)
}

// --- 4. Handshake response cap ------------------------------------------------

// Server that reads the upgrade request then dribbles well over the 64 KiB cap of
// non-terminated bytes ('x' never forms the `\r\n\r\n` header terminator).
srv_handshake_flood :: proc(s: ^Srv) {
    defer free_all(context.temp_allocator)

    listener, conn, ok := srv_accept(&s.port, &s.listening)
    if !ok {
        return
    }
    defer net.close(listener)
    defer net.close(conn)

    req: [4096]byte
    if _, rok := srv_read_request(conn, req[:]); !rok {
        return
    }

    junk: [4096]byte
    for &b in junk {
        b = 'x'
    }

    // 20 * 4 KiB = 80 KiB, past MAX_HANDSHAKE_RESPONSE_BYTES; stop once the client
    // gives up and the socket errors.
    for _ in 0 ..< 20 {
        if _, serr := net.send_tcp(conn, junk[:]); serr != nil {
            break
        }
    }

    s.ok = true
}

// An unbounded header block past 64 KiB fails with Handshake_Failed, bounded by
// the accumulation cap rather than growing without limit.
@(test)
test_client_handshake_cap :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    s := Srv{}
    server := thread.create_and_start_with_poly_data(&s, srv_handshake_flood)
    defer {
        thread.join(server)
        thread.destroy(server)
    }

    if !testing.expect(t, srv_wait_listening(&s.listening), "server should listen") {
        return
    }

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    obs: Client_Obs

    callbacks := Callbacks {
        on_open = proc(c: ^Client) {o := (^Client_Obs)(c.user_data); o.opened = true},
        on_message = obs_on_message,
        on_close = obs_on_close,
        on_error = obs_on_error,
    }

    c: Client
    cerr := client_connect(&c, loop, {host = "127.0.0.1", port = s.port, path = "/ws"}, callbacks, &obs)
    testing.expect_value(t, cerr, Client_Error.None)

    nbio.run_until(&obs.done)
    client_destroy(&c)

    testing.expect(t, !obs.opened, "on_open must not fire past the handshake cap")
    testing.expect_value(t, obs.terminal_count, 1)
    testing.expect_value(t, obs.err, Client_Error.Handshake_Failed)
    testing.expect_value(t, obs.state_at_term, Client_State.Closed)
}

// --- 5. Pipelined first frame -------------------------------------------------

// Server that sends the 101 response and the first text frame in a single TCP
// write, exercising the leftover-bytes handoff into the decoder.
srv_pipelined :: proc(s: ^Srv) {
    defer free_all(context.temp_allocator)

    listener, conn, ok := srv_accept(&s.port, &s.listening)
    if !ok {
        return
    }
    defer net.close(listener)
    defer net.close(conn)

    req: [4096]byte
    n, rok := srv_read_request(conn, req[:])
    if !rok {
        return
    }

    resp, dok := srv_build_upgrade_response(req[:n], context.temp_allocator)
    if !dok {
        return
    }

    frame := srv_frame_bytes(true, .Text, transmute([]byte)string("pipelined"), context.temp_allocator)
    combined := make([]byte, len(resp) + len(frame), context.temp_allocator)
    copy(combined, resp)
    copy(combined[len(resp):], frame)

    net.send_tcp(conn, combined)

    scratch: [512]byte
    net.recv_tcp(conn, scratch[:])
    s.ok = true
}

// The response and first frame arriving together: on_open then on_message fire
// with the correct payload.
@(test)
test_client_pipelined_first_frame :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    s := Srv{}
    server := thread.create_and_start_with_poly_data(&s, srv_pipelined)
    defer {
        thread.join(server)
        thread.destroy(server)
    }

    if !testing.expect(t, srv_wait_listening(&s.listening), "server should listen") {
        return
    }

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    obs: Client_Obs
    obs.message = make([dynamic]byte, context.temp_allocator)

    callbacks := Callbacks {
        on_open = proc(c: ^Client) {o := (^Client_Obs)(c.user_data); o.opened = true},
        on_message = obs_on_message_close,
        on_close = obs_on_close,
        on_error = obs_on_error,
    }

    c: Client
    cerr := client_connect(
        &c,
        loop,
        {host = "127.0.0.1", port = s.port, path = "/ws"},
        callbacks,
        &obs,
        context.temp_allocator,
    )
    testing.expect_value(t, cerr, Client_Error.None)

    nbio.run_until(&obs.done)
    client_destroy(&c)

    testing.expect(t, obs.opened, "on_open should fire")
    testing.expect_value(t, obs.message_count, 1)
    testing.expect_value(t, string(obs.message[:]), "pipelined")
    testing.expect_value(t, obs.err, Client_Error.None)
}

// --- 6. Ping -> automatic Pong -----------------------------------------------

// Server that sends a Ping after the upgrade, reads back the client's Pong, then
// closes gracefully.
srv_ping :: proc(s: ^Srv) {
    defer free_all(context.temp_allocator)

    listener, conn, ok := srv_accept(&s.port, &s.listening)
    if !ok {
        return
    }
    defer net.close(listener)
    defer net.close(conn)

    if !srv_upgrade(conn) {
        return
    }

    srv_send_frame(conn, true, .Ping, transmute([]byte)string("ping-payload"))

    r := Srv_Frame_Reader {
        conn = conn,
    }
    op, pl, fok := srv_next_frame(&r)
    if fok && op == .Pong {
        s.got_pong = true
        s.pong_len = copy(s.pong[:], pl)
    }

    // End gracefully so the client's on_close reports Normal_Closure.
    body: [2]byte
    srv_send_frame(conn, true, .Connection_Close, srv_close_body(&body, u16(Close_Code.Normal_Closure)))
    srv_next_frame(&r)
    s.ok = true
}

// A Ping is answered with a Pong echoing its payload, and on_message never fires
// for it.
@(test)
test_client_ping_pong :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    s := Srv{}
    server := thread.create_and_start_with_poly_data(&s, srv_ping)
    defer {
        thread.join(server)
        thread.destroy(server)
    }

    if !testing.expect(t, srv_wait_listening(&s.listening), "server should listen") {
        return
    }

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    obs: Client_Obs

    callbacks := Callbacks {
        on_open = proc(c: ^Client) {o := (^Client_Obs)(c.user_data); o.opened = true},
        on_message = obs_on_message,
        on_close = obs_on_close,
        on_error = obs_on_error,
    }

    c: Client
    cerr := client_connect(&c, loop, {host = "127.0.0.1", port = s.port, path = "/ws"}, callbacks, &obs)
    testing.expect_value(t, cerr, Client_Error.None)

    nbio.run_until(&obs.done)
    client_destroy(&c)

    testing.expect(t, obs.opened, "on_open should fire")
    testing.expect_value(t, obs.message_count, 0)
    testing.expect_value(t, obs.close_code, Close_Code.Normal_Closure)
    testing.expect_value(t, obs.terminal_count, 1)

    thread.join(server)
    testing.expect(t, s.got_pong, "server should read back a Pong")
    testing.expect_value(t, string(s.pong[:s.pong_len]), "ping-payload")
}

// --- 7. Peer close with a code -----------------------------------------------

// Server that sends Close(1000, "bye") and records the client's echoed close.
srv_close_with_code :: proc(s: ^Srv) {
    defer free_all(context.temp_allocator)

    listener, conn, ok := srv_accept(&s.port, &s.listening)
    if !ok {
        return
    }
    defer net.close(listener)
    defer net.close(conn)

    if !srv_upgrade(conn) {
        return
    }

    code := u16(Close_Code.Normal_Closure)
    body: [5]byte
    body[0] = byte(code >> 8)
    body[1] = byte(code)
    copy(body[2:], transmute([]byte)string("bye"))
    srv_send_frame(conn, true, .Connection_Close, body[:])

    r := Srv_Frame_Reader {
        conn = conn,
    }
    op, pl, fok := srv_next_frame(&r)
    if fok && op == .Connection_Close {
        s.close_seen = true
        s.close_body_len = len(pl)
        if len(pl) >= 2 {
            s.close_code = u16(pl[0]) << 8 | u16(pl[1])
        }
    }

    s.ok = true
}

// A peer close carrying a code is echoed with that code on the wire, and
// on_close reports it.
@(test)
test_client_peer_close_with_code :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    s := Srv{}
    server := thread.create_and_start_with_poly_data(&s, srv_close_with_code)
    defer {
        thread.join(server)
        thread.destroy(server)
    }

    if !testing.expect(t, srv_wait_listening(&s.listening), "server should listen") {
        return
    }

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    obs: Client_Obs

    callbacks := Callbacks {
        on_open = proc(c: ^Client) {o := (^Client_Obs)(c.user_data); o.opened = true},
        on_message = obs_on_message,
        on_close = obs_on_close,
        on_error = obs_on_error,
    }

    c: Client
    cerr := client_connect(&c, loop, {host = "127.0.0.1", port = s.port, path = "/ws"}, callbacks, &obs)
    testing.expect_value(t, cerr, Client_Error.None)

    nbio.run_until(&obs.done)
    client_destroy(&c)

    testing.expect_value(t, obs.close_code, Close_Code.Normal_Closure)
    testing.expect_value(t, obs.terminal_count, 1)

    thread.join(server)
    testing.expect(t, s.close_seen, "server should read the client's echoed close")
    testing.expect_value(t, s.close_body_len, 2)
    testing.expect_value(t, s.close_code, u16(1000))
}

// --- 8. Peer close with empty body -------------------------------------------

// Server that sends an empty-body close and records the client's echoed close.
srv_close_empty :: proc(s: ^Srv) {
    defer free_all(context.temp_allocator)

    listener, conn, ok := srv_accept(&s.port, &s.listening)
    if !ok {
        return
    }
    defer net.close(listener)
    defer net.close(conn)

    if !srv_upgrade(conn) {
        return
    }

    srv_send_frame(conn, true, .Connection_Close, nil)

    r := Srv_Frame_Reader {
        conn = conn,
    }
    op, pl, fok := srv_next_frame(&r)
    if fok && op == .Connection_Close {
        s.close_seen = true
        s.close_body_len = len(pl)
    }

    s.ok = true
}

// An empty peer close is echoed with an empty body (never a serialized 1005),
// while on_close reports the synthesized No_Status_Rcvd locally.
@(test)
test_client_peer_close_empty :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    s := Srv{}
    server := thread.create_and_start_with_poly_data(&s, srv_close_empty)
    defer {
        thread.join(server)
        thread.destroy(server)
    }

    if !testing.expect(t, srv_wait_listening(&s.listening), "server should listen") {
        return
    }

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    obs: Client_Obs

    callbacks := Callbacks {
        on_open = proc(c: ^Client) {o := (^Client_Obs)(c.user_data); o.opened = true},
        on_message = obs_on_message,
        on_close = obs_on_close,
        on_error = obs_on_error,
    }

    c: Client
    cerr := client_connect(&c, loop, {host = "127.0.0.1", port = s.port, path = "/ws"}, callbacks, &obs)
    testing.expect_value(t, cerr, Client_Error.None)

    nbio.run_until(&obs.done)
    client_destroy(&c)

    testing.expect_value(t, obs.close_code, Close_Code.No_Status_Rcvd)
    testing.expect_value(t, obs.terminal_count, 1)

    thread.join(server)
    testing.expect(t, s.close_seen, "server should read the client's echoed close")
    testing.expect_value(t, s.close_body_len, 0)
}

// --- 9. Abrupt TCP close ------------------------------------------------------

// Server that upgrades, then drops the TCP connection with no close frame.
srv_abrupt :: proc(s: ^Srv) {
    defer free_all(context.temp_allocator)

    listener, conn, ok := srv_accept(&s.port, &s.listening)
    if !ok {
        return
    }
    defer net.close(listener)
    defer net.close(conn)

    if !srv_upgrade(conn) {
        return
    }

    s.ok = true
    // Defers close the socket abruptly — no WebSocket close frame.
}

// A dropped TCP connection surfaces via on_close with Abnormal_Closure (the
// documented policy), exactly once, and destroy is clean.
@(test)
test_client_abrupt_close :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    s := Srv{}
    server := thread.create_and_start_with_poly_data(&s, srv_abrupt)
    defer {
        thread.join(server)
        thread.destroy(server)
    }

    if !testing.expect(t, srv_wait_listening(&s.listening), "server should listen") {
        return
    }

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    obs: Client_Obs

    callbacks := Callbacks {
        on_open = proc(c: ^Client) {o := (^Client_Obs)(c.user_data); o.opened = true},
        on_message = obs_on_message,
        on_close = obs_on_close,
        on_error = obs_on_error,
    }

    c: Client
    cerr := client_connect(&c, loop, {host = "127.0.0.1", port = s.port, path = "/ws"}, callbacks, &obs)
    testing.expect_value(t, cerr, Client_Error.None)

    nbio.run_until(&obs.done)
    client_destroy(&c)

    testing.expect(t, obs.opened, "on_open should fire before the drop")
    testing.expect_value(t, obs.terminal_count, 1)
    testing.expect_value(t, obs.err, Client_Error.None)
    testing.expect_value(t, obs.close_code, Close_Code.Abnormal_Closure)
}

// --- 10. Fragmented inbound message with an interleaved Ping ------------------

// Server that sends a text message split across three fragments with a Ping
// interleaved between the first two.
srv_fragmented :: proc(s: ^Srv) {
    defer free_all(context.temp_allocator)

    listener, conn, ok := srv_accept(&s.port, &s.listening)
    if !ok {
        return
    }
    defer net.close(listener)
    defer net.close(conn)

    if !srv_upgrade(conn) {
        return
    }

    srv_send_frame(conn, false, .Text, transmute([]byte)string("Hel"))
    srv_send_frame(conn, true, .Ping, transmute([]byte)string("p"))
    srv_send_frame(conn, false, .Continuation, transmute([]byte)string("lo "))
    srv_send_frame(conn, true, .Continuation, transmute([]byte)string("World"))

    // Drain the client's pong and close frames until the connection ends.
    r := Srv_Frame_Reader {
        conn = conn,
    }
    for {
        op, _, fok := srv_next_frame(&r)
        if !fok || op == .Connection_Close {
            break
        }
    }

    s.ok = true
}

// A text message split across continuation frames, with an interleaved Ping,
// reassembles into a single on_message.
@(test)
test_client_fragmented_message :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    s := Srv{}
    server := thread.create_and_start_with_poly_data(&s, srv_fragmented)
    defer {
        thread.join(server)
        thread.destroy(server)
    }

    if !testing.expect(t, srv_wait_listening(&s.listening), "server should listen") {
        return
    }

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    obs: Client_Obs
    obs.message = make([dynamic]byte, context.temp_allocator)

    callbacks := Callbacks {
        on_open = proc(c: ^Client) {o := (^Client_Obs)(c.user_data); o.opened = true},
        on_message = obs_on_message_close,
        on_close = obs_on_close,
        on_error = obs_on_error,
    }

    c: Client
    cerr := client_connect(
        &c,
        loop,
        {host = "127.0.0.1", port = s.port, path = "/ws"},
        callbacks,
        &obs,
        context.temp_allocator,
    )
    testing.expect_value(t, cerr, Client_Error.None)

    nbio.run_until(&obs.done)
    client_destroy(&c)

    testing.expect_value(t, obs.message_count, 1)
    testing.expect_value(t, string(obs.message[:]), "Hello World")
    testing.expect_value(t, obs.terminal_count, 1)
}

// --- 11. Send-queue serialization --------------------------------------------

// Server that collects every text frame the client sends, in wire order, until
// the closing frame arrives.
srv_recv_order :: proc(s: ^Srv) {
    defer free_all(context.temp_allocator)

    listener, conn, ok := srv_accept(&s.port, &s.listening)
    if !ok {
        return
    }
    defer net.close(listener)
    defer net.close(conn)

    if !srv_upgrade(conn) {
        return
    }

    r := Srv_Frame_Reader {
        conn = conn,
    }
    for {
        op, pl, fok := srv_next_frame(&r)
        if !fok || op == .Connection_Close {
            break
        }

        if op == .Text && s.text_count < len(s.texts) {
            s.texts[s.text_count].len = copy(s.texts[s.text_count].buf[:], pl)
            s.text_count += 1
        }
    }

    s.ok = true
}

// Three messages queued back-to-back from on_open arrive at the server complete
// and in order.
@(test)
test_client_send_serialization :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    s := Srv{}
    server := thread.create_and_start_with_poly_data(&s, srv_recv_order)
    defer {
        thread.join(server)
        thread.destroy(server)
    }

    if !testing.expect(t, srv_wait_listening(&s.listening), "server should listen") {
        return
    }

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    obs: Client_Obs

    callbacks := Callbacks {
        on_open = proc(c: ^Client) {
            o := (^Client_Obs)(c.user_data)
            o.opened = true
            client_send_text(c, transmute([]byte)string("m0"))
            client_send_text(c, transmute([]byte)string("m1"))
            client_send_text(c, transmute([]byte)string("m2"))
            client_close(c)
        },
        on_message = obs_on_message,
        on_close = obs_on_close,
        on_error = obs_on_error,
    }

    c: Client
    cerr := client_connect(&c, loop, {host = "127.0.0.1", port = s.port, path = "/ws"}, callbacks, &obs)
    testing.expect_value(t, cerr, Client_Error.None)

    nbio.run_until(&obs.done)
    client_destroy(&c)

    testing.expect_value(t, obs.terminal_count, 1)

    thread.join(server)
    testing.expect_value(t, s.text_count, 3)
    testing.expect_value(t, string(s.texts[0].buf[:s.texts[0].len]), "m0")
    testing.expect_value(t, string(s.texts[1].buf[:s.texts[1].len]), "m1")
    testing.expect_value(t, string(s.texts[2].buf[:s.texts[2].len]), "m2")
}

// --- 12. Send after close begun ----------------------------------------------

// Server that upgrades then reads the client's close frame.
srv_await_close :: proc(s: ^Srv) {
    defer free_all(context.temp_allocator)

    listener, conn, ok := srv_accept(&s.port, &s.listening)
    if !ok {
        return
    }
    defer net.close(listener)
    defer net.close(conn)

    if !srv_upgrade(conn) {
        return
    }

    r := Srv_Frame_Reader {
        conn = conn,
    }
    srv_next_frame(&r)
    s.ok = true
}

// A send attempted after a close has begun returns .Not_Open rather than queueing.
@(test)
test_client_send_after_close :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    s := Srv{}
    server := thread.create_and_start_with_poly_data(&s, srv_await_close)
    defer {
        thread.join(server)
        thread.destroy(server)
    }

    if !testing.expect(t, srv_wait_listening(&s.listening), "server should listen") {
        return
    }

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    obs: Client_Obs

    callbacks := Callbacks {
        on_open = proc(c: ^Client) {
            o := (^Client_Obs)(c.user_data)
            o.opened = true
            client_close(c)
            o.send_after_close_err = client_send_text(c, transmute([]byte)string("x"))
        },
        on_message = obs_on_message,
        on_close = obs_on_close,
        on_error = obs_on_error,
    }

    c: Client
    cerr := client_connect(&c, loop, {host = "127.0.0.1", port = s.port, path = "/ws"}, callbacks, &obs)
    testing.expect_value(t, cerr, Client_Error.None)

    nbio.run_until(&obs.done)
    client_destroy(&c)

    testing.expect(t, obs.opened, "on_open should fire")
    testing.expect_value(t, obs.send_after_close_err, Client_Error.Not_Open)
    testing.expect_value(t, obs.terminal_count, 1)
}

@(test)
test_client_send_queue_and_message_limits_are_explicit :: proc(t: ^testing.T) {
    c := Client {
        allocator            = context.temp_allocator,
        state                = .Open,
        max_frame_bytes      = 16,
        max_send_queue_bytes = 16 + MAX_HEADER_BYTES,
        sending              = true,
    }
    c.send_queue = make([dynamic][]byte, context.temp_allocator)
    c.send_batch = make([dynamic][]byte, context.temp_allocator)

    first: [16]byte
    testing.expect_value(t, client_send_binary(&c, first[:]), Client_Error.None)
    testing.expect(t, c.pending_send_bytes > 0, "the first frame should be accounted")

    testing.expect_value(t, client_send_binary(&c, transmute([]byte)string("x")), Client_Error.Send_Queue_Full)

    too_large: [17]byte
    testing.expect_value(t, client_send_binary(&c, too_large[:]), Client_Error.Message_Too_Large)

    c.sending = false
    c.state = .Closed
    client_destroy(&c)
}

// `extra_headers` is spliced verbatim, so only complete CRLF-terminated `name: value`
// lines are accepted; anything else could inject a header, a body, or the terminator.
@(test)
test_client_extra_headers_validation :: proc(t: ^testing.T) {
    testing.expect(t, extra_headers_valid(""), "no extra headers is valid")
    testing.expect(t, extra_headers_valid("Authorization: Bearer tok\r\n"), "one complete line is valid")
    testing.expect(t, extra_headers_valid("a: 1\r\nb: 2\r\n"), "several complete lines are valid")

    testing.expect(t, !extra_headers_valid("Authorization: Bearer tok"), "an unterminated line is rejected")
    testing.expect(t, !extra_headers_valid("no-colon\r\n"), "a line without a colon is rejected")
    testing.expect(t, !extra_headers_valid(": 1\r\n"), "an empty header name is rejected")
    testing.expect(t, !extra_headers_valid("a: 1\n\r\n"), "a bare LF control byte is rejected")
    testing.expect(t, !extra_headers_valid("a: \x00\r\n"), "a NUL is rejected")
}

// A control byte or header-injection attempt in the options is refused before any
// I/O, so nothing malformed reaches the socket.
@(test)
test_client_rejects_injectable_options :: proc(t: ^testing.T) {
    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    c: Client
    err := client_connect(
        &c,
        loop,
        {host = "127.0.0.1", port = 1, path = "/ws", extra_headers = "Authorization: tok"},
        {},
    )
    testing.expect_value(t, err, Client_Error.Invalid_Options)
}
