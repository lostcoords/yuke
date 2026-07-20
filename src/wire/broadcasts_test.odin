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

    _, bad := broadcast_name_from_wire("unknown.broadcast")
    testing.expect(t, !bad, "unknown name must be rejected")

    // session.changed / run.canceled / run.failed no longer exist on the wire.
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
    input := `{"revision":4130,"session":{"id":"0123456789abcdef","workspace_id":"aaaaaaaaaaaaaaaa","profile":"default","model":"openai/gpt","reasoning":"low","config_rev":1,"permission":"normal","max_rounds":null,"title":"title","message_count":0,"updated_at_ms":0,"created_by":{"name":"yuke-tui","version":"0.1"},"origin":{"type":"root"}}}`
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

    clone := broadcast_clone(broadcast_build(.Message_Part_Delta, data), dst)

    // Drop the decode arena; the clone must remain valid.
    mem.dynamic_arena_destroy(&src_arena)

    testing.expect_value(t, clone.type, "broadcast")
    testing.expect_value(t, clone.name, Broadcast_Name.Message_Part_Delta)

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    broadcast_data_emit(&e, clone.data)
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

    input := `{"revision":4130,"session":{"id":"0123456789abcdef","workspace_id":"aaaaaaaaaaaaaaaa","profile":"default","model":"openai/gpt","reasoning":"low","config_rev":1,"permission":"normal","max_rounds":null,"title":"title","message_count":0,"updated_at_ms":0,"created_by":{"name":"yuke-tui","version":"0.1"},"origin":{"type":"root"}}}`
    d := decoder_init(input, src)
    data, derr := broadcast_data_from_reader(.Session_Summary_Changed, &d)
    testing.expect(t, derr == .None, "decode should succeed")

    clone := broadcast_clone(broadcast_build(.Session_Summary_Changed, data), dst)

    mem.dynamic_arena_destroy(&src_arena)

    testing.expect_value(t, clone.name, Broadcast_Name.Session_Summary_Changed)

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    broadcast_data_emit(&e, clone.data)
    testing.expect_value(t, to_string(&e), input)
}
