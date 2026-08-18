package wire
import "libs:json"

import "core:testing"

@(private = "file")
u64_of :: proc(text: string) -> (u64, json.Decode_Error) {
    d := json.decoder_init(text, context.temp_allocator)

    return json.dec_u64(&d, MAX_WIRE_INTEGER)
}

@(private = "file")
i64_of :: proc(text: string) -> (i64, json.Decode_Error) {
    d := json.decoder_init(text, context.temp_allocator)

    return json.dec_i64(&d, MAX_WIRE_INTEGER)
}

@(private = "file")
f64_of :: proc(text: string) -> (f64, json.Decode_Error) {
    d := json.decoder_init(text, context.temp_allocator)

    return json.dec_f64(&d)
}

// These tokens wrap to small in-range values, so only the length guard rejects them.
@(test)
test_dec_u64_rejects_overflowing_tokens :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    wrapping := []string {
        "18446744073709551616", // 2^64      wraps to 0
        "18446744073709551617", // 2^64 + 1  wraps to 1
        "18446744073709551623", // 2^64 + 7  wraps to 7
        "36893488147419103232", // 2^65      wraps to 0
        "123456789012345678901234567890",
    }

    for text in wrapping {
        _, err := u64_of(text)
        testing.expectf(t, err == .Out_Of_Range, "%s must not decode as a wire integer", text)
    }
}

@(test)
test_dec_u64_range_boundary :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    value, err := u64_of("9007199254740991")
    testing.expect(t, err == .None, "MAX_WIRE_INTEGER decodes")
    testing.expect_value(t, value, u64(MAX_WIRE_INTEGER))

    // Same digit count, so the length guard passes and the range check rejects it.
    _, over := u64_of("9007199254740992")
    testing.expect(t, over == .Out_Of_Range, "one past MAX_WIRE_INTEGER is rejected")

    _, negative := u64_of("-1")
    testing.expect(t, negative == .Out_Of_Range, "a negative token is not a u64")
}

@(test)
test_dec_i64_rejects_overflowing_tokens :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    wrapping := []string{"18446744073709551617", "-18446744073709551617", "-123456789012345678901234567890"}

    for text in wrapping {
        _, err := i64_of(text)
        testing.expectf(t, err == .Out_Of_Range, "%s must not decode as a wire integer", text)
    }
}

@(test)
test_dec_i64_range_boundary :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    value, err := i64_of("-9007199254740991")
    testing.expect(t, err == .None, "-MAX_WIRE_INTEGER decodes")
    testing.expect_value(t, value, i64(-MAX_WIRE_INTEGER))

    // The sign costs one byte, so this clears the length guard and the range check rejects it.
    _, under := i64_of("-9007199254740992")
    testing.expect(t, under == .Out_Of_Range, "one past -MAX_WIRE_INTEGER is rejected")
}

// The integer arm widens through `parse_i64`, so it wraps like the others.
@(test)
test_dec_f64_rejects_overflowing_integer_tokens :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    wrapping := []string{"18446744073709551617", "36893488147419103232", "-18446744073709551617"}

    for text in wrapping {
        _, err := f64_of(text)
        testing.expectf(t, err == .Out_Of_Range, "%s must not decode as a number", text)
    }

    value, err := f64_of("7")
    testing.expect(t, err == .None, "an ordinary integer literal still widens")
    testing.expect_value(t, value, f64(7))
}

// An id that wraps onto a live pending id would correlate a response to the wrong
// request, which is exactly the peer alteration this proc exists to catch.
@(test)
test_req_id_to_u64_rejects_overflowing_tokens :: proc(t: ^testing.T) {
    wrapping := []string{"18446744073709551617", "18446744073709551616", "36893488147419103232"}

    for text in wrapping {
        _, ok := req_id_to_u64(Request_Id(text))
        testing.expectf(t, !ok, "%s must not correlate", text)
    }

    n, ok := req_id_to_u64(Request_Id("9007199254740991"))
    testing.expect(t, ok, "MAX_REQUEST_ID round-trips")
    testing.expect_value(t, n, u64(MAX_REQUEST_ID))
}
