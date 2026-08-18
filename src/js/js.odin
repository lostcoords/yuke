package js

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:mem"
import "core:nbio"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:time"

import qjs "libs:bindings/quickjs"
import "libs:offload"

// Allocation ceiling; overrun raises a catchable exception, not abort.
DEFAULT_MEMORY_LIMIT :: 64 * mem.Megabyte

DEFAULT_STACK_LIMIT :: 1 * mem.Megabyte

// Wall-clock cap for one JS entry; longer work belongs off the reactor.
DEFAULT_DEADLINE :: 5 * time.Second

// Per-tick wait while TLA awaits host ops; matches offload drain cadence.
MODULE_AWAIT_TICK :: 10 * time.Millisecond

Error :: enum {
    None,
    Invalid_Root,
}

// Host module registration; the set is a value the embedder owns.
Module :: struct {
    name:    string,
    init:    qjs.Module_Init_Func,
    // Declared up front: ES modules resolve bindings before any module body runs.
    exports: []string,
}

// Script-fault reporting; policy is embedder-owned (TUI must not write stderr on alt screen).
Report :: #type proc(user: rawptr, source: string, text: string)

// Called after each drain, on the loop thread and outside the JS entry, so an embedder can
// observe promises it is waiting on without polling.
On_Drain :: #type proc(user: rawptr)

// Resolves non-native import specs to ES source. `owned` true: loader frees `source` after compile.
Resolve :: #type proc(user: rawptr, name: string, allocator: mem.Allocator) -> (source: string, owned: bool, ok: bool)

Options :: struct {
    // Copied by `init`; each module's `name`/`exports` must still outlive the host.
    modules:      []Module,
    // What a relative path resolves against, canonicalized at init. Empty rejects relative
    // paths, which is what an embedder with no single workspace wants.
    base:         string,
    // Nil leaves the filesystem modules uninstalled: blocking IO must not run on the loop thread.
    pool:         ^offload.Pool,
    // Commands hold a worker for their whole timeout. Nil runs them on `pool`.
    exec_pool:    ^offload.Pool,
    user:         rawptr,
    report:       Report,
    on_drain:     On_Drain,
    // Nil keeps the loader closed — unknown specifier throws.
    resolve:      Resolve,
    // Zero takes the matching `DEFAULT_*`.
    memory_limit: int,
    stack_limit:  int,
    deadline:     time.Duration,
    allocator:    mem.Allocator,
}

// One QuickJS runtime+context via opaques (not globals). Drain the pool before destroy.
Host :: struct {
    rt:              ^qjs.Runtime,
    ctx:             ^qjs.Context,
    // Owned canonical base for relative paths; empty requires absolute ones.
    base:            string,
    pool:            ^offload.Pool,
    exec_pool:       ^offload.Pool,
    user:            rawptr,
    report:          Report,
    on_drain:        On_Drain,
    resolve:         Resolve,
    // Owned copy of the caller's module set.
    modules:         []Module,
    deadline:        time.Duration,
    // Zero outside an entry; interrupt is a no-op then.
    deadline_at:     time.Time,
    // Latched when the interrupt handler fired (vs ordinary exception).
    interrupted:     bool,
    // In-flight host ops owning live promises; must be 0 before destroy.
    pending:         int,
    // False while abandoning a failed eval so settled continuations cannot submit new host ops.
    ops_open:        bool,
    // Set on the loop thread by `ops_close`, read by workers. Long-running work stops early
    // rather than making the embedder's drain wait it out.
    cancelled:       bool,
    // Native class for per-run cancellation signals.
    cancel_class:    qjs.Class_ID,
    // Latched by the daemon's first tool call: every later host op carries its run signal.
    cancel_enforced: bool,
    allocator:       mem.Allocator,
}

