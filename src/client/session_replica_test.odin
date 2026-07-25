package client

import "core:mem"
import "core:strings"
import "core:testing"
import ts "libs:testsupport"
import wire "src:wire"

@(private = "file")
_session_id :: proc(s: string) -> wire.Session_Id {
    out: [16]u8
    for i in 0 ..< 16 {
        out[i] = s[i]
    }

    return wire.Session_Id(out)
}

// Session id shared by all live-folding test frames.
@(private = "file")
_sid :: proc() -> wire.Session_Id {
    return _session_id("0123456789abcdef")
}

// Build a `message.started` frame for `message_id`.
@(private = "file")
_started :: proc(message_id: wire.Message_Id) -> wire.Message_Started_Data {
    return {
        session_id = _sid(),
        message_id = message_id,
        run_id = 7,
        config_rev = 2,
        agent = "main",
        created_at_ms = 123,
    }
}

// Build a `message.part_added` frame carrying `part`.
@(private = "file")
_part_added :: proc(message_id: wire.Message_Id, part: wire.Assistant_Part) -> wire.Message_Part_Added_Data {
    return {session_id = _sid(), message_id = message_id, part = part}
}

// Build a `message.part_added` frame carrying a text part.
@(private = "file")
_text_part :: proc(message_id: wire.Message_Id, part_id: wire.Part_Id, text: string) -> wire.Message_Part_Added_Data {
    return _part_added(message_id, wire.Text_Part{id = part_id, text = text})
}

// Build a `message.part_added` frame carrying a reasoning part.
@(private = "file")
_reasoning_part :: proc(
    message_id: wire.Message_Id,
    part_id: wire.Part_Id,
    text: string,
) -> wire.Message_Part_Added_Data {
    return _part_added(message_id, wire.Reasoning_Part{id = part_id, text = text})
}

// Build a `message.part_delta` frame.
@(private = "file")
_delta :: proc(
    message_id: wire.Message_Id,
    part_id: wire.Part_Id,
    offset: u64,
    bytes: string,
) -> wire.Message_Part_Delta_Data {
    return {session_id = _sid(), message_id = message_id, part_id = part_id, delta = bytes, offset = offset}
}

// Build a `tool.output_delta` frame.
@(private = "file")
_tool_out :: proc(
    message_id: wire.Message_Id,
    part_id: wire.Part_Id,
    offset: u64,
    bytes: string,
) -> wire.Tool_Output_Delta_Data {
    return {session_id = _sid(), message_id = message_id, part_id = part_id, delta = bytes, offset = offset}
}

// Start a draft and append an empty text part.
@(private = "file")
_open_text :: proc(t: ^testing.T, r: ^Session_Replica, message_id: wire.Message_Id) {
    res, err := replica_on_started(r, _started(message_id))
    testing.expect_value(t, err, Replica_Error.None)
    testing.expect_value(t, res.kind, Apply_Kind.Changed)

    res2, err2 := replica_on_part_added(r, _text_part(message_id, 0, ""))
    testing.expect_value(t, err2, Replica_Error.None)
    testing.expect_value(t, res2.kind, Apply_Kind.Changed)
}

// A freshly initialized replica is empty and live, and deinit frees it without leaks
// (the test runner's tracking allocator asserts the latter).
@(test)
test_replica_init_deinit :: proc(t: ^testing.T) {
    sid := _session_id("0123456789abcdef")

    r: Session_Replica
    replica_init(&r, context.allocator, sid)
    defer replica_deinit(&r)

    testing.expect_value(t, r.session_id, sid)
    testing.expect(t, r.active == nil, "no active draft")
    testing.expect(t, r.resync == nil, "starts live")
    testing.expect_value(t, len(r.messages), 0)
    testing.expect_value(t, len(r.queued), 0)
    testing.expect_value(t, len(r.configs), 0)
    testing.expect(t, r.highest_finalized_id == nil, "nothing finalized")
    testing.expect(t, r.pending_permission == nil, "no pending permission")
}

@(test)
test_active_draft_retains_metadata_and_accumulates_text :: proc(t: ^testing.T) {
    r: Session_Replica
    replica_init(&r, context.allocator, _sid())
    defer replica_deinit(&r)

    _open_text(t, &r, 3)

    res, err := replica_on_part_delta(&r, _delta(3, 0, 0, "He"))
    testing.expect_value(t, err, Replica_Error.None)
    testing.expect_value(t, res.kind, Apply_Kind.Changed)

    res2, _ := replica_on_part_delta(&r, _delta(3, 0, 2, "llo"))
    testing.expect_value(t, res2.kind, Apply_Kind.Changed)

    text, ok := replica_part_text(&r, 0)
    testing.expect(t, ok, "part text present")
    testing.expect_value(t, text, "Hello")

    info, has := replica_active_info(&r)
    testing.expect(t, has, "active info present")
    testing.expect_value(t, info.message_id, wire.Message_Id(3))
    testing.expect_value(t, info.run_id, wire.Run_Id(7))
    testing.expect_value(t, info.config_rev, wire.Config_Rev(2))
    testing.expect_value(t, info.agent, "main")
    testing.expect_value(t, info.created_at_ms, u64(123))
    testing.expect_value(t, info.part_count, 1)
}

@(test)
test_active_draft_copies_frame_owned_metadata_and_delta_bytes :: proc(t: ^testing.T) {
    r: Session_Replica
    replica_init(&r, context.allocator, _sid())
    defer replica_deinit(&r)

    src: mem.Dynamic_Arena
    mem.dynamic_arena_init(&src, context.allocator, context.allocator)
    a := mem.dynamic_arena_allocator(&src)

    start := _started(3)
    start.agent = strings.clone("worker", a)
    res, err := replica_on_started(&r, start)
    testing.expect_value(t, err, Replica_Error.None)
    testing.expect_value(t, res.kind, Apply_Kind.Changed)

    res2, _ := replica_on_part_added(&r, _text_part(3, 0, strings.clone("initial ", a)))
    testing.expect_value(t, res2.kind, Apply_Kind.Changed)

    res3, _ := replica_on_part_delta(&r, _delta(3, 0, 8, strings.clone("streamed", a)))
    testing.expect_value(t, res3.kind, Apply_Kind.Changed)

    // Drop the source arena: the replica must own its own copies now.
    mem.dynamic_arena_destroy(&src)

    info, _ := replica_active_info(&r)
    testing.expect_value(t, info.agent, "worker")

    text, _ := replica_part_text(&r, 0)
    testing.expect_value(t, text, "initial streamed")
}

@(test)
test_reasoning_part_has_reasoning_kind_and_folds :: proc(t: ^testing.T) {
    r: Session_Replica
    replica_init(&r, context.allocator, _sid())
    defer replica_deinit(&r)

    _, _ = replica_on_started(&r, _started(3))

    res, _ := replica_on_part_added(&r, _reasoning_part(3, 0, "why"))
    testing.expect_value(t, res.kind, Apply_Kind.Changed)

    kind, ok := replica_part_kind(&r, 0)
    testing.expect(t, ok, "part kind present")
    testing.expect_value(t, kind, Part_Kind.Reasoning)

    res2, _ := replica_on_part_delta(&r, _delta(3, 0, 3, " now"))
    testing.expect_value(t, res2.kind, Apply_Kind.Changed)

    text, _ := replica_part_text(&r, 0)
    testing.expect_value(t, text, "why now")
}

@(test)
test_offsets_count_utf8_bytes :: proc(t: ^testing.T) {
    r: Session_Replica
    replica_init(&r, context.allocator, _sid())
    defer replica_deinit(&r)

    _open_text(t, &r, 3)

    // "é" is two UTF-8 bytes, so the next delta lands at offset 2.
    res, _ := replica_on_part_delta(&r, _delta(3, 0, 0, "é"))
    testing.expect_value(t, res.kind, Apply_Kind.Changed)

    text, _ := replica_part_text(&r, 0)
    testing.expect_value(t, len(text), 2)

    res2, _ := replica_on_part_delta(&r, _delta(3, 0, 2, "!"))
    testing.expect_value(t, res2.kind, Apply_Kind.Changed)

    text2, _ := replica_part_text(&r, 0)
    testing.expect_value(t, text2, "é!")
}

@(test)
test_duplicate_overlap_ignored_and_forward_offset_is_gap :: proc(t: ^testing.T) {
    r: Session_Replica
    replica_init(&r, context.allocator, _sid())
    defer replica_deinit(&r)

    _open_text(t, &r, 3)
    _, _ = replica_on_part_delta(&r, _delta(3, 0, 0, "Hello"))

    // Re-sending bytes already applied is a no-op.
    dup, _ := replica_on_part_delta(&r, _delta(3, 0, 0, "Hello"))
    testing.expect_value(t, dup.kind, Apply_Kind.Ignored)

    overlap, _ := replica_on_part_delta(&r, _delta(3, 0, 2, "llo"))
    testing.expect_value(t, overlap.kind, Apply_Kind.Ignored)

    // An offset past the end means a missed delta: resync.
    gap, _ := replica_on_part_delta(&r, _delta(3, 0, 9, "!"))
    testing.expect_value(t, gap.kind, Apply_Kind.Gap)

    text, _ := replica_part_text(&r, 0)
    testing.expect_value(t, text, "Hello")
}

@(test)
test_missing_part_and_tool_target_delta_are_gaps :: proc(t: ^testing.T) {
    r: Session_Replica
    replica_init(&r, context.allocator, _sid())
    defer replica_deinit(&r)

    _, _ = replica_on_started(&r, _started(3))

    // No part at ordinal 0 yet.
    miss, _ := replica_on_part_delta(&r, _delta(3, 0, 0, "x"))
    testing.expect_value(t, miss.kind, Apply_Kind.Gap)

    _, _ = replica_on_part_added(
        &r,
        _part_added(3, wire.Tool_Part{id = 0, name = "read", arguments = "{}", state = wire.Tool_State_Pending{}}),
    )

    // A tool part has no byte buffer, so a delta targeting it is still a gap.
    tool_delta, _ := replica_on_part_delta(&r, _delta(3, 0, 0, "x"))
    testing.expect_value(t, tool_delta.kind, Apply_Kind.Gap)
}

@(test)
test_part_ordinals_append_ignore_duplicates_and_detect_gaps :: proc(t: ^testing.T) {
    r: Session_Replica
    replica_init(&r, context.allocator, _sid())
    defer replica_deinit(&r)

    _, _ = replica_on_started(&r, _started(3))

    add, _ := replica_on_part_added(&r, _text_part(3, 0, "a"))
    testing.expect_value(t, add.kind, Apply_Kind.Changed)

    // Re-announcing ordinal 0 is ignored; skipping to ordinal 2 is a gap.
    dup, _ := replica_on_part_added(&r, _text_part(3, 0, "replacement"))
    testing.expect_value(t, dup.kind, Apply_Kind.Ignored)

    gap, _ := replica_on_part_added(&r, _text_part(3, 2, "gap"))
    testing.expect_value(t, gap.kind, Apply_Kind.Gap)

    text, _ := replica_part_text(&r, 0)
    testing.expect_value(t, text, "a")
}

@(test)
test_tool_part_recursively_outlives_its_source_arena :: proc(t: ^testing.T) {
    r: Session_Replica
    replica_init(&r, context.allocator, _sid())
    defer replica_deinit(&r)

    _, _ = replica_on_started(&r, _started(3))

    // Build a fully-populated tool part in a throwaway source arena.
    src: mem.Dynamic_Arena
    mem.dynamic_arena_init(&src, context.allocator, context.allocator)
    a := mem.dynamic_arena_allocator(&src)

    creates := make([]string, 1, a)
    creates[0] = strings.clone("yuke.exec starts with git", a)

    options := make([]wire.Permission_Option, 1, a)
    options[0] = wire.Permission_Option {
        id      = strings.clone("always", a),
        kind    = .Allow_Always,
        label   = strings.clone("Always allow", a),
        creates = creates,
    }

    views := make([]wire.View, 1, a)
    views[0] = wire.View_Text {
        text     = strings.clone("git status", a),
        language = strings.clone("sh", a),
    }

    tool := wire.Tool_Part {
        id = 0,
        call_id = strings.clone("call-1", a),
        name = strings.clone("yuke.exec", a),
        arguments = strings.clone("{\"cmd\":\"git status\"}", a),
        input_view = views,
        state = wire.Tool_State_Waiting_Permission {
            permission_state = wire.Permission_State{requested_at_ms = 99, options = options},
        },
    }
    res, err := replica_on_part_added(&r, _part_added(3, tool))
    testing.expect_value(t, err, Replica_Error.None)
    testing.expect_value(t, res.kind, Apply_Kind.Changed)

    // Drop the source: everything read below must come from the replica's arena.
    mem.dynamic_arena_destroy(&src)

    tp := replica_tool_part(&r, 0)
    testing.expect(t, tp != nil, "tool part present")

    call_id, _ := tp.call_id.?
    testing.expect_value(t, call_id, "call-1")
    testing.expect_value(t, tp.name, "yuke.exec")
    testing.expect_value(t, tp.arguments, "{\"cmd\":\"git status\"}")

    got_views, _ := tp.input_view.?
    view_text, is_text := got_views[0].(wire.View_Text)
    testing.expect(t, is_text, "input view is text")
    testing.expect_value(t, view_text.text, "git status")
    lang, _ := view_text.language.?
    testing.expect_value(t, lang, "sh")

    waiting, is_waiting := tp.state.(wire.Tool_State_Waiting_Permission)
    testing.expect(t, is_waiting, "state is waiting_permission")
    opts, _ := waiting.permission_state.options.?
    testing.expect_value(t, opts[0].id, "always")
    testing.expect_value(t, opts[0].label, "Always allow")
    opt_creates, _ := opts[0].creates.?
    testing.expect_value(t, opt_creates[0], "yuke.exec starts with git")
}

