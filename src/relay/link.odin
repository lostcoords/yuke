// Link is the dial-and-park half of the relay transport: it opens one WebSocket to
// the relay's /link (daemon) or /connect (client) route and pumps envelope frames.
// This stage wires the daemon's /link role — dial, park, and surface the relay's
// CONTROL messages (peer_attached/peer_gone). A SEALED payload is handed to
// `on_sealed`; the Noise session that fills that callback lands in a later stage.
package relay

import "core:log"
import "core:mem"
import "core:mem/virtual"
import "core:nbio"
import "core:net"
import "core:strconv"
import "core:strings"
import "core:time"

import ws "libs:websocket"

// Which relay route a link dials. The daemon parks on `/link`; the remote client
// dials `/connect`. Both redeem their ticket and are spliced onto the same session.
Link_Route :: enum {
    // Daemon side: GET /link.
    Link,

    // Client side: GET /connect.
    Connect,
}

// A parsed relay endpoint. `host` aliases the source URL, so do not retain it past
// the URL's lifetime. Handed to `link_dial` to open the socket.
Endpoint :: struct {
    // Transport: `Ws` for `ws://`, `Wss` for `wss://`.
    scheme: ws.Scheme,

    // Hostname or dotted IPv4 address, no port.
    host:   string,

    // TCP port; defaulted from the scheme when the URL omits it.
    port:   int,
}

// Events a link raises to its owner. Any field may be nil. Payload and reason strings
// are borrowed for the call only — copy them to retain. CONTROL never reaches the peer;
// `on_sealed` carries opaque ciphertext the owner's Noise session opens.
Link_Callbacks :: struct {
    // The upgrade succeeded: the link is parked, awaiting a peer.
    on_parked:        proc(l: ^Link),

    // A peer was spliced onto this link.
    on_peer_attached: proc(l: ^Link),

    // The peer went away; `reason` says why. The link stays parked for the next peer.
    on_peer_gone:     proc(l: ^Link, reason: string),

    // One SEALED payload (a Noise message), delivered only after peer_attached.
    on_sealed:        proc(l: ^Link, payload: []u8),

    // The link closed with the reported (or synthesized) code.
    on_closed:        proc(l: ^Link, code: ws.Close_Code),

    // The link failed terminally; it is closed when this runs.
    on_error:         proc(l: ^Link, err: ws.Client_Error),
}

// One relay link on an nbio loop. Owns its WebSocket client and a per-message scratch
// arena. Dial with `link_dial`; free with `link_destroy` once closed.
Link :: struct {
    // @private
    // WebSocket client driving the socket. `user_data` points back to this link.
    sock:       ws.Client,

    // @private
    // Borrowed event loop the socket runs on.
    loop:       ^nbio.Event_Loop,

    // @private
    // Backs the scratch arena and outlives the link.
    allocator:  mem.Allocator,

    // @private
    // Owner callbacks.
    cbs:        Link_Callbacks,

    // @private
    // Which route this link dialed.
    route:      Link_Route,

    // @private
    // Whether any peer is currently spliced in. A SEALED frame is only valid while true.
    attached:   bool,

    // @private
    // Attached-peer count on a `.Link`; `attached` stays true until the last peer leaves, so one
    // peer going away never ungates the others. Always 0/1 in effect on the client's `.Connect`.
    peer_count: int,

    // @private
    // Channel of the message being dispatched (the /link routing id); valid only during a callback.
    channel:    u8,

    // @private
    // Scratch for one inbound CONTROL decode, reset per message.
    scratch:    virtual.Arena,

    // Owner pointer, set by `link_dial` and recovered by the owner's callbacks. Borrowed.
    user_data:  rawptr,
}

