package wire

import "core:testing"

@(test)
test_error_code_roundtrip :: proc(t: ^testing.T) {
    testing.expect_value(t, error_code_to_wire(.Session_Busy), "session_busy")

    code, ok := error_code_from_wire("stale_cursor")
    testing.expect(t, ok, "known wire code should map back")
    testing.expect_value(t, code, Error_Code.Stale_Cursor)

    _, unknown := error_code_from_wire("not_a_real_code")
    testing.expect(t, !unknown, "unknown wire code must not map")
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
        d := decoder_init(`{"type":"request"}{"type":"request"}`, context.temp_allocator)
        _ = dec_skip(&d)
        testing.expect(t, dec_finish(&d) == .Bad_Frame_Type, "trailing value must be rejected")
    }
    {
        d := decoder_init(`{"type":"request"} garbage`, context.temp_allocator)
        _ = dec_skip(&d)
        testing.expect(t, dec_finish(&d) == .Bad_Frame_Type, "trailing junk must be rejected")
    }
    {
        d := decoder_init(`{"type":"request"}`, context.temp_allocator)
        testing.expect(t, dec_skip(&d) == .None, "a single well-formed value still parses")
        testing.expect(t, dec_finish(&d) == .None, "single value has no trailing bytes")
    }
}
