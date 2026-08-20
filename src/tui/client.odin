package tui

/*
Client-only QuickJS bridge to `src/client`. The native module is intentionally private:
`js/client.js` exposes the typed `yuke:client` surface and keeps JSON-RPC envelopes out of
user scripts.
*/

import "base:runtime"
import "core:c"
import "core:mem"
import "core:nbio"
import "core:strings"
import "core:time"
import "libs:json"

import qjs "libs:bindings/quickjs"
import ws "libs:websocket"
import "src:client"
import "src:js"
import "src:wire"

CLIENT_NATIVE_MODULE :: "yuke:client-native"

@(rodata)
CLIENT_NATIVE_EXPORTS := []string{"native"}

// Bound for the deferred transport-close callback after we abort. Quit does not wait out the
// WebSocket close handshake (5s).
CLIENT_SHUTDOWN_TIMEOUT :: 250 * time.Millisecond

// JS `connect` options. Local uses host/port/token; remote uses `device` (roster id, name fallback).
Client_Connect_Options :: struct {
    host:   string `json:"host"`,
    port:   int `json:"port"`,
    secure: bool `json:"secure"`,
    token:  string `json:"token"`,
    remote: bool `json:"remote"`,
    device: string `json:"device"`,
}

// One JS Promise held across an async native op. `pending` on the JS host tracks these.
Client_Promise :: struct {
    host:    ^Host,
    resolve: qjs.Value,
    reject:  qjs.Value,
}

// The local daemon's connection key. A process has at most one of these.
CONN_LOCAL :: "local"

// Prefix for a relay connection key (`remote:` + the roster device id).
CONN_REMOTE_PREFIX :: "remote:"

// One daemon connection. Heap-allocated and address-pinned: the transport holds `client` by
// pointer, so these must not live in a relocating array body.
Conn :: struct {
    // Lookup identity: `local` or `remote:<device_id>`. Owned.
    key:         string,

    // Protocol driver. Address-pinned; the transport holds this field by pointer.
    client:      client.Client,

    // True after a successful `client_open`, including once `.Closed`. False if open never ran.
    live:        bool,

    // In-flight connect promise; nil after ready, error, or close.
    connect_job: ^Client_Promise,

    // Roster device id; empty for an unenrolled local. Owned.
    device_id:   string,

    // Enrolled display name, or empty. Owned.
    name:        string,
}

// The private `yuke:client-native` module; `js/client.js` is the typed surface.
client_module :: proc() -> js.Module {
    return {name = CLIENT_NATIVE_MODULE, init = client_module_init, exports = CLIENT_NATIVE_EXPORTS}
}

// Installs `native.{connect,disconnect,request,state,connections,devices}` plus the session natives.
client_module_init :: proc "c" (ctx: ^qjs.Context, m: ^qjs.Module_Def) -> c.int {
    context = runtime.default_context()

    native := qjs.new_object(ctx)
    _ = qjs.set_property(ctx, native, "connect", qjs.new_function(ctx, client_js_connect, "connect", 1))
    _ = qjs.set_property(ctx, native, "disconnect", qjs.new_function(ctx, client_js_disconnect, "disconnect", 1))
    _ = qjs.set_property(ctx, native, "request", qjs.new_function(ctx, client_js_request, "request", 3))
    _ = qjs.set_property(ctx, native, "state", qjs.new_function(ctx, client_js_state, "state", 1))
    _ = qjs.set_property(ctx, native, "connections", qjs.new_function(ctx, client_js_connections, "connections", 0))
    _ = qjs.set_property(ctx, native, "devices", qjs.new_function(ctx, client_js_devices, "devices", 0))
    session_native_install(ctx, native)

    if !qjs.set_module_export(ctx, m, "native", native) do return -1

    return 0
}

