package provider

import "core:io"
import "core:strconv"

// Primitive JSON writers shared by every protocol request builder. Each maps an
// `io.Error` to `.Resource_Exhausted`; callers emit the surrounding structure.

// Write raw bytes verbatim, for pre-formed JSON fragments.
@(private)
json_write :: proc(writer: io.Writer, value: string) -> Transport_Error {
    io.write_string(writer, value)
    return .None
}

// Write one quoted, escaped JSON string.
@(private)
json_write_string :: proc(writer: io.Writer, value: string) -> Transport_Error {
    io.write_quoted_string(writer, value, '"', nil, true)
    return .None
}

// Write a non-negative integer.
@(private)
json_write_u64 :: proc(writer: io.Writer, value: u64) -> Transport_Error {
    io.write_u64(writer, value)
    return .None
}

// Write a finite float in shortest round-trip form. `'g'` with precision -1 is
// strconv's shortest exact encoding; a leading `+` is stripped for valid JSON.
@(private)
json_write_f64 :: proc(writer: io.Writer, value: f64) -> Transport_Error {
    buf: [386]byte
    encoded := strconv.write_float(buf[:], value, 'g', -1, 64)
    if len(encoded) > 0 && encoded[0] == '+' {
        encoded = encoded[1:]
    }

    io.write_string(writer, encoded)
    return .None
}
