#+build !windows
package js

import "base:runtime"
import "core:c"
import "core:mem"
import "core:nbio"
import "core:net"
import "core:strings"
import "core:sys/posix"
import "core:time"

import qjs "libs:bindings/quickjs"

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

@(private = "file")
EXEC_JOB_BLOCK_BYTES :: 64 * mem.Kilobyte

@(private = "file")
EXEC_READ_BYTES :: 4 * mem.Kilobyte

// Loop-side exec state on the host: the process-global reaper (SIGCHLD is a singleton) and the
// intrusive list of live commands, walked to kill on cancel or shutdown.
Exec_Host_State :: struct {
    reaper:    Child_Reaper,
    installed: bool,
    jobs:      ^Exec_Job,
}

// One output stream of a running command, polled for readiness on the loop.
@(private = "file")
Exec_Stream :: struct {
    job:     ^Exec_Job,
    read_fd: posix.FD,
    sock:    net.TCP_Socket,
    op:      ^nbio.Operation,
    builder: strings.Builder,
    eof:     bool,
}

// One in-flight command, owned entirely on the loop thread. Settles once the reaper reports its
// exit and both output streams have closed.
@(private = "package")
Exec_Job :: struct {
    host:          ^Host,
    cancel:        ^Run_Scope,
    prev, next:    ^Exec_Job,
    linked:        bool,
    command:       string,
    cwd:           string,
    timeout:       time.Duration,
    process:       Exec_Process,
    out:           Exec_Stream,
    err:           Exec_Stream,
    deadline_op:   ^nbio.Operation,
    grace_op:      ^nbio.Operation,
    spawn_started: bool,
    reaped:        bool,
    killing:       bool,
    settled:       bool,
    code:          int,
    timed_out:     bool,
    truncated:     bool,
    resolve:       qjs.Value,
    reject:        qjs.Value,
    arena:         mem.Dynamic_Arena,
    allocator:     mem.Allocator,
}

exec_module :: proc() -> Module {
    return {name = EXEC_MODULE, init = exec_module_init, exports = EXEC_EXPORTS}
}

@(private = "file")
exec_module_init :: proc "c" (ctx: ^qjs.Context, m: ^qjs.Module_Def) -> c.int {
    context = runtime.default_context()

    if !qjs.set_module_export(ctx, m, "exec", qjs.new_function(ctx, exec_entry, "exec", 2)) do return -1

    return 0
}

// `exec(command, {cwd, timeoutMs, signal})`
@(private = "file")
exec_entry :: proc "c" (ctx: ^qjs.Context, this: qjs.Value, argc: c.int, argv: [^]qjs.Value) -> qjs.Value {
    context = runtime.default_context()

    h := host_of(ctx)

    if h == nil || h.loop == nil do return qjs.throw_type_error(ctx, "yuke:exec needs an event loop")

    if !h.ops_open do return qjs.throw_type_error(ctx, "yuke:exec is closed")

    if !exec_reaper_ensure(h) do return qjs.throw_type_error(ctx, "yuke:exec could not install its child reaper")

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
    exec_job_link(h, job)

    // Spawn failed to even start: settle rejects with "command could not be started", the
    // same outcome the worker model reported.
    if !exec_start(job) do exec_settle(job)

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

// Open both pipes, spawn the shell group, and arm the loop: watch the child for exit, poll
// both read ends, and start the deadline. Returns false only when nothing was spawned.
@(private = "file")
exec_start :: proc(job: ^Exec_Job) -> bool {
    assert(job != nil, "an exec start needs a job")

    out_fds: [2]posix.FD
    if posix.pipe(&out_fds) != .OK do return false

    err_fds: [2]posix.FD
    if posix.pipe(&err_fds) != .OK {
        posix.close(out_fds[0])
        posix.close(out_fds[1])

        return false
    }

    process, spawned := exec_spawn(job, out_fds[1], err_fds[1])

    // Close the parent's write ends on both paths: while this end holds them open the read
    // side never reaches EOF.
    posix.close(out_fds[1])
    posix.close(err_fds[1])

    if !spawned {
        posix.close(out_fds[0])
        posix.close(err_fds[0])

        return false
    }

    job.process = process
    job.spawn_started = true

    exec_stream_bind(job, &job.out, out_fds[0])
    exec_stream_bind(job, &job.err, err_fds[0])

    reaper_watch(&job.host.exec.reaper, job.process.pid, exec_on_child_exit, job)

    exec_arm_stream(&job.out)
    exec_arm_stream(&job.err)
    job.deadline_op = nbio.timeout_poly(job.timeout, job, exec_on_deadline, l = job.host.loop)

    return true
}

@(private = "file")
exec_arm_stream :: proc(s: ^Exec_Stream) {
    assert(s.op == nil, "a stream arms with no poll in flight")
    assert(!s.eof, "a closed stream does not re-arm")

    s.op = nbio.poll_poly(s.sock, .Receive, s, exec_on_stream_ready, l = s.job.host.loop)
}

// One readiness wake: read a single bounded batch, then re-arm. Level readiness re-delivers
// the rest of a burst on later ticks, so one worker-free loop turn never starves the others.
@(private = "file")
exec_on_stream_ready :: proc(op: ^nbio.Operation, s: ^Exec_Stream) {
    assert(s.op == op, "a stream poll completed for another operation")

    s.op = nil
    job := s.job

    if op.poll.result != .Ready {
        exec_stream_close(s)

        return
    }

    chunk: [EXEC_READ_BYTES]byte
    n := posix.read(s.read_fd, raw_data(chunk[:]), len(chunk))

    if n > 0 {
        exec_stream_append(job, s, chunk[:n])
        exec_arm_stream(s)

        return
    }

    if n == 0 {
        exec_stream_close(s)

        return
    }

    #partial switch posix.errno() {
    case .EINTR, .EAGAIN:
        exec_arm_stream(s)

    case:
        exec_stream_close(s)
    }
}

