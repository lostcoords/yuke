package curl

import "core:c"
import "core:fmt"
import "core:nbio"
import "core:net"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import "libs:http"
import http_server "libs:http/server"
import ts "libs:testsupport"

// --- Option values ------------------------------------------------------------

// The composed option numbers are the only place a wrong constant would be silent:
// libcurl takes an unknown option number and an argument of the wrong C type
// without complaint. Pinned against curl.h's own `CURLOPT(name, type, ordinal)`.
@(test)
test_curl_option_values_match_curl_h :: proc(t: ^testing.T) {
    testing.expect_value(t, int(Option.Url), 10002)
    testing.expect_value(t, int(Option.Write_Data), 10001)
    testing.expect_value(t, int(Option.Error_Buffer), 10010)
    testing.expect_value(t, int(Option.Http_Header), 10023)
    testing.expect_value(t, int(Option.Header_Data), 10029)
    testing.expect_value(t, int(Option.Copy_Post_Fields), 10165)
    testing.expect_value(t, int(Option.Write_Function), 20011)
    testing.expect_value(t, int(Option.Header_Function), 20079)
    testing.expect_value(t, int(Option.Post_Field_Size_Large), 30120)
    testing.expect_value(t, int(Option.Ssl_Cert_Blob), 40291)
    testing.expect_value(t, int(Option.Low_Speed_Limit), 19)
    testing.expect_value(t, int(Option.Low_Speed_Time), 20)
    testing.expect_value(t, int(Option.Post), 47)
    testing.expect_value(t, int(Option.Follow_Location), 52)
    testing.expect_value(t, int(Option.Post_Field_Size), 60)
    testing.expect_value(t, int(Option.Connect_Timeout), 78)
    testing.expect_value(t, int(Option.Http_Get), 80)
    testing.expect_value(t, int(Option.No_Signal), 99)
    testing.expect_value(t, int(Option.Pipe_Wait), 237)
    testing.expect_value(t, int(Option.Connect_Only), 141)
    testing.expect_value(t, int(Option.Http_Version), 84)
    testing.expect_value(t, int(Option.Ca_Info), 10065)
    testing.expect_value(t, HTTP_VERSION_1_1, 2)
    testing.expect_value(t, int(Info.Active_Socket), 5242924)
    testing.expect_value(t, int(Info.Response_Code), 2097154)
    testing.expect_value(t, int(Code.Write_Error), 23)
    testing.expect_value(t, int(Code.Aborted_By_Callback), 42)
    testing.expect_value(t, int(Multi_Code.Call_Multi_Perform), -1)
    testing.expect_value(t, int(Msg_Kind.Done), 1)
}

@(test)
test_curl_parses_status_lines :: proc(t: ^testing.T) {
    status, ok := parse_status_line(transmute([]byte)string("HTTP/1.1 429 Too Many Requests"))
    testing.expect(t, ok, "a status line must parse")
    testing.expect_value(t, status, 429)

    status, ok = parse_status_line(transmute([]byte)string("HTTP/2 200"))
    testing.expect(t, ok, "a reason-less status line must parse")
    testing.expect_value(t, status, 200)

    _, ok = parse_status_line(transmute([]byte)string("content-type: text/plain"))
    testing.expect(t, !ok, "a header line is not a status line")

    _, ok = parse_status_line(transmute([]byte)string("HTTP/1.1 20 OK"))
    testing.expect(t, !ok, "a two-digit status is not a status line")
}

// --- Streaming fixture ---------------------------------------------------------

// A canned response written onto the hijacked socket one piece at a time, so a
// test can prove chunks reach `On_Body` before the response has finished
// arriving. The front door only supplies the accept and the request parse.
Fake :: struct {
    front:    http_server.Server,
    parts:    []string,

    // Delay inserted before every piece after the first.
    gap:      time.Duration,
    next:     int,
    socket:   net.TCP_Socket,
    loop:     ^nbio.Event_Loop,
    taken:    bool,
    closed:   bool,

    // Request body received before the canned response goes out.
    body:     [64]byte,
    body_len: int,
}

fake_on_request :: proc(c: ^http_server.Conn, req: http_server.Request) {
    f := (^Fake)(c.server.user_data)
    f.socket, f.loop, _ = http_server.hijack(c)
    f.taken = true

    f.body_len = copy(f.body[:], req.trailing)
    remaining := min(int(req.content_length) - f.body_len, len(f.body) - f.body_len)
    if remaining > 0 {
        nbio.recv_poly(
            f.socket,
            [][]byte{f.body[f.body_len:][:remaining]},
            f,
            fake_on_body,
            true,
            nbio.NO_TIMEOUT,
            f.loop,
        )
        return
    }

    fake_send_next(f)
}

fake_on_body :: proc(op: ^nbio.Operation, f: ^Fake) {
    f.body_len += op.recv.received
    fake_send_next(f)
}