// `native.connect(opts)` → Promise<connKey>. Throws on bad args or a live duplicate key;
// rejects on transport / enrollment failure. Resolves with the key on `client_on_ready`.
@(private = "file")
client_js_connect :: proc "c" (ctx: ^qjs.Context, this: qjs.Value, argc: c.int, argv: [^]qjs.Value) -> qjs.Value {
    context = runtime.default_context()
    _ = this

    h := host_from_ctx(ctx)
    if h == nil do return qjs.throw_type_error(ctx, "yuke:client has no host")

    if h.done do return qjs.throw_type_error(ctx, "yuke:client host is shutting down")

    if argc < 1 || !qjs.is_object(argv[0]) do return qjs.throw_type_error(ctx, "connect expects an options object")

    options, options_ok := client_connect_options(ctx, argv[0])
    if !options_ok do return qjs.throw_type_error(ctx, "connect options are invalid")

    key := conn_key_of(options)
    conn_reap_closed(h, key)

    if conn_by_key(h, key) != nil do return qjs.throw_type_error(ctx, "a connection for this key already exists")

    if options.remote && remote_by_device(h, options.device) != nil {
        return qjs.throw_type_error(ctx, "a connection for this key already exists")
    }

    if h.drive == nil || h.drive.loop == nil do return qjs.throw_type_error(ctx, "yuke:client has no drive")

    job, promise := client_promise_new(h)
    if job == nil {
        if qjs.is_exception(promise) do return promise

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
        headers = strings.concatenate({"Authorization: Bearer ", options.token, "\r\n"}, h.allocator)
        defer delete(headers, h.allocator)
    }

    scheme := ws.Scheme.Ws
    if options.secure do scheme = .Wss

    transport := client.ws_create(
        h.drive.loop,
        {scheme = scheme, host = options.host, port = options.port, path = "/ws", extra_headers = headers},
        h.allocator,
    )

    conn, slot_ok := conn_slot_new(h, key)
    if !slot_ok {
        transport->destroy()
        client_promise_reject(job, "out_of_memory", false)
        return promise
    }

    callbacks := client.Client_Callbacks {
        on_ready     = client_on_ready,
        on_broadcast = client_on_broadcast,
        on_close     = client_on_close,
        on_error     = client_on_error,
    }

    open_err := client.client_open(&conn.client, transport, "yuke", "0.1.0", callbacks, h, h.allocator)
    if open_err != .None {
        conn_remove(h, conn)
        client_promise_reject(job, client_protocol_error_wire(open_err), false)
        return promise
    }

    conn.live = true
    conn.connect_job = job

    return promise
}

// `native.disconnect(connKey)`. Throws if the key is missing from argv. No-op if that slot is
// absent, already closed, or closing. Cancels an in-flight remote fetch for the same key.
@(private = "file")
client_js_disconnect :: proc "c" (ctx: ^qjs.Context, this: qjs.Value, argc: c.int, argv: [^]qjs.Value) -> qjs.Value {
    context = runtime.default_context()
    _ = this

    h := host_from_ctx(ctx)
    if h == nil do return qjs.throw_type_error(ctx, "yuke:client has no host")

    if argc < 1 || !qjs.is_string(argv[0]) do return qjs.throw_type_error(ctx, "disconnect expects a connection key")

    key, key_ok := qjs.to_string(ctx, argv[0])
    if !key_ok do return qjs.exception()

    defer qjs.free_string(ctx, key)

    // Cancel a remote connect still fetching its roster/ticket; its promise rejects.
    if remote_connect_cancel_key(h, key) do return qjs.undefined()

    conn := conn_by_key(h, key)
    if conn == nil || !conn.live || conn.client.state == .Closed || conn.client.state == .Closing {
        return qjs.undefined()
    }

    client.client_close(&conn.client)

    return qjs.undefined()
}