@(test)
test_tool_state_replacement_recursively_outlives_its_source_arena :: proc(t: ^testing.T) {
    r: Session_Replica
    replica_init(&r, context.allocator, _sid())
    defer replica_deinit(&r)

    _, _ = replica_on_started(&r, _started(3))
    _, _ = replica_on_part_added(
        &r,
        _part_added(
            3,
            wire.Tool_Part{id = 0, name = "yuke.exec", arguments = "{}", state = wire.Tool_State_Pending{}},
        ),
    )

    // Build a completed state with a diff view in a throwaway source arena.
    src: mem.Dynamic_Arena
    mem.dynamic_arena_init(&src, context.allocator, context.allocator)
    a := mem.dynamic_arena_allocator(&src)

    lines := make([]string, 1, a)
    lines[0] = strings.clone("+done", a)

    hunks := make([]wire.Diff_Hunk, 1, a)
    hunks[0] = wire.Diff_Hunk {
        old_start = 1,
        old_lines = 0,
        new_start = 1,
        new_lines = 1,
        lines     = lines,
    }

    files := make([]wire.Diff_File, 1, a)
    files[0] = wire.Diff_File {
        path  = strings.clone("a.txt", a),
        hunks = hunks,
    }

    views := make([]wire.View, 1, a)
    views[0] = wire.View_Diff {
        files = files,
    }

    changed := wire.Tool_State_Changed_Data {
        session_id = _sid(),
        message_id = 3,
        part_id = 0,
        state = wire.Tool_State_Completed {
            output = strings.clone("done", a),
            view = views,
            duration_ms = 12,
            permission_state = wire.Permission_State {
                requested_at_ms = 1,
                decision = wire.Permission_Decision_User {
                    option_id = strings.clone("once", a),
                    kind = .Allow_Once,
                    label = strings.clone("Allow once", a),
                    resolved_at_ms = 2,
                    decided_by = wire.Client{name = strings.clone("yuke-tui", a), version = strings.clone("0.1", a)},
                },
            },
        },
    }
    res, err := replica_on_tool_state_changed(&r, changed)
    testing.expect_value(t, err, Replica_Error.None)
    testing.expect_value(t, res.kind, Apply_Kind.Changed)

    // Drop the source: the replaced state must live in the replica's arena.
    mem.dynamic_arena_destroy(&src)

    tp := replica_tool_part(&r, 0)
    completed, is_completed := tp.state.(wire.Tool_State_Completed)
    testing.expect(t, is_completed, "state is completed")
    testing.expect_value(t, completed.output, "done")

    got_views, _ := completed.view.?
    diff, is_diff := got_views[0].(wire.View_Diff)
    testing.expect(t, is_diff, "view is diff")
    testing.expect_value(t, diff.files[0].path, "a.txt")
    testing.expect_value(t, diff.files[0].hunks[0].lines[0], "+done")

    ps, _ := completed.permission_state.?
    dec, _ := ps.decision.?
    user, is_user := dec.(wire.Permission_Decision_User)
    testing.expect(t, is_user, "decision is user")
    testing.expect_value(t, user.option_id, "once")
    testing.expect_value(t, user.label, "Allow once")
    testing.expect_value(t, user.decided_by.name, "yuke-tui")
    testing.expect_value(t, user.decided_by.version, "0.1")
}

@(test)
test_tool_state_broadcasts_converge_pending_permission :: proc(t: ^testing.T) {
    r: Session_Replica
    replica_init(&r, context.allocator, _sid())
    defer replica_deinit(&r)

    _, _ = replica_on_started(&r, _started(3))
    _, _ = replica_on_part_added(
        &r,
        _part_added(
            3,
            wire.Tool_Part {
                id = 0,
                name = "yuke.exec",
                arguments = "{\"cmd\":\"git status\"}",
                state = wire.Tool_State_Pending{},
            },
        ),
    )

    options := []wire.Permission_Option{{id = "once", kind = .Allow_Once, label = "Allow"}}
    res, _ := replica_on_tool_state_changed(
        &r,
        wire.Tool_State_Changed_Data {
            session_id = _sid(),
            message_id = 3,
            part_id = 0,
            state = wire.Tool_State_Waiting_Permission {
                permission_state = wire.Permission_State{requested_at_ms = 9, options = options},
            },
        },
    )
    testing.expect_value(t, res.kind, Apply_Kind.Changed)

    pending, ok := replica_pending_permission(&r)
    testing.expect(t, ok, "pending permission present")
    testing.expect_value(t, pending.tool_name, "yuke.exec")
    testing.expect_value(t, pending.arguments, "{\"cmd\":\"git status\"}")

    res2, _ := replica_on_tool_state_changed(
        &r,
        wire.Tool_State_Changed_Data {
            session_id = _sid(),
            message_id = 3,
            part_id = 0,
            state = wire.Tool_State_Running{started_at_ms = 10},
        },
    )
    testing.expect_value(t, res2.kind, Apply_Kind.Changed)

    _, still := replica_pending_permission(&r)
    testing.expect(t, !still, "pending permission cleared")
}

@(test)
test_pending_permission_view_outlives_its_source_frames :: proc(t: ^testing.T) {
    r: Session_Replica
    replica_init(&r, context.allocator, _sid())
    defer replica_deinit(&r)

    _, _ = replica_on_started(&r, _started(3))

    // Tool part in one throwaway frame...
    part_src: mem.Dynamic_Arena
    mem.dynamic_arena_init(&part_src, context.allocator, context.allocator)
    pa := mem.dynamic_arena_allocator(&part_src)
    _, _ = replica_on_part_added(
        &r,
        _part_added(
            3,
            wire.Tool_Part {
                id = 0,
                name = strings.clone("yuke.exec", pa),
                arguments = strings.clone("{\"cmd\":\"ls\"}", pa),
                state = wire.Tool_State_Pending{},
            },
        ),
    )
    mem.dynamic_arena_destroy(&part_src)

    // ...waiting transition in another.
    state_src: mem.Dynamic_Arena
    mem.dynamic_arena_init(&state_src, context.allocator, context.allocator)
    sa := mem.dynamic_arena_allocator(&state_src)
    options := make([]wire.Permission_Option, 1, sa)
    options[0] = wire.Permission_Option {
        id    = strings.clone("once", sa),
        kind  = .Allow_Once,
        label = strings.clone("Allow once", sa),
    }
    res, _ := replica_on_tool_state_changed(
        &r,
        wire.Tool_State_Changed_Data {
            session_id = _sid(),
            message_id = 3,
            part_id = 0,
            state = wire.Tool_State_Waiting_Permission {
                permission_state = wire.Permission_State{requested_at_ms = 9, options = options},
            },
        },
    )
    testing.expect_value(t, res.kind, Apply_Kind.Changed)
    mem.dynamic_arena_destroy(&state_src)

    // Both frames freed; the view must read the draft's own copies.
    pending, ok := replica_pending_permission(&r)
    testing.expect(t, ok, "pending permission present")
    testing.expect_value(t, pending.message_id, wire.Message_Id(3))
    testing.expect_value(t, pending.part_id, wire.Part_Id(0))
    testing.expect_value(t, pending.tool_name, "yuke.exec")
    testing.expect_value(t, pending.arguments, "{\"cmd\":\"ls\"}")
    testing.expect_value(t, pending.options[0].id, "once")
    testing.expect_value(t, pending.requested_at_ms, u64(9))
}

@(test)
test_discard_clears_pending_permission :: proc(t: ^testing.T) {
    r: Session_Replica
    replica_init(&r, context.allocator, _sid())
    defer replica_deinit(&r)

    _, _ = replica_on_started(&r, _started(3))
    _, _ = replica_on_part_added(
        &r,
        _part_added(3, wire.Tool_Part{id = 0, name = "read", arguments = "{}", state = wire.Tool_State_Pending{}}),
    )

    options := []wire.Permission_Option{{id = "once", kind = .Allow_Once, label = "Allow"}}
    res, _ := replica_on_tool_state_changed(
        &r,
        wire.Tool_State_Changed_Data {
            session_id = _sid(),
            message_id = 3,
            part_id = 0,
            state = wire.Tool_State_Waiting_Permission {
                permission_state = wire.Permission_State{requested_at_ms = 1, options = options},
            },
        },
    )
    testing.expect_value(t, res.kind, Apply_Kind.Changed)

    _, set := replica_pending_permission(&r)
    testing.expect(t, set, "pending permission set")

    // Discarding the draft clears the pending permission it anchored.
    disc := replica_on_discarded(&r, wire.Message_Discarded_Data{session_id = _sid(), message_id = 3, reason = .Retry})
    testing.expect_value(t, disc.kind, Apply_Kind.Discarded)

    _, still := replica_pending_permission(&r)
    testing.expect(t, !still, "pending permission cleared by discard")
}

@(test)
test_tool_state_entering_waiting_gap_guards :: proc(t: ^testing.T) {
    r: Session_Replica
    replica_init(&r, context.allocator, _sid())
    defer replica_deinit(&r)

    _, _ = replica_on_started(&r, _started(3))
    _, _ = replica_on_part_added(
        &r,
        _part_added(3, wire.Tool_Part{id = 0, name = "read", arguments = "{}", state = wire.Tool_State_Pending{}}),
    )

    // (a) A waiting_permission carrying a resolved decision is malformed: a resolution
    //     must not leave the state waiting.
    decided := wire.Tool_State_Waiting_Permission {
        permission_state = wire.Permission_State {
            requested_at_ms = 1,
            decision = wire.Permission_Decision_Rule{rule_id = {}, label = "rule", resolved_at_ms = 2},
        },
    }
    a, _ := replica_on_tool_state_changed(
        &r,
        wire.Tool_State_Changed_Data{session_id = _sid(), message_id = 3, part_id = 0, state = decided},
    )
    testing.expect_value(t, a.kind, Apply_Kind.Gap)

    // (b) A waiting_permission with neither options nor decision has no prompt to show.
    no_options := wire.Tool_State_Waiting_Permission {
        permission_state = wire.Permission_State{requested_at_ms = 1},
    }
    b, _ := replica_on_tool_state_changed(
        &r,
        wire.Tool_State_Changed_Data{session_id = _sid(), message_id = 3, part_id = 0, state = no_options},
    )
    testing.expect_value(t, b.kind, Apply_Kind.Gap)

    // None of the rejected transitions set a pending permission.
    _, set := replica_pending_permission(&r)
    testing.expect(t, !set, "no pending permission after rejected transitions")

    // (c) A second tool part cannot enter waiting while another part is already pending.
    options := []wire.Permission_Option{{id = "once", kind = .Allow_Once, label = "Allow"}}
    first, _ := replica_on_tool_state_changed(
        &r,
        wire.Tool_State_Changed_Data {
            session_id = _sid(),
            message_id = 3,
            part_id = 0,
            state = wire.Tool_State_Waiting_Permission {
                permission_state = wire.Permission_State{requested_at_ms = 1, options = options},
            },
        },
    )
    testing.expect_value(t, first.kind, Apply_Kind.Changed)

    _, _ = replica_on_part_added(
        &r,
        _part_added(3, wire.Tool_Part{id = 1, name = "write", arguments = "{}", state = wire.Tool_State_Pending{}}),
    )

    mismatch, _ := replica_on_tool_state_changed(
        &r,
        wire.Tool_State_Changed_Data {
            session_id = _sid(),
            message_id = 3,
            part_id = 1,
            state = wire.Tool_State_Waiting_Permission {
                permission_state = wire.Permission_State{requested_at_ms = 2, options = options},
            },
        },
    )
    testing.expect_value(t, mismatch.kind, Apply_Kind.Gap)

    // The originally pending part (0) is still the tracked one.
    pending, ok := replica_pending_permission(&r)
    testing.expect(t, ok, "original pending permission intact")
    testing.expect_value(t, pending.part_id, wire.Part_Id(0))
}

@(test)
test_tool_state_change_requires_an_existing_tool_part :: proc(t: ^testing.T) {
    r: Session_Replica
    replica_init(&r, context.allocator, _sid())
    defer replica_deinit(&r)

    _, _ = replica_on_started(&r, _started(3))
    _, _ = replica_on_part_added(&r, _text_part(3, 0, ""))

    // No part at ordinal 1.
    missing, _ := replica_on_tool_state_changed(
        &r,
        wire.Tool_State_Changed_Data {
            session_id = _sid(),
            message_id = 3,
            part_id = 1,
            state = wire.Tool_State_Pending{},
        },
    )
    testing.expect_value(t, missing.kind, Apply_Kind.Gap)

    // Ordinal 0 exists but is a text part, not a tool.
    wrong, _ := replica_on_tool_state_changed(
        &r,
        wire.Tool_State_Changed_Data {
            session_id = _sid(),
            message_id = 3,
            part_id = 0,
            state = wire.Tool_State_Pending{},
        },
    )
    testing.expect_value(t, wrong.kind, Apply_Kind.Gap)
}

