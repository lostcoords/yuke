package wire

import "core:testing"

@(test)
test_tool_state_parses_pending :: proc(t: ^testing.T) {
    v := decoder_init(`{"type":"pending"}`, context.temp_allocator)
    defer free_all(context.temp_allocator)

    state, derr := tool_state_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    _, ok := state.(Tool_State_Pending)
    testing.expect(t, ok, "should be a pending state")
}

@(test)
test_tool_state_parses_completed :: proc(t: ^testing.T) {
    v := decoder_init(`{"type":"completed","output":"done","duration_ms":42}`, context.temp_allocator)
    defer free_all(context.temp_allocator)

    state, derr := tool_state_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    completed, ok := state.(Tool_State_Completed)
    testing.expect(t, ok, "should be a completed state")
    testing.expect_value(t, completed.output, "done")
    testing.expect_value(t, completed.duration_ms, u64(42))
}

@(test)
test_tool_state_running_output_present_and_absent :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)

    // Present in a resync snapshot: output parses and round-trips.
    {
        v := decoder_init(`{"type":"running","started_at_ms":5,"output":"compiling"}`)
        state, derr := tool_state_from_reader(&v)
        testing.expect(t, derr == .None, "decode should succeed")
        running, ok := state.(Tool_State_Running)
        testing.expect(t, ok, "should be a running state")
        out, has_out := running.output.?
        testing.expect(t, has_out, "output should be present")
        testing.expect_value(t, out, "compiling")

        e: Emitter
        emitter_init(&e)
        defer emitter_destroy(&e)
        tool_state_emit(&e, state)
        testing.expect_value(t, to_string(&e), `{"type":"running","started_at_ms":5,"output":"compiling"}`)
    }

    // Absent in a live transition: none is emitted.
    {
        e: Emitter
        emitter_init(&e)
        defer emitter_destroy(&e)
        tool_state_emit(&e, Tool_State_Running{started_at_ms = 5})
        testing.expect_value(t, to_string(&e), `{"type":"running","started_at_ms":5}`)
    }
}

@(test)
test_user_message_time_has_no_completed_at_ms :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)

    input := `{"type":"user","id":1,"content":[{"type":"text","text":"hi"}],"input_id":5,"time":{"created_at_ms":1700000000000}}`
    v := decoder_init(input)

    msg, derr := message_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    message_emit(&e, msg)
    testing.expect_value(t, to_string(&e), input)
}

@(test)
test_message_parses_user :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)

    v := decoder_init(
        `{"type":"user","id":1,"content":[{"type":"text","text":"hi"}],"input_id":5,"time":{"created_at_ms":1700000000000}}`,
    )

    msg, derr := message_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    user, ok := msg.(User_Message)
    testing.expect(t, ok, "should be a user message")
    testing.expect_value(t, user.id, Message_Id(1))
    testing.expect_value(t, len(user.content), 1)
}

@(test)
test_message_assistant_roundtrip :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)

    input := `{"type":"assistant","id":2,"run_id":1,"config_rev":0,"agent":"main","content":[{"type":"text","id":0,"text":"hello"}],"finish":"stop","time":{"created_at_ms":1700000000000}}`
    v := decoder_init(input)

    msg, derr := message_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    assistant, ok := msg.(Assistant_Message)
    testing.expect(t, ok, "should be an assistant message")
    testing.expect_value(t, assistant.id, Message_Id(2))
    testing.expect_value(t, len(assistant.content), 1)

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    message_emit(&e, msg)
    testing.expect_value(t, to_string(&e), input)
}

@(test)
test_message_user_reordered_fields :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)

    // The emitter writes the discriminator first for deterministic streaming output;
    // the decoder accepts it in any member position. The body fields
    // that follow may be in any order.
    v := decoder_init(
        `{"type":"user","time":{"created_at_ms":1700000000000},"content":[{"type":"text","text":"hi"}],"id":3,"input_id":7}`,
    )

    msg, derr := message_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    user, ok := msg.(User_Message)
    testing.expect(t, ok, "should be a user message")
    testing.expect_value(t, user.id, Message_Id(3))
    testing.expect_value(t, len(user.content), 1)
}

@(test)
test_message_parses_compaction :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)

    input := `{"type":"compaction","id":4,"run_id":1,"reason":"manual","summary":"summarized","first_kept_id":10,"tokens_before":1000,"tokens_after":500,"time":{"created_at_ms":1700000000000}}`
    v := decoder_init(input)

    msg, derr := message_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    compaction, ok := msg.(Compaction_Message)
    testing.expect(t, ok, "should be a compaction message")
    testing.expect_value(t, compaction.id, Message_Id(4))
    testing.expect_value(t, compaction.summary, "summarized")
    fk, has_fk := compaction.first_kept_id.?
    testing.expect(t, has_fk, "first_kept_id should be present")
    testing.expect_value(t, fk, Message_Id(10))

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    message_emit(&e, msg)
    testing.expect_value(t, to_string(&e), input)
}

