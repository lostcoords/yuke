// The daemon's outbound relay link and the session bridge over it: several clients share one
// link as end-to-end Noise sessions, and their decrypted frames enter `handle_text` unchanged.
package daemon

import "core:crypto/ecdh"
import "core:log"
import "core:mem"
import "core:mem/virtual"
import "core:nbio"
import "core:net"
import "core:strconv"
import "core:strings"
import "core:time"

import "src:paths"

import "libs:bindings/curl"
import "libs:http"
import ws "libs:websocket"
import "src:relay"

// Reconnect backoff bounds. The delay doubles from the minimum after each failed dial or
// dropped link, caps at the maximum, and resets to the minimum on a successful park.
RELAY_BACKOFF_MIN :: 1 * time.Second
RELAY_BACKOFF_MAX :: 30 * time.Second

// Daemon-originated keepalive on the relay link: ping interval and pong deadline. Self-heals a
// half-open socket left by suspend/resume; stays well under the proxy idle window (Cloudflare ~100s).
RELAY_KEEPALIVE_INTERVAL :: 25 * time.Second
RELAY_KEEPALIVE_PONG_DEADLINE :: 10 * time.Second

// Bounds for one link-ticket fetch on the relay's own curl client.
RELAY_TICKET_CONNECT_TIMEOUT :: 15 * time.Second
RELAY_TICKET_TOTAL_TIMEOUT :: 30 * time.Second

// The control-plane path a daemon POSTs its device credential to for a link ticket.
RELAY_LINK_TICKETS_PATH :: "/api/v1/link_tickets"

// Daemon-side upper bound on concurrent clients multiplexed over one link; the relay enforces
// the real per-grant cap below this. A channel id at or above it is a protocol violation.
RELAY_MAX_CHANNELS :: 8

// Validate and remove trailing slashes from a control-plane base URL. Remote
// endpoints require HTTPS; plaintext HTTP is limited to literal IPv4 loopback.
relay_cloud_url_normalize :: proc(source: string, allocator := context.allocator) -> (normalized: string, err: Error) {
    if source == "" {
        return "", .Invalid_Options
    }

    for c in transmute([]u8)source {
        if c <= ' ' || c >= 0x7f {
            return "", .Invalid_Options
        }
    }
    if strings.contains_any(source, "@?#") {
        return "", .Invalid_Options
    }

    prefix := "https://"
    secure := true
    if strings.has_prefix(source, "http://") {
        prefix = "http://"
        secure = false
    } else if !strings.has_prefix(source, prefix) {
        return "", .Invalid_Options
    }

    rest := source[len(prefix):]
    slash := strings.index_byte(rest, '/')
    authority := rest
    if slash >= 0 {
        authority = rest[:slash]
    }
    if authority == "" || authority[len(authority) - 1] == ':' {
        return "", .Invalid_Options
    }

    for c in transmute([]u8)authority {
        if !(c >= 'a' && c <= 'z' ||
               c >= 'A' && c <= 'Z' ||
               c >= '0' && c <= '9' ||
               c == '.' ||
               c == '-' ||
               c == ':' ||
               c == '[' ||
               c == ']') {
            return "", .Invalid_Options
        }
    }

    host, bracketed, host_ok := http.split_host(authority)
    if !host_ok || host == "" {
        return "", .Invalid_Options
    }

    port_suffix := authority[len(host):]
    if bracketed {
        port_suffix = authority[len(host) + 2:]
    }
    if port_suffix != "" {
        if len(port_suffix) < 2 || len(port_suffix) > 6 {
            return "", .Invalid_Options
        }

        port, port_ok := strconv.parse_int(port_suffix[1:], 10)
        if !port_ok || port < 1 || port > 65535 {
            return "", .Invalid_Options
        }
    }

    if !secure {
        address, address_ok := net.parse_ip4_address(host)
        if !address_ok || bracketed || address[0] != 127 {
            return "", .Invalid_Options
        }
    }

    end := len(source)
    for end > len(prefix) + len(authority) && source[end - 1] == '/' {
        end -= 1
    }

    path := source[len(prefix) + len(authority):end]
    if path != "" {
        if strings.contains(path, "//") ||
           path == "/." ||
           path == "/.." ||
           strings.contains(path, "/./") ||
           strings.contains(path, "/../") {
            return "", .Invalid_Options
        }

        for c in transmute([]u8)path {
            if !(c >= 'a' && c <= 'z' ||
                   c >= 'A' && c <= 'Z' ||
                   c >= '0' && c <= '9' ||
                   c == '/' ||
                   c == '-' ||
                   c == '.' ||
                   c == '_' ||
                   c == '~') {
                return "", .Invalid_Options
            }
        }
    }

    return strings.clone(source[:end], allocator), .None
}