@(test)
test_duplicate_start_preserves_content_and_conflicting_start_is_gap :: proc(t: ^testing.T) {
    r: Session_Replica
    replica_init(&r, context.allocator, _sid())
    defer replica_deinit(&r)

    _open_text(t, &r, 3)
    _, _ = replica_on_part_delta(&r, _delta(3, 0, 0, "partial"))

    // A duplicate start for the open draft is ignored and keeps its content.
    dup, _ := replica_on_started(&r, _started(3))
    testing.expect_value(t, dup.kind, Apply_Kind.Ignored)

    text, _ := replica_part_text(&r, 0)
    testing.expect_value(t, text, "partial")

    // A start for a different message while one is open is a gap.
    gap, _ := replica_on_started(&r, _started(4))
    testing.expect_value(t, gap.kind, Apply_Kind.Gap)

    info, _ := replica_active_info(&r)
    testing.expect_value(t, info.message_id, wire.Message_Id(3))

    text2, _ := replica_part_text(&r, 0)
    testing.expect_value(t, text2, "partial")
}

@(test)
test_discard_is_idempotent_and_a_fresh_retry_id_starts_clean :: proc(t: ^testing.T) {
    r: Session_Replica
    replica_init(&r, context.allocator, _sid())
    defer replica_deinit(&r)

    _open_text(t, &r, 3)
    _, _ = replica_on_part_delta(&r, _delta(3, 0, 0, "partial"))

    discarded := wire.Message_Discarded_Data {
        session_id = _sid(),
        message_id = 3,
        reason     = .Retry,
    }

    // First discard tombstones the draft; repeats and stale starts are ignored.
    first := replica_on_discarded(&r, discarded)
    testing.expect_value(t, first.kind, Apply_Kind.Discarded)
    testing.expect_value(t, first.message_id, wire.Message_Id(3))

    _, has := replica_active_info(&r)
    testing.expect(t, !has, "active draft dropped")

    again := replica_on_discarded(&r, discarded)
    testing.expect_value(t, again.kind, Apply_Kind.Ignored)

    stale, _ := replica_on_started(&r, _started(3))
    testing.expect_value(t, stale.kind, Apply_Kind.Ignored)

    // A fresh retry id starts clean.
    _open_text(t, &r, 4)
    res, _ := replica_on_part_delta(&r, _delta(4, 0, 0, "new"))
    testing.expect_value(t, res.kind, Apply_Kind.Changed)

    text, _ := replica_part_text(&r, 0)
    testing.expect_value(t, text, "new")
}

@(test)
test_discard_for_another_message_does_not_destroy_open_draft :: proc(t: ^testing.T) {
    r: Session_Replica
    replica_init(&r, context.allocator, _sid())
    defer replica_deinit(&r)

    _open_text(t, &r, 3)

    // Discard tombstone for an unrelated id 9 is ignored and leaves the open draft.
    res := replica_on_discarded(&r, wire.Message_Discarded_Data{session_id = _sid(), message_id = 9, reason = .Retry})
    testing.expect_value(t, res.kind, Apply_Kind.Ignored)

    info, _ := replica_active_info(&r)
    testing.expect_value(t, info.message_id, wire.Message_Id(3))
}

@(test)
test_another_session_cannot_mutate_this_replica :: proc(t: ^testing.T) {
    r: Session_Replica
    replica_init(&r, context.allocator, _sid())
    defer replica_deinit(&r)

    // A start addressed to a different session id does not open a draft.
    other_start := _started(3)
    other_start.session_id = _session_id("fedcba9876543210")
    ignored, _ := replica_on_started(&r, other_start)
    testing.expect_value(t, ignored.kind, Apply_Kind.Ignored)

    _, has := replica_active_info(&r)
    testing.expect(t, !has, "no draft opened")

    // With our own draft open, a foreign-session delta cannot touch it.
    _open_text(t, &r, 3)
    other_delta := _delta(3, 0, 0, "wrong")
    other_delta.session_id = _session_id("fedcba9876543210")
    blocked, _ := replica_on_part_delta(&r, other_delta)
    testing.expect_value(t, blocked.kind, Apply_Kind.Ignored)

    text, _ := replica_part_text(&r, 0)
    testing.expect_value(t, text, "")
}

// --- committed window / config / input test fixtures ---

@(private = "file")
_sample_user_content := [1]wire.Content_Part{wire.Content_Text{text = "user text"}}

@(private = "file")
_sample_assistant_content := [1]wire.Assistant_Part{wire.Text_Part{id = 0, text = "assistant text"}}

// User message with sample content; `input_id` 1 matches the dequeue tests.
@(private = "file")
_user_msg :: proc(id: wire.Message_Id) -> wire.Message {
    return wire.User_Message {
        id = id,
        content = _sample_user_content[:],
        input_id = 1,
        time = wire.Created_Time{created_at_ms = 100},
    }
}

// Assistant message with sample content.
@(private = "file")
_assistant_msg :: proc(id: wire.Message_Id) -> wire.Message {
    return wire.Assistant_Message {
        id = id,
        run_id = 7,
        config_rev = 1,
        agent = "main",
        content = _sample_assistant_content[:],
        finish = wire.Stop_Reason.Stop,
        time = wire.Message_Time{created_at_ms = 100, completed_at_ms = 200},
    }
}

// Compaction message; carries no `input_id`, so committing it never dequeues.
@(private = "file")
_compaction_msg :: proc(id: wire.Message_Id) -> wire.Message {
    return wire.Compaction_Message {
        id = id,
        run_id = 7,
        reason = .Manual,
        summary = "summary",
        first_kept_id = nil,
        tokens_before = 10,
        tokens_after = 5,
        time = wire.Created_Time{created_at_ms = 100},
    }
}

// Build a run config.
@(private = "file")
_run_cfg :: proc(rev: wire.Config_Rev, model: string) -> wire.Run_Config {
    return {config_rev = rev, model = model, reasoning = "high"}
}

// Build a `message.committed` payload.
@(private = "file")
_committed :: proc(seq: wire.Seq, message: wire.Message) -> wire.Message_Committed_Data {
    return {session_id = _sid(), seq = seq, message = message}
}

// Build a queued input frame.
@(private = "file")
_queued :: proc(input_id: wire.Input_Id) -> wire.Input_Queued_Data {
    return {
        session_id = _sid(),
        input = wire.Queued_Input{input_id = input_id, content = _sample_user_content[:], queued_at_ms = 10},
    }
}

@(test)
test_committed_window_retains_only_newest_page :: proc(t: ^testing.T) {
    r: Session_Replica
    replica_init(&r, context.allocator, _sid())
    defer replica_deinit(&r)

    for id in 1 ..= wire.Message_Id(MAX_RETAINED_MESSAGES + 2) {
        _, _ = replica_on_committed(&r, _committed(wire.Seq(id), _user_msg(id)))
    }

    testing.expect_value(t, len(r.messages), MAX_RETAINED_MESSAGES)
    testing.expect(t, r.has_more, "older history exists")

    _, has_first := replica_committed_by_id(&r, 1)
    testing.expect(t, !has_first, "oldest evicted")

    _, has_last := replica_committed_by_id(&r, wire.Message_Id(MAX_RETAINED_MESSAGES + 2))
    testing.expect(t, has_last, "newest retained")
}

@(test)
test_assistant_commit_replaces_partial_draft_and_seals :: proc(t: ^testing.T) {
    r: Session_Replica
    replica_init(&r, context.allocator, _sid())
    defer replica_deinit(&r)

    _open_text(t, &r, 5)
    _, _ = replica_on_part_delta(&r, _delta(5, 0, 0, "partial"))

    res, _ := replica_on_committed(&r, _committed(1, _assistant_msg(5)))
    testing.expect_value(t, res.kind, Apply_Kind.Committed)
    testing.expect_value(t, res.message_id, wire.Message_Id(5))

    _, has := replica_active_info(&r)
    testing.expect(t, !has, "draft destroyed by its commit")
    testing.expect_value(t, len(r.messages), 1)

    msg, ok := replica_committed_by_id(&r, 5)
    testing.expect(t, ok, "committed present")
    assistant, is_assistant := msg.(wire.Assistant_Message)
    testing.expect(t, is_assistant, "assistant variant")
    text, _ := assistant.content[0].(wire.Text_Part)
    testing.expect_value(t, text.text, "assistant text")

    // Sealed: later live events for id 5 are ignored.
    stale, _ := replica_on_started(&r, _started(5))
    testing.expect_value(t, stale.kind, Apply_Kind.Ignored)
}

@(test)
test_unrelated_commit_leaves_open_draft_intact :: proc(t: ^testing.T) {
    r: Session_Replica
    replica_init(&r, context.allocator, _sid())
    defer replica_deinit(&r)

    _open_text(t, &r, 5)
    _, _ = replica_on_part_delta(&r, _delta(5, 0, 0, "partial"))

    res, _ := replica_on_committed(&r, _committed(1, _user_msg(3)))
    testing.expect_value(t, res.kind, Apply_Kind.Committed)
    testing.expect_value(t, res.message_id, wire.Message_Id(3))

    info, _ := replica_active_info(&r)
    testing.expect_value(t, info.message_id, wire.Message_Id(5))
    text, _ := replica_part_text(&r, 0)
    testing.expect_value(t, text, "partial")
}

@(test)
test_duplicate_commit_upserts_without_duplicate_row :: proc(t: ^testing.T) {
    r: Session_Replica
    replica_init(&r, context.allocator, _sid())
    defer replica_deinit(&r)

    _, _ = replica_on_committed(&r, _committed(1, _assistant_msg(3)))
    _, _ = replica_on_committed(&r, _committed(2, _assistant_msg(3)))

    testing.expect_value(t, len(r.messages), 1)
    testing.expect_value(t, wire.message_id(r.messages[0].message), wire.Message_Id(3))
}

@(test)
test_committed_ids_with_gaps_stay_ordered :: proc(t: ^testing.T) {
    r: Session_Replica
    replica_init(&r, context.allocator, _sid())
    defer replica_deinit(&r)

    _, _ = replica_on_committed(&r, _committed(1, _assistant_msg(3)))
    _, _ = replica_on_committed(&r, _committed(2, _assistant_msg(7)))
    _, _ = replica_on_committed(&r, _committed(3, _assistant_msg(5))) // arrives out of order

    testing.expect_value(t, len(r.messages), 3)
    testing.expect_value(t, wire.message_id(r.messages[0].message), wire.Message_Id(3))
    testing.expect_value(t, wire.message_id(r.messages[1].message), wire.Message_Id(5))
    testing.expect_value(t, wire.message_id(r.messages[2].message), wire.Message_Id(7))

    _, has := replica_committed_by_id(&r, 4)
    testing.expect(t, !has, "gap id absent")
}

@(test)
test_truncation_drops_suffix_and_is_idempotent :: proc(t: ^testing.T) {
    r: Session_Replica
    replica_init(&r, context.allocator, _sid())
    defer replica_deinit(&r)

    _, _ = replica_on_committed(&r, _committed(1, _assistant_msg(3)))
    _, _ = replica_on_committed(&r, _committed(2, _assistant_msg(5)))
    _, _ = replica_on_committed(&r, _committed(3, _assistant_msg(7)))

    cut := wire.Transcript_Truncated_Data {
        session_id       = _sid(),
        seq              = 9,
        first_removed_id = 5,
    }
    res := replica_on_truncated(&r, cut)
    testing.expect_value(t, res.kind, Apply_Kind.Changed)
    testing.expect_value(t, len(r.messages), 1)
    testing.expect_value(t, wire.message_id(r.messages[0].message), wire.Message_Id(3))

    // Applying the same cut again is a no-op.
    again := replica_on_truncated(&r, cut)
    testing.expect_value(t, again.kind, Apply_Kind.Ignored)
    testing.expect_value(t, len(r.messages), 1)
}

@(test)
test_config_revisions_immutable_and_unbounded :: proc(t: ^testing.T) {
    r: Session_Replica
    replica_init(&r, context.allocator, _sid())
    defer replica_deinit(&r)

    for rev in 1 ..= wire.Config_Rev(70) {
        res, err := replica_on_config_changed(
            &r,
            wire.Config_Changed_Data{session_id = _sid(), seq = wire.Seq(rev), config = _run_cfg(rev, "model")},
        )
        testing.expect_value(t, err, Replica_Error.None)
        testing.expect_value(t, res.kind, Apply_Kind.Changed)
    }

    testing.expect_value(t, len(r.configs), 70)

    _, has1 := replica_config(&r, 1)
    testing.expect(t, has1, "config 1 present")
    _, has70 := replica_config(&r, 70)
    testing.expect(t, has70, "config 70 present")

    // Re-announcing an identical revision is ignored.
    dup, derr := replica_on_config_changed(
        &r,
        wire.Config_Changed_Data{session_id = _sid(), seq = 71, config = _run_cfg(1, "model")},
    )
    testing.expect_value(t, derr, Replica_Error.None)
    testing.expect_value(t, dup.kind, Apply_Kind.Ignored)

    // A revision that reappears with different content is a conflict.
    _, cerr := replica_on_config_changed(
        &r,
        wire.Config_Changed_Data{session_id = _sid(), seq = 72, config = _run_cfg(1, "different")},
    )
    testing.expect_value(t, cerr, Replica_Error.Config_Revision_Conflict)

    cfg, _ := replica_config(&r, 1)
    testing.expect_value(t, cfg.model, "model")
}

@(test)
test_input_queued_and_canceled_fold :: proc(t: ^testing.T) {
    r: Session_Replica
    replica_init(&r, context.allocator, _sid())
    defer replica_deinit(&r)

    res, _ := replica_on_input_queued(&r, _queued(4))
    testing.expect_value(t, res.kind, Apply_Kind.Changed)
    testing.expect_value(t, len(r.queued), 1)

    // Duplicate id is ignored.
    dup, _ := replica_on_input_queued(&r, _queued(4))
    testing.expect_value(t, dup.kind, Apply_Kind.Ignored)

    cancel := replica_on_input_canceled(&r, wire.Input_Canceled_Data{session_id = _sid(), input_id = 4})
    testing.expect_value(t, cancel.kind, Apply_Kind.Changed)
    testing.expect_value(t, len(r.queued), 0)

    // Canceling an unknown id is a no-op.
    miss := replica_on_input_canceled(&r, wire.Input_Canceled_Data{session_id = _sid(), input_id = 4})
    testing.expect_value(t, miss.kind, Apply_Kind.Ignored)
}

