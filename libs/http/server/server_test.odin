package http_server

import "core:log"
import "core:nbio"
import "core:net"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import ts "libs:testsupport"

// --- Front door tests ---------------------------------------------------------
//
// The peer is a blocking `core:net` client on a worker thread while the server
// drives the loop on the main thread, mirroring `libs/websocket/server_test.odin`.
// Each exchange binds an OS-assigned ephemeral port (port 0).

// What the handler under test should do, plus what it observed.
Obs :: struct {
    // Hijack the socket instead of responding.
    hijack:        bool,

    // Shut the front door down from inside the request callback after answering.
    shutdown:      bool,

    // Number of `on_request` calls.
    request_count: int,

    // Method and target of the most recent request.
    method:        string,
    target:        string,

    // Bytes the handler saw past the head.
    body_len:      int,

    // Head-consumed byte count and raw trailing bytes, for split-terminator checks.
    consumed:      int,
    trailing:      string,

    // Stream the request body via `receive_body` instead of responding immediately.
    receive_body:  bool,

    // Reject the first body chunk from the sink, exercising the abort path.
    abort_body:    bool,

    // Body bytes the sink accumulated, and how many.
    body_buf:      [256]byte,
    body_got:      int,

    // The end callback fired, and with which outcome.
    body_ended:    bool,
    body_ok:       bool,
}

// Bytes a hijacking handler writes straight onto the taken-over socket.
HIJACKED :: "hijacked"

obs_of :: proc(c: ^Conn) -> ^Obs {
    return (^Obs)(c.server.user_data)
}

// Handler under test: answer 200 with a static body, or take the socket over.
test_on_request :: proc(c: ^Conn, req: Request) {
    o := obs_of(c)
    o.request_count += 1
    o.method = strings.clone(req.head.method, context.temp_allocator)
    o.target = strings.clone(req.head.target, context.temp_allocator)
    o.body_len = len(req.trailing)
    o.consumed = req.head.consumed
    o.trailing = strings.clone(string(req.trailing), context.temp_allocator)

    if o.receive_body {
        receive_body(c, o, test_body_chunk, test_body_end)
        return
    }

    if !o.hijack {
        respond_text(c, .Ok, "hello")

        if o.shutdown {
            shutdown(c.server)
        }

        return
    }

    test_hijack_and_greet(c)

    if o.shutdown {
        shutdown(c.server)
    }
}

// Take the socket over and write `HIJACKED` straight onto it.
test_hijack_and_greet :: proc(c: ^Conn) {
    socket, loop := hijack(c)
    nbio.send_poly(
        socket,
        [][]byte{transmute([]byte)string(HIJACKED)},
        socket,
        proc(op: ^nbio.Operation, socket: net.TCP_Socket) {
            nbio.close(socket)
        },
        {},
        true,
        nbio.NO_TIMEOUT,
        loop,
    )
}

// Body sink under test: accumulate the chunk, or reject it to drive the abort path.
test_body_chunk :: proc(c: ^Conn, user_data: rawptr, chunk: []byte) -> bool {
    o := (^Obs)(user_data)
    if o.abort_body {
        return false
    }

    o.body_got += copy(o.body_buf[o.body_got:], chunk)

    return true
}

// Body completion under test: on success echo the accumulated body back as 200.
test_body_end :: proc(c: ^Conn, user_data: rawptr, ok: bool) {
    o := (^Obs)(user_data)
    o.body_ended = true
    o.body_ok = ok

    if ok {
        respond_text(c, .Ok, string(o.body_buf[:o.body_got]))
    }
}

// A blocking peer: send `request`, read until the server closes.
Peer :: struct {
    port:     int,
    request:  string,

    // Byte offset to split `request` across two sends; 0 sends it whole.
    split_at: int,
    response: [4096]byte,
    length:   int,
    ok:       bool,
}