// `native.request(connKey, method, params)` → Promise<JSON response>. Throws on bad args or a
// blocked method (`initialize`, `auth.set_api_key`). A missing/dead slot rejects `not_ready`.
@(private = "file")
client_js_request :: proc "c" (ctx: ^qjs.Context, this: qjs.Value, argc: c.int, argv: [^]qjs.Value) -> qjs.Value {
    context = runtime.default_context()
    _ = this

    h := host_from_ctx(ctx)
    if h == nil do return qjs.throw_type_error(ctx, "yuke:client has no host")

    if h.done do return qjs.throw_type_error(ctx, "yuke:client host is shutting down")

    if argc < 3 || !qjs.is_string(argv[0]) || !qjs.is_string(argv[1]) || !qjs.is_object(argv[2]) {
        return qjs.throw_type_error(ctx, "request expects a connection key, method, and params object")
    }

    key, key_ok := qjs.to_string(ctx, argv[0])
    if !key_ok do return qjs.exception()

    defer qjs.free_string(ctx, key)

    method_text, method_ok := qjs.to_string(ctx, argv[1])
    if !method_ok do return qjs.exception()

    defer qjs.free_string(ctx, method_text)

    method, known := wire.method_name_from_wire(method_text)
    if !known || method == .Initialize || method == .Auth_Set_Api_Key do return qjs.throw_type_error(ctx, "request method is not available")

    params, params_ok := client_request_params(ctx, method, argv[2])
    if !params_ok do return qjs.throw_type_error(ctx, "request params failed wire validation")

    job, promise := client_promise_new(h)
    if job == nil {
        if qjs.is_exception(promise) do return promise

        return qjs.throw_type_error(ctx, "out of memory")
    }

    conn := conn_by_key(h, key)
    if conn == nil || !conn.live {
        client_promise_reject(job, "not_ready", false)
        return promise
    }

    _, send_err := client.client_send_request(&conn.client, method, params, client_on_request_complete, job)
    if send_err != .None do client_promise_reject(job, client_protocol_error_wire(send_err), false)

    return promise
}

// `native.state(connKey)` → `"connecting"|"ready"|"closing"|"disconnected"`. Throws without a
// key. An in-flight remote fetch for that key reports connecting before a slot exists.
@(private = "file")
client_js_state :: proc "c" (ctx: ^qjs.Context, this: qjs.Value, argc: c.int, argv: [^]qjs.Value) -> qjs.Value {
    context = runtime.default_context()
    _ = this

    h := host_from_ctx(ctx)
    if h == nil do return qjs.new_string(ctx, "disconnected")

    if argc < 1 || !qjs.is_string(argv[0]) do return qjs.throw_type_error(ctx, "state expects a connection key")

    key, key_ok := qjs.to_string(ctx, argv[0])
    if !key_ok do return qjs.exception()

    defer qjs.free_string(ctx, key)

    // A remote connect reports "connecting" through its whole roster/ticket/dial phase, before
    // a daemon client exists.
    if remote_by_key(h, key) != nil do return qjs.new_string(ctx, "connecting")

    conn := conn_by_key(h, key)
    if conn == nil || !conn.live do return qjs.new_string(ctx, "disconnected")

    return qjs.new_string(ctx, client_state_wire(conn.client.state))
}

// `native.connections()` → `[{key, state}, …]`. Live slots plus an in-flight remote fetch.
// `set_property` / `set_index` consume the values; do not free them.
@(private = "file")
client_js_connections :: proc "c" (ctx: ^qjs.Context, this: qjs.Value, argc: c.int, argv: [^]qjs.Value) -> qjs.Value {
    context = runtime.default_context()
    _ = this
    _ = argc
    _ = argv

    h := host_from_ctx(ctx)
    arr := qjs.new_array(ctx)
    if h == nil do return arr

    i := u32(0)
    for conn in h.conns {
        if !conn.live do continue

        obj := client_connection_info(ctx, conn.key, client_state_wire(conn.client.state), conn.name, conn.device_id)
        _ = qjs.set_index(ctx, arr, i, obj)
        i += 1
    }

    for rc in h.remotes {
        key := conn_key_remote(rc.device_id if rc.device_id != "" else rc.device, context.temp_allocator)
        obj := client_connection_info(ctx, key, "connecting", rc.name, rc.device_id)
        _ = qjs.set_index(ctx, arr, i, obj)
        i += 1
    }

    return arr
}

// `native.devices()` → Promise<Device[]>. Empty when not enrolled. Shares the one roster GET
// with in-flight remote connects.
@(private = "file")
client_js_devices :: proc "c" (ctx: ^qjs.Context, this: qjs.Value, argc: c.int, argv: [^]qjs.Value) -> qjs.Value {
    context = runtime.default_context()
    _ = this
    _ = argc
    _ = argv

    h := host_from_ctx(ctx)
    if h == nil do return qjs.throw_type_error(ctx, "yuke:client has no host")

    if h.done do return qjs.throw_type_error(ctx, "yuke:client host is shutting down")

    job, promise := client_promise_new(h)
    if job == nil {
        if qjs.is_exception(promise) do return promise

        return qjs.throw_type_error(ctx, "out of memory")
    }

    roster_devices(h, job, false)

    return promise
}