@(test)
test_committed_user_message_dequeues_input :: proc(t: ^testing.T) {
    r: Session_Replica
    replica_init(&r, context.allocator, _sid())
    defer replica_deinit(&r)

    _, _ = replica_on_input_queued(&r, _queued(1))
    _, _ = replica_on_input_queued(&r, _queued(4))

    // userMsg(3) carries input_id 1, so only that queued entry is dequeued.
    _, _ = replica_on_committed(&r, _committed(1, _user_msg(3)))

    testing.expect_value(t, len(r.queued), 1)
    testing.expect_value(t, r.queued[0].input.input_id, wire.Input_Id(4))
}

@(test)
test_assistant_and_compaction_commits_do_not_dequeue :: proc(t: ^testing.T) {
    r: Session_Replica
    replica_init(&r, context.allocator, _sid())
    defer replica_deinit(&r)

    _, _ = replica_on_input_queued(&r, _queued(1))

    // An assistant commit carries no input_id and leaves the queue intact.
    _, _ = replica_on_committed(&r, _committed(1, _assistant_msg(3)))
    testing.expect_value(t, len(r.queued), 1)

    // A compaction commit likewise never dequeues.
    _, _ = replica_on_committed(&r, _committed(2, _compaction_msg(4)))
    testing.expect_value(t, len(r.queued), 1)
    testing.expect_value(t, r.queued[0].input.input_id, wire.Input_Id(1))
}

@(test)
test_commit_clears_pending_permission :: proc(t: ^testing.T) {
    r: Session_Replica
    replica_init(&r, context.allocator, _sid())
    defer replica_deinit(&r)

    _, _ = replica_on_started(&r, _started(3))
    _, _ = replica_on_part_added(
        &r,
        _part_added(3, wire.Tool_Part{id = 0, name = "read", arguments = "{}", state = wire.Tool_State_Pending{}}),
    )

    options := []wire.Permission_Option{{id = "once", kind = .Allow_Once, label = "Allow"}}
    _, _ = replica_on_tool_state_changed(
        &r,
        wire.Tool_State_Changed_Data {
            session_id = _sid(),
            message_id = 3,
            part_id = 0,
            state = wire.Tool_State_Waiting_Permission {
                permission_state = wire.Permission_State{requested_at_ms = 1, options = options},
            },
        },
    )

    _, set := replica_pending_permission(&r)
    testing.expect(t, set, "pending permission set")

    // Committing the message the permission anchored clears it.
    _, _ = replica_on_committed(&r, _committed(1, _assistant_msg(3)))
    _, still := replica_pending_permission(&r)
    testing.expect(t, !still, "pending permission cleared by commit")
}

@(test)
test_sealed_live_events_and_stale_starts_ignored :: proc(t: ^testing.T) {
    r: Session_Replica
    replica_init(&r, context.allocator, _sid())
    defer replica_deinit(&r)

    _open_text(t, &r, 3)
    _, _ = replica_on_committed(&r, _committed(1, _assistant_msg(3)))

    // Committing drops the active draft and finalizes the id.
    _, has := replica_active_info(&r)
    testing.expect(t, !has, "draft dropped on commit")

    // Every later event for that finalized id is ignored.
    s, _ := replica_on_started(&r, _started(3))
    testing.expect_value(t, s.kind, Apply_Kind.Ignored)

    d, _ := replica_on_part_delta(&r, _delta(3, 0, 0, "late"))
    testing.expect_value(t, d.kind, Apply_Kind.Ignored)

    ts, _ := replica_on_tool_state_changed(
        &r,
        wire.Tool_State_Changed_Data {
            session_id = _sid(),
            message_id = 3,
            part_id = 0,
            state = wire.Tool_State_Pending{},
        },
    )
    testing.expect_value(t, ts.kind, Apply_Kind.Ignored)
}

@(test)
test_clear_pending_compaction :: proc(t: ^testing.T) {
    r: Session_Replica
    replica_init(&r, context.allocator, _sid())
    defer replica_deinit(&r)

    // A non-matching run id leaves the slot untouched.
    r.pending_compaction = wire.Run_Id(42)
    other := replica_clear_pending_compaction(&r, 41)
    testing.expect_value(t, other.kind, Apply_Kind.Ignored)
    pc, still := r.pending_compaction.?
    testing.expect(t, still, "unrelated run keeps the slot")
    testing.expect_value(t, pc, wire.Run_Id(42))

    // The matching run id clears it.
    match := replica_clear_pending_compaction(&r, 42)
    testing.expect_value(t, match.kind, Apply_Kind.Changed)
    testing.expect(t, r.pending_compaction == nil, "matching run clears the slot")
}

// --- sequence gating / dispatch / buffering test fixtures ---

// Wrap a payload in a broadcast frame.
@(private = "file")
_bc :: proc(name: wire.Broadcast_Name, data: wire.Broadcast_Data) -> wire.Broadcast {
    return wire.broadcast_build(name, data)
}

// Wrap a `message.committed` payload in a broadcast.
@(private = "file")
_committed_bc :: proc(seq: wire.Seq, message: wire.Message) -> wire.Broadcast {
    return _bc(.Message_Committed, _committed(seq, message))
}

// Build a `run.started` broadcast.
@(private = "file")
_run_started_bc :: proc(seq: wire.Seq, run_id: wire.Run_Id, kind: wire.Run_Kind) -> wire.Broadcast {
    return _bc(
        .Run_Started,
        wire.Run_Started_Data {
            session_id = _sid(),
            seq = seq,
            run_id = run_id,
            kind = kind,
            config_rev = 1,
            started_at_ms = 5,
        },
    )
}

// Build a `run.done` broadcast with the given terminal outcome.
@(private = "file")
_run_done_bc :: proc(seq: wire.Seq, run_id: wire.Run_Id, outcome: wire.Run_Outcome) -> wire.Broadcast {
    return _bc(
        .Run_Done,
        wire.Run_Done_Data {
            session_id = _sid(),
            seq = seq,
            run_id = run_id,
            kind = .Turn,
            timing = wire.Run_Canceled_Timing{started_at_ms = 1, ended_at_ms = 2},
            outcome = outcome,
        },
    )
}

// Build a `session.activity` broadcast advertising `pending`.
@(private = "file")
_activity_bc :: proc(pending: Maybe(wire.Run_Id)) -> wire.Broadcast {
    return _bc(
        .Session_Activity_Changed,
        wire.Session_Activity_Changed_Data {
            session_id = _sid(),
            activity = wire.Session_Activity {
                state = wire.Activity_State_Idle{},
                queued = 0,
                context_tokens = 0,
                pending_compaction = pending,
            },
        },
    )
}

@(test)
test_durable_events_gate_on_sequence :: proc(t: ^testing.T) {
    r: Session_Replica
    replica_init(&r, context.allocator, _sid())
    defer replica_deinit(&r)
    r.base_seq = 5

    // Stale (<= base_seq) is ignored.
    stale, _ := replica_apply_broadcast(&r, _committed_bc(5, _assistant_msg(1)))
    testing.expect_value(t, stale.kind, Apply_Kind.Ignored)
    testing.expect_value(t, len(r.messages), 0)

    // Contiguous (base_seq + 1) applies and advances.
    next, _ := replica_apply_broadcast(&r, _committed_bc(6, _assistant_msg(1)))
    testing.expect_value(t, next.kind, Apply_Kind.Committed)
    testing.expect_value(t, r.base_seq, wire.Seq(6))

    // A hole (> base_seq + 1) starts a resync; further events buffer.
    gap, _ := replica_apply_broadcast(&r, _committed_bc(8, _assistant_msg(2)))
    testing.expect_value(t, gap.kind, Apply_Kind.Gap)
    testing.expect(t, r.resync != nil, "resyncing after gap")

    buffered, _ := replica_apply_broadcast(&r, _committed_bc(9, _assistant_msg(3)))
    testing.expect_value(t, buffered.kind, Apply_Kind.Buffered)
}

@(test)
test_live_broadcasts_route_to_their_folders :: proc(t: ^testing.T) {
    r: Session_Replica
    replica_init(&r, context.allocator, _sid())
    defer replica_deinit(&r)

    s, _ := replica_apply_broadcast(&r, _bc(.Message_Started, _started(3)))
    testing.expect_value(t, s.kind, Apply_Kind.Changed)
    info, has := replica_active_info(&r)
    testing.expect(t, has, "draft opened via dispatch")
    testing.expect_value(t, info.message_id, wire.Message_Id(3))

    p, _ := replica_apply_broadcast(&r, _bc(.Message_Part_Added, _text_part(3, 0, "hi")))
    testing.expect_value(t, p.kind, Apply_Kind.Changed)

    d, _ := replica_apply_broadcast(&r, _bc(.Message_Part_Delta, _delta(3, 0, 2, "!")))
    testing.expect_value(t, d.kind, Apply_Kind.Changed)
    text, _ := replica_part_text(&r, 0)
    testing.expect_value(t, text, "hi!")

    disc, _ := replica_apply_broadcast(
        &r,
        _bc(.Message_Discarded, wire.Message_Discarded_Data{session_id = _sid(), message_id = 3, reason = .Retry}),
    )
    testing.expect_value(t, disc.kind, Apply_Kind.Discarded)
}

@(test)
test_begin_resync_buffers_subsequent_events_and_coalesces :: proc(t: ^testing.T) {
    r: Session_Replica
    replica_init(&r, context.allocator, _sid())
    defer replica_deinit(&r)

    testing.expect_value(t, replica_begin_resync(&r), Replica_Error.None)
    b1, _ := replica_apply_broadcast(&r, _bc(.Message_Started, _started(3)))
    testing.expect_value(t, b1.kind, Apply_Kind.Buffered)

    // A second begin does not open a new buffer.
    testing.expect_value(t, replica_begin_resync(&r), Replica_Error.None)
    b2, _ := replica_apply_broadcast(&r, _bc(.Message_Part_Delta, _delta(3, 0, 0, "x")))
    testing.expect_value(t, b2.kind, Apply_Kind.Buffered)
    testing.expect_value(t, len(r.resync.events), 2)
}

@(test)
test_a_live_gap_starts_a_resync :: proc(t: ^testing.T) {
    r: Session_Replica
    replica_init(&r, context.allocator, _sid())
    defer replica_deinit(&r)

    // A delta for an unseen message is a gap and enters resyncing.
    gap, _ := replica_apply_broadcast(&r, _bc(.Message_Part_Delta, _delta(3, 0, 0, "x")))
    testing.expect_value(t, gap.kind, Apply_Kind.Gap)
    testing.expect(t, r.resync != nil, "resyncing after live gap")

    // Now resyncing: a following live event is buffered, not applied.
    buf, _ := replica_apply_broadcast(&r, _bc(.Message_Started, _started(3)))
    testing.expect_value(t, buf.kind, Apply_Kind.Buffered)
    _, has := replica_active_info(&r)
    testing.expect(t, !has, "no draft materialized while resyncing")
}

@(test)
test_foreign_and_non_replica_broadcasts_are_inert :: proc(t: ^testing.T) {
    r: Session_Replica
    replica_init(&r, context.allocator, _sid())
    defer replica_deinit(&r)
    r.base_seq = 3

    // A committed for a different session neither folds nor gates the sequence.
    other := _committed(99, _assistant_msg(5))
    other.session_id = _session_id("fedcba9876543210")
    f, _ := replica_apply_broadcast(&r, _bc(.Message_Committed, other))
    testing.expect_value(t, f.kind, Apply_Kind.Ignored)
    testing.expect_value(t, r.base_seq, wire.Seq(3))

    // A same-session but other-domain broadcast is ignored before any gating.
    rem, _ := replica_apply_broadcast(
        &r,
        _bc(.Session_Removed, wire.Session_Removed_Data{revision = 1, session_id = _sid()}),
    )
    testing.expect_value(t, rem.kind, Apply_Kind.Ignored)
    testing.expect_value(t, r.base_seq, wire.Seq(3))
}

@(test)
test_run_started_only_advances_the_sequence :: proc(t: ^testing.T) {
    r: Session_Replica
    replica_init(&r, context.allocator, _sid())
    defer replica_deinit(&r)
    r.base_seq = 3

    res, _ := replica_apply_broadcast(&r, _run_started_bc(4, 1, .Turn))
    testing.expect_value(t, res.kind, Apply_Kind.Ignored)
    testing.expect_value(t, r.base_seq, wire.Seq(4))
}

@(test)
test_session_activity_replaces_pending_compaction :: proc(t: ^testing.T) {
    r: Session_Replica
    replica_init(&r, context.allocator, _sid())
    defer replica_deinit(&r)

    res, _ := replica_apply_broadcast(&r, _activity_bc(wire.Run_Id(42)))
    testing.expect_value(t, res.kind, Apply_Kind.Changed)
    pc, ok := r.pending_compaction.?
    testing.expect(t, ok, "pending compaction set")
    testing.expect_value(t, pc, wire.Run_Id(42))

    // The same value again is a no-op.
    again, _ := replica_apply_broadcast(&r, _activity_bc(wire.Run_Id(42)))
    testing.expect_value(t, again.kind, Apply_Kind.Ignored)
}

