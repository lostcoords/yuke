package daemon

import "base:runtime"
import "core:c"
import "core:log"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "libs:json"

import qjs "libs:bindings/quickjs"
import "libs:offload"
import "src:js"
import "src:provider"

// File name of the daemon script entry, evaluated from the config directory at startup.
JS_ENTRY_FILE :: "yuked.js"

// Bring up the script tier: a config directory that exists installs the shared host modules
// plus `yuke:daemon`. No base — a daemon serves many workspaces, so every script path is absolute.
js_init :: proc(d: ^Daemon, root: string, allocator: mem.Allocator) -> Error {
    assert(d != nil, "js_init needs daemon state")
    assert(offload.pool_is_running(&d.workers), "the script tier offloads onto a running pool")
    assert(offload.pool_is_running(&d.exec_workers), "`yuke:exec` commands offload onto a running pool")

    // `init` copies the list, so a stack array is fine.
    modules: [4]js.Module
    count := 0

    if root != "" && os.is_dir(root) {
        d.config_dir = strings.clone(root, allocator)
        modules[count] = js.fs_module()
        count += 1
        modules[count] = js.exec_module()
        count += 1
        modules[count] = js.diff_module()
        count += 1
        modules[count] = script_module()
        count += 1
    } else if root != "" && os.exists(root) {
        log.errorf("daemon: config dir unusable: %s", root)

        return .Invalid_Options
    }

    options := js.Options {
        modules   = modules[:count],
        pool      = &d.workers,
        exec_pool = &d.exec_workers,
        user      = d,
        report    = js_report,
        on_drain  = js_on_drain,
        allocator = allocator,
    }

    switch js.init(&d.js, options) {
    case .None:
        return .None

    case .Invalid_Root:
        return .Invalid_Options
    }

    return .None
}

// A script fault is an operating outcome here: it is logged and the daemon keeps serving.
// The one exception is the entry script, which `js_run_entry` turns into a start failure.
js_report :: proc(user: rawptr, source: string, text: string) {
    log.errorf("daemon: js %s: %s", source, text)
}

// Evaluate `<root>/yuked.js` when present; a root with no entry is normal, one that raises is a
// start failure. `evaluated` tells a script that forgot `defineConfig` from having no script.
js_run_entry :: proc(d: ^Daemon, allocator: mem.Allocator) -> (evaluated: bool, err: Error) {
    assert(d != nil, "js entry needs daemon state")

    if d.config_dir == "" do return false, .None

    path, _ := filepath.join({d.config_dir, JS_ENTRY_FILE}, allocator)
    defer delete(path, allocator)

    source, read_err := os.read_entire_file(path, allocator)
    defer delete(source, allocator)
    if read_err != nil {
        if read_err == .Not_Exist do return false, .None

        log.errorf("daemon: cannot read script entry %s: %v", path, read_err)
        return false, .Script_Failed
    }

    evaluated_ok := js.eval_module(&d.js, JS_ENTRY_FILE, string(source), allocator)

    if !evaluated_ok do return false, .Script_Failed

    log.infof("daemon: evaluated %s", path)

    return true, .None
}

// Well-known port a launcher binds when the operator configures none, so the web client can probe
// for a local daemon. Applied by the launcher, not `start` (which keeps 0 meaning OS-assigned).
DEFAULT_PORT :: 9853

// The config object `yuked.js` hands to `defineConfig`, camelCase to match the JS surface. Every
// absent member defaults in `start`, and a script that never calls it leaves `Options` untouched.
Script_Config :: struct {
    // Dotted IPv4 bind address. Empty binds the front door's `127.0.0.1`.
    host:            string `json:"host"`,

    // TCP port for `/ws` and `/blob`. Zero binds an OS-assigned port.
    port:            int `json:"port"`,

    // Base directory for the event-log database (`yuked.db`) and blob store (`blobs/`). Empty
    // uses the platform data directory.
    data_dir:        string `json:"dataDir"`,

    // Bearer token; at least 32 bytes when set. Empty disables authorization.
    auth_token:      string `json:"authToken"`,

    // One of `debug`, `info`, `warn`, `error`. Empty means `info`.
    log_level:       string `json:"logLevel"`,

    // Control-plane base URL the relay exchanges the device credential for link tickets at.
    // Empty means the hosted default (`start` fills it in).
    relay_cloud_url: string `json:"relayCloudUrl"`,

    // Browser origins the front door admits, each a full `scheme://host[:port]`. Empty admits none.
    allowed_origins: []string `json:"allowedOrigins"`,
}