fake_send_next :: proc(f: ^Fake) {
    if f.next >= len(f.parts) {
        fake_close(f)
        return
    }

    part := f.parts[f.next]
    f.next += 1
    nbio.send_poly(f.socket, [][]byte{transmute([]byte)part}, f, fake_on_sent, {}, true, nbio.NO_TIMEOUT, f.loop)
}

fake_on_sent :: proc(op: ^nbio.Operation, f: ^Fake) {
    // The peer going away mid-script is the canceled-transfer case, not a failure.
    if op.send.err != nil {
        fake_close(f)
        return
    }

    if f.gap > 0 && f.next < len(f.parts) {
        nbio.timeout_poly(f.gap, f, fake_on_gap, f.loop)
        return
    }

    fake_send_next(f)
}

fake_on_gap :: proc(op: ^nbio.Operation, f: ^Fake) {
    fake_send_next(f)
}

// EOF is what ends the body: none of the canned responses carry a content-length.
fake_close :: proc(f: ^Fake) {
    if f.closed || !f.taken {
        return
    }

    f.closed = true
    nbio.close(f.socket, fake_on_closed, f.loop)
}

fake_on_closed :: proc(op: ^nbio.Operation) {
}

// --- Observation ---------------------------------------------------------------

// What the transfer under test saw, accumulated without allocating so the fixture
// stays leak-clean.
Obs :: struct {
    transfer:      Transfer,
    client:        ^Client,

    // Body chunks concatenated in arrival order.
    body:          [4096]byte,
    body_len:      int,
    chunk_count:   int,

    // Header lines joined with '\n', in arrival order.
    headers:       [1024]byte,
    headers_len:   int,
    header_count:  int,
    status_count:  int,
    last_status:   int,
    status_seen:   [4]int,

    // Terminal result.
    done_count:    int,
    done_code:     Code,
    done_status:   int,
    message:       [ERROR_SIZE]byte,
    message_len:   int,

    // Return false from `On_Body` once this many chunks have arrived (0: never).
    abort_after:   int,

    // Cancel the transfer from a loop callback once this many chunks have arrived.
    cancel_after:  int,
    cancel_armed:  bool,

    // Set when the test may stop driving the loop.
    finished:      bool,

    // When set, `On_Done` starts this transfer against `chain_url` before returning
    // — the reentrancy a retrying engine performs.
    chain:         ^Obs,
    chain_url:     cstring,
    chain_err:     Error,

    // How long to keep watching for stray callbacks after a cancel.
    grace:         time.Duration,

    // Callbacks seen after the transfer was canceled, which must stay zero.
    after_cancel:  int,
    canceled:      bool,

    // Chunk count at the moment the transfer was canceled.
    chunks_at_cut: int,
}

obs_finished :: proc(o: ^Obs) -> bool {
    return o.finished
}

obs_on_status :: proc(user: rawptr, status: int) {
    o := (^Obs)(user)

    if o.status_count < len(o.status_seen) {
        o.status_seen[o.status_count] = status
    }

    o.status_count += 1
    o.last_status = status

    if o.canceled {
        o.after_cancel += 1
    }
}

obs_on_header :: proc(user: rawptr, line: []byte) {
    o := (^Obs)(user)
    o.header_count += 1

    if o.canceled {
        o.after_cancel += 1
    }

    if o.headers_len > 0 && o.headers_len < len(o.headers) {
        o.headers[o.headers_len] = '\n'
        o.headers_len += 1
    }

    o.headers_len += copy(o.headers[o.headers_len:], line)
}

obs_on_body :: proc(user: rawptr, chunk: []byte) -> bool {
    o := (^Obs)(user)
    o.chunk_count += 1
    o.body_len += copy(o.body[o.body_len:], chunk)

    if o.canceled {
        o.after_cancel += 1
    }

    if o.abort_after > 0 && o.chunk_count >= o.abort_after {
        return false
    }

    // Cancellation is deferred to the loop: `transfer_cancel` from inside a curl
    // callback is exactly what the driver forbids.
    if o.cancel_after > 0 && o.chunk_count >= o.cancel_after && !o.cancel_armed {
        o.cancel_armed = true
        nbio.timeout_poly(0, o, obs_cancel_now, o.client.loop)
    }

    return true
}

obs_on_done :: proc(user: rawptr, result: Result) {
    o := (^Obs)(user)
    o.done_count += 1
    o.done_code = result.code
    o.done_status = result.status
    o.message_len = copy(o.message[:], result.message)

    if o.canceled {
        o.after_cancel += 1
    }

    if o.chain != nil {
        next := o.chain
        o.chain = nil
        next.client = o.client
        next.chain_err = transfer_start(
            &next.transfer,
            o.client,
            Request{url = o.chain_url, method = .Get},
            obs_callbacks(),
            next,
        )
    }

    o.finished = true
}

