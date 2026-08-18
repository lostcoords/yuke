package provider

import "base:runtime"

import "libs:json"
import "src:wire"

// Largest integer every supported JSON number representation carries exactly.
// Provider counters outside this range degrade per the helper that reads them.
MAX_EXACT_JSON_INTEGER :: u64(wire.MAX_WIRE_INTEGER)

// Parse one provider event as a JSON object. Unknown members stay permitted,
// duplicate members and trailing values do not. The tree is allocated into
// `allocator` and is the caller's to `json.destroy_value`. `allocator` must be
// a bulk-reclaimable scratch scope: malformed input can leave the parser with a
// partial allocation the returned value cannot reach, reclaimable only in bulk.
decode_json_object :: proc(
    data: string,
    allocator: runtime.Allocator,
) -> (
    value: json.Value,
    object: json.Object,
    err: Transport_Error,
) {
    parser := json.make_parser_from_string(data, .JSON, false, allocator)
    parse_err: json.Error
    value, parse_err = json.parse_value(&parser)
    if parse_err != nil {
        assert(parse_err != .Invalid_Allocator, "provider JSON needs a valid allocator")

        if parse_err == .Out_Of_Memory {
            return {}, nil, .Resource_Exhausted
        }

        return {}, nil, .Parse_Error
    }

    object_ok: bool
    object, object_ok = value.(json.Object)
    if !object_ok || parser.curr_token.kind != .EOF {
        json.destroy_value(value, allocator)
        return {}, nil, .Parse_Error
    }

    return value, object, .None
}

// Optional object member. Missing and null are both absent; a present value of
// another type is a provider parse error.
decode_optional_object :: proc(
    object: json.Object,
    name: string,
) -> (
    value: json.Object,
    present: bool,
    err: Transport_Error,
) {
    v, p, valid := json.read_object(object, name)
    if !valid {
        return nil, false, .Parse_Error
    }

    return v, p, .None
}

// Optional string member. Missing and null are both absent; a present value of
// another type is a provider parse error.
decode_optional_string :: proc(
    object: json.Object,
    name: string,
) -> (
    value: string,
    present: bool,
    err: Transport_Error,
) {
    v, p, valid := json.read_string(object, name, 0, true)
    if !valid {
        return "", false, .Parse_Error
    }

    return v, p, .None
}

// Optional exact non-negative integer member. Missing and null are absent; a
// fraction, negative value, unsafe integer, or another JSON type is malformed.
decode_optional_u64 :: proc(object: json.Object, name: string) -> (value: u64, present: bool, err: Transport_Error) {
    v, p, valid := json.read_u64(object, name, 0, MAX_EXACT_JSON_INTEGER)
    if !valid {
        return 0, false, .Parse_Error
    }

    return v, p, .None
}

// Read a provider usage counter permissively. Missing, null, non-number,
// negative, fractional, and unsafe values become zero; usage metadata must
// never crash or invalidate an otherwise usable answer.
decode_usage_u64 :: proc(object: json.Object, name: string) -> u64 {
    v, present, valid := json.read_u64(object, name, 0, MAX_EXACT_JSON_INTEGER)

    return present && valid ? v : 0
}

// Validate a tool call's argument bytes as a JSON object and return them unchanged,
// substituting an empty object for empty input. Shared by every request builder.
tool_arguments :: proc(
    bytes: []byte,
    scratch_allocator: runtime.Allocator,
) -> (
    arguments: string,
    err: Transport_Error,
) {
    if len(bytes) == 0 {
        return "{}", .None
    }

    raw := string(bytes)
    value, _, parse_err := decode_json_object(raw, scratch_allocator)
    if parse_err != .None {
        return "", parse_err
    }

    json.destroy_value(value, scratch_allocator)

    return raw, .None
}
