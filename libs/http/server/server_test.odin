package http_server

import "core:log"
import "core:nbio"
import "core:net"
import "core:os"
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
    hijack:                  bool,

    // Shut the front door down from inside the request callback after answering.
    shutdown:                bool,

    // Number of `on_request` calls.
    request_count:           int,

    // Method and target of the most recent request.
    method:                  string,
    target:                  string,

    // Bytes the handler saw past the head.
    body_len:                int,

    // Head-consumed byte count and raw trailing bytes, for split-terminator checks.
    consumed:                int,
    trailing:                string,

    // Stream the request body via `receive_body` instead of responding immediately.
    receive_body:            bool,

    // Reject the first body chunk from the sink, exercising the abort path.
    abort_body:              bool,

    // Body bytes the sink accumulated, and how many.
    body_buf:                [256]byte,
    body_got:                int,

    // The end callback fired, and with which outcome.
    body_ended:              bool,
    body_ok:                 bool,

    // Defer the response and answer from a later loop callback, standing in for work
    // handed to another thread.
    defer_later:             bool,

    // Finalize the connection between the deferral and the answer.
    finalize_while_deferred: bool,

    // The deferred callback ran at all.
    answered_late:           bool,

    // What `conn_resolve` reported from the deferred callback: its own ticket resolving
    // back to the same connection, and a never-issued ticket and zero both missing.
    resolved_self:           bool,
    resolved_miss:           bool,
    resolved_zero:           bool,

    // Answer with `respond_redirect` instead of a body.
    redirect:                bool,
    redirect_to:             string,

    // Answer from this staged file, exercising `respond_file`'s own head build.
    file_path:               string,

    // What the answering call returned. Exactly one answer path runs per exchange.
    answer_err:              Response_Error,

    // Headers added via `conn_add_header` before answering, and what each add returned.
    add_headers:             []Header,
    add_errs:                [2]Response_Error,

    // Pending header `hijack` handed back, cloned out before the connection is released.
    hijacked_count:          int,
    hijacked:                Header,
}

FILE_BODY :: "file-body"