// Bring up runtime, limits, and loader. The filesystem modules need a pool.
init :: proc(h: ^Host, options: Options) -> Error {
    assert(h != nil, "init needs host storage")
    assert(h.rt == nil, "a host is initialized once")
    assert(options.allocator.procedure != nil, "a host needs an allocator")

    h.user = options.user
    h.report = options.report
    h.on_drain = options.on_drain
    h.resolve = options.resolve
    h.allocator = options.allocator
    h.deadline = options.deadline if options.deadline > 0 else DEFAULT_DEADLINE
    h.ops_open = true

    // A base is optional; a pool is not, because every path op offloads.
    if options.pool != nil {
        h.pool = options.pool
        h.exec_pool = options.exec_pool if options.exec_pool != nil else options.pool
    }

    if options.base != "" {
        canonical, cerr := os.get_absolute_path(options.base, options.allocator)
        if cerr != nil do return .Invalid_Root

        defer delete(canonical, options.allocator)

        if !os.is_dir(canonical) do return .Invalid_Root

        h.base = strings.clone(canonical, options.allocator)
    }

    if len(options.modules) > 0 do h.modules = slice.clone(options.modules, options.allocator)

    h.rt = qjs.runtime_new()

    qjs.set_runtime_opaque(h.rt, h)
    qjs.set_memory_limit(h.rt, options.memory_limit if options.memory_limit > 0 else DEFAULT_MEMORY_LIMIT)
    qjs.set_max_stack_size(h.rt, options.stack_limit if options.stack_limit > 0 else DEFAULT_STACK_LIMIT)
    qjs.set_interrupt_handler(h.rt, interrupt, h)
    qjs.set_module_loader(h.rt, nil, module_loader, h)

    cancel_class, _ := qjs.class_register(
        h.rt,
        qjs.Class_Def{class_name = "YukeCancelSignal", finalizer = cancel_signal_finalize},
    )
    h.cancel_class = cancel_class

    h.ctx = qjs.context_new(h.rt)

    qjs.set_context_opaque(h.ctx, h)

    return .None
}

// Embedder must drain its pool first: in-flight completions own settle functions in this context.
destroy :: proc(h: ^Host) {
    assert(h != nil, "destroy needs host storage")
    assert(h.pending == 0, "a host operation outlived the context that owns its promise")

    if h.ctx != nil {
        qjs.context_free(h.ctx)
        h.ctx = nil
    }

    if h.rt != nil {
        qjs.runtime_free(h.rt)
        h.rt = nil
    }

    if h.base != "" {
        delete(h.base, h.allocator)
        h.base = ""
    }

    if h.modules != nil {
        delete(h.modules, h.allocator)
        h.modules = nil
    }

    h.pool = nil
    h.exec_pool = nil
    h.user = nil
    h.cancel_class = qjs.INVALID_CLASS_ID
    h.cancel_enforced = false
}

// Permanently refuse new host operations while allowing submitted ones to finish. Work
// already on a worker sees `cancelled` and stops at its next check.
ops_close :: proc(h: ^Host) {
    assert(h != nil, "closing host operations needs a host")

    h.ops_open = false
    sync.atomic_store(&h.cancelled, true)
}

// Worker side of `ops_close`.
cancelled :: proc(h: ^Host) -> bool {
    assert(h != nil, "a cancellation check needs a host")

    return sync.atomic_load(&h.cancelled)
}

ops_idle :: proc(h: ^Host) -> bool {
    assert(h != nil, "host operation status needs a host")
    assert(h.pending >= 0, "host operation count stays non-negative")

    return h.pending == 0
}

// A host op owns a live promise in this context, so the host cannot be destroyed while one
// is outstanding. Every module that offloads counts through this pair.
op_begin :: proc(h: ^Host) {
    assert(h != nil, "a host op needs a host")
    assert(h.ops_open, "a host op started after operations closed")

    h.pending += 1
}

// Settle before calling this: `drain` runs the continuations the settle queued.
op_end :: proc(h: ^Host) {
    assert(h != nil, "a host op needs a host")
    assert(h.pending > 0, "a host op completed without being counted")

    h.pending -= 1
    drain(h)
}

user_of :: proc(ctx: ^qjs.Context) -> rawptr {
    h := host_of(ctx)

    return h.user if h != nil else nil
}

host_of :: proc(ctx: ^qjs.Context) -> ^Host {
    return (^Host)(qjs.get_context_opaque(ctx))
}

// Clone one string argument into an arena. `ok` false leaves a pending exception, which the
// caller returns after it releases whatever it had built.
@(private)
arg_string :: proc(
    ctx: ^qjs.Context,
    argv: [^]qjs.Value,
    argc: c.int,
    index: c.int,
    allocator: mem.Allocator,
    out: ^string,
) -> (
    qjs.Value,
    bool,
) {
    if argc <= index || !qjs.is_string(argv[index]) do return qjs.throw_type_error(ctx, "a string argument is required"), false

    value, got := qjs.to_string(ctx, argv[index])
    if !got do return qjs.throw_type_error(ctx, "a string argument could not be read"), false

    defer qjs.free_string(ctx, value)

    owned, clone_err := strings.clone(value, allocator)
    if clone_err != nil do return qjs.throw_type_error(ctx, "out of memory"), false

    out^ = owned

    return qjs.undefined(), true
}