// Keep up to the cap, drop the rest but keep reading: a stream the caller stopped keeping must
// still be consumed, or the child blocks on a full pipe for the rest of its deadline.
@(private = "file")
exec_stream_append :: proc(job: ^Exec_Job, s: ^Exec_Stream, data: []byte) {
    room := EXEC_MAX_OUTPUT_BYTES - strings.builder_len(s.builder)
    if room <= 0 {
        job.truncated = true

        return
    }

    keep := min(len(data), room)
    strings.write_bytes(&s.builder, data[:keep])
    job.truncated = job.truncated || keep < len(data)
}

@(private = "file")
exec_stream_close :: proc(s: ^Exec_Stream) {
    s.eof = true
    exec_check_settle(s.job)
}

// The reaper observed the child's exit. Cancel the escalation timers and try to settle: the
// pipes may already be drained, or their EOF may still be in flight.
@(private = "file")
exec_on_child_exit :: proc(user: rawptr, code: int) {
    job := cast(^Exec_Job)user

    job.reaped = true
    job.code = code

    if job.deadline_op != nil {
        nbio.remove(job.deadline_op)
        job.deadline_op = nil
    }

    if job.grace_op != nil {
        nbio.remove(job.grace_op)
        job.grace_op = nil
    }

    exec_check_settle(job)
}

@(private = "file")
exec_on_deadline :: proc(op: ^nbio.Operation, job: ^Exec_Job) {
    job.deadline_op = nil

    if job.reaped || job.settled do return

    job.timed_out = true
    exec_kill_begin(job)
}

// Signal the whole group, then kill it after the grace window. The group is what makes this
// work: the shell forks the command, so a signal to the shell alone leaves the command running.
@(private = "file")
exec_kill_begin :: proc(job: ^Exec_Job) {
    if job.killing || job.reaped do return

    job.killing = true
    exec_signal_group(job.process, .SIGTERM)
    job.grace_op = nbio.timeout_poly(EXEC_GRACE, job, exec_on_grace, l = job.host.loop)
}

@(private = "file")
exec_on_grace :: proc(op: ^nbio.Operation, job: ^Exec_Job) {
    job.grace_op = nil

    if job.reaped do return

    exec_signal_group(job.process, .SIGKILL)
}

// Settle exactly once, when the child has been reaped and both streams have closed. A killed
// command is an outcome, not a loss: whatever output arrived still answers the caller.
@(private = "file")
exec_check_settle :: proc(job: ^Exec_Job) {
    if job.settled do return

    if !(job.reaped && job.out.eof && job.err.eof) do return

    exec_settle(job)
}

