#+build linux, darwin
package term

import "core:c"
import "core:sys/posix"

// The terminal handle on POSIX: a plain file descriptor. Raw-mode and get_size
// take the same tty fd (input and output name one tty).
Tty_Handle :: posix.FD

when ODIN_OS == .Darwin {
    foreign import libc "system:System"
} else {
    foreign import libc "system:c"
}

foreign libc {
    ioctl :: proc(fd: posix.FD, request: c.ulong, arg: rawptr) -> c.int ---
}

// `struct winsize` from `<sys/ioctl.h>`; field order matches the C layout so the
// ioctl call fills it in place.
Winsize :: struct {
    ws_row:    u16,
    ws_col:    u16,
    ws_xpixel: u16,
    ws_ypixel: u16,
}
#assert(size_of(Winsize) == 8)

when ODIN_OS == .Darwin {
    TIOCGWINSZ :: 0x40087468
} else {
    TIOCGWINSZ :: 0x5413
}

// Saved terminal state plus the fd it was captured from, so `disable_raw_mode`
// restores it on the same descriptor.
Raw_Term :: struct {
    saved: posix.termios,
    fd:    posix.FD,
}

// Enter raw mode on `handle`: no line buffering or echo, no signal generation, 8-bit
// clean input, one byte at a time with no read timeout.
enable_raw_mode :: proc(handle: Tty_Handle) -> (Raw_Term, Term_Error) {
    saved: posix.termios
    if posix.tcgetattr(handle, &saved) != .OK {
        return {}, .Get_Attr_Failed
    }

    raw := saved
    raw.c_iflag -= {.BRKINT, .ICRNL, .INPCK, .ISTRIP, .IXON}
    raw.c_oflag -= {.OPOST}
    raw.c_lflag -= {.ECHO, .ICANON, .IEXTEN, .ISIG}

    // CS8 spans both bits of the 2-bit CSIZE field, so its bit_set enum member
    // (derived via floor-log2 of a non-power-of-two mask) aliases CS7's single
    // bit rather than representing CS8 on its own. Clear the whole CSIZE mask
    // and OR in the raw CS8 bit pattern directly, the same way `posix.CSIZE`
    // itself is built, instead of trusting `.CS8`.
    raw.c_cflag -= posix.CSIZE
    raw.c_cflag += transmute(posix.CControl_Flags)posix.tcflag_t(posix.CS8)

    raw.c_cc[.VMIN] = 1
    raw.c_cc[.VTIME] = 0

    // TCSAFLUSH discards unread input before applying.
    if posix.tcsetattr(handle, .TCSAFLUSH, &raw) != .OK {
        return {}, .Set_Attr_Failed
    }

    return {saved = saved, fd = handle}, .None
}

// Restore the terminal state captured by `enable_raw_mode`.
disable_raw_mode :: proc(t: Raw_Term) -> Term_Error {
    saved := t.saved
    if posix.tcsetattr(t.fd, .TCSAFLUSH, &saved) != .OK {
        return .Set_Attr_Failed
    }

    return .None
}

// Query the terminal's size in character cells via TIOCGWINSZ. `handle` is the tty
// fd; input and output name the same tty on POSIX, so either works.
get_size :: proc(handle: Tty_Handle) -> (Size, Term_Error) {
    ws: Winsize
    if ioctl(handle, TIOCGWINSZ, &ws) < 0 {
        return {}, .Size_Query_Failed
    }

    return {width = ws.ws_col, height = ws.ws_row}, .None
}
