#+build linux, darwin
package term

import "core:sys/posix"
import "core:testing"

// Arming installs the fatal-signal handler for each catchable terminate signal, and disarm
// restores the exact previous disposition. No real tty is needed: the fd is only stored (the
// handler is never invoked here), so a dummy fd suffices.
@(test)
test_signal_restore_arm_disarm :: proc(t: ^testing.T) {
    before: [len(FATAL_SIGNALS)]posix.sigaction_t
    for s, i in FATAL_SIGNALS {
        posix.sigaction(s, nil, &before[i])
    }

    raw := Raw_Term {
        fd = posix.FD(2),
    }
    signal_restore_arm(posix.FD(2), raw, {})

    for s, i in FATAL_SIGNALS {
        cur: posix.sigaction_t
        posix.sigaction(s, nil, &cur)
        installed := (transmute(uintptr)cur.sa_handler) != (transmute(uintptr)before[i].sa_handler)
        testing.expect(t, installed, "arm did not install a handler")
    }

    signal_restore_disarm()

    for s, i in FATAL_SIGNALS {
        cur: posix.sigaction_t
        posix.sigaction(s, nil, &cur)
        restored := (transmute(uintptr)cur.sa_handler) == (transmute(uintptr)before[i].sa_handler)
        testing.expect(t, restored, "disarm did not restore the original disposition")
    }

    // Disarm fully cleared the single-arm guard, so a second cycle asserts-free.
    signal_restore_arm(posix.FD(2), raw, {})
    signal_restore_disarm()
}