@(private = "file")
client_connection_info :: proc(ctx: ^qjs.Context, key, state, name, device_id: string) -> qjs.Value {
    obj := qjs.new_object(ctx)
    _ = qjs.set_property(ctx, obj, "key", qjs.new_string(ctx, key))
    _ = qjs.set_property(ctx, obj, "state", qjs.new_string(ctx, state))
    _ = qjs.set_property(ctx, obj, "name", qjs.new_string(ctx, name))
    _ = qjs.set_property(ctx, obj, "deviceId", qjs.new_string(ctx, device_id))

    return obj
}

// Decode connect options from a JS object. Remote requires a non-empty device name; local
// defaults host to 127.0.0.1 and requires a valid port. Strings live on the temp allocator.
@(private = "file")
client_connect_options :: proc(ctx: ^qjs.Context, value: qjs.Value) -> (options: Client_Connect_Options, ok: bool) {
    encoded := qjs.json_stringify(ctx, value)
    if qjs.is_exception(encoded) || qjs.is_undefined(encoded) do return {}, false

    defer qjs.free_value(ctx, encoded)

    text, text_ok := qjs.to_string(ctx, encoded)
    if !text_ok do return {}, false

    defer qjs.free_string(ctx, text)

    if json.unmarshal(transmute([]byte)text, &options, .JSON, context.temp_allocator) != nil do return {}, false

    // A remote connect selects the daemon by roster device id (name is a fallback).
    if options.remote {
        if options.device == "" do return {}, false

        return options, true
    }

    if options.host == "" do options.host = "127.0.0.1"

    if options.port <= 0 || options.port > 65535 do return {}, false

    return options, true
}

// Decode and wire-validate RPC params for `method` from a JS object. Borrowed from the temp
// allocator for the duration of the send.
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
    if qjs.is_exception(encoded) || qjs.is_undefined(encoded) do return nil, false

    defer qjs.free_value(ctx, encoded)

    text, text_ok := qjs.to_string(ctx, encoded)
    if !text_ok do return nil, false

    defer qjs.free_string(ctx, text)

    d := json.decoder_init(text, context.temp_allocator)
    params, decode_err := wire.request_params_from_reader(method, &d)
    if decode_err != .None || json.dec_finish(&d) != .None do return nil, false

    if wire.request_params_validate(params) != .None do return nil, false

    return params, true
}

// Allocate a JS Promise and bump `h.js.pending`. The job owns the resolve/reject functions
// until settle. On `new_promise` failure the job is freed and `promise` is the exception.
@(private)
client_promise_new :: proc(h: ^Host) -> (job: ^Client_Promise, promise: qjs.Value) {
    assert(h != nil && h.js.ctx != nil, "a client promise needs a live host")

    job = new(Client_Promise, h.allocator)

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

// Fulfill `job` with `value` (consumed). `drain` runs microtasks after settle.
@(private)
client_promise_resolve :: proc(job: ^Client_Promise, value: qjs.Value, drain: bool) {
    client_promise_settle(job, value, true, drain)
}

// Reject `job` with `reason` as a JS string. `drain` runs microtasks after settle.
@(private)
client_promise_reject :: proc(job: ^Client_Promise, reason: string, drain: bool) {
    assert(job != nil && job.host != nil, "client promise rejection needs a job")

    value := qjs.new_string(job.host.js.ctx, reason)
    client_promise_settle(job, value, false, drain)
}

// Call resolve or reject, drop `pending`, free the job. `value` is consumed. Must not run
// after the JS context is gone.
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

    if run_jobs do js.drain(&h.js)
}

// Initialize accepted: dispatch `{type:"conn", kind:"ready", key, workspaces}` from hello, then
// resolve the slot's connect promise with its key. JS must not list workspaces a second time.
client_on_ready :: proc(c: ^client.Client, hello: wire.Initialize_Result) {
    assert(c != nil && c.user_data != nil, "ready callback lost its host")

    h := (^Host)(c.user_data)
    conn := conn_by_client(h, c)
    assert(conn != nil && conn.live, "ready callback crossed connections")
    assert(conn.connect_job != nil, "ready callback lost its connect promise")

    job := conn.connect_job
    conn.connect_job = nil
    session_subscribe_conn(h, conn)
    host_dispatch_conn_ready(h, conn.key, hello.workspaces)
    client_promise_resolve(job, qjs.new_string(h.js.ctx, conn.key), true)
}

