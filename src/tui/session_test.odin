package tui

import "core:strings"
import "core:testing"

import qjs "libs:bindings/quickjs"
import "src:js"
import "src:wire"

// The 16 hex-char session id every open-session test shares.
@(private = "file")
SID_HEX :: "0123456789abcdef"

@(private = "file")
_session_id :: proc() -> wire.Session_Id {
    out: [16]u8
    copy(out[:], transmute([]u8)string(SID_HEX))

    return wire.Session_Id(out)
}

// A host with only the client native module, like `client_test.odin`.
@(private = "file")
session_test_host :: proc(t: ^testing.T, h: ^Host) -> bool {
    h.allocator = context.allocator
    modules := [1]js.Module{client_module()}

    return testing.expect_value(
        t,
        js.init(&h.js, {modules = modules[:], user = h, resolve = host_resolve, allocator = context.allocator}),
        js.Error.None,
    )
}

// A heap slot so `client_on_broadcast` can find the fake client by address.
// Do not JS-open against this: `session_subscribe_conn` would send on a missing transport.
@(private = "file")
session_test_attach_conn_key :: proc(h: ^Host, key: string) -> ^Conn {
    conn, ok := conn_slot_new(h, key)
    assert(ok, "session test conn slot")
    conn.live = true
    conn.client.user_data = h
    conn.client.state = .Ready

    return conn
}

@(private = "file")
session_test_attach_conn :: proc(h: ^Host) -> ^Conn {
    return session_test_attach_conn_key(h, CONN_LOCAL)
}

// Put the host in the state a completed resync leaves: a live, synced replica for the shared
// session, plus a faked live daemon client so `client_on_broadcast`'s connection asserts hold.
@(private = "file")
session_test_open_synced :: proc(h: ^Host) -> (^Conn, ^Open_Entry) {
    conn := session_test_attach_conn(h)
    entry := entry_insert(h, CONN_LOCAL, _session_id())
    entry.sync = .Synced

    return conn, entry
}

@(private = "file")
SID_HEX_B :: "fedcba9876543210"

@(private = "file")
_session_id_b :: proc() -> wire.Session_Id {
    out: [16]u8
    copy(out[:], transmute([]u8)string(SID_HEX_B))

    return wire.Session_Id(out)
}

@(private = "file")
session_test_result :: proc(t: ^testing.T, h: ^Host) -> string {
    global := qjs.global_object(h.js.ctx)
    defer qjs.free_value(h.js.ctx, global)

    value := qjs.get_property(h.js.ctx, global, "result")
    defer qjs.free_value(h.js.ctx, value)

    result, ok := qjs.to_string(h.js.ctx, value)
    if !testing.expect(t, ok, "session test result should be readable") do return ""

    defer qjs.free_string(h.js.ctx, result)

    return strings.clone(result, context.temp_allocator)
}

// Latch `globalThis.onEvent` so dispatched host events collect in `globalThis.seen`.
@(private = "file")
session_test_catch_events :: proc(t: ^testing.T, h: ^Host) -> bool {
    source := `
        globalThis.seen = [];
        globalThis.onEvent = (ev) => { globalThis.seen.push(ev); };
        export {};
    `
    if !testing.expect(t, js.eval_module(&h.js, "test:catch-events", source, context.allocator)) do return false

    global := qjs.global_object(h.js.ctx)
    defer qjs.free_value(h.js.ctx, global)
    h.on_event = qjs.get_property(h.js.ctx, global, "onEvent")

    return testing.expect(t, qjs.is_function(h.js.ctx, h.on_event), "onEvent should be callable")
}

@(private = "file")
session_test_drop_on_event :: proc(h: ^Host) {
    if h.js.ctx == nil || qjs.is_undefined(h.on_event) do return

    qjs.free_value(h.js.ctx, h.on_event)
    h.on_event = qjs.undefined()
}

@(private = "file")
session_test_seen :: proc(t: ^testing.T, h: ^Host) -> string {
    source := `globalThis.result = JSON.stringify(globalThis.seen); export {};`
    if !testing.expect(t, js.eval_module(&h.js, "test:seen", source, context.allocator)) do return ""

    return session_test_result(t, h)
}

@(private = "file")
_activity_changed :: proc() -> wire.Notification {
    return {
        method = .Session_Activity_Changed,
        params = wire.Session_Activity_Changed_Data {
            session_id = _session_id(),
            activity = {state = wire.Activity_State_Idle{}},
        },
    }
}

// --- broadcast builders ---