// Resolve or reject the promise and free the job. A cancel (host shutdown or run signal)
// rejects; a normal or timed-out finish resolves; a command that never spawned rejects.
@(private = "file")
exec_settle :: proc(job: ^Exec_Job) {
    assert(!job.settled, "a command settles once")
    assert(job.out.op == nil && job.err.op == nil, "a settling command has no stream poll in flight")

    job.settled = true

    h := job.host
    ctx := h.ctx

    canceled := exec_job_cancelled(job)
    settle := job.resolve if job.spawn_started && !canceled else job.reject
    message := "operation canceled" if canceled else "command could not be started"
    value := exec_value(ctx, job) if job.spawn_started && !canceled else qjs.new_string(ctx, message)

    args := [1]qjs.Value{value}
    qjs.free_value(ctx, qjs.call(ctx, settle, qjs.undefined(), args[:]))
    qjs.free_value(ctx, value)

    exec_job_free(job)
    op_end(h)
}

@(private = "file")
exec_value :: proc(ctx: ^qjs.Context, job: ^Exec_Job) -> qjs.Value {
    out := qjs.new_object(ctx)
    _ = qjs.set_property(ctx, out, "stdout", qjs.new_string(ctx, strings.to_string(job.out.builder)))
    _ = qjs.set_property(ctx, out, "stderr", qjs.new_string(ctx, strings.to_string(job.err.builder)))
    _ = qjs.set_property(ctx, out, "code", qjs.new_f64(f64(job.code)))
    _ = qjs.set_property(ctx, out, "timedOut", qjs.new_bool(job.timed_out))
    _ = qjs.set_property(ctx, out, "truncated", qjs.new_bool(job.truncated))

    return out
}

// Kill every live command; the reaper settles each as it exits. For host shutdown.
@(private = "package")
exec_cancel_all :: proc(h: ^Host) {
    for job := h.exec.jobs; job != nil; job = job.next {
        exec_kill_begin(job)
    }
}

// Kill the commands that belong to one canceled run. The scope is already latched, so each
// settles as a rejection when the reaper reports its exit.
@(private = "package")
exec_cancel_scope :: proc(h: ^Host, scope: ^Run_Scope) {
    for job := h.exec.jobs; job != nil; job = job.next {
        if job.cancel == scope do exec_kill_begin(job)
    }
}

// Tear the reaper down with the host, after every command has settled.
@(private = "package")
exec_teardown :: proc(h: ^Host) {
    if !h.exec.installed do return

    reaper_destroy(&h.exec.reaper)
    h.exec.installed = false
}

@(private = "file")
exec_reaper_ensure :: proc(h: ^Host) -> bool {
    if h.exec.installed do return true

    if reaper_init(&h.exec.reaper, h.loop, h.allocator) != .None do return false

    h.exec.installed = true

    return true
}

@(private = "file")
exec_job_link :: proc(h: ^Host, job: ^Exec_Job) {
    assert(!job.linked, "a command links once")

    job.next = h.exec.jobs
    job.prev = nil
    if h.exec.jobs != nil do h.exec.jobs.prev = job
    h.exec.jobs = job
    job.linked = true
}

@(private = "file")
exec_job_unlink :: proc(h: ^Host, job: ^Exec_Job) {
    if !job.linked do return

    if job.prev != nil do job.prev.next = job.next
    else do h.exec.jobs = job.next

    if job.next != nil do job.next.prev = job.prev

    job.prev = nil
    job.next = nil
    job.linked = false
}

@(private = "file")
exec_job_free :: proc(job: ^Exec_Job) {
    assert(job != nil, "job cleanup needs job state")

    h := job.host
    assert(h != nil, "job cleanup lost its host")

    exec_job_unlink(h, job)
    cancel_release(job.cancel)

    if h.ctx != nil {
        qjs.free_value(h.ctx, job.resolve)
        qjs.free_value(h.ctx, job.reject)
    }

    mem.dynamic_arena_destroy(&job.arena)
    free(job, h.allocator)
}

@(private = "file")
exec_job_cancelled :: proc(job: ^Exec_Job) -> bool {
    assert(job != nil && job.host != nil, "an exec cancellation check needs its job")

    return cancelled(job.host) || cancelled_scope(job.cancel)
}

// Prepare a pipe read end (non-blocking + close-on-exec, so a later command's child never
// inherits it) and bind it to the loop with a builder for its output.
@(private = "file")
exec_stream_bind :: proc(job: ^Exec_Job, s: ^Exec_Stream, fd: posix.FD) {
    _ = pipe_prepare(fd)

    s.job = job
    s.read_fd = fd
    s.sock = net.TCP_Socket(fd)
    strings.builder_init(&s.builder, 0, 0, job.allocator)

    assert(nbio.associate_socket(s.sock, job.host.loop) == .None, "an owned pipe fd associates")
}
