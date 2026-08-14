package js

import "base:runtime"
import "core:c"
import "core:mem"
import "core:sync"

import qjs "libs:bindings/quickjs"

// One run-scoped cancellation latch. The JS signal object and every submitted job each
// own one reference; workers only read `aborted`.
Cancel_Scope :: struct {
    allocator: mem.Allocator,
    refs:      int,
    aborted:   bool,
}

// Once tool execution begins, every later host operation in this daemon runtime carries a
// run signal. The latch outlives abandoned promises, so a canceled continuation cannot
// omit its signal to escape cancellation. Startup entry modules run before it is enabled.
cancel_enforce :: proc(h: ^Host) {
    assert(h != nil && h.ctx != nil, "enforcing cancellation needs a live host")

    h.cancel_enforced = true
}

// Create the signal passed to one tool handler. Caller owns the returned JS value.
cancel_signal_new :: proc(h: ^Host) -> (qjs.Value, ^Cancel_Scope, bool) {
    assert(h != nil && h.ctx != nil, "creating a cancellation signal needs a live host")
    assert(h.cancel_class != qjs.INVALID_CLASS_ID, "a live host registered its cancellation class")

    scope, alloc_err := new(Cancel_Scope, h.allocator)
    if alloc_err != nil {
        return qjs.undefined(), nil, false
    }
    scope^ = {
        allocator = h.allocator,
        refs      = 1,
    }

    signal := qjs.new_object_class(h.ctx, h.cancel_class)
    if qjs.is_exception(signal) {
        exception := qjs.get_exception(h.ctx)
        qjs.free_value(h.ctx, exception)
        free(scope, h.allocator)

        return qjs.undefined(), nil, false
    }
    if !qjs.set_opaque(signal, scope) {
        qjs.free_value(h.ctx, signal)
        free(scope, h.allocator)

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
cancel_trigger :: proc(h: ^Host, scope: ^Cancel_Scope, signal: qjs.Value) {
    assert(h != nil && h.ctx != nil, "triggering cancellation needs a live host")
    assert(scope != nil, "triggering cancellation needs a scope")

    sync.atomic_store(&scope.aborted, true)
    if !qjs.set_property(h.ctx, signal, "aborted", qjs.new_bool(true)) {
        exception := qjs.get_exception(h.ctx)
        qjs.free_value(h.ctx, exception)
    }
}

cancelled_scope :: proc(scope: ^Cancel_Scope) -> bool {
    return scope != nil && sync.atomic_load(&scope.aborted)
}

@(private = "package")
cancel_retain :: proc(scope: ^Cancel_Scope) {
    if scope != nil {
        assert(scope.refs > 0, "a live cancellation scope has an owner")
        scope.refs += 1
    }
}

@(private = "package")
cancel_release :: proc(scope: ^Cancel_Scope) {
    if scope == nil {
        return
    }

    assert(scope.refs > 0, "a cancellation release has an owner")
    scope.refs -= 1
    if scope.refs == 0 {
        free(scope, scope.allocator)
    }
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
    scope: ^Cancel_Scope,
    thrown: qjs.Value,
    ok: bool,
) {
    h := host_of(ctx)
    assert(h != nil, "a host operation has a host")

    if argc <= index || qjs.is_undefined(argv[index]) || qjs.is_null(argv[index]) {
        if h.cancel_enforced {
            return nil, qjs.throw_type_error(ctx, "a run cancellation signal is required"), false
        }

        return nil, qjs.undefined(), true
    }

    return cancel_value(ctx, argv[index])
}

@(private = "package")
cancel_value :: proc(ctx: ^qjs.Context, value: qjs.Value) -> (^Cancel_Scope, qjs.Value, bool) {
    h := host_of(ctx)
    assert(h != nil, "a cancellation signal has a host")

    scope := (^Cancel_Scope)(qjs.get_opaque(value, h.cancel_class))
    if scope == nil {
        return nil, qjs.throw_type_error(ctx, "invalid run cancellation signal"), false
    }

    if cancelled_scope(scope) {
        return nil, qjs.throw_type_error(ctx, "operation canceled"), false
    }

    return scope, qjs.undefined(), true
}

@(private = "package")
cancel_signal_finalize :: proc "c" (rt: ^qjs.Runtime, value: qjs.Value) {
    context = runtime.default_context()

    class_id := qjs.get_class_id(value)
    scope := (^Cancel_Scope)(qjs.get_opaque(value, class_id))
    cancel_release(scope)
}
