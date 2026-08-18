package tui

import "core:strings"
import "core:testing"

import qjs "libs:bindings/quickjs"
import "src:client"
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

// Put the host in the state a completed resync leaves: a live, synced replica for the shared
// session, plus a faked live daemon client so `client_on_broadcast`'s connection asserts hold.
@(private = "file")
session_test_open_synced :: proc(h: ^Host) {
    client.replica_init(&h.open_session.replica, h.allocator, _session_id())
    h.open_session.live = true
    h.open_session.sync = .Synced

    h.daemon.live = true
    h.daemon.client.user_data = h
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
        import { sessionOpen, sessionClose, sessionRev, sessionSnapshot } from "yuke:client";
        const before = sessionRev();
        sessionOpen("0123456789abcdef");
        const snap = sessionSnapshot();
        const opened = [sessionRev() >= 0, snap.sessionId, snap.sync, snap.messages.length, snap.active];
        sessionClose();
        globalThis.result = JSON.stringify([before, opened, sessionRev(), sessionSnapshot()]);
    `
    testing.expect(t, js.eval_module(&h.js, "test:session-lifecycle", source, context.allocator))
    testing.expect_value(t, session_test_result(t, &h), `[-1,[true,"0123456789abcdef","needs_resync",0,null],-1,null]`)
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
          sessionOpen("not-a-hex-id!!!!");
        } catch (_e) {
          threw = true;
        }
        globalThis.result = threw + ":" + sessionRev();
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

    // Opened but not yet resynced: broadcasts must be dropped, not folded onto a stale cut.
    client.replica_init(&h.open_session.replica, h.allocator, _session_id())
    h.open_session.live = true
    h.open_session.sync = .Needs_Resync
    h.daemon.live = true
    h.daemon.client.user_data = &h

    rev_before := h.open_session.rev
    client_on_broadcast(&h.daemon.client, _started(3))

    testing.expect(t, h.open_session.replica.active == nil, "a dropped start folds nothing")
    testing.expect_value(t, h.open_session.rev, rev_before)
    testing.expect_value(t, h.open_session.sync, Sync_State.Needs_Resync)
}

@(test)
test_synced_fold_updates_snapshot_and_rev :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    h: Host
    if !session_test_host(t, &h) do return

    defer js.destroy(&h.js)
    defer open_session_teardown(&h)

    session_test_open_synced(&h)

    rev_before := h.open_session.rev

    // Commit a user message (durable seq 1), then stream an assistant draft above it. `content`
    // outlives the fold that clones it.
    content := [1]wire.Content_Part{wire.Content_Text{text = "hello"}}
    client_on_broadcast(&h.daemon.client, _committed_user(3, 1, content[:]))
    client_on_broadcast(&h.daemon.client, _started(5))
    client_on_broadcast(&h.daemon.client, _text_added(5, 0, ""))
    client_on_broadcast(&h.daemon.client, _delta(5, 0, 0, "Hi"))

    testing.expect(t, h.open_session.rev > rev_before, "folding visible change bumps rev")

    source := `
        import { sessionSnapshot } from "yuke:client";
        const s = sessionSnapshot();
        globalThis.result = [
          s.sync,
          s.messages.length,
          s.messages[0].type,
          s.messages[0].content[0].text,
          s.active.type,
          s.active.content.map((p) => p.type + ":" + p.text).join(","),
        ].join("|");
    `
    testing.expect(t, js.eval_module(&h.js, "test:session-fold", source, context.allocator))
    testing.expect_value(t, session_test_result(t, &h), "synced|1|user|hello|assistant|text:Hi")
}

@(test)
test_gap_forces_resync_and_then_drops :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    h: Host
    if !session_test_host(t, &h) do return

    defer js.destroy(&h.js)
    defer open_session_teardown(&h)

    session_test_open_synced(&h)

    client_on_broadcast(&h.daemon.client, _started(3))
    client_on_broadcast(&h.daemon.client, _text_added(3, 0, ""))

    // Part ordinal 2 skips ordinal 1: a gap the replica cannot fold in place.
    client_on_broadcast(&h.daemon.client, _text_added(3, 2, "x"))
    testing.expect_value(t, h.open_session.sync, Sync_State.Needs_Resync)

    // With the cut lost, later broadcasts are dropped until a resync reinstalls one.
    rev_after_gap := h.open_session.rev
    client_on_broadcast(&h.daemon.client, _delta(3, 0, 0, "ignored"))
    testing.expect_value(t, h.open_session.rev, rev_after_gap)
}
