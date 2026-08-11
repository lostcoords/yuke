/*
Remote (relay) connect for `yuke:client`. The local WebSocket path in `client.odin` dials a
daemon directly; this drives the extra control-plane steps a relay connection needs first,
entirely on the client's event loop so the TUI never blocks: fetch the account roster, resolve
the named device to its pinned static key, fetch a single-use connect ticket, then build the
`relay_create` transport and hand it to the same `client_open` the local path uses.

One attempt lives in `Host.remote` from the first fetch until it either fails (rejecting the
connect promise) or hands a live transport to `Host.daemon` (where `client_on_ready` resolves
the promise). The control-plane HTTP client is owned by the host and reused across attempts —
`client_destroy` may not run inside a curl callback, so it is torn down only at host teardown.
*/
package tui

import "core:crypto/ecdh"
import "core:log"
import "core:mem"
import "core:os"
import "core:strings"
import "core:time"

import client "src:client"
import relay "src:relay"

import curl "libs:bindings/curl"

// Control-plane paths the client calls with its device credential.
REMOTE_ROSTER_PATH :: "/api/v1/devices"

REMOTE_CONNECT_TICKETS_PATH :: "/api/v1/connect_tickets"

// Per-request bounds for a roster or connect-ticket fetch.
REMOTE_CONNECT_TIMEOUT :: 10 * time.Second

REMOTE_REQUEST_TIMEOUT :: 30 * time.Second

// Cap on one accumulated control-plane response; a larger body is refused rather than grown.
REMOTE_RESP_MAX :: 256 * 1024

// One in-flight remote connect attempt. Owns its identity material and fetch buffers; borrows
// the host's control-plane curl client. Freed by `remote_free`, which wipes the credential and
// static key.
Remote_Connect :: struct {
    // Owning host and the connect promise to settle (nil once handed to the daemon connection).
    host:        ^Host,
    job:         ^Client_Promise,

    // The target device name to resolve, the control-plane base, and the device credential
    // (secret) presented as the bearer. All owned.
    device:      string,
    cloud_url:   string,
    credential:  string,

    // This device's own X25519 static private key, and the target daemon's pinned public key
    // once the roster resolves it.
    static_seed: [relay.NOISE_STATIC_KEY_SIZE]u8,
    pin:         [relay.NOISE_STATIC_KEY_SIZE]u8,

    // The resolved target device id and the connect-ticket request body, owned across the POST.
    device_id:   string,
    req_body:    []u8,

    // The in-flight transfer and the bounded response accumulator, reused across both fetches.
    xfer:        curl.Transfer,
    resp:        Remote_Rx,
}

// A bounded accumulator for one control-plane response body.
Remote_Rx :: struct {
    body:     [dynamic]u8,
    overflow: bool,
}

// Begin a remote connect for the named device: load this device's identity, then fetch the
// roster. `job` is the connect promise; it is rejected on any failure and resolved later by
// `client_on_ready` once the transport opens. Called from `client_js_connect`.
remote_connect_start :: proc(h: ^Host, job: ^Client_Promise, device: string) {
    assert(h != nil && job != nil, "remote connect needs a host and a promise")
    assert(device != "", "remote connect needs a device name")
    assert(h.remote == nil, "remote connect started while one was in flight")

    if h.data_root == "" {
        client_promise_reject(job, "not_enrolled", true)

        return
    }

    id, ierr := relay.identity_load(h.data_root, h.allocator)
    switch ierr {
    case .None:

    case .Absent:
        client_promise_reject(job, "not_enrolled", true)

        return

    case .Unreadable, .Malformed, .Key_Invalid, .Out_Of_Memory, .Write_Failed:
        client_promise_reject(job, "identity_unreadable", true)

        return
    }

    defer relay.identity_destroy(&id)

    rc, aerr := new(Remote_Connect, h.allocator)
    if aerr != nil {
        client_promise_reject(job, "out_of_memory", true)

        return
    }

    rc.host = h
    rc.job = job
    rc.resp.body.allocator = h.allocator
    ecdh.private_key_bytes(&id.static_key, rc.static_seed[:])

    clone_err: mem.Allocator_Error
    rc.device, clone_err = strings.clone(device, h.allocator)
    if clone_err == nil {
        rc.cloud_url, clone_err = remote_cloud_url(h.allocator)
    }
    if clone_err == nil {
        rc.credential, clone_err = strings.clone(id.credential, h.allocator)
    }
    if clone_err != nil {
        remote_free(rc)
        client_promise_reject(job, "out_of_memory", true)

        return
    }

    if !h.cloud_curl_ready {
        if curl.client_init(&h.cloud_curl, h.drive.loop, h.allocator) != .None {
            remote_free(rc)
            client_promise_reject(job, "out_of_memory", true)

            return
        }

        h.cloud_curl_ready = true
    }

    h.remote = rc
    remote_fetch_roster(rc)
}

