package daemon

import "core:log"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"

import "libs:offload"
import js "src:js"

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
        cloned, clone_err := strings.clone(root, allocator)
        if clone_err != nil {
            return .Out_Of_Memory
        }

        d.config_dir = cloned
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

    case .Out_Of_Memory:
        return .Out_Of_Memory

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

    if d.config_dir == "" {
        return false, .None
    }

    path, join_err := filepath.join({d.config_dir, JS_ENTRY_FILE}, allocator)
    if join_err != nil {
        return false, .Out_Of_Memory
    }

    defer delete(path, allocator)

    source, read_err := os.read_entire_file(path, allocator)
    defer delete(source, allocator)
    if read_err != nil {
        if read_err == .Not_Exist {
            return false, .None
        }

        log.errorf("daemon: cannot read script entry %s: %v", path, read_err)
        return false, .Script_Failed
    }

    evaluated_ok := js.eval_module(&d.js, JS_ENTRY_FILE, string(source), allocator)

    if !evaluated_ok {
        return false, .Script_Failed
    }

    log.infof("daemon: evaluated %s", path)

    return true, .None
}
