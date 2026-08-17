package provider

import "core:fmt"
import "core:mem"
import "core:nbio"
import "core:net"
import "core:strings"
import "core:testing"
import "core:time"
import "libs:bindings/curl"
import "libs:http"
import http_server "libs:http/server"
import ts "libs:testsupport"
import "src:wire"

// Loopback provider that writes one canned HTTP response in caller-supplied
// pieces. Hijacking keeps the fixture focused on curl and provider semantics.
@(private = "file")
Turn_Fake :: struct {
    // HTTP front door used only for accepting and parsing the request.
    front:           http_server.Server,
    // Raw response pieces written in order.
    parts:           []string,
    // Delay before each piece after the first.
    gap:             time.Duration,
    // Armed delay before the next response piece.
    gap_op:          ^nbio.Operation,
    // Next response piece.
    next:            int,
    // Hijacked peer socket.
    socket:          net.TCP_Socket,
    // Event loop that owns the socket.
    loop:            ^nbio.Event_Loop,
    // Whether the request was accepted and the socket adopted.
    taken:           bool,
    // Whether socket close has started.
    closed:          bool,
    // Request metadata captured before the HTTP connection was released.
    request_count:   int,
    request_path:    [128]byte,
    request_path_n:  int,
    // Request-header contract observed by the fake provider.
    content_type:    [64]byte,
    content_type_n:  int,
    accept:          [64]byte,
    accept_n:        int,
    version:         [64]byte,
    version_n:       int,
    authorization:   [128]byte,
    authorization_n: int,
}

@(private = "file")
turn_fake_capture_header :: proc(dst: []byte, head: http.Request_Head, name: string) -> int {
    value, lookup := http.request_header(head, name)
    if lookup != .One {
        return 0
    }

    return copy(dst, value)
}

@(private = "file")
turn_fake_on_request :: proc(c: ^http_server.Conn, request: http_server.Request) {
    fake := (^Turn_Fake)(c.server.user_data)
    assert(fake != nil, "provider fixture needs its fake")
    assert(!fake.taken, "provider fixture accepts one request")

    fake.request_count += 1
    fake.request_path_n = copy(fake.request_path[:], request.path)
    fake.content_type_n = turn_fake_capture_header(fake.content_type[:], request.head, "content-type")
    fake.accept_n = turn_fake_capture_header(fake.accept[:], request.head, "accept")
    fake.version_n = turn_fake_capture_header(fake.version[:], request.head, "anthropic-version")
    fake.authorization_n = turn_fake_capture_header(fake.authorization[:], request.head, "authorization")
    fake.socket, fake.loop, _ = http_server.hijack(c)
    fake.taken = true

    turn_fake_send_next(fake)
}

@(private = "file")
turn_fake_send_next :: proc(fake: ^Turn_Fake) {
    assert(fake != nil, "provider fixture send needs its fake")
    assert(fake.taken, "provider fixture send needs a hijacked socket")

    if fake.next >= len(fake.parts) {
        turn_fake_close(fake)
        return
    }

    part := fake.parts[fake.next]
    fake.next += 1
    nbio.send_poly(
        fake.socket,
        [][]byte{transmute([]byte)part},
        fake,
        turn_fake_on_sent,
        {},
        true,
        nbio.NO_TIMEOUT,
        fake.loop,
    )
}

@(private = "file")
turn_fake_on_sent :: proc(op: ^nbio.Operation, fake: ^Turn_Fake) {
    assert(fake != nil, "provider fixture send completion needs its fake")

    if op.send.err != nil {
        turn_fake_close(fake)
        return
    }

    if fake.gap > 0 && fake.next < len(fake.parts) {
        fake.gap_op = nbio.timeout_poly(fake.gap, fake, turn_fake_on_gap, fake.loop)
        return
    }

    turn_fake_send_next(fake)
}

@(private = "file")
turn_fake_on_gap :: proc(op: ^nbio.Operation, fake: ^Turn_Fake) {
    assert(fake.gap_op == op, "provider fixture gap fired for an operation it does not own")
    fake.gap_op = nil

    turn_fake_send_next(fake)
}