obs_cancel_now :: proc(op: ^nbio.Operation, o: ^Obs) {
    transfer_cancel(&o.transfer)
    o.canceled = true
    o.chunks_at_cut = o.chunk_count

    // Give any stray callback a window to appear before the test stops driving.
    nbio.timeout_poly(o.grace, o, obs_grace_over, o.client.loop)
}

obs_grace_over :: proc(op: ^nbio.Operation, o: ^Obs) {
    o.finished = true
}

obs_callbacks :: proc() -> Callbacks {
    return Callbacks {
        on_status = obs_on_status,
        on_header = obs_on_header,
        on_body = obs_on_body,
        on_done = obs_on_done,
    }
}

obs_body :: proc(o: ^Obs) -> string {
    return string(o.body[:o.body_len])
}

obs_headers :: proc(o: ^Obs) -> string {
    return string(o.headers[:o.headers_len])
}

// --- Harness -------------------------------------------------------------------

// The request body the fixture posts.
@(rodata)
REQUEST_BODY := [?]byte{'{', '"', 's', 't', 'r', 'e', 'a', 'm', '"', ':', 't', 'r', 'u', 'e', '}'}

// Binds the front door on an OS-assigned port, runs one transfer against it on the
// same loop, and leaves the client for the caller to inspect and destroy.
run_transfer :: proc(t: ^testing.T, o: ^Obs, c: ^Client, f: ^Fake, method: Method = .Post) {
    port := http_server.bound_port(&f.front)
    testing.expect(t, port > 0, "front door must have a bound port")

    headers := []Header{{name = "content-type", value = "application/json"}, {name = "x-test-client", value = "yuke"}}
    req := Request {
        url     = fmt.ctprintf("http://127.0.0.1:%d/v1/messages", port),
        headers = headers,
        method  = method,
        body    = REQUEST_BODY[:] if method == .Post else nil,
    }

    o.client = c
    testing.expect_value(t, transfer_start(&o.transfer, c, req, obs_callbacks(), o), Error.None)
    testing.expect(t, c.timer_op != nil, "starting a transfer must arm the pump timer")
    testing.expect_value(t, len(c.live), 1)

    ts.nbio_run_until(t, o, obs_finished, "curl transfer completion")
}

// Full fixture lifecycle: loop, front door, client, one or more transfers, teardown.
run_fixture :: proc(t: ^testing.T, o: ^Obs, parts: []string, gap: time.Duration, method: Method = .Post) {
    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    f := Fake {
        parts = parts,
        gap   = gap,
    }
    options := http_server.Options {
        host = "127.0.0.1",
        port = 0,
    }
    testing.expect_value(t, http_server.listen(&f.front, loop, options, fake_on_request, &f), http_server.Error.None)

    c: Client
    testing.expect_value(t, client_init(&c, loop), Error.None)

    run_transfer(t, o, &c, &f)

    testing.expect_value(t, len(c.live), 0)
    testing.expect(t, c.timer_op == nil, "an idle client must disarm its pump timer")
    client_destroy(&c)

    fixture_teardown(t, &f)
}

fixture_teardown :: proc(t: ^testing.T, f: ^Fake) {
    fake_close(f)
    http_server.shutdown(&f.front)
    ts.nbio_run_until(t, &f.front.shutdown_complete, "front door shutdown")
    http_server.destroy(&f.front)
}

// --- Tests ---------------------------------------------------------------------

// Head and body arrive incrementally: the fixture writes the second SSE frame a
// gap after the first, so two separate `On_Body` calls prove the driver delivers
// while the response is still open rather than at completion.
@(test)
test_curl_streams_body_in_order :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    o: Obs
    parts := []string {
        "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\nx-test: alpha\r\n\r\n",
        "data: one\n\n",
        "data: two\n\n",
    }
    run_fixture(t, &o, parts, 30 * time.Millisecond)

    testing.expect_value(t, o.done_count, 1)
    testing.expect_value(t, o.done_code, Code.Ok)
    testing.expect_value(t, o.done_status, 200)
    testing.expect_value(t, o.last_status, 200)
    testing.expect_value(t, o.status_count, 1)
    testing.expect_value(t, obs_body(&o), "data: one\n\ndata: two\n\n")
    testing.expect(t, o.chunk_count >= 2, "a gapped response must arrive in at least two chunks")
    testing.expect(
        t,
        strings.contains(obs_headers(&o), "content-type: text/event-stream"),
        "response headers must reach On_Header",
    )
    testing.expect(t, strings.contains(obs_headers(&o), "x-test: alpha"), "every header line must reach On_Header")
    testing.expect(t, !strings.contains(obs_headers(&o), "HTTP/1.1"), "the status line is not a header line")
}

