#+build windows
package term

import "core:sys/windows"
import "core:testing"

// Enter/leave must restore without crashing, and leave must be idempotent. The test
// process may not own a console, so `mode_saved` can be false; the code-page path runs.
@(test)
test_output_mode_enter_leave_round_trips :: proc(t: ^testing.T) {
    state := output_mode_enter(windows.GetStdHandle(windows.STD_OUTPUT_HANDLE))
    output_mode_leave(state)
    output_mode_leave(state)
}
