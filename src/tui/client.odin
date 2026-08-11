package tui

/*
Client-only QuickJS bridge to `src/client`. The native module is intentionally private:
`js/client.js` exposes the typed `yuke:client` surface and keeps JSON-RPC envelopes out of
user scripts.
*/

import "base:runtime"
import "core:c"
import "core:encoding/json"
import "core:nbio"
import "core:strings"
import "core:time"

import qjs "libs:bindings/quickjs"
import ws "libs:websocket"
import client "src:client"
import js "src:js"
import wire "src:wire"

CLIENT_NATIVE_MODULE :: "yuke:client-native"

@(rodata)
CLIENT_NATIVE_EXPORTS := []string{"native"}

// Slightly beyond the WebSocket close timeout; an opening transport is canceled directly.
CLIENT_SHUTDOWN_TIMEOUT :: 6 * time.Second

Client_Connect_Options :: struct {
    host:   string `json:"host"`,
    port:   int `json:"port"`,
    secure: bool `json:"secure"`,
    token:  string `json:"token"`,
    remote: bool `json:"remote"`,
    device: string `json:"device"`,
}

Client_Promise :: struct {
    host:    ^Host,
    resolve: qjs.Value,
    reject:  qjs.Value,
}

Daemon_Connection :: struct {
    client:      client.Client,
    live:        bool,
    connect_job: ^Client_Promise,
}

client_module :: proc() -> js.Module {
    return {name = CLIENT_NATIVE_MODULE, init = client_module_init, exports = CLIENT_NATIVE_EXPORTS}
}

client_module_init :: proc "c" (ctx: ^qjs.Context, m: ^qjs.Module_Def) -> c.int {
    context = runtime.default_context()

    native := qjs.new_object(ctx)
    _ = qjs.set_property(ctx, native, "connect", qjs.new_function(ctx, client_js_connect, "connect", 1))
    _ = qjs.set_property(ctx, native, "disconnect", qjs.new_function(ctx, client_js_disconnect, "disconnect", 0))
    _ = qjs.set_property(ctx, native, "request", qjs.new_function(ctx, client_js_request, "request", 2))
    _ = qjs.set_property(ctx, native, "state", qjs.new_function(ctx, client_js_state, "state", 0))

    if !qjs.set_module_export(ctx, m, "native", native) {
        return -1
    }

    return 0
}

// Operational failures reject; malformed arguments throw synchronously.
@(private = "file")
client_js_connect :: proc "c" (ctx: ^qjs.Context, this: qjs.Value, argc: c.int, argv: [^]qjs.Value) -> qjs.Value {
    context = runtime.default_context()
    _ = this

    h := host_from_ctx(ctx)
    if h == nil {
        return qjs.throw_type_error(ctx, "yuke:client has no host")
    }

    if h.done {
        return qjs.throw_type_error(ctx, "yuke:client host is shutting down")
    }

    if h.drive == nil || h.drive.loop == nil {
        return qjs.throw_type_error(ctx, "yuke:client has no drive")
    }

    if argc < 1 || !qjs.is_object(argv[0]) {
        return qjs.throw_type_error(ctx, "connect expects an options object")
    }

    if h.daemon.live && h.daemon.client.state == .Closed {
        client.client_destroy(&h.daemon.client)
        h.daemon = {}
    }

    if h.remote != nil || h.daemon.live {
        return qjs.throw_type_error(ctx, "a daemon connection already exists")
    }

    options, options_ok := client_connect_options(ctx, argv[0])
    if !options_ok {
        return qjs.throw_type_error(ctx, "connect options are invalid")
    }

    job, promise := client_promise_new(h)
    if job == nil {
        if qjs.is_exception(promise) {
            return promise
        }

        return qjs.throw_type_error(ctx, "out of memory")
    }

    // A remote connect fetches the roster and a connect ticket asynchronously, then builds the
    // relay transport; the promise settles through the same client callbacks as the local path.
    if options.remote {
        remote_connect_start(h, job, options.device)
        return promise
    }

    headers := ""
    if options.token != "" {
        header_err: runtime.Allocator_Error
        headers, header_err = strings.concatenate({"Authorization: Bearer ", options.token, "\r\n"}, h.allocator)
        if header_err != nil {
            client_promise_reject(job, "out_of_memory", false)
            return promise
        }

        defer delete(headers, h.allocator)
    }

    scheme := ws.Scheme.Ws
    if options.secure {
        scheme = .Wss
    }

    transport, transport_err := client.ws_create(
        h.drive.loop,
        {scheme = scheme, host = options.host, port = options.port, path = "/ws", extra_headers = headers},
        h.allocator,
    )
    if transport_err != .None {
        client_promise_reject(job, client_transport_error_wire(transport_err), false)
        return promise
    }

    callbacks := client.Client_Callbacks {
        on_ready = client_on_ready,
        on_close = client_on_close,
        on_error = client_on_error,
    }

    open_err := client.client_open(&h.daemon.client, transport, "yuke", "0.1.0", callbacks, h, h.allocator)
    if open_err != .None {
        client_promise_reject(job, client_protocol_error_wire(open_err), false)
        return promise
    }

    h.daemon.live = true
    h.daemon.connect_job = job

    return promise
}

