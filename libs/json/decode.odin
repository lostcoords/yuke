package json

import "core:strconv"
import "core:strings"

// Result of a streaming decode primitive. Protocol-level validation (bounds, hex,
// cross-field) is a separate concern the caller layers on top.
Decode_Error :: enum {
    None,
    Bad_Frame_Type,
    Invalid_Length,
    Out_Of_Range,
    Mismatched_Payload,
}

// Streaming decode front end. A value is decoded token-by-token straight into typed
// structs; no intermediate `Value` tree is built. A multi-MB payload, or an ignored
// one, is streamed (or skipped, see `dec_skip`) rather than materialized. Tagged
// readers scan and rewind so members remain valid in any object order.
//
// Decoded strings are unquoted into the parser's allocator (the caller's arena), so
// results stay non-owning borrows into that arena until deep-copied.
Decoder :: Parser

// Start decoding `data`. Integers are kept as i64 (`parse_integers`).
decoder_init :: proc(data: string, allocator := context.allocator) -> Decoder {
    return make_parser_from_string(data, .JSON, true, allocator)
}

// Assert the input held exactly one JSON value: trailing bytes after the root are
// rejected rather than silently dropped.
dec_finish :: proc(d: ^Decoder) -> Decode_Error {
    if d.curr_token.kind != .EOF {
        return .Bad_Frame_Type
    }

    return .None
}

// A JSON string, unquoted into the parser allocator. A non-string is an error.
dec_string :: proc(d: ^Decoder) -> (string, Decode_Error) {
    tok := d.curr_token

    if tok.kind != .String {
        return "", .Mismatched_Payload
    }

    advance_token(d)
    s, err := unquote_string(tok, .JSON, d.allocator)

    if err != nil {
        return "", .Mismatched_Payload
    }

    return s, .None
}

// A scalar's verbatim token text, cloned into the parser allocator — quotes and
// escapes intact. Backs values that must echo byte-identically. A container is an error.
dec_raw_scalar :: proc(d: ^Decoder) -> (string, Decode_Error) {
    tok := d.curr_token

    #partial switch tok.kind {
    case .String, .Integer, .Float, .Null, .True, .False:
        advance_token(d)
        text, err := strings.clone(tok.text, d.allocator)

        if err != nil {
            return "", .Mismatched_Payload
        }

        return text, .None
    }

    return "", .Mismatched_Payload
}

// `parse_i64` wraps silently and still reports success, so an over-long token is
// rejected before the parse. 17 digits cannot wrap `i64`.
MAX_INTEGER_TOKEN_DIGITS :: 16

// A non-negative integer in `[0, max]`. A non-integer, an over-long token, or an
// over-range value (never a small coercion) is an error.
dec_u64 :: proc(d: ^Decoder, max: i64) -> (u64, Decode_Error) {
    tok := d.curr_token

    if tok.kind != .Integer {
        return 0, .Mismatched_Payload
    }

    if len(tok.text) > MAX_INTEGER_TOKEN_DIGITS {
        return 0, .Out_Of_Range
    }

    advance_token(d)
    i, ok := strconv.parse_i64(tok.text)
    if !ok do return 0, .Out_Of_Range

    if i < 0 || i > max do return 0, .Out_Of_Range
    return u64(i), .None
}

// A signed integer in `[-max, max]` (used for e.g. cron UTC offsets).
dec_i64 :: proc(d: ^Decoder, max: i64) -> (i64, Decode_Error) {
    tok := d.curr_token

    if tok.kind != .Integer {
        return 0, .Mismatched_Payload
    }

    // One byte wider than `dec_u64` for a leading `-`.
    if len(tok.text) > MAX_INTEGER_TOKEN_DIGITS + 1 {
        return 0, .Out_Of_Range
    }

    advance_token(d)
    i, ok := strconv.parse_i64(tok.text)

    if !ok {
        return 0, .Out_Of_Range
    }

    if i < -max || i > max {
        return 0, .Out_Of_Range
    }

    return i, .None
}

