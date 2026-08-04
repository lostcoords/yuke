#+build linux
package term

import "core:c"

foreign import libc "system:c"

foreign libc {
    ioctl :: proc "c" (fd: c.int, request: c.ulong, arg: rawptr) -> c.int ---
}

TIOCGWINSZ :: 0x5413

// Query the terminal's size via TIOCGWINSZ. glibc's `ioctl` is a C vararg, but AAPCS64
// and SysV pass variadic arguments in the same registers as named ones, so a fixed 3-arg
// binding is ABI-correct here. Darwin needs the syscall wrapper instead.
get_size :: proc(handle: Tty_Handle) -> (Size, Term_Error) {
    ws: Winsize
    if ioctl(c.int(handle), c.ulong(TIOCGWINSZ), &ws) < 0 {
        return {}, .Size_Query_Failed
    }

    // The kernel zeroes `winsize` at tty allocation and TIOCGWINSZ succeeds regardless,
    // so an unset pty answers 0x0 without an error.
    if ws.ws_col == 0 || ws.ws_row == 0 {
        return {}, .Size_Query_Failed
    }

    return {width = ws.ws_col, height = ws.ws_row}, .None
}