peer_run :: proc(p: ^Peer) {
    sock, derr := net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = p.port})
    if derr != nil {
        return
    }
    defer net.close(sock)

    // Bound thread cleanup even if the server and its shutdown path both fail.
    if net.set_option(sock, .Receive_Timeout, ts.NBIO_WAIT_DEADLINE + time.Second) != nil {
        return
    }

    first := p.request
    second := ""
    if p.split_at > 0 {
        first = p.request[:p.split_at]
        second = p.request[p.split_at:]
    }

    if _, serr := net.send_tcp(sock, transmute([]byte)first); serr != nil {
        return
    }

    if len(second) > 0 {
        // Give the server time to recv and rescan the first chunk before the rest
        // of the terminator arrives, so the two chunks land as separate recvs.
        time.sleep(50 * time.Millisecond)
        if _, serr := net.send_tcp(sock, transmute([]byte)second); serr != nil {
            return
        }
    }

    for p.length < len(p.response) {
        n, rerr := net.recv_tcp(sock, p.response[p.length:])
        if rerr != nil || n == 0 {
            break
        }

        p.length += n
    }

    sync.atomic_store(&p.ok, true)
}

server_empty :: proc(s: ^Server) -> bool {
    return len(s.conns) == 0
}

// Serve one request from a worker-thread peer and return what it read back.
// Binds an OS-assigned ephemeral port; the peer dials whatever `listen` got.
run_exchange :: proc(t: ^testing.T, request: string, obs: ^Obs, options: Options = {}, split_at := 0) -> string {
    return run_exchange_with(t, request, test_on_request, obs, options, split_at)
}

// Serve one request against a `Router` and return the peer's response bytes.
run_router_exchange :: proc(t: ^testing.T, request: string, router: ^Router, split_at := 0) -> string {
    router_validate(router)

    return run_exchange_with(t, request, router_on_request, router, {}, split_at)
}

// The shared choreography: bind, run a blocking peer on a worker thread, drain the
// connection, then shut down. `on_request` and `user_data` are what differ per caller.
run_exchange_with :: proc(
    t: ^testing.T,
    request: string,
    on_request: On_Request,
    user_data: rawptr,
    options: Options = {},
    split_at := 0,
) -> string {
    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    opts := options
    opts.host = "127.0.0.1"
    opts.port = 0

    s: Server
    testing.expect_value(t, listen(&s, loop, opts, on_request, user_data), Error.None)

    p := Peer {
        port     = bound_port(&s),
        request  = request,
        split_at = split_at,
    }
    peer := thread.create_and_start_with_poly_data(&p, peer_run)
    defer {
        thread.join(peer)
        thread.destroy(peer)
    }

    if !ts.nbio_run_until(t, peer, thread.is_done, "HTTP peer completion") {
        shutdown(&s)
        ts.nbio_run_until(t, &s.shutdown_complete, "HTTP server shutdown after peer timeout")
        thread.join(peer)
        return ""
    }

    thread.join(peer)

    if !ts.nbio_run_until(t, &s, server_empty, "HTTP connection teardown") {
        shutdown(&s)
        ts.nbio_run_until(t, &s.shutdown_complete, "HTTP server shutdown after connection timeout")
        return ""
    }

    shutdown(&s)

    if !ts.nbio_run_until(t, &s.shutdown_complete, "HTTP server shutdown") {
        return ""
    }

    destroy(&s)

    return strings.clone(string(p.response[:p.length]), context.temp_allocator)
}

@(test)
test_http_responds_to_a_get :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    obs: Obs
    got := run_exchange(t, "GET /thing?x=1 HTTP/1.1\r\nhost: 127.0.0.1\r\n\r\n", &obs)

    testing.expect_value(t, obs.request_count, 1)
    testing.expect_value(t, obs.method, "GET")
    testing.expect_value(t, obs.target, "/thing?x=1")
    testing.expect_value(t, obs.body_len, 0)
    testing.expect(t, strings.has_prefix(got, "HTTP/1.1 200 OK\r\n"), "should answer 200")
    testing.expect(t, strings.contains(got, "Content-Length: 5\r\n"), "should length the body")
    testing.expect(t, strings.contains(got, "Connection: close\r\n"), "should close after the response")
    testing.expect(t, strings.has_suffix(got, "hello"), "should carry the body")
}

