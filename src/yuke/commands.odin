/*
The subcommand table that drives `yuke help`. Dispatch stays an explicit switch in `main`; this
table is the single source of truth for the help *text*, so the summary lines and per-command
detail cannot drift from the parsers the way a hand-maintained usage block does. Adding a
subcommand means adding a row here and a `case` in `main`.
*/
package main

import "core:fmt"
import "core:os"

// One CLI subcommand, for help rendering only.
Command :: struct {
    // Subcommand name as typed.
    name:    string,

    // Argument summary shown after the name in usage lines (e.g. "<verb>", "[flags]"); empty
    // for a subcommand that takes none.
    args:    string,

    // One-line summary for the top-level list.
    summary: string,

    // Expanded help for `yuke help <name>`; empty falls back to `summary`.
    detail:  []string,
}

COMMANDS := []Command {
    {
        name = "daemon",
        args = "",
        summary = "run the session daemon in the foreground",
        detail = {
            "Runs the front door, event store, and script tier attached to this terminal.",
            "Configuration comes from yuked.js and $YUKED_ROOT.",
            "",
            "To run it unattended instead, install it as a background service: see",
            "`yuke help service`.",
        },
    },
    {
        name = "service",
        args = "<verb>",
        summary = "manage the daemon as a background OS service",
        detail = {
            "Install the daemon under this platform's native supervisor so it starts at",
            "login and restarts on crash — launchd on macOS, systemd (user) on Linux, Task",
            "Scheduler on Windows. The service runs `yuke daemon` from this binary and keeps",
            "$YUKED_ROOT when it is set.",
            "",
            "  yuke service install [--force]   register the service (--force overwrites)",
            "  yuke service uninstall           remove it",
            "  yuke service start               start it now",
            "  yuke service stop                stop it",
            "  yuke service status              show whether it is installed and running",
        },
    },
    {
        name = "login",
        args = "[flags]",
        summary = "enroll this device with the control plane",
        detail = {
            "  --force          re-enroll even if an identity already exists",
            "  --name <name>    device name (default: machine hostname)",
            "  --cloud <url>    control-plane base URL (default $YUKE_CLOUD_URL)",
        },
    },
    {
        name = "provider",
        args = "<verb>",
        summary = "manage provider credentials on the local daemon",
        detail = {
            "  yuke provider list              show saved credential kinds and restart state",
            "  yuke provider set-key <id>      securely prompt for and save an API key",
            "  yuke provider remove-key <id>   remove a saved API key",
            "",
            "API-key changes take effect after the daemon restarts. Keys are never accepted",
            "on the command line or returned by the daemon.",
        },
    },
    {
        name = "catalog",
        args = "<verb>",
        summary = "manage the local model catalog",
        detail = {
            "  yuke catalog list               show the daemon's current models",
            "  yuke catalog refresh            fetch models.dev and rebuild the catalog on the daemon",
        },
    },
    {name = "help", args = "[command]", summary = "show this message, or the detail for one command", detail = {}},
}

// Print the top-level subcommand summary, aligned to the widest command label. Writes to `out`
// so the error paths can send it to stderr; `yuke help` prints it to stdout.
usage :: proc(out := os.stdout) {
    fmt.fprintln(out, "yuke — session client, daemon, and device login")
    fmt.fprintln(out)
    fmt.fprintln(out, "usage:")

    labels := make([]string, len(COMMANDS), context.allocator)
    defer {
        for l in labels {
            delete(l, context.allocator)
        }

        delete(labels, context.allocator)
    }

    col := len("yuke")
    for c, i in COMMANDS {
        labels[i] = command_label(c)

        if len(labels[i]) > col {
            col = len(labels[i])
        }
    }

    fmt.fprintfln(out, "  %-*s  run the interactive TUI client (default)", col, "yuke")

    for c, i in COMMANDS {
        fmt.fprintfln(out, "  %-*s  %s", col, labels[i], c.summary)
    }
}

// Whether an argument requests help: `help`, `--help`, or `-h`.
help_flag :: proc(s: string) -> bool {
    return s == "help" || s == "--help" || s == "-h"
}

// Whether `name` is a real top-level subcommand. Derived from COMMANDS so the help interception
// in `main` does not hardcode its own copy of the command set.
command_exists :: proc(name: string) -> bool {
    for c in COMMANDS {
        if c.name == name {
            return true
        }
    }

    return false
}

// Report an unknown command on stderr, then the usage block (also stderr, since this is an error
// path), and exit non-zero. Shared by `yuke <typo>` and `yuke help <typo>` so both behave the same.
usage_unknown :: proc(cmd: string) -> ! {
    fmt.eprintfln("yuke: unknown command %q", cmd)
    usage(os.stderr)
    os.exit(2)
}

// Print the detail for one command, or report an unknown one and exit non-zero.
help_command :: proc(name: string) {
    for c in COMMANDS {
        if c.name != name {
            continue
        }

        label := command_label(c)
        defer delete(label, context.allocator)

        fmt.printfln("usage: %s", label)
        fmt.println()

        if len(c.detail) == 0 {
            fmt.println(c.summary)

            return
        }

        for line in c.detail {
            fmt.println(line)
        }

        return
    }

    usage_unknown(name)
}

// "yuke <name>" or "yuke <name> <args>". Caller owns the result.
@(private = "file")
command_label :: proc(c: Command, allocator := context.allocator) -> string {
    if c.args == "" {
        return fmt.aprintf("yuke %s", c.name, allocator = allocator)
    }

    return fmt.aprintf("yuke %s %s", c.name, c.args, allocator = allocator)
}
