package daemon

import "base:runtime"
import "core:c"
import "core:strings"

import qjs "libs:bindings/quickjs"
import js "src:js"

// The daemon's own script module `yuke:daemon`: `defineConfig`, so `yuked.js` supplies host/
// port/db/blob/auth_token/log_level as JavaScript. Installed beside `yuke:fs` when a root exists.
CONFIG_MODULE :: "yuke:daemon"

@(rodata)
CONFIG_EXPORTS := []string{"defineConfig"}

config_module :: proc() -> js.Module {
    return {name = CONFIG_MODULE, init = config_module_init, exports = CONFIG_EXPORTS}
}

config_module_init :: proc "c" (ctx: ^qjs.Context, m: ^qjs.Module_Def) -> c.int {
    context = runtime.default_context()

    fn := qjs.new_function(ctx, define_config, "defineConfig", 1)

    if !qjs.set_module_export(ctx, m, "defineConfig", fn) {
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
