// The daemon's outbound relay link and the session bridge over it. The daemon dials the
// relay's /link route and parks; when a client is spliced in it runs the Noise responder
// handshake, then feeds each decrypted frame into the same `handle_text` machinery a local
// WebSocket client uses, and seals the daemon's replies back onto the link. The relay
// forwards only ciphertext, so the session is end-to-end encrypted across it.
//
// The link is kept up for the daemon's whole serving life: if it drops — relay restart,
// network, or a client dropped on a protocol error — the daemon re-dials with capped
// exponential backoff and re-parks. The relay is an addition to the front door, never a
// replacement: a parse or dial failure leaves the local daemon serving. v1 carries one
// client per link — closing a relay connection closes the whole link.
package daemon

import "core:crypto/ecdh"
import "core:log"
import "core:mem"
import "core:mem/virtual"
import "core:nbio"
import "core:strings"
import "core:time"

import "src:paths"

import curl "libs:bindings/curl"
import ws "libs:websocket"
import relay "src:relay"

// Reconnect backoff bounds. The delay doubles from the minimum after each failed dial or
// dropped link, caps at the maximum, and resets to the minimum on a successful park.
RELAY_BACKOFF_MIN :: 1 * time.Second
RELAY_BACKOFF_MAX :: 30 * time.Second

// Bounds for one link-ticket fetch on the relay's own curl client.
RELAY_TICKET_CONNECT_TIMEOUT :: 15 * time.Second
RELAY_TICKET_TOTAL_TIMEOUT :: 30 * time.Second

// The control-plane path a daemon POSTs its device credential to for a link ticket.
RELAY_LINK_TICKETS_PATH :: "/api/v1/link_tickets"

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

// The daemon's relay link, its Noise session, and the one bridged connection at a time.
// Heap-owned by the daemon so its address is stable for the link's owner back-reference and
// the bridged `Conn`'s transport arm.
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
    ticket_resp:     Auth_Response,

    // The relay endpoint and ticket the last fetch produced, owned and refreshed per fetch.
    relay_url:       string,
    ticket:          string,

    // The daemon's static identity: the responder key a client pins, loaded from the device
    // identity's `identity.key`.
    static_key:      ecdh.Private_Key,

    // The live Noise session with the current peer, valid between peer_attached and the peer
    // leaving; `established` gates transport frames.
    session:         relay.Session,
    established:     bool,

    // The bridged connection for the current peer, or nil when none is attached.
    conn:            ^Conn,

    // Scratch for one inbound handshake/transport decode, reset per frame.
    recv_scratch:    virtual.Arena,

    // Reassembles a wire frame fragmented across several inbound SEALED frames.
    recv_reasm:      relay.Reassembler,

    // Scratch for one outbound seal, reset per frame.
    send_scratch:    virtual.Arena,

    // Lifecycle state and the reconnect machinery.
    state:           Relay_State,
    backoff:         time.Duration,
    reconnect_timer: ^nbio.Operation,
}