@(test)
test_http_receives_a_bounded_body :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    request := "PUT /up HTTP/1.1\r\nhost: 127.0.0.1\r\ncontent-length: 11\r\n\r\nhello world"

    obs := Obs {
        receive_body = true,
    }
    got := run_exchange(t, request, &obs)

    testing.expect_value(t, obs.request_count, 1)
    testing.expect(t, obs.body_ended && obs.body_ok, "the body should complete")
    testing.expect_value(t, obs.body_got, 11)
    testing.expect(t, strings.has_prefix(got, "HTTP/1.1 200 OK\r\n"), "should answer 200 after the body")
    testing.expect(t, strings.has_suffix(got, "hello world"), "should echo the received body")

    // Same body split so it lands across the head recv and a later body recv.
    split := Obs {
        receive_body = true,
    }
    run_exchange(t, request, &split, split_at = strings.index(request, "\r\n\r\n") + 6)

    testing.expect(t, split.body_ended && split.body_ok, "a split body should still complete")
    testing.expect_value(t, split.body_got, 11)
}

@(test)
test_http_body_sink_abort_finalizes :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    obs := Obs {
        receive_body = true,
        abort_body   = true,
    }
    got := run_exchange(t, "PUT /up HTTP/1.1\r\nhost: 127.0.0.1\r\ncontent-length: 11\r\n\r\nhello world", &obs)

    testing.expect(t, obs.body_ended && !obs.body_ok, "a sink abort should end the body with ok=false")
    testing.expect_value(t, len(got), 0)
}

// Accumulates emitted log text so a test can assert what never reaches a sink.
capture_log :: proc(data: rawptr, level: log.Level, text: string, options: log.Options, location := #caller_location) {
    into := (^strings.Builder)(data)
    strings.write_string(into, text)
    strings.write_byte(into, '\n')
}

// A `?token=` credential in the target must not survive into a log (RFC 6750 §5.3).
@(test)
test_http_request_log_omits_the_query :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    // Heap-backed: `run_exchange` allocates from the temp allocator, which would
    // alias and clobber the capture buffer.
    capture: strings.Builder
    strings.builder_init(&capture, context.allocator)
    defer strings.builder_destroy(&capture)

    // Restored before asserting: the test runner reports failures through
    // `context.logger`, so asserting while it is captured would swallow them.
    restore := context.logger
    context.logger = log.Logger{capture_log, &capture, .Debug, {}}

    obs: Obs
    run_exchange(t, "GET /thing?token=s3cret HTTP/1.1\r\nhost: 127.0.0.1\r\n\r\n", &obs)

    context.logger = restore

    logged := strings.to_string(capture)
    testing.expect(t, strings.contains(logged, "request GET /thing"), "the request should still be logged")
    testing.expectf(t, !strings.contains(logged, "s3cret"), "a query credential reached a log: %q", logged)
}

// A stalled transfer must not hold its connection slot. `request_timeout` is set past
// the harness deadline so only the absolute body deadline can end this.
@(test)
test_http_body_transfer_deadline_finalizes :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    obs := Obs {
        receive_body = true,
    }
    got := run_exchange(
        t,
        "PUT /up HTTP/1.1\r\nhost: 127.0.0.1\r\ncontent-length: 11\r\n\r\nhello",
        &obs,
        {request_timeout = 60 * time.Second, body_timeout = 20 * time.Millisecond},
    )

    testing.expect(t, obs.body_ended && !obs.body_ok, "a stalled body should end with ok=false")
    testing.expect_value(t, obs.body_got, 5)
    testing.expect_value(t, len(got), 0)
}

// RFC 9110 §9.3.2: a HEAD response carries the headers it would have sent for GET,
// including `Content-Length`, but no content.
@(test)
test_http_head_response_has_no_content :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    obs: Obs
    got := run_exchange(t, "HEAD /thing HTTP/1.1\r\nhost: 127.0.0.1\r\n\r\n", &obs)

    testing.expect(t, strings.has_prefix(got, "HTTP/1.1 200 OK\r\n"), "should answer 200")
    testing.expectf(t, strings.contains(got, "Content-Length: 5\r\n"), "should still length the body, got %q", got)
    testing.expectf(t, strings.has_suffix(got, "\r\n\r\n"), "should send no content, got %q", got)
}

