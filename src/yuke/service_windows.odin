/*
Windows service backend: a Task Scheduler task named `yuke-daemon`. Windows has no launchd or
systemd; a scheduled task with a logon trigger is the equivalent — it starts at sign-in and, with
`<RestartOnFailure>`, relaunches on a crash.

Task Scheduler's `<Exec>` cannot set environment variables or redirect output, so when there is a
$YUKED_ROOT to carry or a log to capture the task runs a generated `.cmd` wrapper instead of the
binary directly. The task is registered from an XML definition (`schtasks /Create /XML`), which
must be UTF-16, so `unit_write_utf16` encodes it explicitly.
*/
package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:unicode/utf16"
import "core:unicode/utf8"

import "src:paths"

// Generated file names inside the service base directory.
@(private = "file")
WRAPPER_FILE :: SERVICE_NAME + ".cmd"

@(private = "file")
TASK_XML_FILE :: SERVICE_NAME + ".xml"

// The directory the generated wrapper and task XML live in: the data directory, else the config
// directory, else empty. Caller owns the result.
@(private = "file")
service_base :: proc(allocator := context.allocator) -> string {
    if base := paths.data_dir(allocator); base != "" {
        return base
    }

    return paths.config_dir(allocator)
}

// A path inside the service base, or exit if no base can be resolved.
@(private = "file")
base_path :: proc(name: string, allocator := context.allocator) -> string {
    base := service_base(allocator)
    if base == "" {
        fmt.eprintln("yuke service: no data or config directory could be resolved")
        os.exit(1)
    }

    defer delete(base, allocator)

    path, err := filepath.join({base, name}, allocator)
    if err != nil {
        fmt.eprintln("yuke service: could not build a service path")
        os.exit(1)
    }

    return path
}

// Render the `.cmd` wrapper that sets $YUKED_ROOT, runs the daemon, and appends its output to the
// log. Used only when there is an environment value or a log path; otherwise the task runs the
// binary directly. `exe` and `log` are absolute paths; `root` is the (present) script root.
@(private = "file")
wrapper_render :: proc(exe, root, log: string, has_root: bool, allocator := context.allocator) -> string {
    b := strings.builder_make(allocator)

    strings.write_string(&b, "@echo off\n")

    if has_root && root != "" {
        fmt.sbprintf(&b, "set \"%s=%s\"\n", ROOT_ENV, root)
    }

    fmt.sbprintf(&b, "\"%s\" daemon", exe)

    if log != "" {
        fmt.sbprintf(&b, " >> \"%s\" 2>&1", log)
    }

    strings.write_string(&b, "\n")

    return strings.to_string(b)
}

// Render the scheduled-task XML. `command` is the executable the task runs (the wrapper, or the
// binary directly) and `arguments` the arguments to pass it (empty for the wrapper). Both are
// XML-escaped by the caller. `<RestartOnFailure>` supplies restart-on-crash.
@(private = "file")
task_xml_render :: proc(command, arguments: string, allocator := context.allocator) -> string {
    b := strings.builder_make(allocator)

    strings.write_string(&b, `<?xml version="1.0" encoding="UTF-16"?>` + "\n")
    strings.write_string(
        &b,
        `<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">` + "\n",
    )
    strings.write_string(
        &b,
        "  <RegistrationInfo>\n    <Description>yuke session daemon</Description>\n  </RegistrationInfo>\n",
    )
    strings.write_string(
        &b,
        "  <Triggers>\n    <LogonTrigger>\n      <Enabled>true</Enabled>\n    </LogonTrigger>\n  </Triggers>\n",
    )
    strings.write_string(&b, "  <Principals>\n    <Principal id=\"Author\">\n")
    strings.write_string(
        &b,
        "      <LogonType>InteractiveToken</LogonType>\n      <RunLevel>LeastPrivilege</RunLevel>\n",
    )
    strings.write_string(&b, "    </Principal>\n  </Principals>\n")
    strings.write_string(&b, "  <Settings>\n")
    strings.write_string(&b, "    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>\n")
    strings.write_string(&b, "    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>\n")
    strings.write_string(&b, "    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>\n")
    strings.write_string(&b, "    <StartWhenAvailable>true</StartWhenAvailable>\n")
    strings.write_string(
        &b,
        "    <RestartOnFailure>\n      <Interval>PT1M</Interval>\n      <Count>999</Count>\n    </RestartOnFailure>\n",
    )
    strings.write_string(&b, "    <AllowStartOnDemand>true</AllowStartOnDemand>\n")
    strings.write_string(&b, "    <Enabled>true</Enabled>\n")
    strings.write_string(&b, "    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>\n")
    strings.write_string(&b, "  </Settings>\n")
    strings.write_string(&b, "  <Actions Context=\"Author\">\n    <Exec>\n")
    fmt.sbprintf(&b, "      <Command>%s</Command>\n", command)

    if arguments != "" {
        fmt.sbprintf(&b, "      <Arguments>%s</Arguments>\n", arguments)
    }

    strings.write_string(&b, "    </Exec>\n  </Actions>\n</Task>\n")

    return strings.to_string(b)
}

