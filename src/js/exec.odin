#+build !windows
package js

import "base:runtime"
import "core:c"
import "core:mem"
import "core:os"
import "core:strings"
import "core:time"

import qjs "libs:bindings/quickjs"
import "libs:offload"

// One shell command per call. The command is a line, not an argument vector, so a script
// composes pipelines and redirection itself.
EXEC_MODULE :: "yuke:exec"

@(rodata)
EXEC_EXPORTS := []string{"exec"}

// Per stream. A command that outruns this is truncated and says so, because the alternative
// is a result that no longer fits a request.
EXEC_MAX_OUTPUT_BYTES :: 1 * mem.Megabyte

EXEC_DEFAULT_TIMEOUT :: 120 * time.Second
EXEC_MAX_TIMEOUT :: 600 * time.Second

// How long a command has to act on its own termination signal before it is killed outright.
// Shorter than a service shutdown grace, because a person is waiting for the cancel.
@(private = "file")
EXEC_GRACE :: 2 * time.Second

// Both pipes are polled, so the worker sleeps between empty rounds rather than spinning.
@(private = "file")
EXEC_POLL_INTERVAL :: 2 * time.Millisecond

@(private = "file")
EXEC_JOB_BLOCK_BYTES :: 64 * mem.Kilobyte

exec_module :: proc() -> Module {
    return {name = EXEC_MODULE, init = exec_module_init, exports = EXEC_EXPORTS}
}

// One in-flight command. `exec_posix.odin` fills the outcome fields from the worker.
@(private = "package")
Exec_Job :: struct {
    task:      offload.Task(Exec_Job),
    host:      ^Host,
    cancel:    ^Run_Scope,
    command:   string,
    cwd:       string,
    timeout:   time.Duration,
    started:   bool,
    out:       string,
    err:       string,
    code:      int,
    timed_out: bool,
    truncated: bool,
    done:      bool,
    resolve:   qjs.Value,
    reject:    qjs.Value,
    arena:     mem.Dynamic_Arena,
    allocator: mem.Allocator,
}

@(private = "file")
exec_module_init :: proc "c" (ctx: ^qjs.Context, m: ^qjs.Module_Def) -> c.int {
    context = runtime.default_context()

    if !qjs.set_module_export(ctx, m, "exec", qjs.new_function(ctx, exec_entry, "exec", 2)) do return -1

    return 0
}

// `exec(command, {cwd, timeoutMs})`
@(private = "file")
exec_entry :: proc "c" (ctx: ^qjs.Context, this: qjs.Value, argc: c.int, argv: [^]qjs.Value) -> qjs.Value {
    context = runtime.default_context()

    h := host_of(ctx)

    if h == nil || h.exec_pool == nil do return qjs.throw_type_error(ctx, "yuke:exec needs a configured worker pool")

    if !h.ops_open do return qjs.throw_type_error(ctx, "yuke:exec is closed")

    job := new(Exec_Job, h.allocator)

    job^ = {}
    job.host = h
    job.timeout = EXEC_DEFAULT_TIMEOUT
    mem.dynamic_arena_init(
        &job.arena,
        runtime.heap_allocator(),
        runtime.heap_allocator(),
        EXEC_JOB_BLOCK_BYTES,
        EXEC_JOB_BLOCK_BYTES,
    )
    job.allocator = mem.dynamic_arena_allocator(&job.arena)

    if thrown, got := arg_string(ctx, argv, argc, 0, job.allocator, &job.command); !got {
        exec_job_free(job)

        return thrown
    }

    if thrown, read := exec_options(ctx, job, argc, argv); !read {
        exec_job_free(job)

        return thrown
    }

    promise, resolve, reject := qjs.new_promise(ctx)
    if qjs.is_exception(promise) {
        exec_job_free(job)

        return promise
    }

    job.resolve = resolve
    job.reject = reject
    op_begin(h)

    offload.submit(h.exec_pool, job, exec_job_run, exec_job_done)

    return promise
}

