package provider

import "base:runtime"
import "core:mem"
import "core:mem/virtual"
import "core:nbio"
import "core:strings"
import "core:time"
import "libs:bindings/curl"
import "libs:http/sse"

// Error-body prefix retained for HTTP status classification. Successful bodies
// remain streaming and are never accumulated.
MAX_ERROR_BODY_BYTES :: 64 * 1024

// Default whole-response byte budget. A peer can stream unlimited individually
// valid SSE events; without an aggregate bound turn memory grows unchecked. The
// per-client value is configurable so a caller may impose a tighter cap.
DEFAULT_MAX_RESPONSE_BYTES :: 64 * mem.Megabyte

// Per-block virtual reservation for a turn's scratch arena. Sized so one SSE
// event's JSON tree — bounded by the 1 MiB event cap, several times larger once
// parsed — fits without spilling into a second block, keeping each event's
// teardown a pure `Arena_Temp` watermark rewind with no commit churn.
TURN_SCRATCH_RESERVE :: 8 * mem.Megabyte

// Lifecycle of one provider attempt. Completion can wait one loop turn while
// already-decoded events drain after curl has left its callback region.
Turn_State :: enum {
    // Never started, or a failed synchronous start.
    Created,

    // Underlying curl transfer is live.
    Running,

    // Curl completed; queued events must dispatch before `on_done`.
    Completing,

    // `on_done` fired exactly once.
    Done,

    // Caller canceled; no `on_done` fires.
    Canceled,
}

// A provider request whose protocol-specific JSON body has already been built.
// `body` is copied during `turn_start`, so the caller may release it after.
Turn_Request :: struct {
    // Resolved endpoint and credential.
    connection: Connection,

    // Complete JSON request body.
    body:       string,
}

// Terminal result for one attempt.
Turn_Result :: struct {
    // Normalized transport outcome; `.None` means the protocol terminator was decoded.
    err:         Transport_Error,

    // Provider delay for a retryable rate limit, including an explicit zero.
    retry_after: Maybe(time.Duration),
}

// One decoded stream event. Its strings borrow the turn arena and are valid
// only until terminal completion or cancellation; clone anything persisted.
On_Event :: #type proc(user: rawptr, event: Stream_Event)

// Fired exactly once after a started, non-canceled attempt reaches terminal
// completion. No callback fires when synchronous start fails.
On_Done :: #type proc(user: rawptr, result: Turn_Result)

Turn_Callbacks :: struct {
    // Incremental neutral output, always outside a curl callback.
    on_event: On_Event,

    // Terminal attempt outcome, after every queued event was delivered.
    on_done:  On_Done,
}

// Provider transport client pinned to one nbio loop. `curl_client` is embedded
// so its address remains stable from `client_init` through `client_destroy`.
Client :: struct {
    // Underlying HTTPS/multi driver.
    curl_client:        curl.Client,

    // Event loop used to defer stream-event dispatch.
    loop:               ^nbio.Event_Loop,

    // Backing allocator for the curl client's own state. Per-turn memory is
    // OS-backed virtual arenas, not drawn from here.
    allocator:          runtime.Allocator,

    // Whole-response byte budget applied to every turn's successful body.
    max_response_bytes: int,

    // Started provider turns, including curl-complete turns draining events.
    live_count:         int,
}