// The relay link's lifecycle. Exactly one state at a time; `shutdown_complete` waits for
// `.Closed`.
Relay_State :: enum {
    // A link-ticket fetch is in flight on the curl client; awaiting the control plane.
    Fetching,

    // `link_dial` is in flight; awaiting on_parked/on_error.
    Dialing,

    // The link is open and parked, maybe with a bridged peer.
    Parked,

    // The link is down; a reconnect timer is pending.
    Waiting,

    // Shutdown was requested; draining the current state to `.Closed`.
    Stopping,

    // Finished; safe to destroy.
    Closed,
}

// One client's session on the shared link, keyed by the relay's channel byte. The zero value is
// an idle slot; session and reassembler are init on attach and destroyed on teardown.
Relay_Peer :: struct {
    // Whether this channel currently holds an attached client.
    active:      bool,

    // Whether the Noise handshake completed; gates transport frames and sealing.
    established: bool,

    // The live Noise session with this channel's client.
    session:     relay.Session,

    // The bridged connection for this client, or nil until the handshake completes.
    conn:        ^Conn,

    // Reassembles a wire frame fragmented across several inbound SEALED frames on this channel.
    recv_reasm:  relay.Reassembler,
}

// The daemon's relay link and its per-channel client sessions. Heap-owned by the daemon so its
// address is stable for the link's owner back-reference and the bridged `Conn`s' transport arm.
Relay :: struct {
    // Owning daemon, recovered by the link callbacks.
    daemon:          ^Daemon,

    // The outbound link. Re-dialed on reconnect; `link_live` says whether it holds buffers.
    link:            relay.Link,
    link_live:       bool,

    // Owned control-plane endpoint and device credential, exchanged for a fresh link ticket on
    // every (re)dial. `credential` is secret — never log it.
    cloud_url:       string,
    credential:      string,

    // The relay's own curl client for ticket fetches and the in-flight fetch + bounded response.
    curl_client:     curl.Client,
    curl_ready:      bool,
    ticket_xfer:     curl.Transfer,
    ticket_resp:     Bounded_Response,

    // The relay endpoint and ticket the last fetch produced, owned and refreshed per fetch.
    relay_url:       string,
    ticket:          string,

    // The daemon's static identity: the responder key a client pins, loaded from the device
    // identity's `identity.key`.
    static_key:      ecdh.Private_Key,

    // Per-channel client sessions, indexed by the relay's routing byte. All-zero is an idle
    // channel; the relay caps the live count below `RELAY_MAX_CHANNELS`.
    peers:           [RELAY_MAX_CHANNELS]Relay_Peer,

    // Scratch for one inbound handshake/transport decode, reset per frame. Shared across channels:
    // the nbio loop is single-threaded, so exactly one frame is in flight at a time.
    recv_scratch:    virtual.Arena,

    // Scratch for one outbound seal, reset per frame. Shared like `recv_scratch`.
    send_scratch:    virtual.Arena,

    // Lifecycle state and the reconnect machinery.
    state:           Relay_State,
    backoff:         time.Duration,
    reconnect_timer: ^nbio.Operation,
}

