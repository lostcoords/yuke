package daemon

import "core:crypto"
import "core:encoding/base64"
import "core:mem"
import "core:nbio"
import "core:net"
import "core:os"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

import http_server "libs:http/server"
import "libs:testsupport"
import ws "libs:websocket"
import "src:client"
import "src:daemon/store"
import "src:wire"

// --- Daemon driver tests ------------------------------------------------------
//
// These drive the EXISTING `src/client` driver against the new `daemon` on ONE
// shared `nbio.Event_Loop`, in-process, no worker threads — accept, upgrade, the
// initialize exchange, and request routing all interleave on a single loop. The
// protocol-error cases (malformed/oversequenced frames, wrong protocol version,
// binary frame, trailing bytes) need a peer the `src/client` driver cannot be —
// it only ever sends a well-formed `initialize` request — so those use a blocking raw
// TCP peer on a worker thread while the daemon drives the loop on the main thread,
// mirroring `libs/websocket/server_test.odin`.
//
// Helpers bind an OS-assigned ephemeral port (port 0); recover it with
// `bound_port` after `start`.

// Bring a daemon all the way down and reclaim it.
test_teardown :: proc(d: ^Daemon) {
    shutdown(d)
    for !shutdown_complete(d) {
        _ = nbio.tick(time.Millisecond)
    }
    destroy(d)
}

// Recover the ephemeral port the daemon's front door bound, for dialing clients.
bound_port :: proc(d: ^Daemon) -> int {
    return http_server.bound_port(&d.front_door)
}

// --- 1 & 2. Hello handshake + request-after-Ready via the real client driver ---

// Observations recorded by the `src/client` callbacks, reached through the driver's
// `user_data`.
Cli_Obs :: struct {
    // Whether to fire a request from `on_ready` (test 2) versus close (test 1).
    send_request_on_ready: bool,

    // Driver reached Ready.
    ready:                 bool,

    // Retained protocol version, read at Ready.
    protocol:              u32,

    // Retained session-index revision, read at Ready.
    session_revision:      wire.Session_Revision,

    // Retained cron-index revision, read at Ready.
    cron_revision:         wire.Cron_Revision,

    // A response frame was delivered.
    got_response:          bool,

    // The delivered response was an `error` frame.
    resp_is_error:         bool,

    // Error code carried by the delivered error response.
    resp_error_code:       wire.Error_Code,

    // Terminal callback fired.
    done:                  bool,

    // Close code reported to the terminal `on_close`.
    close_code:            client.Close_Code,

    // Terminal driver error, if any.
    err:                   client.Protocol_Error,
}

cli_on_ready :: proc(c: ^client.Client, hello: wire.Initialize_Result) {
    o := (^Cli_Obs)(c.user_data)
    o.ready = true
    o.protocol = hello.protocol
    o.session_revision = hello.session_revision
    o.cron_revision = hello.cron_revision

    if o.send_request_on_ready {
        // A method with no dispatch handler. The params are well-formed — a patch of
        // nothing against a well-formed id — so the request passes validation, reaches
        // the router, and falls through to the `Unknown_Method` arm.
        client.client_send_request(
            c,
            .Session_Patch,
            wire.Session_Patch_Params{session_id = pump_test_session('a')},
            cli_on_response,
        )
    } else {
        client.client_close(c)
    }
}

cli_on_response :: proc(c: ^client.Client, outcome: client.Request_Outcome, _: rawptr) {
    o := (^Cli_Obs)(c.user_data)
    answered, ok := outcome.(client.Request_Response)
    if !ok {
        o.err = outcome.(client.Request_Failure).error
        return
    }

    resp := answered.response
    o.got_response = true

    #partial switch v in resp {
    case wire.Response_Error:
        o.resp_is_error = true
        o.resp_error_code = v.error.code

    case wire.Response_Ok:
        o.resp_is_error = false
    }

    client.client_close(c)
}

