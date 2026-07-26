package client

import "core:mem"
import "core:reflect"
import "core:strings"
import "core:testing"
import ws "libs:websocket"
import wire "src:wire"

// Driver tests exercise the pure routing/bookkeeping core with hand-written JSON and
// a recording sink reached via `user_data`. No socket or event loop is created; the
// transport is covered by `libs/websocket`'s own tests.

// Recording sink for the driver callbacks. All fields are value copies extracted
// during the callback except `cloned`/`last_unknown`, which are deep-copied into
// `clone_alloc` to outlive the borrowed frame data.
Sink :: struct {
    ready:            int,
    responses:        int,
    last_response_id: u64,
    last_ok:          bool,
    last_result_type: typeid,
    last_error_code:  wire.Error_Code,
    broadcasts:       int,
    last_bc_name:     wire.Broadcast_Name,
    unknown:          int,
    last_unknown:     string,
    errors:           int,
    last_error:       Protocol_Error,
    closes:           int,
    last_close_code:  ws.Close_Code,
    want_clone:       bool,
    clone_alloc:      mem.Allocator,
    cloned:           wire.Broadcast,
    has_clone:        bool,
}

_rec_on_ready :: proc(c: ^Client) {
    s := (^Sink)(c.user_data)
    s.ready += 1
}

// What one request's completion observed, so concurrent requests can be told apart.
Completion :: struct {
    calls:       int,
    response_id: u64,
    result_type: typeid,
}

// The recording completion registered per request. Updates the connection-wide `Sink`
// and, when the request carried one, its own `Completion`.
_rec_on_response :: proc(c: ^Client, resp: wire.Response, user_data: rawptr) {
    s := (^Sink)(c.user_data)
    s.responses += 1

    switch v in resp {
    case wire.Response_Ok:
        s.last_response_id = u64(v.id)
        s.last_ok = true
        s.last_result_type = reflect.union_variant_typeid(v.result)

    case wire.Response_Error:
        s.last_response_id = u64(v.id)
        s.last_ok = false
        s.last_result_type = nil
        s.last_error_code = v.error.code
    }

    if user_data != nil {
        own := (^Completion)(user_data)
        own.calls += 1
        own.response_id = s.last_response_id
        own.result_type = s.last_result_type
    }
}

_rec_on_broadcast :: proc(c: ^Client, bc: wire.Broadcast) {
    s := (^Sink)(c.user_data)
    s.broadcasts += 1
    s.last_bc_name = bc.name

    if s.want_clone {
        s.cloned = wire.broadcast_clone(bc, s.clone_alloc)
        s.has_clone = true
    }
}

_rec_on_unknown_broadcast :: proc(c: ^Client, name: string) {
    s := (^Sink)(c.user_data)
    s.unknown += 1
    // Borrowed for the call only; copy it to assert after `scratch` is reclaimed.
    s.last_unknown = strings.clone(name, s.clone_alloc)
}

_rec_on_close :: proc(c: ^Client, code: ws.Close_Code) {
    s := (^Sink)(c.user_data)
    s.closes += 1
    s.last_close_code = code
}

_rec_on_error :: proc(c: ^Client, err: Protocol_Error) {
    s := (^Sink)(c.user_data)
    s.errors += 1
    s.last_error = err
}

_rec_callbacks :: proc() -> Client_Callbacks {
    return Client_Callbacks {
        on_ready = _rec_on_ready,
        on_broadcast = _rec_on_broadcast,
        on_unknown_broadcast = _rec_on_unknown_broadcast,
        on_close = _rec_on_close,
        on_error = _rec_on_error,
    }
}

// Set up a driver for pure-core testing: owned `pending`/`scratch`, the recording
// sink, and Ready state (tests override `state` as needed). No transport is connected.
_init_client :: proc(c: ^Client, sink: ^Sink) {
    c^ = {}
    c.allocator = context.allocator
    c.pending = make(map[wire.Request_Id]Pending_Request, context.allocator)
    mem.dynamic_arena_init(&c.scratch, context.allocator, context.allocator)
    c.next_request_id = 1
    c.cbs = _rec_callbacks()
    c.user_data = sink
    c.state = .Ready
}

// Register an in-flight request the way an accepted `client_send_request` would,
// routing its response to the recording completion and optional per-request observer.
_expect_response :: proc(c: ^Client, id: u64, method: wire.Method_Name, own: ^Completion = nil) {
    c.pending[wire.Request_Id(id)] = {
        method      = method,
        on_response = _rec_on_response,
        user_data   = own,
    }
}