@(test)
test_unrelated_turn_terminal_preserves_pending_compaction :: proc(t: ^testing.T) {
    r: Session_Replica
    replica_init(&r, context.allocator, _sid())
    defer replica_deinit(&r)
    r.base_seq = 3
    r.pending_compaction = wire.Run_Id(42)

    // A terminal for an unrelated run (id 41) clears nothing but advances the sequence.
    res, _ := replica_apply_broadcast(
        &r,
        _run_done_bc(4, 41, wire.Run_Outcome_Failed{code = .Provider, message = "boom"}),
    )
    testing.expect_value(t, res.kind, Apply_Kind.Ignored)
    pc, ok := r.pending_compaction.?
    testing.expect(t, ok, "pending compaction preserved")
    testing.expect_value(t, pc, wire.Run_Id(42))
    testing.expect_value(t, r.base_seq, wire.Seq(4))
}

@(test)
test_matching_run_events_clear_pending_compaction :: proc(t: ^testing.T) {
    r: Session_Replica
    replica_init(&r, context.allocator, _sid())
    defer replica_deinit(&r)
    r.base_seq = 3
    r.pending_compaction = wire.Run_Id(42)

    // run.started with a matching compaction id clears it.
    a, _ := replica_apply_broadcast(&r, _run_started_bc(4, 42, .Compaction))
    testing.expect_value(t, a.kind, Apply_Kind.Changed)
    testing.expect(t, r.pending_compaction == nil, "cleared by compaction start")

    // Re-arm with a fresh id (run ids are never reused); run.done clears it.
    _, _ = replica_apply_broadcast(&r, _activity_bc(wire.Run_Id(43)))
    b, _ := replica_apply_broadcast(&r, _run_done_bc(5, 43, wire.Run_Outcome_Compacted{message_id = 1}))
    testing.expect_value(t, b.kind, Apply_Kind.Changed)
    testing.expect(t, r.pending_compaction == nil, "cleared by run.done")

    // Re-arm with another fresh id; a canceled terminal clears it.
    _, _ = replica_apply_broadcast(&r, _activity_bc(wire.Run_Id(44)))
    c, _ := replica_apply_broadcast(&r, _run_done_bc(6, 44, wire.Run_Outcome_Canceled{}))
    testing.expect_value(t, c.kind, Apply_Kind.Changed)
    testing.expect(t, r.pending_compaction == nil, "cleared by canceled terminal")
}

@(test)
test_resync_event_count_overflow_resets_buffer :: proc(t: ^testing.T) {
    r: Session_Replica
    replica_init(&r, context.allocator, _sid())
    defer replica_deinit(&r)

    testing.expect_value(t, replica_begin_resync(&r), Replica_Error.None)
    for i in 0 ..< u64(MAX_BUFFERED_EVENTS + 5) {
        _, _ = replica_apply_broadcast(
            &r,
            _bc(.Input_Canceled, wire.Input_Canceled_Data{session_id = _sid(), input_id = wire.Input_Id(i)}),
        )
    }

    testing.expect(t, r.resync.overflow, "crossing the event cap sets overflow")
    testing.expect_value(t, len(r.resync.events), 0)
}

@(test)
test_resync_byte_overflow_discards_the_entire_prefix :: proc(t: ^testing.T) {
    r: Session_Replica
    replica_init(&r, context.allocator, _sid())
    defer replica_deinit(&r)

    testing.expect_value(t, replica_begin_resync(&r), Replica_Error.None)
    _, _ = replica_apply_broadcast(&r, _bc(.Message_Started, _started(3)))

    big := make([]u8, MAX_BUFFERED_BYTES + 1, context.allocator)
    defer delete(big, context.allocator)
    for &c in big {
        c = 'x'
    }

    _, _ = replica_apply_broadcast(&r, _bc(.Message_Part_Delta, _delta(3, 0, 0, string(big))))
    testing.expect(t, r.resync.overflow, "an oversized event trips the byte cap")
    testing.expect_value(t, len(r.resync.events), 0)

    // A following event buffers cheaply into the fresh empty overflow buffer.
    after, _ := replica_apply_broadcast(&r, _bc(.Message_Started, _started(4)))
    testing.expect_value(t, after.kind, Apply_Kind.Buffered)
    testing.expect_value(t, len(r.resync.events), 0)
}

@(test)
test_deinit_while_resyncing_frees_the_buffer :: proc(t: ^testing.T) {
    r: Session_Replica
    replica_init(&r, context.allocator, _sid())
    defer replica_deinit(&r)

    testing.expect_value(t, replica_begin_resync(&r), Replica_Error.None)
    _, _ = replica_apply_broadcast(&r, _bc(.Message_Started, _started(3)))
    // The deferred deinit must free the buffer arena; the tracking allocator catches a leak.
}

// --- resync install / replay test fixtures ---

@(private = "file")
_sample_configs := [1]wire.Run_Config{{config_rev = 1, model = "model", reasoning = "high"}}

@(private = "file")
_sample_active_content := [3]wire.Assistant_Part {
    wire.Text_Part{id = 0, text = "abc"},
    wire.Reasoning_Part{id = 1, text = "why"},
    wire.Tool_Part{id = 2, name = "read", arguments = "{}", state = wire.Tool_State_Pending{}},
}

// Assistant message under an explicit config revision (for referential-integrity tests).
@(private = "file")
_assistant_msg_cfg :: proc(id: wire.Message_Id, config_rev: wire.Config_Rev) -> wire.Message {
    return wire.Assistant_Message {
        id = id,
        run_id = 7,
        config_rev = config_rev,
        agent = "main",
        content = _sample_assistant_content[:],
        finish = wire.Stop_Reason.Stop,
        time = wire.Message_Time{created_at_ms = 100, completed_at_ms = 200},
    }
}

// A fully wire-valid session-index row for the shared test session, so
// `resync_result_validate` accepts the snapshots built on top of it.
@(private = "file")
_valid_session :: proc() -> wire.Session {
    return wire.Session {
        id = _sid(),
        workspace_id = wire.Workspace_Id(([16]u8)(_session_id("fedcba9876543210"))),
        origin = wire.Session_Origin_Child{parent_id = _session_id("abcdef0123456789")},
    }
}

// Empty resync snapshot at `base_seq`, carrying one config (rev 1).
@(private = "file")
_empty_resync :: proc(base_seq: wire.Seq) -> wire.Resync_Result {
    return wire.Resync_Result {
        item = wire.Session_List_Item {
            session = _valid_session(),
            activity = wire.Session_Activity{state = wire.Activity_State_Idle{}},
        },
        base_seq = base_seq,
        highest_finalized_message_id = nil,
        messages = nil,
        has_more = false,
        configs = _sample_configs[:],
        active = nil,
        queued = nil,
    }
}

// Snapshot carrying `msgs` finalized up to `highest`.
@(private = "file")
_resync_msgs :: proc(base_seq: wire.Seq, msgs: []wire.Message, highest: wire.Message_Id) -> wire.Resync_Result {
    r := _empty_resync(base_seq)
    r.messages = msgs
    r.highest_finalized_message_id = highest
    return r
}

// In-flight draft `id` under run 7 / config 1 with the given content.
@(private = "file")
_active_draft :: proc(id: wire.Message_Id, content: []wire.Assistant_Part) -> wire.Active_Draft {
    return wire.Active_Draft {
        message = wire.Assistant_Message {
            id = id,
            run_id = 7,
            config_rev = 1,
            agent = "main",
            content = content,
            time = wire.Message_Time{created_at_ms = 1},
        },
    }
}

// Running-activity projection consistent with `_active_draft` (run 7 / config rev 1). The
// wire validator requires an activity that matches the draft whenever a snapshot carries
// one, so active-draft snapshots must set this in place of the default idle activity.
@(private = "file")
_running_activity :: proc() -> wire.Session_Activity {
    return wire.Session_Activity {
        state = wire.Activity_State_Running{run_id = 7, config = _sample_configs[0], started_at_ms = 1},
    }
}

@(test)
test_resync_installs_empty_snapshot :: proc(t: ^testing.T) {
    r: Session_Replica
    replica_init(&r, context.allocator, _sid())
    defer replica_deinit(&r)

    out, err := replica_install_snapshot(&r, _empty_resync(42))
    testing.expect_value(t, err, Replica_Error.None)
    testing.expect_value(t, out, Install_Outcome.Live)
    testing.expect_value(t, len(r.messages), 0)
    _, has := replica_active_info(&r)
    testing.expect(t, !has, "no active draft")
    testing.expect_value(t, r.base_seq, wire.Seq(42))
}

@(test)
test_resync_installs_mixed_committed_window :: proc(t: ^testing.T) {
    r: Session_Replica
    replica_init(&r, context.allocator, _sid())
    defer replica_deinit(&r)

    msgs := []wire.Message{_user_msg(1), _assistant_msg(2), _compaction_msg(3)}
    snap := _resync_msgs(50, msgs, 3)
    snap.has_more = true
    out, err := replica_install_snapshot(&r, snap)
    testing.expect_value(t, err, Replica_Error.None)
    testing.expect_value(t, out, Install_Outcome.Live)

    testing.expect_value(t, len(r.messages), 3)
    testing.expect(t, r.has_more, "older messages exist")
    testing.expect_value(t, wire.message_id(r.messages[0].message), wire.Message_Id(1))
    testing.expect_value(t, wire.message_id(r.messages[2].message), wire.Message_Id(3))

    msg, ok := replica_committed_by_id(&r, 2)
    testing.expect(t, ok, "id 2 present")
    assistant, is_a := msg.(wire.Assistant_Message)
    testing.expect(t, is_a, "assistant")
    text, _ := assistant.content[0].(wire.Text_Part)
    testing.expect_value(t, text.text, "assistant text")
}

@(test)
test_resync_installs_active_draft_and_next_delta_applies :: proc(t: ^testing.T) {
    r: Session_Replica
    replica_init(&r, context.allocator, _sid())
    defer replica_deinit(&r)

    snap := _empty_resync(10)
    snap.active = _active_draft(5, _sample_active_content[:])
    snap.item.activity = _running_activity()
    out, err := replica_install_snapshot(&r, snap)
    testing.expect_value(t, err, Replica_Error.None)
    testing.expect_value(t, out, Install_Outcome.Live)

    info, has := replica_active_info(&r)
    testing.expect(t, has, "active draft installed")
    testing.expect_value(t, info.message_id, wire.Message_Id(5))
    testing.expect_value(t, info.part_count, 3)
    text0, _ := replica_part_text(&r, 0)
    testing.expect_value(t, text0, "abc")
    kind1, _ := replica_part_kind(&r, 1)
    testing.expect_value(t, kind1, Part_Kind.Reasoning)
    testing.expect(t, replica_tool_part(&r, 2) != nil, "tool part 2 present")

    // The seeded buffer length is the expected offset: overlap ignored, append at 3.
    dup, _ := replica_on_part_delta(&r, _delta(5, 0, 1, "x"))
    testing.expect_value(t, dup.kind, Apply_Kind.Ignored)
    app, _ := replica_on_part_delta(&r, _delta(5, 0, 3, "d"))
    testing.expect_value(t, app.kind, Apply_Kind.Changed)
    text, _ := replica_part_text(&r, 0)
    testing.expect_value(t, text, "abcd")
}

@(test)
test_installed_snapshot_outlives_its_source_arena :: proc(t: ^testing.T) {
    r: Session_Replica
    replica_init(&r, context.allocator, _sid())
    defer replica_deinit(&r)

    src: mem.Dynamic_Arena
    mem.dynamic_arena_init(&src, context.allocator, context.allocator)
    a := mem.dynamic_arena_allocator(&src)

    acontent := make([]wire.Assistant_Part, 1, a)
    acontent[0] = wire.Text_Part {
        id   = 0,
        text = strings.clone("committed body", a),
    }
    msgs := make([]wire.Message, 1, a)
    msgs[0] = wire.Assistant_Message {
        id = 2,
        run_id = 7,
        config_rev = 1,
        agent = strings.clone("worker", a),
        content = acontent,
        finish = wire.Stop_Reason.Stop,
        time = wire.Message_Time{created_at_ms = 1, completed_at_ms = 2},
    }

    cfgs := make([]wire.Run_Config, 1, a)
    cfgs[0] = wire.Run_Config {
        config_rev = 1,
        model      = strings.clone("gpt", a),
        reasoning  = strings.clone("high", a),
    }

    qcontent := make([]wire.Content_Part, 1, a)
    qcontent[0] = wire.Content_Text {
        text = strings.clone("queued body", a),
    }
    q := make([]wire.Queued_Input, 1, a)
    q[0] = wire.Queued_Input {
        input_id     = 9,
        content      = qcontent,
        queued_at_ms = 50,
    }

    opts := make([]wire.Permission_Option, 1, a)
    opts[0] = wire.Permission_Option {
        id    = strings.clone("always", a),
        kind  = .Allow_Always,
        label = strings.clone("Always", a),
    }

    dcontent := make([]wire.Assistant_Part, 1, a)
    dcontent[0] = wire.Tool_Part {
        id = 0,
        name = strings.clone("read", a),
        arguments = strings.clone("{}", a),
        state = wire.Tool_State_Waiting_Permission {
            permission_state = wire.Permission_State{requested_at_ms = 3, options = opts},
        },
    }

    snap := _empty_resync(10)
    snap.messages = msgs
    snap.highest_finalized_message_id = 2
    snap.configs = cfgs
    snap.queued = q
    snap.active = wire.Active_Draft {
        message = wire.Assistant_Message {
            id = 5,
            run_id = 8,
            config_rev = 1,
            agent = strings.clone("drafter", a),
            content = dcontent,
            time = wire.Message_Time{created_at_ms = 9},
        },
    }
    // The waiting-permission draft demands a matching waiting-permission activity.
    snap.item.activity = wire.Session_Activity {
        state = wire.Activity_State_Waiting_Permission {
            run_id = 8,
            config = cfgs[0],
            message_id = 5,
            part_id = 0,
            tool_name = "read",
            requested_at_ms = 3,
        },
        queued = 1,
    }

    out, err := replica_install_snapshot(&r, snap)
    testing.expect_value(t, err, Replica_Error.None)
    testing.expect_value(t, out, Install_Outcome.Live)

    // Drop the source: everything read below must come from the replica's own arenas.
    mem.dynamic_arena_destroy(&src)

    msg, _ := replica_committed_by_id(&r, 2)
    assistant, is_a := msg.(wire.Assistant_Message)
    testing.expect(t, is_a, "committed assistant")
    testing.expect_value(t, assistant.agent, "worker")
    ctext, _ := assistant.content[0].(wire.Text_Part)
    testing.expect_value(t, ctext.text, "committed body")

    cfg, _ := replica_config(&r, 1)
    testing.expect_value(t, cfg.model, "gpt")

    testing.expect_value(t, r.queued[0].input.content[0].(wire.Content_Text).text, "queued body")

    pending, has_pending := replica_pending_permission(&r)
    testing.expect(t, has_pending, "pending permission derived from installed draft")
    testing.expect_value(t, pending.tool_name, "read")
    testing.expect_value(t, pending.options[0].id, "always")

    info, _ := replica_active_info(&r)
    testing.expect_value(t, info.agent, "drafter")
    testing.expect_value(t, replica_tool_part(&r, 0).name, "read")
}