@(private = "file")
turn_fake_close :: proc(fake: ^Turn_Fake) {
    assert(fake != nil, "provider fixture close needs its fake")

    if fake.closed || !fake.taken {
        return
    }

    if fake.gap_op != nil {
        nbio.remove(fake.gap_op)
        fake.gap_op = nil
    }

    fake.closed = true
    nbio.close(fake.socket, turn_fake_on_closed, fake.loop)
}

@(private = "file")
turn_fake_on_closed :: proc(op: ^nbio.Operation) {
}

@(private = "file")
turn_fake_path :: proc(fake: ^Turn_Fake) -> string {
    return string(fake.request_path[:fake.request_path_n])
}

@(private = "file")
turn_fake_content_type :: proc(fake: ^Turn_Fake) -> string {
    return string(fake.content_type[:fake.content_type_n])
}

@(private = "file")
turn_fake_accept :: proc(fake: ^Turn_Fake) -> string {
    return string(fake.accept[:fake.accept_n])
}

@(private = "file")
turn_fake_version :: proc(fake: ^Turn_Fake) -> string {
    return string(fake.version[:fake.version_n])
}

@(private = "file")
turn_fake_authorization :: proc(fake: ^Turn_Fake) -> string {
    return string(fake.authorization[:fake.authorization_n])
}

@(private = "file")
Observed_Event :: enum {
    Start,
    Text,
    Reasoning,
    Stop,
    Done,
}

// Callback observations use fixed storage so no borrowed event data escapes
// the callback and the fixture remains leak-clean.
@(private = "file")
Turn_Obs :: struct {
    // Turn being exercised.
    turn:                Turn,
    // Provider client, retained so callbacks can check/cancel the turn.
    client:              ^Client,
    // Event kinds in delivery order.
    events:              [8]Observed_Event,
    // Number of delivered events.
    event_count:         int,
    // Concatenated text deltas.
    text:                [256]byte,
    // Used prefix of `text`.
    text_n:              int,
    // Terminal stream metadata.
    reason:              Stop_Reason,
    usage:               Usage,
    tool_call_count:     int,
    // Attempt completion observation.
    done_count:          int,
    done_at_event_count: int,
    result:              Turn_Result,
    // Cancellation behavior requested by a test.
    cancel_on_event:     bool,
    canceled:            bool,
    state_at_cancel:     Turn_State,
    // Set once the test can stop driving nbio.
    finished:            bool,
}

@(private = "file")
turn_obs_finished :: proc(obs: ^Turn_Obs) -> bool {
    return obs.finished
}

@(private = "file")
turn_obs_record :: proc(obs: ^Turn_Obs, kind: Observed_Event) {
    assert(obs != nil, "provider event observation needs state")
    assert(obs.event_count < len(obs.events), "provider test event storage is large enough")

    obs.events[obs.event_count] = kind
    obs.event_count += 1
}

@(private = "file")
turn_obs_on_event :: proc(user: rawptr, event: Stream_Event) {
    obs := (^Turn_Obs)(user)
    assert(obs != nil, "provider event callback needs state")
    assert(obs.client != nil, "provider event callback needs its client")

    switch value in event {
    case Stream_Block_Started:
        turn_obs_record(obs, .Start)

    case Stream_Text_Delta:
        turn_obs_record(obs, .Text)
        obs.text_n += copy(obs.text[obs.text_n:], value.text)

    case Stream_Reasoning_Delta:
        turn_obs_record(obs, .Reasoning)
        obs.text_n += copy(obs.text[obs.text_n:], value.text)

    case Stream_Block_Stopped:
        turn_obs_record(obs, .Stop)

        if _, tool := value.result.(Stream_Tool_Block); tool {
            obs.tool_call_count += 1
        }

    case Stream_Done:
        turn_obs_record(obs, .Done)
        obs.reason = value.reason
        obs.usage = value.usage
    }

    if obs.cancel_on_event && !obs.canceled {
        obs.canceled = true
        obs.state_at_cancel = obs.turn.state
        turn_cancel(&obs.turn)
        obs.finished = true
    }
}

