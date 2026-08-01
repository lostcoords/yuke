#+build darwin
package term

import "core:c"
import darwin "core:sys/darwin"
import "core:sys/posix"
import "core:testing"

TIOCSWINSZ :: 0x80087467

// Round-trip the size through a real pty. This is the only coverage of the XNU
// syscall path in `get_size`: the reason it exists is that a plain `foreign`
// binding to Darwin's variadic `ioctl` mis-passes the `winsize` pointer, and
// that failure mode is invisible to a non-tty test (both spellings "fail").
@(test)
test_get_size_reads_pty_winsize :: proc(t: ^testing.T) {
    master: posix.FD
    slave := pty_open(&master)
    testing.expect(t, slave >= 0, "pty allocation")
    defer posix.close(master)
    defer posix.close(slave)

    want := Winsize {
        ws_row = 40,
        ws_col = 100,
    }
    testing.expect_value(t, darwin.syscall_ioctl(c.int(slave), u32(TIOCSWINSZ), &want), 0)

    // Success on XNU is exactly 0; a failure returns a positive errno, which is
    // why `get_size` tests `rc != 0` rather than `rc < 0`.
    size, err := get_size(slave)
    testing.expect_value(t, err, Term_Error.None)
    testing.expect_value(t, size, Size{width = 100, height = 40})
}