@(test)
test_resync_rejects_response_above_window :: proc(t: ^testing.T) {
    r: Session_Replica
    replica_init(&r, context.allocator, _sid())
    defer replica_deinit(&r)

    msgs := make([]wire.Message, MAX_RETAINED_MESSAGES + 1, context.allocator)
    defer delete(msgs, context.allocator)
    for i in 0 ..< len(msgs) {
        msgs[i] = _user_msg(wire.Message_Id(i + 1))
    }

    _, err := replica_install_snapshot(&r, _resync_msgs(1, msgs, wire.Message_Id(len(msgs))))
    testing.expect_value(t, err, Replica_Error.Malformed_Snapshot)
}

@(test)
test_resync_rejects_session_mismatch :: proc(t: ^testing.T) {
    r: Session_Replica
    replica_init(&r, context.allocator, _sid())
    defer replica_deinit(&r)

    snap := _empty_resync(0)
    snap.item.session.id = _session_id("fedcba9876543210")
    _, err := replica_install_snapshot(&r, snap)
    testing.expect_value(t, err, Replica_Error.Session_Mismatch)
}

@(test)
test_resync_rejects_unordered_ids :: proc(t: ^testing.T) {
    r: Session_Replica
    replica_init(&r, context.allocator, _sid())
    defer replica_deinit(&r)

    msgs := []wire.Message{_assistant_msg(5), _assistant_msg(3)}
    _, err := replica_install_snapshot(&r, _resync_msgs(0, msgs, 5))
    testing.expect_value(t, err, Replica_Error.Malformed_Snapshot)
}

@(test)
test_resync_rejects_id_above_highest_finalized :: proc(t: ^testing.T) {
    r: Session_Replica
    replica_init(&r, context.allocator, _sid())
    defer replica_deinit(&r)

    msgs := []wire.Message{_assistant_msg(2)}
    _, err := replica_install_snapshot(&r, _resync_msgs(0, msgs, 1))
    testing.expect_value(t, err, Replica_Error.Malformed_Snapshot)
}

@(test)
test_resync_rejects_missing_config_rev :: proc(t: ^testing.T) {
    r: Session_Replica
    replica_init(&r, context.allocator, _sid())
    defer replica_deinit(&r)

    // Assistant references config_rev 2, but the snapshot only carries rev 1.
    msgs := []wire.Message{_assistant_msg_cfg(2, 2)}
    _, err := replica_install_snapshot(&r, _resync_msgs(0, msgs, 2))
    testing.expect_value(t, err, Replica_Error.Malformed_Snapshot)
}

@(test)
test_resync_rejects_duplicate_config :: proc(t: ^testing.T) {
    r: Session_Replica
    replica_init(&r, context.allocator, _sid())
    defer replica_deinit(&r)

    snap := _empty_resync(0)
    snap.configs = []wire.Run_Config {
        {config_rev = 1, model = "a", reasoning = "x"},
        {config_rev = 1, model = "a", reasoning = "x"},
    }
    _, err := replica_install_snapshot(&r, snap)
    testing.expect_value(t, err, Replica_Error.Malformed_Snapshot)
}

@(test)
test_resync_rejects_duplicate_queued_input :: proc(t: ^testing.T) {
    r: Session_Replica
    replica_init(&r, context.allocator, _sid())
    defer replica_deinit(&r)

    snap := _empty_resync(0)
    snap.queued = []wire.Queued_Input {
        {input_id = 1, content = _sample_user_content[:], queued_at_ms = 1},
        {input_id = 1, content = _sample_user_content[:], queued_at_ms = 2},
    }
    // Match the activity count so the wire validator passes and the replica's own
    // duplicate-input check is what rejects the snapshot.
    snap.item.activity.queued = 2
    _, err := replica_install_snapshot(&r, snap)
    testing.expect_value(t, err, Replica_Error.Malformed_Snapshot)
}

@(test)
test_resync_rejects_active_draft_ordinal_hole :: proc(t: ^testing.T) {
    r: Session_Replica
    replica_init(&r, context.allocator, _sid())
    defer replica_deinit(&r)

    // A draft part whose ordinal (1) does not match its index (0) is malformed. The
    // activity matches so the wire validator passes and the replica's own ordinal check
    // rejects it.
    holed := []wire.Assistant_Part{wire.Text_Part{id = 1, text = "x"}}
    snap := _empty_resync(0)
    snap.active = _active_draft(5, holed)
    snap.item.activity = _running_activity()
    _, err := replica_install_snapshot(&r, snap)
    testing.expect_value(t, err, Replica_Error.Malformed_Snapshot)
}

@(test)
test_malformed_snapshot_preserves_previous_state :: proc(t: ^testing.T) {
    r: Session_Replica
    replica_init(&r, context.allocator, _sid())
    defer replica_deinit(&r)

    good := []wire.Message{_assistant_msg(2), _assistant_msg(4)}
    _, err := replica_install_snapshot(&r, _resync_msgs(10, good, 4))
    testing.expect_value(t, err, Replica_Error.None)

    // Not oldest-first: id 3 after id 5 is rejected mid-build, after id 5 was cloned.
    bad := []wire.Message{_assistant_msg(5), _assistant_msg(3)}
    _, berr := replica_install_snapshot(&r, _resync_msgs(99, bad, 5))
    testing.expect_value(t, berr, Replica_Error.Malformed_Snapshot)

    // The previous snapshot is untouched.
    testing.expect_value(t, len(r.messages), 2)
    testing.expect_value(t, wire.message_id(r.messages[0].message), wire.Message_Id(2))
    testing.expect_value(t, r.base_seq, wire.Seq(10))
}

@(test)
test_second_resync_fully_replaces_first :: proc(t: ^testing.T) {
    r: Session_Replica
    replica_init(&r, context.allocator, _sid())
    defer replica_deinit(&r)

    first := []wire.Message{_user_msg(1), _assistant_msg(2)}
    _, _ = replica_install_snapshot(&r, _resync_msgs(10, first, 2))

    second := []wire.Message{_assistant_msg(9)}
    _, _ = replica_install_snapshot(&r, _resync_msgs(20, second, 9))

    testing.expect_value(t, len(r.messages), 1)
    testing.expect_value(t, wire.message_id(r.messages[0].message), wire.Message_Id(9))
    testing.expect_value(t, r.base_seq, wire.Seq(20))
    _, has := replica_committed_by_id(&r, 1)
    testing.expect(t, !has, "first snapshot fully replaced")
}

@(test)
test_snapshot_seal_boundary_covers_finalized_ids :: proc(t: ^testing.T) {
    r: Session_Replica
    replica_init(&r, context.allocator, _sid())
    defer replica_deinit(&r)

    testing.expect_value(t, replica_begin_resync(&r), Replica_Error.None)
    _, _ = replica_apply_broadcast(&r, _bc(.Message_Started, _started(7)))

    snap := _empty_resync(4)
    snap.highest_finalized_message_id = 7
    out, err := replica_install_snapshot(&r, snap)
    testing.expect_value(t, err, Replica_Error.None)
    testing.expect_value(t, out, Install_Outcome.Live)

    // Replayed started(7) is at/below the seal boundary, so it is ignored.
    _, has := replica_active_info(&r)
    testing.expect(t, !has, "sealed start not materialized")
}

@(test)
test_buffered_broadcasts_replay_after_resync :: proc(t: ^testing.T) {
    r: Session_Replica
    replica_init(&r, context.allocator, _sid())
    defer replica_deinit(&r)
    r.base_seq = 5

    gap, _ := replica_apply_broadcast(&r, _committed_bc(8, _assistant_msg(8)))
    testing.expect_value(t, gap.kind, Apply_Kind.Gap)
    _, _ = replica_apply_broadcast(&r, _committed_bc(9, _assistant_msg(9)))

    // Resync reaches seq 7; replay applies 8 then 9 contiguously.
    out, err := replica_install_snapshot(&r, _resync_msgs(7, []wire.Message{_assistant_msg(2)}, 2))
    testing.expect_value(t, err, Replica_Error.None)
    testing.expect_value(t, out, Install_Outcome.Live)
    testing.expect_value(t, r.base_seq, wire.Seq(9))
    _, has8 := replica_committed_by_id(&r, 8)
    testing.expect(t, has8, "replayed 8 present")
    _, has9 := replica_committed_by_id(&r, 9)
    testing.expect(t, has9, "replayed 9 present")
}

@(test)
test_buffered_events_superseded_are_skipped :: proc(t: ^testing.T) {
    r: Session_Replica
    replica_init(&r, context.allocator, _sid())
    defer replica_deinit(&r)
    r.base_seq = 5

    _, _ = replica_apply_broadcast(&r, _committed_bc(8, _assistant_msg(8)))
    _, _ = replica_apply_broadcast(&r, _committed_bc(9, _assistant_msg(9)))

    // Snapshot already covered seq 8/9; buffered copies must not re-apply.
    out, err := replica_install_snapshot(&r, _resync_msgs(9, []wire.Message{_assistant_msg(8), _assistant_msg(9)}, 9))
    testing.expect_value(t, err, Replica_Error.None)
    testing.expect_value(t, out, Install_Outcome.Live)
    testing.expect_value(t, r.base_seq, wire.Seq(9))
    testing.expect_value(t, len(r.messages), 2)
}

@(test)
test_fresh_gap_during_replay_requests_another_resync :: proc(t: ^testing.T) {
    r: Session_Replica
    replica_init(&r, context.allocator, _sid())
    defer replica_deinit(&r)
    r.base_seq = 5

    _, _ = replica_apply_broadcast(&r, _committed_bc(8, _assistant_msg(8)))

    // Resync only reaches seq 6, so buffered seq 8 is still a hole.
    out, err := replica_install_snapshot(&r, _empty_resync(6))
    testing.expect_value(t, err, Replica_Error.None)
    testing.expect_value(t, out, Install_Outcome.Resync_Again)
}

@(test)
test_resync_event_overflow_install_requests_resync_again :: proc(t: ^testing.T) {
    r: Session_Replica
    replica_init(&r, context.allocator, _sid())
    defer replica_deinit(&r)

    testing.expect_value(t, replica_begin_resync(&r), Replica_Error.None)
    for i in 0 ..< u64(MAX_BUFFERED_EVENTS + 5) {
        _, _ = replica_apply_broadcast(
            &r,
            _bc(.Input_Canceled, wire.Input_Canceled_Data{session_id = _sid(), input_id = wire.Input_Id(i)}),
        )
    }

    out, err := replica_install_snapshot(&r, _empty_resync(0))
    testing.expect_value(t, err, Replica_Error.None)
    testing.expect_value(t, out, Install_Outcome.Resync_Again)
}

@(test)
test_resync_byte_overflow_install_requests_resync_again :: proc(t: ^testing.T) {
    r: Session_Replica
    replica_init(&r, context.allocator, _sid())
    defer replica_deinit(&r)

    testing.expect_value(t, replica_begin_resync(&r), Replica_Error.None)
    _, _ = replica_apply_broadcast(&r, _bc(.Message_Started, _started(3)))

    big := make([]u8, MAX_BUFFERED_BYTES + 1, context.allocator)
    defer delete(big, context.allocator)
    for &c in big {
        c = 'x'
    }
    _, _ = replica_apply_broadcast(&r, _bc(.Message_Part_Delta, _delta(3, 0, 0, string(big))))

    out, err := replica_install_snapshot(&r, _empty_resync(0))
    testing.expect_value(t, err, Replica_Error.None)
    testing.expect_value(t, out, Install_Outcome.Resync_Again)
    _, has := replica_active_info(&r)
    testing.expect(t, !has, "overflowed buffer materialized nothing")
}