@(private = "file")
turn_obs_on_done :: proc(user: rawptr, result: Turn_Result) {
    obs := (^Turn_Obs)(user)
    assert(obs != nil, "provider completion callback needs state")
    assert(!obs.canceled, "a canceled provider turn must stay silent")

    obs.done_count += 1
    obs.done_at_event_count = obs.event_count
    obs.result = result
    obs.finished = true
}

@(private = "file")
turn_obs_callbacks :: proc() -> Turn_Callbacks {
    return {on_event = turn_obs_on_event, on_done = turn_obs_on_done}
}

@(private = "file")
turn_obs_text :: proc(obs: ^Turn_Obs) -> string {
    return string(obs.text[:obs.text_n])
}

// Completion observer that restarts the same caller-owned Turn once.
@(private = "file")
Turn_Restart_Obs :: struct {
    // Turn and client reused from the first completion callback.
    turn:        Turn,
    client:      ^Client,
    // Prebuilt second request, whose strings outlive both attempts.
    next:        Turn_Request,
    // Results in callback order.
    results:     [2]Turn_Result,
    done_count:  int,
    // Synchronous outcome of the restart.
    restart_err: Transport_Error,
    // Set after the second completion or a failed restart.
    finished:    bool,
}

@(private = "file")
turn_restart_finished :: proc(obs: ^Turn_Restart_Obs) -> bool {
    return obs.finished
}

@(private = "file")
turn_restart_on_done :: proc(user: rawptr, result: Turn_Result) {
    obs := (^Turn_Restart_Obs)(user)
    assert(obs != nil, "provider restart callback needs state")
    assert(obs.done_count < len(obs.results), "provider restart callback count stays bounded")

    obs.results[obs.done_count] = result
    obs.done_count += 1
    if obs.done_count == 1 {
        obs.restart_err = turn_start(
            &obs.turn,
            obs.client,
            obs.next,
            Turn_Callbacks{on_done = turn_restart_on_done},
            obs,
        )
        if obs.restart_err != .None {
            obs.finished = true
        }

        return
    }

    obs.finished = true
}

@(private = "file")
turn_response :: proc(status: string, headers: string, body: string) -> string {
    return fmt.tprintf("HTTP/1.1 %s\r\ncontent-length: %d\r\n%s\r\n%s", status, len(body), headers, body)
}

@(private = "file")
turn_fixture_teardown :: proc(t: ^testing.T, fake: ^Turn_Fake) {
    turn_fake_close(fake)
    http_server.shutdown(&fake.front)
    ts.nbio_run_until(t, &fake.front.shutdown_complete, "provider fixture shutdown")
    http_server.destroy(&fake.front)
}

// Full loopback lifecycle for one provider attempt.
@(private = "file")
turn_run_fixture :: proc(
    t: ^testing.T,
    obs: ^Turn_Obs,
    parts: []string,
    gap: time.Duration = 0,
    protocol: wire.Provider_Protocol = .Anthropic_Messages,
    deliver_events := true,
    max_response_bytes := DEFAULT_MAX_RESPONSE_BYTES,
) -> Turn_Fake {
    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    fake := Turn_Fake {
        parts = parts,
        gap   = gap,
    }
    options := http_server.Options {
        host = "127.0.0.1",
        port = 0,
    }
    testing.expect_value(
        t,
        http_server.listen(&fake.front, loop, options, turn_fake_on_request, &fake),
        http_server.Error.None,
    )

    port := http_server.bound_port(&fake.front)
    testing.expect(t, port > 0, "provider fixture must have a bound port")

    client: Client
    testing.expect_value(t, client_init(&client, loop, max_response_bytes = max_response_bytes), Transport_Error.None)

    obs.client = &client
    request := Turn_Request {
        connection = Connection {
            endpoint = Endpoint{base_url = fmt.tprintf("http://127.0.0.1:%d/v1", port), protocol = protocol},
            auth = Api_Key{key = "test-secret"},
        },
        body = `{"stream":true}`,
    }
    callbacks := turn_obs_callbacks()
    if !deliver_events {
        callbacks.on_event = nil
    }

    testing.expect_value(t, turn_start(&obs.turn, &client, request, callbacks, obs), Transport_Error.None)
    testing.expect(t, client_busy(&client), "a started provider turn must register with its client")

    ts.nbio_run_until(t, obs, turn_obs_finished, "provider turn completion")

    testing.expect(t, !client_busy(&client), "a terminal provider turn must release its client")
    client_destroy(&client)
    turn_fixture_teardown(t, &fake)

    return fake
}

