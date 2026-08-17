package daemon

import "core:crypto/sha2"
import "core:encoding/endian"
import "core:log"
import "core:mem"
import "core:mem/virtual"
import "core:strings"
import "core:time"

import "libs:bindings/curl"

import "src:daemon/catalog"
import "src:daemon/oauth"
import "src:daemon/store"
import "src:wire"

// The persisted rows, the revision covering them, and the health block. Held rather than
// re-derived: only `catalog.refresh` writes it, so it is immutable between revisions.
Daemon_Catalog :: struct {
    rev:      wire.Catalog_Rev,
    health:   wire.Catalog_Health,
    snapshot: store.Catalog,
}

// Read the catalog and recompute the revision. The old snapshot is released only once the
// replacement is in hand, so a failed reload keeps serving rather than emptying it.
catalog_state_load :: proc(d: ^Daemon) -> store.Error {
    assert(d != nil, "catalog state load needs daemon state")
    assert(d.store != nil, "catalog state load needs an open store")

    loaded := store.catalog_load(d.store, d.allocator) or_return

    scratch: virtual.Arena
    _ = virtual.arena_init_growing(&scratch)
    defer virtual.arena_destroy(&scratch)

    models := catalog_models_view(loaded, virtual.arena_allocator(&scratch))

    catalog_state_destroy(d)
    d.catalog.snapshot = loaded
    d.catalog.rev = catalog_rev(models, d.catalog.health)

    return nil
}

// A credential-set change makes the held feed validator stale: the next refresh must refetch
// and re-decode with the new selection. The model set is unchanged, so the revision holds.
catalog_feed_invalidate :: proc(d: ^Daemon) {
    assert(d != nil && d.store != nil, "catalog invalidation needs an open store")

    if clear_err := store.catalog_feed_etag_clear(d.store); clear_err != nil {
        log.errorf("daemon: catalog etag invalidation failed: %v", clear_err)

        return
    }

    if load_err := catalog_state_load(d); load_err != nil {
        log.errorf("daemon: catalog reload after invalidation failed: %v", load_err)
    }
}

catalog_state_destroy :: proc(d: ^Daemon) {
    assert(d != nil, "catalog state teardown needs daemon state")

    if d.catalog.snapshot.allocator.procedure != nil {
        store.catalog_destroy(&d.catalog.snapshot)
    }

    d.catalog.rev = {}
}

// The model a public id names, or nil. Ids are unique across the catalog, so the first
// match is the only one; the pointer borrows the snapshot until a refresh replaces it.
catalog_model_find :: proc(d: ^Daemon, public_id: string) -> ^catalog.Model {
    assert(d != nil, "a model lookup needs daemon state")

    for &item in d.catalog.snapshot.providers {
        for &model in item.models {
            if string(model.info.id) == public_id {
                return &model
            }
        }
    }

    return nil
}

@(private, rodata)
REV_HEX_DIGITS := "0123456789abcdef"

// Flatten the catalog's visible models into one list. Each `Model_Info` borrows the
// snapshot's strings; the stored order feeds both `catalog_rev` and `catalog.list`.
catalog_models_view :: proc(snapshot: store.Catalog, allocator := context.allocator) -> (models: []wire.Model_Info) {
    total := 0
    for provider in snapshot.providers {
        total += len(provider.models)
    }

    if total == 0 {
        return nil
    }

    view := make([]wire.Model_Info, total, allocator)
    index := 0
    for provider in snapshot.providers {
        for model in provider.models {
            view[index] = model.info
            index += 1
        }
    }

    assert(index == total, "the view holds every visible model")

    return view
}

// SHA-256 hex digest over the `catalog.list` content a client caches (visible models plus
// health), so `since_rev == current` means the cache is accurate; caller supplies stored order.
catalog_rev :: proc(models: []wire.Model_Info, health: wire.Catalog_Health) -> wire.Catalog_Rev {
    assert(len(models) <= int(wire.LIMITS.max_catalog_models), "the rev covers a bounded catalog")

    ctx: sha2.Context_256
    sha2.init_256(&ctx)

    sha2.update(&ctx, transmute([]byte)string("yuke.catalog.rev.v1"))

    rev_u64(&ctx, u64(len(models)))
    for model in models {
        rev_str(&ctx, string(model.id))
        rev_str(&ctx, model.provider)
        rev_str(&ctx, model.name)
        rev_u64(&ctx, model.context_window)
        rev_u64(&ctx, model.max_output_tokens)
        rev_u64(&ctx, u64(len(model.reasoning_levels)))
        for level in model.reasoning_levels {
            rev_str(&ctx, level)
        }
        rev_str(&ctx, model.default_reasoning)
        rev_u8(&ctx, 1 if model.supports_vision else 0)
        rev_u8(&ctx, 1 if model.supports_tools else 0)
        rev_f64(&ctx, model.cost.input)
        rev_f64(&ctx, model.cost.output)
        rev_f64(&ctx, model.cost.cache_read)
        rev_f64(&ctx, model.cost.cache_write)
    }

    rev_u64(&ctx, u64(len(health.skipped)))
    for skipped in health.skipped {
        rev_str(&ctx, skipped.provider)
        rev_u8(&ctx, rev_skip_reason_tag(skipped.reason))
    }
    if message, present := health.load_error.?; present {
        rev_u8(&ctx, 1)
        rev_str(&ctx, message)
    } else {
        rev_u8(&ctx, 0)
    }

    digest: [sha2.DIGEST_SIZE_256]byte
    sha2.final(&ctx, digest[:])

    out: [64]u8
    for value, index in digest {
        out[index * 2] = REV_HEX_DIGITS[value >> 4]
        out[index * 2 + 1] = REV_HEX_DIGITS[value & 0xf]
    }

    return wire.Catalog_Rev(out)
}