// Release the driver-owned state a test allocated (never touches an unconnected
// transport). Fake-open tests additionally drain the transport send queue first.
_teardown :: proc(c: ^Client) {
    delete(c.pending)
    mem.dynamic_arena_destroy(&c.scratch)

    if len(c.daemon_version) > 0 {
        delete(c.daemon_version, c.allocator)
    }
}

// Make `ws.client_send_text` accept a frame into the transport's send queue without
// submitting to a (nil) loop: `.Open` passes the guard, and `sending` makes
// `pump_send` return before it touches `nbio`.
_arm_fake_open :: proc(c: ^Client) {
    c.sock.state = .Open
    c.sock.allocator = context.allocator
    c.sock.max_frame_bytes = 1 << 20
    c.sock.max_send_queue_bytes = 1 << 20
    c.sock.sending = true
}

// Free the frames the fake-open path enqueued and the queue itself.
_drain_fake_send_queue :: proc(c: ^Client) {
    for frame in c.sock.send_queue {
        delete(frame, c.sock.allocator)
    }

    delete(c.sock.send_queue)
    c.sock.send_queue = nil
}

@(test)
test_send_request_ids_increment_and_record_pending :: proc(t: ^testing.T) {
    sink: Sink
    c: Client
    _init_client(&c, &sink)
    _arm_fake_open(&c)
    defer {
        _drain_fake_send_queue(&c)
        _teardown(&c)
    }

    own1: Completion
    own2: Completion

    id1, e1 := client_send_request(&c, .Catalog_Refresh, wire.Empty_Params{}, _rec_on_response, &own1)
    testing.expect_value(t, e1, Protocol_Error.None)
    testing.expect_value(t, u64(id1), u64(1))

    id2, e2 := client_send_request(&c, .Session_List, wire.default_params(.Session_List).?, _rec_on_response, &own2)
    testing.expect_value(t, e2, Protocol_Error.None)
    testing.expect_value(t, u64(id2), u64(2))

    testing.expect_value(t, len(c.pending), 2)
    testing.expect_value(t, u64(c.next_request_id), u64(3))

    p1, ok1 := c.pending[id1]
    testing.expect(t, ok1, "id1 recorded")
    testing.expect_value(t, p1.method, wire.Method_Name.Catalog_Refresh)
    testing.expect(t, p1.user_data == &own1, "id1 keeps its own completion data")

    p2, ok2 := c.pending[id2]
    testing.expect(t, ok2, "id2 recorded")
    testing.expect_value(t, p2.method, wire.Method_Name.Session_List)
    testing.expect(t, p2.user_data == &own2, "id2 keeps its own completion data")
}

// The point of per-request completions: two requests in flight at once, answered out
// of order, each reaching only its own completion with its own typed result.
@(test)
test_two_in_flight_requests_reach_their_own_completion :: proc(t: ^testing.T) {
    sink: Sink
    c: Client
    _init_client(&c, &sink)
    _arm_fake_open(&c)
    defer {
        _drain_fake_send_queue(&c)
        _teardown(&c)
    }

    refresh: Completion
    list: Completion

    id_refresh, e1 := client_send_request(&c, .Catalog_Refresh, wire.Empty_Params{}, _rec_on_response, &refresh)
    testing.expect_value(t, e1, Protocol_Error.None)

    id_list, e2 := client_send_request(
        &c,
        .Session_List,
        wire.default_params(.Session_List).?,
        _rec_on_response,
        &list,
    )
    testing.expect_value(t, e2, Protocol_Error.None)
    testing.expect_value(t, len(c.pending), 2)

    // Answer the second request first: correlation is by id, not arrival order.
    list_raw := `{"type":"response","id":2,"result":{"revision":0,"items":[],"next_cursor":null,"total":0}}`
    testing.expect_value(t, client_handle_text(&c, transmute([]byte)list_raw), Protocol_Error.None)

    testing.expect_value(t, list.calls, 1)
    testing.expect_value(t, list.response_id, u64(id_list))
    testing.expect_value(t, list.result_type, typeid_of(wire.Session_List_Result))
    testing.expect_value(t, refresh.calls, 0)
    testing.expect_value(t, len(c.pending), 1)

    refresh_raw := `{"type":"response","id":1,"result":{"catalog_rev":"2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824","health":{"skipped":[],"load_error":null}}}`
    testing.expect_value(t, client_handle_text(&c, transmute([]byte)refresh_raw), Protocol_Error.None)

    testing.expect_value(t, refresh.calls, 1)
    testing.expect_value(t, refresh.response_id, u64(id_refresh))
    testing.expect_value(t, refresh.result_type, typeid_of(wire.Catalog_Refresh_Result))
    testing.expect_value(t, list.calls, 1)
    testing.expect_value(t, len(c.pending), 0)
}