// Exchange the device credential for a link ticket, dial the relay it names, and park for the
// daemon's serving life. `static_seed` is the responder identity a client pins; inputs are cloned.
relay_connect :: proc(d: ^Daemon, cloud_url: string, credential: string, static_seed: []u8) -> Error {
    assert(d != nil, "relay_connect needs daemon state")
    assert(d.relay == nil, "relay_connect called twice")
    assert(d.loop != nil, "relay_connect needs the daemon loop")
    assert(len(static_seed) == relay.NOISE_STATIC_KEY_SIZE, "relay_connect needs a 32-byte static key")

    if cloud_url == "" || credential == "" {
        log.error("daemon: relay not started (no control-plane url or credential)")

        return .None
    }

    r := new(Relay, d.allocator)

    r.daemon = d
    r.state = .Fetching
    r.backoff = RELAY_BACKOFF_MIN

    if !ecdh.private_key_set_bytes(&r.static_key, .X25519, static_seed) {
        log.error("daemon: invalid relay static key")
        free(r, d.allocator)

        return .None
    }

    _ = virtual.arena_init_growing(&r.recv_scratch)
    _ = virtual.arena_init_growing(&r.send_scratch)

    // curl init is a genuine libs failure, not our allocation: degrade to "relay disabled"
    // rather than crash, matching the not-configured path above.
    if curl.client_init(&r.curl_client, d.loop, d.allocator) != .None {
        log.error("daemon: relay curl client init failed; relay disabled")
        relay_free_partial(r)

        return .None
    }

    r.curl_ready = true

    normalized_cloud, url_err := relay_cloud_url_normalize(cloud_url, d.allocator)
    if url_err != .None {
        relay_free_partial(r)

        return url_err
    }
    r.cloud_url = normalized_cloud

    r.credential = strings.clone(credential, d.allocator)

    d.relay = r
    log.infof("daemon: relay enabled via %s", cloud_url)
    relay_fetch_ticket(r)

    return .None
}

// Start the relay from the enrolled device identity; with no identity it stays off. Call once
// after `start`, so a relay failure never blocks the local daemon.
relay_autostart :: proc(d: ^Daemon) {
    assert(d != nil, "relay autostart needs daemon state")

    dir := paths.data_dir(d.allocator)
    if dir == "" {
        log.warn("daemon: no data directory; relay disabled")

        return
    }

    defer delete(dir, d.allocator)

    id, ierr := relay.identity_load(dir, d.allocator)
    switch ierr {
    case .None:

    case .Absent:
        log.info("daemon: no device identity; relay disabled (run `yuke login`)")

        return

    case .Unreadable, .Malformed, .Key_Invalid, .Write_Failed, .Stale:
        log.errorf("daemon: device identity unusable (%v); relay disabled", ierr)

        return
    }

    defer relay.identity_destroy(&id)

    key_bytes: [relay.NOISE_STATIC_KEY_SIZE]u8
    ecdh.private_key_bytes(&id.static_key, key_bytes[:])
    defer mem.zero_slice(key_bytes[:])

    if err := relay_connect(d, d.relay_cloud_url, id.credential, key_bytes[:]); err != .None {
        log.errorf("daemon: relay connect failed: %v", err)
    }
}

// Whether the relay link has finished, or was never up — so a shutdown may stop waiting.
relay_closed :: proc(d: ^Daemon) -> bool {
    return d.relay == nil || d.relay.state == .Closed
}

// Begin a graceful teardown of the link. Idempotent: `.Waiting` cancels its timer, `.Parked`
// closes and drives to `.Closed`, and an in-flight dial resolves into the stopping path.
relay_begin_close :: proc(d: ^Daemon) {
    if d.relay == nil {
        return
    }

    r := d.relay
    if r.state == .Closed || r.state == .Stopping {
        return
    }

    prior := r.state
    r.state = .Stopping

    switch prior {
    case .Fetching:
        // A ticket fetch is in flight; cancel it (its completion never fires after) and finish.
        if r.curl_ready && r.ticket_xfer.state == .Running {
            curl.transfer_cancel(&r.ticket_xfer)
        }

        r.state = .Closed

    case .Waiting:
        if r.reconnect_timer != nil {
            nbio.remove(r.reconnect_timer)
            r.reconnect_timer = nil
        }

        r.state = .Closed

    case .Parked:
        _ = relay.link_close(&r.link)

    case .Dialing:
        // Cancel the in-flight dial so its terminal fires now; otherwise the ws handshake
        // timeout could outrun the shutdown deadline and force the non-graceful exit.
        relay.link_cancel(&r.link)

    case .Stopping, .Closed:
    }
}

