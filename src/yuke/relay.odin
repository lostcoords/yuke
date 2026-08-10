package main

import "core:log"
import "core:os"

import daemon "src:daemon"

// Relay endpoint, e.g. `ws://127.0.0.1:8787` or `wss://relay.yuke.sh`. Unset disables the
// relay link entirely.
RELAY_URL_ENV :: "YUKE_RELAY_URL"

// Ticket presented on the `/link` upgrade. In static mode any value works, but the same
// value must be used by the connecting client for the two to rendezvous.
RELAY_TICKET_ENV :: "YUKE_RELAY_TICKET"

// Optional path to write the daemon's relay static public key (32 raw bytes) so a test
// client can pin it. A stand-in until the control plane publishes the key.
RELAY_PUB_OUT_ENV :: "YUKE_RELAY_STATIC_PUB_OUT"

// Hand the daemon its relay endpoint and ticket when `YUKE_RELAY_URL` is set. The daemon
// owns the link's whole lifecycle from here — this only bridges env config to it. A
// static-mode try hook; real endpoints and tickets come from the control plane later.
relay_start :: proc(d: ^daemon.Daemon) {
    url, has_url := os.lookup_env(RELAY_URL_ENV, context.allocator)
    if !has_url {
        return
    }

    defer delete(url)

    ticket, has_ticket := os.lookup_env(RELAY_TICKET_ENV, context.allocator)
    defer if has_ticket {
        delete(ticket)
    }

    if !has_ticket {
        log.warnf("yuke: %s is unset; the relay will refuse the link", RELAY_TICKET_ENV)
    }

    if err := daemon.relay_connect(d, url, ticket); err != .None {
        log.errorf("yuke: relay connect failed: %v", err)

        return
    }

    if out, has_out := os.lookup_env(RELAY_PUB_OUT_ENV, context.allocator); has_out {
        defer delete(out)

        if pub, ok := daemon.relay_static_public(d); ok && os.write_entire_file(out, pub[:]) != nil {
            log.errorf("yuke: could not write relay static key to %q", out)
        }
    }
}