@(test)
test_deinit_after_install_frees_all_regions :: proc(t: ^testing.T) {
    r: Session_Replica
    replica_init(&r, context.allocator, _sid())
    defer replica_deinit(&r)

    // A snapshot exercising every owned region: committed messages, configs, queued
    // inputs, and an active draft. The deferred deinit must free them all with no leak.
    snap := _resync_msgs(10, []wire.Message{_assistant_msg(2)}, 2)
    snap.queued = []wire.Queued_Input{{input_id = 9, content = _sample_user_content[:], queued_at_ms = 1}}
    snap.active = _active_draft(5, _sample_active_content[:])
    snap.item.activity = _running_activity()
    snap.item.activity.queued = 1

    out, err := replica_install_snapshot(&r, snap)
    testing.expect_value(t, err, Replica_Error.None)
    testing.expect_value(t, out, Install_Outcome.Live)
    testing.expect_value(t, len(r.messages), 1)
    testing.expect_value(t, len(r.queued), 1)
    _, has := replica_active_info(&r)
    testing.expect(t, has, "active draft installed")
}

@(test)
test_tool_output_streams_by_offset_while_running :: proc(t: ^testing.T) {
    r: Session_Replica
    replica_init(&r, context.allocator, _sid())
    defer replica_deinit(&r)

    _, _ = replica_on_started(&r, _started(3))
    _, _ = replica_on_part_added(
        &r,
        _part_added(3, wire.Tool_Part{id = 0, name = "exec", arguments = "{}", state = wire.Tool_State_Pending{}}),
    )

    // Output only streams while running: a delta to a non-running tool is a straggler,
    // ignored rather than a gap.
    straggler, _ := replica_on_tool_output_delta(&r, _tool_out(3, 0, 0, "x"))
    testing.expect_value(t, straggler.kind, Apply_Kind.Ignored)

    run, _ := replica_on_tool_state_changed(
        &r,
        wire.Tool_State_Changed_Data {
            session_id = _sid(),
            message_id = 3,
            part_id = 0,
            state = wire.Tool_State_Running{started_at_ms = 1},
        },
    )
    testing.expect_value(t, run.kind, Apply_Kind.Changed)

    // Offset rule: append at len, ignore behind it, gap ahead of it.
    a, _ := replica_on_tool_output_delta(&r, _tool_out(3, 0, 0, "hel"))
    testing.expect_value(t, a.kind, Apply_Kind.Changed)
    b, _ := replica_on_tool_output_delta(&r, _tool_out(3, 0, 3, "lo"))
    testing.expect_value(t, b.kind, Apply_Kind.Changed)
    dup, _ := replica_on_tool_output_delta(&r, _tool_out(3, 0, 0, "hel"))
    testing.expect_value(t, dup.kind, Apply_Kind.Ignored)
    gap, _ := replica_on_tool_output_delta(&r, _tool_out(3, 0, 99, "!"))
    testing.expect_value(t, gap.kind, Apply_Kind.Gap)

    out, ok := replica_tool_output(&r, 0)
    testing.expect(t, ok, "tool output present")
    testing.expect_value(t, out, "hello")
}

@(test)
test_tool_output_counts_utf8_bytes :: proc(t: ^testing.T) {
    r: Session_Replica
    replica_init(&r, context.allocator, _sid())
    defer replica_deinit(&r)

    _, _ = replica_on_started(&r, _started(3))
    _, _ = replica_on_part_added(
        &r,
        _part_added(
            3,
            wire.Tool_Part {
                id = 0,
                name = "exec",
                arguments = "{}",
                state = wire.Tool_State_Running{started_at_ms = 1},
            },
        ),
    )

    // "é" is two UTF-8 bytes, so the next delta lands at byte offset 2, not rune offset 1.
    e, _ := replica_on_tool_output_delta(&r, _tool_out(3, 0, 0, "é"))
    testing.expect_value(t, e.kind, Apply_Kind.Changed)

    out, _ := replica_tool_output(&r, 0)
    testing.expect_value(t, len(out), 2)

    bang, _ := replica_on_tool_output_delta(&r, _tool_out(3, 0, 2, "!"))
    testing.expect_value(t, bang.kind, Apply_Kind.Changed)

    out2, _ := replica_tool_output(&r, 0)
    testing.expect_value(t, out2, "é!")
}

@(test)
test_tool_output_respects_byte_cap :: proc(t: ^testing.T) {
    r: Session_Replica
    replica_init(&r, context.allocator, _sid())
    defer replica_deinit(&r)

    _, _ = replica_on_started(&r, _started(3))
    _, _ = replica_on_part_added(
        &r,
        _part_added(
            3,
            wire.Tool_Part {
                id = 0,
                name = "exec",
                arguments = "{}",
                state = wire.Tool_State_Running{started_at_ms = 1},
            },
        ),
    )

    cap_bytes := wire.LIMITS.max_tool_output_stream_bytes
    big := make([]u8, cap_bytes, context.allocator)
    defer delete(big, context.allocator)
    for &c in big {
        c = 'x'
    }

    // Reaching exactly the cap is accepted.
    at_cap, _ := replica_on_tool_output_delta(&r, _tool_out(3, 0, 0, string(big)))
    testing.expect_value(t, at_cap.kind, Apply_Kind.Changed)

    // One more byte crosses the cap and is rejected like an offset gap.
    over, _ := replica_on_tool_output_delta(&r, _tool_out(3, 0, u64(cap_bytes), "y"))
    testing.expect_value(t, over.kind, Apply_Kind.Gap)

    out, _ := replica_tool_output(&r, 0)
    testing.expect_value(t, len(out), cap_bytes)
}

@(test)
test_resync_seeds_running_tool_output_and_resumes :: proc(t: ^testing.T) {
    r: Session_Replica
    replica_init(&r, context.allocator, _sid())
    defer replica_deinit(&r)

    content := []wire.Assistant_Part {
        wire.Tool_Part {
            id = 0,
            name = "exec",
            arguments = "{}",
            state = wire.Tool_State_Running{started_at_ms = 1, output = "hello"},
        },
    }

    snap := _empty_resync(10)
    snap.active = _active_draft(5, content)
    snap.item.activity = _running_activity()
    out, err := replica_install_snapshot(&r, snap)
    testing.expect_value(t, err, Replica_Error.None)
    testing.expect_value(t, out, Install_Outcome.Live)

    // The seeded output length is the offset baseline: overlap ignored, append at 5.
    seeded, ok := replica_tool_output(&r, 0)
    testing.expect(t, ok, "seeded output present")
    testing.expect_value(t, seeded, "hello")

    dup, _ := replica_on_tool_output_delta(&r, _tool_out(5, 0, 0, "he"))
    testing.expect_value(t, dup.kind, Apply_Kind.Ignored)
    app, _ := replica_on_tool_output_delta(&r, _tool_out(5, 0, 5, " world"))
    testing.expect_value(t, app.kind, Apply_Kind.Changed)

    resumed, _ := replica_tool_output(&r, 0)
    testing.expect_value(t, resumed, "hello world")
}

@(test)
test_restart_resync_discards_prior_connection_events :: proc(t: ^testing.T) {
    r: Session_Replica
    replica_init(&r, context.allocator, _sid())
    defer replica_deinit(&r)
    r.base_seq = 5

    testing.expect_value(t, replica_begin_resync(&r), Replica_Error.None)

    // Buffer an event belonging to the old connection generation.
    pre, _ := replica_apply_broadcast(&r, _committed_bc(8, _assistant_msg(8)))
    testing.expect_value(t, pre.kind, Apply_Kind.Buffered)
    testing.expect_value(t, len(r.resync.events), 1)

    // A new connection generation restarts the buffer, dropping the prior event.
    testing.expect_value(t, replica_restart_resync(&r), Replica_Error.None)
    testing.expect_value(t, len(r.resync.events), 0)

    // Buffer a post-restart event.
    post, _ := replica_apply_broadcast(&r, _committed_bc(6, _assistant_msg(6)))
    testing.expect_value(t, post.kind, Apply_Kind.Buffered)

    // Install a snapshot reaching seq 5; replay applies only the post-restart event (6).
    out, err := replica_install_snapshot(&r, _resync_msgs(5, []wire.Message{_assistant_msg(2)}, 2))
    testing.expect_value(t, err, Replica_Error.None)
    testing.expect_value(t, out, Install_Outcome.Live)
    testing.expect_value(t, r.base_seq, wire.Seq(6))
    _, has6 := replica_committed_by_id(&r, 6)
    testing.expect(t, has6, "post-restart event replayed")
    _, has8 := replica_committed_by_id(&r, 8)
    testing.expect(t, !has8, "pre-restart event was discarded, not replayed")
}

@(test)
test_resync_rejects_activity_queued_mismatch :: proc(t: ^testing.T) {
    r: Session_Replica
    replica_init(&r, context.allocator, _sid())
    defer replica_deinit(&r)

    // Establish prior state.
    _, err0 := replica_install_snapshot(&r, _resync_msgs(10, []wire.Message{_assistant_msg(2)}, 2))
    testing.expect_value(t, err0, Replica_Error.None)

    // A snapshot whose activity.queued (1) disagrees with len(queued) (0) is malformed; the
    // wire validator catches the cross-field mismatch the replica used not to check.
    bad := _empty_resync(20)
    bad.item.activity.queued = 1
    _, err := replica_install_snapshot(&r, bad)
    testing.expect_value(t, err, Replica_Error.Malformed_Snapshot)

    // Prior state is intact.
    testing.expect_value(t, len(r.messages), 1)
    testing.expect_value(t, r.base_seq, wire.Seq(10))
}

@(test)
test_terminal_tool_state_ignores_backwards_transition :: proc(t: ^testing.T) {
    r: Session_Replica
    replica_init(&r, context.allocator, _sid())
    defer replica_deinit(&r)

    _, _ = replica_on_started(&r, _started(3))
    _, _ = replica_on_part_added(
        &r,
        _part_added(3, wire.Tool_Part{id = 0, name = "read", arguments = "{}", state = wire.Tool_State_Pending{}}),
    )

    comp, _ := replica_on_tool_state_changed(
        &r,
        wire.Tool_State_Changed_Data {
            session_id = _sid(),
            message_id = 3,
            part_id = 0,
            state = wire.Tool_State_Completed{output = "done", duration_ms = 1},
        },
    )
    testing.expect_value(t, comp.kind, Apply_Kind.Changed)

    // A stale waiting_permission for the already-completed part must not regress it.
    options := []wire.Permission_Option{{id = "once", kind = .Allow_Once, label = "Allow"}}
    stale, _ := replica_on_tool_state_changed(
        &r,
        wire.Tool_State_Changed_Data {
            session_id = _sid(),
            message_id = 3,
            part_id = 0,
            state = wire.Tool_State_Waiting_Permission {
                permission_state = wire.Permission_State{requested_at_ms = 5, options = options},
            },
        },
    )
    testing.expect_value(t, stale.kind, Apply_Kind.Ignored)

    tp := replica_tool_part(&r, 0)
    _, is_completed := tp.state.(wire.Tool_State_Completed)
    testing.expect(t, is_completed, "state stays completed")

    _, has := replica_pending_permission(&r)
    testing.expect(t, !has, "stale waiting set no pending permission")
}

@(test)
test_durable_clear_blocks_stale_activity_reassert :: proc(t: ^testing.T) {
    r: Session_Replica
    replica_init(&r, context.allocator, _sid())
    defer replica_deinit(&r)

    // Activity asserts a pending compaction run.
    a1, _ := replica_apply_broadcast(&r, _activity_bc(wire.Run_Id(42)))
    testing.expect_value(t, a1.kind, Apply_Kind.Changed)

    // A durable run.done for that run clears it.
    done, _ := replica_apply_broadcast(
        &r,
        _run_done_bc(1, 42, wire.Run_Outcome_Failed{code = .Provider, message = "boom"}),
    )
    testing.expect_value(t, done.kind, Apply_Kind.Changed)
    testing.expect(t, r.pending_compaction == nil, "durable run.done cleared the compaction")

    // A stale activity re-asserting the same, now-cleared id is dropped; run ids never
    // repeat, so this can only be the id already cleared.
    stale, _ := replica_apply_broadcast(&r, _activity_bc(wire.Run_Id(42)))
    testing.expect_value(t, stale.kind, Apply_Kind.Ignored)
    testing.expect(t, r.pending_compaction == nil, "cleared compaction was not re-asserted")
}

@(test)
test_resync_rejects_draft_missing_config_rev :: proc(t: ^testing.T) {
    r: Session_Replica
    replica_init(&r, context.allocator, _sid())
    defer replica_deinit(&r)

    // Establish prior state.
    _, err0 := replica_install_snapshot(&r, _resync_msgs(10, []wire.Message{_assistant_msg(2)}, 2))
    testing.expect_value(t, err0, Replica_Error.None)

    // An active draft (and its activity) referencing config_rev 99, absent from configs.
    draft := _active_draft(5, _sample_active_content[:])
    draft.message.config_rev = 99
    bad := _empty_resync(20)
    bad.active = draft
    bad.item.activity = wire.Session_Activity {
        state = wire.Activity_State_Running {
            run_id = 7,
            config = wire.Run_Config{config_rev = 99, model = "model", reasoning = "high"},
            started_at_ms = 1,
        },
    }
    _, err := replica_install_snapshot(&r, bad)
    testing.expect_value(t, err, Replica_Error.Malformed_Snapshot)

    // Prior state is intact.
    testing.expect_value(t, len(r.messages), 1)
    _, has := replica_active_info(&r)
    testing.expect(t, !has, "malformed draft snapshot installed no active draft")
}