// A ticket the server never issues, for the miss case.
UNISSUED_TICKET :: Ticket(1 << 40)

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

    assert(len(o.add_headers) <= len(o.add_errs), "test add_errs is too small for its add_headers")
    for field, i in o.add_headers {
        o.add_errs[i] = try_conn_add_header(c, field.name, field.value)
    }

    if o.receive_body {
        receive_body(c, o, test_body_chunk, test_body_end)
        return
    }

    if o.defer_later {
        test_defer_and_answer_later(c)
        return
    }

    if o.redirect {
        o.answer_err = try_respond_redirect(c, .Found, o.redirect_to)
        test_answer_fallback(c, o)
        return
    }

    if o.file_path != "" {
        test_respond_from_file(c, o)
        return
    }

    if !o.hijack {
        o.answer_err = try_respond_text(c, .Ok, "hello")
        test_answer_fallback(c, o)

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

// Defer, then answer from a zero-duration timeout: the same shape an offloaded task's
// completion arrives in, without needing a worker thread to produce it.
test_defer_and_answer_later :: proc(c: ^Conn) {
    defer_response(c)
    assert(c.state == .Deferred, "deferring did not reach Deferred")

    if obs_of(c).finalize_while_deferred {
        // Stand in for teardown landing between the deferral and its answer.
        conn_finalize(c)
    }

    nbio.timeout_poly(0, c, test_answer_deferred, c.loop)
}

test_answer_deferred :: proc(op: ^nbio.Operation, c: ^Conn) {
    o := obs_of(c)

    o.resolved_self = conn_resolve(c.server, c.ticket) == c
    o.resolved_miss = conn_resolve(c.server, UNISSUED_TICKET) == nil
    o.resolved_zero = conn_resolve(c.server, 0) == nil
    o.answered_late = true

    // What deferred work must do: answer only what resolving still hands back.
    if conn_resolve(c.server, c.ticket) == nil {
        return
    }

    respond_text(c, .Ok, "deferred")
}

// Take the socket over and write `HIJACKED` straight onto it. The returned headers borrow
// the connection, so they are cloned before it is released.
test_hijack_and_greet :: proc(c: ^Conn) {
    o := obs_of(c)
    socket, loop, headers := hijack(c)

    o.hijacked_count = len(headers)
    if len(headers) > 0 {
        o.hijacked = {
            name  = strings.clone(headers[0].name, context.temp_allocator),
            value = strings.clone(headers[0].value, context.temp_allocator),
        }
    }

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

// Write the file a `respond_file` exchange serves, off the reactor thread. Empty on
// failure, which the test expects against.
test_stage_file :: proc() -> string {
    base, has := os.lookup_env("TMPDIR", context.temp_allocator)
    if !has {
        base = "/tmp"
    }

    path, _ := os.join_path({base, "http_server_pending_headers"}, context.temp_allocator)
    if os.write_entire_file(path, transmute([]byte)string(FILE_BODY)) != nil {
        return ""
    }

    return path
}

// Answer from the staged file, covering `respond_file`'s own head build.
test_respond_from_file :: proc(c: ^Conn, o: ^Obs) {
    file, oerr := nbio.open_sync(o.file_path, l = c.loop)
    if oerr != nil {
        respond_text(c, .Internal_Server_Error, "cannot open the file")
        return
    }

    o.answer_err = try_respond_file(c, .Ok, "text/plain", file, 1 << 20, .Not_Found, "missing")
    if o.answer_err != .None {
        nbio.close(file, l = c.loop)
    }

    test_answer_fallback(c, o)
}

// The answering call refused, so nothing was sent and the connection contract still
// stands. An oversized pending header poisons every response, so abort is the last resort.
test_answer_fallback :: proc(c: ^Conn, o: ^Obs) {
    if o.answer_err == .None {
        return
    }

    if try_respond_text(c, .Internal_Server_Error, "answer rejected") != .None {
        abort(c)
    }
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
run_router_exchange :: proc(t: ^testing.T, request: string, router: ^Router(Router_Obs), split_at := 0) -> string {
    router_validate(router)

    return run_exchange_with(t, request, router_on_request(Router_Obs), router, {}, split_at)
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

// A handler may answer after returning, which is what work handed to another thread
// needs. The connection must survive the gap and the response must still arrive.
@(test)
test_http_defers_then_answers :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    obs := Obs {
        defer_later = true,
    }
    got := run_exchange(t, "GET /deferred HTTP/1.1\r\nhost: 127.0.0.1\r\n\r\n", &obs)

    testing.expect_value(t, obs.request_count, 1)
    testing.expect(t, strings.has_prefix(got, "HTTP/1.1 200 OK\r\n"), "deferred answer must reach the peer")
    testing.expect(t, strings.has_suffix(got, "deferred"), "deferred answer must carry its body")
}

// Teardown between the deferral and the answer is ordinary, not an error: the ticket must
// stop resolving the moment the connection can no longer be answered, even though it stays
// in the table until its closes complete. Without that, deferred work walks into a
// finalized connection and responds onto a dead socket.
@(test)
test_http_deferred_ticket_misses_after_finalize :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    obs := Obs {
        defer_later             = true,
        finalize_while_deferred = true,
    }
    got := run_exchange(t, "GET /deferred HTTP/1.1\r\nhost: 127.0.0.1\r\n\r\n", &obs)

    testing.expect(t, obs.answered_late, "the deferred callback must still run")
    testing.expect(t, !obs.resolved_self, "a finalized connection must not resolve")
    testing.expect_value(t, got, "")
}

// A ticket resolves to its own connection while it lives; a never-issued ticket and zero
// resolve to nothing. This is the only question deferred work may ask about a connection
// it does not own.
@(test)
test_http_ticket_resolves_only_live_connections :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    obs := Obs {
        defer_later = true,
    }
    run_exchange(t, "GET /deferred HTTP/1.1\r\nhost: 127.0.0.1\r\n\r\n", &obs)

    testing.expect(t, obs.resolved_self, "a live ticket must resolve to its own connection")
    testing.expect(t, obs.resolved_miss, "a never-issued ticket must resolve to nothing")
    testing.expect(t, obs.resolved_zero, "the zero ticket must resolve to nothing")
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

// The cap is enforced on the declared length, so an oversized body is refused before the
// handler runs and before a byte of it is read.
@(test)
test_http_refuses_a_body_over_the_cap :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    obs := Obs {
        receive_body = true,
    }
    got := run_exchange(
        t,
        "PUT /up HTTP/1.1\r\nhost: 127.0.0.1\r\ncontent-length: 11\r\n\r\nhello world",
        &obs,
        {max_body_bytes = 10},
    )

    testing.expect(t, strings.has_prefix(got, "HTTP/1.1 413 Content Too Large\r\n"), "an over-cap body should 413")
    testing.expect_value(t, obs.request_count, 0)
    testing.expect(t, !obs.body_ended, "the body sink must never run")

    // One byte under the cap still reaches the handler.
    fits := Obs {
        receive_body = true,
    }
    ok := run_exchange(
        t,
        "PUT /up HTTP/1.1\r\nhost: 127.0.0.1\r\ncontent-length: 11\r\n\r\nhello world",
        &fits,
        {max_body_bytes = 11},
    )

    testing.expect(t, strings.has_prefix(ok, "HTTP/1.1 200 OK\r\n"), "a body at the cap is accepted")
    testing.expect_value(t, fits.body_got, 11)
}

// A negative ceiling is a configuration error, not a way to ask for "unlimited"; zero
// means the default, which every other exchange here exercises.
@(test)
test_http_body_cap_rejects_a_negative_ceiling :: proc(t: ^testing.T) {
    s: Server
    loop := nbio.Event_Loop{}

    testing.expect_value(t, listen(&s, &loop, {max_body_bytes = -1}, test_on_request), Error.Invalid_Options)
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
test_http_redirect_sets_location_and_sends_no_body :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    obs := Obs {
        redirect    = true,
        redirect_to = "/elsewhere",
    }
    got := run_exchange(t, "GET / HTTP/1.1\r\nhost: 127.0.0.1\r\n\r\n", &obs)

    testing.expect_value(t, obs.answer_err, Response_Error.None)
    testing.expect(t, strings.has_prefix(got, "HTTP/1.1 302 Found\r\n"), "should answer 302")
    testing.expectf(t, strings.contains(got, "Location: /elsewhere\r\n"), "should carry the target, got %q", got)
    testing.expectf(t, strings.contains(got, "Content-Length: 0\r\n"), "a redirect has no body, got %q", got)
    testing.expectf(t, !strings.contains(got, "Content-Type:"), "an empty body needs no type, got %q", got)
}

@(test)
test_http_redirect_carries_pending_headers :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    add := [1]Header{{name = "Cache-Control", value = "no-store"}}
    obs := Obs {
        redirect    = true,
        redirect_to = "https://example.test/next",
        add_headers = add[:],
    }
    got := run_exchange(t, "GET / HTTP/1.1\r\nhost: 127.0.0.1\r\n\r\n", &obs)

    testing.expect_value(t, obs.answer_err, Response_Error.None)
    testing.expectf(t, strings.contains(got, "Location: https://example.test/next\r\n"), "target, got %q", got)
    testing.expectf(t, strings.contains(got, "Cache-Control: no-store\r\n"), "pending header, got %q", got)
}

