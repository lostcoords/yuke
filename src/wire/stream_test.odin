package wire

import "core:testing"

@(private = "file")
u64_of :: proc(text: string) -> (u64, Validation_Error) {
    d := decoder_init(text, context.temp_allocator)

    return dec_u64(&d)
}

@(private = "file")
i64_of :: proc(text: string) -> (i64, Validation_Error) {
    d := decoder_init(text, context.temp_allocator)

    return dec_i64(&d)
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
