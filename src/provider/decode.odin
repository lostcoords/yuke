package provider

import "base:runtime"
import "core:encoding/json"
import "core:math"

// Largest integer every supported JSON number representation carries exactly.
// Provider counters outside this range degrade per the helper that reads them.
MAX_EXACT_JSON_INTEGER :: u64(9_007_199_254_740_991)

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
    field, found := object[name]
    if !found {
        return nil, false, .None
    }

    if _, is_null := field.(json.Null); is_null {
        return nil, false, .None
    }

    ok: bool
    value, ok = field.(json.Object)
    if !ok {
        return nil, false, .Parse_Error
    }

    return value, true, .None
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
    field, found := object[name]
    if !found {
        return "", false, .None
    }

    if _, is_null := field.(json.Null); is_null {
        return "", false, .None
    }

    text, ok := field.(json.String)
    if !ok {
        return "", false, .Parse_Error
    }

    return text, true, .None
}

// Optional exact non-negative integer member. Missing and null are absent; a
// fraction, negative value, unsafe integer, or another JSON type is malformed.
decode_optional_u64 :: proc(object: json.Object, name: string) -> (value: u64, present: bool, err: Transport_Error) {
    field, found := object[name]
    if !found {
        return 0, false, .None
    }

    if _, is_null := field.(json.Null); is_null {
        return 0, false, .None
    }

    #partial switch number in field {
    case json.Integer:
        if number < 0 || u64(number) > MAX_EXACT_JSON_INTEGER {
            return 0, false, .Parse_Error
        }

        return u64(number), true, .None

    case json.Float:
        if number < 0 || number > f64(MAX_EXACT_JSON_INTEGER) || math.floor(number) != number {
            return 0, false, .Parse_Error
        }

        return u64(number), true, .None

    case:
        return 0, false, .Parse_Error
    }
}

// Read a provider usage counter permissively. Missing, null, non-number,
// negative, fractional, and unsafe values become zero; usage metadata must
// never crash or invalidate an otherwise usable answer.
decode_usage_u64 :: proc(object: json.Object, name: string) -> u64 {
    field, found := object[name]
    if !found {
        return 0
    }

    #partial switch number in field {
    case json.Integer:
        if number >= 0 && u64(number) <= MAX_EXACT_JSON_INTEGER {
            return u64(number)
        }

    case json.Float:
        if number >= 0 && number <= f64(MAX_EXACT_JSON_INTEGER) && math.floor(number) == number {
            return u64(number)
        }
    }

    return 0
}