// Release the relay link and its session, wiping key material. Call once, after
// `relay_closed` is true. The bridged connection and any reconnect timer are already gone.
relay_destroy :: proc(d: ^Daemon) {
    if d.relay == nil {
        return
    }

    r := d.relay
    assert(r.state == .Closed, "relay destroyed before it closed")
    assert(r.reconnect_timer == nil, "relay destroyed with a pending reconnect timer")

    // The link's terminal tore every peer down before reaching `.Closed`; clean up defensively
    // in case a slot survived, wiping its key material either way.
    for ch in 0 ..< RELAY_MAX_CHANNELS {
        assert(r.peers[ch].conn == nil, "relay destroyed with a live bridged connection")
        relay.session_destroy(&r.peers[ch].session)
        relay.reassembler_destroy(&r.peers[ch].recv_reasm)
    }

    if r.curl_ready {
        curl.client_destroy(&r.curl_client)
    }

    if r.link_live {
        relay.link_destroy(&r.link)
    }

    ecdh.private_key_clear(&r.static_key)
    bounded_response_reset(&r.ticket_resp)
    virtual.arena_destroy(&r.recv_scratch)
    virtual.arena_destroy(&r.send_scratch)
    delete(r.cloud_url, d.allocator)
    delete(r.credential, d.allocator)
    delete(r.relay_url, d.allocator)
    delete(r.ticket, d.allocator)
    free(r, d.allocator)
    d.relay = nil
}

// Seal one wire frame onto `channel` — the relay half of `conn_send_text`. The link copies, so
// the scratch resets on return; the client-side result maps onto `ws.Server_Error`.
relay_conn_send :: proc(r: ^Relay, channel: u8, plaintext: []byte) -> ws.Server_Error {
    assert(r != nil, "relay send needs relay state")
    assert(int(channel) < RELAY_MAX_CHANNELS, "relay send needs an in-range channel")
    assert(r.peers[channel].established, "relay send before the handshake completed")
    assert(len(plaintext) > 0, "relay send needs a non-empty frame")

    peer := &r.peers[channel]

    temp := virtual.arena_temp_begin(&r.send_scratch)
    defer virtual.arena_temp_end(temp)
    scratch := virtual.arena_allocator(&r.send_scratch)

    // A frame larger than one Noise packet rides several SEALED frames. Each is sealed before it
    // is queued, so the nonce advances per chunk and a failed send cannot be shed.
    count := relay.transport_chunk_count(len(plaintext))

    for i in 0 ..< count {
        lo := i * relay.TRANSPORT_CHUNK_MAX
        hi := min(lo + relay.TRANSPORT_CHUNK_MAX, len(plaintext))

        frame, serr := relay.transport_seal_chunk(&peer.session, plaintext[lo:hi], i, count, scratch)
        if serr != .None {
            log.errorf("daemon: relay seal failed: %v", serr)

            return .Send_Failed
        }

        send_err := tx_error_client(relay.link_send_channel(&r.link, channel, frame))
        if send_err == .None {
            continue
        }

        // The link is already closing; its terminal tears down the session and reconnects.
        if send_err == .Not_Open {
            return .Not_Open
        }

        // Fatal, a full send queue included: the chunk is sealed, so the nonce advanced and dropping
        // it would desync the cipher. Fail hard so the link reconnects and resyncs.
        return .Send_Failed
    }

    return .None
}

// Whether the relay connection can still be answered: the link is open and the channel's session
// is established. The liveness half of `conn_resolve` for a relay `Conn`.
relay_conn_open :: proc(r: ^Relay, channel: u8) -> bool {
    assert(r != nil, "relay liveness needs relay state")
    assert(int(channel) < RELAY_MAX_CHANNELS, "relay liveness needs an in-range channel")

    return relay.link_open(&r.link) && r.peers[channel].established
}

// Close one relay client: a daemon-initiated close tears down just its channel locally, leaving
// the shared link and every other channel untouched. No control message reaches the relay.
relay_conn_close :: proc(r: ^Relay, channel: u8) {
    assert(r != nil, "relay close needs relay state")
    assert(int(channel) < RELAY_MAX_CHANNELS, "relay close needs an in-range channel")

    relay_peer_teardown(r, channel)
}

// Free a partly-built relay during `relay_connect` rollback. Safe on any prefix of the fields
// `relay_connect` sets, in the order it sets them.
@(private = "file")
relay_free_partial :: proc(r: ^Relay) {
    if r.curl_ready {
        curl.client_destroy(&r.curl_client)
    }

    delete(r.cloud_url, r.daemon.allocator)
    delete(r.credential, r.daemon.allocator)
    virtual.arena_destroy(&r.recv_scratch)
    virtual.arena_destroy(&r.send_scratch)
    ecdh.private_key_clear(&r.static_key)
    free(r, r.daemon.allocator)
}

