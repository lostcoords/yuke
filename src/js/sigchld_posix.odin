#+build linux, darwin
package js

import "base:intrinsics"
import "core:c"
import "core:nbio"
import "core:net"
import "core:sys/posix"

// Process-global child reaper: a SIGCHLD self-pipe wakes the loop, whose poll then reaps every
// watched child with waitpid(WNOHANG). Modeled on the SIGWINCH notifier in src/term/resize_posix.

// Pipe write end the handler targets; -1 means unarmed. Global because the handler
// cannot be handed instance state.
@(private = "file")
g_sigchld_write_fd: posix.FD = -1

// Handler invocations in flight, so teardown can wait for a handler that already
// loaded the fd to finish its write before the fd is closed.
@(private = "file")
g_sigchld_active: int

// SIGCHLD as a `Signal` — the enum lacks the member, same gap the term code works
// around for SIGWINCH.
@(private = "file")
SIGCHLD :: posix.Signal(posix.SIGCHLD)

Reaper_Error :: enum {
    None,
    Pipe_Failed,
    Associate_Failed,
    Sigaction_Failed,
    Already_Installed,
}

// Called on the loop thread when a watched child terminates. `code` is the shell
// exit convention: a normal exit's status, or 128+signal for a signalled death.
Child_Exit :: #type proc(user: rawptr, code: int)

@(private = "file")
Child_Watch :: struct {
    on_exit: Child_Exit,
    user:    rawptr,
}

// A watched child is owned until reaped: there is deliberately no un-watch, since dropping a pid
// without reaping leaks a zombie. To abandon a result, kill the child and let the callback fire.
Child_Reaper :: struct {
    loop:     ^nbio.Event_Loop,
    read_fd:  posix.FD,
    write_fd: posix.FD,
    old:      posix.sigaction_t,
    sock:     net.TCP_Socket,
    op:       ^nbio.Operation,
    children: map[posix.pid_t]Child_Watch,
}

// Async-signal-safe SIGCHLD handler: only an atomic load and one non-blocking
// write of a content-free wake token.
@(private = "file")
sigchld_handler :: proc "c" (sig: posix.Signal) {
    intrinsics.atomic_add(&g_sigchld_active, 1)
    defer intrinsics.atomic_sub(&g_sigchld_active, 1)

    fd := intrinsics.atomic_load(&g_sigchld_write_fd)
    if fd < 0 do return

    b: [1]u8
    posix.write(fd, raw_data(b[:]), 1)
}

// Install the process-global reaper on `loop`. Only one may be live per process.
reaper_init :: proc(r: ^Child_Reaper, loop: ^nbio.Event_Loop, allocator := context.allocator) -> Reaper_Error {
    assert(r != nil, "reaper_init needs a reaper")
    assert(loop != nil, "reaper_init needs a loop")
    assert(r.loop == nil, "reaper_init on a live reaper")

    fds: [2]posix.FD
    if posix.pipe(&fds) != .OK do return .Pipe_Failed

    if pipe_prepare(fds[0]) != .None || pipe_prepare(fds[1]) != .None {
        posix.close(fds[0])
        posix.close(fds[1])

        return .Pipe_Failed
    }

    if _, ok := intrinsics.atomic_compare_exchange_strong(&g_sigchld_write_fd, posix.FD(-1), fds[1]); !ok {
        posix.close(fds[0])
        posix.close(fds[1])

        return .Already_Installed
    }

    // Associate before installing the handler: nothing can fire the handler until
    // sigaction runs, so a failure here never races a handler mid-write to fds[1].
    sock := net.TCP_Socket(fds[0])
    if nbio.associate_socket(sock, loop) != .None {
        intrinsics.atomic_store(&g_sigchld_write_fd, posix.FD(-1))
        posix.close(fds[0])
        posix.close(fds[1])

        return .Associate_Failed
    }

    mask: posix.sigset_t
    posix.sigemptyset(&mask)

    // NOCLDSTOP so a stopped/continued child never wakes us; only real exits do.
    action := posix.sigaction_t {
        sa_handler = sigchld_handler,
        sa_mask    = mask,
        sa_flags   = {.RESTART, .NOCLDSTOP},
    }

    old: posix.sigaction_t
    if posix.sigaction(SIGCHLD, &action, &old) != .OK {
        intrinsics.atomic_store(&g_sigchld_write_fd, posix.FD(-1))
        posix.close(fds[0])
        posix.close(fds[1])

        return .Sigaction_Failed
    }

    r.loop = loop
    r.read_fd = fds[0]
    r.write_fd = fds[1]
    r.old = old
    r.sock = sock
    r.children = make(map[posix.pid_t]Child_Watch, allocator)

    return .None
}

