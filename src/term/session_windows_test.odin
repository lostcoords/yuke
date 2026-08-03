#+build windows
package term

import "core:sys/windows"
import "core:testing"

// Runtime smoke test: enter/leave must execute and restore without crashing, and leave
// must be idempotent (it can run from panic/leave paths twice). The test process may
// not own a real console, so `mode_saved` can be false; the code-page path still runs.
@(test)
test_output_mode_enter_leave_round_trips :: proc(t: ^testing.T) {
    state := output_mode_enter(windows.GetStdHandle(windows.STD_OUTPUT_HANDLE))
    output_mode_leave(state)
    output_mode_leave(state)
}
