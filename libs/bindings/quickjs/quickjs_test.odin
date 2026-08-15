package quickjs

import "base:runtime"
import "core:c"
import "core:mem"
import "core:strings"
import "core:testing"

@(private = "file")
new_vm :: proc(t: ^testing.T) -> (rt: ^Runtime, ctx: ^Context) {
    rt = runtime_new()
    testing.expect(t, rt != nil, "runtime_new returned nil")
    ctx = context_new(rt)
    testing.expect(t, ctx != nil, "context_new returned nil")

    return
}

@(private = "file")
free_vm :: proc(rt: ^Runtime, ctx: ^Context) {
    context_free(ctx)
    runtime_free(rt)
}

@(private = "file")
eval_source :: proc(ctx: ^Context, src: string, filename: cstring = "<eval>") -> Value {
    return eval(ctx, strings.clone_to_cstring(src, context.temp_allocator), len(src), filename)
}

@(test)
test_eval_round_trip :: proc(t: ^testing.T) {
    rt, ctx := new_vm(t)
    defer free_vm(rt, ctx)

    v := eval_source(ctx, "1 + 2")
    defer free_value(ctx, v)
    testing.expect(t, !is_exception(v), "eval raised")
    testing.expect(t, is_number(v), "1 + 2 should be a number")

    n, ok := to_i32(ctx, v)
    testing.expect(t, ok, "to_i32 failed")
    testing.expect_value(t, n, i32(3))
}

@(test)
test_string_round_trip :: proc(t: ^testing.T) {
    rt, ctx := new_vm(t)
    defer free_vm(rt, ctx)

    v := eval_source(ctx, "'yuke' + '-' + 'odin'")
    defer free_value(ctx, v)
    testing.expect(t, is_string(v), "expected a string value")

    s, ok := to_string(ctx, v)
    testing.expect(t, ok, "to_string failed")
    defer free_string(ctx, s)
    testing.expect_value(t, s, "yuke-odin")
}

@(test)
test_value_constructors_are_contextless :: proc(t: ^testing.T) {
    // These are the reimplemented `static inline` entry points; they must work
    // without a context because host callbacks run as `proc "c"`.
    testing.expect(t, is_undefined(undefined()), "undefined()")
    testing.expect(t, is_null(null()), "null()")
    testing.expect(t, is_exception(exception()), "exception()")
    testing.expect(t, is_uninitialized(uninitialized()), "uninitialized()")
    testing.expect(t, is_bool(new_bool(true)) && get_bool(new_bool(true)), "new_bool")
    testing.expect(t, get_i32(new_i32(-7)) == -7, "new_i32")
    testing.expect(t, get_f64(new_f64(1.5)) == 1.5, "new_f64")

    // i64 outside the tagged int32 arm must widen to float64, not truncate.
    small := new_i64(42)
    testing.expect(t, small.tag == .Int && get_i32(small) == 42, "new_i64 small stays int")
    big := new_i64(1 << 40)
    testing.expect(t, big.tag == .Float64 && get_f64(big) == f64(1 << 40), "new_i64 large widens")

    testing.expect(t, !is_ref_counted(new_i32(1)), "int is not ref counted")
}

@(test)
test_object_properties :: proc(t: ^testing.T) {
    rt, ctx := new_vm(t)
    defer free_vm(rt, ctx)

    obj := new_object(ctx)
    defer free_value(ctx, obj)

    testing.expect(t, set_property(ctx, obj, "seq", new_i32(9)), "set_property")
    testing.expect(t, set_property(ctx, obj, "id", new_string(ctx, "sess-a")), "set_property string")

    seq := get_property(ctx, obj, "seq")
    defer free_value(ctx, seq)
    n, ok := to_i32(ctx, seq)
    testing.expect(t, ok, "to_i32 on property")
    testing.expect_value(t, n, i32(9))

    missing := get_property(ctx, obj, "nope")
    defer free_value(ctx, missing)
    testing.expect(t, is_undefined(missing), "absent property should be undefined")

    arr := new_array(ctx)
    defer free_value(ctx, arr)
    testing.expect(t, set_index(ctx, arr, 0, new_i32(11)), "set_index")
    first := get_index(ctx, arr, 0)
    defer free_value(ctx, first)
    fv, fok := to_i32(ctx, first)
    testing.expect(t, fok && fv == 11, "get_index round trip")
}

