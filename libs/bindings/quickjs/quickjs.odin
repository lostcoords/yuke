package quickjs

import "core:c"
import "core:strings"

// Source kind for `eval`. The remaining C eval-type bits are internal.
Eval_Kind :: enum c.int {
    Global = 0,
    Module = 1,
}

// Eval modifiers as bit positions matching quickjs.h (bit N → 1<<N).
Eval_Flag :: enum {
    Strict            = 3, // 0x08
    Compile_Only      = 5, // 0x20
    Backtrace_Barrier = 6, // 0x40
    Async             = 7, // 0x80
}

Eval_Flags :: bit_set[Eval_Flag;c.int]

// Pass `alloc` to bind the runtime to a caller-owned allocator; `user` is
// handed back to every hook. With `alloc` nil the engine uses its own malloc
// and `runtime_free` will not return pages to the OS.
runtime_new :: proc(alloc: ^Alloc_Functions = nil, user: rawptr = nil) -> ^Runtime {
    if alloc == nil {
        return c_new_runtime()
    }

    assert(alloc.malloc != nil && alloc.free != nil, "allocator needs malloc and free")
    assert(alloc.realloc != nil && alloc.usable_size != nil, "allocator needs realloc and usable_size")

    return c_new_runtime2(alloc, user)
}

// Destroy a runtime and everything in it. Every Context must already be freed.
runtime_free :: proc(rt: ^Runtime) {
    if rt == nil {
        return
    }

    c_free_runtime(rt)
}

// Exceeding the limit fails the running script with an out-of-memory
// exception rather than aborting the daemon.
set_memory_limit :: proc(rt: ^Runtime, bytes: int) {
    assert(rt != nil, "set_memory_limit needs a runtime")
    assert(bytes > 0, "memory limit must be positive")

    c_set_memory_limit(rt, c.size_t(bytes))
}

set_gc_threshold :: proc(rt: ^Runtime, bytes: int) {
    assert(rt != nil, "set_gc_threshold needs a runtime")
    assert(bytes >= 0, "gc threshold must be non-negative")

    c_set_gc_threshold(rt, c.size_t(bytes))
}

// Zero disables the check.
set_max_stack_size :: proc(rt: ^Runtime, bytes: int) {
    assert(rt != nil, "set_max_stack_size needs a runtime")
    assert(bytes >= 0, "stack size must be non-negative")

    c_set_max_stack_size(rt, c.size_t(bytes))
}

run_gc :: proc(rt: ^Runtime) {
    assert(rt != nil, "run_gc needs a runtime")

    c_run_gc(rt)
}

memory_usage :: proc(rt: ^Runtime) -> (usage: Memory_Usage) {
    assert(rt != nil, "memory_usage needs a runtime")

    c_compute_memory_usage(rt, &usage)

    return
}

// `cb` runs at interpreter checkpoints; returning non-zero aborts the script
// with a catchable exception. It cannot interrupt a single long-running engine
// builtin.
set_interrupt_handler :: proc(rt: ^Runtime, cb: Interrupt_Handler, user: rawptr = nil) {
    assert(rt != nil, "set_interrupt_handler needs a runtime")

    c_set_interrupt_handler(rt, cb, user)
}

// True when a microtask is queued and `run_pending_jobs` has work to do.
job_pending :: proc(rt: ^Runtime) -> bool {
    assert(rt != nil, "job_pending needs a runtime")

    return c_is_job_pending(rt)
}

// Drain the microtask queue. This is what resumes `await` after the host has
// settled a promise. `failed` reports that a job raised; the exception is left
// on its context.
run_pending_jobs :: proc(rt: ^Runtime) -> (executed: int, failed: bool) {
    assert(rt != nil, "run_pending_jobs needs a runtime")

    ctx: ^Context
    for {
        rc := c_execute_pending_job(rt, &ctx)
        if rc == 0 {
            break
        }
        if rc < 0 {
            failed = true
            break
        }
        executed += 1
    }

    return
}

// Create an execution context on `rt`. Several contexts may share one runtime
// and its GC.
context_new :: proc(rt: ^Runtime) -> ^Context {
    assert(rt != nil, "context_new needs a runtime")

    return c_new_context(rt)
}

// Destroy a context. Its runtime and any sibling contexts stay alive.
context_free :: proc(ctx: ^Context) {
    if ctx == nil {
        return
    }

    c_free_context(ctx)
}

// Caller owns the result; release it with `free_value`.
global_object :: proc(ctx: ^Context) -> Value {
    assert(ctx != nil, "global_object needs a context")

    return c_get_global_object(ctx)
}

