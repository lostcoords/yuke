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
    sock:      ws.Client,

    // @private
    // Borrowed event loop the socket runs on.
    loop:      ^nbio.Event_Loop,

    // @private
    // Backs the scratch arena and outlives the link.
    allocator: mem.Allocator,

    // @private
    // Owner callbacks.
    cbs:       Link_Callbacks,

    // @private
    // Which route this link dialed.
    route:     Link_Route,

    // @private
    // Whether a peer is currently spliced in. A SEALED frame is only valid while true.
    attached:  bool,

    // @private
    // Scratch for one inbound CONTROL decode, reset per message.
    scratch:   virtual.Arena,

    // Owner pointer, set by `link_dial` and recovered by the owner's callbacks. Borrowed.
    user_data: rawptr,
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
// by type. On `.Sealed` the returned payload aliases `msg`; on `.Peer_Gone` `reason` is
// allocated from `allocator`. `err` is set only for `.Fail`, naming why the link closes.
link_dispatch :: proc(
    kind: ws.Message_Kind,
    msg: []u8,
    attached: bool,
    allocator := context.allocator,
) -> (
    action: Link_Action,
    payload: []u8,
    reason: string,
    err: Error,
) {
    if kind != .Binary {
        // The socket answers ping/pong/close itself, so only a text data frame reaches
        // here — and the envelope rides only binary.
        return .Fail, nil, "", .Text
    }

    frame, ferr := frame_decode(msg)
    if ferr != .None {
        return .Fail, nil, "", ferr
    }

    switch frame.type {
    case .Sealed:
        if !attached {
            return .Drop, nil, "", .None
        }

        return .Sealed, frame.payload, "", .None

    case .Control:
        ctrl, cerr := control_decode(frame.payload, allocator)
        if cerr != .None {
            return .Fail, nil, "", cerr
        }

        switch ctrl.kind {
        case .Peer_Attached:
            return .Peer_Attached, nil, "", .None

        case .Peer_Gone:
            return .Peer_Gone, nil, ctrl.reason, .None
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
) -> ws.Client_Error {
    assert(l != nil, "link_dial needs link storage")
    assert(loop != nil, "link_dial needs an event loop")

    l^ = {}
    l.loop = loop
    l.allocator = allocator
    l.cbs = cbs
    l.route = route
    l.user_data = user_data

    if virtual.arena_init_growing(&l.scratch) != nil {
        return .Out_Of_Memory
    }

    // client_connect clones the path, so building it in temp storage is safe.
    base := "/link" if route == .Link else "/connect"
    encoded := net.percent_encode(ticket, context.temp_allocator)
    path := strings.concatenate({base, "?ticket=", encoded}, context.temp_allocator)

    options := ws.Options {
        scheme = endpoint.scheme,
        host   = endpoint.host,
        port   = endpoint.port,
        path   = path,
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

// Whether the link's socket is Open — the liveness a bridged connection reports.
link_open :: proc(l: ^Link) -> bool {
    assert(l != nil, "link_open needs a link")

    return l.sock.state == .Open
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

    action, payload, reason, err := link_dispatch(kind, data, l.attached, virtual.arena_allocator(&l.scratch))

    switch action {
    case .Peer_Attached:
        l.attached = true

        if l.cbs.on_peer_attached != nil {
            l.cbs.on_peer_attached(l)
        }

    case .Peer_Gone:
        l.attached = false

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