@(private = "file")
exec_options :: proc(ctx: ^qjs.Context, job: ^Exec_Job, argc: c.int, argv: [^]qjs.Value) -> (qjs.Value, bool) {
    if argc < 2 || !qjs.is_object(argv[1]) {
        if job.host.cancel_enforced do return qjs.throw_type_error(ctx, "yuke:exec requires options with a run cancellation signal"), false

        return qjs.undefined(), true
    }

    signal := qjs.get_property(ctx, argv[1], "signal")
    defer qjs.free_value(ctx, signal)

    if qjs.is_exception(signal) do return signal, false

    if qjs.is_undefined(signal) || qjs.is_null(signal) {
        if job.host.cancel_enforced do return qjs.throw_type_error(ctx, "a run cancellation signal is required"), false
    } else {
        cancel, thrown, ok := cancel_value(ctx, signal)
        if !ok do return thrown, false
        job.cancel = cancel
        cancel_retain(cancel)
    }

    cwd := qjs.get_property(ctx, argv[1], "cwd")
    defer qjs.free_value(ctx, cwd)

    if !qjs.is_undefined(cwd) && !qjs.is_null(cwd) {
        requested, got := qjs.to_string(ctx, cwd)
        if !got do return qjs.throw_type_error(ctx, "yuke:exec could not read cwd"), false

        defer qjs.free_string(ctx, requested)

        resolved, resolved_ok := path_resolve(job.host.base, requested, job.allocator)
        if !resolved_ok do return qjs.throw_type_error(ctx, "yuke:exec expects an absolute cwd"), false

        job.cwd = resolved
    } else if job.cancel != nil && job.cancel.default_cwd != "" do job.cwd = strings.clone(job.cancel.default_cwd, job.allocator)

    timeout := qjs.get_property(ctx, argv[1], "timeoutMs")
    defer qjs.free_value(ctx, timeout)

    if !qjs.is_undefined(timeout) && !qjs.is_null(timeout) {
        milliseconds, read := qjs.to_i64(ctx, timeout)

        if !read || milliseconds <= 0 do return qjs.throw_type_error(ctx, "yuke:exec expects a positive timeoutMs"), false

        job.timeout = min(time.Duration(milliseconds) * time.Millisecond, EXEC_MAX_TIMEOUT)
    }

    return qjs.undefined(), true
}

// Worker: touch only `job`, never the context.
@(private = "file")
exec_job_run :: proc(job: ^Exec_Job) {
    assert(job.host != nil, "a host op lost its host")
    assert(!job.done, "a host op ran twice")
    assert(job.timeout > 0, "a command carries a deadline")

    defer job.done = true

    if exec_job_cancelled(job) do return

    stdout_r, stdout_w, out_err := os.pipe()
    if out_err != nil do return

    defer os.close(stdout_r)

    stderr_r, stderr_w, err_err := os.pipe()
    if err_err != nil {
        os.close(stdout_w)

        return
    }

    defer os.close(stderr_r)

    process, spawned := exec_spawn(job, stdout_w, stderr_w)

    // Closed on both paths: while this end holds the write side open, the read side never
    // reaches end of file, and the drain below would outlive the process it reads.
    os.close(stdout_w)
    os.close(stderr_w)

    if !spawned do return

    job.started = true

    // The deadline bounds the drain, not just the wait: a command that prints without
    // stopping never reaches end of file, and only this makes it stop.
    deadline := time.time_add(time.now(), job.timeout)
    stop := exec_drain(job, stdout_r, stderr_r, deadline)

    if stop != .Finished {
        job.timed_out = stop == .Deadline
        exec_terminate(job, process)
    }

    if code, exited := exec_reap(process, true); exited do job.code = code
}

// Signal the whole group, give it time to act, then kill it. The group is what makes this
// work: the shell forks the command, so a signal to the shell alone leaves the command
// running and reports a stop that did not happen.
@(private = "file")
exec_terminate :: proc(job: ^Exec_Job, process: Exec_Process) {
    exec_signal_group(process, .SIGTERM)

    grace := time.time_add(time.now(), EXEC_GRACE)

    for time.since(grace) < 0 {
        if code, exited := exec_reap(process, false); exited {
            job.code = code

            return
        }

        time.sleep(EXEC_POLL_INTERVAL)
    }

    exec_signal_group(process, .SIGKILL)
}

@(private = "file")
Exec_Stop :: enum {
    Finished,
    Deadline,
    Cancelled,
}

