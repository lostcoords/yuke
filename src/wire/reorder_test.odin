package wire

// Member order is not significant in JSON (RFC 8259 §4). An open protocol will be
// spoken by daemons/clients we do not control — a Go map, a JS object, or a Rust
// `serde_json::Value` (whose default map SORTS keys, emitting `{jsonrpc,method,params}`
// as `{method,params}` after `id`, or `params` before `method`). The streaming decoder
// must therefore accept a discriminator, and any field typed by it, in any position. These frames are the
// same shapes as the round-trip tests, with their members permuted; every one must
// decode identically. See `dec_find_tag`.

import "core:testing"

// A tagged-union payload whose `type` is emitted last still decodes (Class 1).
@(test)
test_reorder_union_type_last :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    // content part: type after its data field
    {
        v := decoder_init(`{"text":"hello","type":"text"}`, context.temp_allocator)
        part, derr := content_part_from_reader(&v)
        testing.expect(t, derr == .None, "type-last content part should decode")
        ct, ok := part.(Content_Text)
        testing.expect(t, ok, "should be a text part")
        testing.expect_value(t, ct.text, "hello")
    }

    // media source: blob with every field ahead of the discriminator
    {
        input := `{"bytes":1024,"mime":"image/png","hash":"2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824","type":"blob"}`
        v := decoder_init(input, context.temp_allocator)
        src, derr := media_source_from_reader(&v)
        testing.expect(t, derr == .None, "type-last media blob should decode")
        mb, ok := src.(Media_Blob)
        testing.expect(t, ok, "should be a blob source")
        testing.expect_value(t, u64(mb.bytes), u64(1024))
    }
}

// A request whose `params` precede `method` (which precedes `id`, `jsonrpc` last)
// still decodes: `method` is resolved before `params` is typed (Class 2).
@(test)
test_reorder_request_params_before_method :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)
    input := `{"params":{"session_id":"0011223344556677","input_id":7},"method":"session.cancel_input","id":2,"jsonrpc":"2.0"}`

    v := decoder_init(input, context.temp_allocator)
    req, derr := request_from_reader(&v)
    testing.expect(t, derr == .None, "params-before-method request should decode")
    testing.expect_value(t, req.method, Method_Name.Session_Cancel_Input)
    testing.expect_value(t, string(req.id), "2")
    testing.expect(t, request_validate(req) == .None, "reordered request should validate")
}

// The serde `json!`/`Value` shape: keys sorted alphabetically, so `jsonrpc` and
// `method` trail `params`. Both the full decode and the tier-1 header scan must
// route it.
@(test)
test_reorder_notification_alphabetical :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)
    input := `{"params":{"level":"warn","source":"provider","message":"rate limited"},"method":"notice","jsonrpc":"2.0"}`

    v := decoder_init(input, context.temp_allocator)
    n, derr := notification_from_reader(&v)
    testing.expect(t, derr == .None, "params-before-method notification should decode")
    testing.expect_value(t, n.method, Broadcast_Name.Notice)

    h, herr := server_frame_header_stream(input, context.temp_allocator)
    testing.expect(t, herr == .None, "header scan should route a method-last frame")
    testing.expect_value(t, h.kind, Server_Frame_Kind.Notification)
    testing.expect_value(t, h.method, "notice")
}

// A response whose `result` precedes its `id`, with a nested result union whose own
// `type` is last. This is the worst case for the header scan: the discriminant is
// found before the routing key, so the scan must walk past the payload and still
// classify correctly.
@(test)
test_reorder_response_result_before_id :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)
    input := `{"result":{"input_id":8,"type":"queued"},"id":3,"jsonrpc":"2.0"}`

    v := decoder_init(input, context.temp_allocator)
    resp, derr := response_from_reader(.Session_Send_Input, &v)
    testing.expect(t, derr == .None, "result-before-id response should decode")
    ok, is_ok := resp.(Response_Ok)
    testing.expect(t, is_ok, "should be a success response")
    testing.expect_value(t, string(ok.id), "3")

    h, herr := server_frame_header_stream(input, context.temp_allocator)
    testing.expect(t, herr == .None, "header scan should route a result-before-id response")
    testing.expect_value(t, h.kind, Server_Frame_Kind.Response)
    testing.expect_value(t, string(h.id), "3")
}

// The same permutation on the error arm.
@(test)
test_reorder_response_error_before_id :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)
    input := `{"error":{"message":"busy","code":-31015},"id":4,"jsonrpc":"2.0"}`

    v := decoder_init(input, context.temp_allocator)
    resp, derr := response_from_reader(.Session_List, &v)
    testing.expect(t, derr == .None, "error-before-id response should decode")
    re, is_err := resp.(Response_Error)
    testing.expect(t, is_err, "should be an error response")
    testing.expect_value(t, re.error.code, Error_Code.Session_Busy)

    h, herr := server_frame_header_stream(input, context.temp_allocator)
    testing.expect(t, herr == .None, "header scan should route an error-before-id response")
    testing.expect_value(t, h.kind, Server_Frame_Kind.Error)
    testing.expect_value(t, string(h.id), "4")
}

// A missing discriminator is still an error — order-independence must not be read as
// "accept anything". A union with no `type`, and a request with no `method`, both fail.
@(test)
test_reorder_missing_discriminator_still_errors :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    v := decoder_init(`{"text":"hello"}`, context.temp_allocator)
    _, derr := content_part_from_reader(&v)
    testing.expect(t, derr != .None, "a union with no discriminator must be rejected")

    v2 := decoder_init(`{"jsonrpc":"2.0","id":2}`, context.temp_allocator)
    _, derr2 := request_from_reader(&v2)
    testing.expect(t, derr2 != .None, "a request with no method must be rejected")
}
