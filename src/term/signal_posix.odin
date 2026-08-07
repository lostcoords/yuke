#+build linux, darwin
package term

import "base:intrinsics"
import "core:c"
import "core:sys/posix"

// `posix.Signal` carries SIGINT/SIGTERM as enum members; SIGHUP/SIGQUIT are raw constants
// (a gap in the binding, like SIGWINCH), converted once here.
SIGHUP :: posix.Signal(posix.SIGHUP)
SIGQUIT :: posix.Signal(posix.SIGQUIT)

// Catchable signals whose default action terminates the process. On any of these the
// terminal is restored before the process dies; SIGKILL/SIGSTOP cannot be caught, and a
// crash (SIGSEGV/SIGABRT) is deliberately out of scope. `g_signal.old` is parallel to this.
// Package-private so the test tracks the real set instead of a hand-copied one.
@(private)
FATAL_SIGNALS :: [4]posix.Signal{SIGHUP, posix.Signal(posix.SIGINT), SIGQUIT, posix.Signal(posix.SIGTERM)}

// Fatal-restore state, published while a session is live. A `proc "c"` handler receives no
// user pointer, so the snapshot is global; one session may be armed per process (asserted).
@(private = "file")
Signal_Restore :: struct {
    // Terminal fd for the emergency escape write; < 0 means disarmed. Loaded atomically by
    // the handler, published last by arm and withdrawn first by disarm.
    fd:  posix.FD,

    // Saved raw-mode state, reset via `tcsetattr` in the handler.
    raw: Raw_Term,

    // Previous dispositions, restored on disarm and chained-to on re-raise.
    old: [4]posix.sigaction_t,
}

@(private = "file")
g_signal := Signal_Restore {
    fd = -1,
}

// Handler invocations in flight; disarm spins on this so a handler that already loaded the
// snapshot finishes before the state is cleared.
@(private = "file")
g_signal_active: int

// Async-signal-safe fatal handler: only `write`, `tcsetattr`, `sigaction`, `raise` — all on
// the POSIX async-signal-safe list. Restores the terminal, then chains to the previous
// disposition and re-raises so the process still dies with the right status. A signal that
// arrives before `fd` is published (or after it is withdrawn) skips the restore but still
// re-raises, so a fatal signal is never swallowed.
@(private = "file")
sig_restore_handler :: proc "c" (sig: posix.Signal) {
    intrinsics.atomic_add(&g_signal_active, 1)
    defer intrinsics.atomic_sub(&g_signal_active, 1)

    if fd := intrinsics.atomic_load(&g_signal.fd); fd >= 0 {
        posix.write(fd, raw_data(SIGNAL_RESTORE_ALL), c.size_t(len(SIGNAL_RESTORE_ALL)))
        posix.tcsetattr(g_signal.raw.fd, .TCSAFLUSH, &g_signal.raw.saved)
    }

    for s, i in FATAL_SIGNALS {
        if s == sig {
            posix.sigaction(sig, &g_signal.old[i], nil)
            break
        }
    }

    posix.raise(sig)
}

// Install the fatal-signal terminal restore. `fd` is the terminal the escape blob is written
// to; `raw` supplies the termios to reset. Only one session may be armed per process.
@(private)
signal_restore_arm :: proc(fd: Tty_Handle, raw: Raw_Term, _: Output_Mode_State) {
    assert(intrinsics.atomic_load(&g_signal.fd) < 0, "signal_restore_arm while already armed")

    g_signal.raw = raw

    mask: posix.sigset_t
    posix.sigemptyset(&mask)

    action := posix.sigaction_t {
        sa_handler = sig_restore_handler,
        sa_mask    = mask,
    }
    for s, i in FATAL_SIGNALS {
        posix.sigaction(s, &action, &g_signal.old[i])
    }

    // Publish last so a handler that reads a valid fd sees a fully-populated snapshot.
    intrinsics.atomic_store(&g_signal.fd, fd)
}

// Uninstall the fatal-signal restore. Order mirrors `resize_notifier_destroy`: withdraw the
// fd, restore the previous dispositions so no further signal reaches the handler, then wait
// out any handler still in flight before clearing the snapshot.
@(private)
signal_restore_disarm :: proc() {
    if intrinsics.atomic_load(&g_signal.fd) < 0 {
        return
    }

    intrinsics.atomic_store(&g_signal.fd, posix.FD(-1))

    for s, i in FATAL_SIGNALS {
        posix.sigaction(s, &g_signal.old[i], nil)
    }

    for intrinsics.atomic_load(&g_signal_active) != 0 {
        intrinsics.cpu_relax()
    }

    g_signal = Signal_Restore {
        fd = -1,
    }
}