// Read both streams until they end, the deadline passes, or the host is cancelled. Whatever
// arrived first still answers the caller: a killed command is an outcome, not a loss.
@(private = "file")
exec_drain :: proc(job: ^Exec_Job, stdout_r: ^os.File, stderr_r: ^os.File, deadline: time.Time) -> Exec_Stop {
    out_buf: strings.Builder
    err_buf: strings.Builder
    strings.builder_init(&out_buf, 0, 0, job.allocator)
    strings.builder_init(&err_buf, 0, 0, job.allocator)

    defer {
        job.out = strings.to_string(out_buf)
        job.err = strings.to_string(err_buf)
    }

    chunk: [4096]byte
    out_done := false
    err_done := false

    for !out_done || !err_done {
        moved := false

        if !out_done {
            read, done := exec_read_chunk(job, stdout_r, &out_buf, chunk[:])
            out_done = done
            moved = moved || read
        }

        if !err_done {
            read, done := exec_read_chunk(job, stderr_r, &err_buf, chunk[:])
            err_done = done
            moved = moved || read
        }

        if time.since(deadline) >= 0 do return .Deadline

        // Draining the pool joins this worker, so a shutdown must not wait out a command
        // that still has ten minutes of its deadline left.
        if exec_job_cancelled(job) do return .Cancelled

        // Both pipes quiet and neither finished: the child is working, so yield rather than
        // spin a worker at full tilt on an empty pipe.
        if !moved do time.sleep(EXEC_POLL_INTERVAL)
    }

    return .Finished
}

// `done` reports the stream ended or failed. A failed read counts as an end, because the
// exit code is the authority on whether the command worked.
@(private = "file")
exec_read_chunk :: proc(
    job: ^Exec_Job,
    file: ^os.File,
    buf: ^strings.Builder,
    chunk: []byte,
) -> (
    read: bool,
    done: bool,
) {
    has_data, poll_err := os.pipe_has_data(file)
    if poll_err != nil do return false, true

    if !has_data do return false, false

    count, read_err := os.read(file, chunk)
    if read_err != nil || count == 0 do return false, true

    // Read first and drop after: a stream the caller stopped keeping must still be consumed,
    // or the child blocks on a full pipe for the rest of its deadline.
    room := EXEC_MAX_OUTPUT_BYTES - strings.builder_len(buf^)
    if room <= 0 {
        job.truncated = true

        return true, false
    }

    kept := min(count, room)
    strings.write_bytes(buf, chunk[:kept])
    job.truncated = job.truncated || kept < count

    return true, false
}

@(private = "file")
exec_job_done :: proc(job: ^Exec_Job) {
    assert(job.done, "a host op completed without an outcome")

    h := job.host
    assert(h.ctx != nil, "a host op completed after its context was freed")

    defer exec_job_free(job)

    ctx := h.ctx

    defer qjs.free_value(ctx, job.resolve)
    defer qjs.free_value(ctx, job.reject)

    canceled := exec_job_cancelled(job)
    settle := job.resolve if job.started && !canceled else job.reject
    message := "operation canceled" if canceled else "command could not be started"
    value := exec_value(ctx, job) if job.started && !canceled else qjs.new_string(ctx, message)

    defer qjs.free_value(ctx, value)

    args := [1]qjs.Value{value}
    qjs.free_value(ctx, qjs.call(ctx, settle, qjs.undefined(), args[:]))

    op_end(h)
}

@(private = "file")
exec_value :: proc(ctx: ^qjs.Context, job: ^Exec_Job) -> qjs.Value {
    out := qjs.new_object(ctx)
    _ = qjs.set_property(ctx, out, "stdout", qjs.new_string(ctx, job.out))
    _ = qjs.set_property(ctx, out, "stderr", qjs.new_string(ctx, job.err))
    _ = qjs.set_property(ctx, out, "code", qjs.new_f64(f64(job.code)))
    _ = qjs.set_property(ctx, out, "timedOut", qjs.new_bool(job.timed_out))
    _ = qjs.set_property(ctx, out, "truncated", qjs.new_bool(job.truncated))

    return out
}

@(private = "file")
exec_job_free :: proc(job: ^Exec_Job) {
    assert(job != nil, "host op cleanup needs job state")
    assert(job.host != nil, "host op cleanup lost its host")

    allocator := job.host.allocator
    cancel_release(job.cancel)
    mem.dynamic_arena_destroy(&job.arena)

    free(job, allocator)
}

@(private = "file")
exec_job_cancelled :: proc(job: ^Exec_Job) -> bool {
    assert(job != nil && job.host != nil, "an exec cancellation check needs its job")

    return cancelled(job.host) || cancelled_scope(job.cancel)
}
