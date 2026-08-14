package daemon

import "base:runtime"
import "core:c"
import "core:strings"

import qjs "libs:bindings/quickjs"
import js "src:js"

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

    if !qjs.set_module_export(ctx, m, "defineConfig", config_fn) {
        return -1
    }

    tool_fn := qjs.new_function(ctx, define_tool, "defineTool", 2)

    if !qjs.set_module_export(ctx, m, "defineTool", tool_fn) {
        return -1
    }

    return 0
}

// `defineConfig(config)` — capture the config object for `start` to decode, and return it so
// `export default defineConfig({...})` reads naturally. Pure registration: a second call or a
// non-object argument throws, and a value JSON cannot represent (cyclic, a throwing `toJSON`)
// surfaces its own exception. The capture is decoded once, after the entry finishes evaluating.
@(private = "file")
define_config :: proc "c" (ctx: ^qjs.Context, this: qjs.Value, argc: c.int, argv: [^]qjs.Value) -> qjs.Value {
    context = runtime.default_context()

    d := (^Daemon)(js.user_of(ctx))
    if d == nil {
        return qjs.throw_type_error(ctx, "defineConfig has no daemon")
    }

    if argc < 1 || !qjs.is_object(argv[0]) {
        return qjs.throw_type_error(ctx, "defineConfig expects a config object")
    }

    if d.config_seen {
        return qjs.throw_type_error(ctx, "defineConfig was called more than once")
    }

    encoded := qjs.json_stringify(ctx, argv[0])
    if qjs.is_exception(encoded) {
        return encoded
    }

    defer qjs.free_value(ctx, encoded)

    text, readable := qjs.to_string(ctx, encoded)
    if !readable {
        return qjs.throw_type_error(ctx, "defineConfig could not serialize its config")
    }

    defer qjs.free_string(ctx, text)

    cloned, clone_err := strings.clone(text, d.allocator)
    if clone_err != nil {
        return qjs.throw_type_error(ctx, "out of memory")
    }

    d.config_json = cloned
    d.config_seen = true

    return qjs.dup_value(ctx, argv[0])
}