// A second response for an id whose completion already ran is uncorrelated: it is
// rejected as `.Unknown_Response` and the completion never fires twice.
@(test)
test_duplicate_response_does_not_refire_completion :: proc(t: ^testing.T) {
    sink: Sink
    c: Client
    _init_client(&c, &sink)
    own: Completion
    _expect_response(&c, 3, .Session_Send_Input, &own)
    defer _teardown(&c)

    raw := `{"type":"response","id":3,"result":{"type":"queued","input_id":8}}`
    testing.expect_value(t, client_handle_text(&c, transmute([]byte)raw), Protocol_Error.None)
    testing.expect_value(t, own.calls, 1)

    testing.expect_value(t, client_handle_text(&c, transmute([]byte)raw), Protocol_Error.Unknown_Response)
    testing.expect_value(t, own.calls, 1)
    testing.expect_value(t, sink.errors, 1)
    testing.expect_value(t, sink.last_error, Protocol_Error.Unknown_Response)
}

@(test)
test_send_request_not_ready :: proc(t: ^testing.T) {
    sink: Sink
    c: Client
    _init_client(&c, &sink)
    c.state = .Awaiting_Hello
    defer _teardown(&c)

    _, err := client_send_request(&c, .Catalog_Refresh, wire.Empty_Params{}, _rec_on_response)
    testing.expect_value(t, err, Protocol_Error.Not_Ready)
    testing.expect_value(t, len(c.pending), 0)
}

@(test)
test_send_request_id_exhausted :: proc(t: ^testing.T) {
    sink: Sink
    c: Client
    _init_client(&c, &sink)
    c.next_request_id = wire.Request_Id(wire.MAX_REQUEST_ID) + 1
    defer _teardown(&c)

    _, err := client_send_request(&c, .Catalog_Refresh, wire.Empty_Params{}, _rec_on_response)
    testing.expect_value(t, err, Protocol_Error.Request_Id_Exhausted)
}

@(test)
test_send_request_too_many_pending :: proc(t: ^testing.T) {
    sink: Sink
    c: Client
    _init_client(&c, &sink)
    defer _teardown(&c)

    for i in 1 ..= MAX_PENDING_REQUESTS {
        _expect_response(&c, u64(i), .Catalog_Refresh)
    }

    _, err := client_send_request(&c, .Catalog_Refresh, wire.Empty_Params{}, _rec_on_response)
    testing.expect_value(t, err, Protocol_Error.Too_Many_Pending)
    testing.expect_value(t, len(c.pending), MAX_PENDING_REQUESTS)
}

@(test)
test_handle_text_routes_typed_response :: proc(t: ^testing.T) {
    sink: Sink
    c: Client
    _init_client(&c, &sink)
    _expect_response(&c, 3, .Session_Send_Input)
    defer _teardown(&c)

    raw := `{"type":"response","id":3,"result":{"type":"queued","input_id":8}}`
    err := client_handle_text(&c, transmute([]byte)raw)
    testing.expect_value(t, err, Protocol_Error.None)
    testing.expect_value(t, sink.responses, 1)
    testing.expect_value(t, sink.last_response_id, u64(3))
    testing.expect(t, sink.last_ok, "success response")
    // Result type comes from the pending method, not the payload.
    testing.expect_value(t, sink.last_result_type, typeid_of(wire.Send_Input_Result))

    _, still := c.pending[wire.Request_Id(3)]
    testing.expect(t, !still, "pending id cleared after response")
}

