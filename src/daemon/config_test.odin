package daemon

import "core:log"
import "core:nbio"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "libs:testsupport"

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
    err := start(&d, loop, {host = "127.0.0.1", port = 0, js_root = root})
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
    testing.expect_value(t, start(&d, loop, {host = "127.0.0.1", port = 0, js_root = root}), Error.None)
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
    testing.expect_value(t, start(&d, loop, {host = "127.0.0.1", port = 0, js_root = root}), Error.None)
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
    testing.expect_value(t, start(&d, loop, {host = "127.0.0.1", port = 0, js_root = root}), Error.None)
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

// A non-object argument throws at the boundary rather than being coerced, so the start fails.
@(test)
test_define_config_rejects_a_non_object :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    err := entry_start(
        t,
        "cfg-non-object",
        `
            import { defineConfig } from "yuke:daemon"

            defineConfig(42)
        `,
    )

    testing.expect_value(t, err, Error.Script_Failed)
}

// A well-formed call carrying a mistyped value decodes-fails, which is a configuration error
// (not a script fault): the same strictness the file loader enforced, now at the JS boundary.
@(test)
test_define_config_rejects_a_mistyped_value :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    err := entry_start(
        t,
        "cfg-mistyped",
        `
            import { defineConfig } from "yuke:daemon"

            export default defineConfig({ port: "nope" })
        `,
    )

    testing.expect_value(t, err, Error.Invalid_Options)
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
    testing.expect_value(t, start(&d, loop, {host = "127.0.0.1", port = 0, js_root = root}), Error.None)
    defer test_teardown(&d)

    if testing.expect_value(t, len(d.allowed_origins), 2) {
        testing.expect_value(t, d.allowed_origins[0], "http://localhost:5173")
        testing.expect_value(t, d.allowed_origins[1], "https://client.yuke.sh")
    }
}

// A mistyped `allowedOrigins` (a string, not an array) fails the strict decode.
@(test)
test_define_config_rejects_mistyped_allowed_origins :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    err := entry_start(
        t,
        "cfg-origins-mistyped",
        `
            import { defineConfig } from "yuke:daemon"

            export default defineConfig({ allowedOrigins: "nope" })
        `,
    )

    testing.expect_value(t, err, Error.Invalid_Options)
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
    testing.expect_value(t, start(&d, loop, {host = "127.0.0.1", port = PORT, js_root = root}), Error.None)
    defer test_teardown(&d)

    testing.expect_value(t, bound_port(&d), PORT)
}