cli_on_close :: proc(c: ^client.Client, code: client.Close_Code) {
    o := (^Cli_Obs)(c.user_data)
    o.close_code = code
    o.done = true
}

cli_on_error :: proc(c: ^client.Client, err: client.Protocol_Error) {
    o := (^Cli_Obs)(c.user_data)
    o.err = err
    o.done = true
}

cli_callbacks :: proc() -> client.Client_Callbacks {
    return client.Client_Callbacks{on_ready = cli_on_ready, on_close = cli_on_close, on_error = cli_on_error}
}

@(test)
test_daemon_hello_handshake_reaches_ready :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    d: Daemon
    derr := start(&d, loop, {host = "127.0.0.1", port = 0, daemon_version = "9.8.7"})
    testing.expect_value(t, derr, Error.None)

    obs: Cli_Obs
    c: client.Client
    transport, terr := client.ws_create(
        loop,
        {host = "127.0.0.1", port = bound_port(&d), path = "/ws"},
        context.temp_allocator,
    )
    testing.expect_value(t, terr, ws.Client_Error.None)

    cerr := client.client_open(&c, transport, "yuke-test", "0.1.0", cli_callbacks(), &obs, context.temp_allocator)
    testing.expect_value(t, cerr, client.Protocol_Error.None)

    nbio.run_until(&obs.done)

    testing.expect(t, obs.ready, "client should reach Ready")
    testing.expect_value(t, obs.protocol, u32(wire.PROTOCOL_VERSION))
    // The retained daemon version is the one the daemon was started with.
    testing.expect_value(t, c.daemon_version, "9.8.7")
    testing.expect_value(t, obs.session_revision, wire.Session_Revision(0))
    testing.expect_value(t, obs.cron_revision, wire.Cron_Revision(0))
    testing.expect_value(t, obs.err, client.Protocol_Error.None)

    client.client_destroy(&c)
    test_teardown(&d)
}

@(test)
test_daemon_request_after_ready_gets_error :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    d: Daemon
    derr := start(&d, loop, {host = "127.0.0.1", port = 0})
    testing.expect_value(t, derr, Error.None)

    obs := Cli_Obs {
        send_request_on_ready = true,
    }
    c: client.Client
    transport, terr := client.ws_create(
        loop,
        {host = "127.0.0.1", port = bound_port(&d), path = "/ws"},
        context.temp_allocator,
    )
    testing.expect_value(t, terr, ws.Client_Error.None)

    cerr := client.client_open(&c, transport, "yuke-test", "0.1.0", cli_callbacks(), &obs, context.temp_allocator)
    testing.expect_value(t, cerr, client.Protocol_Error.None)

    nbio.run_until(&obs.done)

    testing.expect(t, obs.ready, "client should reach Ready")
    testing.expect(t, obs.got_response, "a request after Ready must be answered, not dropped")
    testing.expect(t, obs.resp_is_error, "the answer must be an error response")
    // `session.patch` is a valid method the router does not handle, so it answers
    // with `Unknown_Method` rather than dropping the request.
    testing.expect_value(t, obs.resp_error_code, wire.Error_Code.Unknown_Method)
    testing.expect_value(t, obs.err, client.Protocol_Error.None)

    client.client_destroy(&c)
    test_teardown(&d)
}

// --- Read-only method handlers via the real client driver ---------------------
//
// Each drives one request from `on_ready`, then runs a per-test `check` against the
// delivered response while it is still alive — the driver reclaims its decode arena
// when the callback returns, so every assertion happens inside the callback. A check
// returns whether the exchange is finished; a paginated case sends a follow-up and
// returns false so the loop keeps running.

