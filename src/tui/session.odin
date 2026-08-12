package tui

/*
Open-session controller: folds live broadcasts for the UI's one open session into a native
`client.Session_Replica`. `yuke:client` drives open → resync → fold → close and reads snapshots.
*/

import "base:runtime"
import "core:c"
import "core:encoding/json"
import "core:mem"
import "core:mem/virtual"

import qjs "libs:bindings/quickjs"
import client "src:client"
import wire "src:wire"

// Where the open session sits relative to the resync cut. Broadcasts fold only when `Synced`;
// otherwise they are dropped and the controller (JS) re-issues a resync.
Sync_State :: enum {
    // No valid cut yet: the controller must resync before folding can begin.
    Needs_Resync,

    // A `session.resync` request is in flight; its ordered response is the cut barrier.
    Resyncing,

    // A cut is installed; live broadcasts fold directly.
    Synced,
}

// The single session the client UI has open, plus its folded replica. `rev` bumps on every
// visible change so a JS poller redraws only when something moved.
Open_Session :: struct {
    live:    bool,
    sync:    Sync_State,
    replica: client.Session_Replica,
    rev:     u64,
}

// Free the replica and clear the open session. Never repaints: it runs on shutdown paths where
// painting into a dying context is unsafe.
open_session_teardown :: proc(h: ^Host) {
    assert(h != nil, "open session teardown needs a host")

    if !h.open_session.live {
        return
    }

    client.replica_destroy(&h.open_session.replica)
    h.open_session.live = false
    h.open_session.sync = .Needs_Resync
    h.open_session.rev += 1
}

// Fold one broadcast for the open session. Dropped unless a session is open and synced; a gap
// or fold error demands a fresh resync. A visible change or a gap bumps `rev` and repaints.
client_on_broadcast :: proc(c: ^client.Client, bc: wire.Notification) {
    assert(c != nil && c.user_data != nil, "broadcast callback lost its host")

    h := (^Host)(c.user_data)
    assert(&h.daemon.client == c && h.daemon.live, "broadcast callback crossed connections")

    if h.done || !h.open_session.live || h.open_session.sync != .Synced {
        return
    }

    res, err := client.replica_apply_broadcast(&h.open_session.replica, bc)

    if err != .None {
        // OOM or a config-revision conflict: unrecoverable in place, only a fresh cut recovers.
        session_mark_needs_resync(h)
        return
    }

    #partial switch res.kind {
    case .Gap:
        session_mark_needs_resync(h)

    case .Changed, .Committed, .Discarded:
        h.open_session.rev += 1
        host_dispatch_session(h)
    }
}

// Move the open session back to needing a resync, bump `rev`, and repaint.
session_mark_needs_resync :: proc(h: ^Host) {
    assert(h != nil && h.open_session.live, "resync mark needs an open session")

    h.open_session.sync = .Needs_Resync
    h.open_session.rev += 1
    host_dispatch_session(h)
}

// --- native session functions (yuke:client-native) ---

// Track `id` (16 lowercase hex chars): drop any prior session, install a fresh replica needing
// a resync before it folds.
@(private = "file")
client_js_session_open :: proc "c" (ctx: ^qjs.Context, this: qjs.Value, argc: c.int, argv: [^]qjs.Value) -> qjs.Value {
    context = runtime.default_context()
    _ = this

    h := host_from_ctx(ctx)
    if h == nil {
        return qjs.throw_type_error(ctx, "yuke:client has no host")
    }

    if argc < 1 {
        return qjs.throw_type_error(ctx, "sessionOpen expects a session id")
    }

    id, ok := session_id_from_js(ctx, argv[0])
    if !ok {
        return qjs.throw_type_error(ctx, "sessionOpen expects a 16 hex-char session id")
    }

    open_session_teardown(h)

    client.replica_init(&h.open_session.replica, h.allocator, id)
    h.open_session.live = true
    h.open_session.sync = .Needs_Resync
    h.open_session.rev += 1

    return qjs.undefined()
}

