package daemon

import "core:log"
import "core:nbio"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import qjs "libs:bindings/quickjs"
import "libs:testsupport"
import js "src:js"

// A host op answers on a worker thread, so the loop must be pumped before the promise
// settles. A pass that never completes fails on the shared deadline rather than hanging.
@(private = "file")
js_settle :: proc(t: ^testing.T, d: ^Daemon) {
    testsupport.nbio_run_until(t, d, proc(d: ^Daemon) -> bool {return d.js.pending == 0}, "yuke:fs host op")
}

// Scripts report through `globalThis.result`, which is the only channel a test has into the
// runtime: a promise's value is not otherwise reachable from Odin.
@(private = "file")
js_result :: proc(t: ^testing.T, d: ^Daemon) -> string {
    global := qjs.global_object(d.js.ctx)
    defer qjs.free_value(d.js.ctx, global)

    value := qjs.get_property(d.js.ctx, global, "result")
    defer qjs.free_value(d.js.ctx, value)

    text, ok := qjs.to_string(d.js.ctx, value)
    if !testing.expect(t, ok, "globalThis.result should be readable") {
        return ""
    }

    defer qjs.free_string(d.js.ctx, text)

    // The engine owns `text`; clone it out before the frame that borrows it ends.
    return strings.clone(text, context.temp_allocator)
}

// A file laid down in the script root before the daemon starts.
@(private = "file")
Js_Fixture :: struct {
    name:     string,
    contents: string,
}

@(private = "file")
js_write :: proc(t: ^testing.T, dir: string, name: string, contents: string) {
    path, join_err := filepath.join({dir, name}, context.temp_allocator)
    testing.expect(t, join_err == nil, "the fixture path joins")
    testing.expect_value(t, os.write_entire_file(path, transmute([]byte)contents), nil)
}

// Bring up a daemon rooted at a fresh directory, run `source`, and settle whatever it
// started. Returns whatever the script left in `globalThis.result`.
@(private = "file")
js_run :: proc(t: ^testing.T, name: string, source: string, files: []Js_Fixture) -> string {
    root := test_make_dir(name)
    defer os.remove_all(root)

    for file in files {
        js_write(t, root, file.name, file.contents)
    }

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    d: Daemon
    testing.expect_value(t, start(&d, loop, {host = "127.0.0.1", port = 0, js_root = root}), Error.None)
    defer test_teardown(&d)

    testing.expect(t, js.eval_module(&d.js, "test.js", source, context.temp_allocator), "the test module evaluates")
    js_settle(t, &d)

    return js_result(t, &d)
}

// The bridge end to end: a script calls a host op, the pass runs off the reactor, and the
// promise settles with what it found.
@(test)
test_js_fs_read_file_resolves_with_contents :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    files := []Js_Fixture{{"note.txt", "from the root"}}

    source := `
        import { fs } from "yuke:fs"
        globalThis.result = "pending"
        fs.readFile("note.txt").then(v => { globalThis.result = v }, e => { globalThis.result = "rejected: " + e })
    `

    testing.expect_value(t, js_run(t, "js-read-file", source, files), "from the root")
}

// Containment is the whole security property of the module today. `..` is resolved before
// the prefix test, so climbing out rejects rather than reading.
@(test)
test_js_fs_rejects_a_path_outside_the_root :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    files: []Js_Fixture

    source := `
        import { fs } from "yuke:fs"
        globalThis.result = "pending"
        fs.readFile("../../../../etc/hosts").then(
            v => { globalThis.result = "resolved" },
            e => { globalThis.result = "rejected" },
        )
    `

    testing.expect_value(t, js_run(t, "js-escape", source, files), "rejected")
}

// An absolute path is joined under the root rather than honored, so it cannot name a file
// the root does not contain.
@(test)
test_js_fs_rejects_an_absolute_path :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    files: []Js_Fixture

    source := `
        import { fs } from "yuke:fs"
        globalThis.result = "pending"
        fs.readFile("/etc/hosts").then(v => { globalThis.result = "resolved" }, e => { globalThis.result = "rejected" })
    `

    testing.expect_value(t, js_run(t, "js-absolute", source, files), "rejected")
}