// Per-test observation and context reached through the driver's `user_data`.
Handler_Obs :: struct {
    // Method the request drives.
    method:     wire.Method_Name,

    // Params for that request.
    params:     wire.Request_Params,

    // Assertions run against each delivered response; returns true when finished.
    check:      proc(c: ^client.Client, resp: wire.Response, o: ^Handler_Obs) -> bool,

    // A filesystem path the test set up, read by describe/browse checks.
    dir:        string,

    // Response counter, for multi-page exchanges.
    page:       int,

    // The active testing context, so checks can assert from inside the callback.
    t:          ^testing.T,

    // Terminal callback fired.
    done:       bool,

    // The check declared the exchange complete and initiated the client close.
    finished:   bool,

    // Either a terminal callback or the harness timeout fired.
    wait_done:  bool,

    // The harness timeout fired before a terminal callback.
    timed_out:  bool,

    // At least one response was delivered to `handler_on_response`. Without this, a
    // daemon that closes the connection instead of answering would still leave
    // `done` set (by `handler_on_close`) and no `check` ever runs, so the test would
    // vacuously pass.
    responded:  bool,

    // Terminal driver error, if any.
    err:        client.Protocol_Error,

    // Multi-request auth test state.
    auth_stage: int,

    // Running daemon, exposed only while `run_handler` owns it.
    daemon:     ^Daemon,
}

handler_on_ready :: proc(c: ^client.Client, _: wire.Initialize_Result) {
    o := (^Handler_Obs)(c.user_data)
    client.client_send_request(c, o.method, o.params, handler_on_response)
}

handler_on_response :: proc(c: ^client.Client, outcome: client.Request_Outcome, _: rawptr) {
    o := (^Handler_Obs)(c.user_data)
    answered, ok := outcome.(client.Request_Response)
    if !ok {
        o.err = outcome.(client.Request_Failure).error
        return
    }

    resp := answered.response
    o.responded = true

    // `done` is latched by the terminal callback, not here: destroying a client with
    // its close frame still in flight would free buffers the loop still owns.
    if o.check(c, resp, o) {
        o.finished = true
        client.client_close(c)
    }
}

handler_on_close :: proc(c: ^client.Client, code: client.Close_Code) {
    o := (^Handler_Obs)(c.user_data)
    o.done = true
    o.wait_done = true
}

handler_on_error :: proc(c: ^client.Client, err: client.Protocol_Error) {
    o := (^Handler_Obs)(c.user_data)
    o.err = err
    o.done = true
    o.wait_done = true
}

handler_on_timeout :: proc(_: ^nbio.Operation, o: ^Handler_Obs) {
    o.timed_out = true
    o.wait_done = true
}

handler_callbacks :: proc() -> client.Client_Callbacks {
    return client.Client_Callbacks {
        on_ready = handler_on_ready,
        on_close = handler_on_close,
        on_error = handler_on_error,
    }
}

// Bring up a daemon, drive `obs`'s single request through the client driver, and run its
// check(s). `db_path` selects a file store; an empty path uses the in-memory store.
run_handler :: proc(t: ^testing.T, obs: ^Handler_Obs, db_path := "", sessions: ..wire.Session) {
    obs.t = t

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    d: Daemon
    derr := start(&d, loop, {host = "127.0.0.1", port = 0, db_path = db_path})
    testing.expect_value(t, derr, Error.None)
    obs.daemon = &d

    for session in sessions {
        _, create_err := store.session_create(d.store, daemon_test_workspace(), session, nil)
        testing.expect_value(t, create_err, nil)
    }

    c: client.Client
    transport, terr := client.ws_create(
        loop,
        {host = "127.0.0.1", port = bound_port(&d), path = "/ws"},
        context.temp_allocator,
    )
    testing.expect_value(t, terr, ws.Client_Error.None)

    cerr := client.client_open(&c, transport, "yuke-test", "0.1.0", handler_callbacks(), obs, context.temp_allocator)
    testing.expect_value(t, cerr, client.Protocol_Error.None)

    timeout_op := nbio.timeout_poly(2 * time.Second, obs, handler_on_timeout, loop)
    nbio.run_until(&obs.wait_done)

    if !obs.timed_out {
        nbio.remove(timeout_op)
    } else {
        // Force a terminal callback before destroying the client; the timeout only
        // bounds the request exchange, not the transport's buffer lifetime.
        shutdown(&d)
        nbio.run_until(&obs.done)
    }

    // A daemon that closes or errors the connection instead of answering must not
    // pass silently: without a delivered response, `check` (and every expectation it
    // holds) never ran.
    testing.expect(t, !obs.timed_out, "the daemon request should terminate before the harness timeout")
    testing.expect(t, obs.done, "the client terminal callback should fire")
    testing.expect(t, obs.responded, "the daemon should have answered the request")
    testing.expect(t, obs.finished, "the response check should run to completion")
    testing.expect_value(t, obs.err, client.Protocol_Error.None)

    client.client_destroy(&c)
    test_teardown(&d)
}

