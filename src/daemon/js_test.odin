package daemon

import "core:fmt"
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
    testing.expect_value(t, start(&d, loop, {host = "127.0.0.1", port = 0, config_dir = root}), Error.None)
    defer test_teardown(&d)

    // Prepended rather than interpolated: `fmt` reads a `{` in the source as a verb.
    module := strings.concatenate({fmt.tprintf("const root = %q\n", root), source}, context.temp_allocator)
    testing.expect(t, js.eval_module(&d.js, "test.js", module, context.temp_allocator), "the test module evaluates")
    js_settle(t, &d)

    return js_result(t, &d)
}

// The daemon installs the shared host modules and sets no base, so a script names files by
// absolute path. This covers the module set; `src/js` owns the behavior of each module.
@(test)
test_js_installs_the_shared_host_modules :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    files := []Js_Fixture{{"note.txt", "installed"}}

    source := `
        import * as fs from "yuke:fs"
        import { exec } from "yuke:exec"
        import { diff } from "yuke:diff"
        globalThis.result = "pending"
        let relative = "accepted"
        try { fs.exists("note.txt") } catch (e) { relative = "threw" }
        Promise.all([
            fs.readFile(root + "/note.txt"),
            exec("echo ran", { cwd: root }),
            diff("a.txt", "", "x\n"),
        ]).then(
            ([text, r, d]) => { globalThis.result = [text, r.stdout.trim(), d.hunks.length, relative].join(":") },
            e => { globalThis.result = "rejected: " + e },
        )
    `

    testing.expect_value(t, js_run(t, "js-modules", source, files), "installed:ran:1:threw")
}


// yuked.js may top-level-await host I/O at startup; start fails only if evaluation fails.
@(test)
test_js_entry_top_level_await_fs :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    root := test_make_dir("js-entry-tla")
    defer os.remove_all(root)

    js_write(t, root, "note.txt", "entry-tla")

    note, join_err := filepath.join({root, "note.txt"}, context.temp_allocator)
    testing.expect(t, join_err == nil, "the fixture path joins")
    js_write(
        t,
        root,
        JS_ENTRY_FILE,
        fmt.tprintf("import * as fs from \"yuke:fs\"\nglobalThis.result = await fs.readFile(%q)\n", note),
    )

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    d: Daemon
    testing.expect_value(t, start(&d, loop, {host = "127.0.0.1", port = 0, config_dir = root}), Error.None)
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
    saved_logger := context.logger
    quiet_logger: testsupport.Assert_Only_Logger
    context.logger = testsupport.assert_only_logger(&quiet_logger, saved_logger)
    defer context.logger = saved_logger

    root := test_make_dir("js-unknown-module")
    defer os.remove_all(root)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    d: Daemon
    testing.expect_value(t, start(&d, loop, {host = "127.0.0.1", port = 0, config_dir = root}), Error.None)
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
    testing.expect_value(t, start(&d, loop, {host = "127.0.0.1", port = 0, config_dir = root}), Error.None)
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
    saved_logger := context.logger
    quiet_logger: testsupport.Assert_Only_Logger
    context.logger = testsupport.assert_only_logger(&quiet_logger, saved_logger)
    defer context.logger = saved_logger

    root := test_make_dir("js-entry-broken")
    defer os.remove_all(root)

    js_write(t, root, JS_ENTRY_FILE, `throw new Error("no")`)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    d: Daemon
    testing.expect_value(t, start(&d, loop, {host = "127.0.0.1", port = 0, config_dir = root}), Error.Script_Failed)
}

// A root with no entry script is the ordinary case and starts clean.
@(test)
test_config_dir_without_an_entry_script_starts :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    root := test_make_dir("js-no-entry")
    defer os.remove_all(root)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    d: Daemon
    testing.expect_value(t, start(&d, loop, {host = "127.0.0.1", port = 0, config_dir = root}), Error.None)
    defer test_teardown(&d)

    testing.expect(t, d.js.ctx != nil, "a configured root brings up the runtime")
}

@(test)
test_js_unreadable_entry_refuses_the_start :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)
    saved_logger := context.logger
    quiet_logger: testsupport.Assert_Only_Logger
    context.logger = testsupport.assert_only_logger(&quiet_logger, saved_logger)
    defer context.logger = saved_logger

    root := test_make_dir("js-entry-unreadable")
    defer os.remove_all(root)

    entry, _ := os.join_path({root, JS_ENTRY_FILE}, context.temp_allocator)
    testing.expect(t, os.make_directory(entry) == nil, "create an unreadable entry shape")

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    d: Daemon
    testing.expect_value(t, start(&d, loop, {host = "127.0.0.1", port = 0, config_dir = root}), Error.Script_Failed)
}

// An empty config dir (the test-build default) installs no host modules. The runtime still
// comes up.
@(test)
test_js_fs_is_unavailable_without_a_root :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)
    // Drives an error path on purpose; the runner fails on any error-level log, and this
    // test asserts the outcome instead. nbio callbacks inherit this context.
    saved_logger := context.logger
    quiet_logger: testsupport.Assert_Only_Logger
    context.logger = testsupport.assert_only_logger(&quiet_logger, saved_logger)
    defer context.logger = saved_logger

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    d: Daemon
    testing.expect_value(t, start(&d, loop, {host = "127.0.0.1", port = 0}), Error.None)
    defer test_teardown(&d)

    testing.expect(t, d.js.ctx != nil, "the runtime comes up without a root")

    evaluated := js.eval_module(&d.js, "test.js", `import * as fs from "yuke:fs"`, context.temp_allocator)
    testing.expect(t, !evaluated, "the host modules should be unavailable without a root")
}

// A config path that exists and is not a directory is refused at startup.
@(test)
test_config_dir_must_be_a_directory :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)
    // Drives an error path on purpose; the runner fails on any error-level log, and this
    // test asserts the outcome instead. nbio callbacks inherit this context.
    saved_logger := context.logger
    quiet_logger: testsupport.Assert_Only_Logger
    context.logger = testsupport.assert_only_logger(&quiet_logger, saved_logger)
    defer context.logger = saved_logger

    dir := test_make_dir("js-root-file")
    defer os.remove_all(dir)

    js_write(t, dir, "not-a-dir", "x")

    path, join_err := filepath.join({dir, "not-a-dir"}, context.temp_allocator)
    testing.expect(t, join_err == nil, "the fixture path joins")

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    d: Daemon
    testing.expect_value(t, start(&d, loop, {host = "127.0.0.1", port = 0, config_dir = path}), Error.Invalid_Options)
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
    testing.expect_value(t, start(&d, loop, {host = "127.0.0.1", port = 0, config_dir = root}), Error.None)

    note, join_err := filepath.join({root, "note.txt"}, context.temp_allocator)
    testing.expect(t, join_err == nil, "the fixture path joins")
    source := fmt.tprintf(
        "import * as fs from \"yuke:fs\"\nglobalThis.result = \"pending\"\nfs.readFile(%q).then(v => globalThis.result = v)\n",
        note,
    )
    testing.expect(t, js.eval_module(&d.js, "test.js", source, context.temp_allocator), "the module evaluates")

    // Deliberately not settled: teardown has to drain it.
    testing.expect(t, d.js.pending > 0, "the host op should still be in flight")

    test_teardown(&d)
}
