/*
Remote (relay) connect for `yuke:client`. The local WebSocket path in `client.odin` dials a
daemon directly; this drives the extra control-plane steps a relay connection needs first,
entirely on the client's event loop so the TUI never blocks: one shared roster GET, resolve
the device (id, then unique name) to its pinned static key, fetch a single-use connect
ticket, then build the `relay_create` transport and hand it to the same `client_open` the
local path uses.

In-flight attempts live in `Host.remotes` until they fail (rejecting the connect promise)
or hand a live transport to a `Conn` slot (`client_on_ready` resolves the promise). The
control-plane HTTP client is owned by the host and reused — `client_destroy` may not run
inside a curl callback, so it is torn down only at host teardown.
*/
package tui

import "core:crypto/ecdh"
import "core:log"
import "core:mem"
import "core:os"
import "core:strings"
import "core:time"

import "src:client"
import "src:relay"

import "libs:bindings/curl"
import qjs "libs:bindings/quickjs"
import "libs:json"

// Control-plane paths the client calls with its Session credential.
REMOTE_ROSTER_PATH :: "/api/v1/devices"

REMOTE_CONNECT_TICKETS_PATH :: "/api/v1/connect_tickets"

// Per-request bounds for a roster or connect-ticket fetch.
REMOTE_CONNECT_TIMEOUT :: 10 * time.Second

REMOTE_REQUEST_TIMEOUT :: 30 * time.Second

// Cap on one accumulated control-plane response; a larger body is refused rather than grown.
REMOTE_RESP_MAX :: 256 * 1024

// Cached `GET /api/v1/devices` plus waiters for that one in-flight GET.
Roster_Cache :: struct {
    devices: [dynamic]relay.Roster_Device,
    have:    bool,
    xfer:    curl.Transfer,
    resp:    Remote_Rx,
    waiters: [dynamic]Roster_Waiter,
}

// One waiter on the shared roster GET: a `devices()` promise, a remote connect, or both.
Roster_Waiter :: struct {
    job: ^Client_Promise,
    rc:  ^Remote_Connect,
}

// Client session identity, loaded once.
Identity_Cache :: struct {
    ready:           bool,
    credential:      string,
    static_seed:     [relay.NOISE_STATIC_KEY_SIZE]u8,
    local_device_id: string,
    cloud_url:       string,
}

// One in-flight remote connect attempt. Owns its ticket fetch; borrows the host identity
// and roster. Freed by `remote_free`, which wipes nothing on the shared identity.
Remote_Connect :: struct {
    host:      ^Host,
    job:       ^Client_Promise,

    // Lookup string from `connect({device})` — a roster id, or a display name until resolved.
    device:    string,
    device_id: string,
    name:      string,
    pin:       [relay.NOISE_STATIC_KEY_SIZE]u8,
    req_body:  []u8,
    xfer:      curl.Transfer,
    resp:      Remote_Rx,
}

// A bounded accumulator for one control-plane response body.
Remote_Rx :: struct {
    body:     [dynamic]u8,
    overflow: bool,
}

// Begin a remote connect for `device` (roster id, with unique name as fallback). `job` is the
// connect promise. Called from `client_js_connect`.
remote_connect_start :: proc(h: ^Host, job: ^Client_Promise, device: string) {
    assert(h != nil && job != nil, "remote connect needs a host and a promise")
    assert(device != "", "remote connect needs a device")

    if reason := identity_ensure(h); reason != "" {
        client_promise_reject(job, reason, true)
        return
    }

    if !remote_curl_ensure(h) {
        client_promise_reject(job, "out_of_memory", true)
        return
    }

    rc := new(Remote_Connect, h.allocator)
    rc.host = h
    rc.job = job
    rc.resp.body.allocator = h.allocator
    rc.device = strings.clone(device, h.allocator)
    append(&h.remotes, rc)

    if h.roster.have {
        remote_bind_and_ticket(rc)
        return
    }

    append(&h.roster.waiters, Roster_Waiter{rc = rc})
    roster_fetch_start(h)
}