// Stop tracking the open session and free its replica.
@(private = "file")
client_js_session_close :: proc "c" (
    ctx: ^qjs.Context,
    this: qjs.Value,
    argc: c.int,
    argv: [^]qjs.Value,
) -> qjs.Value {
    context = runtime.default_context()
    _ = this
    _ = argc
    _ = argv

    h := host_from_ctx(ctx)
    if h == nil {
        return qjs.throw_type_error(ctx, "yuke:client has no host")
    }

    open_session_teardown(h)

    return qjs.undefined()
}

// The open session's change counter, or -1 when none is open. Cheap to poll; pull a snapshot
// only when it moves.
@(private = "file")
client_js_session_rev :: proc "c" (ctx: ^qjs.Context, this: qjs.Value, argc: c.int, argv: [^]qjs.Value) -> qjs.Value {
    context = runtime.default_context()
    _ = this
    _ = argc
    _ = argv

    h := host_from_ctx(ctx)
    if h == nil || !h.open_session.live {
        return qjs.new_i64(-1)
    }

    return qjs.new_i64(i64(h.open_session.rev))
}

// The folded transcript as a JSON string, or "null" when no session is open.
@(private = "file")
client_js_session_snapshot :: proc "c" (
    ctx: ^qjs.Context,
    this: qjs.Value,
    argc: c.int,
    argv: [^]qjs.Value,
) -> qjs.Value {
    context = runtime.default_context()
    _ = this
    _ = argc
    _ = argv

    h := host_from_ctx(ctx)
    if h == nil || !h.open_session.live {
        return qjs.new_string(ctx, "null")
    }

    // Reset once `new_string` has copied the bytes into a QuickJS string. The host's shared temp
    // allocator is not reset per frame, so a polled snapshot must not accrue there.
    temp := virtual.arena_temp_begin(&h.snapshot_scratch)
    defer virtual.arena_temp_end(temp)

    return qjs.new_string(ctx, session_snapshot_json(h, virtual.arena_allocator(&h.snapshot_scratch)))
}

// Resync the open session: send `session.resync` and install its ordered response as the cut.
// The response is the barrier — broadcasts stay dropped (sync `.Resyncing`) until it lands.
@(private = "file")
client_js_session_resync :: proc "c" (
    ctx: ^qjs.Context,
    this: qjs.Value,
    argc: c.int,
    argv: [^]qjs.Value,
) -> qjs.Value {
    context = runtime.default_context()
    _ = this
    _ = argc
    _ = argv

    h := host_from_ctx(ctx)
    if h == nil {
        return qjs.throw_type_error(ctx, "yuke:client has no host")
    }

    if h.done {
        return qjs.throw_type_error(ctx, "yuke:client host is shutting down")
    }

    if !h.open_session.live {
        return qjs.throw_type_error(ctx, "no session is open")
    }

    if !h.daemon.live {
        return qjs.throw_type_error(ctx, "not connected")
    }

    params := wire.Session_Resync_Params {
        session_id = h.open_session.replica.session_id,
    }

    job, promise := client_promise_new(h)
    if job == nil {
        if qjs.is_exception(promise) {
            return promise
        }

        return qjs.throw_type_error(ctx, "out of memory")
    }

    h.open_session.sync = .Resyncing
    h.open_session.rev += 1

    _, send_err := client.client_send_request(
        &h.daemon.client,
        .Session_Resync,
        params,
        client_on_session_resync_complete,
        job,
    )
    if send_err != .None {
        h.open_session.sync = .Needs_Resync
        h.open_session.rev += 1
        client_promise_reject(job, client_protocol_error_wire(send_err), false)
    }

    return promise
}

