#+build linux, darwin
package term

import "base:intrinsics"
import "core:sys/posix"

// `posix.Signal` has no SIGWINCH member (a gap in the binding); `posix.SIGWINCH`
// is the raw per-platform constant, converted once here.
SIGWINCH :: posix.Signal(posix.SIGWINCH)

// Pipe write end the handler targets; -1 means unarmed. A handler installed without
// SA_SIGINFO gets no user-data pointer, so a global is the only way to reach it.
g_write_fd: posix.FD = -1

// Handler invocations in flight. `resize_notifier_destroy` spins on this so a handler
// that already loaded `g_write_fd` finishes its write before the fd is closed.
g_active_handlers: int = 0

// Failure modes of the resize notifier. `None` is success.
Resize_Error :: enum {
    None,
    Pipe_Failed,
    Sigaction_Failed,
    Already_Initialized,
    Already_Waiting,
    Size_Query_Failed,
}

// SIGWINCH self-pipe notifier. `tty` is borrowed for `get_size` re-queries; it
// must outlive the notifier.
Resize_Notifier :: struct {
    // Self-pipe read end (non-blocking). Polled by `resize_notifier_wait`, or by a
    // reactor via nbio (termdrive): on readable call `resize_notifier_consume`.
    read_fd:    posix.FD,

    // @private
    // Self-pipe write end; published to `g_write_fd` for the handler.
    write_fd:   posix.FD,

    // @private
    // Previous SIGWINCH disposition, restored by `resize_notifier_destroy`.
    old_action: posix.sigaction_t,

    // @private
    // Borrowed tty handle, re-queried via `get_size` on wake. Must outlive the notifier.
    tty:        Tty_Handle,

    // @private
    // Guards against concurrent `resize_notifier_wait` calls.
    waiting:    bool,
}

// Async-signal-safe SIGWINCH handler: strictly no Odin context, no allocation,
// no printing — only atomic ops and one non-blocking write.
sigwinch_handler :: proc "c" (sig: posix.Signal) {
    intrinsics.atomic_add(&g_active_handlers, 1)
    defer intrinsics.atomic_sub(&g_active_handlers, 1)

    fd := intrinsics.atomic_load(&g_write_fd)
    if fd < 0 do return

    b: [1]u8
    // Content-free wake token; a full pipe already has a wake pending, and a handler
    // cannot report anything anyway.
    posix.write(fd, raw_data(b[:]), 1)
}

// Install the SIGWINCH self-pipe notifier for `tty`. Only one notifier may be
// live per process at a time (one tty to resize).
resize_notifier_init :: proc(tty: Tty_Handle) -> (Resize_Notifier, Resize_Error) {
    fds: [2]posix.FD
    if posix.pipe(&fds) != .OK do return {}, .Pipe_Failed

    // Both ends non-blocking (the handler must never block; `wait` polls the
    // read end) and close-on-exec (the pipe must not leak into a child).
    if pipe_prepare(fds[0]) != .None || pipe_prepare(fds[1]) != .None {
        posix.close(fds[0])
        posix.close(fds[1])
        return {}, .Pipe_Failed
    }

    if _, ok := intrinsics.atomic_compare_exchange_strong(&g_write_fd, posix.FD(-1), fds[1]); !ok {
        posix.close(fds[0])
        posix.close(fds[1])
        return {}, .Already_Initialized
    }

    mask: posix.sigset_t
    posix.sigemptyset(&mask)

    action := posix.sigaction_t {
        sa_handler = sigwinch_handler,
        sa_mask    = mask,
        sa_flags   = {.RESTART},
    }

    old: posix.sigaction_t
    if posix.sigaction(SIGWINCH, &action, &old) != .OK {
        intrinsics.atomic_store(&g_write_fd, posix.FD(-1))
        posix.close(fds[0])
        posix.close(fds[1])
        return {}, .Sigaction_Failed
    }

    return {read_fd = fds[0], write_fd = fds[1], old_action = old, tty = tty}, .None
}