// One single-attempt provider turn. Caller-allocated and address-pinned while
// Running or Completing because curl and nbio both retain its address.
Turn :: struct {
    // Underlying transfer; must not move while live.
    transfer:                     curl.Transfer,

    // Owning provider client.
    client:                       ^Client,

    // Turn lifetime: request URL and headers, SSE parser state, decoder-retained
    // strings, queued events, and the error-body prefix. Freed at turn cleanup.
    retained:                     virtual.Arena,

    // One decode or classify call: the JSON tree and anything else that dies
    // with it. Each use is an `Arena_Temp` watermark rewound after the call, so
    // committed pages are reused across events. Never aliases `retained`.
    scratch:                      virtual.Arena,

    // Incremental SSE framing state.
    sse_parser:                   sse.Parser,

    // Protocol-specific streaming decoder. Unsupported protocols are rejected
    // in `turn_start` before this is initialized.
    decoder:                      Provider_Decoder,

    // Neutral events waiting for out-of-curl dispatch.
    events:                       [dynamic]Stream_Event,

    // Accumulated successful-body bytes, bounded by the client budget.
    response_bytes:               int,

    // Bounded non-2xx body prefix for 429 classification.
    error_body:                   [dynamic]byte,

    // The non-2xx body exceeded its retained prefix and curl was stopped.
    error_body_capped:            bool,

    // Engine callbacks.
    callbacks:                    Turn_Callbacks,

    // Opaque engine owner passed to callbacks.
    user:                         rawptr,

    // Provider-level lifecycle.
    state:                        Turn_State,

    // Zero-delay event-dispatch operation, at most one armed.
    dispatch_op:                  ^nbio.Operation,

    // Guards cancellation cleanup while an event borrow is on the stack.
    dispatching:                  bool,

    // Final response status; each new header block replaces it.
    status:                       int,

    // First decode/SSE/body-callback failure, which overrides curl Write_Error.
    callback_error:               Transport_Error,

    // Parsed delta-seconds Retry-After from the final header block.
    retry_after:                  Maybe(time.Duration),

    // Final header block named a non-identity content encoding.
    unsupported_content_encoding: bool,

    // Whether the SSE parser needs teardown.
    parser_initialized:           bool,
}

// Initialize a provider client on `loop`.
client_init :: proc(
    c: ^Client,
    loop: ^nbio.Event_Loop,
    allocator := context.allocator,
    max_response_bytes := DEFAULT_MAX_RESPONSE_BYTES,
) -> Transport_Error {
    assert(c != nil, "provider client_init needs a client")
    assert(loop != nil, "provider client_init needs an event loop")
    assert(allocator.procedure != nil, "provider client_init needs a valid allocator")
    assert(max_response_bytes > 0, "provider client_init needs a positive response budget")
    assert(c.loop == nil, "provider client_init on an initialized client")

    err := curl.client_init(&c.curl_client, loop, allocator)
    if err != .None do return turn_error_from_curl_start(err)

    c.loop = loop
    c.allocator = allocator
    c.max_response_bytes = max_response_bytes
    c.live_count = 0

    return .None
}

// Destroy an idle provider client.
client_destroy :: proc(c: ^Client) {
    assert(c != nil, "provider client_destroy needs a client")
    assert(c.loop != nil, "provider client_destroy on an uninitialized client")
    assert(c.live_count == 0, "provider client_destroy with live turns")
    assert(!curl.client_busy(&c.curl_client), "provider and curl live-turn counts disagree")

    curl.client_destroy(&c.curl_client)
    c^ = {}
}

// True while a provider turn is live or draining queued events.
client_busy :: proc(c: ^Client) -> bool {
    assert(c != nil, "provider client_busy needs a client")
    assert(c.loop != nil, "provider client_busy needs an initialized client")
    assert(c.live_count >= 0, "provider live-turn count cannot be negative")

    return c.live_count > 0
}

