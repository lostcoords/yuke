package quickjs

import "core:c"

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

// Sentinel for a declared-but-not-yet-initialized binding (e.g. TDZ).
uninitialized :: proc "contextless" () -> Value {
    return mkval(.Uninitialized, 0)
}

new_bool :: proc "contextless" (v: bool) -> Value {
    return mkval(.Bool, v ? 1 : 0)
}

// Does not go through the engine's ToNumber path.
new_i32 :: proc "contextless" (v: i32) -> Value {
    return mkval(.Int, v)
}

new_f64 :: proc "contextless" (v: f64) -> Value {
    return Value{u = {float64 = v}, tag = .Float64}
}

// Widens to f64 when the value does not fit the tagged int32 arm, matching
// `JS_NewInt64`'s behavior so round-tripping through JS stays lossless.
new_i64 :: proc "contextless" (v: i64) -> Value {
    if v >= i64(min(i32)) && v <= i64(max(i32)) {
        return new_i32(i32(v))
    }

    return new_f64(f64(v))
}

// Widens to f64 when the value does not fit the tagged int32 arm.
new_u32 :: proc "contextless" (v: u32) -> Value {
    if v <= u32(max(i32)) {
        return new_i32(i32(v))
    }

    return new_f64(f64(v))
}

// Widens to f64 when the value does not fit the tagged int32 arm.
new_u64 :: proc "contextless" (v: u64) -> Value {
    if v <= u64(max(i32)) {
        return new_i32(i32(v))
    }

    return new_f64(f64(v))
}

// Internal bytecode tag (`JS_NewCatchOffset`); not meaningful outside the
// interpreter's own catch-offset encoding.
new_catch_offset :: proc "contextless" (v: i32) -> Value {
    return mkval(.Catch_Offset, v)
}

is_number :: proc "contextless" (v: Value) -> bool {
    return v.tag == .Int || v.tag == .Float64
}

// Either bigint tag: heap-allocated or the inline short form.
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

// Either string tag: flat or rope representation.
is_string :: proc "contextless" (v: Value) -> bool {
    return v.tag == .String || v.tag == .String_Rope
}

is_symbol :: proc "contextless" (v: Value) -> bool {
    return v.tag == .Symbol
}

// Also covers functions and arrays.
is_object :: proc "contextless" (v: Value) -> bool {
    return v.tag == .Object
}

is_module :: proc "contextless" (v: Value) -> bool {
    return v.tag == .Module
}

is_ref_counted :: proc "contextless" (v: Value) -> bool {
    return i64(v.tag) < 0
}

// Unwraps a bool payload. Caller must have checked `is_bool(v)` first.
get_bool :: proc "contextless" (v: Value) -> bool {
    assert_contextless(v.tag == .Bool, "get_bool on a non-bool value")

    return v.u.int32 != 0
}

// Unwraps a tagged int32 payload. Caller must have checked `v.tag == .Int` first.
get_i32 :: proc "contextless" (v: Value) -> i32 {
    assert_contextless(v.tag == .Int, "get_i32 on a non-int value")

    return v.u.int32
}

// Unwraps a float64 payload. Caller must have checked `v.tag == .Float64` first.
get_f64 :: proc "contextless" (v: Value) -> f64 {
    assert_contextless(v.tag == .Float64, "get_f64 on a non-float value")

    return v.u.float64
}

// Unwraps the heap pointer of a reference-counted value. Caller must have
// checked `is_ref_counted(v)` first.
get_ptr :: proc "contextless" (v: Value) -> rawptr {
    assert_contextless(is_ref_counted(v), "get_ptr on a non-heap value")

    return v.u.ptr
}

// Bytes are copied by the engine.
new_string :: proc(ctx: ^Context, s: string) -> Value {
    assert(ctx != nil, "new_string needs a context")

    return c_new_string_len(ctx, cstring(raw_data(s)), c.size_t(len(s)))
}

// Coerces to a JS boolean. `JS_ToBool`'s -1 (exception) arm becomes `true`,
// matching the C helper's own bool cast.
to_boolean :: proc(ctx: ^Context, val: Value) -> Value {
    assert(ctx != nil, "to_boolean needs a context")

    return new_bool(c_to_bool(ctx, val) != 0)
}

// Same bit pattern as `JS_ToInt32`, reinterpreted unsigned.
to_uint32 :: proc(ctx: ^Context, val: Value) -> (value: u32, ok: bool) {
    assert(ctx != nil, "to_uint32 needs a context")

    i: i32
    ok = c_to_i32(ctx, &i, val) == 0
    value = u32(i)

    return
}

// Borrowed UTF-8 view; free with `c_free_cstring`.
atom_to_cstring :: proc(ctx: ^Context, atom: Atom) -> cstring {
    assert(ctx != nil, "atom_to_cstring needs a context")

    return c_atom_to_cstring_len(ctx, nil, atom)
}

// Borrowed UTF-8 view with its byte length; free with `c_free_cstring`.
to_cstring_len :: proc(ctx: ^Context, val: Value) -> (s: cstring, len: int) {
    assert(ctx != nil, "to_cstring_len needs a context")

    n: c.size_t
    s = c_to_cstring_len2(ctx, &n, val, false)
    len = int(n)

    return
}

// Borrowed, nul-terminated UTF-8 view; free with `c_free_cstring`.
to_cstring :: proc(ctx: ^Context, val: Value) -> cstring {
    assert(ctx != nil, "to_cstring needs a context")

    return c_to_cstring_len2(ctx, nil, val, false)
}

// Borrowed UTF-16 view, not nul-terminated; free with `c_free_cstring_utf16`.
to_cstring_utf16 :: proc(ctx: ^Context, val: Value) -> [^]u16 {
    assert(ctx != nil, "to_cstring_utf16 needs a context")

    return c_to_cstring_len_utf16(ctx, nil, val)
}

// `name` must be nul-terminated.
new_cfunction :: proc(ctx: ^Context, fn: C_Function, name: cstring, length: c.int) -> Value {
    assert(ctx != nil, "new_cfunction needs a context")

    return c_new_cfunction2(ctx, fn, name, length, .Generic, 0)
}

// Puns the magic-carrying proc into `JS_NewCFunction2`'s generic slot. `name` must
// be nul-terminated.
new_cfunction_magic :: proc(
    ctx: ^Context,
    fn: C_Function_Magic,
    name: cstring,
    length: c.int,
    kind: C_Function_Kind,
    magic: c.int,
) -> Value {
    assert(ctx != nil, "new_cfunction_magic needs a context")

    ft := C_Function_Type {
        generic_magic = fn,
    }

    return c_new_cfunction2(ctx, ft.generic, name, length, kind, magic)
}
