package json

import "core:io"
import "core:unicode/utf8"

// Write `s` as a JSON string value: raw UTF-8, escaping only what RFC 8259 requires,
// with invalid UTF-8 mapped to U+FFFD so the output stays well-formed.
write_string :: proc(w: io.Writer, s: string) -> (n: int, err: io.Error) {
    io.write_byte(w, '"', &n) or_return

    i := 0
    for i < len(s) {
        c := s[i]

        if c < 0x80 {
            switch c {
            case '"':
                io.write_string(w, "\\\"", &n) or_return

            case '\\':
                io.write_string(w, "\\\\", &n) or_return

            case '\n':
                io.write_string(w, "\\n", &n) or_return

            case '\r':
                io.write_string(w, "\\r", &n) or_return

            case '\t':
                io.write_string(w, "\\t", &n) or_return

            case '\b':
                io.write_string(w, "\\b", &n) or_return

            case '\f':
                io.write_string(w, "\\f", &n) or_return

            case:
                if c < 0x20 {
                    io.write_string(w, "\\u00", &n) or_return
                    io.write_byte(w, _hex_digit(c >> 4), &n) or_return
                    io.write_byte(w, _hex_digit(c & 0xf), &n) or_return
                } else {
                    io.write_byte(w, c, &n) or_return
                }
            }

            i += 1
            continue
        }

        // One-byte width == invalid UTF-8 (a real U+FFFD is three bytes).
        r, width := utf8.decode_rune_in_string(s[i:])
        if r == utf8.RUNE_ERROR && width == 1 {
            io.write_string(w, "�", &n) or_return
            i += 1
            continue
        }

        io.write_string(w, s[i:i + width], &n) or_return
        i += width
    }

    io.write_byte(w, '"', &n) or_return
    return n, .None
}

@(private)
_hex_digit :: proc(v: u8) -> u8 {
    return v < 10 ? '0' + v : 'a' + (v - 10)
}