// Create a fresh, empty directory under the temp root, removing any stale copy first.
test_make_dir :: proc(name: string) -> string {
    base, has := os.lookup_env("TMPDIR", context.temp_allocator)
    if !has {
        base = "/tmp"
    }

    dir, _ := os.join_path({base, name}, context.temp_allocator)
    os.remove_all(dir)
    os.make_directory_all(dir)

    return dir
}

// --- Raw blocking TCP peer harness (worker thread) ----------------------------

// A raw peer that upgrades, sends one hand-built frame, then reads back the
// server's reaction (a Close frame with its code, or a bare socket close).
Raw_Peer :: struct {
    // Port to connect to.
    port:          int,

    // Opcode of the single frame the peer sends after upgrading.
    opcode:        ws.Op_Code,

    // Payload of that frame (borrowed static bytes; read-only across the thread).
    payload:       []byte,

    // The peer ran its script to completion.
    ok:            bool,

    // The server closed the TCP connection.
    server_closed: bool,

    // The server sent a WebSocket Close frame before closing.
    got_close:     bool,

    // Close code carried by that Close frame.
    close_code:    u16,
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

    return sock, true
}

// Perform the client half of the WebSocket upgrade and validate the 101.
raw_upgrade :: proc(sock: net.TCP_Socket) -> bool {
    key_raw: [ws.SEC_WEBSOCKET_KEY_BYTES]byte
    crypto.rand_bytes(key_raw[:])
    key_encoded: [ws.SEC_WEBSOCKET_KEY_ENCODED_BYTES]byte
    base64.encode_into_buf(key_encoded[:], key_raw[:])

    request := ws.build_upgrade_request("/ws", "127.0.0.1", key_encoded[:], "", context.temp_allocator)
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
        result, _, status := ws.parse_upgrade_response(buf[:n], key_encoded[:])
        if status == .Ready {
            return result == .Ok
        }
    }

    return false
}

// Upgrade, send the configured (masked, as a real client) frame, then read back the
// server's Close frame or observe the socket close.
raw_peer :: proc(p: ^Raw_Peer) {
    defer free_all(context.temp_allocator)

    sock, ok := raw_dial(p.port)
    if !ok {
        return
    }
    defer net.close(sock)

    if !raw_upgrade(sock) {
        return
    }

    key: [ws.MASK_KEY_BYTES]byte
    crypto.rand_bytes(key[:])
    frame := ws.encode_frame(true, p.opcode, p.payload, key, context.temp_allocator)
    if _, serr := net.send_tcp(sock, frame); serr != nil {
        return
    }

    // Read with a client-role decoder (rejects masking, which a server never applies).
    dec: ws.Decoder
    ws.decoder_init(&dec, 1 << 20, 1 << 20, .Client, context.temp_allocator)
    defer ws.decoder_destroy(&dec)

    buf: [4096]byte
    for {
        msg, has, derr := ws.decoder_next(&dec, context.temp_allocator)
        if derr != .None {
            break
        }

        if has {
            if msg.kind == .Close {
                parsed, _ := ws.parse_close(msg.data)
                p.got_close = true
                p.close_code = u16(parsed.code)
                break
            }

            continue
        }

        got, rerr := net.recv_tcp(sock, buf[:])
        if rerr != nil || got == 0 {
            p.server_closed = true
            break
        }

        ws.decoder_feed(&dec, buf[:got])
    }

    p.ok = true
}

