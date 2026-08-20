#+build linux, darwin
package js

import "core:c"
import "core:nbio"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:testing"
import "core:time"

import "libs:testsupport"

// The reaper owns the one process-wide SIGCHLD disposition, so anything that installs
// it — the reaper tests and every exec test — must hold this while it runs; the
// parallel runner would otherwise race on the global. Other tests (fs, diff) never
// spawn children and run alongside freely.
@(private)
sigchld_singleton_lock: sync.Mutex

@(private = "file")
Kid :: struct {
    done: bool,
    code: int,
}

@(private = "file")
kid_on_exit :: proc(user: rawptr, code: int) {
    k := cast(^Kid)user
    k.code = code
    k.done = true
}

// Spawn `/bin/sh -c line` as a bare child (no pgroup — the reaper only reaps the
// direct child). Fails the test on a spawn error.
@(private = "file")
spawn_sh :: proc(t: ^testing.T, line: string) -> posix.pid_t {
    pid: posix.pid_t
    command := strings.clone_to_cstring(line, context.temp_allocator)
    argv := [4]cstring{"sh", "-c", command, nil}

    err := posix.posix_spawn(&pid, "/bin/sh", nil, nil, raw_data(argv[:]), posix.environ)
    testing.expect_value(t, err, posix.Errno.NONE)

    return pid
}

@(test)
test_reaper_reaps_a_child :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    sync.lock(&sigchld_singleton_lock)
    defer sync.unlock(&sigchld_singleton_lock)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    r: Child_Reaper
    testing.expect_value(t, reaper_init(&r, loop, context.temp_allocator), Reaper_Error.None)
    defer reaper_destroy(&r)

    k: Kid
    reaper_watch(&r, spawn_sh(t, "exit 7"), kid_on_exit, &k)

    testsupport.nbio_run_until(t, &k.done, "reap child")
    testing.expect_value(t, k.code, 7)
}

@(test)
test_reaper_reports_a_signalled_death :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    sync.lock(&sigchld_singleton_lock)
    defer sync.unlock(&sigchld_singleton_lock)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    r: Child_Reaper
    testing.expect_value(t, reaper_init(&r, loop, context.temp_allocator), Reaper_Error.None)
    defer reaper_destroy(&r)

    k: Kid
    // The shell kills itself with SIGTERM: 128 + 15.
    reaper_watch(&r, spawn_sh(t, "kill -TERM $$"), kid_on_exit, &k)

    testsupport.nbio_run_until(t, &k.done, "reap signalled child")
    testing.expect_value(t, k.code, 128 + 15)
}

@(private = "file")
kids_all_done :: proc(kids: ^[3]Kid) -> bool {
    return kids[0].done && kids[1].done && kids[2].done
}

@(test)
test_reaper_reaps_concurrent_children :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    sync.lock(&sigchld_singleton_lock)
    defer sync.unlock(&sigchld_singleton_lock)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    r: Child_Reaper
    testing.expect_value(t, reaper_init(&r, loop, context.temp_allocator), Reaper_Error.None)
    defer reaper_destroy(&r)

    kids: [3]Kid
    reaper_watch(&r, spawn_sh(t, "exit 1"), kid_on_exit, &kids[0])
    reaper_watch(&r, spawn_sh(t, "exit 2"), kid_on_exit, &kids[1])
    reaper_watch(&r, spawn_sh(t, "exit 3"), kid_on_exit, &kids[2])

    // Let all three reach zombie state before any tick, so the single readiness wake
    // below must reap every one of them: SIGCHLD coalesces, so one drained byte has
    // to account for all three. A reaper that reaped one child per wake would drain
    // the coalesced byte, reap one, and hang — the other two would never complete.
    time.sleep(50 * time.Millisecond)
    testing.expect_value(t, nbio.tick(10 * time.Millisecond), nil)

    testing.expect(t, kids_all_done(&kids), "one wake reaps every pending child")
    testing.expect_value(t, kids[0].code, 1)
    testing.expect_value(t, kids[1].code, 2)
    testing.expect_value(t, kids[2].code, 3)
}