@(test)
test_committing_older_than_window_evicts_immediately :: proc(t: ^testing.T) {
    r: Session_Replica
    replica_init(&r, context.allocator, _sid())
    defer replica_deinit(&r)

    // Fill the committed window to capacity via a snapshot (ids 1..MAX).
    full := make([]wire.Message, MAX_RETAINED_MESSAGES, context.allocator)
    defer delete(full, context.allocator)
    for i in 0 ..< len(full) {
        full[i] = _user_msg(wire.Message_Id(i + 1))
    }

    _, err := replica_install_snapshot(&r, _resync_msgs(1, full, wire.Message_Id(len(full))))
    testing.expect_value(t, err, Replica_Error.None)
    testing.expect_value(t, len(r.messages), MAX_RETAINED_MESSAGES)

    // Committing an id older than the whole window front-inserts then evicts it at once, so
    // the retained window is unchanged and older history is now known to exist.
    res, cerr := replica_on_committed(&r, _committed(1, _user_msg(0)))
    testing.expect_value(t, cerr, Replica_Error.None)
    testing.expect_value(t, res.kind, Apply_Kind.Committed)
    testing.expect_value(t, len(r.messages), MAX_RETAINED_MESSAGES)
    testing.expect_value(t, wire.message_id(r.messages[0].message), wire.Message_Id(1))
    testing.expect(t, r.has_more, "older history now known to exist")
    _, has0 := replica_committed_by_id(&r, 0)
    testing.expect(t, !has0, "front-inserted old id was evicted immediately")
}

@(test)
test_resync_rejects_multiple_waiting_tools :: proc(t: ^testing.T) {
    r: Session_Replica
    replica_init(&r, context.allocator, _sid())
    defer replica_deinit(&r)

    // The wire contract (`resync_result_validate`) allows at most one waiting tool, so a
    // snapshot with two is malformed rather than silently first-wins.
    options := []wire.Permission_Option{{id = "once", kind = .Allow_Once, label = "Allow"}}
    two := []wire.Assistant_Part {
        wire.Tool_Part {
            id = 0,
            name = "read",
            arguments = "{}",
            state = wire.Tool_State_Waiting_Permission {
                permission_state = wire.Permission_State{requested_at_ms = 1, options = options},
            },
        },
        wire.Tool_Part {
            id = 1,
            name = "write",
            arguments = "{}",
            state = wire.Tool_State_Waiting_Permission {
                permission_state = wire.Permission_State{requested_at_ms = 2, options = options},
            },
        },
    }

    snap := _empty_resync(0)
    snap.active = _active_draft(5, two)
    snap.item.activity = wire.Session_Activity {
        state = wire.Activity_State_Waiting_Permission {
            run_id = 7,
            config = _sample_configs[0],
            message_id = 5,
            part_id = 0,
            tool_name = "read",
            requested_at_ms = 1,
        },
    }
    _, err := replica_install_snapshot(&r, snap)
    testing.expect_value(t, err, Replica_Error.Malformed_Snapshot)
}

@(test)
test_zero_length_delta_at_offset_is_changed :: proc(t: ^testing.T) {
    r: Session_Replica
    replica_init(&r, context.allocator, _sid())
    defer replica_deinit(&r)

    _open_text(t, &r, 3)

    // An empty delta at the current end appends nothing but is reported `.Changed`; pin it.
    res, _ := replica_on_part_delta(&r, _delta(3, 0, 0, ""))
    testing.expect_value(t, res.kind, Apply_Kind.Changed)

    text, _ := replica_part_text(&r, 0)
    testing.expect_value(t, text, "")
}

// --- allocation-failure harness ---

// The fault-injecting allocator lives in `libs:testsupport` (`ts.Failing_Allocator`). It fails
// every alloc/resize from the `fail_at`-th counted allocation onward and exempts arena-internal
// allocations (which report `allocators.odin`) because `Dynamic_Arena` is not failure-safe. The
// replica's OWN direct structural allocations — `new`, candidate spine `make`/`reserve`/`append`,
// `text_buffer_build`, the resync-buffer struct — DO propagate `.Out_Of_Memory` and drive the
// transactional rollback these tests prove.

// Sweep `fail_at` across every allocation of `op`, asserting each run either fully succeeds
// or cleanly returns `.Out_Of_Memory` (never another error or a corrupt state), with no
// leak — the runner's tracking allocator asserts the latter at test end. This is the Odin
// analogue of Zig's `checkAllAllocationFailures`. The sweep does not stop at the first
// success: because the wire deep-clones cannot signal OOM (they under-copy silently and
// return success), a `.None` at one fail point does not imply budget exhaustion, so every
// point in `0..=total` is exercised.
@(private = "file")
_sweep_alloc_failures :: proc(t: ^testing.T, op: proc(alloc: mem.Allocator) -> Replica_Error) {
    // A run whose fail point is unreachable counts the total allocations.
    probe := ts.Failing_Allocator {
        backing = context.allocator,
        fail_at = max(int),
    }
    testing.expect_value(t, op(ts.failing_allocator(&probe)), Replica_Error.None)

    for fail_at in 0 ..= probe.count {
        fa := ts.Failing_Allocator {
            backing = context.allocator,
            fail_at = fail_at,
        }
        err := op(ts.failing_allocator(&fa))
        testing.expect(t, err == .None || err == .Out_Of_Memory, "op must succeed or cleanly OOM under alloc failure")
    }
}

@(private = "file")
_op_install_snapshot :: proc(alloc: mem.Allocator) -> Replica_Error {
    r: Session_Replica
    replica_init(&r, alloc, _sid())
    defer replica_deinit(&r)

    msgs := []wire.Message{_assistant_msg(1), _assistant_msg(2), _assistant_msg(3)}
    _, err := replica_install_snapshot(&r, _resync_msgs(10, msgs, 3))
    return err
}

@(private = "file")
_op_replace_pending_permission :: proc(alloc: mem.Allocator) -> Replica_Error {
    r: Session_Replica
    replica_init(&r, alloc, _sid())
    defer replica_deinit(&r)

    if _, e := replica_on_started(&r, _started(3)); e != .None {
        return e
    }

    tool := wire.Tool_Part {
        id        = 0,
        name      = "read",
        arguments = "{}",
        state     = wire.Tool_State_Pending{},
    }
    if _, e := replica_on_part_added(&r, _part_added(3, tool)); e != .None {
        return e
    }

    options := []wire.Permission_Option{{id = "once", kind = .Allow_Once, label = "Allow"}}
    _, e := replica_on_tool_state_changed(
        &r,
        wire.Tool_State_Changed_Data {
            session_id = _sid(),
            message_id = 3,
            part_id = 0,
            state = wire.Tool_State_Waiting_Permission {
                permission_state = wire.Permission_State{requested_at_ms = 1, options = options},
            },
        },
    )
    return e
}

@(private = "file")
_op_append_config :: proc(alloc: mem.Allocator) -> Replica_Error {
    r: Session_Replica
    replica_init(&r, alloc, _sid())
    defer replica_deinit(&r)

    _, e := replica_on_config_changed(
        &r,
        wire.Config_Changed_Data{session_id = _sid(), seq = 1, config = _run_cfg(2, "model")},
    )
    return e
}

@(private = "file")
_op_queue_input :: proc(alloc: mem.Allocator) -> Replica_Error {
    r: Session_Replica
    replica_init(&r, alloc, _sid())
    defer replica_deinit(&r)

    _, e := replica_on_input_queued(&r, _queued(1))
    return e
}

@(private = "file")
_op_buffered_replay :: proc(alloc: mem.Allocator) -> Replica_Error {
    r: Session_Replica
    replica_init(&r, alloc, _sid())
    defer replica_deinit(&r)

    if e := replica_begin_resync(&r); e != .None {
        return e
    }

    if _, e := replica_apply_broadcast(&r, _bc(.Message_Started, _started(3))); e != .None {
        return e
    }

    _, e := replica_install_snapshot(&r, _resync_msgs(7, []wire.Message{_assistant_msg(2)}, 2))
    return e
}

@(test)
test_alloc_failure_snapshot_install_is_safe :: proc(t: ^testing.T) {
    _sweep_alloc_failures(t, _op_install_snapshot)
}

@(test)
test_alloc_failure_replace_pending_permission_is_safe :: proc(t: ^testing.T) {
    _sweep_alloc_failures(t, _op_replace_pending_permission)
}

@(test)
test_alloc_failure_append_config_is_safe :: proc(t: ^testing.T) {
    _sweep_alloc_failures(t, _op_append_config)
}

@(test)
test_alloc_failure_queue_input_is_safe :: proc(t: ^testing.T) {
    _sweep_alloc_failures(t, _op_queue_input)
}

@(test)
test_alloc_failure_buffered_replay_is_safe :: proc(t: ^testing.T) {
    _sweep_alloc_failures(t, _op_buffered_replay)
}

// A tool in `waiting_permission` that already carries a resolved decision has no consistent
// activity projection: `resync_result_validate` rejects a waiting activity whose tool
// permission state has a decision, and every other activity forbids a waiting tool. The
// snapshot is therefore malformed and prior state is preserved — pending permission is only
// derived (see `derive_pending_permission`) from a tool still awaiting a decision.
@(test)
test_install_waiting_with_decision_is_malformed :: proc(t: ^testing.T) {
    r: Session_Replica
    replica_init(&r, context.allocator, _sid())
    defer replica_deinit(&r)

    resolved := []wire.Assistant_Part {
        wire.Tool_Part {
            id = 0,
            name = "read",
            arguments = "{}",
            state = wire.Tool_State_Waiting_Permission {
                permission_state = wire.Permission_State {
                    requested_at_ms = 1,
                    decision = wire.Permission_Decision_Rule{rule_id = {}, label = "rule", resolved_at_ms = 2},
                },
            },
        },
    }

    snap := _empty_resync(0)
    snap.active = _active_draft(5, resolved)
    snap.item.activity = wire.Session_Activity {
        state = wire.Activity_State_Waiting_Permission {
            run_id = 7,
            config = _sample_configs[0],
            message_id = 5,
            part_id = 0,
            tool_name = "read",
            requested_at_ms = 1,
        },
    }
    _, err := replica_install_snapshot(&r, snap)
    testing.expect_value(t, err, Replica_Error.Malformed_Snapshot)

    _, has := replica_active_info(&r)
    testing.expect(t, !has, "malformed snapshot left no active draft")
}

// --- borrow-returning view surface ---

// Every public view returns none/false on a miss and the right borrow on a hit: wrong or
// out-of-range part id, wrong part kind, unknown config revision, and unknown message id.
@(test)
test_views_return_none_on_miss_and_borrow_on_hit :: proc(t: ^testing.T) {
    r: Session_Replica
    replica_init(&r, context.allocator, _sid())
    defer replica_deinit(&r)

    // Empty replica: every view misses.
    _, has_info := replica_active_info(&r)
    testing.expect(t, !has_info, "no active info when no draft")
    _, has_msg := replica_committed_by_id(&r, 1)
    testing.expect(t, !has_msg, "no committed message")
    _, has_cfg := replica_config(&r, 1)
    testing.expect(t, !has_cfg, "no config")
    _, has_kind := replica_part_kind(&r, 0)
    testing.expect(t, !has_kind, "no part kind without draft")
    _, has_text := replica_part_text(&r, 0)
    testing.expect(t, !has_text, "no part text without draft")
    testing.expect(t, replica_tool_part(&r, 0) == nil, "no tool part without draft")
    _, has_pending := replica_pending_permission(&r)
    testing.expect(t, !has_pending, "no pending permission")

    // A draft with a text part (0) and a tool part (1).
    _, _ = replica_on_started(&r, _started(3))
    _, _ = replica_on_part_added(&r, _text_part(3, 0, "hi"))
    _, _ = replica_on_part_added(
        &r,
        _part_added(3, wire.Tool_Part{id = 1, name = "read", arguments = "{}", state = wire.Tool_State_Pending{}}),
    )

    // Hits.
    kind0, ok0 := replica_part_kind(&r, 0)
    testing.expect(t, ok0, "text part kind present")
    testing.expect_value(t, kind0, Part_Kind.Text)
    text0, okt := replica_part_text(&r, 0)
    testing.expect(t, okt, "text part text present")
    testing.expect_value(t, text0, "hi")
    testing.expect(t, replica_tool_part(&r, 1) != nil, "tool part present")
    kind1, _ := replica_part_kind(&r, 1)
    testing.expect_value(t, kind1, Part_Kind.Tool)

    // Wrong kind: text has no tool, tool has no text buffer.
    testing.expect(t, replica_tool_part(&r, 0) == nil, "text part is not a tool")
    _, tool_text := replica_part_text(&r, 1)
    testing.expect(t, !tool_text, "tool part has no text")

    // Out-of-range part id.
    _, oob_kind := replica_part_kind(&r, 9)
    testing.expect(t, !oob_kind, "out-of-range part kind misses")
    _, oob_text := replica_part_text(&r, 9)
    testing.expect(t, !oob_text, "out-of-range part text misses")
    testing.expect(t, replica_tool_part(&r, 9) == nil, "out-of-range tool part misses")

    // Config hit/miss.
    _, _ = replica_on_config_changed(
        &r,
        wire.Config_Changed_Data{session_id = _sid(), seq = 1, config = _run_cfg(2, "gpt")},
    )
    cfg, cfg_ok := replica_config(&r, 2)
    testing.expect(t, cfg_ok, "known config present")
    testing.expect_value(t, cfg.model, "gpt")
    _, cfg_miss := replica_config(&r, 99)
    testing.expect(t, !cfg_miss, "unknown config misses")

    // Committed message hit/miss.
    _, _ = replica_on_committed(&r, _committed(1, _user_msg(4)))
    msg, msg_ok := replica_committed_by_id(&r, 4)
    testing.expect(t, msg_ok, "known committed message present")
    testing.expect_value(t, wire.message_id(msg), wire.Message_Id(4))
    _, msg_miss := replica_committed_by_id(&r, 99)
    testing.expect(t, !msg_miss, "unknown message misses")
}