// Connect the daemon's relay: exchange the device `credential` for a fresh link ticket at
// `cloud_url`, then dial the relay endpoint the ticket names and park, keeping the link up for the
// daemon's serving life. `static_seed` is the device's 32-byte X25519 static private key — the
// responder identity a client pins. Call once, after `start`. A fetch or dial failure retries with
// backoff. `cloud_url`/`credential` are borrowed for this call and cloned.
relay_connect :: proc(d: ^Daemon, cloud_url: string, credential: string, static_seed: []u8) -> Error {
    assert(d != nil, "relay_connect needs daemon state")
    assert(d.relay == nil, "relay_connect called twice")
    assert(d.loop != nil, "relay_connect needs the daemon loop")
    assert(len(static_seed) == relay.NOISE_STATIC_KEY_SIZE, "relay_connect needs a 32-byte static key")

    if cloud_url == "" || credential == "" {
        log.error("daemon: relay not started (no control-plane url or credential)")

        return .None
    }

    r, aerr := new(Relay, d.allocator)
    if aerr != nil {
        return .Out_Of_Memory
    }

    r.daemon = d
    r.state = .Fetching
    r.backoff = RELAY_BACKOFF_MIN

    if !ecdh.private_key_set_bytes(&r.static_key, .X25519, static_seed) {
        log.error("daemon: invalid relay static key")
        free(r, d.allocator)

        return .None
    }

    if virtual.arena_init_growing(&r.recv_scratch) != nil || virtual.arena_init_growing(&r.send_scratch) != nil {
        relay_free_partial(r)

        return .Out_Of_Memory
    }

    relay.reassembler_init(&r.recv_reasm, d.allocator)

    if curl.client_init(&r.curl_client, d.loop, d.allocator) != .None {
        relay_free_partial(r)

        return .Out_Of_Memory
    }

    r.curl_ready = true

    clone_err: mem.Allocator_Error
    r.cloud_url, clone_err = strings.clone(cloud_url, d.allocator)
    if clone_err == nil {
        r.credential, clone_err = strings.clone(credential, d.allocator)
    }
    if clone_err != nil {
        relay_free_partial(r)

        return .Out_Of_Memory
    }

    d.relay = r
    log.infof("daemon: relay enabled via %s", cloud_url)
    relay_fetch_ticket(r)

    return .None
}

