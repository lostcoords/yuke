/*
macOS service backend: a per-user launchd LaunchAgent at
`~/Library/LaunchAgents/sh.yuke.daemon.plist`. launchd auto-loads agents in that directory at
login, and `RunAtLoad` + `KeepAlive` make it start immediately and restart on crash.

The service model is "loaded == running": `stop` boots the job out of the login (gui) domain and
`disable`s it so `KeepAlive` cannot resurrect it and it stays down across logins; `start` re-enables,
bootstraps, and kickstarts it. Modern `launchctl` domain syntax (`gui/<uid>`) is used throughout;
the older `load`/`unload` verbs are deprecated on current macOS.
*/
package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

import "src:paths"

// Absolute path of the LaunchAgent plist, or exit if the home directory cannot be resolved.
@(private = "file")
plist_path :: proc(allocator := context.allocator) -> string {
    home := paths.home_dir(allocator)
    if home == "" {
        fmt.eprintln("yuke service: no home directory could be resolved")
        os.exit(1)
    }

    defer delete(home, allocator)

    path, err := filepath.join({home, "Library", "LaunchAgents", SERVICE_LABEL + ".plist"}, allocator)
    if err != nil {
        fmt.eprintln("yuke service: could not build the LaunchAgent path")
        os.exit(1)
    }

    return path
}

// The launchd domain for the current user's login session, `gui/<uid>`. Caller owns the result.
@(private = "file")
launchd_domain :: proc(allocator := context.allocator) -> string {
    return fmt.aprintf("gui/%d", os.get_uid(), allocator = allocator)
}

// The service target within that domain, `gui/<uid>/sh.yuke.daemon`. Caller owns the result.
@(private = "file")
launchd_target :: proc(allocator := context.allocator) -> string {
    return fmt.aprintf("gui/%d/%s", os.get_uid(), SERVICE_LABEL, allocator = allocator)
}

// Render the LaunchAgent plist. `RunAtLoad`+`KeepAlive` supply start-at-login and restart-on-crash;
// the environment and log-redirect blocks appear only when there is something to put in them.
@(private = "file")
plist_render :: proc(allocator := context.allocator) -> string {
    raw_exe := service_exe_path(context.allocator)
    defer delete(raw_exe, context.allocator)

    exe := service_xml_escape(raw_exe, context.allocator)
    defer delete(exe, context.allocator)

    log := service_log_path(context.allocator)
    defer delete(log, context.allocator)

    root, has_root := service_yuked_root(context.allocator)
    defer delete(root, context.allocator)

    b := strings.builder_make(allocator)

    strings.write_string(&b, `<?xml version="1.0" encoding="UTF-8"?>` + "\n")
    strings.write_string(
        &b,
        `<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">` +
        "\n",
    )
    strings.write_string(&b, `<plist version="1.0">` + "\n")
    strings.write_string(&b, "<dict>\n")

    fmt.sbprintf(&b, "    <key>Label</key>\n    <string>%s</string>\n", SERVICE_LABEL)
    strings.write_string(&b, "    <key>ProgramArguments</key>\n    <array>\n")
    fmt.sbprintf(&b, "        <string>%s</string>\n", exe)
    strings.write_string(&b, "        <string>daemon</string>\n    </array>\n")
    strings.write_string(&b, "    <key>RunAtLoad</key>\n    <true/>\n")
    strings.write_string(&b, "    <key>KeepAlive</key>\n    <true/>\n")

    if has_root && root != "" {
        esc := service_xml_escape(root, context.allocator)
        defer delete(esc, context.allocator)

        strings.write_string(&b, "    <key>EnvironmentVariables</key>\n    <dict>\n")
        fmt.sbprintf(&b, "        <key>%s</key>\n        <string>%s</string>\n", ROOT_ENV, esc)
        strings.write_string(&b, "    </dict>\n")
    }

    if log != "" {
        esc := service_xml_escape(log, context.allocator)
        defer delete(esc, context.allocator)

        fmt.sbprintf(&b, "    <key>StandardOutPath</key>\n    <string>%s</string>\n", esc)
        fmt.sbprintf(&b, "    <key>StandardErrorPath</key>\n    <string>%s</string>\n", esc)
    }

    strings.write_string(&b, "</dict>\n</plist>\n")

    return strings.to_string(b)
}

service_install :: proc(force: bool) {
    path := plist_path()
    defer delete(path)

    service_refuse_if_installed(path, force)

    domain := launchd_domain()
    defer delete(domain)

    target := launchd_target()
    defer delete(target)

    // Boot out any prior instance before overwriting, so the reinstall re-bootstraps cleanly.
    // "not loaded" is not a failure here.
    if force {
        run_tool({"launchctl", "bootout", target})
    }

    plist := plist_render()
    defer delete(plist)

    service_write(path, plist)

    run_tool({"launchctl", "enable", target})
    run_tool_checked({"launchctl", "bootstrap", domain, path}, "launchctl bootstrap")

    fmt.printfln("Installed %s and started it. It will start again at each login.", SERVICE_LABEL)
}

service_uninstall :: proc() {
    path := plist_path()
    defer delete(path)

    target := launchd_target()
    defer delete(target)

    // Stop and unload; a service that was never loaded is fine.
    run_tool({"launchctl", "bootout", target})

    if os.exists(path) {
        if err := os.remove(path); err != nil {
            fmt.eprintfln("yuke service: could not remove %s: %v", path, err)
            os.exit(1)
        }
    }

    fmt.printfln("Removed %s.", SERVICE_LABEL)
}

service_start :: proc() {
    path := plist_path()
    defer delete(path)

    service_require_installed(path)

    domain := launchd_domain()
    defer delete(domain)

    target := launchd_target()
    defer delete(target)

    run_tool({"launchctl", "enable", target})

    // Bootstrap reloads a booted-out service; ignore "already loaded". kickstart without -k just
    // ensures it runs: -k would bounce a healthy daemon and stall on launchd's relaunch throttle.
    run_tool({"launchctl", "bootstrap", domain, path})
    run_tool_checked({"launchctl", "kickstart", target}, "launchctl kickstart")

    fmt.printfln("Started %s.", SERVICE_LABEL)
}

service_stop :: proc() {
    target := launchd_target()
    defer delete(target)

    // Disable so KeepAlive cannot resurrect it and it stays down across logins, then boot it out.
    // Booting out a service that is not loaded reports a non-zero exit, but that is the desired end
    // state, so only a launch failure (could not run launchctl at all) is fatal.
    run_tool({"launchctl", "disable", target})

    if r := run_tool({"launchctl", "bootout", target}); !r.launched {
        service_tool_failed("launchctl bootout", r)
    }

    fmt.printfln("Stopped %s.", SERVICE_LABEL)
}

service_status :: proc() {
    path := plist_path()
    defer delete(path)

    target := launchd_target()
    defer delete(target)

    installed := os.exists(path)

    fmt.printfln("service:   %s", SERVICE_LABEL)
    fmt.printfln("installed: %v (%s)", installed, path)

    print := run_tool({"launchctl", "print", target})
    loaded := print.launched && print.exit_code == 0
    running := loaded && strings.contains(print.stdout, "state = running")

    fmt.printfln("loaded:    %v", loaded)
    fmt.printfln("running:   %v", running)
}