// Fetch a fresh link ticket, then dial; the completion dials on a 2xx or schedules a reconnect.
// Every dial fetches its own: the control plane issues short-lived, single-use tickets.
@(private = "file")
relay_fetch_ticket :: proc(r: ^Relay) {
    assert(r.curl_ready, "relay ticket fetch needs a curl client")

    r.state = .Fetching
    bounded_response_reset(&r.ticket_resp)

    url := strings.concatenate({r.cloud_url, RELAY_LINK_TICKETS_PATH}, context.temp_allocator)
    bearer := strings.concatenate({"Bearer ", r.credential}, context.temp_allocator)
    defer delete(bearer, context.temp_allocator)

    headers := [?]curl.Header{{name = "authorization", value = bearer}, {name = "accept", value = "application/json"}}
    request := curl.Request {
        url             = strings.clone_to_cstring(url, context.temp_allocator),
        headers         = headers[:],
        method          = .Post,
        connect_timeout = RELAY_TICKET_CONNECT_TIMEOUT,
        total_timeout   = RELAY_TICKET_TOTAL_TIMEOUT,
    }
    callbacks := curl.Callbacks {
        on_body = relay_ticket_on_body,
        on_done = relay_ticket_on_done,
    }

    if err := curl.transfer_start(&r.ticket_xfer, &r.curl_client, request, callbacks, r); err != .None {
        log.errorf("daemon: relay ticket request setup failed: %v", err)
        relay_schedule_reconnect(r)
    }
}

@(private = "file")
relay_ticket_on_body :: proc(user: rawptr, chunk: []byte) -> bool {
    r := (^Relay)(user)

    return bounded_response_accumulate(&r.ticket_resp, chunk)
}

// The ticket fetch finished. On a 2xx with a well-formed body, adopt the ticket and dial; any
// failure — transport, non-2xx, overflow, or malformed — retries with backoff.
@(private = "file")
relay_ticket_on_done :: proc(user: rawptr, result: curl.Result) {
    r := (^Relay)(user)
    assert(r.ticket_xfer.state == .Done, "relay ticket completion needs a terminal transfer")
    defer bounded_response_reset(&r.ticket_resp)

    if r.state == .Stopping {
        r.state = .Closed

        return
    }

    if result.code != .Ok || result.status < 200 || result.status >= 300 || r.ticket_resp.overflow {
        log.errorf("daemon: relay ticket fetch failed: curl=%v status=%d", result.code, result.status)
        relay_schedule_reconnect(r)

        return
    }

    if !relay_ticket_store(r, bounded_response_body(&r.ticket_resp)) {
        log.error("daemon: relay ticket response was malformed")
        relay_schedule_reconnect(r)

        return
    }

    relay_dial(r)
}

// Adopt a ticket response's ticket and endpoint, replacing the previous pair and validating what
// `relay_dial` assumes. Control-plane input, so a bad body degrades rather than asserting.
@(private = "file")
relay_ticket_store :: proc(r: ^Relay, body: string) -> bool {
    parsed, cerr := relay.ticket_decode(transmute([]u8)body, context.temp_allocator)
    if cerr != .None {
        return false
    }
    defer delete(parsed.ticket, context.temp_allocator)

    if _, ok := relay.endpoint_parse(parsed.relay_url); !ok {
        return false
    }

    ticket, t_aerr := strings.clone(parsed.ticket, r.daemon.allocator)
    if t_aerr != nil {
        return false
    }

    url, u_aerr := strings.clone(parsed.relay_url, r.daemon.allocator)
    if u_aerr != nil {
        delete(ticket, r.daemon.allocator)

        return false
    }

    delete(r.ticket, r.daemon.allocator)
    delete(r.relay_url, r.daemon.allocator)
    r.ticket = ticket
    r.relay_url = url

    return true
}

// (Re)dial the relay link. Frees the previous link's buffers first when one is live, so a
// re-dial never leaks. A synchronous failure schedules a retry.
@(private = "file")
relay_dial :: proc(r: ^Relay) {
    if r.link_live {
        relay.link_destroy(&r.link)
        r.link_live = false
    }

    endpoint, ok := relay.endpoint_parse(r.relay_url)
    assert(ok, "relay url was validated when its ticket was fetched")

    r.state = .Dialing

    callbacks := relay.Link_Callbacks {
        on_parked        = relay_on_parked,
        on_peer_attached = relay_on_peer_attached,
        on_peer_gone     = relay_on_peer_gone,
        on_sealed        = relay_on_sealed,
        on_closed        = relay_on_closed,
        on_error         = relay_on_error,
    }

    if err := relay.link_dial(
        &r.link,
        r.daemon.loop,
        endpoint,
        .Link,
        r.ticket,
        callbacks,
        r,
        r.daemon.allocator,
        keepalive_interval = RELAY_KEEPALIVE_INTERVAL,
        keepalive_pong_deadline = RELAY_KEEPALIVE_PONG_DEADLINE,
    ); err != .None {
        log.errorf("daemon: relay dial failed: %v", err)
        relay_schedule_reconnect(r)

        return
    }

    r.link_live = true
}