// Cancel an in-flight remote connect, rejecting its promise. Idempotent. Used by
// `disconnect()` and host teardown; safe to call when no attempt is in flight.
remote_connect_cancel :: proc(h: ^Host) {
    if h.remote == nil {
        return
    }

    rc := h.remote
    if h.cloud_curl_ready && rc.xfer.state == .Running {
        curl.transfer_cancel(&rc.xfer)
    }

    job := rc.job
    h.remote = nil
    rc.job = nil
    remote_free(rc)

    if job != nil {
        client_promise_reject(job, "connection_closed", true)
    }
}

// Fetch the account roster, then resolve the named device on completion.
@(private = "file")
remote_fetch_roster :: proc(rc: ^Remote_Connect) {
    remote_rx_reset(&rc.resp)

    url := strings.concatenate({rc.cloud_url, REMOTE_ROSTER_PATH}, context.temp_allocator)
    bearer := strings.concatenate({relay.BEARER_PREFIX, rc.credential}, context.temp_allocator)

    headers := [?]curl.Header{{name = "authorization", value = bearer}, {name = "accept", value = "application/json"}}
    request := curl.Request {
        url             = strings.clone_to_cstring(url, context.temp_allocator),
        headers         = headers[:],
        method          = .Get,
        connect_timeout = REMOTE_CONNECT_TIMEOUT,
        total_timeout   = REMOTE_REQUEST_TIMEOUT,
    }
    callbacks := curl.Callbacks {
        on_body = remote_on_body,
        on_done = remote_roster_done,
    }

    if curl.transfer_start(&rc.xfer, &rc.host.cloud_curl, request, callbacks, rc) != .None {
        remote_fail(rc, "roster_failed")
    }
}

// The roster fetch finished. Resolve the named non-self device to its pinned key, then fetch a
// connect ticket. Control-plane input, so any bad status or body rejects rather than asserting.
@(private = "file")
remote_roster_done :: proc(user: rawptr, result: curl.Result) {
    rc := (^Remote_Connect)(user)

    defer free_all(context.temp_allocator)

    if result.code != .Ok || result.status < 200 || result.status >= 300 || rc.resp.overflow {
        log.errorf("client: roster fetch failed: curl=%v status=%d", result.code, result.status)
        remote_fail(rc, "roster_failed")

        return
    }

    roster, derr := relay.roster_decode(rc.resp.body[:], context.temp_allocator)
    if derr != .None {
        remote_fail(rc, "roster_failed")

        return
    }

    // Resolve the target by name. Self is a valid target — forcing the relay to this device's
    // own daemon is a supported centralized/testing setup. A missing or duplicated name is a
    // selection error the caller must fix, not a transport failure.
    found := false
    ambiguous := false
    target_id: string
    target_key: string
    for device in roster {
        if device.name != rc.device {
            continue
        }

        if found {
            ambiguous = true
            break
        }

        found = true
        target_id = device.device_id
        target_key = device.static_public_key
    }

    if !found {
        remote_fail(rc, "device_not_found")

        return
    }

    if ambiguous {
        remote_fail(rc, "device_ambiguous")

        return
    }

    if !relay.roster_pin_decode(target_key, rc.pin[:]) {
        remote_fail(rc, "roster_failed")

        return
    }

    did, cerr := strings.clone(target_id, rc.host.allocator)
    if cerr != nil {
        remote_fail(rc, "out_of_memory")

        return
    }

    rc.device_id = did
    remote_fetch_ticket(rc)
}

