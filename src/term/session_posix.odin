#+build linux, darwin
package term

import "core:c"
import "core:sys/posix"

// Poll the tty fd for readability. `timeout_ms` is milliseconds; a poll error is
// treated as "not readable" so the caller stops reading.
poll_readable :: proc(handle: Tty_Handle, timeout_ms: i32) -> bool {
    fds := [1]posix.pollfd{{fd = handle, events = {.IN}, revents = {}}}

    return posix.poll(raw_data(fds[:]), 1, c.int(timeout_ms)) > 0
}

// Read one byte from the tty fd. `ok` is false on EOF or error.
read_byte :: proc(handle: Tty_Handle) -> (u8, bool) {
    b: [1]u8
    if posix.read(handle, raw_data(b[:]), 1) <= 0 {
        return 0, false
    }

    return b[0], true
}

// Nothing to configure for output on POSIX. Present so session.odin's enter/leave
// stay OS-agnostic; the Windows definition carries the real saved state.
Output_Mode_State :: struct {}

output_mode_enter :: proc() -> Output_Mode_State {
    return {}
}

output_mode_leave :: proc(_: Output_Mode_State) {}
