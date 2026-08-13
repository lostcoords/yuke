package daemon

import "core:mem"
import "core:mem/virtual"
import "core:strings"
import "core:time"

import curl "libs:bindings/curl"
import catalog "src:daemon/catalog"
import store "src:daemon/store"
import wire "src:wire"

MODELS_DEV_URL :: "https://models.dev/api.json"

@(private)
CATALOG_REFRESH_CONNECT_TIMEOUT :: 30 * time.Second

@(private)
CATALOG_REFRESH_TOTAL_TIMEOUT :: 60 * time.Second

@(private)
CATALOG_REFRESH_ETAG_MAX :: 4096

#assert(CATALOG_REFRESH_ETAG_MAX <= 4096)

// The async models.dev fetch service: one shared curl client and a single-flight
// operation slot. Trigger-agnostic — a wire method drives it today; a future cron job
// can start the same operation.
Catalog_Refresh :: struct {
    curl:      curl.Client,
    ready:     bool,
    operation: ^Catalog_Refresh_Op,
    stopping:  bool,
}

// One in-flight fetch. `transfer` is embedded and its address is held by libcurl, so the
// operation must never move while live. `ticket`/`request_id` name the client to answer
// on completion (`ticket == 0` for a non-client trigger). The feed accumulates into a
// heap buffer bounded by `catalog.FEED_MAX_BYTES`; `etag` captures the response ETag.
@(private)
Catalog_Refresh_Op :: struct {
    transfer:   curl.Transfer,
    ticket:     Conn_Ticket,
    request_id: wire.Request_Id,
    feed:       [dynamic]byte,
    overflow:   bool,
    etag:       [CATALOG_REFRESH_ETAG_MAX]u8,
    etag_len:   int,
}

catalog_refresh_init :: proc(d: ^Daemon) -> Error {
    assert(d != nil, "catalog refresh init needs daemon state")
    assert(d.loop != nil, "catalog refresh init needs an event loop")
    assert(!d.catalog_refresh.ready, "catalog refresh initialized twice")

    if curl_err := curl.client_init(&d.catalog_refresh.curl, d.loop, d.allocator); curl_err != .None {
        return .Store_Failed
    }
    d.catalog_refresh.ready = true

    return .None
}

// Stop accepting refreshes and cancel any in-flight fetch. `transfer_cancel` is
// synchronous and fires no completion, so no drain is required.
catalog_refresh_shutdown :: proc(d: ^Daemon) {
    assert(d != nil, "catalog refresh shutdown needs daemon state")

    d.catalog_refresh.stopping = true
    if op := d.catalog_refresh.operation; op != nil {
        curl.transfer_cancel(&op.transfer)
        d.catalog_refresh.operation = nil
        catalog_refresh_free(d, op)
    }
}

catalog_refresh_destroy :: proc(d: ^Daemon) {
    assert(d != nil, "catalog refresh teardown needs daemon state")
    assert(d.catalog_refresh.operation == nil, "catalog refresh destroyed with a live operation")

    if d.catalog_refresh.ready {
        curl.client_destroy(&d.catalog_refresh.curl)
        d.catalog_refresh.ready = false
    }
}

catalog_refresh_busy :: proc(d: ^Daemon) -> bool {
    return d.catalog_refresh.operation != nil
}

// Start a fetch for the requester named by `ticket`/`request_id`. Single-flight: the
// caller must check `catalog_refresh_busy` first. Reads the current feed ETag for a
// conditional request. Returns false if the transfer could not be set up (nothing is
// left in flight); on success exactly one completion follows.
catalog_refresh_begin :: proc(d: ^Daemon, ticket: Conn_Ticket, request_id: wire.Request_Id) -> bool {
    assert(d != nil && d.store != nil, "catalog refresh needs an open store")
    assert(d.catalog_refresh.ready, "catalog refresh needs an initialized client")
    assert(!d.catalog_refresh.stopping, "catalog refresh cannot start during shutdown")
    assert(!catalog_refresh_busy(d), "catalog refresh must be single flight")

    op, op_err := new(Catalog_Refresh_Op, d.allocator)
    if op_err != nil {
        return false
    }
    op^ = {}
    op.ticket = ticket
    op.request_id = request_id
    op.feed.allocator = d.allocator
    d.catalog_refresh.operation = op

    scratch: virtual.Arena
    if virtual.arena_init_growing(&scratch) != nil {
        d.catalog_refresh.operation = nil
        catalog_refresh_free(d, op)
        return false
    }
    defer virtual.arena_destroy(&scratch)
    sa := virtual.arena_allocator(&scratch)

    headers: [dynamic]curl.Header
    headers.allocator = sa
    if etag := catalog_current_etag(d, sa); etag != "" {
        append(&headers, curl.Header{name = "If-None-Match", value = etag})
    }

    request := curl.Request {
        url             = MODELS_DEV_URL,
        headers         = headers[:],
        method          = .Get,
        connect_timeout = CATALOG_REFRESH_CONNECT_TIMEOUT,
        total_timeout   = CATALOG_REFRESH_TOTAL_TIMEOUT,
    }
    callbacks := curl.Callbacks {
        on_header = catalog_refresh_on_header,
        on_body   = catalog_refresh_on_body,
        on_done   = catalog_refresh_on_done,
    }

    if transfer_err := curl.transfer_start(&op.transfer, &d.catalog_refresh.curl, request, callbacks, d);
       transfer_err != .None {
        d.catalog_refresh.operation = nil
        catalog_refresh_free(d, op)
        return false
    }

    assert(op.transfer.state == .Running, "a started catalog refresh owns a running transfer")

    return true
}