// Drive the loop while `peer` runs its blocking script, then assert the observed
// close. Shared by the protocol-error cases; each supplies a peer and the expected
// close code. Binds an OS-assigned ephemeral port.
run_raw :: proc(t: ^testing.T, opcode: ws.Op_Code, payload: string, expect_code: u16) {
    defer free_all(context.temp_allocator)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    d: Daemon
    derr := start(&d, loop, {host = "127.0.0.1", port = 0})
    testing.expect_value(t, derr, Error.None)

    p := Raw_Peer {
        port    = bound_port(&d),
        opcode  = opcode,
        payload = transmute([]byte)payload,
    }
    peer := thread.create_and_start_with_poly_data(&p, raw_peer)
    defer {
        thread.join(peer)
        thread.destroy(peer)
    }

    for _ in 0 ..< 2000 {
        nbio.tick(time.Millisecond)
        if sync.atomic_load(&p.ok) && len(d.ws_server.conns) == 0 {
            break
        }
    }

    thread.join(peer)

    testing.expect(t, p.got_close, "server should send a Close frame")
    testing.expect_value(t, p.close_code, expect_code)

    test_teardown(&d)
}

@(test)
test_daemon_malformed_first_frame_closes :: proc(t: ^testing.T) {
    // A text frame that is not a valid `initialize` request (invalid JSON) is a protocol error.
    run_raw(t, .Text, "not json at all", wire.CLOSE.protocol_error)
}

@(test)
test_daemon_wrong_protocol_closes :: proc(t: ^testing.T) {
    // A well-formed `initialize` request with an unsupported protocol closes with the
    // dedicated code.
    hello := `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocol":2,"client":{"name":"x","version":"y"}}}`
    run_raw(t, .Text, hello, wire.CLOSE.unsupported_protocol)
}

@(test)
test_daemon_non_initialize_first_frame_closes :: proc(t: ^testing.T) {
    // The other half of the state-machine XOR: a well-formed request for a method
    // other than `initialize` is refused as a protocol error when sent first.
    req := `{"jsonrpc":"2.0","id":1,"method":"session.list","params":{}}`
    run_raw(t, .Text, req, wire.CLOSE.protocol_error)
}

@(test)
test_daemon_binary_frame_closes :: proc(t: ^testing.T) {
    // The v1 protocol carries only text frames; a binary frame is a protocol error
    // regardless of content.
    hello := `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocol":1,"client":{"name":"x","version":"y"}}}`
    run_raw(t, .Binary, hello, wire.CLOSE.protocol_error)
}

@(test)
test_daemon_trailing_bytes_closes :: proc(t: ^testing.T) {
    // One JSON value per frame: a valid `initialize` request followed by a trailing
    // token is rejected by `dec_finish` before it takes effect.
    hello := `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocol":1,"client":{"name":"x","version":"y"}}} 5`
    run_raw(t, .Text, hello, wire.CLOSE.protocol_error)
}

// `initialize` is the only method accepted before Ready, and the only one refused
// after it: a second `initialize` once Ready is a protocol error.
@(test)
test_daemon_second_initialize_after_ready_closes :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    d: Daemon
    derr := start(&d, loop, {host = "127.0.0.1", port = 0})
    testing.expect_value(t, derr, Error.None)

    second := `{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocol":1,"client":{"name":"x","version":"y"}}}`

    p := Sub_Peer {
        port  = bound_port(&d),
        frame = second,
    }
    peer := thread.create_and_start_with_poly_data(&p, sub_peer)
    defer {
        thread.join(peer)
        thread.destroy(peer)
    }

    for _ in 0 ..< 2000 {
        nbio.tick(time.Millisecond)
        if sync.atomic_load(&p.ok) && len(d.ws_server.conns) == 0 {
            break
        }
    }

    thread.join(peer)

    testing.expect(t, p.got_close, "a second initialize after Ready should close the connection")
    testing.expect_value(t, p.close_code, wire.CLOSE.protocol_error)

    test_teardown(&d)
}

