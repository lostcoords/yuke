package catalog

import "core:encoding/json"
import "core:math"
import "core:unicode/utf8"

import wire "src:wire"

// Bounded readers for one member of an untrusted JSON object, shared by the models.dev
// decoder and the JavaScript provider definitions. An absent member reads as
// `(zero, false, true)`, so each caller decides whether absence is acceptable.

object_string :: proc(
    object: json.Object,
    name: string,
    max_bytes: int,
    allow_empty: bool,
) -> (
    value: string,
    present: bool,
    valid: bool,
) {
    assert(max_bytes > 0, "an external string field needs a positive bound")

    member, found := object[name]
    if !found {
        return "", false, true
    }

    text, ok := member.(json.String)
    if !ok || (!allow_empty && len(text) == 0) || len(text) > max_bytes || !utf8.valid_string(text) {
        return "", true, false
    }

    return text, true, true
}

object_bool :: proc(object: json.Object, name: string) -> (value: bool, present, valid: bool) {
    member, found := object[name]
    if !found {
        return false, false, true
    }

    boolean, ok := member.(json.Boolean)
    if !ok {
        return false, true, false
    }

    return bool(boolean), true, true
}

object_positive_u64 :: proc(object: json.Object, name: string) -> (value: u64, present, valid: bool) {
    member, found := object[name]
    if !found {
        return 0, false, true
    }

    parsed, parsed_ok := json_integer_i64(member)
    if !parsed_ok || parsed <= 0 || parsed > wire.MAX_WIRE_INTEGER {
        return 0, true, false
    }

    return u64(parsed), true, true
}

object_nonnegative_f64 :: proc(object: json.Object, name: string) -> (value: f64, present, valid: bool) {
    member, found := object[name]
    if !found {
        return 0, false, true
    }

    #partial switch number in member {
    case json.Integer:
        value = f64(number)

    case json.Float:
        value = f64(number)

    case:
        return 0, true, false
    }

    if value < 0 || math.is_nan(value) || math.is_inf(value) {
        return 0, true, false
    }

    return value, true, true
}

// A nested object member. An absent member yields a nil object, which reads as empty;
// only a present member of another type is invalid.
object_member_object :: proc(object: json.Object, name: string) -> (nested: json.Object, valid: bool) {
    member, found := object[name]
    if !found {
        return nil, true
    }

    value, ok := member.(json.Object)
    if !ok {
        return nil, false
    }

    return value, true
}

// A JSON number that is exactly an integer. Floats are accepted only when they carry no
// fraction and fit i64, so a feed writing `1.0` is not rejected as malformed.
json_integer_i64 :: proc(value: json.Value) -> (i64, bool) {
    #partial switch number in value {
    case json.Integer:
        return i64(number), true

    case json.Float:
        if !math.is_nan(number) &&
           !math.is_inf(number) &&
           math.floor(number) == number &&
           number >= f64(min(i64)) &&
           number <= f64(max(i64)) {
            return i64(number), true
        }
    }

    return 0, false
}