// Set O_NONBLOCK and FD_CLOEXEC on one pipe end.
pipe_prepare :: proc(fd: posix.FD) -> Resize_Error {
    if posix.fcntl(fd, .SETFL, posix.O_Flags{.NONBLOCK}) < 0 do return .Pipe_Failed

    if posix.fcntl(fd, .SETFD, i32(posix.FD_CLOEXEC)) < 0 do return .Pipe_Failed

    return .None
}

// Drain the self-pipe and re-query the size, for reactors polling `read_fd`. Safe with
// nothing pending. Draining first costs a redundant wake when a signal lands mid-call;
// querying first would drain that signal away and lose the resize. A failed query still
// consumes the token.
resize_notifier_consume :: proc(n: ^Resize_Notifier) -> (Size, Resize_Error) {
    assert(n != nil, "resize_notifier_consume needs a notifier")
    assert(n.read_fd != n.write_fd, "resize_notifier_consume on an unarmed notifier")

    drain_pipe(n.read_fd)

    size, serr := get_size(n.tty)
    if serr != .None do return {}, .Size_Query_Failed

    return size, .None
}

// Block until a resize is signaled, then return the current size. One waiter at a time;
// a second concurrent call fails instead of stacking behind the first.
resize_notifier_wait :: proc(n: ^Resize_Notifier) -> (Size, Resize_Error) {
    if intrinsics.atomic_exchange(&n.waiting, true) do return {}, .Already_Waiting
    defer intrinsics.atomic_store(&n.waiting, false)

    for {
        fds := [1]posix.pollfd{{fd = n.read_fd, events = {.IN}, revents = {}}}
        r := posix.poll(raw_data(fds[:]), 1, -1)
        if r >= 0 do break

        if posix.errno() == .EINTR do continue

        // No dedicated poll-failure variant: an unexpected poll error leaves `wait`
        // unable to produce a size, the same outward failure as a bad ioctl.
        return {}, .Size_Query_Failed
    }

    return resize_notifier_consume(n)
}

// Empty the self-pipe (until EAGAIN) so `read_fd` stops reporting readable. One
// signal queues one byte, so a burst needs the loop to collapse into one wake.
drain_pipe :: proc(fd: posix.FD) {
    buf: [64]u8
    for {
        n := posix.read(fd, raw_data(buf[:]), len(buf))
        if n <= 0 do return
    }
}

// Tear down the notifier: restore the previous SIGWINCH disposition and close the pipe.
// The caller must have no `resize_notifier_wait` in flight. The step order below must not
// change: it keeps a handler from writing to an already-closed fd.
resize_notifier_destroy :: proc(n: ^Resize_Notifier) {
    assert(n != nil, "resize_notifier_destroy needs a notifier")
    assert(!intrinsics.atomic_load(&n.waiting), "resize_notifier_destroy with a wait in flight")

    // A zero-valued notifier (what a failed init returns, and what this leaves behind)
    // would disarm a live notifier and close fd 0 twice; real pipe ends are distinct.
    assert(n.read_fd != n.write_fd, "resize_notifier_destroy on an unarmed notifier")

    // 1. Withdraw the fd: a handler firing from here on loads -1 and returns.
    intrinsics.atomic_store(&g_write_fd, posix.FD(-1))

    // 2. Restore the previous disposition so no further signal reaches the handler.
    old := n.old_action
    posix.sigaction(SIGWINCH, &old, nil)

    // 3. A handler that loaded the fd before step 1 is still mid-write; let it finish.
    for intrinsics.atomic_load(&g_active_handlers) != 0 {
        intrinsics.cpu_relax()
    }

    // 4. Safe to close: no handler can still be touching either end.
    posix.close(n.read_fd)
    posix.close(n.write_fd)

    // Leave it unarmed so a second destroy asserts instead of double-closing.
    n^ = {}
}