@(private = "file")
_started :: proc(message_id: wire.Message_Id) -> wire.Notification {
    return {
        params = wire.Message_Started_Data {
            session_id = _session_id(),
            message_id = message_id,
            run_id = 7,
            config_rev = 2,
            agent = "main",
            created_at_ms = 123,
        },
    }
}

@(private = "file")
_text_added :: proc(message_id: wire.Message_Id, part_id: wire.Part_Id, text: string) -> wire.Notification {
    return {
        params = wire.Message_Part_Added_Data {
            session_id = _session_id(),
            message_id = message_id,
            part = wire.Text_Part{id = part_id, text = text},
        },
    }
}

@(private = "file")
_delta :: proc(message_id: wire.Message_Id, part_id: wire.Part_Id, offset: u64, bytes: string) -> wire.Notification {
    return {
        params = wire.Message_Part_Delta_Data {
            session_id = _session_id(),
            message_id = message_id,
            part_id = part_id,
            offset = offset,
            delta = bytes,
        },
    }
}

// A `message.committed` for a user message whose single text part is backed by `content`. The
// caller owns `content`; it must outlive the fold that clones it.
@(private = "file")
_committed_user :: proc(
    message_id: wire.Message_Id,
    seq: wire.Seq,
    content: []wire.Content_Part,
) -> wire.Notification {
    return {
        params = wire.Message_Committed_Data {
            session_id = _session_id(),
            seq = seq,
            message = wire.User_Message{id = message_id, content = content, input_id = 1},
        },
    }
}

// --- tests ---

@(test)
test_session_open_and_close_lifecycle :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    h: Host
    if !session_test_host(t, &h) do return

    defer js.destroy(&h.js)
    defer open_session_teardown(&h)

    source := `
        import { sessionOpen, sessionClose, sessionRev, sessionOutline } from "yuke:client";
        const k = "local";
        const id = "0123456789abcdef";
        const before = sessionRev(k, id);
        sessionOpen(k, id);
        const o = sessionOutline(k, id);
        const opened = [sessionRev(k, id) >= 0, o.sync, o.messages.length, o.active];
        sessionClose(k, id);
        globalThis.result = JSON.stringify([before, opened, sessionRev(k, id), sessionOutline(k, id)]);
    `
    testing.expect(t, js.eval_module(&h.js, "test:session-lifecycle", source, context.allocator))
    testing.expect_value(t, session_test_result(t, &h), `[-1,[true,"needs_resync",0,null],-1,null]`)
}

@(test)
test_session_open_rejects_non_hex_id :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    h: Host
    if !session_test_host(t, &h) do return

    defer js.destroy(&h.js)
    defer open_session_teardown(&h)

    source := `
        import { sessionOpen, sessionRev } from "yuke:client";
        let threw = false;
        try {
          sessionOpen("local", "not-a-hex-id!!!!");
        } catch (_e) {
          threw = true;
        }
        globalThis.result = threw + ":" + sessionRev("local", "0123456789abcdef");
    `
    testing.expect(t, js.eval_module(&h.js, "test:session-bad-id", source, context.allocator))
    testing.expect_value(t, session_test_result(t, &h), "true:-1")
}

@(test)
test_broadcasts_drop_until_synced :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    h: Host
    if !session_test_host(t, &h) do return

    defer js.destroy(&h.js)
    defer open_session_teardown(&h)
    defer conns_free_unopened(&h)

    // Opened but not yet resynced: broadcasts must be dropped, not folded onto a stale cut.
    conn := session_test_attach_conn(&h)
    entry := entry_insert(&h, CONN_LOCAL, _session_id())

    rev_before := entry.rev
    client_on_broadcast(&conn.client, _started(3))

    testing.expect(t, entry.replica.active == nil, "a dropped start folds nothing")
    testing.expect_value(t, entry.rev, rev_before)
    testing.expect_value(t, entry.sync, Sync_State.Needs_Resync)
}