@(private = "file")
Chain :: struct {
    r:      ^Child_Reaper,
    t:      ^testing.T,
    a_code: int,
    b_code: int,
    b_done: bool,
}

@(private = "file")
chain_on_a :: proc(user: rawptr, code: int) {
    c := cast(^Chain)user
    c.a_code = code

    // Re-enter the reaper from inside an exit callback — the shape the exec layer
    // uses to chain commands. This ran while `reaper_reap` holds the wake.
    reaper_watch(c.r, spawn_sh(c.t, "exit 9"), chain_on_b, user)
}

@(private = "file")
chain_on_b :: proc(user: rawptr, code: int) {
    c := cast(^Chain)user
    c.b_code = code
    c.b_done = true
}

@(test)
test_reaper_rearms_from_an_exit_callback :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    sync.lock(&sigchld_singleton_lock)
    defer sync.unlock(&sigchld_singleton_lock)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    r: Child_Reaper
    testing.expect_value(t, reaper_init(&r, loop, context.temp_allocator), Reaper_Error.None)
    defer reaper_destroy(&r)

    // Watching a second child from the first's callback re-arms the poll mid-reap;
    // the reaper must keep exactly one poll live rather than double-arm.
    c := Chain {
        r = &r,
        t = t,
    }
    reaper_watch(&r, spawn_sh(t, "exit 5"), chain_on_a, &c)

    testsupport.nbio_run_until(t, &c.b_done, "reap chained child")
    testing.expect_value(t, c.a_code, 5)
    testing.expect_value(t, c.b_code, 9)
}

@(test)
test_reaper_leaves_no_zombie :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    sync.lock(&sigchld_singleton_lock)
    defer sync.unlock(&sigchld_singleton_lock)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    r: Child_Reaper
    testing.expect_value(t, reaper_init(&r, loop, context.temp_allocator), Reaper_Error.None)
    defer reaper_destroy(&r)

    k: Kid
    pid := spawn_sh(t, "exit 0")
    reaper_watch(&r, pid, kid_on_exit, &k)
    testsupport.nbio_run_until(t, &k.done, "reap child")

    // Already reaped: a second wait finds no such child.
    status: c.int
    got := posix.waitpid(pid, &status, {.NOHANG})
    testing.expect_value(t, got, posix.pid_t(-1))
}

@(private = "file")
disposition_sentinel :: proc "c" (sig: posix.Signal) {}

@(test)
test_reaper_restores_the_previous_disposition :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    sync.lock(&sigchld_singleton_lock)
    defer sync.unlock(&sigchld_singleton_lock)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    sigchld := posix.Signal(posix.SIGCHLD)

    saved: posix.sigaction_t
    posix.sigaction(sigchld, nil, &saved)
    defer posix.sigaction(sigchld, &saved, nil)

    // Install a recognizable disposition, then prove the reaper restores exactly it.
    sentinel: posix.sigaction_t
    posix.sigemptyset(&sentinel.sa_mask)
    sentinel.sa_handler = disposition_sentinel
    posix.sigaction(sigchld, &sentinel, nil)

    r: Child_Reaper
    testing.expect_value(t, reaper_init(&r, loop, context.temp_allocator), Reaper_Error.None)
    reaper_destroy(&r)

    after: posix.sigaction_t
    posix.sigaction(sigchld, nil, &after)
    testing.expect_value(t, cast(rawptr)after.sa_handler, cast(rawptr)disposition_sentinel)

    // The global write fd is withdrawn, so a fresh reaper installs cleanly.
    r2: Child_Reaper
    testing.expect_value(t, reaper_init(&r2, loop, context.temp_allocator), Reaper_Error.None)
    reaper_destroy(&r2)
}