// Cancel every in-flight remote and roster waiter. Idempotent. Host teardown and quit.
remote_connect_cancel_all :: proc(h: ^Host) {
    assert(h != nil, "remote_connect_cancel_all needs a host")

    if h.cloud_curl_ready && h.roster.xfer.state == .Running {
        curl.transfer_cancel(&h.roster.xfer)
    }

    for w in h.roster.waiters {
        if w.job != nil do client_promise_reject(w.job, "connection_closed", true)
    }

    clear(&h.roster.waiters)

    for len(h.remotes) > 0 {
        remote_fail(h.remotes[0], "connection_closed")
    }

    delete(h.remotes)
    h.remotes = {}
    roster_clear(h)
    identity_clear(h)
}

// Cancel the in-flight remote whose lookup or resolved id matches `key`. True if one was canceled.
remote_connect_cancel_key :: proc(h: ^Host, key: string) -> bool {
    assert(h != nil, "remote_connect_cancel_key needs a host")

    if rc := remote_by_key(h, key); rc != nil {
        remote_fail(rc, "connection_closed")
        return true
    }

    return false
}

remote_by_device :: proc(h: ^Host, device: string) -> ^Remote_Connect {
    assert(h != nil, "remote_by_device needs a host")

    for rc in h.remotes {
        if rc.device == device || rc.device_id == device do return rc
    }

    return nil
}

remote_by_key :: proc(h: ^Host, key: string) -> ^Remote_Connect {
    assert(h != nil, "remote_by_key needs a host")

    for rc in h.remotes {
        if conn_key_is_remote_device(key, rc.device) do return rc
        if rc.device_id != "" && conn_key_is_remote_device(key, rc.device_id) do return rc
    }

    return nil
}

// Resolve `devices()`: empty if not enrolled, the cached roster if present, else one shared GET.
roster_devices :: proc(h: ^Host, job: ^Client_Promise, drain: bool) {
    assert(h != nil && job != nil, "roster_devices needs a host and a promise")

    if reason := identity_ensure(h); reason != "" {
        if reason == "not_enrolled" {
            roster_resolve_empty(h, job, drain)
            return
        }

        client_promise_reject(job, reason, drain)
        return
    }

    if h.roster.have {
        roster_resolve_job(h, job, drain)
        return
    }

    if !remote_curl_ensure(h) {
        client_promise_reject(job, "out_of_memory", drain)
        return
    }

    append(&h.roster.waiters, Roster_Waiter{job = job})
    roster_fetch_start(h)
}

@(private = "file")
roster_resolve_empty :: proc(h: ^Host, job: ^Client_Promise, drain: bool) {
    empty := qjs.parse_json(h.js.ctx, "[]", h.allocator)
    if qjs.is_exception(empty) {
        qjs.free_value(h.js.ctx, empty)
        exc := qjs.get_exception(h.js.ctx)
        qjs.free_value(h.js.ctx, exc)
        client_promise_reject(job, "out_of_memory", drain)
        return
    }

    client_promise_resolve(job, empty, drain)
}

@(private = "file")
roster_resolve_job :: proc(h: ^Host, job: ^Client_Promise, drain: bool) {
    e, encoded := json.marshal(h.roster.devices[:], {}, h.allocator)
    defer delete(e, h.allocator)
    if encoded != nil {
        client_promise_reject(job, "out_of_memory", drain)
        return
    }

    parsed := qjs.parse_json(h.js.ctx, string(e), h.allocator)
    if qjs.is_exception(parsed) {
        qjs.free_value(h.js.ctx, parsed)
        exc := qjs.get_exception(h.js.ctx)
        qjs.free_value(h.js.ctx, exc)
        client_promise_reject(job, "out_of_memory", drain)
        return
    }

    client_promise_resolve(job, parsed, drain)
}

