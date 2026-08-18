#+build linux, darwin
package term

import "core:sys/posix"

// The terminal handle on POSIX: a plain file descriptor. Raw-mode and get_size
// take the same tty fd (input and output name one tty).
Tty_Handle :: posix.FD

// `struct winsize` from `<sys/ioctl.h>`; field order matches the C layout so the
// ioctl call fills it in place.
Winsize :: struct {
    ws_row:    u16,
    ws_col:    u16,
    ws_xpixel: u16,
    ws_ypixel: u16,
}
#assert(size_of(Winsize) == 8)

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
    if posix.tcgetattr(handle, &saved) != .OK do return {}, .Get_Attr_Failed

    raw := saved
    raw.c_iflag -= {.BRKINT, .ICRNL, .INPCK, .ISTRIP, .IXON}
    raw.c_oflag -= {.OPOST}
    raw.c_lflag -= {.ECHO, .ICANON, .IEXTEN, .ISIG}

    // CS8 spans both bits of the 2-bit CSIZE field, so its bit_set member aliases CS7's
    // single bit. Clear the whole CSIZE mask and OR in the raw CS8 pattern, the way
    // `posix.CSIZE` itself is built, instead of trusting `.CS8`.
    raw.c_cflag -= posix.CSIZE
    raw.c_cflag += transmute(posix.CControl_Flags)posix.tcflag_t(posix.CS8)

    raw.c_cc[.VMIN] = 1
    raw.c_cc[.VTIME] = 0

    // TCSAFLUSH discards unread input before applying.
    if posix.tcsetattr(handle, .TCSAFLUSH, &raw) != .OK do return {}, .Set_Attr_Failed

    return {saved = saved, fd = handle}, .None
}

// Restore the terminal state captured by `enable_raw_mode`.
disable_raw_mode :: proc(t: Raw_Term) -> Term_Error {
    saved := t.saved
    if posix.tcsetattr(t.fd, .TCSAFLUSH, &saved) != .OK do return .Set_Attr_Failed

    return .None
}