// A JSON number as f64 (an integer literal is accepted and widened). A non-number
// is an error.
dec_f64 :: proc(d: ^Decoder) -> (f64, Decode_Error) {
    tok := d.curr_token

    #partial switch tok.kind {
    case .Integer:
        if len(tok.text) > MAX_INTEGER_TOKEN_DIGITS + 1 {
            return 0, .Out_Of_Range
        }

        advance_token(d)
        i, ok := strconv.parse_i64(tok.text)

        if !ok {
            return 0, .Out_Of_Range
        }

        return f64(i), .None

    case .Float:
        advance_token(d)
        f, ok := strconv.parse_f64(tok.text)

        if !ok {
            return 0, .Mismatched_Payload
        }

        return f, .None
    }

    return 0, .Mismatched_Payload
}

// A boolean. A non-boolean is an error.
dec_bool :: proc(d: ^Decoder) -> (bool, Decode_Error) {
    #partial switch d.curr_token.kind {
    case .True:
        advance_token(d)
        return true, .None

    case .False:
        advance_token(d)
        return false, .None
    }

    return false, .Mismatched_Payload
}

// If the current value is JSON null, consume it and report true; otherwise leave it.
dec_is_null :: proc(d: ^Decoder) -> bool {
    if d.curr_token.kind == .Null {
        advance_token(d)
        return true
    }

    return false
}

// A fixed-length string copied verbatim into an [N]u8 buffer. Only length is
// checked here; content validation is deferred to the owner.
dec_fixed :: proc(d: ^Decoder, $N: int) -> (out: [N]u8, err: Decode_Error) {
    // Valid fixed ids/hashes are plain ASCII. Copy that overwhelmingly common form
    // directly from the token, avoiding an arena allocation that would immediately
    // be discarded after this fixed-array copy. Escaped strings retain the full JSON
    // semantics through the normal unquote path below.
    tok := d.curr_token

    if tok.kind == .String && len(tok.text) == N + 2 && tok.text[0] == '"' && tok.text[N + 1] == '"' {
        escaped := false
        for c in tok.text[1:N + 1] {
            if c == '\\' {
                escaped = true
                break
            }
        }

        if !escaped {
            advance_token(d)
            copy(out[:], tok.text[1:N + 1])
            return out, .None
        }
    }

    s := dec_string(d) or_return

    if len(s) != N {
        return {}, .Invalid_Length
    }

    copy(out[:], s)

    return out, .None
}

// A closed enum reverse-lookup over `table` (indexed by enum value). An unknown wire
// string yields `ok=false`.
enum_from_wire :: proc(table: [$E]string, s: string) -> (E, bool) {
    for str, e in table {
        if str == s {
            return e, true
        }
    }

    return {}, false
}

// `enum_from_wire`, but an unknown wire string is a payload mismatch.
enum_from_wire_checked :: proc(table: [$E]string, s: string) -> (out: E, err: Decode_Error) {
    value, ok := enum_from_wire(table, s)

    if !ok {
        return {}, .Mismatched_Payload
    }

    return value, .None
}

// Decode a closed-enum field via `table`; an unknown wire string is a payload mismatch.
dec_enum :: proc(d: ^Decoder, table: [$E]string) -> (out: E, err: Decode_Error) {
    s := dec_string(d) or_return

    return enum_from_wire_checked(table, s)
}

// Skip the current value without materializing it: a scalar advances once, an
// object/array is walked by nesting depth. No allocation.
dec_skip :: proc(d: ^Decoder) -> Decode_Error {
    #partial switch d.curr_token.kind {
    case .Open_Brace, .Open_Bracket:
        depth := 0
        for {
            #partial switch d.curr_token.kind {
            case .Open_Brace, .Open_Bracket:
                depth += 1

            case .Close_Brace, .Close_Bracket:
                depth -= 1

            case .EOF:
                return .Mismatched_Payload
            }

            advance_token(d)

            if depth == 0 {
                break
            }
        }

    case .EOF:
        return .Mismatched_Payload

    case:
        advance_token(d)
    }

    return .None
}