// Decode the JSON captured from `defineConfig`. A malformed value or an unknown member fails
// the start rather than taking half of it.
config_decode :: proc(text: string, allocator := context.allocator) -> (config: Script_Config, ok: bool) {
    parse_arena: mem.Dynamic_Arena
    mem.dynamic_arena_init(&parse_arena, runtime.heap_allocator(), runtime.heap_allocator())
    defer mem.dynamic_arena_destroy(&parse_arena)

    value, parse_err := json.parse(text, .JSON, true, mem.dynamic_arena_allocator(&parse_arena))
    if parse_err != nil do return {}, false

    object, is_object := value.(json.Object)
    if !is_object do return {}, false

    for name in object {
        switch name {
        case "host", "port", "dataDir", "authToken", "logLevel", "relayCloudUrl", "allowedOrigins":
        case:
            return {}, false
        }
    }

    if json.unmarshal(transmute([]byte)text, &config, .JSON, allocator) != nil do return {}, false

    return config, true
}

// Map the configured level name to the console logger's, defaulting an empty or unrecognized
// one to `info` — a bad level should not stop a daemon, so an unknown one is warned and falls back.
config_log_level :: proc(name: string) -> log.Level {
    switch name {
    case "", "info":
        return .Info

    case "debug":
        return .Debug

    case "warn":
        return .Warning

    case "error":
        return .Error
    }

    log.warnf("daemon: unknown logLevel %q in yuked.js, using info", name)

    return .Info
}

// Daemon-only script registrations installed beside the shared host modules when a root exists.
SCRIPT_MODULE :: "yuke:daemon"

@(rodata)
SCRIPT_EXPORTS := []string{"defineConfig", "defineTool"}

script_module :: proc() -> js.Module {
    return {name = SCRIPT_MODULE, init = script_module_init, exports = SCRIPT_EXPORTS}
}

script_module_init :: proc "c" (ctx: ^qjs.Context, m: ^qjs.Module_Def) -> c.int {
    context = runtime.default_context()

    config_fn := qjs.new_function(ctx, define_config, "defineConfig", 1)

    if !qjs.set_module_export(ctx, m, "defineConfig", config_fn) do return -1

    tool_fn := qjs.new_function(ctx, define_tool, "defineTool", 2)

    if !qjs.set_module_export(ctx, m, "defineTool", tool_fn) do return -1

    return 0
}

// `defineConfig(config)` — capture the config for `start` to decode, returning it so
// `export default defineConfig({...})` reads naturally. A second call or a non-object throws.
@(private = "file")
define_config :: proc "c" (ctx: ^qjs.Context, this: qjs.Value, argc: c.int, argv: [^]qjs.Value) -> qjs.Value {
    context = runtime.default_context()

    d := (^Daemon)(js.user_of(ctx))
    if d == nil do return qjs.throw_type_error(ctx, "defineConfig has no daemon")

    if argc < 1 || !qjs.is_object(argv[0]) do return qjs.throw_type_error(ctx, "defineConfig expects a config object")

    if d.config_seen do return qjs.throw_type_error(ctx, "defineConfig was called more than once")

    encoded := qjs.json_stringify(ctx, argv[0])
    if qjs.is_exception(encoded) do return encoded

    defer qjs.free_value(ctx, encoded)

    text, readable := qjs.to_string(ctx, encoded)
    if !readable do return qjs.throw_type_error(ctx, "defineConfig could not serialize its config")

    defer qjs.free_string(ctx, text)

    cloned, clone_err := strings.clone(text, d.allocator)
    if clone_err != nil do return qjs.throw_type_error(ctx, "out of memory")

    d.config_json = cloned
    d.config_seen = true

    return qjs.dup_value(ctx, argv[0])
}

// Longest tool name the providers accept.
@(private = "file")
TOOL_NAME_MAX :: 64

// One tool `yuked.js` registered. `handler` is a live JS function this daemon owns for the
// script tier's lifetime, so it is released before the context that made it.
Daemon_Tool :: struct {
    name:         string,
    description:  string,
    input_schema: string,
    handler:      qjs.Value,
}

