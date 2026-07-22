#+build windows
package term

import "core:sys/windows"

// Wait for the console input `handle` to be readable, up to `timeout_ms` ms (the
// negotiate loop only ever passes a value >= 0).
//
// TODO(windows-verify): the input handle signals for any input record, including ones
// that translate to zero VT bytes (key-up, focus, buffer-size). A blocking ReadFile
// after such a wake may not return a byte immediately, so the negotiate deadline is
// best-effort until confirmed on real conhost / Windows Terminal.
poll_readable :: proc(handle: Tty_Handle, timeout_ms: i32) -> bool {
    return windows.WaitForSingleObject(handle, windows.DWORD(timeout_ms)) == windows.WAIT_OBJECT_0
}

// Read one byte from the console input `handle`. `ok` is false on EOF or error.
read_byte :: proc(handle: Tty_Handle) -> (u8, bool) {
    b: [1]u8
    read: windows.DWORD
    if !windows.ReadFile(handle, raw_data(b[:]), 1, &read, nil) || read == 0 {
        return 0, false
    }

    return b[0], true
}

// Saved console-output configuration, restored by `output_mode_leave`. The code page
// is a process-global console attribute (no handle); only the mode is per-handle.
Output_Mode_State :: struct {
    // Console screen-buffer output handle the mode was captured from.
    handle:      windows.HANDLE,

    // Saved output console mode; restore only when `mode_saved`.
    prev_mode:   windows.DWORD,

    // Whether GetConsoleMode succeeded (output really is a console).
    mode_saved:  bool,

    // Saved output code page; `.ACP` (0) is GetConsoleOutputCP's failure return, so it
    // doubles as the "not captured — skip restore" sentinel.
    prev_out_cp: windows.CODEPAGE,

    // Saved input code page; `.ACP` (0) is GetConsoleCP's failure return, likewise the
    // "not captured — skip restore" sentinel.
    prev_in_cp:  windows.CODEPAGE,
}

// Configure the console for TUI output: enable ENABLE_VIRTUAL_TERMINAL_PROCESSING on
// the OUTPUT handle (preserve-and-OR, so our escapes are interpreted rather than
// printed literally) and switch the console code pages to UTF-8, saving both to
// restore. Deliberately does NOT set DISABLE_NEWLINE_AUTO_RETURN (it breaks `\n` on the
// legacy console; Windows Terminal does not set it either). Best-effort: when output is
// not a console (redirected), the mode step is skipped and its restore is a no-op.
//
// TODO(windows-verify): the runtime effect needs a real console; the test suite has no
// console, so only compilation is exercised here.
output_mode_enter :: proc() -> Output_Mode_State {
    state: Output_Mode_State
    state.handle = windows.GetStdHandle(windows.STD_OUTPUT_HANDLE)

    if windows.GetConsoleMode(state.handle, &state.prev_mode) {
        state.mode_saved = true
        windows.SetConsoleMode(state.handle, state.prev_mode | windows.ENABLE_VIRTUAL_TERMINAL_PROCESSING)
    }

    // Code-page calls are process-global (no handle); UTF-8 keeps the byte-stream
    // invariant the reader and src/ui rely on.
    state.prev_out_cp = windows.GetConsoleOutputCP()
    windows.SetConsoleOutputCP(windows.CODEPAGE.UTF8)

    state.prev_in_cp = windows.GetConsoleCP()
    windows.SetConsoleCP(windows.CODEPAGE.UTF8)

    return state
}

// Restore whatever `output_mode_enter` changed. Best-effort; results ignored, like the
// POSIX restore paths.
output_mode_leave :: proc(state: Output_Mode_State) {
    if state.mode_saved {
        windows.SetConsoleMode(state.handle, state.prev_mode)
    }

    if state.prev_out_cp != windows.CODEPAGE.ACP {
        windows.SetConsoleOutputCP(state.prev_out_cp)
    }

    if state.prev_in_cp != windows.CODEPAGE.ACP {
        windows.SetConsoleCP(state.prev_in_cp)
    }
}