@(test)
test_handle_text_routes_error_response :: proc(t: ^testing.T) {
    sink: Sink
    c: Client
    _init_client(&c, &sink)
    _expect_response(&c, 4, .Session_List)
    defer _teardown(&c)

    raw := `{"type":"error","id":4,"error":{"code":"session_busy","message":"busy"}}`
    err := client_handle_text(&c, transmute([]byte)raw)
    testing.expect_value(t, err, Protocol_Error.None)
    testing.expect_value(t, sink.responses, 1)
    testing.expect_value(t, sink.last_response_id, u64(4))
    testing.expect(t, !sink.last_ok, "error response")
    testing.expect_value(t, sink.last_error_code, wire.Error_Code.Session_Busy)

    _, still := c.pending[wire.Request_Id(4)]
    testing.expect(t, !still, "pending id cleared after error")
}

@(test)
test_handle_text_routes_known_broadcast :: proc(t: ^testing.T) {
    sink: Sink
    c: Client
    _init_client(&c, &sink)
    defer _teardown(&c)

    raw := `{"type":"broadcast","name":"notice","data":{"level":"warn","source":"provider","message":"rate limited"}}`
    err := client_handle_text(&c, transmute([]byte)raw)
    testing.expect_value(t, err, Protocol_Error.None)
    testing.expect_value(t, sink.broadcasts, 1)
    testing.expect_value(t, sink.last_bc_name, wire.Broadcast_Name.Notice)
    testing.expect_value(t, sink.unknown, 0)
}

@(test)
test_handle_text_unknown_broadcast_not_materialized :: proc(t: ^testing.T) {
    sink: Sink
    c: Client
    _init_client(&c, &sink)
    defer _teardown(&c)

    clone_arena: mem.Dynamic_Arena
    mem.dynamic_arena_init(&clone_arena, context.allocator, context.allocator)
    defer mem.dynamic_arena_destroy(&clone_arena)
    sink.clone_alloc = mem.dynamic_arena_allocator(&clone_arena)

    // A payload that would fail to decode as any known broadcast proves it is skipped.
    raw := `{"type":"broadcast","name":"totally.unknown","data":{"whatever":{"deep":[1,2,3]}}}`
    err := client_handle_text(&c, transmute([]byte)raw)
    testing.expect_value(t, err, Protocol_Error.None)
    testing.expect_value(t, sink.unknown, 1)
    testing.expect_value(t, sink.broadcasts, 0)
    testing.expect_value(t, sink.last_unknown, "totally.unknown")
}

@(test)
test_handle_text_unknown_response_id :: proc(t: ^testing.T) {
    sink: Sink
    c: Client
    _init_client(&c, &sink)
    defer _teardown(&c)

    raw := `{"type":"response","id":99,"result":{"type":"queued","input_id":8}}`
    err := client_handle_text(&c, transmute([]byte)raw)
    testing.expect_value(t, err, Protocol_Error.Unknown_Response)
    testing.expect_value(t, sink.errors, 1)
    testing.expect_value(t, sink.last_error, Protocol_Error.Unknown_Response)
    testing.expect_value(t, sink.responses, 0)
}

@(test)
test_handle_text_error_unknown_id_accepted_and_validated :: proc(t: ^testing.T) {
    sink: Sink
    c: Client
    _init_client(&c, &sink)
    defer _teardown(&c)

    // An error object is method-agnostic, so an id we never sent is still accepted
    // rather than reported as `.Unknown_Response` — unlike a success `response`, which
    // needs the pending method to type. With no request to correlate it to, there is
    // no completion to reach; it is decoded, validated, and dropped.
    raw := `{"type":"error","id":77,"error":{"code":"session_busy","message":"busy"}}`
    err := client_handle_text(&c, transmute([]byte)raw)
    testing.expect_value(t, err, Protocol_Error.None)
    testing.expect_value(t, sink.responses, 0)
    testing.expect_value(t, sink.errors, 0)

    // Still fully decoded and validated: a bad error code on an uncorrelated id is
    // rejected exactly as it would be on a correlated one.
    bad := `{"type":"error","id":77,"error":{"code":"not_a_code","message":"busy"}}`
    testing.expect_value(t, client_handle_text(&c, transmute([]byte)bad), Protocol_Error.Decode_Failed)
}

@(test)
test_handle_text_malformed_json :: proc(t: ^testing.T) {
    sink: Sink
    c: Client
    _init_client(&c, &sink)
    defer _teardown(&c)

    err := client_handle_text(&c, transmute([]byte)string("not json at all"))
    testing.expect_value(t, err, Protocol_Error.Decode_Failed)
}

