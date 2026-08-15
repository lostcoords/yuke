package js

import "base:runtime"
import "core:c"
import "core:mem"

import qjs "libs:bindings/quickjs"
import "libs:offload"

// Unified diff between two texts. Pure, but offloaded like every other host op so one
// convention covers the whole surface and a large file cannot stall the loop thread.
DIFF_MODULE :: "yuke:diff"

@(rodata)
DIFF_EXPORTS := []string{"diff"}

@(private = "file")
DIFF_JOB_BLOCK_BYTES :: 64 * mem.Kilobyte

diff_module :: proc() -> Module {
    return {name = DIFF_MODULE, init = diff_module_init, exports = DIFF_EXPORTS}
}

@(private = "file")
Diff_Job :: struct {
    task:      offload.Task(Diff_Job),
    host:      ^Host,
    cancel:    ^Run_Scope,
    path:      string,
    before:    string,
    after:     string,
    file:      Diff_File,
    ok:        bool,
    done:      bool,
    resolve:   qjs.Value,
    reject:    qjs.Value,
    arena:     mem.Dynamic_Arena,
    allocator: mem.Allocator,
}

@(private = "file")
diff_module_init :: proc "c" (ctx: ^qjs.Context, m: ^qjs.Module_Def) -> c.int {
    context = runtime.default_context()

    if !qjs.set_module_export(ctx, m, "diff", qjs.new_function(ctx, diff_entry, "diff", 3)) {
        return -1
    }

    return 0
}

// `diff(path, before, after)` — `path` only labels the result; nothing is read from disk.
@(private = "file")
diff_entry :: proc "c" (ctx: ^qjs.Context, this: qjs.Value, argc: c.int, argv: [^]qjs.Value) -> qjs.Value {
    context = runtime.default_context()

    h := host_of(ctx)

    if h == nil || h.pool == nil {
        return qjs.throw_type_error(ctx, "yuke:diff needs a configured worker pool")
    }

    if !h.ops_open {
        return qjs.throw_type_error(ctx, "yuke:diff is closed")
    }

    job, aerr := new(Diff_Job, h.allocator)
    if aerr != nil {
        return qjs.throw_type_error(ctx, "out of memory")
    }

    job^ = {}
    job.host = h
    mem.dynamic_arena_init(
        &job.arena,
        runtime.heap_allocator(),
        runtime.heap_allocator(),
        DIFF_JOB_BLOCK_BYTES,
        DIFF_JOB_BLOCK_BYTES,
    )
    job.allocator = mem.dynamic_arena_allocator(&job.arena)

    fields := [3]^string{&job.path, &job.before, &job.after}

    for out, index in fields {
        value, got := arg_string(ctx, argv, argc, c.int(index), job.allocator, out)
        if !got {
            diff_job_free(job)

            return value
        }
    }

    cancel, thrown, cancel_ok := cancel_arg(ctx, argc, argv, 3)
    if !cancel_ok {
        diff_job_free(job)

        return thrown
    }
    job.cancel = cancel
    cancel_retain(cancel)

    promise, resolve, reject := qjs.new_promise(ctx)
    if qjs.is_exception(promise) {
        diff_job_free(job)

        return promise
    }

    job.resolve = resolve
    job.reject = reject
    op_begin(h)

    offload.submit(h.pool, job, diff_job_run, diff_job_done)

    return promise
}

@(private = "file")
diff_job_run :: proc(job: ^Diff_Job) {
    assert(job.host != nil, "a host op lost its host")
    assert(!job.done, "a host op ran twice")

    if !diff_job_cancelled(job) {
        job.file, job.ok = diff_text(job.path, job.before, job.after, job.allocator)
    }
    job.done = true
}

@(private = "file")
diff_job_done :: proc(job: ^Diff_Job) {
    assert(job.done, "a host op completed without an outcome")

    h := job.host
    assert(h.ctx != nil, "a host op completed after its context was freed")

    defer diff_job_free(job)

    ctx := h.ctx

    defer qjs.free_value(ctx, job.resolve)
    defer qjs.free_value(ctx, job.reject)

    canceled := diff_job_cancelled(job)
    settle := job.resolve if job.ok && !canceled else job.reject
    message := "operation canceled" if canceled else "change is too large to diff"
    value := diff_value(ctx, job.file) if job.ok && !canceled else qjs.new_string(ctx, message)

    defer qjs.free_value(ctx, value)

    args := [1]qjs.Value{value}
    qjs.free_value(ctx, qjs.call(ctx, settle, qjs.undefined(), args[:]))

    op_end(h)
}

@(private = "file")
diff_value :: proc(ctx: ^qjs.Context, file: Diff_File) -> qjs.Value {
    out := qjs.new_object(ctx)
    _ = qjs.set_property(ctx, out, "path", qjs.new_string(ctx, file.path))

    hunks := qjs.new_array(ctx)

    for hunk, index in file.hunks {
        entry := qjs.new_object(ctx)
        _ = qjs.set_property(ctx, entry, "oldStart", qjs.new_f64(f64(hunk.old_start)))
        _ = qjs.set_property(ctx, entry, "oldLines", qjs.new_f64(f64(hunk.old_lines)))
        _ = qjs.set_property(ctx, entry, "newStart", qjs.new_f64(f64(hunk.new_start)))
        _ = qjs.set_property(ctx, entry, "newLines", qjs.new_f64(f64(hunk.new_lines)))

        lines := qjs.new_array(ctx)
        for line, line_index in hunk.lines {
            _ = qjs.set_index(ctx, lines, u32(line_index), qjs.new_string(ctx, line))
        }

        _ = qjs.set_property(ctx, entry, "lines", lines)
        _ = qjs.set_index(ctx, hunks, u32(index), entry)
    }

    _ = qjs.set_property(ctx, out, "hunks", hunks)

    return out
}

@(private = "file")
diff_job_free :: proc(job: ^Diff_Job) {
    assert(job != nil, "host op cleanup needs job state")
    assert(job.host != nil, "host op cleanup lost its host")

    allocator := job.host.allocator
    cancel_release(job.cancel)
    mem.dynamic_arena_destroy(&job.arena)

    free(job, allocator)
}

@(private = "file")
diff_job_cancelled :: proc(job: ^Diff_Job) -> bool {
    assert(job != nil && job.host != nil, "a diff cancellation check needs its job")

    return cancelled(job.host) || cancelled_scope(job.cancel)
}