TURN_SUCCESS_BODY :: `data: {"type":"message_start","message":{"usage":{"input_tokens":3}}}

data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hello"}}

data: {"type":"content_block_stop","index":0}

data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":2}}

data: {"type":"message_stop"}

`

// A complete response can decode several events and complete curl in one pump;
// every event must still precede the terminal callback and retain its bytes.
@(test)
test_provider_turn_streams_and_completes_in_order :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    obs: Turn_Obs
    response := turn_response("200 OK", "content-type: text/event-stream\r\n", TURN_SUCCESS_BODY)
    fake := turn_run_fixture(t, &obs, []string{response})

    testing.expect_value(t, obs.event_count, 4)
    testing.expect_value(t, obs.events[0], Observed_Event.Start)
    testing.expect_value(t, obs.events[1], Observed_Event.Text)
    testing.expect_value(t, obs.events[2], Observed_Event.Stop)
    testing.expect_value(t, obs.events[3], Observed_Event.Done)
    testing.expect_value(t, turn_obs_text(&obs), "hello")
    testing.expect_value(t, obs.reason, Stop_Reason.End_Turn)
    testing.expect_value(t, obs.usage.input, u64(3))
    testing.expect_value(t, obs.usage.output, u64(2))
    testing.expect_value(t, obs.usage.total, u64(5))
    testing.expect_value(t, obs.done_count, 1)
    testing.expect_value(t, obs.done_at_event_count, 4)
    testing.expect_value(t, obs.result.err, Transport_Error.None)
    testing.expect_value(t, obs.turn.state, Turn_State.Done)

    testing.expect_value(t, fake.request_count, 1)
    testing.expect_value(t, turn_fake_path(&fake), "/v1/messages")
    testing.expect_value(t, turn_fake_content_type(&fake), "application/json")
    testing.expect_value(t, turn_fake_accept(&fake), "text/event-stream")
    testing.expect_value(t, turn_fake_version(&fake), ANTHROPIC_VERSION)
    testing.expect_value(t, turn_fake_authorization(&fake), "Bearer test-secret")
}

// EOF before message_stop is an error, but output already decoded before EOF
// still dispatches before the failure callback.
@(test)
test_provider_turn_delivers_partial_output_before_truncation :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    body := `data: {"type":"message_start","message":{"usage":{}}}

data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"partial"}}

`
    response := fmt.tprintf("HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\n\r\n%s", body)
    obs: Turn_Obs
    _ = turn_run_fixture(t, &obs, []string{response})

    testing.expect_value(t, obs.event_count, 2)
    testing.expect_value(t, obs.events[0], Observed_Event.Start)
    testing.expect_value(t, obs.events[1], Observed_Event.Text)
    testing.expect_value(t, turn_obs_text(&obs), "partial")
    testing.expect_value(t, obs.done_at_event_count, 2)
    testing.expect_value(t, obs.result.err, Transport_Error.Stream_Truncated)
}

