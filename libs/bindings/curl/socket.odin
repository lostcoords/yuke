package curl

import "core:c"
import "core:nbio"
import "core:sync"
import "core:time"

// Lifecycle of one connect-only socket: Created -> Connecting -> Connected or Failed,
// and Closed once `socket_destroy` has run. Both Connected and Failed are reported
// exactly once through `On_Connect`.
Socket_State :: enum {
    Created,
    Connecting,
    Connected,
    Failed,
    Closed,
}

// Fired exactly once when the dial finishes, successfully or not. Never fires after
// `socket_destroy`. `result.status` is always 0: a connect-only dial reads no response.
On_Connect :: #type proc(user: rawptr, result: Result)

// What to dial. Every field is copied during `socket_connect`.
Socket_Request :: struct {
    // Absolute URL whose scheme picks the transport: `https` connects and completes a
    // TLS handshake, `http` stops at TCP. Path and query are ignored — nothing is
    // requested. Must be nul-terminated.
    url:             cstring,

    // Time allowed for the connect, rounded up to whole seconds.
    connect_timeout: time.Duration,

    // PEM bundle to verify the peer against. Empty uses libcurl's own default store.
    ca_file:         cstring,
}

// A socket libcurl dialed with `Connect_Only`: it performs the TCP and, for `https`,
// the TLS handshake, then hands over raw `socket_send`/`socket_recv` on the established
// channel. Caller-allocated and address-pinned from `socket_connect` until
// `socket_destroy`, because the pump timer holds it by address.
//
// It carries its own multi handle rather than sharing a `Client`'s. Removing the easy
// handle from a multi destroys a connect-only connection, so the handle must stay added
// for the socket's whole life — and a connected socket needs no pumping at all, so the
// timer is dropped once the dial lands and an idle socket costs nothing on the loop.
Socket :: struct {
    // @private
    // Borrowed loop the dial's pump timer runs on; never run here.
    loop:     ^nbio.Event_Loop,

    // @private
    // This socket's own multi handle, holding `easy` until `socket_destroy`.
    multi:    ^Multi,

    // @private
    easy:     ^Easy,

    // @private
    // The dial's pump timer. Nil once the dial has landed, which is what keeps a
    // connected socket free.
    timer_op: ^nbio.Operation,

    // @private
    cb:       On_Connect,

    // @private
    user:     rawptr,

    // @private
    // Set across every curl call region, so a callback cannot re-enter one.
    in_curl:  bool,

    // @private
    // `CURLOPT_ERRORBUFFER` storage; curl writes a NUL-terminated reason here.
    errbuf:   [ERROR_SIZE]byte,

    // Lifecycle, readable by callers that keep one across loop ticks.
    state:    Socket_State,
}

// Begins dialing `req` on `loop`. On `.None` exactly one `On_Connect` follows unless
// `socket_destroy` intervenes; on any other result nothing was registered and no
// callback ever fires.
socket_connect :: proc(
    s: ^Socket,
    loop: ^nbio.Event_Loop,
    req: Socket_Request,
    cb: On_Connect,
    user: rawptr = nil,
) -> Error {
    assert(s != nil, "socket_connect needs a socket")
    assert(loop != nil, "socket_connect needs an event loop")
    assert(s.state == .Created || s.state == .Closed, "socket_connect on a socket that is already dialing")

    if len(req.url) == 0 {
        return .Invalid_Request
    }

    sync.once_do(&global_init_once, global_init)

    if global_init_code != .Ok {
        return .Setup_Failed
    }

    s^ = {}
    s.loop = loop
    s.cb = cb
    s.user = user

    s.multi = c_multi_init()
    if s.multi == nil {
        return .Setup_Failed
    }

    s.easy = c_easy_init()
    if s.easy == nil {
        socket_release(s)
        return .Setup_Failed
    }

    if code := socket_configure(s, req); code != .Ok {
        socket_release(s)
        return .Out_Of_Memory if code == .Out_Of_Memory else .Setup_Failed
    }

    if c_multi_add_handle(s.multi, s.easy) != .Ok {
        socket_release(s)
        return .Setup_Failed
    }

    s.state = .Connecting
    s.timer_op = nbio.timeout_poly(multi_period(s.multi), s, socket_on_tick, loop)

    return .None
}

// The socket libcurl connected, for registering with an event loop. Valid only while
// the socket is Connected.
socket_handle :: proc(s: ^Socket) -> Socket_Handle {
    assert(s != nil, "socket_handle needs a socket")
    assert(s.state == .Connected, "socket_handle before the dial landed")

    handle, code := getinfo_socket(s.easy, .Active_Socket)
    assert(code == .Ok, "a connected socket has no active socket")
    assert(handle != SOCKET_BAD, "a connected socket reported no socket")

    return handle
}