// Non-2xx is delivery, not classification: the status is surfaced and the body
// still reaches the caller, which is what a 429 classifier needs to read.
@(test)
test_curl_surfaces_non_2xx_with_body :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    o: Obs
    parts := []string {
        "HTTP/1.1 429 Too Many Requests\r\ncontent-type: application/json\r\nretry-after: 3\r\n\r\n",
        `{"error":{"type":"rate_limit_error"}}`,
    }
    run_fixture(t, &o, parts, 0)

    testing.expect_value(t, o.done_count, 1)
    testing.expect_value(t, o.done_code, Code.Ok)
    testing.expect_value(t, o.done_status, 429)
    testing.expect_value(t, o.last_status, 429)
    testing.expect_value(t, obs_body(&o), `{"error":{"type":"rate_limit_error"}}`)
    testing.expect(t, strings.contains(obs_headers(&o), "retry-after: 3"), "Retry-After must reach On_Header")
}

// `On_Body` returning false is the only in-callback cancellation: the transfer
// aborts and the transfer still completes through the ordinary done path.
@(test)
test_curl_aborts_from_body_callback :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    o := Obs {
        abort_after = 1,
    }
    parts := []string{"HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\n\r\n", "data: one\n\n", "data: two\n\n"}
    run_fixture(t, &o, parts, 30 * time.Millisecond)

    testing.expect_value(t, o.done_count, 1)
    testing.expect_value(t, o.done_code, Code.Write_Error)
    testing.expect_value(t, o.chunk_count, 1)
    testing.expect_value(t, obs_body(&o), "data: one\n\n")
}

// `transfer_cancel` from a loop callback is terminal and silent: no further callback
// fires, the handles are gone, and the client is immediately reusable.
@(test)
test_curl_cancels_mid_stream_and_reuses_client :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    // Four frames 30 ms apart against a 150 ms grace window: at least three
    // writes fall after the cancel, so a driver that kept delivering would be
    // seen doing it.
    f := Fake {
        parts = []string {
            "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\n\r\n",
            "data: one\n\n",
            "data: two\n\n",
            "data: three\n\n",
            "data: four\n\n",
        },
        gap   = 30 * time.Millisecond,
    }
    options := http_server.Options {
        host = "127.0.0.1",
        port = 0,
    }
    testing.expect_value(t, http_server.listen(&f.front, loop, options, fake_on_request, &f), http_server.Error.None)

    c: Client
    testing.expect_value(t, client_init(&c, loop), Error.None)

    cut := Obs {
        cancel_after = 1,
        grace        = 150 * time.Millisecond,
    }
    run_transfer(t, &cut, &c, &f)

    testing.expect(t, cut.canceled, "the transfer must have been canceled")
    testing.expect_value(t, cut.done_count, 0)
    testing.expect_value(t, cut.after_cancel, 0)
    testing.expect_value(t, cut.chunk_count, cut.chunks_at_cut)
    testing.expect_value(t, cut.transfer.state, Transfer_State.Canceled)
    testing.expect_value(t, len(c.live), 0)
    testing.expect(t, c.timer_op == nil, "canceling the last transfer must disarm the pump timer")

    // The same client must serve a fresh transfer against a fresh connection.
    fixture_teardown(t, &f)

    second := Fake {
        parts = []string{"HTTP/1.1 200 OK\r\ncontent-type: text/plain\r\n\r\nsecond"},
    }
    testing.expect_value(
        t,
        http_server.listen(&second.front, loop, options, fake_on_request, &second),
        http_server.Error.None,
    )

    o: Obs
    run_transfer(t, &o, &c, &second)

    testing.expect_value(t, o.done_count, 1)
    testing.expect_value(t, o.done_code, Code.Ok)
    testing.expect_value(t, obs_body(&o), "second")
    testing.expect_value(t, len(c.live), 0)
    testing.expect(t, c.timer_op == nil, "an idle client must disarm its pump timer")

    client_destroy(&c)
    fixture_teardown(t, &second)
}

// Two transfers in a row on one client exercise the reuse path through the multi
// handle. Connection reuse itself is libcurl's business and is not asserted.
@(test)
test_curl_runs_two_sequential_transfers :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    options := http_server.Options {
        host = "127.0.0.1",
        port = 0,
    }

    c: Client
    testing.expect_value(t, client_init(&c, loop), Error.None)

    first := Fake {
        parts = []string{"HTTP/1.1 200 OK\r\ncontent-type: text/plain\r\n\r\nalpha"},
    }
    testing.expect_value(
        t,
        http_server.listen(&first.front, loop, options, fake_on_request, &first),
        http_server.Error.None,
    )

    a: Obs
    run_transfer(t, &a, &c, &first)
    fixture_teardown(t, &first)

    second := Fake {
        parts = []string{"HTTP/1.1 200 OK\r\ncontent-type: text/plain\r\n\r\nbeta"},
    }
    testing.expect_value(
        t,
        http_server.listen(&second.front, loop, options, fake_on_request, &second),
        http_server.Error.None,
    )

    b: Obs
    run_transfer(t, &b, &c, &second, .Get)
    fixture_teardown(t, &second)

    testing.expect_value(t, a.done_count, 1)
    testing.expect_value(t, obs_body(&a), "alpha")
    testing.expect_value(t, b.done_count, 1)
    testing.expect_value(t, obs_body(&b), "beta")
    testing.expect_value(t, len(c.live), 0)
    testing.expect(t, c.timer_op == nil, "an idle client must disarm its pump timer")

    client_destroy(&c)
}

