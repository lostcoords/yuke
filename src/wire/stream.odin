package wire

import "core:encoding/json"
import "core:strconv"
import "core:strings"

// Streaming decode front end. A frame is decoded token-by-token straight into typed
// structs; no intermediate `json.Value` tree is built. A multi-MB result, or an
// ignored broadcast payload, is streamed (or skipped, see `dec_skip`) rather than
// materialized. Encoders emit discriminators first, while decoders scan and rewind
// so tagged objects remain valid when members arrive in any JSON object order.
//
// Ownership matches the value-tree path: decoded strings are unquoted into the
// parser's allocator (the caller's frame arena), so the wire types stay non-owning
// borrows into that arena; `*_clone` deep-copies into a caller allocator.
Decoder :: json.Parser

// Start decoding `data`. Integers are kept as i64 (`parse_integers`).
decoder_init :: proc(data: string, allocator := context.allocator) -> Decoder {
    return json.make_parser_from_string(data, .JSON, true, allocator)
}

// Assert the input held exactly one JSON value: a frame is one value, so trailing
// bytes after the root are rejected rather than silently dropped.
dec_finish :: proc(d: ^Decoder) -> Validation_Error {
    if d.curr_token.kind != .EOF {
        return .Bad_Frame_Type
    }

    return .None
}

// --- scalar readers (consume the current value token) ---

// A JSON string, unquoted into the parser allocator. A non-string is an error.
dec_string :: proc(d: ^Decoder) -> (string, Validation_Error) {
    tok := d.curr_token

    if tok.kind != .String {
        return "", .Mismatched_Payload
    }

    json.advance_token(d)
    s, err := json.unquote_string(tok, .JSON, d.allocator)

    if err != nil {
        return "", .Mismatched_Payload
    }

    return s, .None
}

// A scalar's verbatim token text, cloned into the parser allocator — quotes and
// escapes intact. Backs values that must echo byte-identically. A container is an error.
dec_raw_scalar :: proc(d: ^Decoder) -> (string, Validation_Error) {
    tok := d.curr_token

    #partial switch tok.kind {
    case .String, .Integer, .Float, .Null, .True, .False:
        json.advance_token(d)
        text, err := strings.clone(tok.text, d.allocator)

        if err != nil {
            return "", .Mismatched_Payload
        }

        return text, .None
    }

    return "", .Mismatched_Payload
}

// A u64 in JSON's safe integer range. A non-integer, an over-range value, or a
// value that does not fit i64 (never a small coercion) is an error.
dec_u64 :: proc(d: ^Decoder) -> (u64, Validation_Error) {
    tok := d.curr_token

    if tok.kind != .Integer {
        return 0, .Mismatched_Payload
    }

    json.advance_token(d)
    i, ok := strconv.parse_i64(tok.text)

    if !ok {
        return 0, .Out_Of_Range
    }

    if i < 0 || i > MAX_WIRE_INTEGER {
        return 0, .Out_Of_Range
    }

    return u64(i), .None
}

// A signed i64 in JSON's safe integer range (used for e.g. cron UTC offsets).
dec_i64 :: proc(d: ^Decoder) -> (i64, Validation_Error) {
    tok := d.curr_token

    if tok.kind != .Integer {
        return 0, .Mismatched_Payload
    }

    json.advance_token(d)
    i, ok := strconv.parse_i64(tok.text)

    if !ok {
        return 0, .Out_Of_Range
    }

    if i < -MAX_WIRE_INTEGER || i > MAX_WIRE_INTEGER {
        return 0, .Out_Of_Range
    }

    return i, .None
}

// A JSON number as f64 (an integer literal is accepted and widened). A non-number
// is an error.
dec_f64 :: proc(d: ^Decoder) -> (f64, Validation_Error) {
    tok := d.curr_token

    #partial switch tok.kind {
    case .Integer:
        json.advance_token(d)
        i, ok := strconv.parse_i64(tok.text)

        if !ok {
            return 0, .Out_Of_Range
        }

        return f64(i), .None

    case .Float:
        json.advance_token(d)
        f, ok := strconv.parse_f64(tok.text)

        if !ok {
            return 0, .Mismatched_Payload
        }

        return f, .None
    }

    return 0, .Mismatched_Payload
}

// A boolean. A non-boolean is an error.
dec_bool :: proc(d: ^Decoder) -> (bool, Validation_Error) {
    #partial switch d.curr_token.kind {
    case .True:
        json.advance_token(d)
        return true, .None

    case .False:
        json.advance_token(d)
        return false, .None
    }

    return false, .Mismatched_Payload
}