// What an inbound link message means, decided from its kind and bytes. `.Fail` names a
// framing or control violation the link must close on.
Link_Action :: enum {
    // A SEALED payload to hand to `on_sealed`.
    Sealed,

    // A CONTROL peer_attached: mark the link attached and raise `on_peer_attached`.
    Peer_Attached,

    // A CONTROL peer_gone: raise `on_peer_gone` and stay parked.
    Peer_Gone,

    // A SEALED frame that arrived before peer_attached: misordered, discard it.
    Drop,

    // A text frame, malformed envelope, or bad CONTROL: close the link.
    Fail,
}

// Decide what an inbound message means. Pure — no socket, no callbacks — so the pump's
// rules are testable directly: text is fatal, a SEALED needs a live peer, CONTROL routes
// by type. CONTROL is relay→daemon only, so on the client's `.Connect` route it is a
// violation. On the daemon's `.Link` the relay prefixes a one-byte `channel`, stripped and
// returned here (0 on `.Connect`). On `.Sealed` the returned payload aliases `msg`; on
// `.Peer_Gone` `reason` is allocated from `allocator`. `err` is set only for `.Fail`.
link_dispatch :: proc(
    route: Link_Route,
    kind: ws.Message_Kind,
    msg: []u8,
    attached: bool,
    allocator := context.allocator,
) -> (
    action: Link_Action,
    channel: u8,
    payload: []u8,
    reason: string,
    err: Error,
) {
    if kind != .Binary {
        // The socket answers ping/pong/close itself, so only a text data frame reaches
        // here — and the envelope rides only binary.
        return .Fail, 0, nil, "", .Text
    }

    // The daemon's `.Link` prefixes a one-byte channel that routes the frame to one of several
    // clients; the client's `.Connect` carries no prefix (one session per socket).
    body := msg
    if route == .Link {
        if len(msg) == 0 {
            return .Fail, 0, nil, "", .Empty
        }

        channel = msg[0]
        body = msg[1:]
    }

    frame, ferr := frame_decode(body)
    if ferr != .None {
        return .Fail, 0, nil, "", ferr
    }

    switch frame.type {
    case .Sealed:
        if !attached {
            return .Drop, 0, nil, "", .None
        }

        return .Sealed, channel, frame.payload, "", .None

    case .Control:
        if route == .Connect {
            return .Fail, 0, nil, "", .Control_Unexpected
        }

        ctrl, cerr := control_decode(frame.payload, allocator)
        if cerr != .None {
            return .Fail, 0, nil, "", cerr
        }

        switch ctrl.kind {
        case .Peer_Attached:
            return .Peer_Attached, channel, nil, "", .None

        case .Peer_Gone:
            return .Peer_Gone, channel, nil, ctrl.reason, .None
        }
    }

    unreachable()
}

// Parse a relay endpoint from `ws://host[:port]` or `wss://host[:port]`. Any path is
// ignored — the route decides it. `host` aliases `url`. A missing port defaults to 80
// (ws) or 443 (wss). IPv6 literals are out of scope. Returns false on a bad scheme,
// empty host, or an out-of-range port.
endpoint_parse :: proc(url: string) -> (ep: Endpoint, ok: bool) {
    scheme: ws.Scheme
    rest: string

    switch {
    case strings.has_prefix(url, "wss://"):
        scheme = .Wss
        rest = url[6:]

    case strings.has_prefix(url, "ws://"):
        scheme = .Ws
        rest = url[5:]

    case:
        return {}, false
    }

    if slash := strings.index_byte(rest, '/'); slash >= 0 {
        rest = rest[:slash]
    }

    if rest == "" {
        return {}, false
    }

    host := rest
    port := 443 if scheme == .Wss else 80

    if colon := strings.last_index_byte(rest, ':'); colon >= 0 {
        host = rest[:colon]
        parsed, pok := strconv.parse_int(rest[colon + 1:], 10)
        if !pok || parsed <= 0 || parsed > 65535 {
            return {}, false
        }

        port = parsed
    }

    if host == "" {
        return {}, false
    }

    return Endpoint{scheme = scheme, host = host, port = port}, true
}

