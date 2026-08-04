package wire

import "core:mem"
import "core:testing"

@(test)
test_broadcast_name_wire_roundtrip :: proc(t: ^testing.T) {
    name, ok := broadcast_name_from_wire("run.done")
    testing.expect(t, ok, "run.done should be known")
    testing.expect_value(t, name, Broadcast_Name.Run_Done)
    testing.expect_value(t, broadcast_name_to_wire(.Session_Summary_Changed), "session.summary_changed")
    testing.expect_value(t, broadcast_name_to_wire(.Session_Activity_Changed), "session.activity_changed")

    shed, shed_ok := broadcast_name_from_wire("session.deltas_shed")
    testing.expect(t, shed_ok, "session.deltas_shed should be known")
    testing.expect_value(t, shed, Broadcast_Name.Session_Deltas_Shed)

    _, bad := broadcast_name_from_wire("unknown.broadcast")
    testing.expect(t, !bad, "unknown name must be rejected")

    // session.changed / run.canceled / run.failed are not part of the closed set.
    _, c := broadcast_name_from_wire("session.changed")
    testing.expect(t, !c, "session.changed must be removed")
    _, rc := broadcast_name_from_wire("run.canceled")
    testing.expect(t, !rc, "run.canceled must be removed")
    _, rf := broadcast_name_from_wire("run.failed")
    testing.expect(t, !rf, "run.failed must be removed")
}

@(test)
test_broadcast_name_class :: proc(t: ^testing.T) {
    testing.expect_value(t, broadcast_name_class(.Run_Done), Broadcast_Class.Durable_Gated)
    testing.expect_value(t, broadcast_name_class(.Message_Committed), Broadcast_Class.Durable_Gated)
    testing.expect_value(t, broadcast_name_class(.Message_Part_Delta), Broadcast_Class.Live_Droppable)
    testing.expect_value(t, broadcast_name_class(.Tool_Output_Delta), Broadcast_Class.Live_Droppable)
    testing.expect_value(t, broadcast_name_class(.Message_Started), Broadcast_Class.Live_Gated)
    testing.expect_value(t, broadcast_name_class(.Session_Summary_Changed), Broadcast_Class.Ungated)
    testing.expect_value(t, broadcast_name_class(.Session_Activity_Changed), Broadcast_Class.Ungated)
    testing.expect_value(t, broadcast_name_class(.Notice), Broadcast_Class.Ungated)
}

@(test)
test_broadcast_data_name :: proc(t: ^testing.T) {
    committed, ok := broadcast_data_name(Message_Committed_Data{})
    testing.expect(t, ok, "a payload arm names its broadcast")
    testing.expect_value(t, committed, Broadcast_Name.Message_Committed)

    // The two delta arms are distinct types over the same struct, so they must not
    // collapse onto one name.
    part, part_ok := broadcast_data_name(Message_Part_Delta_Data{})
    testing.expect(t, part_ok, "message.part_delta names its broadcast")
    testing.expect_value(t, part, Broadcast_Name.Message_Part_Delta)
    tool, tool_ok := broadcast_data_name(Tool_Output_Delta_Data{})
    testing.expect(t, tool_ok, "tool.output_delta names its broadcast")
    testing.expect_value(t, tool, Broadcast_Name.Tool_Output_Delta)

    notice, notice_ok := broadcast_data_name(Notice{})
    testing.expect(t, notice_ok, "notice names its broadcast")
    testing.expect_value(t, notice, Broadcast_Name.Notice)

    _, empty := broadcast_data_name(nil)
    testing.expect(t, !empty, "an empty payload names nothing")
}