// A missing file is an operating outcome: it rejects the promise instead of throwing out of
// the host function or faulting the daemon.
@(test)
test_js_fs_rejects_a_missing_file :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    files: []Js_Fixture

    source := `
        import { fs } from "yuke:fs"
        globalThis.result = "pending"
        fs.readFile("absent.txt").then(v => { globalThis.result = "resolved" }, e => { globalThis.result = "rejected" })
    `

    testing.expect_value(t, js_run(t, "js-missing", source, files), "rejected")
}

@(test)
test_js_fs_stat_reports_kind_and_size :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    files := []Js_Fixture{{"note.txt", "12345"}}

    source := `
        import { fs } from "yuke:fs"
        globalThis.result = "pending"
        fs.stat("note.txt").then(
            s => { globalThis.result = s.name + ":" + s.size + ":" + s.isFile + ":" + s.isDirectory },
            e => { globalThis.result = "rejected" },
        )
    `

    testing.expect_value(t, js_run(t, "js-stat", source, files), "note.txt:5:true:false")
}

@(test)
test_js_fs_read_dir_lists_entries :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    files := []Js_Fixture{{"a.txt", "a"}, {"b.txt", "b"}}

    // Sorted in JS: `readDir` reports what the filesystem returned, in its order.
    source := `
        import { fs } from "yuke:fs"
        globalThis.result = "pending"
        fs.readDir(".").then(
            entries => { globalThis.result = entries.map(e => e.name).sort().join(",") },
            e => { globalThis.result = "rejected: " + e },
        )
    `

    testing.expect_value(t, js_run(t, "js-read-dir", source, files), "a.txt,b.txt")
}

// Several calls in flight at once: the pool answers each independently and every promise
// settles, which is what "parallel tool calls are concurrent promises" reduces to here.
@(test)
test_js_fs_settles_concurrent_calls :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    files := []Js_Fixture{{"a.txt", "a"}, {"b.txt", "b"}, {"c.txt", "c"}}

    source := `
        import { fs } from "yuke:fs"
        globalThis.result = "pending"
        Promise.all([fs.readFile("a.txt"), fs.readFile("b.txt"), fs.readFile("c.txt")]).then(
            v => { globalThis.result = v.join("") },
            e => { globalThis.result = "rejected: " + e },
        )
    `

    testing.expect_value(t, js_run(t, "js-concurrent", source, files), "abc")
}

// Top-level await of yuke:fs finishes inside eval_module (loop pumped until the module
// promise settles), so globalThis.result is set before the caller continues.
@(test)
test_js_top_level_await_fs :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    files := []Js_Fixture{{"note.txt", "tla-ok"}}

    source := `
        import { fs } from "yuke:fs"
        globalThis.result = await fs.readFile("note.txt")
    `

    testing.expect_value(t, js_run(t, "js-tla-fs", source, files), "tla-ok")
}

// yuked.js may top-level-await host I/O at startup; start fails only if evaluation fails.
@(test)
test_js_entry_top_level_await_fs :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    root := test_make_dir("js-entry-tla")
    defer os.remove_all(root)

    js_write(t, root, "note.txt", "entry-tla")
    js_write(
        t,
        root,
        JS_ENTRY_FILE,
        `
            import { fs } from "yuke:fs"
            globalThis.result = await fs.readFile("note.txt")
        `,
    )

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    d: Daemon
    testing.expect_value(t, start(&d, loop, {host = "127.0.0.1", port = 0, js_root = root}), Error.None)
    defer test_teardown(&d)

    testing.expect_value(t, js_result(t, &d), "entry-tla")
}

// The module set is closed: an unknown specifier is a script error, and the daemon never
// goes looking for it on disk.
@(test)
test_js_unknown_module_is_refused :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)
    // Drives an error path on purpose; the runner fails on any error-level log, and this
    // test asserts the outcome instead. nbio callbacks inherit this context.
    context.logger = log.nil_logger()

    root := test_make_dir("js-unknown-module")
    defer os.remove_all(root)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    d: Daemon
    testing.expect_value(t, start(&d, loop, {host = "127.0.0.1", port = 0, js_root = root}), Error.None)
    defer test_teardown(&d)

    evaluated := js.eval_module(&d.js, "test.js", `import "yuke:nope"`, context.temp_allocator)
    testing.expect(t, !evaluated, "an unknown module should fail to evaluate")
}