// Release a value. Required for every owned value the API hands back.
free_value :: proc(ctx: ^Context, v: Value) {
    assert(ctx != nil, "free_value needs a context")

    c_free_value(ctx, v)
}

// Take an additional reference. Use when storing a value beyond the call that
// produced it.
dup_value :: proc(ctx: ^Context, v: Value) -> Value {
    assert(ctx != nil, "dup_value needs a context")

    return c_dup_value(ctx, v)
}

// Compile and run `src`, which is `src_len` bytes long. `filename` appears in stack
// traces. Both must be nul-terminated. On failure the result satisfies `is_exception`
// and the detail is available via `exception_text`. Caller owns the result.
eval :: proc(
    ctx: ^Context,
    src: cstring,
    src_len: int,
    filename: cstring = "<eval>",
    kind: Eval_Kind = .Global,
    flags: Eval_Flags = {},
) -> Value {
    assert(ctx != nil, "eval needs a context")
    assert(src != nil, "eval needs source")
    assert(src_len >= 0, "source length must be non-negative")

    return c_eval(ctx, src, c.size_t(src_len), filename, c.int(kind) | transmute(c.int)flags)
}

// Invoke `fn` with `this` and `args`. Caller owns the result; `args` stay owned
// by the caller.
call :: proc(ctx: ^Context, fn: Value, this: Value, args: []Value = nil) -> Value {
    assert(ctx != nil, "call needs a context")

    argv := raw_data(args)

    return c_call(ctx, fn, this, c.int(len(args)), argv)
}

new_object :: proc(ctx: ^Context) -> Value {
    assert(ctx != nil, "new_object needs a context")

    return c_new_object(ctx)
}

new_array :: proc(ctx: ^Context) -> Value {
    assert(ctx != nil, "new_array needs a context")

    return c_new_array(ctx)
}

// A JS Int32Array copy of `values`. Wraps a fresh ArrayBuffer, released once the view refs it.
new_int32_array :: proc(ctx: ^Context, values: []i32) -> Value {
    assert(ctx != nil, "new_int32_array needs a context")

    ab := c_new_array_buffer_copy(ctx, cast([^]u8)raw_data(values), c.size_t(len(values) * size_of(i32)))

    // The constructor reads argv[0..2] (buffer, offset, length) regardless of argc; undefined
    // offset/length gives a view over the whole buffer.
    args := [3]Value{ab, undefined(), undefined()}
    ta := c_new_typed_array(ctx, 3, raw_data(args[:]), .Int32)
    free_value(ctx, ab)

    return ta
}

// Caller owns the result.
get_property :: proc(ctx: ^Context, obj: Value, name: string) -> Value {
    assert(ctx != nil, "get_property needs a context")

    atom := c_new_atom_len(ctx, cstring(raw_data(name)), c.size_t(len(name)))

    if atom == ATOM_NULL {
        return exception()
    }
    defer c_free_atom(ctx, atom)

    return c_get_property(ctx, obj, atom)
}

// **Consumes `val`** — the engine takes the reference whether or not the store
// succeeds, so the caller must not also free it.
set_property :: proc(ctx: ^Context, obj: Value, name: string, val: Value) -> bool {
    assert(ctx != nil, "set_property needs a context")

    atom := c_new_atom_len(ctx, cstring(raw_data(name)), c.size_t(len(name)))

    // Interning fails before the engine takes the reference, so honor the consume
    // contract here.
    if atom == ATOM_NULL {
        c_free_value(ctx, val)
        return false
    }
    defer c_free_atom(ctx, atom)

    return c_set_property(ctx, obj, atom, val) >= 0
}

// Caller owns the result.
get_index :: proc(ctx: ^Context, obj: Value, idx: u32) -> Value {
    assert(ctx != nil, "get_index needs a context")

    return c_get_property_u32(ctx, obj, idx)
}

// **Consumes `val`**, as `set_property` does.
set_index :: proc(ctx: ^Context, obj: Value, idx: u32, val: Value) -> bool {
    assert(ctx != nil, "set_index needs a context")

    return c_set_property_u32(ctx, obj, idx, val) >= 0
}

// `arity` is the advertised `Function.length`, not a limit on the arguments
// actually passed. `name` must be nul-terminated.
new_function :: proc(ctx: ^Context, fn: C_Function, name: cstring, arity: int = 0) -> Value {
    assert(ctx != nil, "new_function needs a context")
    assert(fn != nil, "new_function needs a procedure")
    assert(name != nil, "new_function needs a name")
    assert(arity >= 0, "arity must be non-negative")

    return c_new_cfunction2(ctx, fn, name, c.int(arity), .Generic, 0)
}

// True when ctx has a pending exception, without consuming it.
has_exception :: proc(ctx: ^Context) -> bool {
    assert(ctx != nil, "has_exception needs a context")

    return c_has_exception(ctx)
}