// Install a resync response into the replica, then settle the promise and repaint. A result for
// a session the UI has since closed or re-opened is discarded, but its promise still settles.
@(private = "file")
client_on_session_resync_complete :: proc(c: ^client.Client, outcome: client.Request_Outcome, user_data: rawptr) {
    assert(c != nil && c.user_data != nil, "resync completion lost its host")
    assert(user_data != nil, "resync completion lost its promise")

    h := (^Host)(c.user_data)
    job := (^Client_Promise)(user_data)
    assert(&h.daemon.client == c && h.daemon.live, "resync completion crossed connections")
    assert(job.host == h, "resync completion crossed hosts")

    targeting := h.open_session.live && h.open_session.sync == .Resyncing

    switch result in outcome {
    case client.Request_Response:
        #partial switch resp in result.response {
        case wire.Response_Ok:
            snapshot, is_snapshot := resp.result.(wire.Session_Resync_Result)
            if !is_snapshot {
                resync_fail(h, job, "unexpected_result", targeting)
                return
            }

            if !targeting {
                client_promise_resolve(job, qjs.undefined(), true)
                return
            }

            if install_err := client.replica_install_snapshot(&h.open_session.replica, snapshot);
               install_err != .None {
                resync_fail(h, job, replica_error_wire(install_err), true)
                return
            }

            h.open_session.sync = .Synced
            h.open_session.rev += 1
            client_promise_resolve(job, qjs.undefined(), true)
            host_dispatch_session(h)

        case wire.Response_Error:
            resync_fail(h, job, "resync_rejected", targeting)
        }

    case client.Request_Failure:
        resync_fail(h, job, client_protocol_error_wire(result.error), targeting)
    }
}

// Reject a resync promise and, when still targeting the open session, drop it back to needing a
// resync and repaint.
@(private = "file")
resync_fail :: proc(h: ^Host, job: ^Client_Promise, reason: string, targeting: bool) {
    if targeting {
        h.open_session.sync = .Needs_Resync
        h.open_session.rev += 1
    }

    client_promise_reject(job, reason, true)

    if targeting {
        host_dispatch_session(h)
    }
}

@(private = "file")
replica_error_wire :: proc(err: client.Replica_Error) -> string {
    switch err {
    case .None:
        unreachable()

    case .Out_Of_Memory:
        return "out_of_memory"

    case .Session_Mismatch:
        return "session_mismatch"

    case .Malformed_Snapshot:
        return "malformed_snapshot"

    case .Config_Revision_Conflict:
        return "config_revision_conflict"
    }

    unreachable()
}

// Install the open-session native functions onto the shared client-native object.
session_native_install :: proc(ctx: ^qjs.Context, native: qjs.Value) {
    _ = qjs.set_property(ctx, native, "sessionOpen", qjs.new_function(ctx, client_js_session_open, "sessionOpen", 1))
    _ = qjs.set_property(
        ctx,
        native,
        "sessionClose",
        qjs.new_function(ctx, client_js_session_close, "sessionClose", 0),
    )
    _ = qjs.set_property(ctx, native, "sessionRev", qjs.new_function(ctx, client_js_session_rev, "sessionRev", 0))
    _ = qjs.set_property(
        ctx,
        native,
        "sessionResync",
        qjs.new_function(ctx, client_js_session_resync, "sessionResync", 0),
    )
    _ = qjs.set_property(
        ctx,
        native,
        "sessionSnapshot",
        qjs.new_function(ctx, client_js_session_snapshot, "sessionSnapshot", 0),
    )
}

// Parse a JS value into a session id: a 16-char lowercase-hex string held as its bytes.
@(private = "file")
session_id_from_js :: proc(ctx: ^qjs.Context, v: qjs.Value) -> (wire.Session_Id, bool) {
    if !qjs.is_string(v) {
        return {}, false
    }

    s, ok := qjs.to_string(ctx, v)
    if !ok {
        return {}, false
    }

    defer qjs.free_string(ctx, s)

    if len(s) != 16 {
        return {}, false
    }

    arr: [16]u8
    copy(arr[:], transmute([]u8)s)

    if wire.enforce_id(arr) != .None {
        return {}, false
    }

    return wire.Session_Id(arr), true
}

