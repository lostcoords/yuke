package main

import "core:os"
import term "src:term"

// stdin drives raw mode and reads; stdout drives size queries and VT output. POSIX backs
// both with the same tty (fds 0 and 1); Windows splits them into the console INPUT and
// screen-buffer OUTPUT handles. `os.stdin`/`os.stdout` already hold the right handle on
// each platform, so one accessor covers both.

stdin_handle :: proc() -> term.Tty_Handle {
    return term.Tty_Handle(os.fd(os.stdin))
}

stdout_handle :: proc() -> term.Tty_Handle {
    return term.Tty_Handle(os.fd(os.stdout))
}