// Two `Location` fields would be ambiguous, so `respond_redirect` owns the name outright
// and refuses a target that is already pending.
@(test)
test_http_redirect_rejects_a_pending_location :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    add := [1]Header{{name = "location", value = "/sneaky"}}
    obs := Obs {
        redirect    = true,
        redirect_to = "/elsewhere",
        add_headers = add[:],
    }
    got := run_exchange(t, "GET / HTTP/1.1\r\nhost: 127.0.0.1\r\n\r\n", &obs)

    testing.expect_value(t, obs.add_errs[0], Response_Error.None)
    testing.expect_value(t, obs.answer_err, Response_Error.Invalid_Header)
    testing.expect(t, strings.has_prefix(got, "HTTP/1.1 500 Internal Server Error\r\n"), "should not redirect")
    testing.expectf(t, !strings.contains(got, "/elsewhere"), "the refused target must not ship, got %q", got)
}

@(test)
test_http_redirect_rejects_an_unusable_target :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    empty := Obs {
        redirect    = true,
        redirect_to = "",
    }
    run_exchange(t, "GET / HTTP/1.1\r\nhost: 127.0.0.1\r\n\r\n", &empty)
    testing.expect_value(t, empty.answer_err, Response_Error.Invalid_Header)

    // A bare CR cannot appear in a field value; it would split the head.
    injected := Obs {
        redirect    = true,
        redirect_to = "/ok\r\nx-injected: 1",
    }
    got := run_exchange(t, "GET / HTTP/1.1\r\nhost: 127.0.0.1\r\n\r\n", &injected)

    testing.expect_value(t, injected.answer_err, Response_Error.Invalid_Header)
    testing.expectf(t, !strings.contains(got, "x-injected"), "injection must not ship, got %q", got)
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

// --- Pending response headers -------------------------------------------------
//
// A pre-match step marks the connection once and every response it can reach carries the
// header, instead of each response site repeating it.

@(test)
test_http_pending_header_reaches_the_response :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    add := [1]Header{{name = "Cache-Control", value = "private, no-store"}}
    obs := Obs {
        add_headers = add[:],
    }
    got := run_exchange(t, "GET /thing HTTP/1.1\r\nhost: 127.0.0.1\r\n\r\n", &obs)

    testing.expect_value(t, obs.add_errs[0], Response_Error.None)
    testing.expect_value(t, obs.answer_err, Response_Error.None)
    testing.expectf(t, strings.contains(got, "Cache-Control: private, no-store\r\n"), "pending header, got %q", got)
    testing.expectf(t, strings.has_suffix(got, "hello"), "the body must still arrive, got %q", got)
}

