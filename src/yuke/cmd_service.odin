/*
yuke service (`yuke service <verb>`): install and manage the foreground daemon as a background
service under the platform's native supervisor — launchd on macOS, systemd (user) on Linux, Task
Scheduler on Windows. This subcommand does not reimplement supervision; it generates a unit that
runs `yuke daemon` from this binary's absolute path and lets the OS keep it alive.

Everything platform-specific — where the unit is written, which tool loads it, how "installed"
and "running" are probed — lives in the per-OS `service_<os>.odin` files, one of which compiles
per target. This file owns the verb parsing and the helpers they share.

The generated unit is deliberately thin: it carries $YUKE_APPNAME forward when set (so a
service installed from a named profile keeps it) and otherwise leaves every operator-facing
value to yuked.js, exactly as the foreground daemon does.
*/
package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

import "src:paths"

// launchd label, and the systemd unit / schtasks task name. Stable identifiers: uninstall and
// status locate the service by these, so they must not change once shipped.
SERVICE_LABEL :: "sh.yuke.daemon"
SERVICE_NAME :: "yuke-daemon"

// Log file the generated unit points its stdout/stderr at, under the data directory. Empty when
// no data directory resolves; the supervisor then keeps its own default (journald, launchd log).
SERVICE_LOG_FILE :: "yuked.log"

// The `service` subcommand: parse the `--force` flag and the verb, then hand off to the
// per-platform implementation. `--force` is only meaningful for `install`; the others ignore it.
service_run :: proc() {
    if msg := paths.app_name_error(); msg != "" {
        fmt.eprintfln("yuke service: %s", msg)
        os.exit(1)
    }

    args := os.args[2:]
    if len(args) == 0 {
        help_command("service")
        os.exit(2)
    }

    force := false
    for a in args[1:] {
        switch a {
        case "--force":
            force = true

        case:
            fmt.eprintfln("yuke service: unknown option %q", a)
            os.exit(2)
        }
    }

    switch args[0] {
    case "install":
        service_install(force)

    case "uninstall":
        service_uninstall()

    case "start":
        service_start()

    case "stop":
        service_stop()

    case "status":
        service_status()

    case:
        fmt.eprintfln("yuke service: unknown verb %q; run `yuke help service`", args[0])
        os.exit(2)
    }
}

// One supervisor invocation's outcome. `launched` is false only when the tool could not be run
// at all (missing binary, no permission to fork); a tool that ran and failed is `launched` with a
// non-zero `exit_code`. Callers decide what a code means — some verbs treat "not loaded" as
// success (idempotent stop), others as failure.
Tool_Result :: struct {
    launched:  bool,
    exit_code: int,
    stdout:    string,
    stderr:    string,
}

// Run a supervisor command (launchctl/systemctl/schtasks) to completion, capturing its output.
run_tool :: proc(argv: []string, allocator := context.allocator) -> Tool_Result {
    desc := os.Process_Desc {
        command = argv,
    }

    state, out, err, perr := os.process_exec(desc, allocator)
    if perr != nil do return {launched = false}

    return {launched = true, exit_code = state.exit_code, stdout = string(out), stderr = string(err)}
}

// Run a supervisor command that must succeed, reporting `what` and exiting on failure. The common
// case: a step whose non-zero exit is fatal. Steps that tolerate a specific failure (an idempotent
// stop, a best-effort cleanup) call `run_tool` directly and inspect the result themselves.
run_tool_checked :: proc(argv: []string, what: string) {
    if r := run_tool(argv); !r.launched || r.exit_code != 0 do service_tool_failed(what, r)
}

// This binary's absolute path, for the generated unit's exec line. Exits on failure: a service
// pointing at a relative or unresolved path fails to start later in a way that is far harder to
// diagnose than an install-time error here.
service_exe_path :: proc(allocator := context.allocator) -> string {
    path, err := os.get_executable_path(allocator)
    if err != nil {
        fmt.eprintfln("yuke service: could not resolve this binary's path: %v", err)
        os.exit(1)
    }

    return path
}