// An informational block in front of the real response is the multi-block case:
// each status line starts a fresh block, headers from both reach the caller, and
// the final result carries the last status, not the first.
@(test)
test_curl_delivers_two_header_blocks :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    o: Obs
    parts := []string {
        "HTTP/1.1 100 Continue\r\n\r\n",
        "HTTP/1.1 201 Created\r\ncontent-type: text/plain\r\nx-second-block: yes\r\n\r\n",
        "created",
    }
    run_fixture(t, &o, parts, 0)

    testing.expect_value(t, o.status_count, 2)
    testing.expect_value(t, o.status_seen[0], 100)
    testing.expect_value(t, o.status_seen[1], 201)
    testing.expect_value(t, o.last_status, 201)
    testing.expect_value(t, o.done_count, 1)
    testing.expect_value(t, o.done_status, 201)
    testing.expect(
        t,
        strings.contains(obs_headers(&o), "x-second-block: yes"),
        "headers of the final block must reach On_Header",
    )
    testing.expect_value(t, obs_body(&o), "created")
}

// Starting a transfer from inside `On_Done` is what a retrying engine does. It runs
// while the driver is still walking its completion scratch, so both transfers must
// finish and the pump timer must end up disarmed.
@(test)
test_curl_starts_a_transfer_from_on_done :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    options := http_server.Options {
        host = "127.0.0.1",
        port = 0,
    }

    c: Client
    testing.expect_value(t, client_init(&c, loop), Error.None)

    f := Fake {
        parts = []string{"HTTP/1.1 200 OK\r\ncontent-type: text/plain\r\n\r\nchained"},
    }
    testing.expect_value(t, http_server.listen(&f.front, loop, options, fake_on_request, &f), http_server.Error.None)

    second: Obs
    first := Obs {
        chain     = &second,
        chain_url = fmt.ctprintf("http://127.0.0.1:%d/second", http_server.bound_port(&f.front)),
    }
    run_transfer(t, &first, &c, &f)

    testing.expect_value(t, first.done_count, 1)
    testing.expect_value(t, second.chain_err, Error.None)

    // The front door serves the chained transfer from the same listener.
    f.next = 0
    f.taken = false
    f.closed = false
    ts.nbio_run_until(t, &second, obs_finished, "chained curl transfer completion")

    testing.expect_value(t, second.done_count, 1)
    testing.expect_value(t, second.done_code, Code.Ok)
    testing.expect_value(t, obs_body(&second), "chained")
    testing.expect_value(t, len(c.live), 0)
    testing.expect(t, c.timer_op == nil, "an idle client must disarm its pump timer")

    client_destroy(&c)
    fixture_teardown(t, &f)
}

// A refused connection is an operating error, not a crash: it comes back through
// the ordinary done path with curl's own code, no HTTP status, and the reason
// text libcurl wrote into the transfer's error buffer.
@(test)
test_curl_reports_connection_failure :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    // Bind an ephemeral port only to learn a number nothing is listening on.
    dead: Fake
    options := http_server.Options {
        host = "127.0.0.1",
        port = 0,
    }
    testing.expect_value(
        t,
        http_server.listen(&dead.front, loop, options, fake_on_request, &dead),
        http_server.Error.None,
    )

    port := http_server.bound_port(&dead.front)
    testing.expect(t, port > 0, "front door must have a bound port")
    fixture_teardown(t, &dead)

    c: Client
    testing.expect_value(t, client_init(&c, loop), Error.None)

    o: Obs
    o.client = &c
    request := Request {
        url    = fmt.ctprintf("http://127.0.0.1:%d/gone", port),
        method = .Get,
    }
    testing.expect_value(t, transfer_start(&o.transfer, &c, request, obs_callbacks(), &o), Error.None)

    ts.nbio_run_until(t, &o, obs_finished, "curl connection failure")

    testing.expect_value(t, o.done_count, 1)
    testing.expect_value(t, o.done_code, Code.Couldnt_Connect)
    testing.expect_value(t, o.done_status, 0)
    testing.expect_value(t, o.status_count, 0)
    testing.expect(t, o.message_len > 0, "a failed connect must carry curl's reason text")
    testing.expect_value(t, len(c.live), 0)
    testing.expect(t, c.timer_op == nil, "an idle client must disarm its pump timer")

    client_destroy(&c)
}