@(test)
test_http_rejects_a_malformed_request_line :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    obs: Obs
    got := run_exchange(t, "BOGUS\r\nhost: 127.0.0.1\r\n\r\n", &obs)

    testing.expect_value(t, obs.request_count, 0)
    testing.expect(t, strings.has_prefix(got, "HTTP/1.1 400 Bad Request\r\n"), "should answer 400")
}

@(test)
test_http_rejects_an_oversized_head :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    // A header block that never terminates, past the configured ceiling.
    b := strings.builder_make(context.temp_allocator)
    strings.write_string(&b, "GET / HTTP/1.1\r\n")
    for _ in 0 ..< 64 {
        strings.write_string(&b, "x-pad: 0123456789012345678901234567890123456789\r\n")
    }

    obs: Obs
    got := run_exchange(t, strings.to_string(b), &obs, {max_head_bytes = 512})

    testing.expect_value(t, obs.request_count, 0)
    testing.expect(t, strings.has_prefix(got, "HTTP/1.1 431 Request Header Fields Too Large\r\n"), "should answer 431")
}

@(test)
test_http_hijack_hands_over_the_socket :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    obs := Obs {
        hijack = true,
    }
    // The pipelined byte behind the terminator must reach the handler, as a
    // WebSocket client's eager first frame does.
    got := run_exchange(t, "GET /ws HTTP/1.1\r\nhost: 127.0.0.1\r\n\r\n!", &obs)

    testing.expect_value(t, obs.request_count, 1)
    testing.expect_value(t, obs.body_len, 1)
    testing.expect_value(t, got, HIJACKED)
}

@(test)
test_http_shutdown_from_responding_handler :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    obs := Obs {
        shutdown = true,
    }
    run_exchange(t, "GET /stop HTTP/1.1\r\nhost: 127.0.0.1\r\n\r\n", &obs)

    testing.expect_value(t, obs.request_count, 1)
}

@(test)
test_http_shutdown_from_hijacking_handler :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    obs := Obs {
        hijack   = true,
        shutdown = true,
    }
    got := run_exchange(t, "GET /stop HTTP/1.1\r\nhost: 127.0.0.1\r\n\r\n", &obs)

    testing.expect_value(t, obs.request_count, 1)
    testing.expect_value(t, got, HIJACKED)
}

@(test)
test_http_head_terminator_split_across_recv :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    request := "GET /a?x=1 HTTP/1.1\r\nhost: 127.0.0.1\r\n\r\n!ab"
    term := strings.index(request, "\r\n\r\n")

    baseline: Obs
    run_exchange(t, request, &baseline)

    // Split inside the preceding header line, then with 1, 2, and 3 bytes of the
    // "\r\n\r\n" terminator landing in the earlier chunk.
    for split_at in ([]int{term - 4, term + 1, term + 2, term + 3}) {
        obs: Obs
        run_exchange(t, request, &obs, split_at = split_at)

        testing.expect_value(t, obs.request_count, baseline.request_count)
        testing.expect_value(t, obs.method, baseline.method)
        testing.expect_value(t, obs.target, baseline.target)
        testing.expect_value(t, obs.consumed, baseline.consumed)
        testing.expect_value(t, obs.trailing, baseline.trailing)
    }
}

// --- Router tests -------------------------------------------------------------

// Fixture state for router middleware and handlers under test.
Router_Obs :: struct {
    // How many times the counting middleware ran.
    middleware_hits:  int,

    // How many times a second middleware ran (proves ordering / short-circuit).
    middleware2_hits: int,

    // How many times a route handler ran.
    handler_hits:     int,

    // Last `params.path_rest` seen by a handler.
    last_rest:        string,

    // Last `allow` value the 405 fallback received.
    allow:            string,

    // `params.path` and `params.query` the first middleware saw.
    mw_path:          string,
    mw_query:         string,

    // Body bytes and completion seen by the `.Receive_Body` middleware.
    mw_body_got:      int,
    mw_body_ended:    bool,

    // How the first middleware takes over the connection, if at all.
    stop_mode:        Router_Stop_Mode,
}

// The ways a middleware can legally answer and return `.Stop`.
Router_Stop_Mode :: enum {
    None,
    Respond,
    Hijack,
    Receive_Body,
}