// `defineTool(name, definition)` — register a tool the model may call. A name registered twice
// replaces the first.
define_tool :: proc "c" (ctx: ^qjs.Context, this: qjs.Value, argc: c.int, argv: [^]qjs.Value) -> qjs.Value {
    context = runtime.default_context()

    d := (^Daemon)(js.user_of(ctx))
    if d == nil do return qjs.throw_type_error(ctx, "defineTool has no daemon")

    if argc < 2 || !qjs.is_string(argv[0]) || !qjs.is_object(argv[1]) do return qjs.throw_type_error(ctx, "defineTool expects a name and a definition object")

    tool: Daemon_Tool
    if message := tool_read(ctx, d, argv[0], argv[1], &tool); message != nil {
        tool_free(ctx, d, &tool)

        return qjs.throw_type_error(ctx, message)
    }

    if !tool_register(d, tool) {
        tool_free(ctx, d, &tool)

        return qjs.throw_type_error(ctx, "out of memory")
    }

    return qjs.dup_value(ctx, argv[1])
}

// Fill `out` from the definition. A non-nil result is the message to throw, and `out` may be
// half-built, so the caller releases it either way.
@(private = "file")
tool_read :: proc(
    ctx: ^qjs.Context,
    d: ^Daemon,
    name_value: qjs.Value,
    spec: qjs.Value,
    out: ^Daemon_Tool,
) -> cstring {
    name, name_ok := tool_own_string(ctx, d, name_value, &out.name)
    if !name_ok do return name

    if !tool_name_valid(out.name) do return "defineTool expects a name of 1 to 64 characters from [A-Za-z0-9_-]"

    description := qjs.get_property(ctx, spec, "description")
    defer qjs.free_value(ctx, description)

    if !qjs.is_string(description) do return "defineTool expects a description string"

    if message, ok := tool_own_string(ctx, d, description, &out.description); !ok do return message

    if out.description == "" do return "defineTool expects a non-empty description"

    handler := qjs.get_property(ctx, spec, "handler")
    if !qjs.is_function(ctx, handler) {
        qjs.free_value(ctx, handler)

        return "defineTool expects a handler function"
    }

    // Owned from here: the run path calls it long after this entry returns.
    out.handler = handler

    params := qjs.get_property(ctx, spec, "params")
    defer qjs.free_value(ctx, params)

    if !qjs.is_undefined(params) && !qjs.is_null(params) && !qjs.is_object(params) do return "defineTool expects params to be an object"

    return tool_schema_read(ctx, d, params, &out.input_schema)
}

// Serialize the sugar and compile it. Going through JSON rather than enumerating the object
// keeps this on the same path `defineConfig` already uses to move a script value into Odin.
@(private = "file")
tool_schema_read :: proc(ctx: ^qjs.Context, d: ^Daemon, params: qjs.Value, out: ^string) -> cstring {
    if qjs.is_undefined(params) || qjs.is_null(params) {
        schema, err := strings.clone(TOOL_SCHEMA_EMPTY, d.allocator)
        if err != nil do return "out of memory"

        out^ = schema

        return nil
    }

    encoded := qjs.json_stringify(ctx, params)
    if qjs.is_exception(encoded) do return "defineTool could not serialize its params"

    defer qjs.free_value(ctx, encoded)

    text, readable := qjs.to_string(ctx, encoded)
    if !readable do return "defineTool could not serialize its params"

    defer qjs.free_string(ctx, text)

    schema, ok := tool_schema_compile(text, d.allocator)
    if !ok {
        return(
            "defineTool expects each param to be \"string\", \"integer\", \"number\", or \"boolean\", with an optional trailing ?" \
        )
    }

    out^ = schema

    return nil
}

@(private = "file")
TOOL_SCHEMA_EMPTY :: `{"type":"object","properties":{},"additionalProperties":false}`

// Compile the params sugar to JSON Schema: `required` names every field without a trailing `?`.
// Fields are emitted sorted, and names are identifier-only, so the schema needs no escaping.
tool_schema_compile :: proc(params_json: string, allocator: mem.Allocator) -> (string, bool) {
    parse_arena: mem.Dynamic_Arena
    mem.dynamic_arena_init(&parse_arena, runtime.heap_allocator(), runtime.heap_allocator())

    defer mem.dynamic_arena_destroy(&parse_arena)

    scratch := mem.dynamic_arena_allocator(&parse_arena)

    value, parse_err := json.parse(params_json, .JSON, true, scratch)
    if parse_err != nil do return "", false

    object, is_object := value.(json.Object)
    if !is_object do return "", false

    names, names_err := make([dynamic]string, 0, len(object), scratch)
    if names_err != nil do return "", false

    for name in object {
        if !tool_param_name_valid(name) do return "", false

        append(&names, name)
    }

    slice.sort(names[:])

    // Built in the scratch arena and cloned out at the end, so a failure partway needs no
    // cleanup of its own.
    out: strings.Builder
    strings.builder_init(&out, 0, 0, scratch)

    strings.write_string(&out, `{"type":"object","properties":{`)

    for name, index in names {
        declared, is_string := object[name].(json.String)
        if !is_string do return "", false

        keyword, keyword_ok := tool_param_keyword(string(declared))
        if !keyword_ok do return "", false

        if index > 0 do strings.write_byte(&out, ',')

        strings.write_byte(&out, '"')
        strings.write_string(&out, name)
        strings.write_string(&out, `":{"type":"`)
        strings.write_string(&out, keyword)
        strings.write_string(&out, `"}`)
    }

    strings.write_string(&out, `},"required":[`)

    required := 0

    for name in names {
        declared := string(object[name].(json.String))
        if strings.has_suffix(declared, "?") do continue

        if required > 0 do strings.write_byte(&out, ',')

        strings.write_byte(&out, '"')
        strings.write_string(&out, name)
        strings.write_byte(&out, '"')
        required += 1
    }

    strings.write_string(&out, `],"additionalProperties":false}`)

    schema, clone_err := strings.clone(strings.to_string(out), allocator)
    if clone_err != nil do return "", false

    return schema, true
}