// `transfer_start` copies the body, so scribbling the caller's buffer the moment it
// returns cannot change what the peer receives.
@(test)
test_curl_copies_request_body :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    f := Fake {
        parts = []string{"HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\n\r\ndata: one\n\n"},
    }
    options := http_server.Options {
        host = "127.0.0.1",
        port = 0,
    }
    testing.expect_value(t, http_server.listen(&f.front, loop, options, fake_on_request, &f), http_server.Error.None)

    c: Client
    testing.expect_value(t, client_init(&c, loop), Error.None)

    body := [?]byte{'{', '"', 'a', '"', ':', '1', '}'}
    o: Obs
    o.client = &c
    req := Request {
        url    = fmt.ctprintf("http://127.0.0.1:%d/v1/messages", http_server.bound_port(&f.front)),
        body   = body[:],
        method = .Post,
    }
    testing.expect_value(t, transfer_start(&o.transfer, &c, req, obs_callbacks(), &o), Error.None)

    for &b in body {
        b = 0xff
    }

    ts.nbio_run_until(t, &o, obs_finished, "curl transfer completion")

    testing.expect_value(t, string(f.body[:f.body_len]), `{"a":1}`)
    testing.expect_value(t, o.done_code, Code.Ok)
    testing.expect_value(t, o.done_status, 200)

    client_destroy(&c)
    fixture_teardown(t, &f)
}

// A rejected header stops the request before any handle joins the multi.
@(test)
test_curl_rejects_unsendable_headers :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    c: Client
    testing.expect_value(t, client_init(&c, loop), Error.None)

    long := strings.repeat("k", HEADER_LINE_MAX, context.temp_allocator)
    cases := [?][]Header {
        {{name = "authorization", value = "Bearer x\r\nx-injected: yes"}},
        {{name = "x bad name", value = "yes"}},
        {{name = "accept", value = ""}},
        {{name = "authorization", value = long}},
    }

    for headers in cases {
        o: Obs
        o.client = &c
        request := Request {
            url     = "http://127.0.0.1:1/v1/messages",
            headers = headers,
            method  = .Get,
        }
        testing.expect_value(t, transfer_start(&o.transfer, &c, request, obs_callbacks(), &o), Error.Invalid_Request)
        testing.expect_value(t, len(c.live), 0)
        testing.expect_value(t, o.done_count, 0)
    }

    client_destroy(&c)
}

// `field_name_valid` and `field_value_valid` are copies of the `libs:http` originals,
// duplicated so a binding depends on nothing but its C library. They guard against
// header injection, so a copy that silently drifted from the original would be a
// security regression rather than a style problem. This pins them to it over the
// whole byte range; the dependency is test-only and never reaches a consumer.
@(test)
test_field_validators_match_libs_http :: proc(t: ^testing.T) {
    for c in 0 ..= 255 {
        one := string([]byte{u8(c)})

        testing.expectf(
            t,
            field_name_valid(one) == http.field_name_valid(one),
            "field_name_valid disagrees with libs:http on byte %d",
            c,
        )
        testing.expectf(
            t,
            field_value_valid(one) == http.field_value_valid(one),
            "field_value_valid disagrees with libs:http on byte %d",
            c,
        )
    }

    samples := [?]string {
        "",
        "authorization",
        "x-api-key",
        "x bad name",
        "colon:inside",
        "Bearer token",
        "value\r\nx-injected: yes",
        "trailing\t",
    }

    for s in samples {
        testing.expectf(
            t,
            field_name_valid(s) == http.field_name_valid(s),
            "field_name_valid disagrees with libs:http on %q",
            s,
        )
        testing.expectf(
            t,
            field_value_valid(s) == http.field_value_valid(s),
            "field_value_valid disagrees with libs:http on %q",
            s,
        )
    }
}

// --- Connect-only sockets ------------------------------------------------------

// Drive a `Connect_Only` handle on `multi` until its transfer completes, and report
// that transfer's own result.
connect_only_dial :: proc(easy: ^Easy, multi: ^Multi, url: cstring) -> Code {
    if code := setopt_str(easy, .Url, url); code != .Ok {
        return code
    }

    if code := setopt_long(easy, .Connect_Only, 1); code != .Ok {
        return code
    }

    if mcode := c_multi_add_handle(multi, easy); mcode != .Ok {
        return .Failed_Init
    }

    deadline := time.time_add(time.now(), 5 * time.Second)
    for time.diff(time.now(), deadline) > 0 {
        running, mcode := multi_perform(multi)
        if mcode != .Ok && mcode != .Call_Multi_Perform {
            return .Failed_Init
        }

        for {
            msg, _ := multi_info_read(multi)
            if msg == nil {
                break
            }

            if msg.kind == .Done && msg.easy == easy {
                return msg.data.result
            }
        }

        if running == 0 {
            break
        }

        time.sleep(time.Millisecond)
    }

    return .Operation_Timedout
}