// Start one prebuilt streaming request. On failure no callback fires and the
// turn is left `Created`, whether it was fresh or reused; on success exactly one
// `on_done` follows unless the caller cancels.
turn_start :: proc(
    turn: ^Turn,
    client: ^Client,
    request: Turn_Request,
    callbacks: Turn_Callbacks,
    user: rawptr,
) -> (
    err: Transport_Error,
) {
    assert(turn != nil, "provider turn_start needs a turn")
    assert(client != nil, "provider turn_start needs a client")
    assert(client.loop != nil, "provider turn_start needs an initialized client")
    assert(!turn.dispatching, "a turn cannot restart from inside its own event callback")
    assert(turn.state != .Running && turn.state != .Completing, "provider turn_start on a live turn")

    // Reset before validating so every synchronous-start failure — fresh turn or
    // reused terminal turn — leaves the same `Created` postcondition.
    turn^ = {
        client    = client,
        callbacks = callbacks,
        user      = user,
        state     = .Created,
    }

    ep := request.connection.endpoint
    if endpoint_validate(ep) != .None || !protocol_supported(ep.protocol) || len(request.body) == 0 do return .Invalid_Request

    defer if err != .None do turn_abandon_prepared(turn)

    _ = virtual.arena_init_growing(&turn.retained)
    _ = virtual.arena_init_growing(&turn.scratch, TURN_SCRATCH_RESERVE)

    allocator := virtual.arena_allocator(&turn.retained)
    turn.events.allocator = allocator
    turn.error_body.allocator = allocator

    sse.parser_init(&turn.sse_parser, sse.DEFAULT_CONFIG, allocator)
    turn.parser_initialized = true

    turn.decoder = decoder_init(ep.protocol, allocator)

    // Setup data — URL, header descriptors, credential strings — is transient:
    // curl copies every request field at transfer_start, so it lives in a scratch
    // temp scope reclaimed once the transfer is armed, never in `retained`
    // alongside streaming state.
    setup := virtual.arena_temp_begin(&turn.scratch)
    defer virtual.arena_temp_end(setup)
    setup_alloc := virtual.arena_allocator(&turn.scratch)

    url := endpoint_url(ep, setup_alloc)

    curl_url := strings.clone_to_cstring(url, setup_alloc)

    header_buf: [MAX_REQUEST_HEADERS]curl.Header
    header_n := turn_request_headers(request.connection, header_buf[:], setup_alloc) or_return

    curl_request := curl.Request {
        url     = curl_url,
        headers = header_buf[:header_n],
        body    = transmute([]byte)request.body,
        method  = .Post,
    }
    curl_err := curl.transfer_start(&turn.transfer, &client.curl_client, curl_request, turn_curl_callbacks(), turn)
    if curl_err != .None do return turn_error_from_curl_start(curl_err)

    turn.state = .Running
    client.live_count += 1

    assert(client.live_count > 0, "a started provider turn increments the live count")
    assert(turn.transfer.state == .Running, "provider turn start and transfer start must agree")

    return .None
}

// Cancel a live provider attempt synchronously. No `on_done` callback fires.
// When called from `on_event`, arena teardown waits until the borrowed event
// leaves the callback stack.
turn_cancel :: proc(turn: ^Turn) {
    assert(turn != nil, "provider turn_cancel needs a turn")
    assert(turn.client != nil, "provider turn_cancel on a turn that never started")
    assert(turn.state == .Running || turn.state == .Completing, "provider turn_cancel on a terminal turn")

    if turn.state == .Running {
        assert(turn.transfer.state == .Running, "a running provider turn must own a running transfer")
        curl.transfer_cancel(&turn.transfer)
    } else {
        assert(turn.transfer.state == .Done, "a completing provider turn must have completed its transfer")
    }

    turn.state = .Canceled

    if turn.dispatching do return

    turn_cleanup(turn, .Canceled)
}

// Fill `out` with the fixed protocol headers then the credential lines,
// returning the count. Credential values are cloned into `allocator`; every
// descriptor is copied by curl at transfer_start, so `out` may be stack storage.
@(private)
turn_request_headers :: proc(
    connection: Connection,
    out: []curl.Header,
    allocator: runtime.Allocator,
) -> (
    n: int,
    err: Transport_Error,
) {
    assert(endpoint_validate(connection.endpoint) == .None, "request headers need a validated endpoint")
    assert(protocol_supported(connection.endpoint.protocol), "request headers need a supported protocol")
    assert(len(out) >= MAX_REQUEST_HEADERS, "request header buffer holds the closed header set")

    out[0] = {
        name  = "content-type",
        value = "application/json",
    }
    out[1] = {
        name  = "accept",
        value = "text/event-stream",
    }
    n = 2

    credentials := auth_headers(connection, out[n:], allocator) or_return
    n += credentials

    return n, .None
}

// Curl callbacks only parse and queue; no user callback runs from this table.
@(private)
turn_curl_callbacks :: proc() -> curl.Callbacks {
    return {
        on_status = turn_on_status,
        on_header = turn_on_header,
        on_body = turn_on_body,
        on_done = turn_on_curl_done,
    }
}

@(private)
turn_on_status :: proc(user: rawptr, status: int) {
    turn := (^Turn)(user)
    assert(turn != nil, "curl status needs a provider turn")
    assert(turn.state == .Running, "curl status reached a non-running provider turn")
    assert(turn.client.curl_client.in_curl, "curl status must run inside curl")

    turn.status = status
    turn.retry_after = nil
    turn.unsupported_content_encoding = false
    turn.error_body_capped = false
    turn.response_bytes = 0
    clear(&turn.error_body)

    // A redirect or interim response starts a distinct body. No partial SSE
    // state from the previous header block may flow into it.
    sse.parser_destroy(&turn.sse_parser)
    sse.parser_init(&turn.sse_parser, sse.DEFAULT_CONFIG, virtual.arena_allocator(&turn.retained))
}

