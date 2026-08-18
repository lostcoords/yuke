#+build linux, darwin
package term

import "core:sys/posix"
import "core:testing"

// `Winsize` must match the C `struct winsize` layout (four packed `u16` fields)
// for the ioctl call to fill it correctly.
#assert(size_of(Winsize) == 8)

@(test)
test_enable_raw_mode_on_non_tty_fails :: proc(t: ^testing.T) {
    fd := posix.open("/dev/null", {})
    testing.expect(t, fd >= 0)
    defer posix.close(fd)

    raw, err := enable_raw_mode(fd)
    testing.expect_value(t, err, Term_Error.Get_Attr_Failed)
    zero := Raw_Term{}
    testing.expect_value(t, raw, zero)
}

@(test)
test_get_size_on_non_tty_fails :: proc(t: ^testing.T) {
    fd := posix.open("/dev/null", {})
    testing.expect(t, fd >= 0)
    defer posix.close(fd)

    size, err := get_size(fd)
    testing.expect_value(t, err, Term_Error.Size_Query_Failed)
    zero := Size{}
    testing.expect_value(t, size, zero)
}

// Open a pty pair and return the slave fd, or -1. The master is handed back so
// the caller can close it; closing it early would invalidate the slave.
pty_open :: proc(master: ^posix.FD) -> posix.FD {
    master^ = posix.posix_openpt({.RDWR, .NOCTTY})
    if master^ < 0 do return -1

    if posix.grantpt(master^) != .OK || posix.unlockpt(master^) != .OK {
        posix.close(master^)
        return -1
    }

    name := posix.ptsname(master^)
    if name == nil {
        posix.close(master^)
        return -1
    }

    return posix.open(name, {.RDWR, .NOCTTY})
}

// A freshly allocated pty carries an all-zero winsize and the query still succeeds at
// the OS level; `.None` must never report a degenerate size.
@(test)
test_get_size_on_unsized_pty_fails :: proc(t: ^testing.T) {
    master: posix.FD
    slave := pty_open(&master)
    testing.expect(t, slave >= 0, "pty allocation")
    defer posix.close(master)
    defer posix.close(slave)

    testing.expect(t, bool(posix.isatty(slave)), "slave should be a tty")

    size, err := get_size(slave)
    testing.expect_value(t, err, Term_Error.Size_Query_Failed)
    zero := Size{}
    testing.expect_value(t, size, zero)
}