// Listener plus the connected curl handle that dialed it, with the accepted peer.
Connect_Only_Pair :: struct {
    listener: net.TCP_Socket,
    peer:     net.TCP_Socket,
    easy:     ^Easy,
    multi:    ^Multi,
}

connect_only_pair :: proc(t: ^testing.T) -> (p: Connect_Only_Pair, ok: bool) {
    sync.once_do(&global_init_once, global_init)

    listener, lerr := net.listen_tcp({address = net.IP4_Loopback, port = 0})
    if lerr != nil {
        testing.expectf(t, false, "listen failed: %v", lerr)
        return {}, false
    }

    endpoint, eerr := net.bound_endpoint(listener)
    if eerr != nil {
        net.close(listener)
        testing.expectf(t, false, "bound_endpoint failed: %v", eerr)
        return {}, false
    }

    p.listener = listener
    p.easy = c_easy_init()
    p.multi = c_multi_init()

    url := fmt.ctprintf("http://127.0.0.1:%d/", endpoint.port)
    if code := connect_only_dial(p.easy, p.multi, url); code != .Ok {
        testing.expectf(t, false, "connect-only dial failed: %v", code)
        connect_only_pair_destroy(&p)
        return {}, false
    }

    // The TCP handshake completed into the listen backlog, so this does not block.
    peer, _, aerr := net.accept_tcp(listener)
    if aerr != nil {
        testing.expectf(t, false, "accept failed: %v", aerr)
        connect_only_pair_destroy(&p)
        return {}, false
    }

    p.peer = peer

    return p, true
}

connect_only_pair_destroy :: proc(p: ^Connect_Only_Pair) {
    if p.easy != nil {
        c_easy_cleanup(p.easy)
    }

    if p.multi != nil {
        c_multi_cleanup(p.multi)
    }

    if p.peer != 0 {
        net.close(p.peer)
    }

    if p.listener != 0 {
        net.close(p.listener)
    }
}

// The control: a `Connect_Only` handle still on the multi can send.
@(test)
test_connect_only_sends_while_attached :: proc(t: ^testing.T) {
    p, ok := connect_only_pair(t)
    if !ok {
        return
    }
    defer connect_only_pair_destroy(&p)

    payload := "ping"
    sent: c.size_t
    code := c_easy_send(p.easy, raw_data(payload), len(payload), &sent)
    testing.expect_value(t, code, Code.Ok)
    testing.expect_value(t, int(sent), len(payload))

    buf: [16]byte
    n, rerr := net.recv_tcp(p.peer, buf[:])
    testing.expect_value(t, rerr, nil)
    testing.expect_value(t, string(buf[:n]), payload)
}

// `curl_multi_remove_handle` destroys a `Connect_Only` connection: the active socket
// goes to `-1` and the handle can no longer send. So a parked socket has to stay added
// to the multi for its whole life, and keeping the pump timer off it is the caller's
// job rather than something detaching can buy.
@(test)
test_connect_only_dies_on_multi_remove :: proc(t: ^testing.T) {
    p, ok := connect_only_pair(t)
    if !ok {
        return
    }
    defer connect_only_pair_destroy(&p)

    testing.expect_value(t, c_multi_remove_handle(p.multi, p.easy), Multi_Code.Ok)

    sock, icode := getinfo_socket(p.easy, .Active_Socket)
    testing.expect_value(t, icode, Code.Ok)
    testing.expect_value(t, int(sock), -1)

    payload := "ping"
    sent: c.size_t
    testing.expect_value(t, c_easy_send(p.easy, raw_data(payload), len(payload), &sent), Code.Unsupported_Protocol)
    testing.expect_value(t, int(sent), 0)
}

// A parked connect-only handle asks nothing of the pump: curl reports no timeout and
// no running transfer, and `curl_easy_send`/`curl_easy_recv` work with no
// `curl_multi_perform` in between. `client_period` maps that `-1` to `TICK_MAX`, so
// such a handle must stay out of the live set or it arms a 10ms timer forever.
@(test)
test_connect_only_parked_asks_nothing_of_the_pump :: proc(t: ^testing.T) {
    p, ok := connect_only_pair(t)
    if !ok {
        return
    }
    defer connect_only_pair_destroy(&p)

    for _ in 0 ..< 3 {
        ms, code := multi_timeout_ms(p.multi)
        testing.expect_value(t, code, Multi_Code.Ok)
        testing.expect_value(t, ms, -1)

        running, mcode := multi_perform(p.multi)
        testing.expect_value(t, mcode, Multi_Code.Ok)
        testing.expect_value(t, running, 0)
    }

    // Never pumped since the dial completed, yet the socket still works.
    payload := "ping"
    sent: c.size_t
    testing.expect_value(t, c_easy_send(p.easy, raw_data(payload), len(payload), &sent), Code.Ok)

    buf: [16]byte
    n, rerr := net.recv_tcp(p.peer, buf[:])
    testing.expect_value(t, rerr, nil)
    testing.expect_value(t, string(buf[:n]), payload)
}