@(test)
test_run_started_turn_roundtrip :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)
    input := `{"session_id":"0123456789abcdef","seq":1,"run_id":7,"kind":"turn","config_rev":1,"started_at_ms":10}`
    v := decoder_init(input, context.temp_allocator)

    data, derr := broadcast_data_from_reader(.Run_Started, &v)
    testing.expect(t, derr == .None, "decode should succeed")
    rs, ok := data.(Run_Started_Data)
    testing.expect(t, ok, "should be run.started")
    testing.expect_value(t, rs.kind, Run_Kind.Turn)
    _, has_reason := rs.reason.?
    testing.expect(t, !has_reason, "a turn carries no compaction reason")
    testing.expect(t, broadcast_data_validate(data) == .None, "valid run.started")

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    broadcast_data_emit(&e, data)
    testing.expect_value(t, to_string(&e), input)
}

// The durable log has to carry the reason, or a resync cannot rebuild a compacting session.
@(test)
test_run_started_compaction_roundtrip :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)
    input := `{"session_id":"0123456789abcdef","seq":4,"run_id":8,"kind":"compaction","reason":"manual","config_rev":2,"started_at_ms":11}`
    v := decoder_init(input, context.temp_allocator)

    data, derr := broadcast_data_from_reader(.Run_Started, &v)
    testing.expect(t, derr == .None, "decode should succeed")
    rs, ok := data.(Run_Started_Data)
    testing.expect(t, ok, "should be run.started")
    testing.expect_value(t, rs.kind, Run_Kind.Compaction)
    reason, has_reason := rs.reason.?
    testing.expect(t, has_reason, "a compaction carries its reason")
    testing.expect_value(t, reason, Compaction_Reason.Manual)
    testing.expect(t, broadcast_data_validate(data) == .None, "valid compaction run.started")

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    broadcast_data_emit(&e, data)
    testing.expect_value(t, to_string(&e), input)
}

// The reason is meaningful only for a compaction run, in both directions.
@(test)
test_run_started_rejects_reason_kind_mismatch :: proc(t: ^testing.T) {
    data := Run_Started_Data {
        session_id    = Session_Id(
            [16]u8{'0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f'},
        ),
        seq           = 1,
        run_id        = 7,
        kind          = .Turn,
        reason        = Compaction_Reason.Auto,
        config_rev    = 1,
        started_at_ms = 10,
    }
    testing.expect(
        t,
        run_started_data_validate(data) == .Mismatched_Payload,
        "a turn with a compaction reason must fail",
    )

    data.reason = nil
    data.kind = .Compaction
    testing.expect(
        t,
        run_started_data_validate(data) == .Mismatched_Payload,
        "a compaction without a reason must fail",
    )

    data.reason = Compaction_Reason.Auto
    testing.expect(t, run_started_data_validate(data) == .None, "a compaction with a reason validates")
}

@(test)
test_run_started_rejects_unknown_reason :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)
    input := `{"session_id":"0123456789abcdef","seq":4,"run_id":8,"kind":"compaction","reason":"whenever","config_rev":2,"started_at_ms":11}`
    v := decoder_init(input, context.temp_allocator)

    _, derr := broadcast_data_from_reader(.Run_Started, &v)
    testing.expect(t, derr != .None, "an unknown compaction reason must be rejected")
}

@(test)
test_session_deltas_shed_roundtrip :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)
    input := `{"session_id":"0123456789abcdef","count":12}`
    v := decoder_init(input, context.temp_allocator)

    data, derr := broadcast_data_from_reader(.Session_Deltas_Shed, &v)
    testing.expect(t, derr == .None, "decode should succeed")
    shed, ok := data.(Session_Deltas_Shed_Data)
    testing.expect(t, ok, "should be session.deltas_shed")
    testing.expect_value(t, shed.count, u64(12))
    testing.expect(t, broadcast_data_validate(data) == .None, "valid session.deltas_shed")

    // Live droppable: never sequenced, routed by session like the deltas it reports on.
    _, has_seq := broadcast_data_seq(data).?
    testing.expect(t, !has_seq, "the shed marker is not durable")
    _, has_sid := broadcast_data_session_id(data).?
    testing.expect(t, has_sid, "the shed marker routes by session")
    testing.expect_value(t, broadcast_name_class(.Session_Deltas_Shed), Broadcast_Class.Live_Droppable)

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    broadcast_data_emit(&e, data)
    testing.expect_value(t, to_string(&e), input)
}