@(private)
turn_on_header :: proc(user: rawptr, line: []byte) {
    turn := (^Turn)(user)
    assert(turn != nil, "curl header needs a provider turn")
    assert(turn.state == .Running, "curl header reached a non-running provider turn")
    assert(turn.client.curl_client.in_curl, "curl header must run inside curl")

    name, value, ok := turn_header_split(line)
    if !ok do return

    if strings.equal_fold(name, "content-encoding") {
        turn.unsupported_content_encoding = turn.unsupported_content_encoding || !strings.equal_fold(value, "identity")
        return
    }

    if strings.equal_fold(name, "retry-after") do turn.retry_after = turn_retry_after_parse(value)
}

@(private)
turn_on_body :: proc(user: rawptr, chunk: []byte) -> bool {
    turn := (^Turn)(user)
    assert(turn != nil, "curl body needs a provider turn")
    assert(turn.state == .Running, "curl body reached a non-running provider turn")
    assert(turn.client.curl_client.in_curl, "curl body must run inside curl")
    assert(turn.callback_error == .None, "curl must stop after the callback latched an error")

    if turn.unsupported_content_encoding {
        turn.callback_error = .Unsupported_Content_Encoding
        return false
    }

    if turn.status < 200 || turn.status >= 300 {
        remaining := MAX_ERROR_BODY_BYTES - len(turn.error_body)
        assert(remaining >= 0, "error-body prefix stays within its bound")

        keep := min(remaining, len(chunk))
        append(&turn.error_body, ..chunk[:keep])

        assert(len(turn.error_body) <= MAX_ERROR_BODY_BYTES, "error-body prefix stays bounded")
        if keep < len(chunk) {
            turn.error_body_capped = true
            return false
        }

        return true
    }

    turn.response_bytes += len(chunk)
    assert(turn.response_bytes >= 0, "response byte count cannot overflow negative")
    if turn.response_bytes > turn.client.max_response_bytes {
        turn.callback_error = .Response_Too_Large
        return false
    }

    feed_err := sse.feed(&turn.sse_parser, chunk, turn, turn_on_sse_event)
    if turn.callback_error != .None do return false

    switch feed_err {
    case .None:
        return true

    case .Line_Too_Long, .Event_Too_Large:
        turn.callback_error = .Response_Too_Large

    case .Out_Of_Memory:
        turn.callback_error = .Resource_Exhausted
    }

    return false
}

// Decode one borrowed SSE payload into turn-owned output. Returning false stops
// the transfer; `callback_error` preserves why.
@(private)
turn_on_sse_event :: proc(user: rawptr, data: string) -> bool {
    turn := (^Turn)(user)
    assert(turn != nil, "SSE event needs a provider turn")
    assert(turn.state == .Running, "SSE event reached a non-running provider turn")
    assert(turn.callback_error == .None, "SSE decode cannot continue after an error")

    temp := virtual.arena_temp_begin(&turn.scratch)
    defer virtual.arena_temp_end(temp)
    scratch := virtual.arena_allocator(&turn.scratch)

    before := len(turn.events)
    err := decoder_decode(&turn.decoder, data, &turn.events, scratch)
    if commit_err := turn_commit(turn, before, err); commit_err != .None {
        turn.callback_error = commit_err
        return false
    }

    return true
}

// Make the events appended since `before` atomically visible. A failed decode
// rolls the queue back so nothing partial escapes; with no consumer the new
// events are dropped; otherwise one deferred dispatch is armed. The turn owns
// this invariant so no decoder can leave an unscheduled queue.
@(private)
turn_commit :: proc(turn: ^Turn, before: int, err: Transport_Error) -> Transport_Error {
    assert(turn != nil, "event commit needs a provider turn")
    assert(turn.state == .Running, "events commit only while the turn is running")
    assert(before <= len(turn.events), "a decode step only grows the queue")

    if err != .None {
        resize(&turn.events, before)
        return err
    }

    if turn.callbacks.on_event == nil {
        resize(&turn.events, before)
        return .None
    }

    if len(turn.events) > before do turn_schedule_dispatch(turn)

    return .None
}