@(private = "file")
sync_state_wire :: proc(s: Sync_State) -> string {
    switch s {
    case .Needs_Resync:
        return "needs_resync"

    case .Resyncing:
        return "resyncing"

    case .Synced:
        return "synced"
    }

    unreachable()
}

// --- snapshot serialization ---

@(private = "file")
Snapshot_Part :: struct {
    type: string `json:"type"`,
    text: string `json:"text"`,
}

@(private = "file")
Snapshot_Message :: struct {
    type:    string `json:"type"`,
    id:      u64 `json:"id"`,
    content: []Snapshot_Part `json:"content"`,
}

// The open-session view. `active` is the streaming draft, or null when no draft is open.
@(private = "file")
Snapshot :: struct {
    session_id: string `json:"sessionId"`,
    sync:       string `json:"sync"`,
    rev:        u64 `json:"rev"`,
    has_more:   bool `json:"hasMore"`,
    messages:   []Snapshot_Message `json:"messages"`,
    active:     Maybe(Snapshot_Message) `json:"active"`,
}

// Fold the open session into one JSON snapshot. Allocated in `allocator` (caller frees); borrowed
// replica strings are valid for this call and copied by `json.marshal`.
@(private = "file")
session_snapshot_json :: proc(h: ^Host, allocator: mem.Allocator) -> string {
    assert(h != nil && h.open_session.live, "snapshot needs an open session")

    open := &h.open_session
    sid := ([16]u8)(open.replica.session_id)

    msgs := make([dynamic]Snapshot_Message, 0, len(open.replica.messages), allocator)
    for owned in open.replica.messages {
        if m, ok := snapshot_message_from_wire(owned.message, allocator); ok {
            append(&msgs, m)
        }
    }

    snap := Snapshot {
        session_id = string(sid[:]),
        sync       = sync_state_wire(open.sync),
        rev        = open.rev,
        has_more   = open.replica.has_more,
        messages   = msgs[:],
    }

    if info, has := client.replica_active_info(&open.replica); has {
        parts := make([dynamic]Snapshot_Part, 0, info.part_count, allocator)

        for i in 0 ..< info.part_count {
            pid := wire.Part_Id(u64(i))

            kind, kok := client.replica_part_kind(&open.replica, pid)
            if !kok {
                continue
            }

            #partial switch kind {
            case .Text, .Reasoning:
                if txt, tok := client.replica_part_text(&open.replica, pid); tok {
                    append(&parts, Snapshot_Part{type = kind == .Reasoning ? "reasoning" : "text", text = txt})
                }
            }
        }

        snap.active = Snapshot_Message {
            type    = "assistant",
            id      = u64(info.message_id),
            content = parts[:],
        }
    }

    bytes, err := json.marshal(snap, {}, allocator)
    if err != nil {
        return "null"
    }

    return string(bytes)
}

// Build a folded message from a committed wire message, extracting text-bearing parts. A
// compaction divider carries no transcript text and is skipped (`ok` false).
@(private = "file")
snapshot_message_from_wire :: proc(msg: wire.Message, allocator := context.allocator) -> (Snapshot_Message, bool) {
    switch v in msg {
    case wire.User_Message:
        parts := make([dynamic]Snapshot_Part, 0, len(v.content), allocator)
        for part in v.content {
            if t, ok := part.(wire.Content_Text); ok {
                append(&parts, Snapshot_Part{type = "text", text = t.text})
            }
        }

        return {type = "user", id = u64(v.id), content = parts[:]}, true

    case wire.Assistant_Message:
        parts := make([dynamic]Snapshot_Part, 0, len(v.content), allocator)
        for part in v.content {
            #partial switch p in part {
            case wire.Text_Part:
                append(&parts, Snapshot_Part{type = "text", text = p.text})

            case wire.Reasoning_Part:
                append(&parts, Snapshot_Part{type = "reasoning", text = p.text})
            }
        }

        return {type = "assistant", id = u64(v.id), content = parts[:]}, true

    case wire.Compaction_Message:
        return {}, false
    }

    return {}, false
}
