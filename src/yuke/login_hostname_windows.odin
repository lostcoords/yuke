#+build windows
package main

import "core:os"
import win "core:sys/windows"

// Windows computer name. `$COMPUTERNAME` is set by the OS (not a shell convenience).
login_hostname :: proc() -> string {
    if v, set := os.lookup_env("COMPUTERNAME", context.allocator); set && v != "" {
        return v
    }

    return ""
}

login_stdin_is_tty :: proc() -> bool {
    handle := win.GetStdHandle(win.STD_INPUT_HANDLE)
    return win.GetFileType(handle) == win.FILE_TYPE_CHAR
}