// `respond_file` builds its head on its own path, so it needs its own proof.
@(test)
test_http_pending_header_reaches_a_file_response :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    add := [1]Header{{name = "Cache-Control", value = "private, no-store"}}
    obs := Obs {
        file_path   = test_stage_file(),
        add_headers = add[:],
    }
    testing.expect(t, obs.file_path != "", "the served file must stage")
    got := run_exchange(t, "GET /file HTTP/1.1\r\nhost: 127.0.0.1\r\n\r\n", &obs)

    testing.expect_value(t, obs.answer_err, Response_Error.None)
    testing.expectf(t, strings.contains(got, "Cache-Control: private, no-store\r\n"), "pending header, got %q", got)
    testing.expectf(t, strings.has_suffix(got, FILE_BODY), "the file body must still arrive, got %q", got)
}

// The answer may outlive the request frame. `pending` lives on the connection, so an
// answer resolved by ticket long after the handler returned still carries it.
@(test)
test_http_pending_header_survives_a_deferred_answer :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    add := [1]Header{{name = "Cache-Control", value = "private, no-store"}}
    obs := Obs {
        defer_later = true,
        add_headers = add[:],
    }
    got := run_exchange(t, "GET /deferred HTTP/1.1\r\nhost: 127.0.0.1\r\n\r\n", &obs)

    testing.expectf(t, strings.contains(got, "Cache-Control: private, no-store\r\n"), "pending header, got %q", got)
    testing.expectf(t, strings.has_suffix(got, "deferred"), "the deferred body must still arrive, got %q", got)
}

// `hijack` hands its pending headers back for the adopting protocol to emit.
@(test)
test_http_hijack_returns_pending_headers :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    add := [1]Header{{name = "Cache-Control", value = "private, no-store"}}
    obs := Obs {
        hijack      = true,
        add_headers = add[:],
    }
    run_exchange(t, "GET /ws HTTP/1.1\r\nhost: 127.0.0.1\r\n\r\n", &obs)

    testing.expect_value(t, obs.hijacked_count, 1)
    testing.expect_value(t, obs.hijacked.name, "Cache-Control")
    testing.expect_value(t, obs.hijacked.value, "private, no-store")
}

// One field name, one value: a second add of the same name is refused rather than
// emitting two fields or silently replacing the first. Matched case-insensitively.
@(test)
test_http_pending_header_rejects_a_duplicate_add :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    add := [2]Header {
        {name = "Cache-Control", value = "private, no-store"},
        {name = "cache-control", value = "no-cache"},
    }
    obs := Obs {
        add_headers = add[:],
    }
    got := run_exchange(t, "GET /thing HTTP/1.1\r\nhost: 127.0.0.1\r\n\r\n", &obs)

    testing.expect_value(t, obs.add_errs[0], Response_Error.None)
    testing.expect_value(t, obs.add_errs[1], Response_Error.Invalid_Header)
    testing.expectf(t, !strings.contains(got, "no-cache"), "the refused value must not ship, got %q", got)
}

// The framing fields the server owns are refused, and a refused add leaves the response
// itself untouched.
@(test)
test_http_pending_header_rejects_a_reserved_name :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    add := [1]Header{{name = "Content-Length", value = "7"}}
    obs := Obs {
        add_headers = add[:],
    }
    got := run_exchange(t, "GET /thing HTTP/1.1\r\nhost: 127.0.0.1\r\n\r\n", &obs)

    testing.expect_value(t, obs.add_errs[0], Response_Error.Invalid_Header)
    testing.expect_value(t, obs.answer_err, Response_Error.None)
    testing.expectf(t, strings.has_suffix(got, "hello"), "a refused add must not stop the response, got %q", got)
}


// Pending headers are charged against the same head budget as caller headers, so a
// pre-match step cannot overrun the response head.
@(test)
test_http_pending_header_counts_against_the_head_budget :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    add := [1]Header{{name = "X-Big", value = strings.repeat("v", 512, context.temp_allocator)}}
    obs := Obs {
        add_headers = add[:],
    }
    run_exchange(t, "GET /thing HTTP/1.1\r\nhost: 127.0.0.1\r\n\r\n", &obs, {max_head_bytes = 256})

    testing.expect_value(t, obs.add_errs[0], Response_Error.None)
    testing.expect_value(t, obs.answer_err, Response_Error.Invalid_Header)
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