// Dial the relay and begin parking. Opens a WebSocket to the route's path with the
// ticket in the query; the rest runs on the loop, reporting through `cbs`. A synchronous
// failure returns directly and leaves nothing to destroy; an async one arrives via
// `on_error`. `endpoint.host` is borrowed only for this call.
link_dial :: proc(
    l: ^Link,
    loop: ^nbio.Event_Loop,
    endpoint: Endpoint,
    route: Link_Route,
    ticket: string,
    cbs: Link_Callbacks,
    user_data: rawptr = nil,
    allocator := context.allocator,
    keepalive_interval: time.Duration = 0,
    keepalive_pong_deadline: time.Duration = 0,
) -> ws.Client_Error {
    assert(l != nil, "link_dial needs link storage")
    assert(loop != nil, "link_dial needs an event loop")

    l^ = {}
    l.loop = loop
    l.allocator = allocator
    l.cbs = cbs
    l.route = route
    l.user_data = user_data

    _ = virtual.arena_init_growing(&l.scratch)

    // client_connect clones the path, so building it in temp storage is safe.
    base := "/link" if route == .Link else "/connect"
    encoded := net.percent_encode(ticket, context.temp_allocator)
    defer delete(encoded, context.temp_allocator)
    path := strings.concatenate({base, "?ticket=", encoded}, context.temp_allocator)
    defer delete(path, context.temp_allocator)

    options := ws.Options {
        scheme                  = endpoint.scheme,
        host                    = endpoint.host,
        port                    = endpoint.port,
        path                    = path,
        keepalive_interval      = keepalive_interval,
        keepalive_pong_deadline = keepalive_pong_deadline,
    }

    callbacks := ws.Callbacks {
        on_open    = link_on_open,
        on_message = link_on_message,
        on_close   = link_on_close,
        on_error   = link_on_error,
    }

    err := ws.client_connect(&l.sock, loop, options, callbacks, l, allocator)
    if err != .None {
        virtual.arena_destroy(&l.scratch)
    }

    return err
}

// Queue one SEALED (or handshake) frame on the link. The bytes are copied into the
// client's send queue, so the caller may free them once this returns.
link_send_binary :: proc(l: ^Link, bytes: []u8) -> ws.Client_Error {
    assert(l != nil, "link_send_binary needs a link")

    return ws.client_send_binary(&l.sock, bytes)
}

// Queue one SEALED (or handshake) frame on the daemon's `.Link`, prefixed with the routing
// `channel` the relay reads to fan out to one client. The prefixed buffer is built in temp
// storage and copied into the send queue, so the caller's `bytes` are neither retained nor mutated.
link_send_channel :: proc(l: ^Link, channel: u8, bytes: []u8) -> ws.Client_Error {
    assert(l != nil, "link_send_channel needs a link")

    prefixed := make([]u8, 1 + len(bytes), context.temp_allocator)
    prefixed[0] = channel
    copy(prefixed[1:], bytes)

    return ws.client_send_binary(&l.sock, prefixed)
}

// Whether the link's socket is Open — the liveness a bridged connection reports.
link_open :: proc(l: ^Link) -> bool {
    assert(l != nil, "link_open needs a link")

    return l.sock.state == .Open
}

// The /link channel of the message being dispatched, for a `.Link` owner to read inside
// on_sealed/on_peer_attached/on_peer_gone. Always 0 on the client's `.Connect`.
link_channel :: proc(l: ^Link) -> u8 {
    assert(l != nil, "link_channel needs a link")

    return l.channel
}

// Cancel an in-flight dial or upgrade before the link opens; the terminal callback reports
// the cancellation. Valid only while the link is still opening — use `link_close` once Open.
link_cancel :: proc(l: ^Link) {
    assert(l != nil, "link_cancel needs a link")

    ws.client_cancel(&l.sock)
}

