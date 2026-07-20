package wire

import "core:testing"

@(test)
test_request_roundtrip :: proc(t: ^testing.T) {
    input := `{"type":"request","id":2,"method":"session.cancel_input","params":{"session_id":"0011223344556677","input_id":7}}`
    v := decoder_init(input, context.temp_allocator)
    defer free_all(context.temp_allocator)

    req, derr := request_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    testing.expect_value(t, req.method, Method_Name.Session_Cancel_Input)
    testing.expect_value(t, u64(req.id), u64(2))
    testing.expect(t, request_validate(req) == .None, "request should validate")

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    request_emit(&e, req)
    testing.expect_value(t, to_string(&e), input)
}

@(test)
test_response_ok_roundtrip :: proc(t: ^testing.T) {
    input := `{"type":"response","id":3,"result":{"type":"queued","input_id":8}}`
    v := decoder_init(input, context.temp_allocator)
    defer free_all(context.temp_allocator)

    resp, derr := response_from_reader(.Session_Send_Input, &v)
    testing.expect(t, derr == .None, "decode should succeed")
    _, ok := resp.(Response_Ok)
    testing.expect(t, ok, "should be a success response")

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    response_emit(&e, resp)
    testing.expect_value(t, to_string(&e), input)
}

@(test)
test_response_error_roundtrip :: proc(t: ^testing.T) {
    input := `{"type":"error","id":4,"error":{"code":"session_busy","message":"busy"}}`
    v := decoder_init(input, context.temp_allocator)
    defer free_all(context.temp_allocator)

    resp, derr := response_from_reader(.Session_List, &v)
    testing.expect(t, derr == .None, "decode should succeed")
    re, ok := resp.(Response_Error)
    testing.expect(t, ok, "should be an error response")
    testing.expect_value(t, re.error.code, Error_Code.Session_Busy)
    testing.expect(t, response_validate(resp) == .None, "error response should validate")

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    response_emit(&e, resp)
    testing.expect_value(t, to_string(&e), input)
}

@(test)
test_broadcast_roundtrip :: proc(t: ^testing.T) {
    input := `{"type":"broadcast","name":"notice","data":{"level":"warn","source":"provider","message":"rate limited"}}`
    v := decoder_init(input, context.temp_allocator)
    defer free_all(context.temp_allocator)

    bc, derr := broadcast_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    testing.expect_value(t, bc.name, Broadcast_Name.Notice)

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    broadcast_emit(&e, bc)
    testing.expect_value(t, to_string(&e), input)
}

@(test)
test_server_frame_header_dispatch :: proc(t: ^testing.T) {
    {
        // The streaming header scan reads `type`+`id` and stops before the result
        // is ever materialized.
        h, err := server_frame_header_stream(`{"type":"response","id":9,"result":{}}`, context.temp_allocator)
        testing.expect(t, err == .None, "header parse should succeed")
        testing.expect_value(t, h.kind, Server_Frame_Kind.Response)
        testing.expect_value(t, u64(h.id), u64(9))
    }
    {
        // A broadcast's `name` is read without touching the (possibly huge) data.
        h, err := server_frame_header_stream(
            `{"type":"broadcast","name":"run.done","data":{}}`,
            context.temp_allocator,
        )
        testing.expect(t, err == .None, "header parse should succeed")
        testing.expect_value(t, h.kind, Server_Frame_Kind.Broadcast)
        testing.expect_value(t, h.name, "run.done")
    }
    free_all(context.temp_allocator)
}

@(test)
test_client_frame_request :: proc(t: ^testing.T) {
    input := `{"type":"request","id":1,"method":"catalog.refresh"}`
    v := decoder_init(input, context.temp_allocator)
    defer free_all(context.temp_allocator)

    cf, derr := client_frame_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    _, ok := cf.(Request)
    testing.expect(t, ok, "should be a request frame")

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    client_frame_emit(&e, cf)
    testing.expect_value(t, to_string(&e), input)
}