@(private = "file")
client_js_disconnect :: proc "c" (ctx: ^qjs.Context, this: qjs.Value, argc: c.int, argv: [^]qjs.Value) -> qjs.Value {
    context = runtime.default_context()
    _ = this
    _ = argc
    _ = argv

    h := host_from_ctx(ctx)
    if h == nil {
        return qjs.throw_type_error(ctx, "yuke:client has no host")
    }

    // Cancel a remote connect still fetching its roster/ticket; its promise rejects.
    if h.remote != nil {
        remote_connect_cancel(h)
        return qjs.undefined()
    }

    if !h.daemon.live || h.daemon.client.state == .Closed || h.daemon.client.state == .Closing {
        return qjs.undefined()
    }

    client.client_close(&h.daemon.client)

    return qjs.undefined()
}

@(private = "file")
client_js_request :: proc "c" (ctx: ^qjs.Context, this: qjs.Value, argc: c.int, argv: [^]qjs.Value) -> qjs.Value {
    context = runtime.default_context()
    _ = this

    h := host_from_ctx(ctx)
    if h == nil {
        return qjs.throw_type_error(ctx, "yuke:client has no host")
    }

    if h.done {
        return qjs.throw_type_error(ctx, "yuke:client host is shutting down")
    }

    if argc < 2 || !qjs.is_string(argv[0]) || !qjs.is_object(argv[1]) {
        return qjs.throw_type_error(ctx, "request expects a method and params object")
    }

    method_text, method_ok := qjs.to_string(ctx, argv[0])
    if !method_ok {
        return qjs.exception()
    }

    defer qjs.free_string(ctx, method_text)

    method, known := wire.method_name_from_wire(method_text)
    if !known || method == .Initialize || method == .Auth_Set_Api_Key {
        return qjs.throw_type_error(ctx, "request method is not available")
    }

    params, params_ok := client_request_params(ctx, method, argv[1])
    if !params_ok {
        return qjs.throw_type_error(ctx, "request params failed wire validation")
    }

    job, promise := client_promise_new(h)
    if job == nil {
        if qjs.is_exception(promise) {
            return promise
        }

        return qjs.throw_type_error(ctx, "out of memory")
    }

    _, send_err := client.client_send_request(&h.daemon.client, method, params, client_on_request_complete, job)
    if send_err != .None {
        client_promise_reject(job, client_protocol_error_wire(send_err), false)
    }

    return promise
}

@(private = "file")
client_js_state :: proc "c" (ctx: ^qjs.Context, this: qjs.Value, argc: c.int, argv: [^]qjs.Value) -> qjs.Value {
    context = runtime.default_context()
    _ = this
    _ = argc
    _ = argv

    h := host_from_ctx(ctx)
    if h == nil {
        return qjs.new_string(ctx, "disconnected")
    }

    // A remote connect reports "connecting" through its whole roster/ticket/dial phase, before
    // a daemon client exists.
    if h.remote != nil {
        return qjs.new_string(ctx, "connecting")
    }

    if !h.daemon.live {
        return qjs.new_string(ctx, "disconnected")
    }

    return qjs.new_string(ctx, client_state_wire(h.daemon.client.state))
}