// Sends over the established channel, encrypting first when the dial used `https`.
// Reports `.Again` when the socket cannot take bytes right now, in which case nothing
// was sent and the caller must wait for writability and retry.
socket_send :: proc(s: ^Socket, data: []byte) -> (sent: int, code: Code) {
    assert(s != nil, "socket_send needs a socket")
    assert(s.state == .Connected, "socket_send before the dial landed")

    if len(data) == 0 {
        return 0, .Ok
    }

    out: c.size_t
    code = c_easy_send(s.easy, raw_data(data), c.size_t(len(data)), &out)

    return int(out), code
}

// Receives from the established channel, decrypting first when the dial used `https`.
// Reports `.Again` once no buffered plaintext is left: TLS records arrive whole, so a
// reader must drain to `.Again` before waiting on readability again or it can park with
// data already decrypted and in hand.
socket_recv :: proc(s: ^Socket, buf: []byte) -> (received: int, code: Code) {
    assert(s != nil, "socket_recv needs a socket")
    assert(s.state == .Connected, "socket_recv before the dial landed")
    assert(len(buf) > 0, "socket_recv needs somewhere to put the bytes")

    out: c.size_t
    code = c_easy_recv(s.easy, raw_data(buf), c.size_t(len(buf)), &out)

    return int(out), code
}

// Closes the connection and releases everything the socket owns. Final and silent: a
// dial still in flight is abandoned and its `On_Connect` never fires, mirroring
// `nbio.remove`. Safe on a socket that never connected.
socket_destroy :: proc(s: ^Socket) {
    assert(s != nil, "socket_destroy needs a socket")
    assert(!s.in_curl, "socket_destroy must not run inside a curl callback")

    if s.timer_op != nil {
        nbio.remove(s.timer_op)
        s.timer_op = nil
    }

    socket_release(s)
    s.state = .Closed
}

// Releases the curl handles. Removing the easy handle from the multi is what closes the
// connection; it is also required before the multi handle can be cleaned up.
@(private)
socket_release :: proc(s: ^Socket) {
    assert(s != nil, "socket_release needs a socket")
    assert(!s.in_curl, "socket_release must not run inside a curl callback")

    if s.easy != nil {
        if s.multi != nil {
            _ = c_multi_remove_handle(s.multi, s.easy)
        }

        c_easy_cleanup(s.easy)
        s.easy = nil
    }

    if s.multi != nil {
        _ = c_multi_cleanup(s.multi)
        s.multi = nil
    }
}

@(private)
socket_configure :: proc(s: ^Socket, req: Socket_Request) -> Code {
    assert(s != nil && s.easy != nil, "socket_configure needs an easy handle")

    e := s.easy

    setopt_str(e, .Url, req.url) or_return
    setopt_ptr(e, .Error_Buffer, &s.errbuf[0]) or_return

    // Connect and hand the channel over rather than making a request.
    setopt_long(e, .Connect_Only, 1) or_return

    // ALPN still runs during the TLS handshake, and a server that picks h2 there can
    // refuse the HTTP/1.1 request the caller then writes — a WebSocket upgrade is
    // HTTP/1.1 only. Advertising 1.1 alone makes the server agree to it up front.
    setopt_long(e, .Http_Version, HTTP_VERSION_1_1) or_return

    // libcurl otherwise uses signals and alarm() for its own DNS timeouts, which
    // is unsafe in a process with worker threads.
    setopt_long(e, .No_Signal, 1) or_return

    setopt_long(e, .Connect_Timeout, seconds_ceil(req.connect_timeout, DEFAULT_CONNECT_TIMEOUT)) or_return

    if len(req.ca_file) > 0 {
        setopt_str(e, .Ca_Info, req.ca_file) or_return
    }

    return .Ok
}

// Advances the dial. Re-arms itself until curl reports the handle done, then stops for
// good: from that point the socket is driven by readiness, not by this timer.
@(private)
socket_on_tick :: proc(op: ^nbio.Operation, s: ^Socket) {
    assert(s != nil, "the dial tick needs a socket")
    assert(s.timer_op == op, "the dial tick fired for an operation the socket does not own")
    assert(s.state == .Connecting, "the dial tick fired outside a dial")
    assert(!s.in_curl, "the dial tick re-entered the curl region")

    s.timer_op = nil
    s.in_curl = true

    multi_perform_all(s.multi)

    done := false
    result: Code

    for {
        msg, _ := multi_info_read(s.multi)
        if msg == nil {
            break
        }

        if msg.kind != .Done {
            continue
        }

        assert(msg.easy == s.easy, "multi_info_read reported a handle the socket does not own")
        done = true
        result = msg.data.result
    }

    s.in_curl = false

    // Everything below leaves the curl region first: `On_Connect` may destroy the
    // socket, and libcurl forbids touching the multi handle from inside a callback.
    if !done {
        s.timer_op = nbio.timeout_poly(multi_period(s.multi), s, socket_on_tick, s.loop)
        return
    }

    s.state = .Connected if result == .Ok else .Failed

    if s.cb != nil {
        s.cb(s.user, Result{code = result, message = curl_message(&s.errbuf, result), status = 0})
    }
}
