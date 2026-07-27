package wire

import "core:testing"

@(test)
test_error_code_roundtrip :: proc(t: ^testing.T) {
    testing.expect_value(t, error_code_to_number(.Session_Busy), i32(-31015))

    code, ok := error_code_from_number(-31002)
    testing.expect(t, ok, "known wire number should map back")
    testing.expect_value(t, code, Error_Code.Stale_Cursor)

    _, unknown := error_code_from_number(-31999)
    testing.expect(t, !unknown, "unknown wire number must not map")

    // The four codes that carry JSON-RPC's reserved values.
    testing.expect_value(t, error_code_to_number(.Bad_Protocol), i32(-32600))
    testing.expect_value(t, error_code_to_number(.Unknown_Method), i32(-32601))
    testing.expect_value(t, error_code_to_number(.Bad_Request), i32(-32602))
    testing.expect_value(t, error_code_to_number(.Internal), i32(-32603))

    testing.expect_value(t, error_code_to_name(.Overloaded), "overloaded")
}

@(test)
test_run_error_code_roundtrip :: proc(t: ^testing.T) {
    testing.expect_value(t, run_error_code_to_wire(.Quota_Exhausted), "quota_exhausted")

    code, ok := run_error_code_from_wire("context_overflow")
    testing.expect(t, ok, "known run error code should map back")
    testing.expect_value(t, code, Run_Error_Code.Context_Overflow)
}

@(test)
test_error_object_validate :: proc(t: ^testing.T) {
    ok := Error_Object {
        code    = .Bad_Request,
        message = "bad",
    }
    testing.expect(t, error_object_validate(ok) == .None, "short message is within bound")
}

@(test)
test_parse_rejects_trailing_bytes :: proc(t: ^testing.T) {
    // A frame is exactly one JSON value; a second value or junk after the root is
    // rejected rather than silently dropped (dec_finish asserts end-of-input).
    defer free_all(context.temp_allocator)
    {
        d := decoder_init(`{"jsonrpc":"2.0"}{"jsonrpc":"2.0"}`, context.temp_allocator)
        _ = dec_skip(&d)
        testing.expect(t, dec_finish(&d) == .Bad_Frame_Type, "trailing value must be rejected")
    }
    {
        d := decoder_init(`{"jsonrpc":"2.0"} garbage`, context.temp_allocator)
        _ = dec_skip(&d)
        testing.expect(t, dec_finish(&d) == .Bad_Frame_Type, "trailing junk must be rejected")
    }
    {
        d := decoder_init(`{"jsonrpc":"2.0"}`, context.temp_allocator)
        testing.expect(t, dec_skip(&d) == .None, "a single well-formed value still parses")
        testing.expect(t, dec_finish(&d) == .None, "single value has no trailing bytes")
    }
}
