package http_server

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

    if o.shutdown {
        shutdown(c.server)
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
    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    opts := options
    opts.host = "127.0.0.1"
    opts.port = 0

    s: Server
    testing.expect_value(t, listen(&s, loop, opts, test_on_request, obs), Error.None)

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