// The current feed ETag: any imported provider carries the ETag of the last refresh, so
// they share one value. Empty when nothing is imported or a load fails, making the next
// request unconditional. Borrows `allocator`.
@(private)
catalog_current_etag :: proc(d: ^Daemon, allocator: mem.Allocator) -> string {
    data, load_err := store.catalog_data_load(d.store, allocator)
    if load_err != nil {
        return ""
    }

    for provider in data.providers {
        if provider.source == .Models_Dev && provider.etag != "" {
            return provider.etag
        }
    }

    return ""
}

@(private)
catalog_refresh_on_header :: proc(user: rawptr, line: []byte) {
    d := (^Daemon)(user)
    op := d.catalog_refresh.operation
    if op == nil {
        return
    }

    text := string(line)
    colon := strings.index_byte(text, ':')
    if colon < 0 {
        return
    }

    if !strings.equal_fold(strings.trim_space(text[:colon]), "etag") {
        return
    }

    value := strings.trim_space(text[colon + 1:])
    if len(value) == 0 || len(value) > CATALOG_REFRESH_ETAG_MAX {
        return
    }

    copy(op.etag[:], transmute([]byte)value)
    op.etag_len = len(value)
}

@(private)
catalog_refresh_on_body :: proc(user: rawptr, chunk: []byte) -> bool {
    d := (^Daemon)(user)
    op := d.catalog_refresh.operation
    assert(op != nil, "catalog refresh body lost its owner")
    assert(op.transfer.state == .Running, "catalog refresh body needs a running transfer")

    if op.overflow {
        return false
    }
    if len(op.feed) + len(chunk) > catalog.FEED_MAX_BYTES {
        op.overflow = true
        return false
    }
    if _, append_err := append(&op.feed, ..chunk); append_err != nil {
        op.overflow = true
        return false
    }

    return true
}

@(private)
catalog_refresh_on_done :: proc(user: rawptr, result: curl.Result) {
    d := (^Daemon)(user)
    op := d.catalog_refresh.operation
    assert(op != nil, "catalog refresh completion lost its owner")
    assert(op.transfer.state == .Done, "catalog refresh completion needs a terminal transfer")

    ticket := op.ticket
    request_id := op.request_id

    outcome := catalog_refresh_settle(
        d,
        result.code,
        result.status,
        op.overflow,
        op.feed[:],
        string(op.etag[:op.etag_len]),
    )

    d.catalog_refresh.operation = nil
    catalog_refresh_free(d, op)

    if outcome.changed {
        _ = broadcast(d, wire.Catalog_Changed_Data{catalog_rev = d.catalog.rev, health = d.catalog.health})
    }

    if ticket == 0 {
        return
    }
    conn := conn_resolve(d, ticket)
    if conn == nil {
        return
    }

    if outcome.ok {
        result_payload := wire.Catalog_Refresh_Result {
            catalog_rev = d.catalog.rev,
            health      = d.catalog.health,
        }
        send_result(conn, request_id, result_payload, conn.allocator)
    } else {
        send_error(conn, request_id, .Internal, outcome.message, conn.allocator)
    }
}

// Outcome of a completed fetch. `ok` drives the client reply; `changed` drives the
// broadcast. `message` is diagnostic for the error reply.
@(private)
Catalog_Refresh_Outcome :: struct {
    ok:      bool,
    changed: bool,
    message: string,
}

// Network-independent completion logic, tested directly: classify the HTTP result and,
// on a fresh 200, build the selection and apply the feed. A 304 keeps the current
// snapshot; any other non-success preserves it and reports an error.
@(private)
catalog_refresh_settle :: proc(
    d: ^Daemon,
    code: curl.Code,
    status: int,
    overflow: bool,
    feed: []byte,
    response_etag: string,
) -> Catalog_Refresh_Outcome {
    // Overflow is our own body-abort, which curl reports as `.Write_Error`; check it
    // first so the client hears the specific reason rather than a generic fetch failure.
    if overflow {
        return {ok = false, message = "catalog response exceeded the size limit"}
    }
    if code != .Ok {
        return {ok = false, message = "catalog fetch failed"}
    }
    if status == 304 {
        return {ok = true}
    }
    if status < 200 || status >= 300 {
        return {ok = false, message = "catalog source returned an error status"}
    }

    scratch: virtual.Arena
    if virtual.arena_init_growing(&scratch) != nil {
        return {ok = false, message = "out of memory"}
    }
    defer virtual.arena_destroy(&scratch)

    selections, selection_err := catalog_selections_build(d, virtual.arena_allocator(&scratch))
    if selection_err != nil {
        return {ok = false, message = "could not build the catalog selection"}
    }

    changed, apply_err := catalog_refresh_apply(d, feed, response_etag, selections[:])
    if apply_err != nil {
        return {ok = false, message = "catalog could not be applied"}
    }

    return {ok = true, changed = changed}
}

@(private)
catalog_refresh_free :: proc(d: ^Daemon, op: ^Catalog_Refresh_Op) {
    assert(d != nil && op != nil, "catalog refresh cleanup needs owned state")
    assert(op.transfer.state != .Running, "catalog refresh cleanup with a live transfer")

    delete(op.feed)
    op^ = {}
    free(op, d.allocator)
}
