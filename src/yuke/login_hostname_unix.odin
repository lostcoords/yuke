#+build !windows
package main

import "core:c"
import "core:strings"
import "core:sys/posix"

// Kernel nodename (`gethostname` / `uname -n`). Empty when the call fails.
login_hostname :: proc() -> string {
    buf: [256]c.char
    if posix.gethostname(raw_data(buf[:]), len(buf)) == .OK {
        return strings.clone_from_cstring(cstring(&buf[0]), context.allocator) or_else ""
    }

    return ""
}