// Schedule a reconnect after the current backoff, then double it toward the cap. A shutdown
// requested while waiting resolves straight to `.Closed`.
@(private = "file")
relay_schedule_reconnect :: proc(r: ^Relay) {
    assert(r.reconnect_timer == nil, "reconnect scheduled twice")

    if r.state == .Stopping {
        r.state = .Closed

        return
    }

    r.state = .Waiting
    log.infof("daemon: relay retrying in %v", r.backoff)
    r.reconnect_timer = nbio.timeout_poly(r.backoff, r, relay_reconnect_on_timer, r.daemon.loop)
    r.backoff = min(r.backoff * 2, RELAY_BACKOFF_MAX)
}

@(private = "file")
relay_reconnect_on_timer :: proc(op: ^nbio.Operation, r: ^Relay) {
    assert(r.reconnect_timer == op, "reconnect timer crossed ownership")
    r.reconnect_timer = nil

    if r.state == .Stopping {
        r.state = .Closed

        return
    }

    relay_fetch_ticket(r)
}

// The link went down (closed or errored): tear the bridged session down, then reconnect
// unless we are shutting down.
@(private = "file")
relay_on_down :: proc(r: ^Relay) {
    relay_teardown(r)

    if r.state == .Stopping {
        r.state = .Closed

        return
    }

    relay_schedule_reconnect(r)
}

// Tear down one channel's client: latch its bridged `Conn` Closed and free it (which severs
// `peers[channel].conn`), destroy its session and reassembler, and return the slot to idle.
@(private = "file")
relay_peer_teardown :: proc(r: ^Relay, channel: u8) {
    assert(int(channel) < RELAY_MAX_CHANNELS, "relay teardown needs an in-range channel")

    peer := &r.peers[channel]
    if peer.conn != nil {
        peer.conn.state = .Closed
        conn_free(peer.conn)
    }

    assert(peer.conn == nil, "relay teardown left a dangling connection")

    relay.session_destroy(&peer.session)
    relay.reassembler_destroy(&peer.recv_reasm)
    peer^ = {}
}

// Tear down every active channel — the link went down or the relay is stopping. The shared
// scratch arenas are left intact for the next dial.
@(private = "file")
relay_teardown :: proc(r: ^Relay) {
    for ch in 0 ..< RELAY_MAX_CHANNELS {
        if r.peers[ch].active {
            relay_peer_teardown(r, u8(ch))
        }
    }
}

// Recover the owning relay state from a link callback.
@(private = "file")
relay_of :: proc(l: ^relay.Link) -> ^Relay {
    r := (^Relay)(l.user_data)
    assert(r != nil, "relay link lost its owner")

    return r
}

@(private = "file")
relay_on_parked :: proc(l: ^relay.Link) {
    r := relay_of(l)

    if r.state == .Stopping {
        _ = relay.link_close(l)

        return
    }

    r.state = .Parked
    r.backoff = RELAY_BACKOFF_MIN
    log.info("daemon: relay link parked, awaiting client")
}

@(private = "file")
relay_on_peer_attached :: proc(l: ^relay.Link) {
    r := relay_of(l)
    ch := relay.link_channel(l)

    // The relay is an untrusted middlebox, so its channel assignment is peer input: one out of range
    // or already active drops the link rather than crashing.
    if int(ch) >= RELAY_MAX_CHANNELS || r.peers[ch].active {
        log.warnf("daemon: relay peer_attached on a bad or busy channel %d; closing link", ch)
        _ = relay.link_close(l)

        return
    }

    peer := &r.peers[ch]
    relay.session_init_responder(&peer.session, &r.static_key, transmute([]u8)string(relay.NOISE_PROLOGUE_V1))
    relay.reassembler_init(&peer.recv_reasm, r.daemon.allocator)
    peer.active = true
    peer.established = false
    log.infof("daemon: relay peer attached on channel %d, awaiting handshake", ch)
}