@(test)
test_session_deltas_shed_rejects_zero_count :: proc(t: ^testing.T) {
    // A marker that reports nothing shed is meaningless; the count is the payload.
    bad := Session_Deltas_Shed_Data {
        session_id = Session_Id(
            [16]u8{'0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f'},
        ),
        count      = 0,
    }
    testing.expect(t, session_deltas_shed_data_validate(bad) == .Out_Of_Range, "zero count must be rejected")

    bad.count = MAX_WIRE_INTEGER + 1
    testing.expect(
        t,
        session_deltas_shed_data_validate(bad) == .Out_Of_Range,
        "a count past the JSON safe range must be rejected",
    )
}

@(test)
test_session_deltas_shed_requires_both_fields :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)
    {
        v := decoder_init(`{"session_id":"0123456789abcdef"}`, context.temp_allocator)
        _, derr := broadcast_data_from_reader(.Session_Deltas_Shed, &v)
        testing.expect(t, derr == .Mismatched_Payload, "a missing count must be rejected")
    }
    {
        v := decoder_init(`{"count":3}`, context.temp_allocator)
        _, derr := broadcast_data_from_reader(.Session_Deltas_Shed, &v)
        testing.expect(t, derr == .Mismatched_Payload, "a missing session id must be rejected")
    }
}

@(test)
test_run_done_turn_roundtrip :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)
    input := `{"session_id":"0123456789abcdef","seq":2,"run_id":7,"kind":"turn","timing":{"started_at_ms":0,"ended_at_ms":1},"outcome":{"type":"turn","finish":"stop","rounds":3}}`
    v := decoder_init(input, context.temp_allocator)

    data, derr := broadcast_data_from_reader(.Run_Done, &v)
    testing.expect(t, derr == .None, "decode should succeed")
    rd, ok := data.(Run_Done_Data)
    testing.expect(t, ok, "should be run.done")
    testing.expect_value(t, rd.kind, Run_Kind.Turn)
    testing.expect_value(t, u64(rd.seq), u64(2))
    turn, is_turn := rd.outcome.(Run_Outcome_Turn)
    testing.expect(t, is_turn, "outcome should be a turn")
    testing.expect_value(t, turn.rounds, u64(3))

    // Durable: seq present. Session-scoped: routes by session.
    s, has_seq := broadcast_data_seq(data).?
    testing.expect(t, has_seq && u64(s) == 2, "run.done is durable")
    _, has_sid := broadcast_data_session_id(data).?
    testing.expect(t, has_sid, "run.done routes by session")
    testing.expect(t, broadcast_data_validate(data) == .None, "valid run.done")

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    broadcast_data_emit(&e, data)
    testing.expect_value(t, to_string(&e), input)
}

@(test)
test_run_done_canceled_null_start_roundtrip :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)
    // A queued run canceled before starting: timing.started_at_ms is null; the
    // outcome arm carries no timing of its own.
    input := `{"session_id":"0123456789abcdef","seq":3,"run_id":7,"kind":"turn","timing":{"started_at_ms":null,"ended_at_ms":100},"outcome":{"type":"canceled"}}`
    v := decoder_init(input, context.temp_allocator)

    data, derr := broadcast_data_from_reader(.Run_Done, &v)
    testing.expect(t, derr == .None, "decode should succeed")
    rd, ok := data.(Run_Done_Data)
    testing.expect(t, ok, "should be run.done")
    _, has_start := rd.timing.started_at_ms.?
    testing.expect(t, !has_start, "started_at_ms should be absent")
    testing.expect_value(t, rd.timing.ended_at_ms, u64(100))
    _, is_canceled := rd.outcome.(Run_Outcome_Canceled)
    testing.expect(t, is_canceled, "outcome should be canceled")

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    broadcast_data_emit(&e, data)
    testing.expect_value(t, to_string(&e), input)
}