// Take the pending exception, clearing it. Caller owns the result.
get_exception :: proc(ctx: ^Context) -> Value {
    assert(ctx != nil, "get_exception needs a context")

    return c_get_exception(ctx)
}

// Borrowed UTF-8 view of `v` coerced to string. The bytes belong to the engine
// and are valid until `free_string`; clone if they must outlive that.
to_string :: proc(ctx: ^Context, v: Value) -> (s: string, ok: bool) {
    assert(ctx != nil, "to_string needs a context")

    n: c.size_t
    cs := c_to_cstring_len2(ctx, &n, v, false)
    if cs == nil {
        return "", false
    }

    return string(([^]byte)(cs)[:n]), true
}

// Release a view returned by `to_string`.
// Empty strings still need free when the engine returned a non-nil pointer
// (ASCII `""` is a real `JSString` ref in QuickJS-NG).
free_string :: proc(ctx: ^Context, s: string) {
    assert(ctx != nil, "free_string needs a context")

    if raw_data(s) == nil {
        return
    }

    c_free_cstring(ctx, cstring(raw_data(s)))
}

// Take the pending exception and render it as owned text, with the stack
// appended when the thrown value carries one. Clears the exception.
exception_text :: proc(ctx: ^Context, allocator := context.allocator) -> string {
    assert(ctx != nil, "exception_text needs a context")

    err := get_exception(ctx)
    defer free_value(ctx, err)

    b := strings.builder_make(allocator)
    if msg, ok := to_string(ctx, err); ok {
        strings.write_string(&b, msg)
        free_string(ctx, msg)
    } else {
        strings.write_string(&b, "<unrepresentable exception>")
    }

    if is_object(err) {
        stack := get_property(ctx, err, "stack")
        defer free_value(ctx, stack)

        if !is_undefined(stack) {
            if st, ok := to_string(ctx, stack); ok {
                if len(st) > 0 {
                    strings.write_string(&b, "\n")
                    strings.write_string(&b, st)
                }
                free_string(ctx, st)
            }
        }
    }

    return strings.to_string(b)
}

// ToBoolean semantics. `ok` is false only when coercion itself threw.
to_bool :: proc(ctx: ^Context, v: Value) -> (value: bool, ok: bool) {
    assert(ctx != nil, "to_bool needs a context")

    rc := c_to_bool(ctx, v)
    if rc < 0 {
        return false, false
    }

    return rc != 0, true
}

// ToInt32 semantics: wraps, does not range-check. `ok` is false on a thrown
// coercion (e.g. from a Symbol).
to_i32 :: proc(ctx: ^Context, v: Value) -> (value: i32, ok: bool) {
    assert(ctx != nil, "to_i32 needs a context")

    ok = c_to_i32(ctx, &value, v) == 0

    return
}

// ToInt64 semantics. `ok` is false on a thrown coercion.
to_i64 :: proc(ctx: ^Context, v: Value) -> (value: i64, ok: bool) {
    assert(ctx != nil, "to_i64 needs a context")

    ok = c_to_i64(ctx, &value, v) == 0

    return
}

// ToNumber semantics. `ok` is false on a thrown coercion.
to_f64 :: proc(ctx: ^Context, v: Value) -> (value: f64, ok: bool) {
    assert(ctx != nil, "to_f64 needs a context")

    ok = c_to_f64(ctx, &value, v) == 0

    return
}

// Create a pending promise plus its settle functions. The yield point for
// host IO: return `promise` to the script, park the task, then `call` `resolve`
// or `reject` and drain the job queue with `run_pending_jobs`. Caller owns all
// three values.
new_promise :: proc(ctx: ^Context) -> (promise: Value, resolve: Value, reject: Value) {
    assert(ctx != nil, "new_promise needs a context")

    funcs: [2]Value
    promise = c_new_promise_capability(ctx, raw_data(funcs[:]))

    return promise, funcs[0], funcs[1]
}

// Whether `v` is a promise, and if so how it settled. This is how a caller learns a module's
// top level threw: `eval` reports an exception only for a syntax error, never a rejection.
promise_state :: proc(ctx: ^Context, v: Value) -> Promise_State {
    assert(ctx != nil, "promise_state needs a context")
    return c_promise_state(ctx, v)
}

// The fulfilled value or the rejection reason of a settled promise. Owned by the caller.
// Reading it does not settle, handle, or otherwise consume the promise.
promise_result :: proc(ctx: ^Context, v: Value) -> Value {
    assert(ctx != nil, "promise_result needs a context")
    return c_promise_result(ctx, v)
}