// Eval as ES module; false on failure. TLA drains microtasks and ticks the pool until settle or deadline;
// pending with nothing in flight fails so a half-evaluated entry is never treated as loaded.
// Failure paths with in-flight host ops close ops and wait them out so abandoned continuations
// cannot submit after the pool stops accepting.
eval_module :: proc(h: ^Host, name: string, source: string, allocator: mem.Allocator) -> bool {
    assert(h != nil, "a module evaluation needs a host")

    if h.ctx == nil do return false

    csource, source_err := strings.clone_to_cstring(source, allocator)
    cname, name_err := strings.clone_to_cstring(name, allocator)

    if source_err != nil || name_err != nil do return false

    defer delete(csource, allocator)
    defer delete(cname, allocator)

    enter(h)
    result := qjs.eval(h.ctx, csource, len(source), cname, .Module)
    leave(h)

    defer qjs.free_value(h.ctx, result)

    if qjs.is_exception(result) {
        report_exception(h, name)

        return eval_module_fail(h)
    }

    // Module body runs on the job queue; nothing has executed yet.
    drain(h)

    // Same budget as one JS entry for how long TLA may stall load.
    deadline_at := time.time_add(time.now(), h.deadline)

    for {
        switch qjs.promise_state(h.ctx, result) {
        case .Not_A_Promise, .Fulfilled:
            return true

        case .Rejected:
            reason := qjs.promise_result(h.ctx, result)
            defer qjs.free_value(h.ctx, reason)

            report_value(h, name, reason)

            return eval_module_fail(h)

        case .Pending:
            remaining := module_await_remaining(deadline_at)
            if remaining <= 0 {
                report(h, name, "module did not finish evaluating")

                return eval_module_fail(h)
            }

            // Nothing left that can settle the module: no host ops and no microtasks.
            if h.pending == 0 {
                if qjs.job_pending(h.rt) {
                    drain(h, remaining)
                    continue
                }

                report(h, name, "module did not finish evaluating")

                return eval_module_fail(h)
            }

            if h.pool == nil {
                report(h, name, "module did not finish evaluating")

                return eval_module_fail(h)
            }

            assert(
                h.pool.loop == nbio.current_thread_event_loop(),
                "module await must run on the pool's event-loop thread",
            )

            tick_timeout := min(MODULE_AWAIT_TICK, remaining)
            if err := nbio.tick(tick_timeout); err != nil {
                report(h, name, "event loop failed while evaluating module")

                return eval_module_fail(h)
            }

            // Completions drain themselves; catch leftover microtasks before re-check.
            remaining = module_await_remaining(deadline_at)
            if remaining > 0 {
                drain(h, remaining)
            } else {
                drain(h, 1 * time.Millisecond)
            }
        }
    }
}

@(private)
module_await_remaining :: proc(deadline_at: time.Time) -> time.Duration {
    left := deadline_at._nsec - time.now()._nsec

    return time.Duration(left) if left > 0 else 0
}

// After a failed eval: refuse new host ops, wait in-flight ones out, then reopen.
// Prevents abandoned TLA continuations from submit-after-drain during embedder teardown.
@(private)
eval_module_fail :: proc(h: ^Host) -> bool {
    wait_host_ops_idle(h)

    return false
}

// Tick until pending host ops finish. ops_open is false so resumed script cannot submit more.
@(private)
wait_host_ops_idle :: proc(h: ^Host) {
    assert(h != nil, "wait_host_ops_idle needs a host")

    if h.pending == 0 {
        drain(h)

        return
    }

    assert(h.ops_open, "ops_open is only closed by wait_host_ops_idle")
    h.ops_open = false
    defer h.ops_open = true

    assert(h.pool != nil, "pending host ops always have a pool")
    assert(
        h.pool.loop == nbio.current_thread_event_loop(),
        "wait_host_ops_idle must run on the pool's event-loop thread",
    )

    for h.pending > 0 {
        if err := nbio.tick(MODULE_AWAIT_TICK); err != nil do continue
    }

    drain(h)
}

// Invoke `fn` under the deadline; result owned by caller, undefined when `ok` is false.
call :: proc(
    h: ^Host,
    fn: qjs.Value,
    this: qjs.Value,
    args: []qjs.Value,
    source: string,
) -> (
    result: qjs.Value,
    ok: bool,
) {
    assert(h != nil, "a call needs a host")
    assert(h.ctx != nil, "a call needs a live context")

    result = call_value(h, fn, this, args)

    if qjs.is_exception(result) {
        report_exception(h, source)
        qjs.free_value(h.ctx, result)

        return qjs.undefined(), false
    }

    return result, true
}

// Invoke `fn` under the deadline and leave any exception pending for the caller to take.
// Caller owns the result.
call_value :: proc(h: ^Host, fn: qjs.Value, this: qjs.Value, args: []qjs.Value) -> qjs.Value {
    assert(h != nil, "a call needs a host")
    assert(h.ctx != nil, "a call needs a live context")

    enter(h)
    result := qjs.call(h.ctx, fn, this, args)
    leave(h)

    return result
}

