package term

// Terminal size in character cells. A `.None` result guarantees both fields are
// non-zero: a degenerate 0x0 is `Size_Query_Failed` on every OS.
Size :: struct {
    width:  u16,
    height: u16,
}

// Failure modes from raw-mode and window-size queries. `None` is success. Names are
// OS-neutral: on POSIX the termios tcgetattr/tcsetattr failures and the TIOCGWINSZ
// ioctl; on Windows GetConsoleMode/SetConsoleMode and GetConsoleScreenBufferInfo.
Term_Error :: enum {
    None,
    Get_Attr_Failed,
    Set_Attr_Failed,
    Size_Query_Failed,
}