@(private = "file")
relay_on_peer_gone :: proc(l: ^relay.Link, reason: string) {
    r := relay_of(l)
    ch := relay.link_channel(l)
    log.infof("daemon: relay peer gone on channel %d (%s)", ch, reason)

    if int(ch) < RELAY_MAX_CHANNELS && r.peers[ch].active {
        relay_peer_teardown(r, ch)
    }
}

// One SEALED payload: before the handshake it is the initiator's first message, after it is a
// transport frame fed to `handle_text`. A frame on an inactive channel is dropped, not fatal.
@(private = "file")
relay_on_sealed :: proc(l: ^relay.Link, payload: []u8) {
    r := relay_of(l)
    ch := relay.link_channel(l)

    if int(ch) >= RELAY_MAX_CHANNELS || !r.peers[ch].active {
        log.warnf("daemon: relay SEALED on inactive channel %d, dropping", ch)

        return
    }

    peer := &r.peers[ch]

    temp := virtual.arena_temp_begin(&r.recv_scratch)
    defer virtual.arena_temp_end(temp)
    scratch := virtual.arena_allocator(&r.recv_scratch)

    if !peer.established {
        reply, herr := relay.session_respond(&peer.session, payload, scratch)
        if herr != .None {
            // A per-channel handshake failure tears down only this client; the shared link and
            // every other channel stay up (no daemon→relay control message).
            log.errorf("daemon: relay handshake rejected on channel %d: %v", ch, herr)
            relay_peer_teardown(r, ch)

            return
        }

        frame := relay.frame_encode(relay.Frame{type = .Sealed, payload = reply}, scratch)
        if send_err := relay.link_send_channel(l, ch, frame); send_err != .None {
            // A send failure is a fault of the shared socket, not this channel, so close the link.
            log.errorf("daemon: relay handshake reply failed: %v", send_err)
            _ = relay.link_close(l)

            return
        }

        peer.established = true

        conn := conn_register(r.daemon, Relay_Client{relay = r, channel = ch})
        if conn == nil {
            log.error("daemon: out of memory bridging a relay connection")
            _ = relay.link_close(l)

            return
        }

        peer.conn = conn
        log.infof("daemon: relay session established on channel %d", ch)

        return
    }

    frame, done, ok := relay.transport_open_fragment(&peer.session, &peer.recv_reasm, payload, scratch)
    if !ok {
        // A desynced cipher is unrecoverable, but only for this channel — tear it down alone.
        log.errorf("daemon: relay frame rejected on channel %d", ch)
        relay_peer_teardown(r, ch)

        return
    }

    if !done {
        return
    }

    if peer.conn != nil && peer.conn.state != .Closed {
        handle_text(peer.conn, frame)
    }

    relay.reassembler_reset(&peer.recv_reasm)
}

@(private = "file")
relay_on_closed :: proc(l: ^relay.Link, code: ws.Close_Code) {
    r := relay_of(l)
    log.infof("daemon: relay link closed: %s", relay_close_reason(code))
    relay_on_down(r)
}

@(private = "file")
relay_on_error :: proc(l: ^relay.Link, err: ws.Client_Error) {
    r := relay_of(l)
    log.errorf("daemon: relay link error: %v", err)
    relay_on_down(r)
}

// A human reason for a relay close code: the relay's application codes (4000-range) plus the
// standard ones the daemon sees. Rendered in logs and, later, to the operator.
@(private = "file")
relay_close_reason :: proc(code: ws.Close_Code) -> string {
    switch u16(code) {
    case 1000:
        return "normal closure"

    case 1001:
        return "relay going away"

    case 4001:
        return "replaced by a newer link"

    case 4404:
        return "no device online"

    case 4409:
        return "device already has a client"

    case 4410:
        return "peer gone"

    case:
        return "closed"
    }
}

// Map a relay-link send result onto the server-side outcome the send policy speaks. Delivered,
// closing and backpressure are common to both; anything else is a generic send failure.
@(private = "file")
tx_error_client :: proc(e: ws.Client_Error) -> ws.Server_Error {
    if e == .None {
        return .None
    }

    if e == .Not_Open {
        return .Not_Open
    }

    if e == .Send_Queue_Full {
        return .Send_Queue_Full
    }

    return .Send_Failed
}
