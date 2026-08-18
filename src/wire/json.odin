package wire

import "base:intrinsics"
import "core:crypto"
import "core:strconv"
import "core:strings"

import "libs:json"

// Emit a required-but-nullable JSON-number field: always writes the key, null when
// absent. Parapoly over the `distinct u64` id types so a `Maybe(Message_Id)` needs no
// cast at the call site.
field_required_null_u64 :: proc(e: ^Emitter, name: string, m: Maybe($T)) where intrinsics.type_is_integer(T) {
    key(e, name)

    if v, ok := m.?; ok {
        val_u64(e, u64(v))
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
// written first, one open container tracked per nesting level. A write the buffer
// could not grow for latches `failed`: the text is then truncated, so a caller that
// ships or persists it must consult `emitter_failed` first.
Emitter :: struct {
    sb:     strings.Builder,
    depth:  int,
    first:  [32]bool,
    failed: bool,
    secret: bool,
}

// Initialize an emitter over a fresh buffer.
emitter_init :: proc(e: ^Emitter, allocator := context.allocator) {
    e.sb = strings.builder_make(allocator)
    e.depth = 0
    e.failed = false
}

// Preallocate a secret-bearing emitter so growth never releases an old plaintext copy.
emitter_secret_init :: proc(e: ^Emitter, capacity: int, allocator := context.allocator) {
    assert(e != nil, "secret emitter init needs storage")
    assert(capacity > 0, "secret emitter capacity must be positive")

    e^ = {
        secret = true,
    }
    sb, aerr := strings.builder_make_len_cap(0, capacity, allocator)
    if aerr != nil {
        e.failed = true
        return
    }

    e.sb = sb
}

// Whether any write was truncated by a failed buffer growth. The accumulated text is
// then incomplete JSON and must not be sent or stored.
emitter_failed :: proc(e: ^Emitter) -> bool {
    assert(e != nil, "the health check needs an emitter")

    return e.failed
}

// Append `s` verbatim, latching `failed` when the buffer could not take all of it.
@(private)
_put :: proc(e: ^Emitter, s: string) {
    n := strings.write_string(&e.sb, s)

    if n != len(s) {
        e.failed = true
    }
}

// Append one byte, latching `failed` when the buffer could not take it.
@(private)
_put_byte :: proc(e: ^Emitter, c: byte) {
    n := strings.write_byte(&e.sb, c)

    if n != 1 {
        e.failed = true
    }
}

// Release the emitter's buffer, explicitly wiping it when it carried a secret.
emitter_destroy :: proc(e: ^Emitter) {
    assert(e != nil, "emitter cleanup needs storage")

    if e.secret && cap(e.sb.buf) > 0 {
        crypto.zero_explicit(raw_data(e.sb.buf), cap(e.sb.buf))
    }
    strings.builder_destroy(&e.sb)
    e^ = {}
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
        _put_byte(e, ',')
    } else {
        e.first[e.depth - 1] = false
    }
}

// Open a JSON object.
object_begin :: proc(e: ^Emitter) {
    assert(e.depth < len(e.first), "json emitter nesting too deep")
    _put_byte(e, '{')
    e.first[e.depth] = true
    e.depth += 1
}

// Close a JSON object.
object_end :: proc(e: ^Emitter) {
    e.depth -= 1
    _put_byte(e, '}')
}

// Open a JSON array.
array_begin :: proc(e: ^Emitter) {
    assert(e.depth < len(e.first), "json emitter nesting too deep")
    _put_byte(e, '[')
    e.first[e.depth] = true
    e.depth += 1
}

// Close a JSON array.
array_end :: proc(e: ^Emitter) {
    e.depth -= 1
    _put_byte(e, ']')
}

// Write an object key. The following value writer supplies the value.
key :: proc(e: ^Emitter, name: string) {
    _sep(e)
    _write_json_string(e, name)
    _put_byte(e, ':')
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
    _put(e, strconv.write_uint(buf[:], n, 10))
}

// Write a bare i64 value (used for signed wire fields, e.g. cron UTC offsets).
val_i64 :: proc(e: ^Emitter, n: i64) {
    buf: [20]u8
    _put(e, strconv.write_int(buf[:], n, 10))
}

// Write a bare boolean value.
val_bool :: proc(e: ^Emitter, b: bool) {
    _put(e, b ? "true" : "false")
}

// Write a null value.
val_null :: proc(e: ^Emitter) {
    _put(e, "null")
}

// Splice an already-encoded JSON value in as the current value. The bytes are written
// verbatim, so they must be one complete value this emitter produced — it is what lets
// a payload be encoded once and reused inside its envelope.
val_raw :: proc(e: ^Emitter, json: string) {
    assert(len(json) > 0, "a spliced value is not empty")
    _put(e, json)
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

// Write a JSON string value; a failed builder growth latches `failed`.
@(private)
_write_json_string :: proc(e: ^Emitter, s: string) {
    _, err := json.write_string(strings.to_writer(&e.sb), s)

    if err != .None {
        e.failed = true
    }
}