@(private)
rev_skip_reason_tag :: proc(reason: wire.Skip_Reason) -> u8 {
    switch _ in reason {
    case wire.Skip_Reason_Missing_Credential:
        return 1

    case wire.Skip_Reason_Invalid_Config:
        return 2
    }

    return 0
}

@(private)
rev_str :: proc(ctx: ^sha2.Context_256, value: string) {
    rev_u64(ctx, u64(len(value)))
    if len(value) > 0 {
        sha2.update(ctx, transmute([]byte)value)
    }
}

@(private)
rev_u64 :: proc(ctx: ^sha2.Context_256, value: u64) {
    buf: [8]u8
    endian.put_u64(buf[:], .Little, value)
    sha2.update(ctx, buf[:])
}

@(private)
rev_f64 :: proc(ctx: ^sha2.Context_256, value: f64) {
    buf: [8]u8
    endian.put_f64(buf[:], .Little, value)
    sha2.update(ctx, buf[:])
}

@(private)
rev_u8 :: proc(ctx: ^sha2.Context_256, value: u8) {
    buf := [1]u8{value}
    sha2.update(ctx, buf[:])
}

// Build the models.dev import selection: every provider with a saved credential.
// `allocator` should be scratch.
catalog_selections_build :: proc(
    d: ^Daemon,
    allocator: mem.Allocator,
) -> (
    selections: [dynamic]catalog.Selection,
    err: store.Error,
) {
    assert(d != nil, "selection build needs daemon state")
    assert(d.store != nil, "selection build needs an open store")

    selections.allocator = allocator

    // The source key defaults to the provider id; an OAuth identity overrides it, and an
    // empty override drops the provider from the feed. Statuses are already unique.
    statuses := store.credential_statuses_load(d.store, allocator) or_return
    for status in statuses {
        source_id := status.provider_id
        if kind, is_oauth := oauth.kind_from_id(status.provider_id); is_oauth {
            source_id = oauth.provider(kind).catalog_source_id
            if source_id == "" {
                continue
            }
        }

        append(
            &selections,
            catalog.Selection{provider_id = wire.Provider_Id(status.provider_id), source_id = source_id},
        )
    }

    if len(selections) > catalog.SELECTIONS_MAX {
        return selections, .Invalid_Catalog
    }

    return selections, nil
}

// Apply one fetched models.dev feed: decode, transactionally replace each imported snapshot, then
// reload the held catalog. Untrusted feed, so a decode failure preserves the old snapshot.
catalog_refresh_apply :: proc(
    d: ^Daemon,
    feed: []byte,
    feed_etag: string,
    selections: []catalog.Selection,
) -> (
    changed: bool,
    err: store.Error,
) {
    assert(d != nil, "catalog refresh needs daemon state")
    assert(d.store != nil, "catalog refresh needs an open store")

    old_rev := d.catalog.rev

    scratch: virtual.Arena
    _ = virtual.arena_init_growing(&scratch)
    defer virtual.arena_destroy(&scratch)
    sa := virtual.arena_allocator(&scratch)

    result, decode_err := catalog.decode(feed, selections, sa)
    if decode_err != .None {
        return false, .Invalid_Catalog
    }

    // The decoder already produces the shape the store persists, so each provider goes
    // straight in with the feed's own validator.
    apply_err: store.Error
    for item in result.providers {
        if replace_err := store.catalog_imported_replace(d.store, item, feed_etag); replace_err != nil {
            apply_err = replace_err
            break
        }
    }

    // Always re-sync the held state with the store, even after a partial failure, so the
    // revision and health never disagree with the persisted rows.
    load_err := catalog_state_load(d)
    changed = d.catalog.rev != old_rev

    if apply_err != nil {
        return changed, apply_err
    }

    return changed, load_err
}

MODELS_DEV_URL :: "https://models.dev/api.json"

@(private)
CATALOG_REFRESH_CONNECT_TIMEOUT :: 30 * time.Second

@(private)
CATALOG_REFRESH_TOTAL_TIMEOUT :: 60 * time.Second

