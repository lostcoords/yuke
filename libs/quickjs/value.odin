package quickjs

import "core:c"
import "core:strings"

// QuickJS declares its value constructors and predicates as `static inline` in
// quickjs.h, so they have no exported symbols and cannot be linked. They are
// reimplemented here: the pure ones directly against the `Value` layout that
// `c.odin` asserts, the rest as one-line calls to the exported entry point the
// C header itself delegates to.

@(private)
mkval :: proc "contextless" (tag: Tag, int32: i32) -> Value {
    return Value{u = {int32 = int32}, tag = tag}
}

@(private)
mkptr :: proc "contextless" (tag: Tag, ptr: rawptr) -> Value {
    return Value{u = {ptr = ptr}, tag = tag}
}

undefined :: proc "contextless" () -> Value {
    return mkval(.Undefined, 0)
}

null :: proc "contextless" () -> Value {
    return mkval(.Null, 0)
}

// The sentinel returned by a host procedure to propagate a pending exception.
exception :: proc "contextless" () -> Value {
    return mkval(.Exception, 0)
}

uninitialized :: proc "contextless" () -> Value {
    return mkval(.Uninitialized, 0)
}

new_bool :: proc "contextless" (v: bool) -> Value {
    return mkval(.Bool, v ? 1 : 0)
}

new_i32 :: proc "contextless" (v: i32) -> Value {
    return mkval(.Int, v)
}

new_f64 :: proc "contextless" (v: f64) -> Value {
    // Mirrors __JS_NewFloat64: no int narrowing, NaN boxing is off.
    return Value{u = {float64 = v}, tag = .Float64}
}

// Widens to f64 when the value does not fit the tagged int32 arm, matching
// JS_NewInt64's behavior so round-tripping through JS stays lossless.
new_i64 :: proc "contextless" (v: i64) -> Value {
    if v >= i64(min(i32)) && v <= i64(max(i32)) {
        return new_i32(i32(v))
    }

    return new_f64(f64(v))
}

new_u32 :: proc "contextless" (v: u32) -> Value {
    if v <= u32(max(i32)) {
        return new_i32(i32(v))
    }

    return new_f64(f64(v))
}

is_number :: proc "contextless" (v: Value) -> bool {
    return v.tag == .Int || v.tag == .Float64
}

is_big_int :: proc "contextless" (v: Value) -> bool {
    return v.tag == .Big_Int || v.tag == .Short_Big_Int
}

is_bool :: proc "contextless" (v: Value) -> bool {
    return v.tag == .Bool
}

is_null :: proc "contextless" (v: Value) -> bool {
    return v.tag == .Null
}

is_undefined :: proc "contextless" (v: Value) -> bool {
    return v.tag == .Undefined
}

is_exception :: proc "contextless" (v: Value) -> bool {
    return v.tag == .Exception
}

is_uninitialized :: proc "contextless" (v: Value) -> bool {
    return v.tag == .Uninitialized
}

is_string :: proc "contextless" (v: Value) -> bool {
    return v.tag == .String || v.tag == .String_Rope
}

is_symbol :: proc "contextless" (v: Value) -> bool {
    return v.tag == .Symbol
}

is_object :: proc "contextless" (v: Value) -> bool {
    return v.tag == .Object
}

is_module :: proc "contextless" (v: Value) -> bool {
    return v.tag == .Module
}

// True for the reference-counted arms, i.e. those `free_value` acts on.
is_ref_counted :: proc "contextless" (v: Value) -> bool {
    return i64(v.tag) < 0
}

get_bool :: proc "contextless" (v: Value) -> bool {
    assert_contextless(v.tag == .Bool, "get_bool on a non-bool value")

    return v.u.int32 != 0
}

get_i32 :: proc "contextless" (v: Value) -> i32 {
    assert_contextless(v.tag == .Int, "get_i32 on a non-int value")

    return v.u.int32
}

get_f64 :: proc "contextless" (v: Value) -> f64 {
    assert_contextless(v.tag == .Float64, "get_f64 on a non-float value")

    return v.u.float64
}

get_ptr :: proc "contextless" (v: Value) -> rawptr {
    assert_contextless(is_ref_counted(v), "get_ptr on a non-heap value")

    return v.u.ptr
}

// Allocates a JS string from Odin memory. The bytes are copied by the engine.
new_string :: proc(ctx: ^Context, s: string) -> Value {
    assert(ctx != nil, "new_string needs a context")

    cs := strings.clone_to_cstring(s, context.temp_allocator)

    return c_new_string_len(ctx, cs, c.size_t(len(s)))
}
