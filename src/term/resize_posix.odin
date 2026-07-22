#+build linux, darwin
package term

import "base:intrinsics"
import "core:sys/posix"

// `posix.Signal` has no SIGWINCH member (a gap in the binding); `posix.SIGWINCH`
// is the raw per-platform constant, converted once here.
SIGWINCH :: posix.Signal(posix.SIGWINCH)

// Process-wide singleton: a POSIX handler installed without SA_SIGINFO gets no
// user-data pointer, so it has no way to reach a `^Resize_Notifier` except
// through a global. This is the pipe write end the handler targets; -1 means no
// notifier is armed. One notifier is live at a time (one tty).
g_write_fd: posix.FD = -1

// Count of handler invocations currently in flight. `resize_notifier_destroy`
// spins on this before closing the pipe, so a handler that already loaded
// `g_write_fd` is guaranteed to finish its write before the fd it's holding is
// closed out from under it.
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
    // Self-pipe read end (non-blocking); polled by `resize_notifier_wait`.
    read_fd:    posix.FD,

    // Self-pipe write end; published to `g_write_fd` for the handler.
    write_fd:   posix.FD,

    // Previous SIGWINCH disposition, restored by `resize_notifier_destroy`.
    old_action: posix.sigaction_t,

    // Borrowed tty handle, re-queried via `get_size` on wake. Must outlive the notifier.
    tty:        Tty_Handle,

    // Guards against concurrent `resize_notifier_wait` calls.
    waiting:    bool,
}

// Async-signal-safe SIGWINCH handler: strictly no Odin context, no allocation,
// no printing — only atomic ops and one non-blocking write.
sigwinch_handler :: proc "c" (sig: posix.Signal) {
    intrinsics.atomic_add(&g_active_handlers, 1)
    defer intrinsics.atomic_sub(&g_active_handlers, 1)

    fd := intrinsics.atomic_load(&g_write_fd)
    if fd < 0 {
        return
    }

    b: [1]u8
    // Result discarded: EAGAIN when a byte is already queued is not a failure,
    // it is the coalescing mechanism — a burst of SIGWINCH collapses into one
    // pending byte, hence one wake. A signal handler has no safe way to report
    // anything else regardless.
    posix.write(fd, raw_data(b[:]), 1)
}

// Install the SIGWINCH self-pipe notifier for `tty`. Only one notifier may be
// live per process at a time (one tty to resize).
resize_notifier_init :: proc(tty: Tty_Handle) -> (Resize_Notifier, Resize_Error) {
    fds: [2]posix.FD
    if posix.pipe(&fds) != .OK {
        return {}, .Pipe_Failed
    }

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

    return Resize_Notifier{read_fd = fds[0], write_fd = fds[1], old_action = old, tty = tty}, .None
}

// Set O_NONBLOCK and FD_CLOEXEC on one pipe end.
pipe_prepare :: proc(fd: posix.FD) -> Resize_Error {
    if posix.fcntl(fd, .SETFL, posix.O_Flags{.NONBLOCK}) < 0 {
        return .Pipe_Failed
    }

    if posix.fcntl(fd, .SETFD, i32(posix.FD_CLOEXEC)) < 0 {
        return .Pipe_Failed
    }

    return .None
}

// Block until a resize is signaled, then return the terminal's current size.
// Only one waiter at a time; a second concurrent call fails immediately rather
// than stacking behind the first.
resize_notifier_wait :: proc(n: ^Resize_Notifier) -> (Size, Resize_Error) {
    if intrinsics.atomic_exchange(&n.waiting, true) {
        return {}, .Already_Waiting
    }
    defer intrinsics.atomic_store(&n.waiting, false)

    for {
        fds := [1]posix.pollfd{{fd = n.read_fd, events = {.IN}, revents = {}}}
        r := posix.poll(raw_data(fds[:]), 1, -1)
        if r >= 0 {
            break
        }

        if posix.errno() == .EINTR {
            continue
        }

        // No dedicated poll-failure variant: an unexpected poll error leaves
        // `wait` unable to produce a size, the same outward failure as a bad
        // ioctl below.
        return {}, .Size_Query_Failed
    }

    drain_pipe(n.read_fd)

    // The event only means "at least one resize happened"; the dimensions
    // always come from ioctl, never from the pipe.
    size, serr := get_size(n.tty)
    if serr != .None {
        return {}, .Size_Query_Failed
    }

    return size, .None
}

// Drain every byte queued on the self-pipe until empty (EAGAIN) or another
// error. Bursts of SIGWINCH coalesce to at most one pending byte, but draining
// in a loop is still correct if more than one arrived between wakes.
drain_pipe :: proc(fd: posix.FD) {
    buf: [64]u8
    for {
        n := posix.read(fd, raw_data(buf[:]), len(buf))
        if n <= 0 {
            return
        }
    }
}

// Read end of the self-pipe, for a caller running its own `poll` loop over
// stdin and this fd together (driving the terminal `Reader` while also
// watching for resize). On readiness the caller must drain the pipe and
// re-query the size itself, the same as `resize_notifier_wait` does.
resize_notifier_fd :: proc(n: ^Resize_Notifier) -> posix.FD {
    return n.read_fd
}

// Tear down the notifier: restore the previous SIGWINCH disposition and close
// the pipe. The caller must have no `resize_notifier_wait` in flight.
//
// Order matters here and must not change: it prevents a handler from writing
// to a pipe fd this has already closed.
resize_notifier_destroy :: proc(n: ^Resize_Notifier) {
    assert(!intrinsics.atomic_load(&n.waiting))

    // 1. Withdraw the fd first. A handler that fires from this point on loads
    //    -1 and returns without touching the pipe.
    intrinsics.atomic_store(&g_write_fd, posix.FD(-1))

    // 2. Restore the previous disposition so no further signal reaches our
    //    handler at all.
    old := n.old_action
    posix.sigaction(SIGWINCH, &old, nil)

    // 3. A handler that loaded the fd before step 1 is still mid-write; wait
    //    for it to finish before the fd it's holding is closed.
    for intrinsics.atomic_load(&g_active_handlers) != 0 {
        intrinsics.cpu_relax()
    }

    // 4. Only now is it safe to close: no handler can still be touching
    //    either end.
    posix.close(n.read_fd)
    posix.close(n.write_fd)
}