// The sugar's closed type set. A trailing `?` marks the field optional and is stripped here.
@(private = "file")
tool_param_keyword :: proc(declared: string) -> (string, bool) {
    base := strings.trim_suffix(declared, "?")

    switch base {
    case "string", "integer", "number", "boolean":
        return base, true
    }

    return "", false
}

@(private = "file")
tool_param_name_valid :: proc(name: string) -> bool {
    if name == "" do return false

    for r, index in name {
        switch {
        case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r == '_':
        case index > 0 && r >= '0' && r <= '9':
        case:
            return false
        }
    }

    return true
}

// What every provider accepts for a tool name.
@(private = "file")
tool_name_valid :: proc(name: string) -> bool {
    if name == "" || len(name) > TOOL_NAME_MAX do return false

    for r in name {
        switch {
        case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9', r == '_', r == '-':
        case:
            return false
        }
    }

    return true
}

@(private = "file")
tool_own_string :: proc(ctx: ^qjs.Context, d: ^Daemon, value: qjs.Value, out: ^string) -> (cstring, bool) {
    text, readable := qjs.to_string(ctx, value)
    if !readable do return "defineTool could not read a string argument", false

    defer qjs.free_string(ctx, text)

    cloned, err := strings.clone(text, d.allocator)
    if err != nil do return "out of memory", false

    out^ = cloned

    return nil, true
}

// Last definition of a name wins, which is what makes a tool overridable.
@(private = "file")
tool_register :: proc(d: ^Daemon, tool: Daemon_Tool) -> bool {
    for &existing, index in d.tools {
        if existing.name == tool.name {
            tool_free(d.js.ctx, d, &existing)
            d.tools[index] = tool

            return true
        }
    }

    _, err := append(&d.tools, tool)

    return err == nil
}

// Definitions for one request, in registration order. Borrows every string from the registry,
// so the result lives only as long as the caller's turn assembly.
tools_definitions :: proc(d: ^Daemon, allocator: mem.Allocator) -> []provider.Tool_Definition {
    assert(d != nil, "tool definitions need daemon state")

    if len(d.tools) == 0 do return nil

    out, err := make([]provider.Tool_Definition, len(d.tools), allocator)
    if err != nil do return nil

    for tool, index in d.tools {
        out[index] = {
            name         = tool.name,
            description  = tool.description,
            input_schema = tool.input_schema,
        }
    }

    return out
}

// The registered tool of that name, or nil. Tools are few, so a scan is the lookup.
tools_find :: proc(d: ^Daemon, name: string) -> ^Daemon_Tool {
    assert(d != nil, "a tool lookup needs daemon state")

    for &tool in d.tools {
        if tool.name == name do return &tool
    }

    return nil
}

// Release every handler before the context that made them is freed.
tools_destroy :: proc(d: ^Daemon) {
    assert(d != nil, "tool teardown needs daemon state")

    for &tool in d.tools {
        tool_free(d.js.ctx, d, &tool)
    }

    delete(d.tools)
    d.tools = nil
}

@(private = "file")
tool_free :: proc(ctx: ^qjs.Context, d: ^Daemon, tool: ^Daemon_Tool) {
    assert(tool != nil, "tool cleanup needs tool state")

    delete(tool.name, d.allocator)
    delete(tool.description, d.allocator)
    delete(tool.input_schema, d.allocator)

    if ctx != nil do qjs.free_value(ctx, tool.handler)

    tool^ = {}
}