// `yuked.js` is the script tier's production entry point. A root that has one runs it at
// startup, before the transport adopts anything.
@(test)
test_js_entry_script_runs_at_startup :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)
    testing.expect_value(t, JS_ENTRY_FILE, "yuked.js")

    root := test_make_dir("js-entry")
    defer os.remove_all(root)

    js_write(t, root, JS_ENTRY_FILE, `globalThis.result = "booted"`)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    d: Daemon
    testing.expect_value(t, start(&d, loop, {host = "127.0.0.1", port = 0, js_root = root}), Error.None)
    defer test_teardown(&d)

    testing.expect_value(t, js_result(t, &d), "booted")
}

// A script tier the operator configured but that will not load is a start failure, for the
// same reason an unusable blob directory is one.
@(test)
test_js_entry_script_failure_refuses_the_start :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)
    // Drives an error path on purpose; the runner fails on any error-level log, and this
    // test asserts the outcome instead. nbio callbacks inherit this context.
    context.logger = log.nil_logger()

    root := test_make_dir("js-entry-broken")
    defer os.remove_all(root)

    js_write(t, root, JS_ENTRY_FILE, `throw new Error("no")`)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    d: Daemon
    testing.expect_value(t, start(&d, loop, {host = "127.0.0.1", port = 0, js_root = root}), Error.Script_Failed)
}

// A root with no entry script is the ordinary case and starts clean.
@(test)
test_js_root_without_an_entry_script_starts :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    root := test_make_dir("js-no-entry")
    defer os.remove_all(root)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    d: Daemon
    testing.expect_value(t, start(&d, loop, {host = "127.0.0.1", port = 0, js_root = root}), Error.None)
    defer test_teardown(&d)

    testing.expect(t, d.js.ctx != nil, "a configured root brings up the runtime")
}

// Without a root there is nothing to contain paths against, so the module refuses to load
// rather than reaching an unbounded filesystem. The runtime itself still comes up.
@(test)
test_js_fs_is_unavailable_without_a_root :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)
    // Drives an error path on purpose; the runner fails on any error-level log, and this
    // test asserts the outcome instead. nbio callbacks inherit this context.
    context.logger = log.nil_logger()

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    d: Daemon
    testing.expect_value(t, start(&d, loop, {host = "127.0.0.1", port = 0}), Error.None)
    defer test_teardown(&d)

    testing.expect(t, d.js.ctx != nil, "the runtime comes up without a root")

    evaluated := js.eval_module(&d.js, "test.js", `import { fs } from "yuke:fs"`, context.temp_allocator)
    testing.expect(t, !evaluated, "yuke:fs should be unavailable without a root")
}

// A configured root that is not a directory is refused at startup rather than making every
// later containment check fail as if it were a permission error.
@(test)
test_js_root_must_be_a_directory :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)
    // Drives an error path on purpose; the runner fails on any error-level log, and this
    // test asserts the outcome instead. nbio callbacks inherit this context.
    context.logger = log.nil_logger()

    dir := test_make_dir("js-root-file")
    defer os.remove_all(dir)

    js_write(t, dir, "not-a-dir", "x")

    path, join_err := filepath.join({dir, "not-a-dir"}, context.temp_allocator)
    testing.expect(t, join_err == nil, "the fixture path joins")

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    d: Daemon
    testing.expect_value(t, start(&d, loop, {host = "127.0.0.1", port = 0, js_root = path}), Error.Invalid_Options)
}

// The teardown order `destroy` depends on: a host op still in flight is drained before its
// completion settles a promise in the context, or this would be a use-after-free.
@(test)
test_js_fs_job_in_flight_survives_shutdown :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    root := test_make_dir("js-inflight")
    defer os.remove_all(root)

    js_write(t, root, "note.txt", "x")

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    d: Daemon
    testing.expect_value(t, start(&d, loop, {host = "127.0.0.1", port = 0, js_root = root}), Error.None)

    source := `
        import { fs } from "yuke:fs"
        globalThis.result = "pending"
        fs.readFile("note.txt").then(v => { globalThis.result = v }, e => { globalThis.result = "rejected" })
    `
    testing.expect(t, js.eval_module(&d.js, "test.js", source, context.temp_allocator), "the module evaluates")

    // Deliberately not settled: teardown has to drain it.
    testing.expect(t, d.js.pending > 0, "the host op should still be in flight")

    test_teardown(&d)
}
