package json

import stdjson "core:encoding/json"
import "core:math"
import "core:unicode/utf8"

// Typed readers for one member of an already-parsed JSON object. Missing and null both
// read as absent `(zero, present=false, valid=true)`; a present member of the wrong
// type or out of bounds is invalid `(zero, present=true, valid=false)`. The caller
// decides whether absence is acceptable.

// `max_bytes <= 0` means uncapped. A present non-string, over-cap, empty (unless
// `allow_empty`), or non-UTF-8 value is invalid.
read_string :: proc(
    o: stdjson.Object,
    name: string,
    max_bytes: int,
    allow_empty: bool,
) -> (
    value: string,
    present, valid: bool,
) {
    member, found := o[name]
    if !found do return "", false, true

    if _, is_null := member.(stdjson.Null); is_null do return "", false, true

    text, ok := member.(stdjson.String)
    if !ok ||
       (!allow_empty && len(text) == 0) ||
       (max_bytes > 0 && len(text) > max_bytes) ||
       !utf8.valid_string(text) {
        return "", true, false
    }

    return text, true, true
}

read_bool :: proc(o: stdjson.Object, name: string) -> (value: bool, present, valid: bool) {
    member, found := o[name]
    if !found do return false, false, true

    if _, is_null := member.(stdjson.Null); is_null do return false, false, true

    boolean, ok := member.(stdjson.Boolean)
    if !ok do return false, true, false

    return bool(boolean), true, true
}

// A non-negative integer in `[lo, hi]`. A fractionless float (`1.0`) counts; a
// fraction, nan/inf, or out-of-range value is invalid.
read_u64 :: proc(o: stdjson.Object, name: string, lo, hi: u64) -> (value: u64, present, valid: bool) {
    member, found := o[name]
    if !found do return 0, false, true

    if _, is_null := member.(stdjson.Null); is_null do return 0, false, true

    n, ok := integer_i64(member)
    if !ok || n < 0 || u64(n) < lo || u64(n) > hi do return 0, true, false

    return u64(n), true, true
}

read_f64_nonneg :: proc(o: stdjson.Object, name: string) -> (value: f64, present, valid: bool) {
    member, found := o[name]
    if !found do return 0, false, true

    if _, is_null := member.(stdjson.Null); is_null do return 0, false, true

    #partial switch number in member {
    case stdjson.Integer:
        value = f64(number)

    case stdjson.Float:
        value = f64(number)

    case:
        return 0, true, false
    }

    if value < 0 || !f64_is_finite(value) do return 0, true, false

    return value, true, true
}

read_object :: proc(o: stdjson.Object, name: string) -> (value: stdjson.Object, present, valid: bool) {
    member, found := o[name]
    if !found do return nil, false, true

    if _, is_null := member.(stdjson.Null); is_null do return nil, false, true

    object, ok := member.(stdjson.Object)
    if !ok do return nil, true, false

    return object, true, true
}

// A JSON number that is exactly an integer fitting i64. A fractionless float is
// accepted; nan/inf/fraction/out-of-range is not.
integer_i64 :: proc(v: stdjson.Value) -> (i64, bool) {
    #partial switch number in v {
    case stdjson.Integer:
        return i64(number), true

    case stdjson.Float:
        if f64_is_integral(f64(number)) && f64(number) >= f64(min(i64)) && f64(number) <= f64(max(i64)) {
            return i64(number), true
        }
    }

    return 0, false
}

f64_is_integral :: proc(f: f64) -> bool {
    return f64_is_finite(f) && math.floor(f) == f
}

f64_is_finite :: proc(f: f64) -> bool {
    return !math.is_nan(f) && !math.is_inf(f)
}
