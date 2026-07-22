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
    testing.expect_value(t, raw, Raw_Term{})
}

@(test)
test_get_size_on_non_tty_fails :: proc(t: ^testing.T) {
    fd := posix.open("/dev/null", {})
    testing.expect(t, fd >= 0)
    defer posix.close(fd)

    size, err := get_size(fd)
    testing.expect_value(t, err, Term_Error.Size_Query_Failed)
    testing.expect_value(t, size, Size{})
}
