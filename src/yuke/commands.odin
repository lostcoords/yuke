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
            "  --name <name>    device name (default $HOSTNAME)",
            "  --cloud <url>    control-plane base URL (default $YUKE_CLOUD_URL)",
        },
    },
    {name = "help", args = "[command]", summary = "show this message, or the detail for one command", detail = {}},
}

// Print the top-level subcommand summary to stdout, aligned to the widest command label.
usage :: proc() {
    fmt.println("yuke — session client, daemon, and device login")
    fmt.println()
    fmt.println("usage:")

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

    fmt.printfln("  %-*s  run the interactive TUI client (default)", col, "yuke")

    for c, i in COMMANDS {
        fmt.printfln("  %-*s  %s", col, labels[i], c.summary)
    }
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

    fmt.eprintfln("yuke: unknown command %q; run `yuke help`", name)
    os.exit(2)
}

// "yuke <name>" or "yuke <name> <args>". Caller owns the result.
@(private = "file")
command_label :: proc(c: Command, allocator := context.allocator) -> string {
    if c.args == "" {
        return fmt.aprintf("yuke %s", c.name, allocator = allocator)
    }

    return fmt.aprintf("yuke %s %s", c.name, c.args, allocator = allocator)
}