// Write `contents` as UTF-16LE with a BOM, the encoding `schtasks /Create /XML` requires. Creates
// parent directories and exits on failure, matching `service_write`.
@(private = "file")
unit_write_utf16 :: proc(path: string, contents: string) {
    service_make_parent_dirs(path)

    runes := utf8.string_to_runes(contents, context.allocator)
    defer delete(runes, context.allocator)

    units := make([]u16, len(runes) * 2, context.allocator)
    defer delete(units, context.allocator)

    n := utf16.encode(units, runes)

    // BOM (0xFEFF little-endian) followed by each code unit, low byte first.
    bytes := make([dynamic]u8, 0, (n + 1) * 2, context.allocator)
    defer delete(bytes)

    append(&bytes, 0xFF, 0xFE)

    for i in 0 ..< n {
        append(&bytes, u8(units[i] & 0xFF), u8(units[i] >> 8))
    }

    if err := os.write_entire_file(path, bytes[:]); err != nil {
        fmt.eprintfln("yuke service: could not write %s: %v", path, err)
        os.exit(1)
    }
}

// Generate the wrapper (when needed) and task XML, returning the path of the written XML for
// `schtasks /Create`. When no environment value or log applies, the task runs the binary directly.
// Caller owns the returned path.
@(private = "file")
task_prepare :: proc() -> string {
    exe := service_exe_path(context.allocator)
    defer delete(exe, context.allocator)

    log := service_log_path(context.allocator)
    defer delete(log, context.allocator)

    root, has_root := service_yuked_root(context.allocator)
    defer delete(root, context.allocator)

    xml_path := base_path(TASK_XML_FILE)

    use_wrapper := (has_root && root != "") || log != ""

    command: string
    arguments: string
    defer delete(command)
    defer delete(arguments)

    if use_wrapper {
        wrapper := base_path(WRAPPER_FILE)
        defer delete(wrapper)

        contents := wrapper_render(exe, root, log, has_root)
        defer delete(contents)

        service_write(wrapper, contents)

        command = service_xml_escape(wrapper)
        arguments = strings.clone("")
    } else {
        command = service_xml_escape(exe)
        arguments = service_xml_escape("daemon")
    }

    xml := task_xml_render(command, arguments)
    defer delete(xml)

    unit_write_utf16(xml_path, xml)

    return xml_path
}

service_install :: proc(force: bool) {
    if !force {
        if r := run_tool({"schtasks", "/Query", "/TN", SERVICE_NAME}); r.launched && r.exit_code == 0 {
            fmt.eprintfln("yuke service: task %s already exists; pass --force to reinstall", SERVICE_NAME)
            os.exit(1)
        }
    }

    xml_path := task_prepare()
    defer delete(xml_path)

    // `/F` overwrites without prompting; the existence check above enforces the non-force refusal.
    run_tool_checked({"schtasks", "/Create", "/TN", SERVICE_NAME, "/XML", xml_path, "/F"}, "schtasks /Create")

    // Logon-triggered tasks start at the next sign-in; run it once now so it is up immediately.
    run_tool({"schtasks", "/Run", "/TN", SERVICE_NAME})

    fmt.printfln("Installed task %s and started it. It will start again at each sign-in.", SERVICE_NAME)
}

service_uninstall :: proc() {
    run_tool({"schtasks", "/End", "/TN", SERVICE_NAME})
    run_tool_checked({"schtasks", "/Delete", "/TN", SERVICE_NAME, "/F"}, "schtasks /Delete")

    // Remove the generated wrapper and XML; a missing file is fine.
    base := service_base()
    defer delete(base)

    for name in ([]string{WRAPPER_FILE, TASK_XML_FILE}) {
        path, join_err := filepath.join({base, name})
        if join_err != nil {
            continue
        }

        defer delete(path)

        if os.exists(path) {
            os.remove(path)
        }
    }

    fmt.printfln("Removed task %s.", SERVICE_NAME)
}

service_start :: proc() {
    run_tool_checked({"schtasks", "/Run", "/TN", SERVICE_NAME}, "schtasks /Run")

    fmt.printfln("Started task %s.", SERVICE_NAME)
}

service_stop :: proc() {
    run_tool_checked({"schtasks", "/End", "/TN", SERVICE_NAME}, "schtasks /End")

    fmt.printfln("Stopped task %s.", SERVICE_NAME)
}

service_status :: proc() {
    query := run_tool({"schtasks", "/Query", "/TN", SERVICE_NAME, "/FO", "LIST", "/V"})
    installed := query.launched && query.exit_code == 0
    running := installed && strings.contains(query.stdout, "Running")

    fmt.printfln("service:   %s", SERVICE_NAME)
    fmt.printfln("installed: %v", installed)
    fmt.printfln("running:   %v", running)
}
