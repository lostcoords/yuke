/*
Linux service backend: a per-user systemd unit at
`~/.config/systemd/user/yuke-daemon.service`. `WantedBy=default.target` starts it at login and
`Restart=on-failure` restarts it on a crash — a clean stop (SIGTERM → graceful exit 0) is not a
failure, so `stop` stays stopped.

User services need lingering to run without an active login session; `status` surfaces that,
since `install` cannot enable it without `sudo loginctl enable-linger`.
*/
package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

import "src:paths"

// The systemd unit file name, `yuke-daemon.service`.
@(private = "file")
UNIT_FILE :: SERVICE_NAME + ".service"

// Absolute path of the user unit file under `$XDG_CONFIG_HOME/systemd/user` (or `~/.config/...`),
// or exit if no config base can be resolved. This is systemd's own directory, not yuke's config
// directory, so it is built from the XDG base directly rather than from `paths.config_dir`.
@(private = "file")
unit_path :: proc(allocator := context.allocator) -> string {
    base := xdg_config_home(allocator)
    if base == "" {
        fmt.eprintln("yuke service: no config directory could be resolved")
        os.exit(1)
    }

    defer delete(base, allocator)

    path, err := filepath.join({base, "systemd", "user", UNIT_FILE}, allocator)
    if err != nil {
        fmt.eprintln("yuke service: could not build the unit path")
        os.exit(1)
    }

    return path
}

// `$XDG_CONFIG_HOME` when set and non-empty, else `~/.config`. Caller owns the result.
@(private = "file")
xdg_config_home :: proc(allocator := context.allocator) -> string {
    if xdg, set := os.lookup_env("XDG_CONFIG_HOME", allocator); set {
        if xdg != "" do return xdg

        delete(xdg, allocator)
    }

    home := paths.home_dir(allocator)
    if home == "" do return ""

    defer delete(home, allocator)

    path, err := filepath.join({home, ".config"}, allocator)

    return path if err == nil else ""
}

// Render the unit. `Restart=on-failure` supplies restart-on-crash; the environment and log lines
// appear only when there is something to put in them. The exec line points at this binary.
@(private = "file")
unit_render :: proc(allocator := context.allocator) -> string {
    exe := service_exe_path(context.allocator)
    defer delete(exe, context.allocator)

    log := service_log_path(context.allocator)
    defer delete(log, context.allocator)

    name, has_name := service_app_name(context.allocator)
    defer delete(name, context.allocator)

    b := strings.builder_make(allocator)

    strings.write_string(&b, "[Unit]\n")
    strings.write_string(&b, "Description=yuke session daemon\n")
    strings.write_string(&b, "After=network.target\n\n")

    strings.write_string(&b, "[Service]\n")
    fmt.sbprintf(&b, "ExecStart=%s daemon\n", exe)
    strings.write_string(&b, "Restart=on-failure\n")
    strings.write_string(&b, "RestartSec=2\n")

    if has_name && name != "" do fmt.sbprintf(&b, "Environment=\"%s=%s\"\n", paths.APP_NAME_ENV, name)

    if log != "" {
        fmt.sbprintf(&b, "StandardOutput=append:%s\n", log)
        fmt.sbprintf(&b, "StandardError=append:%s\n", log)
    }

    strings.write_string(&b, "\n[Install]\n")
    strings.write_string(&b, "WantedBy=default.target\n")

    return strings.to_string(b)
}

service_install :: proc(force: bool) {
    path := unit_path()
    defer delete(path)

    service_refuse_if_installed(path, force)

    unit := unit_render()
    defer delete(unit)

    service_ensure_log_dir()
    service_write(path, unit)

    run_tool_checked({"systemctl", "--user", "daemon-reload"}, "systemctl daemon-reload")
    run_tool_checked({"systemctl", "--user", "enable", "--now", UNIT_FILE}, "systemctl enable --now")

    fmt.printfln("Installed %s and started it. It will start again at each login.", UNIT_FILE)
    fmt.println("To keep it running while you are logged out: sudo loginctl enable-linger $USER")
}

service_uninstall :: proc() {
    path := unit_path()
    defer delete(path)

    // Stop and disable; failures here are not fatal, the unit may already be inactive.
    run_tool({"systemctl", "--user", "disable", "--now", UNIT_FILE})

    if os.exists(path) {
        if err := os.remove(path); err != nil {
            fmt.eprintfln("yuke service: could not remove %s: %v", path, err)
            os.exit(1)
        }
    }

    run_tool({"systemctl", "--user", "daemon-reload"})

    fmt.printfln("Removed %s.", UNIT_FILE)
}

service_start :: proc() {
    path := unit_path()
    defer delete(path)

    service_require_installed(path)

    run_tool_checked({"systemctl", "--user", "start", UNIT_FILE}, "systemctl start")

    fmt.printfln("Started %s.", UNIT_FILE)
}

service_stop :: proc() {
    run_tool_checked({"systemctl", "--user", "stop", UNIT_FILE}, "systemctl stop")

    fmt.printfln("Stopped %s.", UNIT_FILE)
}

service_status :: proc() {
    path := unit_path()
    defer delete(path)

    installed := os.exists(path)

    fmt.printfln("service:   %s", UNIT_FILE)
    fmt.printfln("installed: %v (%s)", installed, path)

    // `is-enabled`/`is-active` print a word and set exit status; the word is the authoritative
    // state, so report it trimmed.
    enabled := run_tool({"systemctl", "--user", "is-enabled", UNIT_FILE})
    active := run_tool({"systemctl", "--user", "is-active", UNIT_FILE})

    fmt.printfln("enabled:   %s", strings.trim_space(enabled.stdout))
    fmt.printfln("active:    %s", strings.trim_space(active.stdout))
}