// The provider's decode error must override curl's generic Write_Error caused
// by our body callback returning false.
@(test)
test_provider_turn_preserves_decode_and_provider_errors :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    Case :: struct {
        body: string,
        want: Transport_Error,
    }

    cases := [?]Case {
        {"data: {not-json}\n\n", .Parse_Error},
        {`data: {"type":"error","error":{"type":"overloaded_error"}}

`, .Server_Error},
    }

    for c in cases {
        obs: Turn_Obs
        response := turn_response("200 OK", "content-type: text/event-stream\r\n", c.body)
        _ = turn_run_fixture(t, &obs, []string{response})

        testing.expect_value(t, obs.event_count, 0)
        testing.expect_value(t, obs.done_count, 1)
        testing.expectf(t, obs.result.err == c.want, "want %v, got %v", c.want, obs.result.err)
    }
}

// Retry-After is delta-seconds only, preserves zero, and saturates at the
// transport's confirmed 120-second cap.
@(test)
test_provider_turn_rate_limit_retry_after_semantics :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    Case :: struct {
        value: string,
        want:  time.Duration,
    }

    cases := [?]Case{{"0", 0}, {"999999999999999999999999", RETRY_AFTER_CAP}}

    for c in cases {
        body := `{"error":{"type":"rate_limit_error"}}`
        headers := fmt.tprintf("content-type: application/json\r\nretry-after: %s\r\n", c.value)
        response := turn_response("429 Too Many Requests", headers, body)
        obs: Turn_Obs
        _ = turn_run_fixture(t, &obs, []string{response})

        testing.expect_value(t, obs.result.err, Transport_Error.Rate_Limited)
        after, present := obs.result.retry_after.?
        testing.expect(t, present, "valid Retry-After must remain present")
        testing.expect_value(t, after, c.want)
    }
}

// A 429 quota discriminator is terminal and carries no retry delay even when
// the response includes Retry-After.
@(test)
test_provider_turn_distinguishes_quota_exhaustion :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    body := `{"error":{"type":"insufficient_quota"}}`
    response := turn_response("429 Too Many Requests", "content-type: application/json\r\nretry-after: 7\r\n", body)
    obs: Turn_Obs
    _ = turn_run_fixture(t, &obs, []string{response})

    testing.expect_value(t, obs.result.err, Transport_Error.Quota_Exhausted)
    _, present := obs.result.retry_after.?
    testing.expect(t, !present, "terminal quota exhaustion must not suggest a retry delay")
}

// Any non-identity encoding is rejected even if another duplicate field says
// identity; accepting the latter would feed compressed bytes into the SSE parser.
@(test)
test_provider_turn_rejects_unsupported_content_encoding :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    response := turn_response(
        "200 OK",
        "content-type: text/event-stream\r\ncontent-encoding: gzip\r\ncontent-encoding: identity\r\n",
        TURN_SUCCESS_BODY,
    )
    obs: Turn_Obs
    _ = turn_run_fixture(t, &obs, []string{response})

    testing.expect_value(t, obs.event_count, 0)
    testing.expect_value(t, obs.result.err, Transport_Error.Unsupported_Content_Encoding)
}

// Cancellation from on_event is legal because dispatch runs outside curl. It
// drops all later queued events, releases the client, and never calls on_done.
@(test)
test_provider_turn_cancels_from_event_callback :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    obs := Turn_Obs {
        cancel_on_event = true,
    }
    response := turn_response("200 OK", "content-type: text/event-stream\r\n", TURN_SUCCESS_BODY)
    _ = turn_run_fixture(t, &obs, []string{response})

    testing.expect(t, obs.canceled, "first event must cancel the turn")
    testing.expect_value(t, obs.state_at_cancel, Turn_State.Completing)
    testing.expect_value(t, obs.event_count, 1)
    testing.expect_value(t, obs.events[0], Observed_Event.Start)
    testing.expect_value(t, obs.done_count, 0)
    testing.expect_value(t, obs.turn.state, Turn_State.Canceled)
}

