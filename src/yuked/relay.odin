/*
Optional relay link for the daemon binary.

When `YUKE_RELAY_URL` is set, the daemon dials the relay's `/link` route and parks,
holding the socket open (ping/pong is the relay's heartbeat) until a client is spliced
in. This is the static-mode try hook: the ticket is passed verbatim, and against a relay
in `static`/`none` mode the device is derived from it, so no control plane is needed yet.
Real tickets and endpoints from the control plane replace these env vars in a later stage.

Parking only: nothing is sent, and a SEALED payload (once the Noise session exists) has
nowhere to go yet, so it is logged and dropped. A parse or dial failure never stops the
local daemon — the relay is an addition to the front door, not a replacement.
*/
package main

import "core:log"
import "core:nbio"
import "core:os"

import ws "libs:websocket"
import relay "src:relay"

// Relay endpoint, e.g. `ws://127.0.0.1:8787` or `wss://relay.yuke.sh`. Unset disables
// the relay link entirely.
RELAY_URL_ENV :: "YUKE_RELAY_URL"

// Ticket presented on the `/link` upgrade. In static mode any value works, but the same
// value must be used by the connecting client for the two to rendezvous.
RELAY_TICKET_ENV :: "YUKE_RELAY_TICKET"

@(private = "file")
g_link: relay.Link

// The link was dialed and still needs destroying.
@(private = "file")
g_link_on: bool

// The link reported closed or errored; safe to destroy.
@(private = "file")
g_link_done: bool

// A close was requested before the link reached Open; close it as soon as it parks.
@(private = "file")
g_link_closing: bool

// Dial the relay link when `YUKE_RELAY_URL` is set. Logs and returns on any failure so a
// misconfigured or unreachable relay leaves the local daemon serving.
relay_start :: proc(loop: ^nbio.Event_Loop) {
    url, set := os.lookup_env(RELAY_URL_ENV, context.allocator)
    if !set {
        return
    }

    defer delete(url)

    endpoint, ok := relay.endpoint_parse(url)
    if !ok {
        log.errorf("yuked: ignoring malformed %s=%q", RELAY_URL_ENV, url)
        return
    }

    ticket, has_ticket := os.lookup_env(RELAY_TICKET_ENV, context.allocator)
    defer if has_ticket {
        delete(ticket)
    }

    if !has_ticket {
        log.warnf("yuked: %s is unset; the relay will refuse the link", RELAY_TICKET_ENV)
    }

    callbacks := relay.Link_Callbacks {
        on_parked        = relay_on_parked,
        on_peer_attached = relay_on_peer_attached,
        on_peer_gone     = relay_on_peer_gone,
        on_sealed        = relay_on_sealed,
        on_closed        = relay_on_closed,
        on_error         = relay_on_error,
    }

    if err := relay.link_dial(&g_link, loop, endpoint, .Link, ticket, callbacks); err != .None {
        log.errorf("yuked: relay link dial failed: %v", err)
        return
    }

    g_link_on = true
    log.infof("yuked: dialing relay %s (route /link)", url)
}

// Request a graceful close. Idempotent; if the link has not reached Open yet, the close
// is deferred to `relay_on_parked`.
relay_begin_close :: proc() {
    if !g_link_on || g_link_done {
        return
    }

    g_link_closing = true

    // `.Not_Open` here means the link is still dialing; `relay_on_parked` will close it.
    _ = relay.link_close(&g_link)
}

// Whether the link has finished, so a shutdown may stop waiting on it.
relay_closed :: proc() -> bool {
    return !g_link_on || g_link_done
}

// Release the link's storage. Call once, after `relay_closed` is true.
relay_finish :: proc() {
    if !g_link_on {
        return
    }

    relay.link_destroy(&g_link)
    g_link_on = false
}

@(private = "file")
relay_on_parked :: proc(l: ^relay.Link) {
    if g_link_closing {
        _ = relay.link_close(l)
        return
    }

    log.info("yuked: relay link parked, awaiting client")
}

@(private = "file")
relay_on_peer_attached :: proc(l: ^relay.Link) {
    log.info("yuked: relay peer attached")
}

@(private = "file")
relay_on_peer_gone :: proc(l: ^relay.Link, reason: string) {
    log.infof("yuked: relay peer gone (%s)", reason)
}

@(private = "file")
relay_on_sealed :: proc(l: ^relay.Link, payload: []u8) {
    log.debugf("yuked: relay SEALED payload (%d bytes) dropped; no session yet", len(payload))
}

@(private = "file")
relay_on_closed :: proc(l: ^relay.Link, code: ws.Close_Code) {
    g_link_done = true
    log.infof("yuked: relay link closed (%d)", u16(code))
}

@(private = "file")
relay_on_error :: proc(l: ^relay.Link, err: ws.Client_Error) {
    g_link_done = true
    log.errorf("yuked: relay link error: %v", err)
}