// Terminal close for one slot. Drops only this connection's replicas, then `{type:"conn",
// kind:"close"}`. A pending connect job on this slot rejects `connection_closed`.
client_on_close :: proc(c: ^client.Client, code: client.Close_Code) {
    assert(c != nil && c.user_data != nil, "close callback lost its host")

    h := (^Host)(c.user_data)
    conn := conn_by_client(h, c)
    assert(conn != nil && conn.live, "close callback crossed connections")

    entries_drop_conn(h, conn.key)
    host_dispatch_conn_close(h, conn.key, u16(code))

    if conn.connect_job != nil {
        job := conn.connect_job
        conn.connect_job = nil
        client_promise_reject(job, "connection_closed", true)
    }
}

// Protocol/transport error on one slot. `{type:"conn", kind:"error"}` then rejects a still-pending
// connect job; the close callback follows if the driver goes terminal.
client_on_error :: proc(c: ^client.Client, err: client.Protocol_Error) {
    assert(c != nil && c.user_data != nil, "error callback lost its host")
    assert(err != .None, "client error callback needs an error")

    h := (^Host)(c.user_data)
    conn := conn_by_client(h, c)
    assert(conn != nil && conn.live, "error callback crossed connections")

    host_dispatch_conn_error(h, conn.key, client_protocol_error_wire(err))

    if conn.connect_job != nil {
        job := conn.connect_job
        conn.connect_job = nil
        client_promise_reject(job, client_protocol_error_wire(err), true)
    }
}

// Settle one RPC: encode the wire response as JSON for JS, or reject with a protocol code.
client_on_request_complete :: proc(c: ^client.Client, outcome: client.Request_Outcome, user_data: rawptr) {
    assert(c != nil && c.user_data != nil, "request completion lost its host")
    assert(user_data != nil, "request completion lost its promise")

    h := (^Host)(c.user_data)
    job := (^Client_Promise)(user_data)
    conn := conn_by_client(h, c)
    assert(conn != nil && conn.live, "request completion crossed connections")
    assert(job.host == h, "request completion crossed hosts")

    switch result in outcome {
    case client.Request_Response:
        e, encoded := wire.response_encode(result.response, h.allocator)
        defer json.emitter_destroy(&e)
        if !encoded {
            client_promise_reject(job, "out_of_memory", true)
            return
        }

        value := qjs.new_string(h.js.ctx, json.to_string(&e))
        client_promise_resolve(job, value, true)

    case client.Request_Failure:
        client_promise_reject(job, client_protocol_error_wire(result.error), true)
    }
}

// Host teardown: abort every live slot, wait up to `CLIENT_SHUTDOWN_TIMEOUT` for the
// terminal callback, then destroy. Drops replicas first. Asserts every connect job settled.
conns_destroy :: proc(h: ^Host) {
    assert(h != nil, "conns destroy needs a host")

    open_session_teardown(h)

    deadline := time.time_add(time.now(), CLIENT_SHUTDOWN_TIMEOUT)

    for conn in h.conns {
        if !conn.live do continue
        if conn.client.state == .Closed do continue
        if conn.client.state == .Connecting {
            client.client_close(&conn.client)
            continue
        }

        // Abort even if already Closing — a graceful close waits ~5s for the peer.
        conn.client.state = .Closing
        conn.client.transport->abort(.Canceled)
    }

    for time.now()._nsec < deadline._nsec {
        if !conns_any_open(h) do break
        _ = nbio.tick(10 * time.Millisecond)
    }

    for conn in h.conns {
        if !conn.live do continue

        assert(conn.client.state == .Closed, "daemon connection did not finish bounded shutdown")
        assert(conn.connect_job == nil, "daemon shutdown did not settle connect")
        client.client_destroy(&conn.client)
        conn.live = false
    }

    for conn in h.conns {
        conn_free(h, conn)
    }

    delete(h.conns)
    h.conns = {}
}