@(test)
test_session_summary_changed_roundtrip :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)
    input := `{"revision":4130,"session":{"id":"0123456789abcdef","workspace_id":"aaaaaaaaaaaaaaaa","profile":"default","model":"openai/gpt","reasoning":"low","config_rev":1,"permission":"normal","max_rounds":null,"title":"title","message_count":0,"created_at_ms":0,"updated_at_ms":0,"created_by":{"name":"yuke-tui","version":"0.1"},"origin":{"type":"root"}}}`
    v := decoder_init(input, context.temp_allocator)

    data, derr := broadcast_data_from_reader(.Session_Summary_Changed, &v)
    testing.expect(t, derr == .None, "decode should succeed")
    sc, ok := data.(Session_Summary_Changed_Data)
    testing.expect(t, ok, "should be session.summary_changed")
    testing.expect_value(t, u64(sc.revision), u64(4130))
    testing.expect_value(t, sc.session.profile, "default")

    // Ungated: no durable seq. Session-scoped: routes by the carried summary's id.
    _, has_seq := broadcast_data_seq(data).?
    testing.expect(t, !has_seq, "summary_changed carries no seq")
    _, has_sid := broadcast_data_session_id(data).?
    testing.expect(t, has_sid, "summary_changed routes by session")
    testing.expect(t, broadcast_data_validate(data) == .None, "valid summary_changed")

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    broadcast_data_emit(&e, data)
    testing.expect_value(t, to_string(&e), input)
}

@(test)
test_session_activity_changed_roundtrip :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)
    input := `{"session_id":"0123456789abcdef","activity":{"state":{"type":"idle"},"queued":0,"context_tokens":5123,"pending_compaction":null}}`
    v := decoder_init(input, context.temp_allocator)

    data, derr := broadcast_data_from_reader(.Session_Activity_Changed, &v)
    testing.expect(t, derr == .None, "decode should succeed")
    ac, ok := data.(Session_Activity_Changed_Data)
    testing.expect(t, ok, "should be session.activity_changed")
    testing.expect_value(t, ac.activity.context_tokens, u64(5123))
    _, is_idle := ac.activity.state.(Activity_State_Idle)
    testing.expect(t, is_idle, "state should be idle")

    _, has_seq := broadcast_data_seq(data).?
    testing.expect(t, !has_seq, "activity_changed carries no seq")

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    broadcast_data_emit(&e, data)
    testing.expect_value(t, to_string(&e), input)
}

// The hoisted activity config is borrowed frame data; a clone must own its strings.
@(test)
test_session_activity_changed_config_clone_outlives_source :: proc(t: ^testing.T) {
    src_arena: mem.Dynamic_Arena
    mem.dynamic_arena_init(&src_arena, context.allocator, context.allocator)
    src := mem.dynamic_arena_allocator(&src_arena)

    dst_arena: mem.Dynamic_Arena
    mem.dynamic_arena_init(&dst_arena, context.allocator, context.allocator)
    dst := mem.dynamic_arena_allocator(&dst_arena)
    defer mem.dynamic_arena_destroy(&dst_arena)

    input := `{"session_id":"0123456789abcdef","activity":{"state":{"type":"running","run_id":7,"started_at_ms":1},"config":{"config_rev":2,"model":"openai/gpt-5.5","reasoning":"high"},"queued":0,"context_tokens":0,"pending_compaction":null}}`
    d := decoder_init(input, src)
    data, derr := broadcast_data_from_reader(.Session_Activity_Changed, &d)
    testing.expect(t, derr == .None, "decode should succeed")
    testing.expect(t, broadcast_data_validate(data) == .None, "running activity with config must validate")

    clone := notification_clone(notification_build(.Session_Activity_Changed, data), dst)

    // Drop the decode arena; the cloned config must remain valid.
    mem.dynamic_arena_destroy(&src_arena)

    changed, is_changed := clone.params.(Session_Activity_Changed_Data)
    testing.expect(t, is_changed, "payload is session.activity_changed")
    cfg, has_config := changed.activity.config.?
    testing.expect(t, has_config, "cloned config is present")
    testing.expect_value(t, cfg.model, "openai/gpt-5.5")
    testing.expect_value(t, cfg.reasoning, "high")

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    broadcast_data_emit(&e, clone.params)
    testing.expect_value(t, to_string(&e), input)
}

