package js

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"

import qjs "libs:bindings/quickjs"
import "libs:offload"

// Allocation ceiling for a runtime. Overrun raises a catchable exception rather than
// aborting, so a runaway script fails its own turn instead of the process.
DEFAULT_MEMORY_LIMIT :: 64 * mem.Megabyte

// Stack ceiling, which bounds recursion depth the same way.
DEFAULT_STACK_LIMIT :: 1 * mem.Megabyte

// Wall clock one entry into JS may hold the thread before the interrupt handler reclaims it.
// Work that needs longer belongs off the reactor; exceeding this is a bug either way.
DEFAULT_DEADLINE :: 5 * time.Second

Error :: enum {
    None,

    // The runtime, context, or an owned string could not be allocated.
    Out_Of_Memory,

    // The configured root does not resolve, or is not a directory.
    Invalid_Root,
}

// One host module and the exports it installs. Registration is data rather than a branch in
// the loader, so an embedder's module set is a value it owns.
Module :: struct {
    // Specifier scripts import, `yuke:`-scheme by convention.
    name:    string,

    // Installs the exports when the module is first imported.
    init:    qjs.Module_Init_Func,

    // Every name `init` will set. Declared up front because ES modules resolve their
    // bindings before any module body runs.
    exports: []string,
}

// Where a script fault goes; policy differs per embedder (daemon logs, TUI latches) and does
// not belong here. A TUI in particular must not write to stderr while the alternate screen is up.
Report :: #type proc(user: rawptr, source: string, text: string)

Options :: struct {
    // The modules this embedder installs, chosen at the call site. Copied by `init`, so a
    // temporary is fine; each module's own `name` and `exports` must still outlive the host.
    modules:      []Module,

    // Directory every `yuke:fs` path must resolve inside, canonicalized at init. Empty
    // leaves the module uninstalled — containment cannot be decided without a root to check against.
    root:         string,

    // Where `yuke:fs` runs its blocking passes. Nil leaves the module uninstalled: a blocking
    // read on the loop thread would stall everything else the embedder is driving.
    pool:         ^offload.Pool,

    // Embedder state, recovered inside module callbacks with `user_of`.
    user:         rawptr,

    // Reporting seam; nil discards.
    report:       Report,

    // Zero takes the matching `DEFAULT_*`.
    memory_limit: int,
    stack_limit:  int,
    deadline:     time.Duration,

    // Backs the owned root and every in-flight host operation.
    allocator:    mem.Allocator,
}

// One QuickJS runtime and context, recovered via opaque pointers rather than a global so a
// process may hold several. Teardown is ordered: the pool drains before `destroy` (see `pending`).
Host :: struct {
    // Nil until `init` succeeds; every entry point tolerates that.
    rt:          ^qjs.Runtime,
    ctx:         ^qjs.Context,

    // Owned canonical `yuke:fs` root; empty when the module is not installed.
    root:        string,

    // Borrowed pool the fs module offloads onto.
    pool:        ^offload.Pool,

    // Borrowed embedder state and its reporting policy.
    user:        rawptr,
    report:      Report,

    // Installed modules, owned: a caller composes its set at the call site, so borrowing
    // would leave the loader reading a temporary after `init` returned.
    modules:     []Module,
    deadline:    time.Duration,

    // When the current entry must yield; zero outside an entry, which makes the interrupt
    // handler a no-op for work this host isn't driving.
    deadline_at: time.Time,

    // Latched when the interrupt handler fired, so a deadline is distinguishable from an
    // ordinary exception.
    interrupted: bool,

    // In-flight host operations. Each owns a live promise, so this must reach zero before
    // the context is freed; `destroy` asserts it.
    pending:     int,
    allocator:   mem.Allocator,
}

// Bring up the runtime, its limits, and the module loader. `yuke:fs` is installed exactly
// when both a root and a pool are supplied.
init :: proc(h: ^Host, options: Options) -> Error {
    assert(h != nil, "init needs host storage")
    assert(h.rt == nil, "a host is initialized once")
    assert(options.allocator.procedure != nil, "a host needs an allocator")

    h.user = options.user
    h.report = options.report
    h.allocator = options.allocator
    h.deadline = options.deadline if options.deadline > 0 else DEFAULT_DEADLINE

    // Both halves or neither: a root with no pool would have to run blocking IO on the
    // caller's thread, and a pool with no root has nothing to contain paths against.
    if options.root != "" && options.pool != nil {
        // Resolved once here so every later containment check is a prefix test rather than
        // a filesystem call.
        canonical, cerr := os.get_absolute_path(options.root, options.allocator)
        if cerr != nil {
            return .Invalid_Root
        }

        defer delete(canonical, options.allocator)

        if !os.is_dir(canonical) {
            return .Invalid_Root
        }

        cloned, clone_err := strings.clone(canonical, options.allocator)
        if clone_err != nil {
            return .Out_Of_Memory
        }

        h.root = cloned
        h.pool = options.pool
    }

    if len(options.modules) > 0 {
        installed, modules_err := slice.clone(options.modules, options.allocator)
        if modules_err != nil {
            destroy(h)

            return .Out_Of_Memory
        }

        h.modules = installed
    }

    h.rt = qjs.runtime_new()
    if h.rt == nil {
        destroy(h)

        return .Out_Of_Memory
    }

    qjs.set_runtime_opaque(h.rt, h)
    qjs.set_memory_limit(h.rt, options.memory_limit if options.memory_limit > 0 else DEFAULT_MEMORY_LIMIT)
    qjs.set_max_stack_size(h.rt, options.stack_limit if options.stack_limit > 0 else DEFAULT_STACK_LIMIT)
    qjs.set_interrupt_handler(h.rt, interrupt, h)
    qjs.set_module_loader(h.rt, nil, module_loader, h)

    h.ctx = qjs.context_new(h.rt)
    if h.ctx == nil {
        destroy(h)

        return .Out_Of_Memory
    }

    qjs.set_context_opaque(h.ctx, h)

    return .None
}