// Run microtasks the last entry queued so host-settled promises reach continuations.
// `budget` > 0 clips the interrupt deadline (used so TLA wait drains cannot overrun the load budget).
drain :: proc(h: ^Host, budget: time.Duration = 0) {
    assert(h != nil, "a job drain needs a host")

    if h.ctx == nil || !qjs.job_pending(h.rt) do return

    enter(h, budget)
    _, failed := qjs.run_pending_jobs(h.rt)
    leave(h)

    if failed do report_exception(h, "microtask")

    // After `leave`, so the hook may enter JS again if it needs to.
    if h.on_drain != nil do h.on_drain(h.user)
}

// Arm the interrupt deadline for one JS entry. Entries do not nest.
// `budget` > 0 uses min(budget, h.deadline); zero uses the host default.
@(private)
enter :: proc(h: ^Host, budget: time.Duration = 0) {
    assert(h.deadline_at == {}, "an entry into js is never re-entered")

    limit := h.deadline
    if budget > 0 do limit = min(budget, h.deadline)

    h.deadline_at = time.time_add(time.now(), limit)
    h.interrupted = false
}

@(private)
leave :: proc(h: ^Host) {
    h.deadline_at = {}
}

// Engine interrupt: may read the clock but must not allocate or report.
@(private)
interrupt :: proc "c" (rt: ^qjs.Runtime, user: rawptr) -> c.int {
    h := (^Host)(user)

    if h == nil || h.deadline_at == {} do return 0

    if time.now()._nsec < h.deadline_at._nsec do return 0

    h.interrupted = true

    return 1
}

// Closed module set: unknown specifier is a script error, never a filesystem lookup.
@(private)
module_loader :: proc "c" (ctx: ^qjs.Context, module_name: cstring, opaque: rawptr) -> ^qjs.Module_Def {
    context = runtime.default_context()

    h := (^Host)(opaque)
    name := string(module_name)

    if h != nil {
        for module in h.modules {
            if module.name == name do return module_define(ctx, module_name, module.init, module.exports)
        }

        // Embedder resolve for non-native specs; compile error leaves the pending exception.
        if h.resolve != nil {
            if source, owned, ok := h.resolve(h.user, name, h.allocator); ok {
                m := compile_module(ctx, module_name, source)
                if owned do delete(source, h.allocator)

                return m
            }
        }
    }

    message, err := strings.clone_to_cstring(
        fmt.tprintf("module %q is not installed here", name),
        context.temp_allocator,
    )

    if err != nil {
        _ = qjs.throw_type_error(ctx, "unknown module")

        return nil
    }

    _ = qjs.throw_type_error(ctx, message)

    return nil
}

@(private)
module_define :: proc(
    ctx: ^qjs.Context,
    name: cstring,
    init: qjs.Module_Init_Func,
    exports: []string,
) -> ^qjs.Module_Def {
    m := qjs.new_cmodule(ctx, name, init)
    if m == nil do return nil

    for export in exports {
        cexport, err := strings.clone_to_cstring(export, context.temp_allocator)
        if err != nil do return nil

        if !qjs.add_module_export(ctx, m, cexport) do return nil
    }

    return m
}

// Compile-only eval yields Module_Def via heap pointer (quickjs-libc). Syntax error: nil + pending exception.
@(private)
compile_module :: proc(ctx: ^qjs.Context, name: cstring, source: string) -> ^qjs.Module_Def {
    h := host_of(ctx)

    csource, err := strings.clone_to_cstring(source, h.allocator)
    if err != nil {
        _ = qjs.throw_type_error(ctx, "module source could not be prepared")

        return nil
    }

    defer delete(csource, h.allocator)

    compiled := qjs.eval(ctx, csource, len(source), name, .Module, {.Compile_Only})
    if qjs.is_exception(compiled) do return nil

    assert(qjs.is_module(compiled), "a compile-only module eval must yield a module")
    m := (^qjs.Module_Def)(qjs.get_ptr(compiled))
    qjs.free_value(ctx, compiled)

    return m
}

// Script fault is an operating outcome, never an assertion.
@(private)
report_exception :: proc(h: ^Host, source: string) {
    text := qjs.exception_text(h.ctx, context.temp_allocator)

    if h.interrupted {
        report(h, source, "exceeded its deadline")

        return
    }

    report(h, source, text)
}

// Report a value in hand (e.g. rejection reason), not the pending exception.
@(private)
report_value :: proc(h: ^Host, source: string, value: qjs.Value) {
    text, readable := qjs.to_string(h.ctx, value)
    if !readable {
        report(h, source, "rejected")

        return
    }

    defer qjs.free_string(h.ctx, text)

    report(h, source, text)
}

@(private)
report :: proc(h: ^Host, source: string, text: string) {
    if h.report == nil do return

    h.report(h.user, source, text)
}
