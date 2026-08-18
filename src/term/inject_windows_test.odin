#+build windows
package term

import "core:sys/windows"

// An anonymous pipe standing in for the console; the relay reads it with the same
// blocking ReadFile.

// Not bound by core:sys/windows. PIPE_NOWAIT is deprecated but is still the only way to
// make an anonymous pipe's write end non-blocking.
foreign import kernel32 "system:Kernel32.lib"

@(default_calling_convention = "system")
foreign kernel32 {
    SetNamedPipeHandleState :: proc(h: windows.HANDLE, mode: ^windows.DWORD, cnt: ^windows.DWORD, timeout: ^windows.DWORD) -> windows.BOOL ---
}

PIPE_NOWAIT :: windows.DWORD(0x00000001)

inject_open :: proc() -> (r, w: Tty_Handle, ok: bool) {
    read_h, write_h: windows.HANDLE
    if !windows.CreatePipe(&read_h, &write_h, nil, 0) do return nil, nil, false

    return read_h, write_h, true
}

inject_close :: proc(h: Tty_Handle) {
    windows.CloseHandle(h)
}

// One write attempt; <= 0 means would-block or error.
inject_write_some :: proc(w: Tty_Handle, data: []u8) -> int {
    written: windows.DWORD
    if !windows.WriteFile(w, raw_data(data), windows.DWORD(len(data)), &written, nil) do return -1

    return int(written)
}

inject_nonblocking :: proc(w: Tty_Handle) -> bool {
    mode := PIPE_NOWAIT

    return bool(SetNamedPipeHandleState(w, &mode, nil, nil))
}