// A response the emitter could not finish is protocol damage, not a smaller response:
// the peer would read a partial JSON value and lose framing for good. `send_response`
// aborts the connection rather than shipping the prefix.
@(test)
test_daemon_truncated_response_aborts_the_connection :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    d: Daemon
    derr := start(&d, loop, {host = "127.0.0.1", port = 0})
    testing.expect_value(t, derr, Error.None)

    obs: Pump_Obs
    pump_obs_init(&obs, nil)
    c: client.Client
    pump_client_arm(t, &c, loop, bound_port(&d), &obs)

    conn: ^Conn
    for _, live in d.conns {
        conn = live
    }

    testing.expect(t, conn != nil, "the armed client has a daemon-side connection")

    // The refused encode is logged as an error, which the runner would otherwise count
    // as a test failure; the assertions below are the check.
    saved_logger := context.logger
    quiet_logger: testsupport.Assert_Only_Logger
    context.logger = testsupport.assert_only_logger(&quiet_logger, saved_logger)
    defer context.logger = saved_logger

    // Smaller than the shortest response text, so the encode latches its truncation.
    backing: [16]byte
    arena: mem.Arena
    mem.arena_init(&arena, backing[:])

    send_result(conn, wire.Request_Id("1"), wire.Empty{}, mem.arena_allocator(&arena))

    testing.expect_value(t, conn.state, Protocol_State.Closed)
    testing.expect(t, pump_tick_until(&obs.done), "the aborted connection should terminate the client")
    testing.expect_value(t, len(obs.names), 0)

    client.client_destroy(&c)
    test_teardown(&d)
}

// --- Lifecycle soak under a tracking allocator (leak hunt) --------------------

// Repeated connect -> initialize -> Ready -> close cycles must leave zero leaked
// allocations and zero bad frees: the daemon's per-connection lifecycle (accept,
// allocate `Conn`, open, initialize, retain identity, close, release) frees everything
// it allocates on every cycle, mirroring the WebSocket package's soak rigor.
@(test)
test_daemon_lifecycle_no_leak :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    track: mem.Tracking_Allocator
    mem.tracking_allocator_init(&track, context.allocator)
    defer mem.tracking_allocator_destroy(&track)
    tracked := mem.tracking_allocator(&track)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    d: Daemon
    derr := start(&d, loop, {host = "127.0.0.1", port = 0, daemon_version = "1.0.0"}, tracked)
    testing.expect_value(t, derr, Error.None)

    port := bound_port(&d)
    ITERATIONS :: 32

    for i in 0 ..< ITERATIONS {
        obs: Cli_Obs
        c: client.Client
        transport, terr := client.ws_create(loop, {host = "127.0.0.1", port = port, path = "/ws"}, tracked)
        testing.expect_value(t, terr, ws.Client_Error.None)

        cerr := client.client_open(&c, transport, "yuke-test", "0.1.0", cli_callbacks(), &obs, tracked)
        testing.expect_value(t, cerr, client.Protocol_Error.None)

        nbio.run_until(&obs.done)
        client.client_destroy(&c)

        // Drain the daemon-side connection's deferred teardown before the next cycle
        // so releases interleave with fresh accepts, not batch at the end.
        for _ in 0 ..< 64 {
            if len(d.ws_server.conns) == 0 {
                break
            }

            nbio.tick(time.Millisecond)
        }

        testing.expectf(t, obs.ready, "cycle %d should reach Ready", i)
    }

    test_teardown(&d)

    testing.expectf(t, len(track.allocation_map) == 0, "expected zero leaks, got %d", len(track.allocation_map))
    testing.expectf(t, len(track.bad_free_array) == 0, "expected zero bad frees, got %d", len(track.bad_free_array))
}
