package wire

// Member order is not significant in JSON (RFC 8259 §4). An open protocol will be
// spoken by daemons/clients we do not control — a Go map, a JS object, or a Rust
// `serde_json::Value` (whose default map SORTS keys, emitting `{data,name,type}`
// with the discriminator LAST). The streaming decoder must therefore accept the
// discriminator, and any field typed by it, in any position. These frames are the
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

// A request whose `params` precede `method` (which precedes `id`, `type` last) still
// decodes: `method` is resolved before `params` is typed (Class 2).
@(test)
test_reorder_request_params_before_method :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)
    input := `{"params":{"session_id":"0011223344556677","input_id":7},"method":"session.cancel_input","id":2,"type":"request"}`

    v := decoder_init(input, context.temp_allocator)
    req, derr := request_from_reader(&v)
    testing.expect(t, derr == .None, "params-before-method request should decode")
    testing.expect_value(t, req.method, Method_Name.Session_Cancel_Input)
    testing.expect_value(t, u64(req.id), u64(2))
    testing.expect(t, request_validate(req) == .None, "reordered request should validate")

    // same frame through the client-frame entry point
    v2 := decoder_init(input, context.temp_allocator)
    cf, derr2 := client_frame_from_reader(&v2)
    testing.expect(t, derr2 == .None, "client frame should decode reordered request")
    r, ok := cf.(Request)
    testing.expect(t, ok, "should be a request frame")
    testing.expect_value(t, r.method, Method_Name.Session_Cancel_Input)
}

// The serde `json!`/`Value` shape: keys sorted alphabetically, so `data` comes first
// and `type` last. Both the full decode and the tier-1 header scan must route it.
@(test)
test_reorder_broadcast_alphabetical :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)
    input := `{"data":{"level":"warn","source":"provider","message":"rate limited"},"name":"notice","type":"broadcast"}`

    v := decoder_init(input, context.temp_allocator)
    bc, derr := broadcast_from_reader(&v)
    testing.expect(t, derr == .None, "data-before-name broadcast should decode")
    testing.expect_value(t, bc.name, Broadcast_Name.Notice)

    h, herr := server_frame_header_stream(input, context.temp_allocator)
    testing.expect(t, herr == .None, "header scan should route a discriminator-last frame")
    testing.expect_value(t, h.kind, Server_Frame_Kind.Broadcast)
    testing.expect_value(t, h.name, "notice")
}

// A response whose `type` is last, with a nested result union whose own `type` is also
// last, still decodes (order-independence composes through nesting).
@(test)
test_reorder_response_type_last :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)
    input := `{"id":3,"result":{"input_id":8,"type":"queued"},"type":"response"}`

    v := decoder_init(input, context.temp_allocator)
    resp, derr := response_from_reader(.Session_Send_Input, &v)
    testing.expect(t, derr == .None, "type-last response with type-last result should decode")
    _, ok := resp.(Response_Ok)
    testing.expect(t, ok, "should be a success response")

    h, herr := server_frame_header_stream(input, context.temp_allocator)
    testing.expect(t, herr == .None, "header scan should route a discriminator-last response")
    testing.expect_value(t, h.kind, Server_Frame_Kind.Response)
    testing.expect_value(t, u64(h.id), u64(3))
}

// A missing discriminator is still an error — order-independence must not be read as
// "accept anything". A union with no `type`, and a request with no `method`, both fail.
@(test)
test_reorder_missing_discriminator_still_errors :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    v := decoder_init(`{"text":"hello"}`, context.temp_allocator)
    _, derr := content_part_from_reader(&v)
    testing.expect(t, derr != .None, "a union with no discriminator must be rejected")

    v2 := decoder_init(`{"type":"request","id":2}`, context.temp_allocator)
    _, derr2 := request_from_reader(&v2)
    testing.expect(t, derr2 != .None, "a request with no method must be rejected")

}