router_mw_count :: proc(c: ^Conn, req: Request, user_data: rawptr) -> Middleware_Result {
    o := (^Router_Obs)(user_data)
    o.middleware_hits += 1
    o.mw_path = strings.clone(req.path, context.temp_allocator)
    o.mw_query = strings.clone(req.query, context.temp_allocator)

    switch o.stop_mode {
    case .None:

    case .Respond:
        respond_text(c, .Unauthorized, "unauthorized")
        return .Stop

    case .Hijack:
        test_hijack_and_greet(c)
        return .Stop

    case .Receive_Body:
        receive_body(c, o, router_mw_body_chunk, router_mw_body_end)
        return .Stop
    }

    return .Continue
}

// Body sink for the `.Receive_Body` middleware: accumulate, then answer from the end
// callback so the connection is still owned when the router's `.Stop` assert runs.
router_mw_body_chunk :: proc(c: ^Conn, user_data: rawptr, chunk: []byte) -> bool {
    o := (^Router_Obs)(user_data)
    o.mw_body_got += len(chunk)

    return true
}

router_mw_body_end :: proc(c: ^Conn, user_data: rawptr, ok: bool) {
    o := (^Router_Obs)(user_data)
    o.mw_body_ended = true

    if ok {
        respond_text(c, .Ok, "mw-body")
    }
}

router_mw_count2 :: proc(c: ^Conn, req: Request, user_data: rawptr) -> Middleware_Result {
    o := (^Router_Obs)(user_data)
    o.middleware2_hits += 1
    return .Continue
}

router_handle_ok :: proc(c: ^Conn, req: Request, params: Params, user_data: rawptr) {
    o := (^Router_Obs)(user_data)
    o.handler_hits += 1
    o.last_rest = strings.clone(params.path_rest, context.temp_allocator)
    respond_text(c, .Ok, "routed")
}

@(test)
test_match_route_path_exact_and_prefix :: proc(t: ^testing.T) {
    rest, ok := match_route_path("/ws", "/ws")
    testing.expect(t, ok)
    testing.expect_value(t, rest, "")

    _, no := match_route_path("/ws", "/ws/extra")
    testing.expect(t, !no)

    rest, ok = match_route_path("/blob/*", "/blob/abc")
    testing.expect(t, ok)
    testing.expect_value(t, rest, "abc")

    rest, ok = match_route_path("/blob/*", "/blob/")
    testing.expect(t, ok)
    testing.expect_value(t, rest, "")

    _, no = match_route_path("/blob/*", "/blob")
    testing.expect(t, !no)

    _, no = match_route_path("/blob/*", "/other/abc")
    testing.expect(t, !no)
}

@(test)
test_router_dispatches_and_captures :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    obs: Router_Obs
    middleware := [?]Middleware{router_mw_count}
    routes := [?]Route{{method = "GET", pattern = "/blob/*", handler = router_handle_ok}}
    router := Router {
        middleware = middleware[:],
        routes     = routes[:],
        user_data  = &obs,
    }

    got := run_router_exchange(t, "GET /blob/deadbeef HTTP/1.1\r\nhost: 127.0.0.1\r\n\r\n", &router)

    testing.expect_value(t, obs.middleware_hits, 1)
    testing.expect_value(t, obs.handler_hits, 1)
    testing.expect_value(t, obs.last_rest, "deadbeef")
    testing.expect(t, strings.has_prefix(got, "HTTP/1.1 200 OK\r\n"), "matched route should 200")
    testing.expect(t, strings.has_suffix(got, "routed"), "handler body should reach the peer")
}

@(test)
test_router_middleware_runs_before_match_and_can_stop :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    obs := Router_Obs {
        stop_mode = .Respond,
    }
    middleware := [?]Middleware{router_mw_count, router_mw_count2}
    routes := [?]Route{{method = "GET", pattern = "/ws", handler = router_handle_ok}}
    router := Router {
        middleware = middleware[:],
        routes     = routes[:],
        user_data  = &obs,
    }

    got := run_router_exchange(t, "GET /ws HTTP/1.1\r\nhost: 127.0.0.1\r\n\r\n", &router)

    testing.expect_value(t, obs.middleware_hits, 1)
    testing.expect_value(t, obs.middleware2_hits, 0)
    testing.expect_value(t, obs.handler_hits, 0)
    testing.expect(t, strings.has_prefix(got, "HTTP/1.1 401 Unauthorized\r\n"), "stopped middleware should answer")
}

