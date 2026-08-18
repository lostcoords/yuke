package json

import "core:io"
import "core:strconv"

// Write a pre-formed JSON fragment verbatim.
write_raw :: proc(w: io.Writer, value: string) -> (n: int, err: io.Error) {
    return io.write_string(w, value)
}

// Write a non-negative integer.
write_u64 :: proc(w: io.Writer, value: u64) -> (n: int, err: io.Error) {
    return io.write_u64(w, value)
}

// Shortest round-trip float; strconv's leading `+` on positives is stripped for JSON.
write_f64 :: proc(w: io.Writer, value: f64) -> (n: int, err: io.Error) {
    // 384 (Decimal's max digits) + sign + point; write_float truncates a short buf.
    buf: [386]byte
    encoded := strconv.write_float(buf[:], value, 'g', -1, 64)
    if len(encoded) > 0 && encoded[0] == '+' {
        encoded = encoded[1:]
    }

    return io.write_string(w, encoded)
}