@(private = "file")
identity_ensure :: proc(h: ^Host) -> string {
    if h.ident.ready do return ""

    if h.data_root == "" do return "not_enrolled"

    id, ierr := relay.session_identity_load(h.data_root, h.allocator)
    switch ierr {
    case .None:

    case .Absent, .Stale:
        return "not_enrolled"

    case .Unreadable, .Malformed, .Key_Invalid, .Write_Failed:
        return "identity_unreadable"
    }

    if !id.has_static_key {
        relay.session_identity_destroy(&id)
        return "not_enrolled"
    }

    defer relay.session_identity_destroy(&id)

    ecdh.private_key_bytes(&id.static_key, h.ident.static_seed[:])
    h.ident.credential = strings.clone(id.credential, h.allocator)
    if id.local_device_id != "" do h.ident.local_device_id = strings.clone(id.local_device_id, h.allocator)
    h.ident.cloud_url = remote_cloud_url(h.allocator)
    h.ident.ready = true

    return ""
}

@(private = "file")
identity_clear :: proc(h: ^Host) {
    if h.ident.credential != "" {
        mem.zero_slice(transmute([]u8)h.ident.credential)
        delete(h.ident.credential, h.allocator)
    }

    delete(h.ident.local_device_id, h.allocator)
    delete(h.ident.cloud_url, h.allocator)
    mem.zero_slice(h.ident.static_seed[:])
    h.ident = {}
}

@(private = "file")
roster_clear :: proc(h: ^Host) {
    for d in h.roster.devices {
        delete(d.device_id, h.allocator)
        delete(d.name, h.allocator)
        delete(d.static_public_key, h.allocator)
    }

    delete(h.roster.devices)
    h.roster.devices = {}
    h.roster.have = false
    delete(h.roster.resp.body)
    h.roster.resp = {}
    delete(h.roster.waiters)
    h.roster.waiters = {}
}

@(private = "file")
roster_store :: proc(h: ^Host, src: []relay.Roster_Device) {
    roster_clear(h)
    h.roster.resp.body.allocator = h.allocator
    for d in src {
        append(
            &h.roster.devices,
            relay.Roster_Device {
                device_id = strings.clone(d.device_id, h.allocator),
                name = strings.clone(d.name, h.allocator),
                static_public_key = strings.clone(d.static_public_key, h.allocator),
                online = d.online,
                is_self = d.is_self,
            },
        )
    }

    h.roster.have = true
}

@(private = "file")
remote_curl_ensure :: proc(h: ^Host) -> bool {
    if h.cloud_curl_ready do return true
    if h.drive == nil || h.drive.loop == nil do return false

    if curl.client_init(&h.cloud_curl, h.drive.loop, h.allocator) != .None do return false

    h.cloud_curl_ready = true
    h.roster.resp.body.allocator = h.allocator

    return true
}

@(private = "file")
roster_fetch_start :: proc(h: ^Host) {
    if h.roster.xfer.state == .Running do return

    remote_rx_reset(&h.roster.resp)

    url := strings.concatenate({h.ident.cloud_url, REMOTE_ROSTER_PATH}, context.temp_allocator)
    bearer := strings.concatenate({relay.BEARER_PREFIX, h.ident.credential}, context.temp_allocator)
    headers := [?]curl.Header{{name = "authorization", value = bearer}, {name = "accept", value = "application/json"}}
    request := curl.Request {
        url             = strings.clone_to_cstring(url, context.temp_allocator),
        headers         = headers[:],
        method          = .Get,
        connect_timeout = REMOTE_CONNECT_TIMEOUT,
        total_timeout   = REMOTE_REQUEST_TIMEOUT,
    }
    callbacks := curl.Callbacks {
        on_body = roster_on_body,
        on_done = roster_on_done,
    }

    if curl.transfer_start(&h.roster.xfer, &h.cloud_curl, request, callbacks, h) != .None {
        roster_fail_waiters(h, "roster_failed")
    }
}

@(private = "file")
roster_on_body :: proc(user: rawptr, chunk: []byte) -> bool {
    h := (^Host)(user)
    if len(h.roster.resp.body) + len(chunk) > REMOTE_RESP_MAX {
        h.roster.resp.overflow = true
        return false
    }

    if _, aerr := append(&h.roster.resp.body, ..chunk); aerr != nil do return false

    return true
}