// Release the runtime. The embedder must have drained its pool first: a completion still in
// flight owns the settle functions of a promise in this context.
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

    if h.root != "" {
        delete(h.root, h.allocator)
        h.root = ""
    }

    if h.modules != nil {
        delete(h.modules, h.allocator)
        h.modules = nil
    }

    h.pool = nil
    h.user = nil
}

// The embedder state a module callback belongs to.
user_of :: proc(ctx: ^qjs.Context) -> rawptr {
    h := host_of(ctx)

    return h.user if h != nil else nil
}

// The host owning `ctx`.
host_of :: proc(ctx: ^qjs.Context) -> ^Host {
    return (^Host)(qjs.get_context_opaque(ctx))
}

// Evaluate `source` as an ES module; false on failure, reported. A throwing top level rejects
// the returned promise rather than raising `is_exception`, so that check alone can't detect it.
eval_module :: proc(h: ^Host, name: string, source: string, allocator: mem.Allocator) -> bool {
    assert(h != nil, "a module evaluation needs a host")

    if h.ctx == nil {
        return false
    }

    csource, source_err := strings.clone_to_cstring(source, allocator)
    cname, name_err := strings.clone_to_cstring(name, allocator)

    if source_err != nil || name_err != nil {
        return false
    }

    defer delete(csource, allocator)
    defer delete(cname, allocator)

    enter(h)
    result := qjs.eval(h.ctx, csource, len(source), cname, .Module)
    leave(h)

    defer qjs.free_value(h.ctx, result)

    if qjs.is_exception(result) {
        report_exception(h, name)

        return false
    }

    // The module body runs on the job queue, so nothing has executed yet.
    drain(h)

    switch qjs.promise_state(h.ctx, result) {
    case .Not_A_Promise, .Fulfilled:
        return true

    case .Pending:
        // A top-level `await` that never settled. Reporting success would leave the
        // embedder believing a module is loaded while its body has not finished.
        report(h, name, "module did not finish evaluating")

        return false

    case .Rejected:
        reason := qjs.promise_result(h.ctx, result)
        defer qjs.free_value(h.ctx, reason)

        report_value(h, name, reason)

        return false
    }

    return false
}

// Invoke `fn` under the deadline, reporting against `source` on exception. Result is owned
// by the caller and undefined when `ok` is false; draining is left to the caller.
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

    enter(h)
    result = qjs.call(h.ctx, fn, this, args)
    leave(h)

    if qjs.is_exception(result) {
        report_exception(h, source)
        qjs.free_value(h.ctx, result)

        return qjs.undefined(), false
    }

    return result, true
}

// Run whatever microtasks the last entry queued. Every JS entry path ends here, so a promise
// settled by a host operation reaches its continuations before the embedder moves on.
drain :: proc(h: ^Host) {
    assert(h != nil, "a job drain needs a host")

    if h.ctx == nil || !qjs.job_pending(h.rt) {
        return
    }

    enter(h)
    _, failed := qjs.run_pending_jobs(h.rt)
    leave(h)

    if failed {
        report_exception(h, "microtask")
    }
}

// Arm the deadline for one entry into JS. Entries do not nest: a host operation's
// completion runs from the embedder's loop, never from inside a script.
@(private)
enter :: proc(h: ^Host) {
    assert(h.deadline_at == {}, "an entry into js is never re-entered")

    h.deadline_at = time.time_add(time.now(), h.deadline)
    h.interrupted = false
}

@(private)
leave :: proc(h: ^Host) {
    h.deadline_at = {}
}

// Reclaims the thread from a script that will not yield. Runs inside the engine — may read
// the clock but must not allocate or report — and only interrupts between interpreter steps.
@(private)
interrupt :: proc "c" (rt: ^qjs.Runtime, user: rawptr) -> c.int {
    h := (^Host)(user)

    if h == nil || h.deadline_at == {} {
        return 0
    }

    if time.now()._nsec < h.deadline_at._nsec {
        return 0
    }

    h.interrupted = true

    return 1
}

// Resolve an installed module. The set is closed: an unknown specifier is a script error,
// never a filesystem lookup.
@(private)
module_loader :: proc "c" (ctx: ^qjs.Context, module_name: cstring, opaque: rawptr) -> ^qjs.Module_Def {
    context = runtime.default_context()

    h := (^Host)(opaque)
    name := string(module_name)

    if h != nil {
        for module in h.modules {
            if module.name == name {
                return module_define(ctx, module_name, module.init, module.exports)
            }
        }
    }

    // Naming the specifier is what tells a script author "you asked for a module this
    // embedder does not install" apart from a typo, without privileging any one name.
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
    if m == nil {
        return nil
    }

    for export in exports {
        cexport, err := strings.clone_to_cstring(export, context.temp_allocator)
        if err != nil {
            return nil
        }

        if !qjs.add_module_export(ctx, m, cexport) {
            return nil
        }
    }

    return m
}

// Hand the embedder the pending exception's text. A script fault is an operating outcome —
// a bad tool, a bad widget — never an assertion.
@(private)
report_exception :: proc(h: ^Host, source: string) {
    text := qjs.exception_text(h.ctx, context.temp_allocator)

    if h.interrupted {
        report(h, source, "exceeded its deadline")

        return
    }

    report(h, source, text)
}

// Report a value rather than the pending exception: a rejected promise's reason is a value
// in hand, and reading it does not make it the current exception.
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
    if h.report == nil {
        return
    }

    h.report(h.user, source, text)
}