// A gapped response leaves curl live after the first event. Dispatch is still
// outside curl, so cancellation may synchronously remove the easy handle.
@(test)
test_provider_turn_cancels_live_curl_from_event_callback :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    parts := []string {
        "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\n\r\n",
        `data: {"type":"message_start","message":{"usage":{}}}

data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"first"}}

`,
        `data: {"type":"content_block_stop","index":0}

data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}

data: {"type":"message_stop"}

`,
    }
    obs := Turn_Obs {
        cancel_on_event = true,
    }
    _ = turn_run_fixture(t, &obs, parts, 30 * time.Millisecond)

    testing.expect(t, obs.canceled, "first live event must cancel the turn")
    testing.expect_value(t, obs.state_at_cancel, Turn_State.Running)
    testing.expect_value(t, obs.event_count, 1)
    testing.expect_value(t, obs.events[0], Observed_Event.Start)
    testing.expect_value(t, turn_obs_text(&obs), "")
    testing.expect_value(t, obs.done_count, 0)
    testing.expect_value(t, obs.turn.state, Turn_State.Canceled)
}

// OpenAI Chat with a `finish_reason` but no `[DONE]` sentinel emits its terminal
// events from `decoder_finish` at EOF. The gap drains the mid-stream queue first,
// so finish appends into an empty queue with no armed dispatch — the turn must
// still schedule those events instead of asserting an already-scheduled queue.
@(test)
test_provider_turn_schedules_finish_generated_events :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    parts := []string {
        "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\n\r\n",
        `data: {"choices":[{"delta":{"content":"hi"}}]}

data: {"choices":[{"delta":{},"finish_reason":"stop"}]}

`,
        "",
    }
    obs: Turn_Obs
    _ = turn_run_fixture(t, &obs, parts, 30 * time.Millisecond, .Openai_Chat)

    testing.expect_value(t, obs.event_count, 4)
    testing.expect_value(t, obs.events[0], Observed_Event.Start)
    testing.expect_value(t, obs.events[1], Observed_Event.Text)
    testing.expect_value(t, obs.events[2], Observed_Event.Stop)
    testing.expect_value(t, obs.events[3], Observed_Event.Done)
    testing.expect_value(t, turn_obs_text(&obs), "hi")
    testing.expect_value(t, obs.reason, Stop_Reason.End_Turn)
    testing.expect_value(t, obs.done_count, 1)
    testing.expect_value(t, obs.done_at_event_count, 4)
    testing.expect_value(t, obs.result.err, Transport_Error.None)
    testing.expect_value(t, obs.turn.state, Turn_State.Done)
}

// The same finish-generated events with no `on_event` consumer must be discarded
// cleanly: the turn completes once with no delivered events and no crash.
@(test)
test_provider_turn_discards_finish_events_without_consumer :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    parts := []string {
        "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\n\r\n",
        `data: {"choices":[{"delta":{"content":"hi"}}]}

data: {"choices":[{"delta":{},"finish_reason":"stop"}]}

`,
        "",
    }
    obs: Turn_Obs
    _ = turn_run_fixture(t, &obs, parts, 30 * time.Millisecond, .Openai_Chat, deliver_events = false)

    testing.expect_value(t, obs.event_count, 0)
    testing.expect_value(t, obs.done_count, 1)
    testing.expect_value(t, obs.result.err, Transport_Error.None)
    testing.expect_value(t, obs.turn.state, Turn_State.Done)
}

// A response whose successful body is exactly the budget is still accepted; the
// bound only rejects bytes beyond it.
@(test)
test_provider_turn_accepts_response_at_budget :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    obs: Turn_Obs
    response := turn_response("200 OK", "content-type: text/event-stream\r\n", TURN_SUCCESS_BODY)
    _ = turn_run_fixture(t, &obs, []string{response}, max_response_bytes = len(TURN_SUCCESS_BODY))

    testing.expect_value(t, obs.result.err, Transport_Error.None)
    testing.expect_value(t, turn_obs_text(&obs), "hello")
    testing.expect_value(t, obs.done_count, 1)
    testing.expect_value(t, obs.turn.state, Turn_State.Done)
}