@(test)
test_session_removed_roundtrip :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)
    input := `{"revision":2,"session_id":"0123456789abcdef"}`
    v := decoder_init(input, context.temp_allocator)

    data, derr := broadcast_data_from_reader(.Session_Removed, &v)
    testing.expect(t, derr == .None, "decode should succeed")
    rm, ok := data.(Session_Removed_Data)
    testing.expect(t, ok, "should be session.removed")
    testing.expect_value(t, u64(rm.revision), u64(2))
    testing.expect(t, broadcast_data_validate(data) == .None, "valid session.removed")

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    broadcast_data_emit(&e, data)
    testing.expect_value(t, to_string(&e), input)
}

@(test)
test_session_removed_rejects_bad_revision :: proc(t: ^testing.T) {
    // A zero revision is out of range regardless of the id.
    raw: [16]u8
    for i in 0 ..< 16 {
        raw[i] = '0'
    }

    bad := Session_Removed_Data {
        revision   = 0,
        session_id = Session_Id(raw),
    }
    testing.expect(t, session_removed_data_validate(bad) == .Out_Of_Range, "zero revision must be rejected")
}

@(test)
test_message_part_delta_roundtrip :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)
    input := `{"session_id":"0123456789abcdef","message_id":4,"part_id":0,"delta":"hi","offset":3}`
    v := decoder_init(input, context.temp_allocator)

    data, derr := broadcast_data_from_reader(.Message_Part_Delta, &v)
    testing.expect(t, derr == .None, "decode should succeed")
    pd, ok := data.(Message_Part_Delta_Data)
    testing.expect(t, ok, "should be message.part_delta")
    testing.expect_value(t, Part_Delta(pd).delta, "hi")
    testing.expect_value(t, Part_Delta(pd).offset, u64(3))

    // Live droppable: no durable seq.
    _, has_seq := broadcast_data_seq(data).?
    testing.expect(t, !has_seq, "part_delta is not durable")

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    broadcast_data_emit(&e, data)
    testing.expect_value(t, to_string(&e), input)
}

@(test)
test_tool_output_delta_roundtrip :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)
    input := `{"session_id":"0123456789abcdef","message_id":12,"part_id":1,"delta":"hi","offset":3}`
    v := decoder_init(input, context.temp_allocator)

    data, derr := broadcast_data_from_reader(.Tool_Output_Delta, &v)
    testing.expect(t, derr == .None, "decode should succeed")
    od, ok := data.(Tool_Output_Delta_Data)
    testing.expect(t, ok, "should be tool.output_delta")
    testing.expect_value(t, Part_Delta(od).delta, "hi")
    sid, has_sid := broadcast_data_session_id(data).?
    testing.expect(t, has_sid, "tool.output_delta routes by session")
    _ = sid

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    broadcast_data_emit(&e, data)
    testing.expect_value(t, to_string(&e), input)
}