@(private = "file")
roster_on_done :: proc(user: rawptr, result: curl.Result) {
    h := (^Host)(user)
    defer free_all(context.temp_allocator)

    if result.code != .Ok || result.status < 200 || result.status >= 300 || h.roster.resp.overflow {
        log.errorf("client: roster fetch failed: curl=%v status=%d", result.code, result.status)
        roster_fail_waiters(h, "roster_failed")
        return
    }

    decoded, derr := relay.roster_decode(h.roster.resp.body[:], context.temp_allocator)
    if derr != .None {
        roster_fail_waiters(h, "roster_failed")
        return
    }

    waiters := h.roster.waiters
    h.roster.waiters = {}
    roster_store(h, decoded)

    for w in waiters {
        if w.job != nil do roster_resolve_job(h, w.job, true)
        if w.rc != nil && remote_still(h, w.rc) do remote_bind_and_ticket(w.rc)
    }

    delete(waiters)
}

@(private = "file")
roster_fail_waiters :: proc(h: ^Host, code: string) {
    waiters := h.roster.waiters
    h.roster.waiters = {}
    for w in waiters {
        if w.job != nil do client_promise_reject(w.job, code, true)
        if w.rc != nil && remote_still(h, w.rc) do remote_fail(w.rc, code)
    }

    delete(waiters)
}

@(private = "file")
remote_still :: proc(h: ^Host, rc: ^Remote_Connect) -> bool {
    for existing in h.remotes {
        if existing == rc do return true
    }

    return false
}

// Resolve `rc.device` against the cached roster (id, then unique name), skip self, then ticket.
@(private = "file")
remote_bind_and_ticket :: proc(rc: ^Remote_Connect) {
    h := rc.host
    found: ^relay.Roster_Device
    ambiguous := false
    for &d in h.roster.devices {
        if d.device_id == rc.device {
            found = &d
            ambiguous = false
            break
        }
    }

    if found == nil {
        for &d in h.roster.devices {
            if d.name != rc.device do continue
            if h.ident.local_device_id != "" && d.device_id == h.ident.local_device_id {
                found = &d
                ambiguous = false
                continue
            }
            if found != nil && found.device_id == h.ident.local_device_id do continue
            if found != nil {
                ambiguous = true
                continue
            }
            found = &d
        }
    }

    if found == nil {
        remote_fail(rc, "device_not_found")
        return
    }

    if ambiguous {
        remote_fail(rc, "device_ambiguous")
        return
    }

    if found.is_self || (h.ident.local_device_id != "" && found.device_id == h.ident.local_device_id) {
        remote_fail(rc, "device_not_found")
        return
    }

    if !relay.roster_pin_decode(found.static_public_key, rc.pin[:]) {
        remote_fail(rc, "roster_failed")
        return
    }

    rc.device_id = strings.clone(found.device_id, h.allocator)
    rc.name = strings.clone(found.name, h.allocator)
    key := conn_key_remote(rc.device_id, context.temp_allocator)
    if conn_by_key(h, key) != nil {
        remote_fail(rc, "transport_failed")
        return
    }

    remote_fetch_ticket(rc)
}

@(private = "file")
remote_fetch_ticket :: proc(rc: ^Remote_Connect) {
    remote_rx_reset(&rc.resp)

    body := relay.connect_ticket_encode(rc.device_id, rc.host.allocator)
    rc.req_body = body

    url := strings.concatenate({rc.host.ident.cloud_url, REMOTE_CONNECT_TICKETS_PATH}, context.temp_allocator)
    bearer := strings.concatenate({relay.BEARER_PREFIX, rc.host.ident.credential}, context.temp_allocator)
    headers := [?]curl.Header {
        {name = "authorization", value = bearer},
        {name = "content-type", value = "application/json"},
        {name = "accept", value = "application/json"},
    }
    request := curl.Request {
        url             = strings.clone_to_cstring(url, context.temp_allocator),
        headers         = headers[:],
        method          = .Post,
        body            = rc.req_body,
        connect_timeout = REMOTE_CONNECT_TIMEOUT,
        total_timeout   = REMOTE_REQUEST_TIMEOUT,
    }
    callbacks := curl.Callbacks {
        on_body = remote_on_body,
        on_done = remote_ticket_done,
    }

    if curl.transfer_start(&rc.xfer, &rc.host.cloud_curl, request, callbacks, rc) != .None do remote_fail(rc, "ticket_failed")
}