@(test)
test_handle_text_trailing_bytes_rejected :: proc(t: ^testing.T) {
    sink: Sink
    c: Client
    _init_client(&c, &sink)
    defer _teardown(&c)

    // A complete broadcast followed by a trailing token: rejected by `dec_finish`
    // before `on_broadcast` fires.
    raw := `{"type":"broadcast","name":"notice","data":{"level":"info","source":"x","message":"y"}} 5`
    err := client_handle_text(&c, transmute([]byte)raw)
    testing.expect_value(t, err, Protocol_Error.Decode_Failed)
    testing.expect_value(t, sink.broadcasts, 0)
}

@(test)
test_handle_text_hello_while_ready_is_unexpected :: proc(t: ^testing.T) {
    sink: Sink
    c: Client
    _init_client(&c, &sink)
    defer _teardown(&c)

    err := client_handle_text(&c, transmute([]byte)string(`{"type":"hello"}`))
    testing.expect_value(t, err, Protocol_Error.Unexpected_Hello)
}

@(test)
test_handle_hello_valid_reaches_ready_and_retains :: proc(t: ^testing.T) {
    sink: Sink
    c: Client
    _init_client(&c, &sink)
    c.state = .Awaiting_Hello
    defer _teardown(&c)

    src := `{"type":"hello","protocol":1,"daemon":{"version":"1.2.3","server_now_ms":1720000000000},"workspaces":[],"profiles":[],"session_revision":7,"cron_revision":9,"catalog_rev":"2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824","catalog_health":{"skipped":[],"load_error":null}}`
    buf := make([]byte, len(src), context.allocator)
    copy(buf, src)
    defer delete(buf, context.allocator)

    err := client_handle_hello(&c, buf)
    testing.expect_value(t, err, Protocol_Error.None)
    testing.expect_value(t, c.state, Protocol_State.Ready)
    testing.expect_value(t, sink.ready, 1)
    testing.expect_value(t, c.protocol, u32(1))
    testing.expect_value(t, c.session_revision, wire.Session_Revision(7))
    testing.expect_value(t, c.cron_revision, wire.Cron_Revision(9))
    testing.expect_value(t, c.daemon_version, "1.2.3")

    // The retained daemon version is an owned clone: clobbering the source frame
    // must not disturb it.
    for i in 0 ..< len(buf) {
        buf[i] = 0xff
    }

    testing.expect_value(t, c.daemon_version, "1.2.3")
}

@(test)
test_handle_hello_malformed_is_bad_hello :: proc(t: ^testing.T) {
    sink: Sink
    c: Client
    _init_client(&c, &sink)
    c.state = .Awaiting_Hello
    defer _teardown(&c)

    raw := `{"type":"hello","protocol":1,"daemon":{"version":"x"`
    err := client_handle_hello(&c, transmute([]byte)raw)
    testing.expect_value(t, err, Protocol_Error.Bad_Hello)
    testing.expect_value(t, sink.errors, 0)
    testing.expect_value(t, c.state, Protocol_State.Awaiting_Hello)
}

@(test)
test_broadcast_clone_survives_source_and_scratch :: proc(t: ^testing.T) {
    sink: Sink
    c: Client
    _init_client(&c, &sink)
    defer _teardown(&c)

    clone_arena: mem.Dynamic_Arena
    mem.dynamic_arena_init(&clone_arena, context.allocator, context.allocator)
    defer mem.dynamic_arena_destroy(&clone_arena)
    sink.clone_alloc = mem.dynamic_arena_allocator(&clone_arena)
    sink.want_clone = true

    src := `{"type":"broadcast","name":"notice","data":{"level":"warn","source":"provider","message":"rate limited"}}`
    buf := make([]byte, len(src), context.allocator)
    copy(buf, src)
    defer delete(buf, context.allocator)

    err := client_handle_text(&c, buf)
    testing.expect_value(t, err, Protocol_Error.None)
    testing.expect(t, sink.has_clone, "broadcast cloned into caller arena")

    // `scratch` was reclaimed by `client_handle_text`; now destroy the source too.
    for i in 0 ..< len(buf) {
        buf[i] = 0xff
    }

    notice, ok := sink.cloned.data.(wire.Notice)
    testing.expect(t, ok, "cloned payload is a notice")
    testing.expect_value(t, sink.cloned.name, wire.Broadcast_Name.Notice)
    testing.expect_value(t, notice.level, wire.Notice_Level.Warn)
    testing.expect_value(t, notice.source, "provider")
    testing.expect_value(t, notice.message, "rate limited")
}
