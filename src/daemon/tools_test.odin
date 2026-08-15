package daemon

import "core:nbio"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import "libs:testsupport"

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
