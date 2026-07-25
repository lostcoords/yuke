#+build windows
package term

import "core:sys/windows"

// The terminal handle on Windows: a console HANDLE. Unlike POSIX, raw-mode and
// get_size take DIFFERENT handles (input vs screen-buffer output) — see per-proc.
Tty_Handle :: windows.HANDLE

// Saved console input mode plus the input handle it was captured from, so
// `disable_raw_mode` restores it on the same handle.
Raw_Term :: struct {
    saved:  windows.DWORD,
    handle: windows.HANDLE,
}

// Enter raw mode on the console INPUT `handle` (GetStdHandle(STD_INPUT_HANDLE)).
// Sets ENABLE_MOUSE_INPUT | ENABLE_WINDOW_INPUT | ENABLE_VIRTUAL_TERMINAL_INPUT as
// a full overwrite: line input, echo, and processed input are off by absence.
// Processed input off means Ctrl-C arrives as byte 0x03, the same as POSIX with
// ISIG cleared.
enable_raw_mode :: proc(handle: Tty_Handle) -> (Raw_Term, Term_Error) {
    saved: windows.DWORD
    if !windows.GetConsoleMode(handle, &saved) {
        return {}, .Get_Attr_Failed
    }

    mode := windows.ENABLE_MOUSE_INPUT | windows.ENABLE_WINDOW_INPUT | windows.ENABLE_VIRTUAL_TERMINAL_INPUT
    if !windows.SetConsoleMode(handle, mode) {
        return {}, .Set_Attr_Failed
    }

    return {saved = saved, handle = handle}, .None
}

// Restore the console input mode captured by `enable_raw_mode`.
disable_raw_mode :: proc(t: Raw_Term) -> Term_Error {
    if !windows.SetConsoleMode(t.handle, t.saved) {
        return .Set_Attr_Failed
    }

    return .None
}

// Query the terminal's size in character cells. HANDLE-MEANING: `handle` is the
// console screen-buffer OUTPUT handle (GetStdHandle(STD_OUTPUT_HANDLE)), NOT the
// input handle passed to `enable_raw_mode`. Uses srWindow (the visible viewport),
// not dwSize (the scrollback buffer); SMALL_RECT bounds are inclusive.
get_size :: proc(handle: Tty_Handle) -> (Size, Term_Error) {
    info: windows.CONSOLE_SCREEN_BUFFER_INFO
    if !windows.GetConsoleScreenBufferInfo(handle, &info) {
        return {}, .Size_Query_Failed
    }

    width := int(info.srWindow.Right) - int(info.srWindow.Left) + 1
    height := int(info.srWindow.Bottom) - int(info.srWindow.Top) + 1

    return {width = u16(width), height = u16(height)}, .None
}
