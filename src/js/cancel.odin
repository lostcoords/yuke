package js

import "base:runtime"
import "core:c"
import "core:mem"
import "core:strings"
import "core:sync"

import qjs "libs:bindings/quickjs"

// Per-run ambient context for host ops. The signal object and every job own one reference;
// workers read `aborted`. `default_cwd` is the run's working dir, owned and applied by
// `yuke:exec` when a call names none.
Run_Scope :: struct {
    allocator:   mem.Allocator,
    refs:        int,
    aborted:     bool,
    default_cwd: string,
}

// After `yuked.js` finishes, every later host op must carry a run signal. Startup
// top-level await may omit it; a canceled continuation cannot.
cancel_enforce :: proc(h: ^Host) {
    assert(h != nil && h.ctx != nil, "enforcing cancellation needs a live host")

    h.cancel_enforced = true
}

// Create the signal passed to one tool handler. Caller owns the returned JS value.
// `default_cwd` is cloned into the scope; pass "" for no run working directory.
cancel_signal_new :: proc(h: ^Host, default_cwd: string) -> (qjs.Value, ^Run_Scope, bool) {
    assert(h != nil && h.ctx != nil, "creating a cancellation signal needs a live host")
    assert(h.cancel_class != qjs.INVALID_CLASS_ID, "a live host registered its cancellation class")

    scope, alloc_err := new(Run_Scope, h.allocator)
    if alloc_err != nil do return qjs.undefined(), nil, false
    scope^ = {
        allocator = h.allocator,
        refs      = 1,
    }

    if default_cwd != "" {
        cwd, cwd_err := strings.clone(default_cwd, h.allocator)
        if cwd_err != nil {
            free(scope, h.allocator)

            return qjs.undefined(), nil, false
        }

        scope.default_cwd = cwd
    }

    signal := qjs.new_object_class(h.ctx, h.cancel_class)
    if qjs.is_exception(signal) {
        exception := qjs.get_exception(h.ctx)
        qjs.free_value(h.ctx, exception)
        run_scope_free(scope)

        return qjs.undefined(), nil, false
    }
    if !qjs.set_opaque(signal, scope) {
        qjs.free_value(h.ctx, signal)
        run_scope_free(scope)

        return qjs.undefined(), nil, false
    }

    if !qjs.set_property(h.ctx, signal, "aborted", qjs.new_bool(false)) {
        qjs.free_value(h.ctx, signal)
        exception := qjs.get_exception(h.ctx)
        qjs.free_value(h.ctx, exception)

        return qjs.undefined(), nil, false
    }

    return signal, scope, true
}

// Latch one run and update its script-visible signal. Idempotent.
cancel_trigger :: proc(h: ^Host, scope: ^Run_Scope, signal: qjs.Value) {
    assert(h != nil && h.ctx != nil, "triggering cancellation needs a live host")
    assert(scope != nil, "triggering cancellation needs a scope")

    sync.atomic_store(&scope.aborted, true)
    if !qjs.set_property(h.ctx, signal, "aborted", qjs.new_bool(true)) {
        exception := qjs.get_exception(h.ctx)
        qjs.free_value(h.ctx, exception)
    }
}

cancelled_scope :: proc(scope: ^Run_Scope) -> bool {
    return scope != nil && sync.atomic_load(&scope.aborted)
}

@(private = "package")
cancel_retain :: proc(scope: ^Run_Scope) {
    if scope != nil {
        assert(scope.refs > 0, "a live cancellation scope has an owner")
        scope.refs += 1
    }
}

@(private = "package")
cancel_release :: proc(scope: ^Run_Scope) {
    if scope == nil do return

    assert(scope.refs > 0, "a cancellation release has an owner")
    scope.refs -= 1
    if scope.refs == 0 do run_scope_free(scope)
}

@(private = "file")
run_scope_free :: proc(scope: ^Run_Scope) {
    assert(scope != nil, "freeing a run scope needs one")

    if scope.default_cwd != "" do delete(scope.default_cwd, scope.allocator)

    free(scope, scope.allocator)
}

// Read an optional signal argument. Once the daemon enables scoped operations, omission is
// rejected so a handler cannot accidentally create work that outlives its run.
@(private = "package")
cancel_arg :: proc(
    ctx: ^qjs.Context,
    argc: c.int,
    argv: [^]qjs.Value,
    index: c.int,
) -> (
    scope: ^Run_Scope,
    thrown: qjs.Value,
    ok: bool,
) {
    h := host_of(ctx)
    assert(h != nil, "a host operation has a host")

    if argc <= index || qjs.is_undefined(argv[index]) || qjs.is_null(argv[index]) {
        if h.cancel_enforced do return nil, qjs.throw_type_error(ctx, "a run cancellation signal is required"), false

        return nil, qjs.undefined(), true
    }

    return cancel_value(ctx, argv[index])
}

@(private = "package")
cancel_value :: proc(ctx: ^qjs.Context, value: qjs.Value) -> (^Run_Scope, qjs.Value, bool) {
    h := host_of(ctx)
    assert(h != nil, "a cancellation signal has a host")

    scope := (^Run_Scope)(qjs.get_opaque(value, h.cancel_class))
    if scope == nil do return nil, qjs.throw_type_error(ctx, "invalid run cancellation signal"), false

    if cancelled_scope(scope) do return nil, qjs.throw_type_error(ctx, "operation canceled"), false

    return scope, qjs.undefined(), true
}

@(private = "package")
cancel_signal_finalize :: proc "c" (rt: ^qjs.Runtime, value: qjs.Value) {
    context = runtime.default_context()

    class_id := qjs.get_class_id(value)
    scope := (^Run_Scope)(qjs.get_opaque(value, class_id))
    cancel_release(scope)
}