@(test)
test_config_changed_roundtrip :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)
    input := `{"session_id":"0123456789abcdef","seq":5,"config":{"config_rev":1,"model":"openai/gpt","reasoning":"low"}}`
    v := decoder_init(input, context.temp_allocator)

    data, derr := broadcast_data_from_reader(.Config_Changed, &v)
    testing.expect(t, derr == .None, "decode should succeed")
    cc, ok := data.(Config_Changed_Data)
    testing.expect(t, ok, "should be config.changed")
    testing.expect_value(t, cc.config.model, "openai/gpt")
    s, has_seq := broadcast_data_seq(data).?
    testing.expect(t, has_seq && u64(s) == 5, "config.changed is durable")

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    broadcast_data_emit(&e, data)
    testing.expect_value(t, to_string(&e), input)
}

@(test)
test_broadcast_notice_roundtrip :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)
    input := `{"level":"warn","source":"daemon","message":"rate limited"}`
    v := decoder_init(input, context.temp_allocator)

    data, derr := broadcast_data_from_reader(.Notice, &v)
    testing.expect(t, derr == .None, "decode should succeed")
    n, ok := data.(Notice)
    testing.expect(t, ok, "should be a notice")
    testing.expect_value(t, n.message, "rate limited")
    // Global: no session routing, no durable seq.
    _, has_sid := broadcast_data_session_id(data).?
    testing.expect(t, !has_sid, "notice has no session")

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    broadcast_data_emit(&e, data)
    testing.expect_value(t, to_string(&e), input)
}

@(test)
test_workspace_removed_roundtrip :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)
    input := `{"workspace_id":"aaaaaaaaaaaaaaaa"}`
    v := decoder_init(input, context.temp_allocator)

    data, derr := broadcast_data_from_reader(.Workspace_Removed, &v)
    testing.expect(t, derr == .None, "decode should succeed")
    _, ok := data.(Workspace_Removed_Data)
    testing.expect(t, ok, "should be workspace.removed")
    testing.expect(t, broadcast_data_validate(data) == .None, "valid workspace.removed")

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    broadcast_data_emit(&e, data)
    testing.expect_value(t, to_string(&e), input)
}

// The clone must outlive its decode arena. Tracked arenas turn a missed copy into a
// use-after-free and a missed free into a leak.
@(test)
test_broadcast_clone_outlives_source_delta :: proc(t: ^testing.T) {
    src_arena: mem.Dynamic_Arena
    mem.dynamic_arena_init(&src_arena, context.allocator, context.allocator)
    src := mem.dynamic_arena_allocator(&src_arena)

    dst_arena: mem.Dynamic_Arena
    mem.dynamic_arena_init(&dst_arena, context.allocator, context.allocator)
    dst := mem.dynamic_arena_allocator(&dst_arena)
    defer mem.dynamic_arena_destroy(&dst_arena)

    // `delta` is a borrowed string in the payload.
    input := `{"session_id":"0123456789abcdef","message_id":4,"part_id":0,"delta":"hi","offset":3}`
    d := decoder_init(input, src)
    data, derr := broadcast_data_from_reader(.Message_Part_Delta, &d)
    testing.expect(t, derr == .None, "decode should succeed")

    clone := notification_clone(notification_build(.Message_Part_Delta, data), dst)

    // Drop the decode arena; the clone must remain valid.
    mem.dynamic_arena_destroy(&src_arena)

    testing.expect_value(t, clone.method, Broadcast_Name.Message_Part_Delta)

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    broadcast_data_emit(&e, clone.params)
    testing.expect_value(t, to_string(&e), input)
}