@(private)
turn_on_curl_done :: proc(user: rawptr, result: curl.Result) {
    turn := (^Turn)(user)
    assert(turn != nil, "curl completion needs a provider turn")
    assert(turn.state == .Running, "curl completed a non-running provider turn")
    assert(!turn.client.curl_client.in_curl, "provider completion must be outside curl")
    assert(turn.transfer.state == .Done, "curl completion callback must follow curl teardown")

    err := turn.callback_error
    capped_write := turn.error_body_capped && result.code == .Write_Error

    // The `.Write_Error` from capping the error body is our own stop, not a
    // transfer failure.
    if err == .None && result.code != .Ok && !capped_write do err = transport_error_from_curl(result.code)

    if err == .None && turn.unsupported_content_encoding do err = .Unsupported_Content_Encoding

    status := result.status

    if status == 0 do status = turn.status

    turn.status = status

    if err == .None && (status < 200 || status >= 300) {
        temp := virtual.arena_temp_begin(&turn.scratch)
        defer virtual.arena_temp_end(temp)

        err = transport_error_from_status(status, string(turn.error_body[:]), virtual.arena_allocator(&turn.scratch))
    }

    // Finish while still Running so late events schedule like any other, then
    // enter Completing with the queue already consistent.
    if err == .None {
        before := len(turn.events)
        temp := virtual.arena_temp_begin(&turn.scratch)
        finish_err := decoder_finish(&turn.decoder, &turn.events, virtual.arena_allocator(&turn.scratch))
        virtual.arena_temp_end(temp)
        err = turn_commit(turn, before, finish_err)
    }

    turn.callback_error = err
    turn.state = .Completing

    if len(turn.events) > 0 {
        assert(turn.dispatch_op != nil, "queued events must own a deferred dispatch")
        return
    }

    assert(turn.dispatch_op == nil, "an empty queue must not retain a dispatch operation")
    turn_finalize(turn)
}

// Schedule at most one later-tick dispatch. nbio guarantees this callback is
// never synchronous, which is the boundary that keeps user code out of curl.
@(private)
turn_schedule_dispatch :: proc(turn: ^Turn) {
    assert(turn != nil, "event scheduling needs a provider turn")
    assert(turn.state == .Running, "only a running turn can queue new events")
    assert(len(turn.events) > 0, "event scheduling needs queued output")

    if turn.dispatch_op == nil do turn.dispatch_op = nbio.timeout_poly(0, turn, turn_on_dispatch, turn.client.loop)

    assert(turn.dispatch_op != nil, "nbio returns a live dispatch operation")
}

@(private)
turn_on_dispatch :: proc(op: ^nbio.Operation, turn: ^Turn) {
    assert(turn != nil, "event dispatch needs a provider turn")
    assert(turn.dispatch_op == op, "event dispatch fired for an operation the turn does not own")
    assert(turn.state == .Running || turn.state == .Completing, "event dispatch needs a live turn")
    assert(!turn.dispatching, "event dispatch re-entered itself")
    assert(!turn.client.curl_client.in_curl, "user events must dispatch outside curl")

    turn.dispatch_op = nil
    turn.dispatching = true

    for event in turn.events {
        assert(turn.callbacks.on_event != nil, "queued events require an event callback")
        turn.callbacks.on_event(turn.user, event)

        if turn.state == .Canceled do break
    }

    clear(&turn.events)
    turn.dispatching = false

    if turn.state == .Canceled {
        turn_cleanup(turn, .Canceled)
        return
    }

    if turn.state == .Completing do turn_finalize(turn)
}

// Deliver terminal completion after queued output has drained. Cleanup happens
// before the callback so the callback may reuse the same Turn immediately.
@(private)
turn_finalize :: proc(turn: ^Turn) {
    assert(turn != nil, "turn finalization needs a provider turn")
    assert(turn.state == .Completing, "only a completing turn may finalize")
    assert(!turn.dispatching, "turn finalization cannot invalidate an event callback borrow")
    assert(turn.dispatch_op == nil, "turn finalization cannot leave deferred dispatch armed")
    assert(len(turn.events) == 0, "turn finalization requires an empty event queue")

    result := Turn_Result {
        err = turn.callback_error,
    }
    if result.err == .Rate_Limited do result.retry_after = turn.retry_after

    callbacks := turn.callbacks
    user := turn.user
    turn_cleanup(turn, .Done)

    if callbacks.on_done != nil do callbacks.on_done(user, result)
}

