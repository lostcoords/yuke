package term

// Terminal size in character cells.
Size :: struct {
    width:  u16,
    height: u16,
}

// Failure modes from raw-mode and window-size queries. `None` is success. Names
// are OS-neutral: on POSIX `Get_Attr_Failed`/`Set_Attr_Failed` are the termios
// tcgetattr/tcsetattr failures and `Size_Query_Failed` is the TIOCGWINSZ ioctl; on
// Windows they map to GetConsoleMode/SetConsoleMode and GetConsoleScreenBufferInfo.
Term_Error :: enum {
    None,
    Get_Attr_Failed,
    Set_Attr_Failed,
    Size_Query_Failed,
}