@(private = "file")
client_connect_options :: proc(ctx: ^qjs.Context, value: qjs.Value) -> (options: Client_Connect_Options, ok: bool) {
    encoded := qjs.json_stringify(ctx, value)
    if qjs.is_exception(encoded) || qjs.is_undefined(encoded) {
        return {}, false
    }

    defer qjs.free_value(ctx, encoded)

    text, text_ok := qjs.to_string(ctx, encoded)
    if !text_ok {
        return {}, false
    }

    defer qjs.free_string(ctx, text)

    if json.unmarshal(transmute([]byte)text, &options, .JSON, context.temp_allocator) != nil {
        return {}, false
    }

    // A remote connect selects the daemon by device name; host/port are unused.
    if options.remote {
        if options.device == "" {
            return {}, false
        }

        return options, true
    }

    if options.host == "" {
        options.host = "127.0.0.1"
    }

    if options.port <= 0 || options.port > 65535 {
        return {}, false
    }

    return options, true
}

@(private = "file")
client_request_params :: proc(
    ctx: ^qjs.Context,
    method: wire.Method_Name,
    value: qjs.Value,
) -> (
    wire.Request_Params,
    bool,
) {
    encoded := qjs.json_stringify(ctx, value)
    if qjs.is_exception(encoded) || qjs.is_undefined(encoded) {
        return nil, false
    }

    defer qjs.free_value(ctx, encoded)

    text, text_ok := qjs.to_string(ctx, encoded)
    if !text_ok {
        return nil, false
    }

    defer qjs.free_string(ctx, text)

    d := wire.decoder_init(text, context.temp_allocator)
    params, decode_err := wire.request_params_from_reader(method, &d)
    if decode_err != .None || wire.dec_finish(&d) != .None {
        return nil, false
    }

    if wire.request_params_validate(params) != .None {
        return nil, false
    }

    return params, true
}

@(private)
client_promise_new :: proc(h: ^Host) -> (job: ^Client_Promise, promise: qjs.Value) {
    assert(h != nil && h.js.ctx != nil, "a client promise needs a live host")

    allocation_err: runtime.Allocator_Error
    job, allocation_err = new(Client_Promise, h.allocator)
    if allocation_err != nil {
        return nil, qjs.undefined()
    }

    resolve, reject: qjs.Value
    promise, resolve, reject = qjs.new_promise(h.js.ctx)
    if qjs.is_exception(promise) {
        free(job, h.allocator)
        return nil, promise
    }

    job^ = {
        host    = h,
        resolve = resolve,
        reject  = reject,
    }
    h.js.pending += 1

    return job, promise
}

@(private = "file")
client_promise_resolve :: proc(job: ^Client_Promise, value: qjs.Value, drain: bool) {
    client_promise_settle(job, value, true, drain)
}

@(private)
client_promise_reject :: proc(job: ^Client_Promise, reason: string, drain: bool) {
    assert(job != nil && job.host != nil, "client promise rejection needs a job")

    value := qjs.new_string(job.host.js.ctx, reason)
    client_promise_settle(job, value, false, drain)
}

@(private = "file")
client_promise_settle :: proc(job: ^Client_Promise, value: qjs.Value, success: bool, run_jobs: bool) {
    assert(job != nil && job.host != nil, "client promise settlement needs a job")

    h := job.host
    assert(h.js.ctx != nil, "client promise settled after its context was freed")
    assert(h.js.pending > 0, "client promise settled without being counted")

    h.js.pending -= 1

    settle := job.resolve if success else job.reject
    args := [1]qjs.Value{value}
    result := qjs.call(h.js.ctx, settle, qjs.undefined(), args[:])

    qjs.free_value(h.js.ctx, result)
    qjs.free_value(h.js.ctx, value)
    qjs.free_value(h.js.ctx, job.resolve)
    qjs.free_value(h.js.ctx, job.reject)
    free(job, h.allocator)

    if run_jobs {
        js.drain(&h.js)
    }
}

client_on_ready :: proc(c: ^client.Client, hello: wire.Initialize_Result) {
    assert(c != nil && c.user_data != nil, "ready callback lost its host")
    _ = hello

    h := (^Host)(c.user_data)
    assert(&h.daemon.client == c && h.daemon.live, "ready callback crossed connections")
    assert(h.daemon.connect_job != nil, "ready callback lost its connect promise")

    job := h.daemon.connect_job
    h.daemon.connect_job = nil
    client_promise_resolve(job, qjs.undefined(), true)
}