// If the current value is JSON null, consume it and report true; otherwise leave it.
dec_is_null :: proc(d: ^Decoder) -> bool {
    if d.curr_token.kind == .Null {
        json.advance_token(d)
        return true
    }

    return false
}

// A fixed-length string copied verbatim into an [N]u8 buffer. Only length is
// checked here; content validation (lowercase hex) is deferred to the owner's validate.
dec_fixed :: proc(d: ^Decoder, $N: int) -> (out: [N]u8, err: Validation_Error) {
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
            json.advance_token(d)
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

// Decode a closed-enum field via `table`; an unknown wire string is a payload mismatch.
dec_enum :: proc(d: ^Decoder, table: [$E]string) -> (out: E, err: Validation_Error) {
    s := dec_string(d) or_return

    return enum_from_wire_checked(table, s)
}

// Skip the current value without materializing it: a scalar advances once, an
// object/array is walked by nesting depth. No allocation — this is how an unknown
// broadcast's `data` or a not-yet-routed `result` is passed over.
dec_skip :: proc(d: ^Decoder) -> Validation_Error {
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

            json.advance_token(d)

            if depth == 0 {
                break
            }
        }

    case .EOF:
        return .Mismatched_Payload

    case:
        json.advance_token(d)
    }

    return .None
}

// --- object iteration ---

// Consume the opening `{`. A non-object is an error.
dec_object_begin :: proc(d: ^Decoder) -> Validation_Error {
    if d.curr_token.kind != .Open_Brace {
        return .Mismatched_Payload
    }

    json.advance_token(d)

    return .None
}

// Read the next object member key, or `done=true` at the closing `}` (consumed).
// Consumes the separating comma. On `done=false` the parser sits at the value token.
// A trailing comma (`{...,}`) is rejected. Call repeatedly in a `for` loop.
dec_key :: proc(d: ^Decoder) -> (key: string, done: bool, err: Validation_Error) {
    #partial switch d.curr_token.kind {
    case .Close_Brace:
        json.advance_token(d)
        return "", true, .None

    case .Comma:
        json.advance_token(d)
    }

    tok := d.curr_token

    if tok.kind != .String {
        return "", false, .Mismatched_Payload
    }

    json.advance_token(d)

    if d.curr_token.kind != .Colon {
        return "", false, .Mismatched_Payload
    }

    json.advance_token(d)
    k, uerr := json.unquote_string(tok, .JSON, d.allocator)

    if uerr != nil {
        return "", false, .Mismatched_Payload
    }

    return k, false, .None
}

// Reject the current member: a closed-union sibling key under the wrong tag is a
// payload mismatch. The value is left unread (the caller returns immediately).
dec_forbid :: proc(d: ^Decoder) -> Validation_Error {
    return .Mismatched_Payload
}

// Locate an internally-tagged object's discriminator in any member position.
// Snapshots the parser, scans members skipping values until `wanted` is found,
// then rewinds so the caller's field loop re-reads from the first member.
// Caller must sit just past `{` (see `dec_object_begin`).
dec_find_tag :: proc(d: ^Decoder, wanted: string) -> (tag: string, err: Validation_Error) {
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

// --- array iteration ---

// Consume the opening `[`. A non-array is an error.
dec_array_begin :: proc(d: ^Decoder) -> Validation_Error {
    if d.curr_token.kind != .Open_Bracket {
        return .Mismatched_Payload
    }

    json.advance_token(d)

    return .None
}

// Advance to the next array element, or `more=false` at the closing `]` (consumed).
// Consumes the separating comma. On `more=true` the parser sits at the element value.
// A trailing comma is rejected.
dec_elem :: proc(d: ^Decoder) -> (more: bool, err: Validation_Error) {
    #partial switch d.curr_token.kind {
    case .Close_Bracket:
        json.advance_token(d)
        return false, .None

    case .Comma:
        json.advance_token(d)
    }

    if d.curr_token.kind == .Close_Bracket {
        return false, .Mismatched_Payload
    }

    return true, .None
}

// Decode a JSON array, reading each element with `read`, into an arena-backed slice.
// The element reader is one of the scalar readers (`dec_string`, `dec_u64`) or any
// `*_from_reader`. A non-array is an error.
dec_array :: proc(
    d: ^Decoder,
    read: proc(d: ^Decoder) -> ($T, Validation_Error),
) -> (
    out: []T,
    err: Validation_Error,
) {
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
