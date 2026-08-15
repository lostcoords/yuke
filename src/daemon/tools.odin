package daemon

import "base:runtime"
import "core:c"
import "core:encoding/json"
import "core:mem"
import "core:slice"
import "core:strings"

import qjs "libs:bindings/quickjs"
import js "src:js"
import provider "src:provider"

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

// `defineTool(name, definition)` — register a tool the model may call, returning the definition so
// `export default defineTool(...)` reads naturally. A repeat name replaces the first.
define_tool :: proc "c" (ctx: ^qjs.Context, this: qjs.Value, argc: c.int, argv: [^]qjs.Value) -> qjs.Value {
    context = runtime.default_context()

    d := (^Daemon)(js.user_of(ctx))
    if d == nil {
        return qjs.throw_type_error(ctx, "defineTool has no daemon")
    }

    if argc < 2 || !qjs.is_string(argv[0]) || !qjs.is_object(argv[1]) {
        return qjs.throw_type_error(ctx, "defineTool expects a name and a definition object")
    }

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
    if !name_ok {
        return name
    }

    if !tool_name_valid(out.name) {
        return "defineTool expects a name of 1 to 64 characters from [A-Za-z0-9_-]"
    }

    description := qjs.get_property(ctx, spec, "description")
    defer qjs.free_value(ctx, description)

    if !qjs.is_string(description) {
        return "defineTool expects a description string"
    }

    if message, ok := tool_own_string(ctx, d, description, &out.description); !ok {
        return message
    }

    if out.description == "" {
        return "defineTool expects a non-empty description"
    }

    handler := qjs.get_property(ctx, spec, "handler")
    if !qjs.is_function(ctx, handler) {
        qjs.free_value(ctx, handler)

        return "defineTool expects a handler function"
    }

    // Owned from here: the run path calls it long after this entry returns.
    out.handler = handler

    params := qjs.get_property(ctx, spec, "params")
    defer qjs.free_value(ctx, params)

    if !qjs.is_undefined(params) && !qjs.is_null(params) && !qjs.is_object(params) {
        return "defineTool expects params to be an object"
    }

    return tool_schema_read(ctx, d, params, &out.input_schema)
}

// Serialize the sugar and compile it. Going through JSON rather than enumerating the object
// keeps this on the same path `defineConfig` already uses to move a script value into Odin.
@(private = "file")
tool_schema_read :: proc(ctx: ^qjs.Context, d: ^Daemon, params: qjs.Value, out: ^string) -> cstring {
    if qjs.is_undefined(params) || qjs.is_null(params) {
        schema, err := strings.clone(TOOL_SCHEMA_EMPTY, d.allocator)
        if err != nil {
            return "out of memory"
        }

        out^ = schema

        return nil
    }

    encoded := qjs.json_stringify(ctx, params)
    if qjs.is_exception(encoded) {
        return "defineTool could not serialize its params"
    }

    defer qjs.free_value(ctx, encoded)

    text, readable := qjs.to_string(ctx, encoded)
    if !readable {
        return "defineTool could not serialize its params"
    }

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
    if parse_err != nil {
        return "", false
    }

    object, is_object := value.(json.Object)
    if !is_object {
        return "", false
    }

    names, names_err := make([dynamic]string, 0, len(object), scratch)
    if names_err != nil {
        return "", false
    }

    for name in object {
        if !tool_param_name_valid(name) {
            return "", false
        }

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
        if !is_string {
            return "", false
        }

        keyword, keyword_ok := tool_param_keyword(string(declared))
        if !keyword_ok {
            return "", false
        }

        if index > 0 {
            strings.write_byte(&out, ',')
        }

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
        if strings.has_suffix(declared, "?") {
            continue
        }

        if required > 0 {
            strings.write_byte(&out, ',')
        }

        strings.write_byte(&out, '"')
        strings.write_string(&out, name)
        strings.write_byte(&out, '"')
        required += 1
    }

    strings.write_string(&out, `],"additionalProperties":false}`)

    schema, clone_err := strings.clone(strings.to_string(out), allocator)
    if clone_err != nil {
        return "", false
    }

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
    if name == "" {
        return false
    }

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
    if name == "" || len(name) > TOOL_NAME_MAX {
        return false
    }

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
    if !readable {
        return "defineTool could not read a string argument", false
    }

    defer qjs.free_string(ctx, text)

    cloned, err := strings.clone(text, d.allocator)
    if err != nil {
        return "out of memory", false
    }

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

    if len(d.tools) == 0 {
        return nil
    }

    out, err := make([]provider.Tool_Definition, len(d.tools), allocator)
    if err != nil {
        return nil
    }

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
        if tool.name == name {
            return &tool
        }
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

    if ctx != nil {
        qjs.free_value(ctx, tool.handler)
    }

    tool^ = {}
}