@(test)
test_synced_fold_updates_snapshot_and_rev :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    h: Host
    if !session_test_host(t, &h) do return

    defer js.destroy(&h.js)
    defer open_session_teardown(&h)
    defer conns_free_unopened(&h)

    conn, entry := session_test_open_synced(&h)

    rev_before := entry.rev

    // Commit a user message (durable seq 1), then stream an assistant draft above it. `content`
    // outlives the fold that clones it.
    content := [1]wire.Content_Part{wire.Content_Text{text = "hello"}}
    client_on_broadcast(&conn.client, _committed_user(3, 1, content[:]))
    client_on_broadcast(&conn.client, _started(5))
    client_on_broadcast(&conn.client, _text_added(5, 0, ""))
    client_on_broadcast(&conn.client, _delta(5, 0, 0, "Hi"))

    testing.expect(t, entry.rev > rev_before, "folding visible change bumps rev")

    source := `
        import { sessionOutline, sessionText } from "yuke:client";
        const k = "local";
        const id = "0123456789abcdef";
        const o = sessionOutline(k, id);
        globalThis.result = [
          o.sync,
          o.messages.length,
          o.messages[0].type,
          sessionText(k, id, o.messages[0].id),
          o.active.type,
          sessionText(k, id, o.active.id),
        ].join("|");
    `
    testing.expect(t, js.eval_module(&h.js, "test:session-fold", source, context.allocator))
    testing.expect_value(t, session_test_result(t, &h), "synced|1|user|hello|assistant|Hi")
}

@(test)
test_gap_forces_resync_and_then_drops :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    h: Host
    if !session_test_host(t, &h) do return

    defer js.destroy(&h.js)
    defer open_session_teardown(&h)
    defer conns_free_unopened(&h)

    conn, entry := session_test_open_synced(&h)

    client_on_broadcast(&conn.client, _started(3))
    client_on_broadcast(&conn.client, _text_added(3, 0, ""))

    // Part ordinal 2 skips ordinal 1: a gap the replica cannot fold in place.
    client_on_broadcast(&conn.client, _text_added(3, 2, "x"))
    testing.expect_value(t, entry.sync, Sync_State.Needs_Resync)

    // With the cut lost, later broadcasts are dropped until a resync reinstalls one.
    rev_after_gap := entry.rev
    client_on_broadcast(&conn.client, _delta(3, 0, 0, "ignored"))
    testing.expect_value(t, entry.rev, rev_after_gap)
}

@(test)
test_two_sessions_are_independent :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    h: Host
    if !session_test_host(t, &h) do return

    defer js.destroy(&h.js)
    defer open_session_teardown(&h)
    defer conns_free_unopened(&h)

    conn := session_test_attach_conn(&h)
    entry_insert(&h, CONN_LOCAL, _session_id()).sync = .Synced
    entry_insert(&h, CONN_LOCAL, _session_id_b()).sync = .Synced
    a := entry_by(&h, CONN_LOCAL, _session_id())
    b := entry_by(&h, CONN_LOCAL, _session_id_b())
    rev_b := b.rev

    client_on_broadcast(&conn.client, _started(3))

    testing.expect(t, a.replica.active != nil, "broadcast for A opens A's draft")
    testing.expect(t, b.replica.active == nil, "broadcast for A does not touch B")
    testing.expect_value(t, b.rev, rev_b)
}

@(test)
test_session_open_two_from_js :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    h: Host
    if !session_test_host(t, &h) do return

    defer js.destroy(&h.js)
    defer open_session_teardown(&h)

    source := `
        import { sessionOpen, sessionRev, sessionClose, sessionOutline } from "yuke:client";
        const k = "local";
        const a = "0123456789abcdef";
        const b = "fedcba9876543210";
        sessionOpen(k, a);
        sessionOpen(k, b);
        const both = sessionRev(k, a) >= 0 && sessionRev(k, b) >= 0;
        sessionClose(k, a);
        const o = sessionOutline(k, b);
        globalThis.result = [both, sessionRev(k, a) < 0, sessionRev(k, b) >= 0, o != null, o && o.sync].join(":");
    `
    testing.expect(t, js.eval_module(&h.js, "test:session-two-js", source, context.allocator))
    testing.expect_value(t, session_test_result(t, &h), "true:true:true:true:needs_resync")
}

@(test)
test_same_id_on_two_conns_is_independent :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    h: Host
    if !session_test_host(t, &h) do return

    defer js.destroy(&h.js)
    defer open_session_teardown(&h)
    defer conns_free_unopened(&h)

    local := session_test_attach_conn(&h)
    _ = session_test_attach_conn_key(&h, "remote:x")
    sid := _session_id()
    entry_insert(&h, CONN_LOCAL, sid).sync = .Synced
    entry_insert(&h, "remote:x", sid).sync = .Synced
    local_e := entry_by(&h, CONN_LOCAL, sid)
    remote_e := entry_by(&h, "remote:x", sid)
    rev_r := remote_e.rev

    client_on_broadcast(&local.client, _started(3))

    testing.expect(t, local_e.replica.active != nil, "local broadcast opens the local draft")
    testing.expect(t, remote_e.replica.active == nil, "the same session id on another conn is untouched")
    testing.expect_value(t, remote_e.rev, rev_r)
}

