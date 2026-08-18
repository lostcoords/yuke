#+build !windows
package main

import "core:c"
import "core:strings"
import "core:sys/posix"

// Kernel nodename (`gethostname` / `uname -n`). Empty when the call fails.
login_hostname :: proc() -> string {
    buf: [256]c.char
    if posix.gethostname(raw_data(buf[:]), len(buf)) == .OK do return strings.clone_from_cstring(cstring(&buf[0]), context.allocator) or_else ""

    return ""
}

login_stdin_is_tty :: proc() -> bool {
    return bool(posix.isatty(posix.STDIN_FILENO))
}
