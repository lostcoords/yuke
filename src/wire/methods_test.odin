package wire

import "core:testing"

@(test)
test_method_name_wire_roundtrip :: proc(t: ^testing.T) {
    cases := []struct {
        method: Method_Name,
        wire:   string,
    } {
        {.Session_List, "session.list"},
        {.Session_Send_Input, "session.send_input"},
        {.Permission_Decide, "permission.decide"},
        {.Cron_Run_Now, "cron.run_now"},
    }
    for c in cases {
        testing.expect_value(t, method_name_to_wire(c.method), c.wire)
        m, ok := method_name_from_wire(c.wire)
        testing.expect(t, ok, "known wire string should map back")
        testing.expect_value(t, m, c.method)
    }

    // A dotted wire string resolves to its variant.
    dotted, dotted_ok := method_name_from_wire("session.list")
    testing.expect(t, dotted_ok, "dotted name should be known")
    testing.expect_value(t, dotted, Method_Name.Session_List)

    // An unknown wire string is rejected.
    _, unknown_ok := method_name_from_wire("unknown.method")
    testing.expect(t, !unknown_ok, "unknown method must be rejected")
}

@(test)
test_request_params_cancel_input_roundtrip :: proc(t: ^testing.T) {
    input := `{"session_id":"0123456789abcdef","input_id":7}`
    v := decoder_init(input, context.temp_allocator)
    defer free_all(context.temp_allocator)

    params, derr := request_params_from_reader(.Session_Cancel_Input, &v)
    testing.expect(t, derr == .None, "decode should succeed")
    cp, ok := params.(Session_Cancel_Input_Params)
    testing.expect(t, ok, "should be cancel_input params")
    testing.expect_value(t, u64(cp.input_id), u64(7))
    testing.expect(t, request_params_validate(params) == .None, "valid params")

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    request_params_emit(&e, params)
    testing.expect_value(t, to_string(&e), input)
}

@(test)
test_request_params_catalog_refresh_empty :: proc(t: ^testing.T) {
    input := `{}`
    v := decoder_init(input, context.temp_allocator)
    defer free_all(context.temp_allocator)

    params, derr := request_params_from_reader(.Catalog_Refresh, &v)
    testing.expect(t, derr == .None, "decode should succeed")
    _, ok := params.(Empty)
    testing.expect(t, ok, "should be empty params")
    testing.expect(t, params_are_default(params), "empty params are the default")

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    request_params_emit(&e, params)
    testing.expect_value(t, to_string(&e), input)
}

@(test)
test_response_result_remove_empty :: proc(t: ^testing.T) {
    input := `{}`
    v := decoder_init(input, context.temp_allocator)
    defer free_all(context.temp_allocator)

    result, derr := response_result_from_reader(.Session_Remove, &v)
    testing.expect(t, derr == .None, "decode should succeed")
    _, ok := result.(Empty)
    testing.expect(t, ok, "should be empty result")

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    response_result_emit(&e, result)
    testing.expect_value(t, to_string(&e), input)
}

@(test)
test_response_result_send_input_queued_roundtrip :: proc(t: ^testing.T) {
    input := `{"type":"queued","input_id":8}`
    v := decoder_init(input, context.temp_allocator)
    defer free_all(context.temp_allocator)

    result, derr := response_result_from_reader(.Session_Send_Input, &v)
    testing.expect(t, derr == .None, "decode should succeed")
    sr, ok := result.(Session_Send_Input_Result)
    testing.expect(t, ok, "should be a send_input result")
    queued, is_queued := sr.(Session_Send_Input_Result_Queued)
    testing.expect(t, is_queued, "should be queued")
    testing.expect_value(t, u64(queued.input_id), u64(8))

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    response_result_emit(&e, result)
    testing.expect_value(t, to_string(&e), input)
}
