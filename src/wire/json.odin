package wire

import "core:strconv"
import "core:strings"

// JSON encode back end: a discriminator-first `Emitter` and the field writers used
// by every `*_emit`. Decoding is streaming and token-based (see stream.odin);
// nothing here builds or parses a value tree.

// Emit a required-but-nullable u64 field: always writes the key, null when absent.
field_required_null_u64 :: proc(e: ^Emitter, name: string, m: Maybe(u64)) {
    key(e, name)

    if v, ok := m.?; ok {
        val_u64(e, v)
    } else {
        val_null(e)
    }
}

// Emit a required-but-nullable string field: always writes the key, null when absent.
field_required_null_string :: proc(e: ^Emitter, name: string, m: Maybe(string)) {
    key(e, name)

    if v, ok := m.?; ok {
        val_string(e, v)
    } else {
        val_null(e)
    }
}

// Encode back end. Builds JSON into a growable buffer with the discriminator
// written first, one open container tracked per nesting level.
Emitter :: struct {
    sb:    strings.Builder,
    depth: int,
    first: [32]bool,
}

// Initialize an emitter over a fresh buffer.
emitter_init :: proc(e: ^Emitter, allocator := context.allocator) {
    e.sb = strings.builder_make(allocator)
    e.depth = 0
}

// Release the emitter's buffer.
emitter_destroy :: proc(e: ^Emitter) {
    strings.builder_destroy(&e.sb)
}

// The accumulated JSON text (valid until the emitter is destroyed).
to_string :: proc(e: ^Emitter) -> string {
    return strings.to_string(e.sb)
}

// Write the element/key separator for the current container, if one is needed.
@(private)
_sep :: proc(e: ^Emitter) {
    if e.depth == 0 {
        return
    }

    if !e.first[e.depth - 1] {
        strings.write_byte(&e.sb, ',')
    } else {
        e.first[e.depth - 1] = false
    }
}

// Open a JSON object.
object_begin :: proc(e: ^Emitter) {
    assert(e.depth < len(e.first), "json emitter nesting too deep")
    strings.write_byte(&e.sb, '{')
    e.first[e.depth] = true
    e.depth += 1
}

// Close a JSON object.
object_end :: proc(e: ^Emitter) {
    e.depth -= 1
    strings.write_byte(&e.sb, '}')
}

// Open a JSON array.
array_begin :: proc(e: ^Emitter) {
    assert(e.depth < len(e.first), "json emitter nesting too deep")
    strings.write_byte(&e.sb, '[')
    e.first[e.depth] = true
    e.depth += 1
}

// Close a JSON array.
array_end :: proc(e: ^Emitter) {
    e.depth -= 1
    strings.write_byte(&e.sb, ']')
}

// Write an object key. The following value writer supplies the value.
key :: proc(e: ^Emitter, name: string) {
    _sep(e)
    _write_json_string(e, name)
    strings.write_byte(&e.sb, ':')
}

// Open the next array element.
elem :: proc(e: ^Emitter) {
    _sep(e)
}

// Write a bare string value.
val_string :: proc(e: ^Emitter, s: string) {
    _write_json_string(e, s)
}

// Write a bare u64 value.
val_u64 :: proc(e: ^Emitter, n: u64) {
    buf: [20]u8
    strings.write_string(&e.sb, strconv.write_uint(buf[:], n, 10))
}

// Write a bare i64 value (used for signed wire fields, e.g. cron UTC offsets).
val_i64 :: proc(e: ^Emitter, n: i64) {
    buf: [20]u8
    strings.write_string(&e.sb, strconv.write_int(buf[:], n, 10))
}

// Write a bare boolean value.
val_bool :: proc(e: ^Emitter, b: bool) {
    strings.write_string(&e.sb, b ? "true" : "false")
}

// Write a null value.
val_null :: proc(e: ^Emitter) {
    strings.write_string(&e.sb, "null")
}

// Write a `name: string` object field.
field_string :: proc(e: ^Emitter, name: string, s: string) {
    key(e, name)
    val_string(e, s)
}

// Write a `name: u64` object field.
field_u64 :: proc(e: ^Emitter, name: string, n: u64) {
    key(e, name)
    val_u64(e, n)
}

// Write a `name: i64` object field.
field_i64 :: proc(e: ^Emitter, name: string, n: i64) {
    key(e, name)
    val_i64(e, n)
}

// Write a `name: hex-id` object field from a fixed byte array (id or content hash).
// Copies to a local so the array is addressable when viewed as a string.
field_id :: proc(e: ^Emitter, name: string, id: [$N]u8) {
    b := id
    field_string(e, name, string(b[:]))
}

// Write a bare fixed-byte id/hash value (for array elements).
val_id :: proc(e: ^Emitter, id: [$N]u8) {
    b := id
    val_string(e, string(b[:]))
}

// Write a `name: bool` object field.
field_bool :: proc(e: ^Emitter, name: string, b: bool) {
    key(e, name)
    val_bool(e, b)
}

// Write a `name: string` object field only when the value is present.
field_string_opt :: proc(e: ^Emitter, name: string, m: Maybe(string)) {
    if v, ok := m.?; ok {
        field_string(e, name, v)
    }
}

// Write a JSON string literal with the required escapes.
@(private)
_write_json_string :: proc(e: ^Emitter, s: string) {
    strings.write_byte(&e.sb, '"')
    for i in 0 ..< len(s) {
        c := s[i]

        switch c {
        case '"':
            strings.write_string(&e.sb, "\\\"")

        case '\\':
            strings.write_string(&e.sb, "\\\\")

        case '\n':
            strings.write_string(&e.sb, "\\n")

        case '\r':
            strings.write_string(&e.sb, "\\r")

        case '\t':
            strings.write_string(&e.sb, "\\t")

        case '\b':
            strings.write_string(&e.sb, "\\b")

        case '\f':
            strings.write_string(&e.sb, "\\f")

        case:
            if c < 0x20 {
                strings.write_string(&e.sb, "\\u00")
                strings.write_byte(&e.sb, _hex_digit(c >> 4))
                strings.write_byte(&e.sb, _hex_digit(c & 0xf))
            } else {
                strings.write_byte(&e.sb, c)
            }
        }
    }

    strings.write_byte(&e.sb, '"')
}

@(private)
_hex_digit :: proc(n: u8) -> u8 {
    return n < 10 ? '0' + n : 'a' + (n - 10)
}