router_mw_count :: proc(ctx: ^Context(Router_Obs)) -> Middleware_Result {
    o := ctx.user_data
    o.middleware_hits += 1
    o.mw_path = strings.clone(ctx.request.path, context.temp_allocator)
    o.mw_query = strings.clone(ctx.request.query, context.temp_allocator)

    switch o.stop_mode {
    case .None:

    case .Respond:
        respond_text(ctx.conn, .Unauthorized, "unauthorized")
        return .Stop

    case .Hijack:
        test_hijack_and_greet(ctx.conn)
        return .Stop

    case .Receive_Body:
        receive_body(ctx.conn, o, router_mw_body_chunk, router_mw_body_end)
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

router_mw_count2 :: proc(ctx: ^Context(Router_Obs)) -> Middleware_Result {
    o := ctx.user_data
    o.middleware2_hits += 1
    return .Continue
}

router_handle_ok :: proc(ctx: ^Context(Router_Obs)) {
    o := ctx.user_data
    o.handler_hits += 1
    o.last_rest = strings.clone(ctx.params.path_rest, context.temp_allocator)
    respond_text(ctx.conn, .Ok, "routed")
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
    middleware := [?]Middleware(Router_Obs){{router_mw_count}}
    routes := [?]Route(Router_Obs){{method = "GET", pattern = "/blob/*", handler = router_handle_ok}}
    router := Router(Router_Obs) {
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
    middleware := [?]Middleware(Router_Obs){{router_mw_count}, {router_mw_count2}}
    routes := [?]Route(Router_Obs){{method = "GET", pattern = "/ws", handler = router_handle_ok}}
    router := Router(Router_Obs) {
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
    middleware := [?]Middleware(Router_Obs){{router_mw_count}}
    routes := [?]Route(Router_Obs) {
        {method = "GET", pattern = "/ws", handler = router_handle_ok},
        {method = "PUT", pattern = "/blob/*", handler = router_handle_ok},
    }
    router := Router(Router_Obs) {
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
    middleware := [?]Middleware(Router_Obs){{router_mw_count}, {router_mw_count2}}
    routes := [?]Route(Router_Obs){{method = "GET", pattern = "/ws", handler = router_handle_ok}}
    router := Router(Router_Obs) {
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

router_fallback_not_found :: proc(ctx: ^Context(Router_Obs)) {
    o := ctx.user_data
    o.handler_hits += 1
    respond_text(ctx.conn, .Not_Found, "custom-missing")
}

router_fallback_method :: proc(ctx: ^Context(Router_Obs)) {
    o := ctx.user_data
    o.handler_hits += 1
    o.allow = strings.clone(ctx.allow, context.temp_allocator)
    respond_text(ctx.conn, .Method_Not_Allowed, "custom-method")
}

@(test)
test_router_custom_fallbacks :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    obs: Router_Obs
    routes := [?]Route(Router_Obs){{method = "GET", pattern = "/ws", handler = router_handle_ok}}
    router := Router(Router_Obs) {
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
    middleware := [?]Middleware(Router_Obs){{router_mw_count}}
    routes := [?]Route(Router_Obs){{method = "GET", pattern = "/ws", handler = router_handle_ok}}
    router := Router(Router_Obs) {
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
    middleware := [?]Middleware(Router_Obs){{router_mw_count}}
    routes := [?]Route(Router_Obs){{method = "PUT", pattern = "/up", handler = router_handle_ok}}
    router := Router(Router_Obs) {
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
    middleware := [?]Middleware(Router_Obs){{router_mw_count}}
    routes := [?]Route(Router_Obs){{method = "GET", pattern = "/ws", handler = router_handle_ok}}
    router := Router(Router_Obs) {
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
    routes := [?]Route(Router_Obs) {
        {method = "GET", pattern = "/blob/*", handler = router_handle_ok},
        {method = "PUT", pattern = "/blob/*", handler = router_handle_ok},
    }
    router := Router(Router_Obs) {
        routes    = routes[:],
        user_data = &obs,
    }

    got := run_router_exchange(t, "DELETE /blob/abc HTTP/1.1\r\nhost: 127.0.0.1\r\n\r\n", &router)

    testing.expect(t, strings.has_prefix(got, "HTTP/1.1 405 Method Not Allowed\r\n"), "should answer 405")
    testing.expectf(t, strings.contains(got, "Allow: GET, PUT\r\n"), "405 must list both methods, got %q", got)
    testing.expect_value(t, obs.handler_hits, 0)
}
