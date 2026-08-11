/*
yuke: one binary, a handful of subcommands over a single `~/.config/yuke` identity.

  yuke            the interactive TUI client (default, no subcommand)
  yuke daemon     the session daemon (front door, store, script tier)
  yuke service    install/manage the daemon as a background OS service
  yuke login      device-code enrollment against the control plane

Role is per-invocation, not a persisted identity: the same device credential backs the client,
the daemon, and login. This file only routes; each subcommand's body lives in its own
`cmd_*.odin`, and `commands.odin` holds the help table the routing is documented from.
*/
package main

import "core:os"

import tui "src:tui"

main :: proc() {
    sub := os.args[1] if len(os.args) > 1 else ""
    rest := os.args[2] if len(os.args) > 2 else ""

    // `yuke <command> help|--help|-h` shows that command's help, mirroring `yuke help <command>`.
    // `help` itself is excluded so `yuke help --help` falls to the help case below.
    if help_flag(rest) && sub != "help" && command_exists(sub) {
        help_command(sub)

        return
    }

    switch sub {
    case "daemon":
        daemon_run()

    case "service":
        service_run()

    case "login":
        login_run()

    case "help", "--help", "-h":
        if rest == "" || help_flag(rest) {
            usage()
        } else {
            help_command(rest)
        }

    case "":
        tui.run()

    case:
        usage_unknown(sub)
    }
}