@(test)
test_empty_names_and_strings_are_accepted :: proc(t: ^testing.T) {
    rt, ctx := new_vm(t)
    defer free_vm(rt, ctx)

    // `raw_data` of an empty Odin string is nil, so every counted entry point below
    // hands the engine a nil pointer with a zero length.
    empty := new_string(ctx, "")
    defer free_value(ctx, empty)
    testing.expect(t, is_string(empty), "empty string is a string")

    s, ok := to_string(ctx, empty)
    testing.expect(t, ok, "to_string on the empty string")
    defer free_string(ctx, s)
    testing.expect_value(t, s, "")

    obj := new_object(ctx)
    defer free_value(ctx, obj)

    testing.expect(t, set_property(ctx, obj, "", new_i32(4)), "set_property with an empty name")

    got := get_property(ctx, obj, "")
    defer free_value(ctx, got)
    n, nok := to_i32(ctx, got)
    testing.expect(t, nok, "to_i32 on the empty-named property")
    testing.expect_value(t, n, i32(4))
}

@(private = "file")
host_calls: int

@(private = "file")
host_echo :: proc "c" (ctx: ^Context, this_val: Value, argc: c.int, argv: [^]Value) -> Value {
    context = runtime.default_context()
    host_calls += 1
    if argc < 1 {
        return undefined()
    }

    return dup_value(ctx, argv[0])
}

@(test)
test_host_function :: proc(t: ^testing.T) {
    rt, ctx := new_vm(t)
    defer free_vm(rt, ctx)

    host_calls = 0
    global := global_object(ctx)
    defer free_value(ctx, global)
    testing.expect(t, set_property(ctx, global, "echo", new_function(ctx, host_echo, "echo", 1)), "install echo")

    v := eval_source(ctx, "echo('from js')")
    defer free_value(ctx, v)
    testing.expect(t, !is_exception(v), "echo call raised")
    testing.expect_value(t, host_calls, 1)

    s, ok := to_string(ctx, v)
    testing.expect(t, ok, "echo result to_string")
    defer free_string(ctx, s)
    testing.expect_value(t, s, "from js")
}

@(test)
test_exception_text_includes_stack :: proc(t: ^testing.T) {
    rt, ctx := new_vm(t)
    defer free_vm(rt, ctx)

    v := eval_source(ctx, "function boom() { throw new Error('kaboom'); }\nboom();", "boom.js")
    defer free_value(ctx, v)
    testing.expect(t, is_exception(v), "expected an exception value")
    testing.expect(t, has_exception(ctx), "exception should be pending")

    msg := exception_text(ctx)
    defer delete(msg)
    testing.expect(t, strings.contains(msg, "kaboom"), "message should carry the throw text")
    testing.expect(t, strings.contains(msg, "boom.js"), "stack should name the source file")
    testing.expect(t, !has_exception(ctx), "exception_text should clear the exception")
}

@(test)
test_memory_limit_is_enforced :: proc(t: ^testing.T) {
    rt := runtime_new()
    testing.expect(t, rt != nil, "runtime_new")
    set_memory_limit(rt, 2 * mem.Megabyte)
    ctx := context_new(rt)
    defer free_vm(rt, ctx)

    // A runaway allocation must fail the script, not the process.
    v := eval_source(ctx, "const a = []; for (;;) { a.push('x'.repeat(4096)); } a.length")
    defer free_value(ctx, v)
    testing.expect(t, is_exception(v), "allocation past the cap should raise")

    usage := memory_usage(rt)
    testing.expect(t, usage.malloc_size <= i64(2 * mem.Megabyte), "usage should stay under the cap")
}