@(test)
test_router_not_found_and_method_not_allowed :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    obs: Router_Obs
    middleware := [?]Middleware{router_mw_count}
    routes := [?]Route {
        {method = "GET", pattern = "/ws", handler = router_handle_ok},
        {method = "PUT", pattern = "/blob/*", handler = router_handle_ok},
    }
    router := Router {
        middleware = middleware[:],
        routes     = routes[:],
        user_data  = &obs,
    }

    missing := run_router_exchange(t, "GET /nope HTTP/1.1\r\nhost: 127.0.0.1\r\n\r\n", &router)
    testing.expect_value(t, obs.middleware_hits, 1)
    testing.expect_value(t, obs.handler_hits, 0)
    testing.expect(t, strings.has_prefix(missing, "HTTP/1.1 404 Not Found\r\n"), "unknown path should 404")

    obs = {}
    wrong := run_router_exchange(t, "POST /ws HTTP/1.1\r\nhost: 127.0.0.1\r\ncontent-length: 0\r\n\r\n", &router)
    testing.expect_value(t, obs.middleware_hits, 1)
    testing.expect_value(t, obs.handler_hits, 0)
    testing.expect(
        t,
        strings.has_prefix(wrong, "HTTP/1.1 405 Method Not Allowed\r\n"),
        "known path wrong method should 405",
    )

    obs = {}
    put_unknown := run_router_exchange(
        t,
        "PUT /nope HTTP/1.1\r\nhost: 127.0.0.1\r\ncontent-length: 0\r\n\r\n",
        &router,
    )
    testing.expect(
        t,
        strings.has_prefix(put_unknown, "HTTP/1.1 404 Not Found\r\n"),
        "unknown path with a non-GET method should 404 when no pattern matches",
    )
}

@(test)
test_router_middleware_continue_chain_reaches_handler :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    obs: Router_Obs
    middleware := [?]Middleware{router_mw_count, router_mw_count2}
    routes := [?]Route{{method = "GET", pattern = "/ws", handler = router_handle_ok}}
    router := Router {
        middleware = middleware[:],
        routes     = routes[:],
        user_data  = &obs,
    }

    got := run_router_exchange(t, "GET /ws HTTP/1.1\r\nhost: 127.0.0.1\r\n\r\n", &router)

    testing.expect_value(t, obs.middleware_hits, 1)
    testing.expect_value(t, obs.middleware2_hits, 1)
    testing.expect_value(t, obs.handler_hits, 1)
    testing.expect(t, strings.has_prefix(got, "HTTP/1.1 200 OK\r\n"), "Continue chain should reach the handler")
}

router_fallback_not_found :: proc(c: ^Conn, req: Request, user_data: rawptr) {
    o := (^Router_Obs)(user_data)
    o.handler_hits += 1
    respond_text(c, .Not_Found, "custom-missing")
}

router_fallback_method :: proc(c: ^Conn, req: Request, allow: string, user_data: rawptr) {
    o := (^Router_Obs)(user_data)
    o.handler_hits += 1
    o.allow = strings.clone(allow, context.temp_allocator)
    respond_text(c, .Method_Not_Allowed, "custom-method")
}