// Start the relay from the enrolled device identity, if there is one. Loads `identity.key` as the
// responder static key and the credential the ticket fetch presents; with no identity the relay
// stays off. Call once, after `start`, so a relay failure never blocks the local daemon.
relay_autostart :: proc(d: ^Daemon) {
    assert(d != nil, "relay autostart needs daemon state")

    dir := paths.config_dir(d.allocator)
    if dir == "" {
        log.warn("daemon: no config directory; relay disabled")

        return
    }

    defer delete(dir, d.allocator)

    id, ierr := relay.identity_load(dir, d.allocator)
    switch ierr {
    case .None:

    case .Absent:
        log.info("daemon: no device identity; relay disabled (run `yuke login`)")

        return

    case .Unreadable, .Malformed, .Key_Invalid, .Out_Of_Memory, .Write_Failed:
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

// Begin a graceful teardown of the relay link. Idempotent. From `.Waiting` there is only a
// pending timer to cancel; from `.Parked` the link is closed and its terminal drives to
// `.Closed`; from `.Dialing` the in-flight dial resolves into the stopping path.
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
    assert(r.conn == nil, "relay destroyed with a live bridged connection")
    assert(r.reconnect_timer == nil, "relay destroyed with a pending reconnect timer")

    relay.session_destroy(&r.session)
    relay.reassembler_destroy(&r.recv_reasm)
    if r.curl_ready {
        curl.client_destroy(&r.curl_client)
    }

    if r.link_live {
        relay.link_destroy(&r.link)
    }

    ecdh.private_key_clear(&r.static_key)
    virtual.arena_destroy(&r.recv_scratch)
    virtual.arena_destroy(&r.send_scratch)
    delete(r.cloud_url, d.allocator)
    delete(r.credential, d.allocator)
    delete(r.relay_url, d.allocator)
    delete(r.ticket, d.allocator)
    free(r, d.allocator)
    d.relay = nil
}

// Seal one plaintext wire frame and queue it on the link — the relay half of
// `conn_send_text`. The bytes are copied into the link's send queue, so the scratch is reset
// on return. The client-side result is mapped onto the `ws.Server_Error` the daemon's send
// policy speaks.
relay_conn_send :: proc(r: ^Relay, plaintext: []byte) -> ws.Server_Error {
    assert(r != nil, "relay send needs relay state")
    assert(r.established, "relay send before the handshake completed")
    assert(len(plaintext) > 0, "relay send needs a non-empty frame")

    temp := virtual.arena_temp_begin(&r.send_scratch)
    defer virtual.arena_temp_end(temp)
    scratch := virtual.arena_allocator(&r.send_scratch)

    // A frame larger than one Noise packet rides several SEALED frames, each a header byte then a
    // slice of the plaintext. Each chunk is sealed before it is queued, so the Noise nonce advances
    // per chunk; a send that fails after sealing cannot be shed (see below).
    count := relay.transport_chunk_count(len(plaintext))

    for i in 0 ..< count {
        lo := i * relay.TRANSPORT_CHUNK_MAX
        hi := min(lo + relay.TRANSPORT_CHUNK_MAX, len(plaintext))

        chunk := make([]u8, 1 + (hi - lo), scratch)
        chunk[0] = relay.transport_chunk_header(i, count)
        copy(chunk[1:], plaintext[lo:hi])

        sealed, serr := relay.session_seal(&r.session, chunk, scratch)
        if serr != .None {
            log.errorf("daemon: relay seal failed: %v", serr)

            return .Send_Failed
        }

        frame := relay.frame_encode(relay.Frame{type = .Sealed, payload = sealed}, scratch)
        send_err := tx_error_client(relay.link_send_binary(&r.link, frame))
        if send_err == .None {
            continue
        }

        // The link is already closing; its terminal tears down the session and reconnects.
        if send_err == .Not_Open {
            return .Not_Open
        }

        // Any other failure — a full send queue included — is fatal here. The chunk is already
        // sealed, so the Noise nonce advanced; unlike a stateless WebSocket frame, a sealed frame
        // cannot be dropped without desyncing the cipher and breaking every later frame. Report a
        // hard failure so the pump aborts and the link reconnects and resyncs, instead of shedding
        // this frame (which the droppable class would otherwise do) and silently corrupting the
        // session.
        return .Send_Failed
    }

    return .None
}

// Whether the relay connection can still be answered: the link is open and the session is
// established. The liveness half of `conn_resolve` for a relay `Conn`.
relay_conn_open :: proc(r: ^Relay) -> bool {
    assert(r != nil, "relay liveness needs relay state")

    return relay.link_open(&r.link) && r.established
}

// Close a relay connection. v1 carries one client per link, so closing the connection closes
// the whole link; its terminal then frees the bridged `Conn` and re-parks.
relay_conn_close :: proc(r: ^Relay) {
    assert(r != nil, "relay close needs relay state")

    _ = relay.link_close(&r.link)
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
    relay.reassembler_destroy(&r.recv_reasm)
    ecdh.private_key_clear(&r.static_key)
    free(r, r.daemon.allocator)
}

// Fetch a fresh link ticket from the control plane, then dial. Async on the relay curl client: the
// completion dials on a 2xx or schedules a reconnect on any failure. A fresh ticket is fetched for
// every dial — the control plane issues short-lived, single-use link tickets.
@(private = "file")
relay_fetch_ticket :: proc(r: ^Relay) {
    assert(r.curl_ready, "relay ticket fetch needs a curl client")

    r.state = .Fetching
    r.ticket_resp = {}

    url := strings.concatenate({r.cloud_url, RELAY_LINK_TICKETS_PATH}, context.temp_allocator)
    bearer := strings.concatenate({"Bearer ", r.credential}, context.temp_allocator)

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

    return auth_response_accumulate(&r.ticket_resp, chunk)
}

// The ticket fetch finished. On a 2xx with a well-formed body, adopt the ticket and dial; any
// failure — transport, non-2xx, overflow, or malformed — retries with backoff.
@(private = "file")
relay_ticket_on_done :: proc(user: rawptr, result: curl.Result) {
    r := (^Relay)(user)
    assert(r.ticket_xfer.state == .Done, "relay ticket completion needs a terminal transfer")

    if r.state == .Stopping {
        r.state = .Closed

        return
    }

    if result.code != .Ok || result.status < 200 || result.status >= 300 || r.ticket_resp.overflow {
        log.errorf("daemon: relay ticket fetch failed: curl=%v status=%d", result.code, result.status)
        relay_schedule_reconnect(r)

        return
    }

    if !relay_ticket_store(r, auth_response_body(&r.ticket_resp)) {
        log.error("daemon: relay ticket response was malformed")
        relay_schedule_reconnect(r)

        return
    }

    relay_dial(r)
}

// Decode a link-ticket response and adopt its ticket and relay endpoint, replacing the previous
// pair. Validates the endpoint so `relay_dial` may assume it parses. Control-plane input, so a bad
// body degrades to false rather than asserting.
@(private = "file")
relay_ticket_store :: proc(r: ^Relay, body: string) -> bool {
    parsed, cerr := relay.ticket_decode(transmute([]u8)body, context.temp_allocator)
    if cerr != .None {
        return false
    }

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

    if err := relay.link_dial(&r.link, r.daemon.loop, endpoint, .Link, r.ticket, callbacks, r, r.daemon.allocator);
       err != .None {
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

// Tear down the bridged connection for the current peer, if any. Latches it Closed and frees
// it, which severs `r.conn`. The Noise session is reset so a fresh peer re-handshakes.
@(private = "file")
relay_teardown :: proc(r: ^Relay) {
    if r.conn != nil {
        r.conn.state = .Closed
        conn_free(r.conn)
    }

    assert(r.conn == nil, "relay teardown left a dangling connection")

    relay.session_destroy(&r.session)
    relay.reassembler_reset(&r.recv_reasm)
    r.established = false
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

    // The relay is an untrusted middlebox, so its CONTROL sequencing is peer input, not an
    // invariant to assert: a second peer_attached with no intervening peer_gone is a
    // protocol violation. Fail closed by dropping the link rather than crashing.
    if r.conn != nil || r.established {
        log.warn("daemon: relay peer_attached while a peer was bridged; closing link")
        _ = relay.link_close(l)

        return
    }

    relay.session_init_responder(&r.session, &r.static_key, transmute([]u8)string(relay.NOISE_PROLOGUE_V1))
    r.established = false
    log.info("daemon: relay peer attached, awaiting handshake")
}

@(private = "file")
relay_on_peer_gone :: proc(l: ^relay.Link, reason: string) {
    r := relay_of(l)
    log.infof("daemon: relay peer gone (%s)", reason)
    relay_teardown(r)
}

// One SEALED payload from the peer. Before the handshake completes it is the initiator's
// first message: respond, split, and bridge a `Conn`. After, it is a transport frame:
// decrypt it and feed the plaintext to `handle_text` as if it arrived on a local socket.
@(private = "file")
relay_on_sealed :: proc(l: ^relay.Link, payload: []u8) {
    r := relay_of(l)

    temp := virtual.arena_temp_begin(&r.recv_scratch)
    defer virtual.arena_temp_end(temp)
    scratch := virtual.arena_allocator(&r.recv_scratch)

    if !r.established {
        reply, herr := relay.session_respond(&r.session, payload, scratch)
        if herr != .None {
            log.errorf("daemon: relay handshake rejected: %v", herr)
            _ = relay.link_close(l, ws.Close_Code(1002))

            return
        }

        frame := relay.frame_encode(relay.Frame{type = .Sealed, payload = reply}, scratch)
        if send_err := relay.link_send_binary(l, frame); send_err != .None {
            log.errorf("daemon: relay handshake reply failed: %v", send_err)
            _ = relay.link_close(l)

            return
        }

        r.established = true

        conn := conn_register(r.daemon, r)
        if conn == nil {
            log.error("daemon: out of memory bridging a relay connection")
            _ = relay.link_close(l)

            return
        }

        r.conn = conn
        log.info("daemon: relay session established")

        return
    }

    chunk, oerr := relay.session_open(&r.session, payload, scratch)
    if oerr != .None {
        log.errorf("daemon: relay frame failed to open: %v", oerr)
        _ = relay.link_close(l, ws.Close_Code(1002))

        return
    }

    frame, done, rerr := relay.reassembler_push(&r.recv_reasm, chunk)
    if rerr != .None {
        log.errorf("daemon: relay frame reassembly failed: %v", rerr)
        _ = relay.link_close(l, ws.Close_Code(1002))

        return
    }

    if !done {
        return
    }

    if r.conn != nil && r.conn.state != .Closed {
        handle_text(r.conn, frame)
    }

    relay.reassembler_reset(&r.recv_reasm)
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

// Map a relay-link (WebSocket client) send result onto the server-side outcome the daemon's
// send policy already speaks. The relevant arms — delivered, closing, backpressure — are
// common to both; anything else is a generic send failure.
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