@(private)
CATALOG_REFRESH_ETAG_MAX :: 4096

// The async models.dev fetch service: one shared curl client and a single-flight
// operation slot. Trigger-agnostic — a wire method drives it today.
Catalog_Refresh :: struct {
    curl:      curl.Client,
    ready:     bool,
    operation: ^Catalog_Refresh_Op,
    stopping:  bool,
}

// One in-flight fetch. `transfer`'s address is held by libcurl, so the operation must never
// move while live. `ticket`/`request_id` name the client to answer (`ticket == 0`: no client).
@(private)
Catalog_Refresh_Op :: struct {
    transfer:   curl.Transfer,
    ticket:     Conn_Ticket,

    // Owned clone of the request id the response correlates against. The inbound frame's
    // arena is reset and wiped when the request returns, long before this fetch completes.
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
        return .Catalog_Failed
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

// Start a fetch for `ticket`/`request_id`. Single-flight: the caller checks
// `catalog_refresh_busy` first. Returns false on setup failure; on success one completion follows.
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
    op.feed.allocator = d.allocator

    cloned_id, id_err := strings.clone(string(request_id), d.allocator)
    if id_err != nil {
        free(op, d.allocator)

        return false
    }

    op.request_id = wire.Request_Id(cloned_id)
    d.catalog_refresh.operation = op

    // The feed's own validator; empty makes the request unconditional. `transfer_start` materializes
    // its own header list, so this stack storage only has to outlive the call.
    headers: [1]curl.Header
    header_count := 0
    if etag := d.catalog.snapshot.feed_etag; etag != "" {
        headers[header_count] = curl.Header {
            name  = "If-None-Match",
            value = etag,
        }
        header_count += 1
    }

    request := curl.Request {
        url             = MODELS_DEV_URL,
        headers         = headers[:header_count],
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

    outcome := catalog_refresh_settle(
        d,
        result.code,
        result.status,
        op.overflow,
        op.feed[:],
        string(op.etag[:op.etag_len]),
    )

    // The slot is released before the answer so the next refresh may start, but the
    // operation outlives it: the response borrows the id the operation owns.
    ticket := op.ticket
    d.catalog_refresh.operation = nil
    defer catalog_refresh_free(d, op)

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
        send_result(conn, op.request_id, result_payload, conn.allocator)
    } else {
        send_error(conn, op.request_id, .Internal, outcome.message, conn.allocator)
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
// on a fresh 200, apply the feed. A 304 keeps the current snapshot; other errors preserve it.
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
    delete(string(op.request_id), d.allocator)
    op^ = {}
    free(op, d.allocator)
}

// `catalog.list`: `unchanged` when the client already holds the current revision, else a
// `full` snapshot of the visible models re-derived from the store, plus the held rev and health.
method_catalog_list :: proc(conn: ^Conn, req: wire.Request, sa: mem.Allocator) {
    assert(conn != nil, "catalog.list needs connection state")
    assert(conn.state == .Ready, "catalog.list ran outside Ready")
    assert(req.method == .Catalog_List, "catalog.list received another method")

    d := conn.daemon
    params := req.params.(wire.Catalog_List_Params)

    if since, ok := params.since_rev.?; ok && since == d.catalog.rev {
        send_result(conn, req.id, wire.Catalog_List_Result_Unchanged{catalog_rev = d.catalog.rev}, sa)
        return
    }

    // A view over the held snapshot, built into request scratch. The snapshot is what
    // `d.catalog.rev` was computed from, so the two cannot disagree.
    models := catalog_models_view(d.catalog.snapshot, sa)

    // `send_result` asserts the result validates; these models come from persisted rows, so
    // store-write validation must stay at least as strict as wire validation (it is).
    result := wire.Catalog_List_Result_Full {
        catalog_rev = d.catalog.rev,
        models      = models,
        health      = d.catalog.health,
    }
    send_result(conn, req.id, result, sa)
}

// `catalog.refresh` starts an async models.dev fetch and answers when it lands with the
// new revision and health, or an error. Single-flight; the reply is deferred to completion.
method_catalog_refresh :: proc(conn: ^Conn, req: wire.Request, sa: mem.Allocator) {
    assert(conn != nil, "catalog.refresh needs connection state")
    assert(conn.state == .Ready, "catalog.refresh ran outside Ready")
    assert(req.method == .Catalog_Refresh, "catalog.refresh received another method")

    d := conn.daemon
    if !d.catalog_refresh.ready || d.catalog_refresh.stopping {
        send_error(conn, req.id, .Internal, "catalog refresh is unavailable", sa)
        return
    }

    if catalog_refresh_busy(d) {
        send_error(conn, req.id, .Overloaded, "a catalog refresh is already in progress", sa)
        return
    }

    if !catalog_refresh_begin(d, conn.ticket, req.id) {
        send_error(conn, req.id, .Internal, "catalog refresh could not start", sa)
    }
}
