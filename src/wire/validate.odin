package wire

// Validation helpers for annotated wire fields.

// Errors returned when parsed wire data violates the v1 contract.
Validation_Error :: enum {
    None,
    Bad_Frame_Type,
    Unsupported_Protocol,
    Overflow,
    Invalid_Length,
    Invalid_Hex,
    Out_Of_Range,
    Mismatched_Payload,
}

// Enforce `@bounded N` byte/element length.
enforce_bounded :: proc(max: int, value: string) -> Validation_Error {
    if len(value) > max {
        return .Overflow
    }

    return .None
}

// Enforce `@fixed N` byte length.
enforce_fixed :: proc(length: int, value: string) -> Validation_Error {
    if len(value) != length {
        return .Invalid_Length
    }

    return .None
}

// Enforce an optional/deferred `@fixed N` field where empty means absent.
enforce_fixed_optional :: proc(length: int, value: string) -> Validation_Error {
    if len(value) != 0 && len(value) != length {
        return .Invalid_Length
    }

    return .None
}

// Enforce a lowercase hexadecimal `@fixed N` byte string.
enforce_fixed_lower_hex :: proc(length: int, value: string) -> Validation_Error {
    enforce_fixed(length, value) or_return

    if !is_lower_hex(value) {
        return .Invalid_Hex
    }

    return .None
}

// Enforce a lowercase-hex `@fixed N` id held as a fixed byte array (id or content hash).
enforce_id :: proc(id: [$N]u8) -> Validation_Error {
    b := id

    return enforce_fixed_lower_hex(N, string(b[:]))
}

// Reverse lookup over an `[Enum]string` wire table: the enum value whose wire string
// equals `s`; `ok` is false for an unknown string. The forward direction is a direct
// index into `table`.
enum_from_wire :: proc(table: [$E]string, s: string) -> (E, bool) {
    for str, e in table {
        if str == s {
            return e, true
        }
    }

    return {}, false
}

// Reverse lookup for decode paths. Unknown enum strings are malformed payloads, so
// callers can propagate the result with the same `or_return` form as other readers.
enum_from_wire_checked :: proc(table: [$E]string, s: string) -> (out: E, err: Validation_Error) {
    value, ok := enum_from_wire(table, s)

    if !ok {
        return {}, .Mismatched_Payload
    }

    return value, .None
}

// Return whether every byte is an ASCII lowercase hexadecimal digit.
is_lower_hex :: proc(value: string) -> bool {
    for i in 0 ..< len(value) {
        if !is_lower_hex_byte(value[i]) {
            return false
        }
    }

    return true
}

// Return whether `c` is an ASCII lowercase hexadecimal digit.
is_lower_hex_byte :: proc(c: u8) -> bool {
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')
}