// Tear down all turn-owned allocations while preserving only terminal state.
@(private)
turn_cleanup :: proc(turn: ^Turn, terminal: Turn_State) {
    assert(turn != nil, "turn cleanup needs a turn")
    assert(terminal == .Done || terminal == .Canceled, "turn cleanup needs a terminal state")
    assert(!turn.dispatching, "turn cleanup cannot run during an event borrow")
    assert(turn.client != nil, "turn cleanup needs its owning client")
    assert(turn.client.live_count > 0, "turn cleanup must release one registered turn")

    transfer_state := turn.transfer.state
    if terminal == .Done {
        assert(transfer_state == .Done, "a completed provider turn must have completed its transfer")
    } else {
        assert(
            transfer_state == .Done || transfer_state == .Canceled,
            "a canceled provider turn must have stopped its transfer",
        )
    }

    if turn.dispatch_op != nil {
        nbio.remove(turn.dispatch_op)
        turn.dispatch_op = nil
    }

    if turn.parser_initialized do sse.parser_destroy(&turn.sse_parser)

    client := turn.client
    virtual.arena_check_temp(&turn.scratch)
    virtual.arena_destroy(&turn.scratch)
    virtual.arena_destroy(&turn.retained)

    client.live_count -= 1
    assert(client.live_count >= 0, "provider live-turn count stays non-negative")

    turn^ = Turn {
        state = terminal,
    }
}

// Release a request that failed before registering with the provider client.
@(private)
turn_abandon_prepared :: proc(turn: ^Turn) {
    assert(turn != nil, "prepared-turn abandonment needs a turn")
    assert(turn.state == .Created, "only an unregistered turn may be abandoned")
    assert(turn.client != nil, "prepared turn must remember its client")
    assert(turn.transfer.state == .Created, "an unregistered provider turn cannot retain curl resources")

    if turn.parser_initialized do sse.parser_destroy(&turn.sse_parser)

    virtual.arena_destroy(&turn.scratch)
    virtual.arena_destroy(&turn.retained)

    turn^ = Turn {
        state = .Created,
    }
}

// Split one response `Name: value` line. Both results borrow `line`, so nothing
// here may outlive the curl header callback.
@(private)
turn_header_split :: proc(line: []byte) -> (name, value: string, ok: bool) {
    text := string(line)
    colon := strings.index_byte(text, ':')
    if colon <= 0 do return "", "", false

    name = strings.trim_space(text[:colon])
    value = strings.trim_space(text[colon + 1:])
    if len(name) == 0 do return "", "", false

    return name, value, true
}

// Parse the delta-seconds form of Retry-After. HTTP-date is deliberately
// ignored; arbitrarily large decimal values saturate at the confirmed cap.
@(private)
turn_retry_after_parse :: proc(value: string) -> Maybe(time.Duration) {
    text := strings.trim_space(value)
    if len(text) == 0 do return nil

    cap_seconds := int(RETRY_AFTER_CAP / time.Second)
    seconds := 0
    for b in transmute([]byte)text {
        if b < '0' || b > '9' do return nil

        if seconds < cap_seconds do seconds = min(cap_seconds, seconds * 10 + int(b - '0'))
    }

    return time.Duration(seconds) * time.Second
}

// Synchronous curl setup failure mapped into the provider taxonomy.
@(private)
turn_error_from_curl_start :: proc(err: curl.Error) -> Transport_Error {
    switch err {
    case .None:
        return .None

    case .Out_Of_Memory:
        return .Resource_Exhausted

    case .Invalid_Request:
        return .Invalid_Request

    case .Setup_Failed:
        return .Network_Error
    }

    return .Network_Error
}

#assert(MAX_ERROR_BODY_BYTES > 0)
#assert(MAX_ERROR_BODY_BYTES < sse.DEFAULT_CONFIG.max_event_bytes)