@(test)
test_router_custom_fallbacks :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    obs: Router_Obs
    routes := [?]Route{{method = "GET", pattern = "/ws", handler = router_handle_ok}}
    router := Router {
        routes                = routes[:],
        user_data             = &obs,
        on_not_found          = router_fallback_not_found,
        on_method_not_allowed = router_fallback_method,
    }

    missing := run_router_exchange(t, "GET /nope HTTP/1.1\r\nhost: 127.0.0.1\r\n\r\n", &router)
    testing.expect_value(t, obs.handler_hits, 1)
    testing.expect(t, strings.has_prefix(missing, "HTTP/1.1 404 Not Found\r\n"), "custom not-found status")
    testing.expect(t, strings.has_suffix(missing, "custom-missing"), "custom not-found body")

    obs = {}
    wrong := run_router_exchange(t, "POST /ws HTTP/1.1\r\nhost: 127.0.0.1\r\ncontent-length: 0\r\n\r\n", &router)
    testing.expect_value(t, obs.handler_hits, 1)
    testing.expect(t, strings.has_prefix(wrong, "HTTP/1.1 405 Method Not Allowed\r\n"), "custom method status")
    testing.expect(t, strings.has_suffix(wrong, "custom-method"), "custom method body")
    testing.expect_value(t, obs.allow, "GET")
}

// `.Stop` is legal via hijack and via receive_body, not just respond; the router
// asserts the connection left `Reading` on each.
@(test)
test_router_middleware_can_stop_by_hijacking :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    obs := Router_Obs {
        stop_mode = .Hijack,
    }
    middleware := [?]Middleware{router_mw_count}
    routes := [?]Route{{method = "GET", pattern = "/ws", handler = router_handle_ok}}
    router := Router {
        middleware = middleware[:],
        routes     = routes[:],
        user_data  = &obs,
    }
    got := run_router_exchange(t, "GET /ws HTTP/1.1\r\nhost: 127.0.0.1\r\n\r\n", &router)

    testing.expect_value(t, obs.middleware_hits, 1)
    testing.expect_value(t, obs.handler_hits, 0)
    testing.expect_value(t, got, HIJACKED)
}

@(test)
test_router_middleware_can_stop_by_receiving_body :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    obs := Router_Obs {
        stop_mode = .Receive_Body,
    }
    middleware := [?]Middleware{router_mw_count}
    routes := [?]Route{{method = "PUT", pattern = "/up", handler = router_handle_ok}}
    router := Router {
        middleware = middleware[:],
        routes     = routes[:],
        user_data  = &obs,
    }
    got := run_router_exchange(t, "PUT /up HTTP/1.1\r\nhost: 127.0.0.1\r\ncontent-length: 5\r\n\r\nhello", &router)

    testing.expect_value(t, obs.middleware_hits, 1)
    testing.expect_value(t, obs.handler_hits, 0)
    testing.expect(t, obs.mw_body_ended, "the body should complete")
    testing.expect_value(t, obs.mw_body_got, 5)
    testing.expect(t, strings.has_suffix(got, "mw-body"), "the middleware should answer after the body")
}

// Middleware receives what the router already derived, so nothing re-splits the target.
@(test)
test_router_middleware_sees_path_and_query :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    obs: Router_Obs
    middleware := [?]Middleware{router_mw_count}
    routes := [?]Route{{method = "GET", pattern = "/ws", handler = router_handle_ok}}
    router := Router {
        middleware = middleware[:],
        routes     = routes[:],
        user_data  = &obs,
    }
    run_router_exchange(t, "GET /ws?a=1&b=2 HTTP/1.1\r\nhost: 127.0.0.1\r\n\r\n", &router)

    testing.expect_value(t, obs.mw_path, "/ws")
    testing.expect_value(t, obs.mw_query, "a=1&b=2")
    testing.expect_value(t, obs.handler_hits, 1)
}

// RFC 9110 §15.5.6: a 405 MUST carry `Allow` listing the methods for that resource.
@(test)
test_router_405_carries_allow :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    obs: Router_Obs
    routes := [?]Route {
        {method = "GET", pattern = "/blob/*", handler = router_handle_ok},
        {method = "PUT", pattern = "/blob/*", handler = router_handle_ok},
    }
    router := Router {
        routes    = routes[:],
        user_data = &obs,
    }

    got := run_router_exchange(t, "DELETE /blob/abc HTTP/1.1\r\nhost: 127.0.0.1\r\n\r\n", &router)

    testing.expect(t, strings.has_prefix(got, "HTTP/1.1 405 Method Not Allowed\r\n"), "should answer 405")
    testing.expectf(t, strings.contains(got, "Allow: GET, PUT\r\n"), "405 must list both methods, got %q", got)
    testing.expect_value(t, obs.handler_hits, 0)
}