@(private = "file")
Budget :: struct {
    ticks: int,
    limit: int,
}

@(private = "file")
budget_interrupt :: proc "c" (rt: ^Runtime, user: rawptr) -> c.int {
    b := (^Budget)(user)
    b.ticks += 1

    return b.ticks > b.limit ? 1 : 0
}

@(test)
test_interrupt_handler_stops_runaway_script :: proc(t: ^testing.T) {
    rt, ctx := new_vm(t)
    defer free_vm(rt, ctx)

    b := Budget {
        limit = 1000,
    }
    set_interrupt_handler(rt, budget_interrupt, &b)

    v := eval_source(ctx, "let x = 0; while (true) { x++; } x")
    defer free_value(ctx, v)
    testing.expect(t, is_exception(v), "runaway loop should be interrupted")
    testing.expect(t, b.ticks > b.limit, "interrupt handler should have fired")

    // The runtime must remain usable for the next turn.
    _ = get_exception(ctx)
    ok := eval_source(ctx, "40 + 2")
    defer free_value(ctx, ok)
    n, got := to_i32(ctx, ok)
    testing.expect(t, got && n == 42, "runtime should survive an interrupt")
}

@(private = "file")
pending_resolve: Value

@(private = "file")
have_pending: bool

@(private = "file")
host_io :: proc "c" (ctx: ^Context, this_val: Value, argc: c.int, argv: [^]Value) -> Value {
    context = runtime.default_context()
    promise, resolve, reject := new_promise(ctx)
    pending_resolve = resolve
    have_pending = true
    free_value(ctx, reject)

    return promise
}

@(test)
test_await_resumes_from_host_promise :: proc(t: ^testing.T) {
    // The yield/resume contract the scheduler depends on: JS parks on a promise
    // the host owns, the host settles it later, then drains the job queue.
    rt, ctx := new_vm(t)
    defer free_vm(rt, ctx)

    have_pending = false
    global := global_object(ctx)
    defer free_value(ctx, global)
    testing.expect(t, set_property(ctx, global, "hostIO", new_function(ctx, host_io, "hostIO", 0)), "install hostIO")

    v := eval_source(
        ctx,
        `globalThis.trace = [];
         (async () => {
             trace.push("parked");
             const body = await hostIO();
             trace.push("resumed:" + body);
         })();
         1`,
    )
    defer free_value(ctx, v)
    testing.expect(t, !is_exception(v), "async eval raised")
    testing.expect(t, have_pending, "host should hold the pending op")

    arg := new_string(ctx, "body")
    defer free_value(ctx, arg)
    args := [1]Value{arg}
    r := call(ctx, pending_resolve, undefined(), args[:])
    free_value(ctx, r)
    free_value(ctx, pending_resolve)

    executed, failed := run_pending_jobs(rt)
    testing.expect(t, !failed, "draining jobs should not raise")
    testing.expect(t, executed > 0, "resolving should have queued a job")

    trace := eval_source(ctx, "trace.join('|')")
    defer free_value(ctx, trace)
    s, ok := to_string(ctx, trace)
    testing.expect(t, ok, "trace to_string")
    defer free_string(ctx, s)
    testing.expect_value(t, s, "parked|resumed:body")
}

// --- per-session allocator --------------------------------------------------
// Mirrors how the daemon binds a session VM to its own arena so that eviction
// reclaims in one shot. Header stores the block size so free/realloc/usable_size
// can recover it.
@(private = "file")
HDR :: 16

@(private = "file")
Session_Heap :: struct {
    arena: mem.Arena,
    buf:   []byte,
    live:  int,
    peak:  int,
    ctx:   runtime.Context,
}

@(private = "file")
heap_alloc :: proc "c" (user: rawptr, size: c.size_t) -> rawptr {
    h := (^Session_Heap)(user)
    context = h.ctx
    block, err := mem.alloc_bytes(int(size) + HDR, 16, mem.arena_allocator(&h.arena))
    if err != nil {
        return nil
    }

    (^u64)(raw_data(block))^ = u64(size)
    h.live += int(size)
    if h.live > h.peak {
        h.peak = h.live
    }

    return rawptr(uintptr(raw_data(block)) + HDR)
}