@(test)
test_conn_close_drops_only_that_connections_entries :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    h: Host
    if !session_test_host(t, &h) do return

    defer js.destroy(&h.js)
    defer open_session_teardown(&h)
    defer conns_free_unopened(&h)

    _ = session_test_attach_conn(&h)
    remote := session_test_attach_conn_key(&h, "remote:x")
    sid := _session_id()
    entry_insert(&h, CONN_LOCAL, sid)
    entry_insert(&h, "remote:x", sid)

    client_on_close(&remote.client, 1000)

    testing.expect(t, entry_by(&h, CONN_LOCAL, sid) != nil, "local replica survives a remote close")
    testing.expect(t, entry_by(&h, "remote:x", sid) == nil, "remote replica drops with its connection")
}

@(test)
test_activity_changed_is_index_without_replica :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    h: Host
    if !session_test_host(t, &h) do return

    defer js.destroy(&h.js)
    defer session_test_drop_on_event(&h)
    defer conns_free_unopened(&h)
    if !session_test_catch_events(t, &h) do return

    conn := session_test_attach_conn(&h)
    client_on_broadcast(&conn.client, _activity_changed())
    client_on_broadcast(&conn.client, _started(3))

    testing.expect_value(
        t,
        session_test_seen(t, &h),
        `[{"type":"index","connKey":"local","method":"session.activity_changed","params":{"session_id":"0123456789abcdef","activity":{"state":{"type":"idle"},"queued":0,"context_usage":{"input":0,"output":0,"reasoning":0,"cache_read":0,"cache_write":0},"pending_compaction":null}}}]`,
    )
}

@(test)
test_conn_ready_includes_hello_workspaces :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    h: Host
    if !session_test_host(t, &h) do return

    defer js.destroy(&h.js)
    defer session_test_drop_on_event(&h)
    defer conns_free_unopened(&h)
    if !session_test_catch_events(t, &h) do return

    conn := session_test_attach_conn(&h)
    job, promise := client_promise_new(&h)
    if !testing.expect(t, job != nil, "ready test needs a connect promise") do return

    defer qjs.free_value(h.js.ctx, promise)
    conn.connect_job = job

    ws := wire.Workspace {
        id    = wire.Workspace_Id(([16]u8)(_session_id())),
        root  = "/tmp/ws",
        title = "demo",
    }
    workspaces := [1]wire.Workspace{ws}
    client_on_ready(&conn.client, wire.Initialize_Result{workspaces = workspaces[:]})

    testing.expect_value(
        t,
        session_test_seen(t, &h),
        `[{"type":"conn","kind":"ready","key":"local","workspaces":[{"id":"0123456789abcdef","root":"/tmp/ws","title":"demo"}]}]`,
    )
}

@(test)
test_conn_close_and_error_events :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    h: Host
    if !session_test_host(t, &h) do return

    defer js.destroy(&h.js)
    defer session_test_drop_on_event(&h)
    defer conns_free_unopened(&h)
    if !session_test_catch_events(t, &h) do return

    remote := session_test_attach_conn_key(&h, "remote:x")
    client_on_close(&remote.client, 1000)
    local := session_test_attach_conn(&h)
    client_on_error(&local.client, .Transport_Failed)

    testing.expect_value(
        t,
        session_test_seen(t, &h),
        `[{"type":"conn","kind":"close","key":"remote:x","code":1000},{"type":"conn","kind":"error","key":"local","code":"transport_failed"}]`,
    )
}

@(test)
test_session_open_rejects_past_subscription_cap :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    h: Host
    if !session_test_host(t, &h) do return

    defer js.destroy(&h.js)
    defer open_session_teardown(&h)

    source := `
        import { sessionOpen, sessionRev } from "yuke:client";
        const k = "local";
        const ids = [];
        for (let i = 0; i < 64; i++) ids.push(i.toString(16).padStart(16, "0"));
        for (const id of ids) sessionOpen(k, id);
        let threw = false;
        try {
          sessionOpen(k, "ffffffffffffffff");
        } catch (_e) {
          threw = true;
        }
        globalThis.result = [threw, sessionRev(k, ids[63]) >= 0, sessionRev(k, "ffffffffffffffff") < 0].join(":");
    `
    testing.expect(t, js.eval_module(&h.js, "test:session-cap", source, context.allocator))
    testing.expect_value(t, session_test_result(t, &h), "true:true:true")
}
