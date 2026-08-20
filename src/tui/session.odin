package tui

/*
Open-session controller: folds live broadcasts for each mounted session into a native
`client.Session_Replica`. Entries are keyed by `(connKey, sessionId)`. `yuke:client` drives
open → resync → fold → close and reads the outline plus each message's text on demand.
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

// Where one mounted session sits relative to the resync cut. Broadcasts fold only when `Synced`;
// otherwise they are dropped and the controller (JS) re-issues a resync.
Sync_State :: enum {
    // No valid cut yet: the controller must resync before folding can begin.
    Needs_Resync,

    // A `session.resync` request is in flight; its ordered response is the cut barrier.
    Resyncing,

    // A cut is installed; live broadcasts fold directly.
    Synced,
}

// One mounted transcript. `conn_key` is owned; `rev` bumps on every visible change.
Open_Entry :: struct {
    // Connection this replica is bound to (`local` / `remote:<name>`). Owned.
    conn_key: string,
    replica:  client.Session_Replica,
    sync:     Sync_State,
    rev:      u64,
}

// Destroy every mounted replica. Never repaints: it runs on shutdown paths where painting
// into a dying context is unsafe.
open_session_teardown :: proc(h: ^Host) {
    assert(h != nil, "open session teardown needs a host")

    for i := 0; i < len(h.entries); i += 1 {
        client.replica_destroy(&h.entries[i].replica)
        delete(h.entries[i].conn_key, h.allocator)
    }

    delete(h.entries)
    h.entries = {}
}

// Drop every replica bound to `conn_key` and tell JS to reload those chats. Destroy first:
// `host_dispatch` drains JS, which may open/close entries and relocate the array.
entries_drop_conn :: proc(h: ^Host, conn_key: string) {
    assert(h != nil && conn_key != "", "entries_drop_conn needs a host and key")

    sids: [wire.LIMITS.max_subscriptions]wire.Session_Id
    n := 0
    for i := len(h.entries) - 1; i >= 0; i -= 1 {
        e := &h.entries[i]
        if e.conn_key != conn_key do continue

        assert(n < wire.LIMITS.max_subscriptions, "dropped sessions exceed the subscription cap")
        sids[n] = e.replica.session_id
        n += 1
        client.replica_destroy(&e.replica)
        delete(e.conn_key, h.allocator)
        ordered_remove(&h.entries, i)
    }

    for i in 0 ..< n {
        host_dispatch_session(h, "reload", conn_key, sids[i])
    }
}

entry_by :: proc(h: ^Host, conn_key: string, session_id: wire.Session_Id) -> ^Open_Entry {
    assert(h != nil, "entry_by needs a host")

    for &e in h.entries {
        if e.conn_key == conn_key && e.replica.session_id == session_id do return &e
    }

    return nil
}

// Insert a Needs_Resync replica. Caller must not already hold this pair. The returned pointer
// is invalid after the next append.
entry_insert :: proc(h: ^Host, conn_key: string, session_id: wire.Session_Id) -> ^Open_Entry {
    assert(h != nil && conn_key != "", "entry_insert needs a host and conn key")
    assert(entry_by(h, conn_key, session_id) == nil, "entry_insert of a pair already mounted")

    e: Open_Entry
    e.conn_key = strings.clone(conn_key, h.allocator)
    client.replica_init(&e.replica, h.allocator, session_id)
    e.sync = .Needs_Resync
    e.rev = 1
    append(&h.entries, e)

    return &h.entries[len(h.entries) - 1]
}

entry_close :: proc(h: ^Host, conn_key: string, session_id: wire.Session_Id) {
    assert(h != nil, "entry_close needs a host")

    for &e, i in h.entries {
        if e.conn_key != conn_key || e.replica.session_id != session_id do continue

        client.replica_destroy(&e.replica)
        delete(e.conn_key, h.allocator)
        ordered_remove(&h.entries, i)

        return
    }
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

// Index broadcasts, classified by payload type.
@(private = "file")
index_broadcast_name :: proc(data: wire.Broadcast_Data) -> (wire.Broadcast_Name, bool) {
    #partial switch _ in data {
    case wire.Session_Summary_Changed_Data:
        return .Session_Summary_Changed, true

    case wire.Session_Activity_Changed_Data:
        return .Session_Activity_Changed, true

    case wire.Session_Removed_Data:
        return .Session_Removed, true

    case wire.Workspace_Created_Data:
        return .Workspace_Created, true

    case wire.Workspace_Removed_Data:
        return .Workspace_Removed, true
    }

    return {}, false
}

// Fold one broadcast into the matching mounted replica. Unmounted or unsynced sessions drop it.
// A gap or fold error demands a fresh resync. A visible change bumps `rev` and repaints that chat.
// Index broadcasts never enter a replica — they are dispatched to JS as `{type:"index", …}`.
client_on_broadcast :: proc(c: ^client.Client, bc: wire.Notification) {
    assert(c != nil && c.user_data != nil, "broadcast callback lost its host")

    h := (^Host)(c.user_data)
    conn := conn_by_client(h, c)
    assert(conn != nil && conn.live, "broadcast callback crossed connections")

    if h.done do return

    if name, is_index := index_broadcast_name(bc.params); is_index {
        host_dispatch_index(h, conn.key, name, bc.params)
        return
    }

    sid, ok := client.replica_domain_session_id(bc.params)
    if !ok do return

    entry := entry_by(h, conn.key, sid)
    if entry == nil || entry.sync != .Synced do return

    res, err := client.replica_apply_broadcast(&entry.replica, bc)

    if err != .None {
        session_mark_needs_resync(h, entry)
        return
    }

    #partial switch res.kind {
    case .Gap:
        session_mark_needs_resync(h, entry)

    case .Changed:
        entry.rev += 1
        info, has := client.replica_active_info(&entry.replica)
        if session_broadcast_is_draft_delta(bc) && has {
            host_dispatch_session(h, "active", conn.key, sid, u64(info.message_id))
        } else {
            host_dispatch_session(h, "reload", conn.key, sid)
        }

    case .Committed, .Discarded:
        entry.rev += 1
        host_dispatch_session(h, "reload", conn.key, sid)
    }
}

// Move one mounted session back to needing a resync, bump `rev`, and repaint that chat.
session_mark_needs_resync :: proc(h: ^Host, entry: ^Open_Entry) {
    assert(h != nil && entry != nil, "resync mark needs a host and entry")

    conn_key := entry.conn_key
    session_id := entry.replica.session_id
    entry.sync = .Needs_Resync
    entry.rev += 1
    host_dispatch_session(h, "reload", conn_key, session_id)
}

// Mounted replica count on `conn_key`.
@(private = "file")
entries_on_conn :: proc(h: ^Host, conn_key: string) -> int {
    n := 0
    for e in h.entries {
        if e.conn_key == conn_key do n += 1
    }

    return n
}

// `subscription.set` on `conn` to exactly the sessions mounted on that key. No-op if the
// connection is not Ready or has no transport (tests fake Ready without one). A failed send is
// best-effort — folding stays dead until the next open or a later ready.
session_subscribe_conn :: proc(h: ^Host, conn: ^Conn) {
    assert(h != nil && conn != nil, "subscribe needs a host and connection")

    if !conn.live || conn.client.state != .Ready do return
    if conn.client.transport.send_text == nil do return

    ids: [wire.LIMITS.max_subscriptions]wire.Session_Id
    n := 0
    for e in h.entries {
        if e.conn_key != conn.key do continue
        assert(n < wire.LIMITS.max_subscriptions, "mounted sessions exceed the subscription cap")
        ids[n] = e.replica.session_id
        n += 1
    }

    _, _ = client.client_send_request(
        &conn.client,
        .Subscription_Set,
        wire.Subscription_Set_Params{sessions = ids[:n]},
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

// `sessionOpen(connKey, sessionId)`: mount a replica for the pair. Idempotent if already open.
// Subscribes that connection to the union of its mounted ids.
@(private = "file")
client_js_session_open :: proc "c" (ctx: ^qjs.Context, this: qjs.Value, argc: c.int, argv: [^]qjs.Value) -> qjs.Value {
    context = runtime.default_context()
    _ = this

    h := host_from_ctx(ctx)
    if h == nil do return qjs.throw_type_error(ctx, "yuke:client has no host")

    if argc < 2 do return qjs.throw_type_error(ctx, "sessionOpen expects a connection key and session id")

    key, key_ok := qjs.to_string(ctx, argv[0])
    if !key_ok do return qjs.exception()

    defer qjs.free_string(ctx, key)

    if key == "" do return qjs.throw_type_error(ctx, "sessionOpen expects a connection key and session id")

    id, ok := session_id_from_js(ctx, argv[1])
    if !ok do return qjs.throw_type_error(ctx, "sessionOpen expects a 16 hex-char session id")

    if entry_by(h, key, id) == nil {
        if entries_on_conn(h, key) >= wire.LIMITS.max_subscriptions {
            return qjs.throw_type_error(ctx, "too many open sessions")
        }

        entry_insert(h, key, id)
    }

    if conn := conn_by_key(h, key); conn != nil do session_subscribe_conn(h, conn)

    return qjs.undefined()
}

// `sessionClose(connKey, sessionId)`: drop that replica and resubscribe the connection.
@(private = "file")
client_js_session_close :: proc "c" (
    ctx: ^qjs.Context,
    this: qjs.Value,
    argc: c.int,
    argv: [^]qjs.Value,
) -> qjs.Value {
    context = runtime.default_context()
    _ = this

    h := host_from_ctx(ctx)
    if h == nil do return qjs.throw_type_error(ctx, "yuke:client has no host")

    if argc < 2 do return qjs.throw_type_error(ctx, "sessionClose expects a connection key and session id")

    key, key_ok := qjs.to_string(ctx, argv[0])
    if !key_ok do return qjs.exception()

    defer qjs.free_string(ctx, key)

    id, ok := session_id_from_js(ctx, argv[1])
    if !ok do return qjs.throw_type_error(ctx, "sessionClose expects a 16 hex-char session id")

    entry_close(h, key, id)
    if conn := conn_by_key(h, key); conn != nil do session_subscribe_conn(h, conn)

    return qjs.undefined()
}

// `sessionRev(connKey, sessionId)` → change counter, or -1 when that pair is not mounted.
@(private = "file")
client_js_session_rev :: proc "c" (ctx: ^qjs.Context, this: qjs.Value, argc: c.int, argv: [^]qjs.Value) -> qjs.Value {
    context = runtime.default_context()
    _ = this

    h := host_from_ctx(ctx)
    if h == nil do return qjs.new_i64(-1)

    if argc < 2 do return qjs.throw_type_error(ctx, "sessionRev expects a connection key and session id")

    key, key_ok := qjs.to_string(ctx, argv[0])
    if !key_ok do return qjs.exception()

    defer qjs.free_string(ctx, key)

    id, ok := session_id_from_js(ctx, argv[1])
    if !ok do return qjs.new_i64(-1)

    entry := entry_by(h, key, id)
    if entry == nil do return qjs.new_i64(-1)

    return qjs.new_i64(i64(entry.rev))
}

// `sessionOutline(connKey, sessionId)` → JSON outline, or "null" when that pair is not mounted.
@(private = "file")
client_js_session_outline :: proc "c" (
    ctx: ^qjs.Context,
    this: qjs.Value,
    argc: c.int,
    argv: [^]qjs.Value,
) -> qjs.Value {
    context = runtime.default_context()
    _ = this

    h := host_from_ctx(ctx)
    if h == nil do return qjs.new_string(ctx, "null")

    if argc < 2 do return qjs.throw_type_error(ctx, "sessionOutline expects a connection key and session id")

    key, key_ok := qjs.to_string(ctx, argv[0])
    if !key_ok do return qjs.exception()

    defer qjs.free_string(ctx, key)

    id, ok := session_id_from_js(ctx, argv[1])
    if !ok do return qjs.new_string(ctx, "null")

    entry := entry_by(h, key, id)
    if entry == nil do return qjs.new_string(ctx, "null")

    temp := virtual.arena_temp_begin(&h.snapshot_scratch)
    defer virtual.arena_temp_end(temp)

    return qjs.new_string(ctx, session_outline_json(entry, virtual.arena_allocator(&h.snapshot_scratch)))
}

// `sessionText(connKey, sessionId, messageId)` → concatenated text parts, or "" when absent.
@(private = "file")
client_js_session_text :: proc "c" (ctx: ^qjs.Context, this: qjs.Value, argc: c.int, argv: [^]qjs.Value) -> qjs.Value {
    context = runtime.default_context()
    _ = this

    h := host_from_ctx(ctx)
    if h == nil do return qjs.new_string(ctx, "")

    if argc < 3 do return qjs.throw_type_error(ctx, "sessionText(connKey, sessionId, messageId)")

    key, key_ok := qjs.to_string(ctx, argv[0])
    if !key_ok do return qjs.exception()

    defer qjs.free_string(ctx, key)

    sid, sok := session_id_from_js(ctx, argv[1])
    if !sok do return qjs.new_string(ctx, "")

    mid, mok := qjs.to_i64(ctx, argv[2])
    if !mok do return qjs.exception()

    entry := entry_by(h, key, sid)
    if entry == nil do return qjs.new_string(ctx, "")

    temp := virtual.arena_temp_begin(&h.snapshot_scratch)
    defer virtual.arena_temp_end(temp)

    text, found := session_message_text(entry, u64(mid), virtual.arena_allocator(&h.snapshot_scratch))
    if !found do return qjs.new_string(ctx, "")

    return qjs.new_string(ctx, text)
}

// `sessionResync(connKey, sessionId)`: send `session.resync` and install the ordered cut on that entry.
@(private = "file")
client_js_session_resync :: proc "c" (
    ctx: ^qjs.Context,
    this: qjs.Value,
    argc: c.int,
    argv: [^]qjs.Value,
) -> qjs.Value {
    context = runtime.default_context()
    _ = this

    h := host_from_ctx(ctx)
    if h == nil do return qjs.throw_type_error(ctx, "yuke:client has no host")

    if h.done do return qjs.throw_type_error(ctx, "yuke:client host is shutting down")

    if argc < 2 do return qjs.throw_type_error(ctx, "sessionResync expects a connection key and session id")

    key, key_ok := qjs.to_string(ctx, argv[0])
    if !key_ok do return qjs.exception()

    defer qjs.free_string(ctx, key)

    id, ok := session_id_from_js(ctx, argv[1])
    if !ok do return qjs.throw_type_error(ctx, "sessionResync expects a 16 hex-char session id")

    entry := entry_by(h, key, id)
    if entry == nil do return qjs.throw_type_error(ctx, "no session is open")

    conn := conn_by_key(h, key)
    if conn == nil || !conn.live || conn.client.state != .Ready {
        return qjs.throw_type_error(ctx, "not connected")
    }

    params := wire.Session_Resync_Params {
        session_id = entry.replica.session_id,
    }

    job, promise := client_promise_new(h)
    if job == nil {
        if qjs.is_exception(promise) do return promise

        return qjs.throw_type_error(ctx, "out of memory")
    }

    rj := new(Resync_Job, h.allocator)
    rj.promise = job
    rj.session_id = id

    entry.sync = .Resyncing
    entry.rev += 1

    _, send_err := client.client_send_request(
        &conn.client,
        .Session_Resync,
        params,
        client_on_session_resync_complete,
        rj,
    )
    if send_err != .None {
        free(rj, h.allocator)
        entry.sync = .Needs_Resync
        entry.rev += 1
        client_promise_reject(job, client_protocol_error_wire(send_err), false)
    }

    return promise
}

// Ties a resync completion back to the mounted pair. Freed in the completion callback.
@(private = "file")
Resync_Job :: struct {
    promise:    ^Client_Promise,
    session_id: wire.Session_Id,
}

// Install a resync response into the replica named by the job. A result for a pair the UI
// has since closed is discarded, but its promise still settles.
@(private = "file")
client_on_session_resync_complete :: proc(c: ^client.Client, outcome: client.Request_Outcome, user_data: rawptr) {
    assert(c != nil && c.user_data != nil, "resync completion lost its host")
    assert(user_data != nil, "resync completion lost its job")

    h := (^Host)(c.user_data)
    rj := (^Resync_Job)(user_data)
    job := rj.promise
    session_id := rj.session_id
    free(rj, h.allocator)
    conn := conn_by_client(h, c)
    assert(conn != nil && conn.live, "resync completion crossed connections")
    assert(job.host == h, "resync completion crossed hosts")

    entry := entry_by(h, conn.key, session_id)
    targeting := entry != nil && entry.sync == .Resyncing

    switch result in outcome {
    case client.Request_Response:
        #partial switch resp in result.response {
        case wire.Response_Ok:
            snapshot, is_snapshot := resp.result.(wire.Session_Resync_Result)
            if !is_snapshot {
                resync_fail(h, job, conn.key, session_id, targeting, "unexpected_result")
                return
            }

            if !targeting {
                client_promise_resolve(job, qjs.undefined(), true)
                return
            }

            if install_err := client.replica_install_snapshot(&entry.replica, snapshot); install_err != .None {
                resync_fail(h, job, conn.key, session_id, true, replica_error_wire(install_err))
                return
            }

            entry.sync = .Synced
            entry.rev += 1
            host_dispatch_session(h, "reload", conn.key, session_id)
            client_promise_resolve(job, qjs.undefined(), true)

        case wire.Response_Error:
            resync_fail(h, job, conn.key, session_id, targeting, "resync_rejected")
        }

    case client.Request_Failure:
        resync_fail(h, job, conn.key, session_id, targeting, client_protocol_error_wire(result.error))
    }
}

// Reject a resync promise. When `targeting`, drop that pair back to needing a resync and
// repaint. Look the entry up again: JS may have closed it during an earlier drain.
@(private = "file")
resync_fail :: proc(
    h: ^Host,
    job: ^Client_Promise,
    conn_key: string,
    session_id: wire.Session_Id,
    targeting: bool,
    reason: string,
) {
    if targeting {
        if entry := entry_by(h, conn_key, session_id); entry != nil && entry.sync == .Resyncing {
            entry.sync = .Needs_Resync
            entry.rev += 1
        }

        host_dispatch_session(h, "reload", conn_key, session_id)
    }

    client_promise_reject(job, reason, true)
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
    _ = qjs.set_property(ctx, native, "sessionOpen", qjs.new_function(ctx, client_js_session_open, "sessionOpen", 2))
    _ = qjs.set_property(
        ctx,
        native,
        "sessionClose",
        qjs.new_function(ctx, client_js_session_close, "sessionClose", 2),
    )
    _ = qjs.set_property(ctx, native, "sessionRev", qjs.new_function(ctx, client_js_session_rev, "sessionRev", 2))
    _ = qjs.set_property(
        ctx,
        native,
        "sessionResync",
        qjs.new_function(ctx, client_js_session_resync, "sessionResync", 2),
    )
    _ = qjs.set_property(
        ctx,
        native,
        "sessionOutline",
        qjs.new_function(ctx, client_js_session_outline, "sessionOutline", 2),
    )
    _ = qjs.set_property(ctx, native, "sessionText", qjs.new_function(ctx, client_js_session_text, "sessionText", 3))
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
session_outline_json :: proc(entry: ^Open_Entry, allocator: mem.Allocator) -> string {
    assert(entry != nil, "outline needs a mounted session")

    msgs := make([dynamic]Outline_Message, 0, len(entry.replica.messages), allocator)
    for owned in entry.replica.messages {
        if role, ok := message_role_wire(owned.message); ok do append(&msgs, Outline_Message{id = u64(wire.message_id(owned.message)), type = role})
    }

    outline := Outline {
        sync     = sync_state_wire(entry.sync),
        rev      = entry.rev,
        has_more = entry.replica.has_more,
        messages = msgs[:],
    }

    if info, has := client.replica_active_info(&entry.replica); has {
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
session_message_text :: proc(entry: ^Open_Entry, id: u64, allocator: mem.Allocator) -> (string, bool) {
    assert(entry != nil, "message text needs a mounted session")

    if info, has := client.replica_active_info(&entry.replica); has && u64(info.message_id) == id {
        b := strings.builder_make(allocator)
        first := true

        for i in 0 ..< info.part_count {
            pid := wire.Part_Id(u64(i))

            kind, kok := client.replica_part_kind(&entry.replica, pid)
            if !kok || kind != .Text do continue

            txt, tok := client.replica_part_text(&entry.replica, pid)
            if !tok do continue

            if !first do strings.write_byte(&b, '\n')
            strings.write_string(&b, txt)
            first = false
        }

        return strings.to_string(b), true
    }

    msg, ok := client.replica_committed_by_id(&entry.replica, wire.Message_Id(id))
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
