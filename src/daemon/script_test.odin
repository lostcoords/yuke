package daemon

import "core:fmt"
import "core:log"
import "core:nbio"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import qjs "libs:bindings/quickjs"
import "libs:testsupport"

import "src:js"

// A 32-byte unreserved token: the minimum `auth_token_valid` accepts, so the manifest can set
// authorization and the test can read it back off the daemon.
@(private = "file")
TEST_TOKEN :: "0123456789abcdef0123456789abcdef"

@(private = "file")
write_entry :: proc(t: ^testing.T, dir: string, source: string) {
    path, join_err := filepath.join({dir, JS_ENTRY_FILE}, context.temp_allocator)
    testing.expect(t, join_err == nil, "the entry path joins")
    testing.expect_value(t, os.write_entire_file(path, transmute([]byte)source), nil)
}

// Start a daemon rooted at a fresh directory holding `source` as `yuked.js`, and return the
// start outcome. Rolls the daemon down on success; a failed start already rolled itself back.
// The logger is silenced because the error cases drive error-level logs the runner fails on.
@(private = "file")
entry_start :: proc(t: ^testing.T, name: string, source: string) -> Error {
    saved_logger := context.logger
    quiet_logger: testsupport.Assert_Only_Logger
    context.logger = testsupport.assert_only_logger(&quiet_logger, saved_logger)
    defer context.logger = saved_logger

    root := test_make_dir(name)
    defer os.remove_all(root)

    write_entry(t, root, source)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    d: Daemon
    err := start(&d, loop, {host = "127.0.0.1", port = 0, config_dir = root})
    if err == .None {
        test_teardown(&d)
    }

    return err
}

// The core of the feature: `export default defineConfig({...})` supersedes the caller's options,
// so the daemon takes host/port/auth_token/log_level straight from `yuked.js`.
@(test)
test_define_config_supersedes_options :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    root := test_make_dir("cfg-supersede")
    defer os.remove_all(root)

    write_entry(
        t,
        root,
        `
            import { defineConfig } from "yuke:daemon"

            export default defineConfig({
                authToken: "` +
        TEST_TOKEN +
        `",
                logLevel: "debug",
            })
        `,
    )

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    d: Daemon
    testing.expect_value(t, start(&d, loop, {host = "127.0.0.1", port = 0, config_dir = root}), Error.None)
    defer test_teardown(&d)

    testing.expect(t, d.config_seen, "defineConfig was recorded")
    testing.expect_value(t, d.auth_token, TEST_TOKEN)
    testing.expect_value(t, d.log_level, log.Level.Debug)
}

// The async path: a manifest may `await` a host op — reading a secret off disk — before it
// defines config. Top-level await settles before the entry is treated as loaded.
@(test)
test_define_config_reads_a_secret_with_top_level_await :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    root := test_make_dir("cfg-async")
    defer os.remove_all(root)

    token_path, join_err := filepath.join({root, "token"}, context.temp_allocator)
    testing.expect(t, join_err == nil, "the token path joins")
    testing.expect_value(t, os.write_entire_file(token_path, transmute([]byte)string(TEST_TOKEN + "\n")), nil)

    // Absolute: the daemon sets no base, so a relative path has no single meaning there.
    // Concatenated rather than interpolated, because `fmt` reads a `{` as a verb.
    entry := strings.concatenate(
        {
            `
            import { defineConfig } from "yuke:daemon"
            import * as fs from "yuke:fs"

            const token = (await fs.readFile("`,
            token_path,
            `")).trim()
            export default defineConfig({ authToken: token })
        `,
        },
        context.temp_allocator,
    )

    write_entry(t, root, entry)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    d: Daemon
    testing.expect_value(t, start(&d, loop, {host = "127.0.0.1", port = 0, config_dir = root}), Error.None)
    defer test_teardown(&d)

    testing.expect_value(t, d.auth_token, TEST_TOKEN)
}