@(test)
test_compaction_first_kept_id_null :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)

    input := `{"type":"compaction","id":4,"run_id":1,"reason":"auto","summary":"s","first_kept_id":null,"tokens_before":10,"tokens_after":5,"time":{"created_at_ms":1}}`
    v := decoder_init(input)

    msg, derr := message_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    compaction, ok := msg.(Compaction_Message)
    testing.expect(t, ok, "should be a compaction message")
    _, has_fk := compaction.first_kept_id.?
    testing.expect(t, !has_fk, "first_kept_id should be absent")

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    message_emit(&e, msg)
    testing.expect_value(t, to_string(&e), input)
}

@(test)
test_assistant_part_tool_roundtrip :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)

    input := `{"type":"tool","id":0,"call_id":"c1","name":"read","arguments":"{}","state":{"type":"pending"}}`
    v := decoder_init(input)

    part, derr := assistant_part_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    tool, ok := part.(Tool_Part)
    testing.expect(t, ok, "should be a tool part")
    testing.expect_value(t, tool.name, "read")
    testing.expect_value(t, u64(assistant_part_id(part)), u64(0))
    _, is_pending := tool.state.(Tool_State_Pending)
    testing.expect(t, is_pending, "state should be pending")

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    assistant_part_emit(&e, part)
    testing.expect_value(t, to_string(&e), input)
}

@(test)
test_assistant_part_sibling_field_rejected :: proc(t: ^testing.T) {
    v := decoder_init(`{"type":"text","id":0,"text":"hi","name":"x"}`, context.temp_allocator)
    defer free_all(context.temp_allocator)
    _, derr := assistant_part_from_reader(&v)
    testing.expect(t, derr == .Mismatched_Payload, "sibling key must be rejected")
}

@(test)
test_assistant_message_part_ordinal :: proc(t: ^testing.T) {
    // A part whose id disagrees with its content[] index is rejected.
    parts := []Assistant_Part{Text_Part{id = 3, text = "a"}}
    msg := Assistant_Message {
        id = 1,
        agent = "main",
        content = parts,
        finish = Stop_Reason.Stop,
        time = {created_at_ms = 1, completed_at_ms = 2},
    }
    testing.expect(t, assistant_message_validate(msg) == .Mismatched_Payload, "misordered part id must fail")

    // With the id matching the index it validates.
    parts[0] = Text_Part {
        id   = 0,
        text = "a",
    }
    testing.expect(t, assistant_message_validate_committed(msg) == .None, "aligned part id must pass")
}

@(test)
test_tool_state_permission_lifecycle :: proc(t: ^testing.T) {
    // waiting_permission with a decision already recorded is invalid.
    dec: Permission_Decision = Permission_Decision_Rule {
        rule_id        = Rule_Id(
            [16]u8{'0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f'},
        ),
        label          = "allow",
        resolved_at_ms = 2,
    }
    decided := Permission_State {
        requested_at_ms = 1,
        decision        = dec,
    }
    waiting: Tool_State = Tool_State_Waiting_Permission {
        permission_state = decided,
    }
    testing.expect(t, tool_state_validate(waiting) == .Mismatched_Payload, "decided waiting must fail")

    // running with options still offered (no decision) is invalid.
    opts := make([]Permission_Option, 0, context.temp_allocator)
    offered := Permission_State {
        requested_at_ms = 1,
        options         = opts,
    }
    running: Tool_State = Tool_State_Running {
        started_at_ms    = 2,
        permission_state = offered,
    }
    testing.expect(t, tool_state_validate(running) == .Mismatched_Payload, "undecided running must fail")
}

@(test)
test_tool_state_waiting_permission_roundtrip :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)

    input := `{"type":"waiting_permission","permission":{"requested_at_ms":1,"options":[{"id":"o1","kind":"allow_once","label":"Allow"}]}}`
    v := decoder_init(input)

    state, derr := tool_state_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    waiting, ok := state.(Tool_State_Waiting_Permission)
    testing.expect(t, ok, "should be a waiting_permission state")
    testing.expect_value(t, waiting.permission_state.requested_at_ms, u64(1))

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    tool_state_emit(&e, state)
    testing.expect_value(t, to_string(&e), input)
}

// Regression: cloning a source-less user message must keep `source` absent. Wrapping a
// bare (nil) `User_Message_Source` union into the `Maybe` field previously marked it
// present on cloned values.
@(test)
test_user_message_clone_preserves_absent_source :: proc(t: ^testing.T) {
    src := User_Message {
        id = 1,
        input_id = 1,
        content = []Content_Part{Content_Text{text = "hi"}},
        time = {created_at_ms = 1},
    }

    cloned := user_message_clone(src, context.temp_allocator)
    _, has_source := cloned.source.?
    testing.expect(t, !has_source, "cloned source must stay absent")
}