// The value of $YUKE_APPNAME, or ("", false) when unset. Baked into the unit so a service
// installed under a named profile keeps it; unset means the default `yuke` leaf.
service_app_name :: proc(allocator := context.allocator) -> (string, bool) {
    return os.lookup_env(paths.APP_NAME_ENV, allocator)
}

// The log path the generated unit redirects to, or "" when no data directory resolves.
service_log_path :: proc(allocator := context.allocator) -> string {
    base := paths.data_dir(allocator)
    if base == "" do return ""

    defer delete(base, allocator)

    path, err := filepath.join({base, SERVICE_LOG_FILE}, allocator)

    return path if err == nil else ""
}

// Create the log file's parent dir: systemd and launchd open the log before forking the daemon, so
// a missing directory aborts the start (209/STDOUT). No log path means no redirect line, so no-op.
service_ensure_log_dir :: proc() {
    log := service_log_path()
    if log == "" do return

    defer delete(log)

    service_make_parent_dirs(log)
}

// Ensure the parent directory of `path` exists, exiting on failure.
service_make_parent_dirs :: proc(path: string) {
    // filepath.dir slices `path`; it is not an allocation and must not be freed.
    dir := filepath.dir(path)

    if err := os.make_directory_all(dir); err != nil && !os.is_dir(dir) {
        fmt.eprintfln("yuke service: could not create %s: %v", dir, err)
        os.exit(1)
    }
}

// Write the generated unit to `path`, creating parent directories. Exits on failure — a
// half-installed service is worse than a clear error at install time.
service_write :: proc(path: string, contents: string) {
    service_make_parent_dirs(path)

    if err := os.write_entire_file(path, contents); err != nil {
        fmt.eprintfln("yuke service: could not write %s: %v", path, err)
        os.exit(1)
    }
}

// Guard used by the darwin and linux backends, whose "installed" state is the on-disk unit file.
// Refuse to overwrite an existing unit unless `--force` was given.
service_refuse_if_installed :: proc(path: string, force: bool) {
    if !force && os.exists(path) {
        fmt.eprintfln("yuke service: already installed at %s; pass --force to reinstall", path)
        os.exit(1)
    }
}

// Guard used by the darwin and linux backends: `start` needs the unit written first.
service_require_installed :: proc(path: string) {
    if !os.exists(path) {
        fmt.eprintln("yuke service: not installed; run `yuke service install` first")
        os.exit(1)
    }
}

// XML-escape a value interpolated into a plist (macOS) or a scheduled-task definition (Windows).
// Filesystem paths rarely contain these, but a home directory or log path that does must not
// produce a malformed unit. Caller owns the result.
service_xml_escape :: proc(s: string, allocator := context.allocator) -> string {
    // replace_all aliases its input when the pattern is absent; free only real allocations and
    // clone the result so it is always owned.
    amp, amp_alloc := strings.replace_all(s, "&", "&amp;", allocator)
    defer if amp_alloc do delete(amp, allocator)

    lt, lt_alloc := strings.replace_all(amp, "<", "&lt;", allocator)
    defer if lt_alloc do delete(lt, allocator)

    gt, gt_alloc := strings.replace_all(lt, ">", "&gt;", allocator)
    defer if gt_alloc do delete(gt, allocator)

    return strings.clone(gt, allocator)
}

// Report a supervisor step that failed and exit non-zero. Shared exit path so every platform
// surfaces tool failures the same way, with the captured stderr when there is any.
service_tool_failed :: proc(what: string, r: Tool_Result) -> ! {
    if !r.launched {
        fmt.eprintfln("yuke service: could not run %s", what)
    } else {
        msg := r.stderr if r.stderr != "" else r.stdout
        fmt.eprintfln("yuke service: %s failed (exit %d): %s", what, r.exit_code, msg)
    }

    os.exit(1)
}