client_on_close :: proc(c: ^client.Client, code: client.Close_Code) {
    assert(c != nil && c.user_data != nil, "close callback lost its host")
    _ = code

    h := (^Host)(c.user_data)
    assert(&h.daemon.client == c && h.daemon.live, "close callback crossed connections")

    if h.daemon.connect_job != nil {
        job := h.daemon.connect_job
        h.daemon.connect_job = nil
        client_promise_reject(job, "connection_closed", true)
    }
}

client_on_error :: proc(c: ^client.Client, err: client.Protocol_Error) {
    assert(c != nil && c.user_data != nil, "error callback lost its host")
    assert(err != .None, "client error callback needs an error")

    h := (^Host)(c.user_data)
    assert(&h.daemon.client == c && h.daemon.live, "error callback crossed connections")

    if h.daemon.connect_job != nil {
        job := h.daemon.connect_job
        h.daemon.connect_job = nil
        client_promise_reject(job, client_protocol_error_wire(err), true)
    }
}

client_on_request_complete :: proc(c: ^client.Client, outcome: client.Request_Outcome, user_data: rawptr) {
    assert(c != nil && c.user_data != nil, "request completion lost its host")
    assert(user_data != nil, "request completion lost its promise")

    h := (^Host)(c.user_data)
    job := (^Client_Promise)(user_data)
    assert(&h.daemon.client == c && h.daemon.live, "request completion crossed connections")
    assert(job.host == h, "request completion crossed hosts")

    switch result in outcome {
    case client.Request_Response:
        e, encoded := wire.response_encode(result.response, h.allocator)
        defer wire.emitter_destroy(&e)
        if !encoded {
            client_promise_reject(job, "out_of_memory", true)
            return
        }

        value := qjs.new_string(h.js.ctx, wire.to_string(&e))
        client_promise_resolve(job, value, true)

    case client.Request_Failure:
        client_promise_reject(job, client_protocol_error_wire(result.error), true)
    }
}

daemon_connection_destroy :: proc(h: ^Host) {
    assert(h != nil, "daemon connection destroy needs a host")

    if !h.daemon.live {
        return
    }

    deadline := time.time_add(time.now(), CLIENT_SHUTDOWN_TIMEOUT)

    if h.daemon.client.state != .Closing && h.daemon.client.state != .Closed {
        client.client_close(&h.daemon.client)
    }

    for h.daemon.client.state != .Closed && time.now()._nsec < deadline._nsec {
        if nbio.tick(50 * time.Millisecond) != nil {
            break
        }
    }

    assert(h.daemon.client.state == .Closed, "daemon connection did not finish bounded shutdown")
    assert(h.daemon.connect_job == nil, "daemon shutdown did not settle connect")

    client.client_destroy(&h.daemon.client)
    h.daemon = {}
}

@(private = "file")
client_state_wire :: proc(state: client.Protocol_State) -> string {
    switch state {
    case .Connecting, .Awaiting_Initialize:
        return "connecting"

    case .Ready:
        return "ready"

    case .Closing:
        return "closing"

    case .Closed:
        return "disconnected"
    }

    unreachable()
}

@(private = "file")
client_protocol_error_wire :: proc(err: client.Protocol_Error) -> string {
    switch err {
    case .None:
        unreachable()

    case .Transport_Failed:
        return "transport_failed"

    case .Bad_Initialize:
        return "bad_initialize"

    case .Unknown_Response:
        return "unknown_response"

    case .Decode_Failed:
        return "decode_failed"

    case .Bad_Frame:
        return "bad_frame"

    case .Out_Of_Memory:
        return "out_of_memory"

    case .Request_Id_Exhausted:
        return "request_id_exhausted"

    case .Too_Many_Pending:
        return "too_many_pending"

    case .Not_Ready:
        return "not_ready"

    case .Connection_Closed:
        return "connection_closed"
    }

    unreachable()
}

@(private = "file")
client_transport_error_wire :: proc(err: ws.Client_Error) -> string {
    assert(err != .None, "transport error string needs an error")

    #partial switch err {
    case .Out_Of_Memory:
        return "out_of_memory"
    }

    return "transport_failed"
}