// Many individually valid, individually bounded SSE events still fail the turn
// once their aggregate crosses the whole-response budget.
@(test)
test_provider_turn_rejects_response_over_budget :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    obs: Turn_Obs
    response := turn_response("200 OK", "content-type: text/event-stream\r\n", TURN_SUCCESS_BODY)
    _ = turn_run_fixture(t, &obs, []string{response}, max_response_bytes = len(TURN_SUCCESS_BODY) - 1)

    testing.expect_value(t, obs.result.err, Transport_Error.Response_Too_Large)
    testing.expect_value(t, obs.done_count, 1)
    testing.expect_value(t, obs.turn.state, Turn_State.Done)
}

// Finalization releases provider and curl state before on_done, so a retrying
// engine may immediately start the same Turn against another endpoint.
@(test)
test_provider_turn_restarts_same_turn_from_completion_callback :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()
    options := http_server.Options {
        host = "127.0.0.1",
        port = 0,
    }
    body := `data: {"type":"message_start","message":{"usage":{}}}

data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":0}}

data: {"type":"message_stop"}

`
    response := turn_response("200 OK", "content-type: text/event-stream\r\n", body)

    first := Turn_Fake {
        parts = []string{response},
    }
    testing.expect_value(
        t,
        http_server.listen(&first.front, loop, options, turn_fake_on_request, &first),
        http_server.Error.None,
    )

    second := Turn_Fake {
        parts = []string{response},
    }
    testing.expect_value(
        t,
        http_server.listen(&second.front, loop, options, turn_fake_on_request, &second),
        http_server.Error.None,
    )

    client: Client
    testing.expect_value(t, client_init(&client, loop), Transport_Error.None)

    first_request := Turn_Request {
        connection = Connection {
            endpoint = Endpoint {
                base_url = fmt.tprintf("http://127.0.0.1:%d/v1", http_server.bound_port(&first.front)),
                protocol = .Anthropic_Messages,
            },
        },
        body = `{}`,
    }
    obs := Turn_Restart_Obs {
        client = &client,
        next = Turn_Request {
            connection = Connection {
                endpoint = Endpoint {
                    base_url = fmt.tprintf("http://127.0.0.1:%d/v1", http_server.bound_port(&second.front)),
                    protocol = .Anthropic_Messages,
                },
            },
            body = `{}`,
        },
    }
    testing.expect_value(
        t,
        turn_start(&obs.turn, &client, first_request, Turn_Callbacks{on_done = turn_restart_on_done}, &obs),
        Transport_Error.None,
    )

    ts.nbio_run_until(t, &obs, turn_restart_finished, "provider turn restart")

    testing.expect_value(t, obs.done_count, 2)
    testing.expect_value(t, obs.restart_err, Transport_Error.None)
    testing.expect_value(t, obs.results[0].err, Transport_Error.None)
    testing.expect_value(t, obs.results[1].err, Transport_Error.None)
    testing.expect_value(t, obs.turn.state, Turn_State.Done)
    testing.expect(t, !client_busy(&client), "both restarted attempts must release the client")

    client_destroy(&client)
    turn_fixture_teardown(t, &first)
    turn_fixture_teardown(t, &second)
}

@(test)
test_provider_turn_maps_http_server_failure :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    body := `{"error":{"type":"overloaded_error"}}`
    response := turn_response("503 Service Unavailable", "content-type: application/json\r\n", body)
    obs: Turn_Obs
    _ = turn_run_fixture(t, &obs, []string{response})

    testing.expect_value(t, obs.event_count, 0)
    testing.expect_value(t, obs.result.err, Transport_Error.Server_Error)
}

// Once the classification prefix is full, the body callback deliberately
// stops curl but preserves the HTTP status instead of reporting a local abort.
@(test)
test_provider_turn_caps_error_body_without_losing_status :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    body := strings.repeat("x", MAX_ERROR_BODY_BYTES + 1, context.temp_allocator)
    response := turn_response("503 Service Unavailable", "content-type: text/plain\r\n", body)
    obs: Turn_Obs
    _ = turn_run_fixture(t, &obs, []string{response})

    testing.expect_value(t, obs.event_count, 0)
    testing.expect_value(t, obs.result.err, Transport_Error.Server_Error)
}

