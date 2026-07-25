package testsupport

import "base:intrinsics"
import "core:nbio"
import "core:testing"
import "core:time"

NBIO_WAIT_DEADLINE :: 30 * time.Second

NBIO_WAIT_TICK :: 10 * time.Millisecond

_nbio_flag_set :: proc(done: ^bool) -> bool {
    return intrinsics.volatile_load(done)
}

nbio_run_until_flag :: proc(t: ^testing.T, done: ^bool, name: string, deadline := NBIO_WAIT_DEADLINE) -> bool {
    return nbio_run_until_condition(t, done, _nbio_flag_set, name, deadline)
}

nbio_run_until_condition :: proc(
    t: ^testing.T,
    state: ^$T,
    condition: proc(_: ^T) -> bool,
    name: string,
    deadline := NBIO_WAIT_DEADLINE,
) -> bool {
    assert(t != nil, "test context must not be nil")
    assert(state != nil, "wait state must not be nil")
    assert(condition != nil, "wait condition must not be nil")
    assert(len(name) > 0, "wait name must not be empty")
    assert(deadline > 0, "wait deadline must be positive")

    started := time.tick_now()
    for !condition(state) {
        elapsed := time.tick_diff(started, time.tick_now())
        if elapsed >= deadline {
            waiting := nbio.num_waiting()
            assert(waiting >= 0, "nbio waiting count must not be negative")

            testing.expectf(t, false, "%s timed out after %v with %d operations pending", name, deadline, waiting)
            return false
        }

        tick_timeout := min(NBIO_WAIT_TICK, deadline - elapsed)
        if err := nbio.tick(tick_timeout); err != nil {
            testing.expectf(t, false, "%s event-loop tick failed: %v", name, err)
            return false
        }
    }

    return true
}

nbio_run_until :: proc {
    nbio_run_until_flag,
    nbio_run_until_condition,
}