// Associate host state with a context; recovered in C host callbacks via
// `get_context_opaque`.
set_context_opaque :: proc(ctx: ^Context, user: rawptr) {
    assert(ctx != nil, "set_context_opaque needs a context")

    c_set_context_opaque(ctx, user)
}

get_context_opaque :: proc(ctx: ^Context) -> rawptr {
    assert(ctx != nil, "get_context_opaque needs a context")

    return c_get_context_opaque(ctx)
}

set_runtime_opaque :: proc(rt: ^Runtime, user: rawptr) {
    assert(rt != nil, "set_runtime_opaque needs a runtime")

    c_set_runtime_opaque(rt, user)
}

get_runtime_opaque :: proc(rt: ^Runtime) -> rawptr {
    assert(rt != nil, "get_runtime_opaque needs a runtime")

    return c_get_runtime_opaque(rt)
}

// Install the ES module normalize + load hooks. `normalize` may be nil to use
// the engine default (identity). `loader` must return a `Module_Def` from
// `new_cmodule` (or nil + exception).
set_module_loader :: proc(
    rt: ^Runtime,
    normalize: Module_Normalize_Func,
    loader: Module_Loader_Func,
    opaque: rawptr = nil,
) {
    assert(rt != nil, "set_module_loader needs a runtime")
    assert(loader != nil, "set_module_loader needs a loader")

    c_set_module_loader_func(rt, normalize, loader, opaque)
}

// Create a native ES module; `init` runs when the module is evaluated.
new_cmodule :: proc(ctx: ^Context, name: cstring, init: Module_Init_Func) -> ^Module_Def {
    assert(ctx != nil, "new_cmodule needs a context")
    assert(name != nil, "new_cmodule needs a name")
    assert(init != nil, "new_cmodule needs an init proc")

    return c_new_cmodule(ctx, name, init)
}

// Declare an export name before evaluation (pairs with `set_module_export`).
add_module_export :: proc(ctx: ^Context, m: ^Module_Def, name: cstring) -> bool {
    assert(ctx != nil, "add_module_export needs a context")
    assert(m != nil, "add_module_export needs a module")
    assert(name != nil, "add_module_export needs a name")

    return c_add_module_export(ctx, m, name) == 0
}

// **Consumes `val`** — same ownership as `set_property`.
set_module_export :: proc(ctx: ^Context, m: ^Module_Def, name: cstring, val: Value) -> bool {
    assert(ctx != nil, "set_module_export needs a context")
    assert(m != nil, "set_module_export needs a module")
    assert(name != nil, "set_module_export needs a name")

    return c_set_module_export(ctx, m, name, val) == 0
}

// Throw a TypeError; returns the exception sentinel for host C functions.
throw_type_error :: proc(ctx: ^Context, msg: cstring) -> Value {
    assert(ctx != nil, "throw_type_error needs a context")
    assert(msg != nil, "throw_type_error needs a message")

    return c_throw_type_error(ctx, "%s", msg)
}

// Resolve imports on a module record returned by `eval(..., .Module)`.
resolve_module :: proc(ctx: ^Context, module_val: Value) -> bool {
    assert(ctx != nil, "resolve_module needs a context")

    return c_resolve_module(ctx, module_val) == 0
}

// Evaluate a resolved module function. **Consumes `fun_obj`.**
eval_function :: proc(ctx: ^Context, fun_obj: Value) -> Value {
    assert(ctx != nil, "eval_function needs a context")

    return c_eval_function(ctx, fun_obj)
}

// Parse `text` as JSON. Satisfies `is_exception` on malformed input, leaving the exception
// pending. Caller owns the result.
parse_json :: proc(ctx: ^Context, text: string, filename: cstring = "<json>") -> Value {
    assert(ctx != nil, "parse_json needs a context")

    return c_parse_json(ctx, cstring(raw_data(text)), c.size_t(len(text)), filename)
}

// Whether `v` is callable. Needs a context because a function is an object whose class the
// runtime resolves; the tag-based predicates in `value.odin` cannot tell.
is_function :: proc(ctx: ^Context, v: Value) -> bool {
    assert(ctx != nil, "is_function needs a context")

    return c_is_function(ctx, v)
}

// Serialize `v` to a compact JSON string value (the `JSON.stringify` builtin: runs
// getters/`toJSON`, drops function- and `undefined`-valued members). Satisfies
// `is_exception` on a cyclic value or a throwing `toJSON`; yields the JS `undefined`
// value when `v` itself is not serializable. Caller owns the result.
json_stringify :: proc(ctx: ^Context, v: Value) -> Value {
    assert(ctx != nil, "json_stringify needs a context")

    return c_json_stringify(ctx, v, undefined(), undefined())
}
