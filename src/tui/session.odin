package tui

/*
Open-session controller: folds live broadcasts for the UI's one open session into a native
`client.Session_Replica`. `yuke:client` drives open → resync → fold → close and reads the outline
plus each message's text on demand.
*/

import "base:runtime"
import "core:c"
import "core:mem"
import "core:mem/virtual"
import "core:strings"
import "libs:json"

import qjs "libs:bindings/quickjs"
import "src:client"
import "src:wire"

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

    if !h.open_session.live do return

    client.replica_destroy(&h.open_session.replica)
    h.open_session.live = false
    h.open_session.sync = .Needs_Resync
    h.open_session.rev += 1
}

// Whether a broadcast changes only the streaming draft (UI re-wraps just it) vs. the transcript's
// structure. A commit or truncation also folds to .Changed, so classify by broadcast, not "draft open".
@(private = "file")
session_broadcast_is_draft_delta :: proc(bc: wire.Notification) -> bool {
    #partial switch _ in bc.params {
    case wire.Message_Started_Data,
         wire.Message_Part_Added_Data,
         wire.Message_Part_Delta_Data,
         wire.Tool_State_Changed_Data,
         wire.Tool_Output_Delta_Data:
        return true
    }

    return false
}

// Fold one broadcast for the open session. Dropped unless a session is open and synced; a gap
// or fold error demands a fresh resync. A visible change or a gap bumps `rev` and repaints.
client_on_broadcast :: proc(c: ^client.Client, bc: wire.Notification) {
    assert(c != nil && c.user_data != nil, "broadcast callback lost its host")

    h := (^Host)(c.user_data)
    assert(&h.daemon.client == c && h.daemon.live, "broadcast callback crossed connections")

    if h.done || !h.open_session.live || h.open_session.sync != .Synced do return

    res, err := client.replica_apply_broadcast(&h.open_session.replica, bc)

    if err != .None {
        // OOM or a config-revision conflict: unrecoverable in place, only a fresh cut recovers.
        session_mark_needs_resync(h)
        return
    }

    #partial switch res.kind {
    case .Gap:
        session_mark_needs_resync(h)

    case .Changed:
        h.open_session.rev += 1
        info, has := client.replica_active_info(&h.open_session.replica)
        if session_broadcast_is_draft_delta(bc) && has {
            // Only the streaming draft changed: JS re-wraps just it, by the active message id.
            host_dispatch_session(h, "active", u64(info.message_id))
        } else {
            // A structural change that folds to .Changed (e.g. transcript.truncated): reload.
            host_dispatch_session(h, "reload")
        }

    case .Committed, .Discarded:
        // A structural change (commit/discard): JS re-pulls the outline.
        h.open_session.rev += 1
        host_dispatch_session(h, "reload")
    }
}

// Move the open session back to needing a resync, bump `rev`, and repaint.
session_mark_needs_resync :: proc(h: ^Host) {
    assert(h != nil && h.open_session.live, "resync mark needs an open session")

    h.open_session.sync = .Needs_Resync
    h.open_session.rev += 1
    host_dispatch_session(h, "reload")
}

// Subscribe the daemon connection to the open session's broadcasts, or clear the set when none is
// open — broadcasts are subscription-gated. Sent before resync (cut taken subscribed); no-op if down.
session_subscribe :: proc(h: ^Host) {
    assert(h != nil, "subscribe needs a host")

    if !h.daemon.live do return

    one: [1]wire.Session_Id
    sessions: []wire.Session_Id
    if h.open_session.live {
        one[0] = h.open_session.replica.session_id
        sessions = one[:]
    }

    _, _ = client.client_send_request(
        &h.daemon.client,
        .Subscription_Set,
        wire.Subscription_Set_Params{sessions = sessions},
        client_on_subscription_complete,
    )
}

// Best-effort: a failed subscribe just leaves the replica folding nothing until the next open.
client_on_subscription_complete :: proc(c: ^client.Client, outcome: client.Request_Outcome, user_data: rawptr) {
    _ = c
    _ = outcome
    _ = user_data
}

// --- native session functions (yuke:client-native) ---