@(test)
test_provider_turn_rejects_unsupported_request_synchronously :: proc(t: ^testing.T) {
    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    client: Client
    testing.expect_value(t, client_init(&client, loop), Transport_Error.None)

    turn: Turn
    openai := Turn_Request {
        connection = Connection {
            endpoint = Endpoint {
                // A trailing slash is a malformed base URL; the protocol paths
                // carry their own leading slash.
                base_url = "https://api.openai.com/v1/",
                protocol = wire.Provider_Protocol.Openai_Responses,
            },
        },
        body = `{}`,
    }
    testing.expect_value(t, turn_start(&turn, &client, openai, {}, nil), Transport_Error.Invalid_Request)
    testing.expect_value(t, turn.state, Turn_State.Created)
    testing.expect(t, !client_busy(&client), "a rejected start must not register a turn")

    anthropic := openai
    anthropic.connection.endpoint.protocol = .Anthropic_Messages
    anthropic.body = ""
    testing.expect_value(t, turn_start(&turn, &client, anthropic, {}, nil), Transport_Error.Invalid_Request)
    testing.expect(t, !client_busy(&client), "an empty request body must fail before curl")

    // A configured credential is not peer input, but it is also not trusted to
    // be a single header value.
    injected := anthropic
    injected.body = `{}`
    injected.connection.auth = Api_Key {
        key = "secret\r\nx-injected: yes",
    }
    testing.expect_value(t, turn_start(&turn, &client, injected, {}, nil), Transport_Error.Invalid_Request)
    testing.expect(t, !client_busy(&client), "an unsendable credential must fail before curl")

    client_destroy(&client)
}

// A synchronous start failure leaves the turn `Created` regardless of its prior
// terminal state, so a reusing caller sees one predictable postcondition.
@(test)
test_provider_turn_invalid_restart_resets_to_created :: proc(t: ^testing.T) {
    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    client: Client
    testing.expect_value(t, client_init(&client, loop), Transport_Error.None)

    invalid := Turn_Request {
        connection = Connection{endpoint = Endpoint{base_url = "https://api.openai.com/v1", protocol = .Openai_Chat}},
        body = "",
    }

    for prior in ([?]Turn_State{.Created, .Done, .Canceled}) {
        turn := Turn {
            state = prior,
        }
        testing.expect_value(t, turn_start(&turn, &client, invalid, {}, nil), Transport_Error.Invalid_Request)
        testing.expectf(t, turn.state == .Created, "a %v turn resets to Created on invalid restart", prior)
        testing.expect(t, !client_busy(&client), "a rejected restart must not register a turn")
    }

    client_destroy(&client)
}

@(test)
test_provider_turn_request_headers :: proc(t: ^testing.T) {
    connection := Connection {
        endpoint = Endpoint{base_url = "https://api.anthropic.com/v1", protocol = .Anthropic_Messages},
        auth = Api_Key{key = "secret"},
    }

    arena: mem.Dynamic_Arena
    mem.dynamic_arena_init(&arena, context.allocator, context.allocator)
    defer mem.dynamic_arena_destroy(&arena)

    out: [MAX_REQUEST_HEADERS]curl.Header
    n, err := turn_request_headers(connection, out[:], mem.dynamic_arena_allocator(&arena))
    testing.expect_value(t, err, Transport_Error.None)
    testing.expect_value(t, n, 4)
    headers := out[:n]
    testing.expect_value(t, headers[0], curl.Header{name = "content-type", value = "application/json"})
    testing.expect_value(t, headers[1], curl.Header{name = "accept", value = "text/event-stream"})
    testing.expect_value(t, headers[2], curl.Header{name = "anthropic-version", value = "2023-06-01"})
    testing.expect_value(t, headers[3], curl.Header{name = "x-api-key", value = "secret"})
}
