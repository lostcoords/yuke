package wire

import "core:strings"
import "core:testing"

@(test)
test_client_hello_accepts_valid_bounds :: proc(t: ^testing.T) {
    h := client_hello_build({name = "yuke-tui", version = "0.0.1"})
    testing.expect(t, client_hello_validate(h) == .None, "valid hello should validate")
}

@(test)
test_client_hello_rejects_bad_type :: proc(t: ^testing.T) {
    h := client_hello_build({name = "yuke-tui", version = "0.0.1"})
    h.type = "hello"
    testing.expect(t, client_hello_validate(h) == .Bad_Frame_Type, "bad type must be rejected")
}

@(test)
test_client_hello_rejects_wrong_protocol :: proc(t: ^testing.T) {
    h := client_hello_build({name = "yuke-tui", version = "0.0.1"})
    h.protocol = 0
    testing.expect(t, client_hello_validate(h) == .Unsupported_Protocol, "wrong protocol must be rejected")
}

@(test)
test_client_hello_rejects_oversized_client_fields :: proc(t: ^testing.T) {
    long_name := strings.repeat("n", 65, context.temp_allocator)
    long_version := strings.repeat("v", 33, context.temp_allocator)
    defer free_all(context.temp_allocator)

    bad_name := client_hello_build({name = long_name, version = "0.0.1"})
    testing.expect(t, client_hello_validate(bad_name) == .Overflow, "oversized name must overflow")

    bad_version := client_hello_build({name = "yuke-tui", version = long_version})
    testing.expect(t, client_hello_validate(bad_version) == .Overflow, "oversized version must overflow")
}

@(test)
test_client_hello_roundtrip :: proc(t: ^testing.T) {
    input := `{"type":"client.hello","protocol":1,"client":{"name":"yuke-tui","version":"0.0.1"}}`
    d := decoder_init(input, context.temp_allocator)
    defer free_all(context.temp_allocator)

    h, derr := client_hello_from_reader(&d)
    testing.expect(t, derr == .None, "decode should succeed")
    testing.expect_value(t, h.type, "client.hello")
    testing.expect_value(t, h.protocol, u32(1))
    testing.expect_value(t, h.client.name, "yuke-tui")
    testing.expect_value(t, h.client.version, "0.0.1")

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    client_hello_emit(&e, h)
    testing.expect_value(t, to_string(&e), input)
}

@(test)
test_client_hello_from_reader_defaults :: proc(t: ^testing.T) {
    input := `{"client":{"name":"yuke-tui","version":"0.0.1"}}`
    d := decoder_init(input, context.temp_allocator)
    defer free_all(context.temp_allocator)

    h, derr := client_hello_from_reader(&d)
    testing.expect(t, derr == .None, "decode should succeed")
    testing.expect_value(t, h.type, "client.hello")
    testing.expect_value(t, h.protocol, u32(PROTOCOL_VERSION))
}