// A nested payload exercises the transitive deep copy through session_clone.
@(test)
test_broadcast_clone_outlives_source_nested :: proc(t: ^testing.T) {
    src_arena: mem.Dynamic_Arena
    mem.dynamic_arena_init(&src_arena, context.allocator, context.allocator)
    src := mem.dynamic_arena_allocator(&src_arena)

    dst_arena: mem.Dynamic_Arena
    mem.dynamic_arena_init(&dst_arena, context.allocator, context.allocator)
    dst := mem.dynamic_arena_allocator(&dst_arena)
    defer mem.dynamic_arena_destroy(&dst_arena)

    input := `{"revision":4130,"session":{"id":"0123456789abcdef","workspace_id":"aaaaaaaaaaaaaaaa","profile":"default","model":"openai/gpt","reasoning":"low","config_rev":1,"permission":"normal","max_rounds":null,"title":"title","message_count":0,"created_at_ms":0,"updated_at_ms":0,"created_by":{"name":"yuke-tui","version":"0.1"},"origin":{"type":"root"}}}`
    d := decoder_init(input, src)
    data, derr := broadcast_data_from_reader(.Session_Summary_Changed, &d)
    testing.expect(t, derr == .None, "decode should succeed")

    clone := notification_clone(notification_build(.Session_Summary_Changed, data), dst)

    mem.dynamic_arena_destroy(&src_arena)

    testing.expect_value(t, clone.method, Broadcast_Name.Session_Summary_Changed)

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    broadcast_data_emit(&e, clone.params)
    testing.expect_value(t, to_string(&e), input)
}

// The part-level permission travels with `tool.state_changed` and must survive the clone
// that buffers a broadcast across a resync.
@(test)
test_tool_state_changed_permission_clone_outlives_source :: proc(t: ^testing.T) {
    src_arena: mem.Dynamic_Arena
    mem.dynamic_arena_init(&src_arena, context.allocator, context.allocator)
    src := mem.dynamic_arena_allocator(&src_arena)

    dst_arena: mem.Dynamic_Arena
    mem.dynamic_arena_init(&dst_arena, context.allocator, context.allocator)
    dst := mem.dynamic_arena_allocator(&dst_arena)
    defer mem.dynamic_arena_destroy(&dst_arena)

    input := `{"session_id":"0123456789abcdef","message_id":4,"part_id":0,"state":{"type":"waiting_permission"},"permission":{"requested_at_ms":7,"options":[{"id":"once","kind":"allow_once","label":"Allow once"}]}}`
    d := decoder_init(input, src)
    data, derr := broadcast_data_from_reader(.Tool_State_Changed, &d)
    testing.expect(t, derr == .None, "decode should succeed")
    testing.expect(t, broadcast_data_validate(data) == .None, "offered waiting must validate")

    clone := notification_clone(notification_build(.Tool_State_Changed, data), dst)

    // Drop the decode arena; the cloned permission must remain valid.
    mem.dynamic_arena_destroy(&src_arena)

    changed, is_changed := clone.params.(Tool_State_Changed_Data)
    testing.expect(t, is_changed, "payload is tool.state_changed")
    perm, has_perm := changed.permission_state.?
    testing.expect(t, has_perm, "cloned permission state is present")
    opts, has_opts := perm.options.?
    testing.expect(t, has_opts, "cloned options are present")
    testing.expect_value(t, opts[0].label, "Allow once")

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    broadcast_data_emit(&e, clone.params)
    testing.expect_value(t, to_string(&e), input)
}

// The payload carries the same state/permission pair a tool part does, under the same
// cross-field invariant.
@(test)
test_tool_state_changed_rejects_inconsistent_permission :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)

    offered := Permission_State {
        requested_at_ms = 1,
        options         = make([]Permission_Option, 0, context.temp_allocator),
    }
    data := Tool_State_Changed_Data {
        session_id = Session_Id(
            [16]u8{'0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f'},
        ),
        message_id = 4,
        part_id = 0,
        state = Tool_State_Running{started_at_ms = 2},
        permission_state = offered,
    }
    testing.expect(t, tool_state_changed_data_validate(data) == .Mismatched_Payload, "undecided running must fail")

    data.state = Tool_State_Waiting_Permission{}
    data.permission_state = nil
    testing.expect(
        t,
        tool_state_changed_data_validate(data) == .Mismatched_Payload,
        "waiting without permission must fail",
    )

    data.permission_state = offered
    testing.expect(t, tool_state_changed_data_validate(data) == .None, "offered waiting must validate")
}