// Register a live child. The reaper owns `pid` until it exits, then calls `on_exit`
// on the loop thread. Arms the self-pipe poll on the first watched child.
reaper_watch :: proc(r: ^Child_Reaper, pid: posix.pid_t, on_exit: Child_Exit, user: rawptr) {
    assert(r != nil && r.loop != nil, "reaper_watch needs a live reaper")
    assert(pid > 0, "reaper_watch needs a real pid")
    assert(on_exit != nil, "reaper_watch needs an exit callback")
    assert(pid not_in r.children, "a live pid is watched once")

    r.children[pid] = {
        on_exit = on_exit,
        user    = user,
    }

    if r.op == nil do reaper_arm(r)
}

@(private = "file")
reaper_arm :: proc(r: ^Child_Reaper) {
    assert(r.op == nil, "reaper_arm with a poll in flight")
    assert(r.loop != nil, "reaper_arm needs a live reaper")
    assert(len(r.children) > 0, "reaper_arm with nothing to reap")

    r.op = nbio.poll_poly(r.sock, .Receive, r, reaper_on_ready, l = r.loop)
}

// Self-pipe readable: drain the wake tokens, reap every exited child, and re-arm while children
// remain. A disarmed reaper watches none, so it can miss no exit.
@(private = "file")
reaper_on_ready :: proc(op: ^nbio.Operation, r: ^Child_Reaper) {
    assert(r != nil, "reaper_on_ready needs a reaper")
    assert(r.op == op, "reaper_on_ready completed for another operation")

    r.op = nil

    if op.poll.result != .Ready {
        if len(r.children) > 0 do reaper_arm(r)

        return
    }

    drain_pipe(r.read_fd)
    reaper_reap(r)

    // An exit callback may have re-armed via a follow-up `reaper_watch`; only arm
    // when nothing is in flight, so exactly one poll stays live.
    if r.op == nil && len(r.children) > 0 do reaper_arm(r)
}

// Reap each exited child once, firing its callback. Restarts the scan after every reap because
// that mutates the map; SIGCHLD coalesces, so one wake can carry several exits.
@(private = "file")
reaper_reap :: proc(r: ^Child_Reaper) {
    for {
        reaped := false

        for pid, watch in r.children {
            status: c.int
            got := posix.waitpid(pid, &status, {.NOHANG})

            if got == 0 do continue

            // got == pid: exited. got < 0: unwaitable (ECHILD) — it is gone either
            // way, so drop it and report an unknown status rather than spin forever.
            code := child_status_decode(status) if got == pid else -1
            w := watch

            delete_key(&r.children, pid)
            w.on_exit(w.user, code)
            reaped = true

            break
        }

        if !reaped do break
    }
}

// Tear down: withdraw the fd, restore the SIGCHLD disposition, wait out any in-flight handler,
// then close — the order keeps a handler off a closed fd. Loop-thread only; call after watches drain.
reaper_destroy :: proc(r: ^Child_Reaper) {
    assert(r != nil, "reaper_destroy needs a reaper")
    if r.loop == nil do return

    assert(r.loop == nbio.current_thread_event_loop(), "reaper_destroy off the loop thread")

    if r.op != nil {
        nbio.remove(r.op)
        r.op = nil
    }

    intrinsics.atomic_store(&g_sigchld_write_fd, posix.FD(-1))
    posix.sigaction(SIGCHLD, &r.old, nil)

    for intrinsics.atomic_load(&g_sigchld_active) != 0 {
        intrinsics.cpu_relax()
    }

    posix.close(r.read_fd)
    posix.close(r.write_fd)
    delete(r.children)

    r^ = {}
}

// Exit status → the shell code convention exec already reports: a normal exit's
// status, 128+signal for a signalled death, else 0.
@(private = "file")
child_status_decode :: proc(status: c.int) -> int {
    if posix.WIFEXITED(status) do return int(posix.WEXITSTATUS(status))

    if posix.WIFSIGNALED(status) do return 128 + int(posix.WTERMSIG(status))

    return 0
}

// Set O_NONBLOCK and FD_CLOEXEC on one pipe end.
@(private = "package")
pipe_prepare :: proc(fd: posix.FD) -> Reaper_Error {
    if posix.fcntl(fd, .SETFL, posix.O_Flags{.NONBLOCK}) < 0 do return .Pipe_Failed

    if posix.fcntl(fd, .SETFD, i32(posix.FD_CLOEXEC)) < 0 do return .Pipe_Failed

    return .None
}

// Empty the self-pipe so the read end stops reporting readable; a burst of exits
// collapses into one wake.
@(private = "file")
drain_pipe :: proc(fd: posix.FD) {
    buf: [64]u8
    for {
        n := posix.read(fd, raw_data(buf[:]), len(buf))
        if n <= 0 do return
    }
}