@(private = "file")
heap_calloc :: proc "c" (user: rawptr, count, size: c.size_t) -> rawptr {
    p := heap_alloc(user, count * size)
    if p != nil {
        h := (^Session_Heap)(user)
        context = h.ctx
        mem.zero(p, int(count * size))
    }

    return p
}

@(private = "file")
heap_free :: proc "c" (user: rawptr, ptr: rawptr) {
    if ptr == nil {
        return
    }

    h := (^Session_Heap)(user)
    h.live -= int((^u64)(uintptr(ptr) - HDR)^)
}

@(private = "file")
heap_realloc :: proc "c" (user: rawptr, ptr: rawptr, size: c.size_t) -> rawptr {
    if ptr == nil {
        return heap_alloc(user, size)
    }
    if size == 0 {
        heap_free(user, ptr)
        return nil
    }

    old := int((^u64)(uintptr(ptr) - HDR)^)
    np := heap_alloc(user, size)
    if np == nil {
        return nil
    }

    h := (^Session_Heap)(user)
    context = h.ctx
    mem.copy(np, ptr, min(old, int(size)))
    heap_free(user, ptr)

    return np
}

@(private = "file")
heap_usable_size :: proc "c" (ptr: rawptr) -> c.size_t {
    if ptr == nil {
        return 0
    }

    return c.size_t((^u64)(uintptr(ptr) - HDR)^)
}

@(test)
test_runtime_on_caller_owned_heap :: proc(t: ^testing.T) {
    h := new(Session_Heap)
    defer free(h)
    h.buf = make([]byte, 8 * mem.Megabyte)
    defer delete(h.buf)
    mem.arena_init(&h.arena, h.buf)
    h.ctx = context

    alloc := Alloc_Functions {
        calloc      = heap_calloc,
        malloc      = heap_alloc,
        free        = heap_free,
        realloc     = heap_realloc,
        usable_size = heap_usable_size,
    }
    rt := runtime_new(&alloc, h)
    testing.expect(t, rt != nil, "runtime_new with a custom allocator")
    ctx := context_new(rt)
    testing.expect(t, ctx != nil, "context_new on a custom heap")

    v := eval_source(ctx, "const t = []; for (let i = 0; i < 500; i++) t.push('part_' + i); t.length")
    n, ok := to_i32(ctx, v)
    testing.expect(t, ok && n == 500, "script should run on the caller's heap")
    free_value(ctx, v)

    testing.expect(t, h.live > 0, "engine should have allocated through our hooks")
    testing.expect(t, h.peak >= h.live, "peak tracks live")

    free_vm(rt, ctx)
    // Eviction in the daemon is exactly this: drop the arena in one shot.
    testing.expect(t, h.live == 0, "every block should have been released before free")
}

@(test)
test_parse_json_ignores_bytes_past_length :: proc(t: ^testing.T) {
    rt, ctx := new_vm(t)
    defer free_vm(rt, ctx)

    // A tool block's argument JSON is a slice with the next block's bytes right after it, so
    // `text[len]` is non-NUL. Slicing an object out of such a buffer reproduces the parse.
    source := "{\"path\":\"x\"}GARBAGE"
    object := source[:12]
    testing.expect_value(t, object, "{\"path\":\"x\"}")
    testing.expect(t, source[12] != 0, "the byte past the object must be non-NUL to reproduce")

    v := parse_json(ctx, object, context.allocator)
    defer free_value(ctx, v)
    testing.expect(t, !is_exception(v), "valid JSON followed by unrelated bytes must still parse")
    testing.expect(t, is_object(v), "parsed value should be an object")

    path := get_property(ctx, v, "path")
    defer free_value(ctx, path)
    s, ok := to_string(ctx, path)
    testing.expect(t, ok, "path should read back as a string")
    defer free_string(ctx, s)
    testing.expect_value(t, s, "x")
}
