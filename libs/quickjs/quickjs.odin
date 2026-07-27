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

// Create an engine instance. Pass `alloc` to bind this runtime to a caller-owned
// allocator (the per-session arena); `user` is handed back to every hook. With
// `alloc` nil the engine uses its own malloc and `runtime_free` will not return
// pages to the OS on its own.
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

// Hard ceiling on engine allocation. Exceeding it fails the running script with
// an out-of-memory exception rather than aborting the daemon.
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

// Install the CPU budget hook. `cb` runs at interpreter checkpoints; returning
// non-zero aborts the script with a catchable exception. It cannot interrupt a
// single long-running engine builtin.
set_interrupt_handler :: proc(rt: ^Runtime, cb: Interrupt_Handler, user: rawptr = nil) {
    assert(rt != nil, "set_interrupt_handler needs a runtime")

    c_set_interrupt_handler(rt, cb, user)
}

job_pending :: proc(rt: ^Runtime) -> bool {
    assert(rt != nil, "job_pending needs a runtime")

    return c_is_job_pending(rt)
}

// Drain the microtask queue. This is what resumes `await` after the host has
// settled a promise, so the event loop calls it once per turn of the reactor.
// `failed` reports that a job raised; the exception is left on its context.
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

context_new :: proc(rt: ^Runtime) -> ^Context {
    assert(rt != nil, "context_new needs a runtime")

    return c_new_context(rt)
}

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

// Compile and run `src`. `filename` appears in stack traces. On failure the
// result satisfies `is_exception` and the detail is available via
// `exception_text`. Caller owns the result.
eval :: proc(
    ctx: ^Context,
    src: string,
    filename: string = "<eval>",
    kind: Eval_Kind = .Global,
    flags: Eval_Flags = {},
) -> Value {
    assert(ctx != nil, "eval needs a context")

    csrc := strings.clone_to_cstring(src, context.temp_allocator)
    cname := strings.clone_to_cstring(filename, context.temp_allocator)

    return c_eval(ctx, csrc, c.size_t(len(src)), cname, c.int(kind) | transmute(c.int)flags)
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

// Caller owns the result.
get_property :: proc(ctx: ^Context, obj: Value, name: string) -> Value {
    assert(ctx != nil, "get_property needs a context")

    cname := strings.clone_to_cstring(name, context.temp_allocator)

    return c_get_property_str(ctx, obj, cname)
}

// **Consumes `val`** — the engine takes the reference whether or not the store
// succeeds, so the caller must not also free it.
set_property :: proc(ctx: ^Context, obj: Value, name: string, val: Value) -> bool {
    assert(ctx != nil, "set_property needs a context")

    cname := strings.clone_to_cstring(name, context.temp_allocator)

    return c_set_property_str(ctx, obj, cname, val) >= 0
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

// Expose an Odin procedure to JavaScript. `arity` is the advertised
// `Function.length`, not a limit on the arguments actually passed.
new_function :: proc(ctx: ^Context, fn: C_Function, name: string, arity: int = 0) -> Value {
    assert(ctx != nil, "new_function needs a context")
    assert(fn != nil, "new_function needs a procedure")
    assert(arity >= 0, "arity must be non-negative")

    cname := strings.clone_to_cstring(name, context.temp_allocator)

    return c_new_cfunction2(ctx, fn, cname, c.int(arity), .Generic, 0)
}

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
free_string :: proc(ctx: ^Context, s: string) {
    assert(ctx != nil, "free_string needs a context")

    if len(s) == 0 {
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

to_bool :: proc(ctx: ^Context, v: Value) -> (value: bool, ok: bool) {
    assert(ctx != nil, "to_bool needs a context")

    rc := c_to_bool(ctx, v)
    if rc < 0 {
        return false, false
    }

    return rc != 0, true
}

// The conversion must run before the named result is read; returning it in the
// same expression as the call would copy the value out first.
to_i32 :: proc(ctx: ^Context, v: Value) -> (value: i32, ok: bool) {
    assert(ctx != nil, "to_i32 needs a context")

    ok = c_to_i32(ctx, &value, v) == 0

    return
}

to_i64 :: proc(ctx: ^Context, v: Value) -> (value: i64, ok: bool) {
    assert(ctx != nil, "to_i64 needs a context")

    ok = c_to_i64(ctx, &value, v) == 0

    return
}

to_f64 :: proc(ctx: ^Context, v: Value) -> (value: f64, ok: bool) {
    assert(ctx != nil, "to_f64 needs a context")

    ok = c_to_f64(ctx, &value, v) == 0

    return
}

// Create a pending promise plus its settle functions. This is the yield point
// for host IO: return `promise` to the script, park the task, then `call`
// `resolve` or `reject` from the completion callback and drain the job queue
// with `run_pending_jobs`. Caller owns all three values.
new_promise :: proc(ctx: ^Context) -> (promise: Value, resolve: Value, reject: Value) {
    assert(ctx != nil, "new_promise needs a context")

    funcs: [2]Value
    promise = c_new_promise_capability(ctx, raw_data(funcs[:]))

    return promise, funcs[0], funcs[1]
}