// Fetch a single-use connect ticket for the resolved device, then dial on completion.
@(private = "file")
remote_fetch_ticket :: proc(rc: ^Remote_Connect) {
    remote_rx_reset(&rc.resp)

    body, berr := relay.connect_ticket_encode(rc.device_id, rc.host.allocator)
    if berr != .None {
        remote_fail(rc, "out_of_memory")

        return
    }

    rc.req_body = body

    url := strings.concatenate({rc.cloud_url, REMOTE_CONNECT_TICKETS_PATH}, context.temp_allocator)
    bearer := strings.concatenate({relay.BEARER_PREFIX, rc.credential}, context.temp_allocator)

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

    if curl.transfer_start(&rc.xfer, &rc.host.cloud_curl, request, callbacks, rc) != .None {
        remote_fail(rc, "ticket_failed")
    }
}

// The connect-ticket fetch finished. Build the relay transport pinned to the daemon's key and
// hand it to `client_open`; from here the shared client callbacks resolve or reject the promise.
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
        rc.static_seed[:],
        rc.pin[:],
        h.allocator,
    )
    if terr != .None {
        remote_fail(rc, "transport_failed" if terr != .Out_Of_Memory else "out_of_memory")

        return
    }

    callbacks := client.Client_Callbacks {
        on_ready = client_on_ready,
        on_close = client_on_close,
        on_error = client_on_error,
    }

    open_err := client.client_open(&h.daemon.client, transport, "yuke", "0.1.0", callbacks, h, h.allocator)
    if open_err != .None {
        remote_fail(rc, "out_of_memory" if open_err == .Out_Of_Memory else "transport_failed")

        return
    }

    // The transport is dialing; the connect promise now belongs to the daemon connection, so
    // free the fetch scaffolding without settling it. The host's curl client stays for reuse.
    job := rc.job
    h.daemon.live = true
    h.daemon.connect_job = job
    rc.job = nil
    h.remote = nil
    remote_free(rc)
}

// Accumulate one response chunk, refusing a body past the cap.
@(private = "file")
remote_on_body :: proc(user: rawptr, chunk: []byte) -> bool {
    rc := (^Remote_Connect)(user)
    if len(rc.resp.body) + len(chunk) > REMOTE_RESP_MAX {
        rc.resp.overflow = true

        return false
    }

    if _, aerr := append(&rc.resp.body, ..chunk); aerr != nil {
        return false
    }

    return true
}

// Reject the connect promise with `code` and release the attempt. Terminal for any failure
// before the transport opens.
@(private = "file")
remote_fail :: proc(rc: ^Remote_Connect, code: string) {
    h := rc.host
    job := rc.job
    h.remote = nil
    rc.job = nil
    remote_free(rc)

    if job != nil {
        client_promise_reject(job, code, true)
    }
}

// Release an attempt's owned memory, wiping the credential and static key. Never settles the
// promise — the caller owns that.
@(private = "file")
remote_free :: proc(rc: ^Remote_Connect) {
    allocator := rc.host.allocator

    delete(rc.resp.body)
    delete(rc.req_body, allocator)
    delete(rc.device, allocator)
    delete(rc.cloud_url, allocator)
    delete(rc.device_id, allocator)

    if rc.credential != "" {
        mem.zero_slice(transmute([]u8)rc.credential)
        delete(rc.credential, allocator)
    }

    mem.zero_slice(rc.static_seed[:])
    free(rc, allocator)
}

@(private = "file")
remote_rx_reset :: proc(rx: ^Remote_Rx) {
    clear(&rx.body)
    rx.overflow = false
}

// Control-plane defaults, resolved identically by `yuke login` so client and enrollment agree.
@(private = "file")
DEFAULT_CLOUD_URL :: "https://platform.yuke.sh"

@(private = "file")
CLOUD_URL_ENV :: "YUKE_CLOUD_URL"

// The control-plane base URL: `$YUKE_CLOUD_URL` when set and non-empty, else the hosted
// default. Mirrors `yuke login`, so the client and enrollment resolve the same control plane.
@(private = "file")
remote_cloud_url :: proc(allocator: mem.Allocator) -> (string, mem.Allocator_Error) {
    if v, set := os.lookup_env(CLOUD_URL_ENV, allocator); set {
        if v != "" {
            return v, nil
        }

        delete(v, allocator)
    }

    return strings.clone(DEFAULT_CLOUD_URL, allocator)
}