// The lookup key for a connect: local is fixed; a remote is `remote:` plus the device id (or
// the lookup string until the roster resolves it).
conn_key_of :: proc(options: Client_Connect_Options) -> string {
    if options.remote do return conn_key_remote(options.device, context.temp_allocator)

    return CONN_LOCAL
}

// `"remote:" + device`. Caller owns the result.
conn_key_remote :: proc(device: string, allocator: mem.Allocator) -> string {
    return strings.concatenate({CONN_REMOTE_PREFIX, device}, allocator)
}

// True when `key` is the relay slot for `device` (`remote:` + name).
conn_key_is_remote_device :: proc(key, device: string) -> bool {
    return strings.has_prefix(key, CONN_REMOTE_PREFIX) && key[len(CONN_REMOTE_PREFIX):] == device
}

// Linear find by key. Nil if absent (including a closed slot already reaped).
conn_by_key :: proc(h: ^Host, key: string) -> ^Conn {
    assert(h != nil, "conn_by_key needs a host")

    for conn in h.conns {
        if conn.key == key do return conn
    }

    return nil
}

// Linear find by `client` pointer — callbacks look up their slot this way.
conn_by_client :: proc(h: ^Host, c: ^client.Client) -> ^Conn {
    assert(h != nil && c != nil, "conn_by_client needs a host and client")

    for conn in h.conns {
        if &conn.client == c do return conn
    }

    return nil
}

// If `key` has a `.Closed` slot, destroy it so a reconnect can reuse the key. No-op if the
// slot is still live.
conn_reap_closed :: proc(h: ^Host, key: string) {
    assert(h != nil, "conn_reap_closed needs a host")

    for conn, i in h.conns {
        if conn.key != key do continue
        if conn.client.state != .Closed do return

        assert(conn.connect_job == nil, "a closed connection settled its connect job")
        if conn.live do client.client_destroy(&conn.client)

        conn_free(h, conn)
        unordered_remove(&h.conns, i)

        return
    }
}

// Allocate a pinned slot with `key`. The caller opens the client; on open failure it must
// `conn_remove`. False on alloc failure (no slot is retained).
conn_slot_new :: proc(h: ^Host, key: string) -> (^Conn, bool) {
    assert(h != nil && key != "", "conn_slot_new needs a host and key")

    conn := new(Conn, h.allocator)
    conn.key = strings.clone(key, h.allocator)
    if _, aerr := append(&h.conns, conn); aerr != nil {
        conn_free(h, conn)
        return nil, false
    }

    return conn, true
}

conn_free :: proc(h: ^Host, conn: ^Conn) {
    assert(h != nil && conn != nil, "conn_free needs a host and slot")

    delete(conn.key, h.allocator)
    delete(conn.device_id, h.allocator)
    delete(conn.name, h.allocator)
    free(conn, h.allocator)
}

// Drop a slot that never reached `client_open` (open failed). Does not `client_destroy`.
conn_remove :: proc(h: ^Host, conn: ^Conn) {
    assert(h != nil && conn != nil, "conn_remove needs a host and slot")

    for existing, i in h.conns {
        if existing != conn do continue

        conn_free(h, conn)
        unordered_remove(&h.conns, i)

        return
    }

    assert(false, "conn_remove on a slot the host does not own")
}

// Drop slots that were never `client_open`'d — tests that fake a live client without a transport.
conns_free_unopened :: proc(h: ^Host) {
    assert(h != nil, "conns_free_unopened needs a host")

    for conn in h.conns {
        assert(!conn.live || conn.client.transport.open == nil, "conns_free_unopened on a real transport")
        conn_free(h, conn)
    }

    delete(h.conns)
    h.conns = {}
}

// True if any live slot is still short of `.Closed` — used to wait out shutdown.
@(private = "file")
conns_any_open :: proc(h: ^Host) -> bool {
    for conn in h.conns {
        if conn.live && conn.client.state != .Closed do return true
    }

    return false
}

// Map a protocol state to the JS `ConnectionState` strings.
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

// Map a protocol error to the JS `ClientError.code` strings. `.None` is a caller bug.
@(private)
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
