#+build windows
package main

import "core:os"

// Windows computer name. `$COMPUTERNAME` is set by the OS (not a shell convenience).
login_hostname :: proc() -> string {
    if v, set := os.lookup_env("COMPUTERNAME", context.allocator); set && v != "" {
        return v
    }

    return ""
}