@(private = "file")
remote_ticket_done :: proc(user: rawptr, result: curl.Result) {
    rc := (^Remote_Connect)(user)
    h := rc.host
    defer free_all(context.temp_allocator)

    if result.code != .Ok || result.status < 200 || result.status >= 300 || rc.resp.overflow {
        log.errorf("client: connect ticket failed: curl=%v status=%d", result.code, result.status)
        remote_fail(rc, "ticket_failed")
        return
    }

    tk, derr := relay.ticket_decode(rc.resp.body[:], context.temp_allocator)
    if derr != .None {
        remote_fail(rc, "ticket_failed")
        return
    }

    transport, terr := client.relay_create(
        h.drive.loop,
        tk.relay_url,
        tk.ticket,
        h.ident.static_seed[:],
        rc.pin[:],
        h.allocator,
    )
    if terr != .None {
        remote_fail(rc, "transport_failed" if terr != .Out_Of_Memory else "out_of_memory")
        return
    }

    callbacks := client.Client_Callbacks {
        on_ready     = client_on_ready,
        on_broadcast = client_on_broadcast,
        on_close     = client_on_close,
        on_error     = client_on_error,
    }

    key := conn_key_remote(rc.device_id, context.temp_allocator)
    conn_reap_closed(h, key)
    if conn_by_key(h, key) != nil {
        transport->destroy()
        remote_fail(rc, "transport_failed")
        return
    }

    conn, slot_ok := conn_slot_new(h, key)
    if !slot_ok {
        transport->destroy()
        remote_fail(rc, "out_of_memory")
        return
    }

    open_err := client.client_open(&conn.client, transport, "yuke", "0.1.0", callbacks, h, h.allocator)
    if open_err != .None {
        conn_remove(h, conn)
        remote_fail(rc, "transport_failed")
        return
    }

    job := rc.job
    conn.live = true
    conn.connect_job = job
    conn.device_id = strings.clone(rc.device_id, h.allocator)
    conn.name = strings.clone(rc.name, h.allocator)
    rc.job = nil
    remote_detach(rc)
    remote_free(rc)
}

@(private = "file")
remote_on_body :: proc(user: rawptr, chunk: []byte) -> bool {
    rc := (^Remote_Connect)(user)
    if len(rc.resp.body) + len(chunk) > REMOTE_RESP_MAX {
        rc.resp.overflow = true
        return false
    }

    if _, aerr := append(&rc.resp.body, ..chunk); aerr != nil do return false

    return true
}

@(private = "file")
remote_fail :: proc(rc: ^Remote_Connect, code: string) {
    h := rc.host
    job := rc.job
    rc.job = nil
    if h.cloud_curl_ready && rc.xfer.state == .Running do curl.transfer_cancel(&rc.xfer)

    remote_detach(rc)
    remote_free(rc)
    if job != nil do client_promise_reject(job, code, true)
}

@(private = "file")
remote_detach :: proc(rc: ^Remote_Connect) {
    h := rc.host
    for existing, i in h.remotes {
        if existing != rc do continue

        unordered_remove(&h.remotes, i)
        return
    }
}

@(private = "file")
remote_free :: proc(rc: ^Remote_Connect) {
    allocator := rc.host.allocator
    delete(rc.resp.body)
    delete(rc.req_body, allocator)
    delete(rc.device, allocator)
    delete(rc.device_id, allocator)
    delete(rc.name, allocator)
    mem.zero_slice(rc.pin[:])
    free(rc, allocator)
}

@(private = "file")
remote_rx_reset :: proc(rx: ^Remote_Rx) {
    clear(&rx.body)
    rx.overflow = false
}

@(private = "file")
DEFAULT_CLOUD_URL :: "https://platform.yuke.sh"

@(private = "file")
CLOUD_URL_ENV :: "YUKE_CLOUD_URL"

@(private = "file")
remote_cloud_url :: proc(allocator: mem.Allocator) -> string {
    if v, set := os.lookup_env(CLOUD_URL_ENV, allocator); set {
        if v != "" do return v

        delete(v, allocator)
    }

    return strings.clone(DEFAULT_CLOUD_URL, allocator)
}