// Track `id` (16 lowercase hex chars): drop any prior session, install a fresh replica needing
// a resync before it folds.
@(private = "file")
client_js_session_open :: proc "c" (ctx: ^qjs.Context, this: qjs.Value, argc: c.int, argv: [^]qjs.Value) -> qjs.Value {
    context = runtime.default_context()
    _ = this

    h := host_from_ctx(ctx)
    if h == nil do return qjs.throw_type_error(ctx, "yuke:client has no host")

    if argc < 1 do return qjs.throw_type_error(ctx, "sessionOpen expects a session id")

    id, ok := session_id_from_js(ctx, argv[0])
    if !ok do return qjs.throw_type_error(ctx, "sessionOpen expects a 16 hex-char session id")

    open_session_teardown(h)

    client.replica_init(&h.open_session.replica, h.allocator, id)
    h.open_session.live = true
    h.open_session.sync = .Needs_Resync
    h.open_session.rev += 1

    session_subscribe(h) // before the JS-side resync, so the daemon takes its cut subscribed

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
    if h == nil do return qjs.throw_type_error(ctx, "yuke:client has no host")

    open_session_teardown(h)
    session_subscribe(h) // no session open now: clears the subscription set

    return qjs.undefined()
}

// The open session's change counter, or -1 when none is open. Cheap to poll; re-read the outline
// only when it moves. (Unused by the default UI, which reacts to the "session" event instead.)
@(private = "file")
client_js_session_rev :: proc "c" (ctx: ^qjs.Context, this: qjs.Value, argc: c.int, argv: [^]qjs.Value) -> qjs.Value {
    context = runtime.default_context()
    _ = this
    _ = argc
    _ = argv

    h := host_from_ctx(ctx)
    if h == nil || !h.open_session.live do return qjs.new_i64(-1)

    return qjs.new_i64(i64(h.open_session.rev))
}

// The transcript outline (ids + roles, no text) as a JSON string, or "null" when no session is open.
@(private = "file")
client_js_session_outline :: proc "c" (
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
    if h == nil || !h.open_session.live do return qjs.new_string(ctx, "null")

    temp := virtual.arena_temp_begin(&h.snapshot_scratch)
    defer virtual.arena_temp_end(temp)

    return qjs.new_string(ctx, session_outline_json(h, virtual.arena_allocator(&h.snapshot_scratch)))
}