// A manifest that runs but never calls `defineConfig` leaves the caller's options in place and
// starts on defaults, rather than silently dropping a config the operator forgot to register.
@(test)
test_entry_without_define_config_runs_on_defaults :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)
    // The "did not call defineConfig" path warns; keep the runner quiet.
    saved_logger := context.logger
    quiet_logger: testsupport.Assert_Only_Logger
    context.logger = testsupport.assert_only_logger(&quiet_logger, saved_logger)
    defer context.logger = saved_logger

    root := test_make_dir("cfg-none")
    defer os.remove_all(root)

    write_entry(t, root, `globalThis.x = 1`)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    d: Daemon
    testing.expect_value(t, start(&d, loop, {host = "127.0.0.1", port = 0, config_dir = root}), Error.None)
    defer test_teardown(&d)

    testing.expect(t, !d.config_seen, "no defineConfig call was recorded")
    testing.expect_value(t, d.log_level, log.Level.Info)
}

// Pure registration: a second `defineConfig` throws, and the throw fails the entry, which fails
// the start.
@(test)
test_define_config_twice_refuses_the_start :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    err := entry_start(
        t,
        "cfg-twice",
        `
            import { defineConfig } from "yuke:daemon"

            defineConfig({ port: 1 })
            defineConfig({ port: 2 })
        `,
    )

    testing.expect_value(t, err, Error.Script_Failed)
}

@(test)
test_define_config_rejects_an_unknown_member :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    err := entry_start(
        t,
        "cfg-unknown",
        `
            import { defineConfig } from "yuke:daemon"

            export default defineConfig({ prot: 9853 })
        `,
    )

    testing.expect_value(t, err, Error.Invalid_Options)
}

// `allowedOrigins` decodes into the owned string slice, surviving the decode arena as clones.
@(test)
test_define_config_reads_allowed_origins :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    root := test_make_dir("cfg-origins")
    defer os.remove_all(root)

    write_entry(
        t,
        root,
        `
            import { defineConfig } from "yuke:daemon"

            export default defineConfig({
                allowedOrigins: ["http://localhost:5173", "https://client.yuke.sh"],
            })
        `,
    )

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    d: Daemon
    testing.expect_value(t, start(&d, loop, {host = "127.0.0.1", port = 0, config_dir = root}), Error.None)
    defer test_teardown(&d)

    if testing.expect_value(t, len(d.allowed_origins), 2) {
        testing.expect_value(t, d.allowed_origins[0], "http://localhost:5173")
        testing.expect_value(t, d.allowed_origins[1], "https://client.yuke.sh")
    }
}

// A manifest that omits `port` keeps the port the launcher set, rather than resetting to an
// OS-assigned one: a zero from the manifest does not clobber the incoming value.
@(test)
test_define_config_keeps_the_launcher_port :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    root := test_make_dir("cfg-port")
    defer os.remove_all(root)

    write_entry(
        t,
        root,
        `
            import { defineConfig } from "yuke:daemon"

            export default defineConfig({ logLevel: "warn" })
        `,
    )

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    // An arbitrary free port, not DEFAULT_PORT, so the assertion checks retention rather than a
    // coincidental default.
    PORT :: 43219
    d: Daemon
    testing.expect_value(t, start(&d, loop, {host = "127.0.0.1", port = PORT, config_dir = root}), Error.None)
    defer test_teardown(&d)

    testing.expect_value(t, bound_port(&d), PORT)
}

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

// Bring up a daemon whose `yuked.js` is `entry`. `err` says whether the start was expected to
// succeed, since a definition error is a start failure rather than a silent skip.
@(private = "file")
tools_start :: proc(t: ^testing.T, d: ^Daemon, name: string, entry: string, expected: Error) -> string {
    root := test_make_dir(name)

    path, join_err := filepath.join({root, JS_ENTRY_FILE}, context.temp_allocator)
    testing.expect(t, join_err == nil, "the entry path joins")
    testing.expect_value(t, os.write_entire_file(path, transmute([]byte)entry), nil)

    loop := nbio.current_thread_event_loop()
    testing.expect_value(t, start(d, loop, {host = "127.0.0.1", port = 0, config_dir = root}), expected)

    return root
}