// Begin a graceful close. Fails with `.Not_Open` when the link has not reached Open,
// which the caller may ignore during a shutdown race.
link_close :: proc(l: ^Link, code := ws.Close_Code.Normal_Closure) -> ws.Client_Error {
    assert(l != nil, "link_close needs a link")

    return ws.client_close(&l.sock, code)
}

// Fail the link without a close handshake, reporting `err` through `on_error`. The terminal
// fallback when the owner cannot continue safely (a seal or queue failure). `err` must be a
// real failure, never `.None` or `.Not_Open`.
link_abort :: proc(l: ^Link, err: ws.Client_Error) {
    assert(l != nil, "link_abort needs a link")

    ws.client_abort(&l.sock, err)
}

// Release the link's storage. Call once, after it has closed (post on_closed/on_error).
link_destroy :: proc(l: ^Link) {
    assert(l != nil, "link_destroy needs a link")

    ws.client_destroy(&l.sock)
    virtual.arena_destroy(&l.scratch)
    l^ = {}
}

// Recover the link from a socket callback's user_data.
@(private = "file")
link_from_socket :: proc(sock: ^ws.Client) -> ^Link {
    assert(sock != nil && sock.user_data != nil, "link callback lost its link")

    l := (^Link)(sock.user_data)
    assert(&l.sock == sock, "link callback crossed link ownership")

    return l
}

@(private = "file")
link_on_open :: proc(sock: ^ws.Client) {
    l := link_from_socket(sock)
    assert(!l.attached, "link opened with a peer already attached")

    // The client's /connect link is spliced onto the parked daemon the instant it opens —
    // no peer_attached CONTROL arrives, so it is attached from open and may seal at once.
    // The daemon's /link waits for peer_attached to flip `attached`.
    if l.route == .Connect {
        l.attached = true
    }

    log.debugf("relay link: parked on %s", "/link" if l.route == .Link else "/connect")

    if l.cbs.on_parked != nil {
        l.cbs.on_parked(l)
    }
}

@(private = "file")
link_on_message :: proc(sock: ^ws.Client, kind: ws.Message_Kind, data: []byte) {
    l := link_from_socket(sock)

    temp := virtual.arena_temp_begin(&l.scratch)
    defer virtual.arena_temp_end(temp)

    action, channel, payload, reason, err := link_dispatch(
        l.route,
        kind,
        data,
        l.attached,
        virtual.arena_allocator(&l.scratch),
    )
    l.channel = channel

    switch action {
    case .Peer_Attached:
        l.peer_count += 1
        l.attached = true

        if l.cbs.on_peer_attached != nil {
            l.cbs.on_peer_attached(l)
        }

    case .Peer_Gone:
        // Clamp: an untrusted relay could send peer_gone with no matching peer_attached.
        l.peer_count = max(0, l.peer_count - 1)
        l.attached = l.peer_count > 0

        if l.cbs.on_peer_gone != nil {
            l.cbs.on_peer_gone(l, reason)
        }

    case .Sealed:
        if l.cbs.on_sealed != nil {
            l.cbs.on_sealed(l, payload)
        }

    case .Drop:
        log.debug("relay link: SEALED before peer_attached, dropping")

    case .Fail:
        log.warnf("relay link: closing on bad frame: %v", err)
        _ = ws.client_close(&l.sock, .Unsupported_Data if err == .Text else .Protocol_Error)
    }
}

@(private = "file")
link_on_close :: proc(sock: ^ws.Client, code: ws.Close_Code) {
    l := link_from_socket(sock)

    if l.cbs.on_closed != nil {
        l.cbs.on_closed(l, code)
    }
}

@(private = "file")
link_on_error :: proc(sock: ^ws.Client, err: ws.Client_Error) {
    l := link_from_socket(sock)

    if l.cbs.on_error != nil {
        l.cbs.on_error(l, err)
    }
}
