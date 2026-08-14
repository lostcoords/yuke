#+build windows
package js

import "base:runtime"
import "core:c"

import qjs "libs:bindings/quickjs"

// Windows needs its own implementation, not a translation of the POSIX one. Three pieces are
// missing: a shell the model can write for (`cmd` is a different language, and `core:os`
// quotes command lines by MSVCRT rules that `cmd` does not parse), our own `CreateProcessW`
// to control that command line, and a Job Object with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`
// so a cancel reaches the whole tree. Until then the export refuses rather than mis-running.
EXEC_MODULE :: "yuke:exec"

@(rodata)
EXEC_EXPORTS := []string{"exec"}

exec_module :: proc() -> Module {
    return {name = EXEC_MODULE, init = exec_module_init, exports = EXEC_EXPORTS}
}

@(private = "file")
exec_module_init :: proc "c" (ctx: ^qjs.Context, m: ^qjs.Module_Def) -> c.int {
    context = runtime.default_context()

    if !qjs.set_module_export(ctx, m, "exec", qjs.new_function(ctx, exec_entry, "exec", 2)) {
        return -1
    }

    return 0
}

@(private = "file")
exec_entry :: proc "c" (ctx: ^qjs.Context, this: qjs.Value, argc: c.int, argv: [^]qjs.Value) -> qjs.Value {
    context = runtime.default_context()

    return qjs.throw_type_error(ctx, "yuke:exec is not supported on Windows yet")
}