// The concatenated text of one message (committed or the draft), by id. Empty string when the id is
// absent or has no text. A plain string, not JSON — JS wraps it on demand.
@(private = "file")
client_js_session_text :: proc "c" (ctx: ^qjs.Context, this: qjs.Value, argc: c.int, argv: [^]qjs.Value) -> qjs.Value {
    context = runtime.default_context()
    _ = this

    h := host_from_ctx(ctx)
    if h == nil || !h.open_session.live do return qjs.new_string(ctx, "")

    if argc < 1 do return qjs.throw_type_error(ctx, "sessionText(id)")

    id, ok := qjs.to_i64(ctx, argv[0])
    if !ok do return qjs.exception()

    temp := virtual.arena_temp_begin(&h.snapshot_scratch)
    defer virtual.arena_temp_end(temp)

    text, found := session_message_text(h, u64(id), virtual.arena_allocator(&h.snapshot_scratch))
    if !found do return qjs.new_string(ctx, "")

    return qjs.new_string(ctx, text)
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
    if h == nil do return qjs.throw_type_error(ctx, "yuke:client has no host")

    if h.done do return qjs.throw_type_error(ctx, "yuke:client host is shutting down")

    if !h.open_session.live do return qjs.throw_type_error(ctx, "no session is open")

    if !h.daemon.live do return qjs.throw_type_error(ctx, "not connected")

    params := wire.Session_Resync_Params {
        session_id = h.open_session.replica.session_id,
    }

    job, promise := client_promise_new(h)
    if job == nil {
        if qjs.is_exception(promise) do return promise

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
            host_dispatch_session(h, "reload")

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

    if targeting do host_dispatch_session(h, "reload")
}

@(private = "file")
replica_error_wire :: proc(err: client.Replica_Error) -> string {
    switch err {
    case .None:
        unreachable()

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
        "sessionOutline",
        qjs.new_function(ctx, client_js_session_outline, "sessionOutline", 0),
    )
    _ = qjs.set_property(ctx, native, "sessionText", qjs.new_function(ctx, client_js_session_text, "sessionText", 1))
}

// Parse a JS value into a session id: a 16-char lowercase-hex string held as its bytes.
@(private = "file")
session_id_from_js :: proc(ctx: ^qjs.Context, v: qjs.Value) -> (wire.Session_Id, bool) {
    if !qjs.is_string(v) do return {}, false

    s, ok := qjs.to_string(ctx, v)
    if !ok do return {}, false

    defer qjs.free_string(ctx, s)

    if len(s) != 16 do return {}, false

    arr: [16]u8
    copy(arr[:], transmute([]u8)s)

    if wire.enforce_id(arr) != .None do return {}, false

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

// --- virtualized transcript: outline + on-demand text ---

@(private = "file")
Outline_Message :: struct {
    id:   u64 `json:"id"`,
    type: string `json:"type"`,
}

// The transcript structure without any body text: message ids and roles, plus the streaming draft.
// JS keeps this as its row index and pulls a message's text with sessionText only when it wraps it.
@(private = "file")
Outline :: struct {
    sync:     string `json:"sync"`,
    rev:      u64 `json:"rev"`,
    has_more: bool `json:"hasMore"`,
    messages: []Outline_Message `json:"messages"`,
    active:   Maybe(Outline_Message) `json:"active"`,
}

// The role of a committed message, or ok=false for a compaction divider (no transcript text).
@(private = "file")
message_role_wire :: proc(msg: wire.Message) -> (string, bool) {
    switch v in msg {
    case wire.User_Message:
        return "user", true

    case wire.Assistant_Message:
        return "assistant", true

    case wire.Compaction_Message:
        return {}, false
    }

    return {}, false
}

@(private = "file")
session_outline_json :: proc(h: ^Host, allocator: mem.Allocator) -> string {
    assert(h != nil && h.open_session.live, "outline needs an open session")

    open := &h.open_session

    msgs := make([dynamic]Outline_Message, 0, len(open.replica.messages), allocator)
    for owned in open.replica.messages {
        if role, ok := message_role_wire(owned.message); ok do append(&msgs, Outline_Message{id = u64(wire.message_id(owned.message)), type = role})
    }

    outline := Outline {
        sync     = sync_state_wire(open.sync),
        rev      = open.rev,
        has_more = open.replica.has_more,
        messages = msgs[:],
    }

    if info, has := client.replica_active_info(&open.replica); has {
        outline.active = Outline_Message {
            id   = u64(info.message_id),
            type = "assistant",
        }
    }

    bytes, err := json.marshal(outline, {}, allocator)
    if err != nil do return "null"

    return string(bytes)
}

// Concatenate the text-bearing parts of the message with id `id` (a committed message or the open
// draft), text parts only — reasoning/tool parts are dropped, matching what the transcript renders.
@(private = "file")
session_message_text :: proc(h: ^Host, id: u64, allocator: mem.Allocator) -> (string, bool) {
    assert(h != nil && h.open_session.live, "message text needs an open session")

    open := &h.open_session

    if info, has := client.replica_active_info(&open.replica); has && u64(info.message_id) == id {
        b := strings.builder_make(allocator)
        first := true

        for i in 0 ..< info.part_count {
            pid := wire.Part_Id(u64(i))

            kind, kok := client.replica_part_kind(&open.replica, pid)
            if !kok || kind != .Text do continue

            txt, tok := client.replica_part_text(&open.replica, pid)
            if !tok do continue

            if !first do strings.write_byte(&b, '\n')
            strings.write_string(&b, txt)
            first = false
        }

        return strings.to_string(b), true
    }

    msg, ok := client.replica_committed_by_id(&open.replica, wire.Message_Id(id))
    if !ok do return {}, false

    b := strings.builder_make(allocator)
    first := true

    #partial switch v in msg {
    case wire.User_Message:
        for part in v.content {
            t, is_text := part.(wire.Content_Text)
            if !is_text do continue

            if !first do strings.write_byte(&b, '\n')
            strings.write_string(&b, t.text)
            first = false
        }

    case wire.Assistant_Message:
        for part in v.content {
            p, is_text := part.(wire.Text_Part)
            if !is_text do continue

            if !first do strings.write_byte(&b, '\n')
            strings.write_string(&b, p.text)
            first = false
        }
    }

    return strings.to_string(b), true
}
