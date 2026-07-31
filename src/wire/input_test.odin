package wire

import "core:testing"

@(test)
test_input_content_roundtrip :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)

    src := `{"type":"content","content":[{"type":"text","text":"hello"}]}`
    v := decoder_init(src, context.temp_allocator)

    input, derr := input_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    content, ok := input.(Input_Content)
    testing.expect(t, ok, "should be a content input")
    testing.expect_value(t, len(content.content), 1)

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    input_emit(&e, input)
    testing.expect_value(t, to_string(&e), src)
}

@(test)
test_input_skill_roundtrip :: proc(t: ^testing.T) {
    src := `{"type":"skill","name":"commit","arguments":"--all"}`
    v := decoder_init(src, context.temp_allocator)
    defer free_all(context.temp_allocator)

    input, derr := input_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    skill, ok := input.(Input_Skill)
    testing.expect(t, ok, "should be a skill input")
    testing.expect_value(t, skill.name, "commit")
    testing.expect_value(t, skill.arguments, "--all")

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    input_emit(&e, input)
    testing.expect_value(t, to_string(&e), src)
}

@(test)
test_send_input_result_started_queued :: proc(t: ^testing.T) {
    // Started carries the `type` discriminator first.
    {
        src := `{"type":"started","input_id":1,"run_id":2}`
        v := decoder_init(src, context.temp_allocator)
        defer free_all(context.temp_allocator)

        result, derr := session_send_input_result_from_reader(&v)
        testing.expect(t, derr == .None, "decode should succeed")
        started, ok := result.(Session_Send_Input_Result_Started)
        testing.expect(t, ok, "should be started")
        testing.expect_value(t, started.input_id, Input_Id(1))
        testing.expect_value(t, started.run_id, Run_Id(2))

        e: Emitter
        emitter_init(&e)
        defer emitter_destroy(&e)
        session_send_input_result_emit(&e, result)
        testing.expect_value(t, to_string(&e), src)
    }
    // Queued omits run_id.
    {
        src := `{"type":"queued","input_id":3}`
        v := decoder_init(src, context.temp_allocator)
        defer free_all(context.temp_allocator)

        result, derr := session_send_input_result_from_reader(&v)
        testing.expect(t, derr == .None, "decode should succeed")
        queued, ok := result.(Session_Send_Input_Result_Queued)
        testing.expect(t, ok, "should be queued")
        testing.expect_value(t, queued.input_id, Input_Id(3))

        e: Emitter
        emitter_init(&e)
        defer emitter_destroy(&e)
        session_send_input_result_emit(&e, result)
        testing.expect_value(t, to_string(&e), src)
    }
    // A sibling variant's run_id under `queued` is rejected.
    {
        v := decoder_init(`{"type":"queued","input_id":3,"run_id":4}`, context.temp_allocator)
        defer free_all(context.temp_allocator)
        _, derr := session_send_input_result_from_reader(&v)
        testing.expect(t, derr == .Mismatched_Payload, "sibling key must be rejected")
    }
}

@(test)
test_part_delta_roundtrip :: proc(t: ^testing.T) {
    src := `{"session_id":"0123456789abcdef","message_id":3,"part_id":0,"delta":"hello","offset":0}`
    v := decoder_init(src, context.temp_allocator)
    defer free_all(context.temp_allocator)

    pd, derr := part_delta_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    testing.expect_value(t, pd.message_id, Message_Id(3))
    testing.expect_value(t, pd.delta, "hello")
    testing.expect(t, part_delta_validate(pd) == .None, "valid session id")

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    part_delta_emit(&e, pd)
    testing.expect_value(t, to_string(&e), src)
}

@(test)
test_cancel_input_result_roundtrip :: proc(t: ^testing.T) {
    src := `{"canceled_input":7}`
    v := decoder_init(src, context.temp_allocator)
    defer free_all(context.temp_allocator)

    result, derr := session_cancel_input_result_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    testing.expect_value(t, result.canceled_input, Input_Id(7))

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    session_cancel_input_result_emit(&e, result)
    testing.expect_value(t, to_string(&e), src)
}

@(test)
test_cancel_run_result_roundtrip :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)

    src := `{"canceled_run":2,"cleared_inputs":[3,4],"cleared_compaction":5}`
    v := decoder_init(src, context.temp_allocator)

    result, derr := session_cancel_run_result_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    run, ok := result.canceled_run.?
    testing.expect(t, ok, "canceled_run present")
    testing.expect_value(t, run, Run_Id(2))
    testing.expect_value(t, len(result.cleared_inputs), 2)
    testing.expect_value(t, result.cleared_inputs[1], Input_Id(4))

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    session_cancel_run_result_emit(&e, result)
    testing.expect_value(t, to_string(&e), src)
}

@(test)
test_cancel_run_result_writes_absent_as_null :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)

    src := `{"canceled_run":null,"cleared_inputs":[],"cleared_compaction":null}`
    v := decoder_init(src, context.temp_allocator)

    result, derr := session_cancel_run_result_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    _, has_run := result.canceled_run.?
    testing.expect(t, !has_run, "canceled_run absent")

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    session_cancel_run_result_emit(&e, result)
    testing.expect_value(t, to_string(&e), src)
}

@(test)
test_cancel_run_rejects_wrong_presence :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)

    // run_id is optional, not nullable.
    v := decoder_init(`{"session_id":"0123456789abcdef","run_id":null}`)
    _, derr := session_cancel_run_params_from_reader(&v)
    testing.expect(t, derr != .None, "explicit null run_id must fail")

    // Both absent results are required members whose value may be null.
    v = decoder_init(`{"cleared_inputs":[]}`)
    _, derr = session_cancel_run_result_from_reader(&v)
    testing.expect(t, derr == .Mismatched_Payload, "omitted nullable result members must fail")
}