// Consume the opening `{`. A non-object is an error.
dec_object_begin :: proc(d: ^Decoder) -> Decode_Error {
    if d.curr_token.kind != .Open_Brace {
        return .Mismatched_Payload
    }

    advance_token(d)

    return .None
}

// Read the next object member key, or `done=true` at the closing `}` (consumed).
// Consumes the separating comma. On `done=false` the parser sits at the value token.
// A trailing comma (`{...,}`) is rejected. Call repeatedly in a `for` loop.
dec_key :: proc(d: ^Decoder) -> (key: string, done: bool, err: Decode_Error) {
    #partial switch d.curr_token.kind {
    case .Close_Brace:
        advance_token(d)
        return "", true, .None

    case .Comma:
        advance_token(d)
    }

    tok := d.curr_token

    if tok.kind != .String {
        return "", false, .Mismatched_Payload
    }

    advance_token(d)

    if d.curr_token.kind != .Colon {
        return "", false, .Mismatched_Payload
    }

    advance_token(d)
    k, uerr := unquote_string(tok, .JSON, d.allocator)

    if uerr != nil {
        return "", false, .Mismatched_Payload
    }

    return k, false, .None
}

// Reject the current member: a closed-union sibling key under the wrong tag is a
// payload mismatch. The value is left unread (the caller returns immediately).
dec_forbid :: proc(d: ^Decoder) -> Decode_Error {
    return .Mismatched_Payload
}

// Locate an internally-tagged object's discriminator in any member position.
// Snapshots the parser, scans members skipping values until `wanted` is found,
// then rewinds so the caller's field loop re-reads from the first member.
// Caller must sit just past `{` (see `dec_object_begin`).
dec_find_tag :: proc(d: ^Decoder, wanted: string) -> (tag: string, err: Decode_Error) {
    saved := d^
    for {
        k, done := dec_key(d) or_return

        if done {
            d^ = saved
            return "", .Mismatched_Payload
        }

        if k == wanted {
            tag = dec_string(d) or_return
            d^ = saved
            return tag, .None
        }

        dec_skip(d) or_return
    }
}

// Consume the opening `[`. A non-array is an error.
dec_array_begin :: proc(d: ^Decoder) -> Decode_Error {
    if d.curr_token.kind != .Open_Bracket {
        return .Mismatched_Payload
    }

    advance_token(d)

    return .None
}

// Advance to the next array element, or `more=false` at the closing `]` (consumed).
// Consumes the separating comma. On `more=true` the parser sits at the element value.
// A trailing comma is rejected.
dec_elem :: proc(d: ^Decoder) -> (more: bool, err: Decode_Error) {
    #partial switch d.curr_token.kind {
    case .Close_Bracket:
        advance_token(d)
        return false, .None

    case .Comma:
        advance_token(d)
    }

    if d.curr_token.kind == .Close_Bracket {
        return false, .Mismatched_Payload
    }

    return true, .None
}

// Decode a JSON array, reading each element with `read`, into an arena-backed slice.
// The element reader is one of the scalar readers (`dec_string`) or any `*_from_reader`.
// A non-array is an error.
dec_array :: proc(d: ^Decoder, read: proc(d: ^Decoder) -> ($T, Decode_Error)) -> (out: []T, err: Decode_Error) {
    dec_array_begin(d) or_return
    arr: [dynamic]T
    // Match `dec_string`'s allocator so decoded elements and strings share one arena.
    arr.allocator = d.allocator
    for {
        more := dec_elem(d) or_return
        if !more do break
        el := read(d) or_return
        append(&arr, el)
    }

    return arr[:], .None
}