// What a dial reported, so a test can wait on the loop and then assert.
Dial_Obs :: struct {
    socket: Socket,
    calls:  int,
    code:   Code,
    done:   bool,
}

dial_on_connect :: proc(user: rawptr, result: Result) {
    o := (^Dial_Obs)(user)
    o.calls += 1
    o.code = result.code
    o.done = true
}

// The whole point of the connect-only socket: it dials on the loop, then carries raw
// bytes with no pump behind it. The dropped timer is what makes an idle session free.
@(test)
test_socket_connects_and_carries_bytes :: proc(t: ^testing.T) {
    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    listener, lerr := net.listen_tcp({address = net.IP4_Loopback, port = 0})
    testing.expect_value(t, lerr, nil)
    defer net.close(listener)

    endpoint, eerr := net.bound_endpoint(listener)
    testing.expect_value(t, eerr, nil)

    o: Dial_Obs
    url := fmt.ctprintf("http://127.0.0.1:%d/", endpoint.port)
    testing.expect_value(t, socket_connect(&o.socket, loop, {url = url}, dial_on_connect, &o), Error.None)
    defer socket_destroy(&o.socket)

    nbio.run_until(&o.done)

    testing.expect_value(t, o.calls, 1)
    testing.expect_value(t, o.code, Code.Ok)
    testing.expect_value(t, o.socket.state, Socket_State.Connected)
    testing.expect(t, o.socket.timer_op == nil, "a connected socket must leave no timer armed")
    testing.expect(t, socket_handle(&o.socket) != SOCKET_BAD, "a connected socket has a real handle")

    peer, _, aerr := net.accept_tcp(listener)
    testing.expect_value(t, aerr, nil)
    defer net.close(peer)

    sent, scode := socket_send(&o.socket, transmute([]byte)string("ping"))
    testing.expect_value(t, scode, Code.Ok)
    testing.expect_value(t, sent, 4)

    buf: [16]byte
    n, rerr := net.recv_tcp(peer, buf[:])
    testing.expect_value(t, rerr, nil)
    testing.expect_value(t, string(buf[:n]), "ping")

    _, serr := net.send_tcp(peer, transmute([]byte)string("pong"))
    testing.expect_value(t, serr, nil)

    // The peer's bytes have to land before a non-blocking read can see them, and
    // there is no completion to wait on: this is exactly the readiness wait the ws
    // pipe will do with `nbio.poll`.
    got: int
    for _ in 0 ..< 200 {
        received, code := socket_recv(&o.socket, buf[:])
        if code == .Ok && received > 0 {
            got = received
            break
        }

        testing.expect_value(t, code, Code.Again)
        time.sleep(time.Millisecond)
    }

    testing.expect_value(t, string(buf[:got]), "pong")
}

// A refused dial reports through the same callback and leaves nothing armed.
@(test)
test_socket_dial_failure_reports_once :: proc(t: ^testing.T) {
    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    // Bind and close to get a port nothing is listening on.
    probe, lerr := net.listen_tcp({address = net.IP4_Loopback, port = 0})
    testing.expect_value(t, lerr, nil)
    endpoint, eerr := net.bound_endpoint(probe)
    testing.expect_value(t, eerr, nil)
    net.close(probe)

    o: Dial_Obs
    url := fmt.ctprintf("http://127.0.0.1:%d/", endpoint.port)
    testing.expect_value(t, socket_connect(&o.socket, loop, {url = url}, dial_on_connect, &o), Error.None)
    defer socket_destroy(&o.socket)

    nbio.run_until(&o.done)

    testing.expect_value(t, o.calls, 1)
    testing.expect_value(t, o.code, Code.Couldnt_Connect)
    testing.expect_value(t, o.socket.state, Socket_State.Failed)
    testing.expect(t, o.socket.timer_op == nil, "a failed dial must leave no timer armed")
}

// `socket_destroy` mid-dial is final and silent, like `nbio.remove`.
@(test)
test_socket_destroy_during_dial_is_silent :: proc(t: ^testing.T) {
    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    listener, lerr := net.listen_tcp({address = net.IP4_Loopback, port = 0})
    testing.expect_value(t, lerr, nil)
    defer net.close(listener)

    endpoint, eerr := net.bound_endpoint(listener)
    testing.expect_value(t, eerr, nil)

    o: Dial_Obs
    url := fmt.ctprintf("http://127.0.0.1:%d/", endpoint.port)
    testing.expect_value(t, socket_connect(&o.socket, loop, {url = url}, dial_on_connect, &o), Error.None)

    socket_destroy(&o.socket)
    testing.expect_value(t, o.socket.state, Socket_State.Closed)

    // Nothing is left to run; any stray callback would have to come from the loop.
    for _ in 0 ..< 20 {
        nbio.tick(time.Millisecond)
    }

    testing.expect_value(t, o.calls, 0)
}
