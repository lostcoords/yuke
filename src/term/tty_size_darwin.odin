#+build darwin
package term

import "core:c"
import darwin "core:sys/darwin"

// Query the terminal's size in character cells via TIOCGWINSZ.
//
// Darwin's libc `ioctl` is a C vararg; a fixed 3-arg foreign binding mis-passes
// the third argument (EFAULT). Use the XNU syscall wrapper instead.
get_size :: proc(handle: Tty_Handle) -> (Size, Term_Error) {
    ws: Winsize
    rc := darwin.syscall_ioctl(c.int(handle), u32(darwin.TIOCGWINSZ), &ws)
    // The raw XNU trap reports failure as a POSITIVE errno (BSD carry-flag
    // convention); the wrapper does not negate it. Success is exactly 0, so a
    // `rc < 0` test would never fire. A pty with an unset winsize answers 0x0.
    if rc != 0 || ws.ws_col == 0 || ws.ws_row == 0 {
        return {}, .Size_Query_Failed
    }

    return {width = ws.ws_col, height = ws.ws_row}, .None
}