@(test)
test_define_tool_registers_a_definition :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()

    entry := `
        import { defineTool } from "yuke:daemon"

        defineTool("read", {
            description: "Read a file",
            params: { path: "string", start: "integer?" },
            handler: async ({ path }) => path,
        })
    `

    d: Daemon
    root := tools_start(t, &d, "tools-define", entry, .None)
    defer os.remove_all(root)
    defer test_teardown(&d)

    if !testing.expect_value(t, len(d.tools), 1) {
        return
    }

    testing.expect_value(t, d.tools[0].name, "read")
    testing.expect_value(t, d.tools[0].description, "Read a file")

    // Sorted, so `path` precedes `start`; only `path` is required.
    expected := `{"type":"object","properties":{"path":{"type":"string"},"start":{"type":"integer"}},"required":["path"],"additionalProperties":false}`
    testing.expect_value(t, d.tools[0].input_schema, expected)

    definitions := tools_definitions(&d, context.temp_allocator)

    if testing.expect_value(t, len(definitions), 1) {
        testing.expect_value(t, definitions[0].name, "read")
        testing.expect_value(t, definitions[0].input_schema, expected)
    }
}

// Last definition of a name wins, which is what makes a baked tool overridable.
@(test)
test_define_tool_replaces_a_name :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()

    entry := `
        import { defineTool } from "yuke:daemon"

        defineTool("read", { description: "first", handler: async () => 1 })
        defineTool("read", { description: "second", handler: async () => 2 })
        defineTool("write", { description: "other", handler: async () => 3 })
    `

    d: Daemon
    root := tools_start(t, &d, "tools-replace", entry, .None)
    defer os.remove_all(root)
    defer test_teardown(&d)

    if !testing.expect_value(t, len(d.tools), 2) {
        return
    }

    testing.expect_value(t, d.tools[0].name, "read")
    testing.expect_value(t, d.tools[0].description, "second")
    testing.expect_value(t, d.tools[1].name, "write")
}

// A tool with no arguments still carries a schema, because the providers require one.
@(test)
test_define_tool_without_params_carries_an_empty_schema :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()

    entry := `
        import { defineTool } from "yuke:daemon"

        defineTool("now", { description: "The current time", handler: async () => Date.now() })
    `

    d: Daemon
    root := tools_start(t, &d, "tools-empty", entry, .None)
    defer os.remove_all(root)
    defer test_teardown(&d)

    if testing.expect_value(t, len(d.tools), 1) {
        expected := `{"type":"object","properties":{},"additionalProperties":false}`
        testing.expect_value(t, d.tools[0].input_schema, expected)
    }
}

// A definition error is a start failure. Finding it on the first turn that would have used
// the tool is worse: by then a person is waiting on a model that cannot answer.
@(test)
test_define_tool_refuses_a_bad_definition :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)
    // Drives an error path on purpose; the runner fails on any error-level log, and this
    // test asserts the outcome instead. nbio callbacks inherit this context.
    saved_logger := context.logger
    quiet_logger: testsupport.Assert_Only_Logger
    context.logger = testsupport.assert_only_logger(&quiet_logger, saved_logger)
    defer context.logger = saved_logger

    Case :: struct {
        name:  string,
        entry: string,
    }

    cases := []Case {
        {"no-handler", `defineTool("a", { description: "d" })`},
        {"handler-not-callable", `defineTool("a", { description: "d", handler: 7 })`},
        {"no-description", `defineTool("a", { handler: async () => 1 })`},
        {"empty-description", `defineTool("a", { description: "", handler: async () => 1 })`},
        {"bad-name", `defineTool("a b", { description: "d", handler: async () => 1 })`},
        {"unknown-param-type", `defineTool("a", { description: "d", params: { x: "date" }, handler: async () => 1 })`},
        {"param-not-a-string", `defineTool("a", { description: "d", params: { x: 3 }, handler: async () => 1 })`},
        {"params-not-an-object", `defineTool("a", { description: "d", params: 3, handler: async () => 1 })`},
    }

    for c in cases {
        nbio.acquire_thread_event_loop()

        entry, entry_err := strings.concatenate(
            {`import { defineTool } from "yuke:daemon"`, "\n", c.entry, "\n"},
            context.temp_allocator,
        )
        testing.expect(t, entry_err == nil, "the entry builds")

        d: Daemon
        root := tools_start(t, &d, c.name, entry, .Script_Failed)
        os.remove_all(root)

        nbio.release_thread_event_loop()
    }
}
