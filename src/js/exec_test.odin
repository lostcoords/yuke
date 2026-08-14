#+build !windows
package js

import "core:fmt"
import "core:nbio"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"

import "libs:testsupport"

@(test)
test_exec_reports_both_streams_and_the_code :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    // A shell line, not an argument vector: the redirection below is the point of that choice.
    source := `
        import { exec } from "yuke:exec"
        globalThis.result = "pending"
        exec("echo out; echo err 1>&2; exit 3", { cwd: root }).then(
            r => { globalThis.result = [r.stdout.trim(), r.stderr.trim(), r.code, r.timedOut].join(":") },
            e => { globalThis.result = "rejected: " + e },
        )
    `

    testing.expect_value(t, module_run(t, "js-exec", source), "out:err:3:false")
}

@(test)
test_exec_stops_at_its_deadline :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    source := `
        import { exec } from "yuke:exec"
        globalThis.result = "pending"
        exec("sleep 5", { timeoutMs: 250 }).then(
            r => { globalThis.result = "" + r.timedOut },
            e => { globalThis.result = "rejected: " + e },
        )
    `

    testing.expect_value(t, module_run(t, "js-exec-timeout", source), "true")
}

@(test)
test_exec_stops_a_command_that_never_goes_quiet :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    source := `
        import { exec } from "yuke:exec"
        globalThis.result = "pending"
        exec("while true; do echo noise; done", { timeoutMs: 250 }).then(
            r => { globalThis.result = "" + r.timedOut },
            e => { globalThis.result = "rejected: " + e },
        )
    `

    testing.expect_value(t, module_run(t, "js-exec-noisy", source), "true")
}

@(test)
test_exec_does_not_block_a_file_read :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    source := `
        import * as fs from "yuke:fs"
        import { exec } from "yuke:exec"
        globalThis.result = "pending"
        const slow = exec("sleep 5", { timeoutMs: 400 })
        fs.writeFile("note.txt", "read me")
            .then(() => fs.readFile("note.txt"))
            .then(v => { globalThis.result = v })
        slow.catch(() => {})
    `

    testing.expect_value(t, module_run(t, "js-exec-parallel", source), "read me")
}

@(test)
test_exec_stops_when_operations_close :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()

    f: Fixture
    fixture_start(t, &f, "js-exec-cancel")

    source := `
        import { exec } from "yuke:exec"
        globalThis.result = "pending"
        exec("sleep 5", { timeoutMs: 600000 }).then(
            r => { globalThis.result = "resolved" },
            e => { globalThis.result = "rejected" },
        )
    `
    testing.expect(t, eval_module(&f.host, "test.js", source, context.temp_allocator), "the module evaluates")
    testing.expect(t, f.host.pending > 0, "the command should still be running")

    started := time.tick_now()
    fixture_stop(t, &f)
    testing.expect(t, time.tick_since(started) < 10 * time.Second, "teardown must not wait out the command")
}

// The regression test for the whole point of the process group. The shell forks the command,
// so a signal to the shell alone leaves the command running. Here the shell backgrounds a
// timer and waits: if only the shell dies, the timer survives and creates the marker.
@(test)
test_exec_kills_the_whole_process_tree :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()

    f: Fixture
    fixture_start(t, &f, "js-exec-tree")

    source := strings.concatenate(
        {
            fmt.tprintf("const root = %q\n", f.dir),
            `
        import { exec } from "yuke:exec"
        globalThis.result = "pending"
        exec("(sleep 1 && touch marker) & wait", { cwd: root, timeoutMs: 200 }).then(
            r => { globalThis.result = "" + r.timedOut },
            e => { globalThis.result = "rejected" },
        )
    `,
        },
        context.temp_allocator,
    )
    testing.expect(t, eval_module(&f.host, "test.js", source, context.temp_allocator), "the module evaluates")
    testsupport.nbio_run_until(t, &f.host, proc(h: ^Host) -> bool {return h.pending == 0}, "host op")

    marker, join_err := filepath.join({f.dir, "marker"}, context.temp_allocator)
    testing.expect(t, join_err == nil, "the marker path joins")

    // Well past the timer, so a survivor has had every chance to write.
    time.sleep(2500 * time.Millisecond)
    testing.expect(t, !os.exists(marker), "a backgrounded child must not outlive the command")

    fixture_stop(t, &f)
}

// A command gets its termination signal before it is killed outright, so it can remove its
// temporary files. The exit code proves the trap ran rather than a kill landing first.
@(test)
test_exec_terminates_before_it_kills :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    source := `
        import { exec } from "yuke:exec"
        globalThis.result = "pending"
        exec("trap 'exit 42' TERM; sleep 30 & wait", { timeoutMs: 200 }).then(
            r => { globalThis.result = r.code + ":" + r.timedOut },
            e => { globalThis.result = "rejected: " + e },
        )
    `

    testing.expect_value(t, module_run(t, "js-exec-term", source), "42:true")
}
