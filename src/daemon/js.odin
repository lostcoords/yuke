package daemon

import "core:log"
import "core:mem"
import "core:os"
import "core:path/filepath"

import "libs:offload"
import js "src:js"

// Daemon-global manifest evaluated from the script root at startup, when a root is configured.
// This is the shared-runtime tier; per-session tool contexts attach here once a session engine
// owns their lifetime.
JS_ENTRY_FILE :: "yuked.js"

// Bring up the script tier. The daemon takes every limit `src/js` defaults to and installs
// `yuke:fs` plus its own `yuke:daemon` registrations — both only when a root gives an entry
// script to evaluate.
js_init :: proc(d: ^Daemon, root: string, allocator: mem.Allocator) -> Error {
    assert(d != nil, "js_init needs daemon state")
    assert(offload.pool_is_running(&d.workers), "the script tier offloads onto a running pool")

    // Only when a root gives it something to contain paths against — an unrooted import
    // fails rather than throwing on first call. `init` copies the list, so a local is fine.
    modules: [2]js.Module
    count := 0

    if root != "" {
        modules[count] = js.fs_module()
        count += 1
        modules[count] = script_module()
        count += 1
    }

    options := js.Options {
        modules   = modules[:count],
        root      = root,
        pool      = &d.workers,
        user      = d,
        report    = js_report,
        allocator = allocator,
    }

    switch js.init(&d.js, options) {
    case .None:
        return .None

    case .Invalid_Root:
        log.errorf("daemon: js root unusable: %s", root)

        return .Invalid_Options

    case .Out_Of_Memory:
        return .Out_Of_Memory
    }

    return .None
}

// A script fault is an operating outcome here: it is logged and the daemon keeps serving.
// The one exception is the entry script, which `js_run_entry` turns into a start failure.
js_report :: proc(user: rawptr, source: string, text: string) {
    log.errorf("daemon: js %s: %s", source, text)
}

// Evaluate `<root>/yuked.js` when configured and present. A root with no entry script is
// normal; one that won't evaluate is a start failure, like an unusable `blob_dir`. `evaluated`
// distinguishes "ran an entry" from "no entry to run", so `start` can tell a script that forgot
// `defineConfig` from a daemon with no script at all.
js_run_entry :: proc(d: ^Daemon, allocator: mem.Allocator) -> (evaluated: bool, err: Error) {
    assert(d != nil, "js entry needs daemon state")

    if d.js.root == "" {
        return false, .None
    }

    path, join_err := filepath.join({d.js.root, JS_ENTRY_FILE}, allocator)
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
