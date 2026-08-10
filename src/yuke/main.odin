/*
yuke: one binary, three subcommands over a single `~/.config/yuke` identity.

  yuke            the interactive TUI client (default, no subcommand)
  yuke daemon     the session daemon (front door, store, script tier)
  yuke login      device-code enrollment against the control plane

Role is per-invocation, not a persisted identity: the same device credential backs the client,
the daemon, and login. This file only routes; each subcommand's body lives in its own
`cmd_*.odin`.
*/
package main

import "core:fmt"
import "core:os"

main :: proc() {
    sub := os.args[1] if len(os.args) > 1 else ""

    switch sub {
    case "daemon":
        daemon_run()

    case "login":
        login_run()

    case "help", "--help", "-h":
        usage()

    case:
        client_run()
    }
}

// Print the subcommand summary to stdout.
@(private = "file")
usage :: proc() {
    fmt.println(
        `yuke — session client, daemon, and device login

usage:
  yuke            run the interactive TUI client (default)
  yuke daemon     run the session daemon
  yuke login      enroll this device with the control plane
  yuke help       show this message`,
    )
}
