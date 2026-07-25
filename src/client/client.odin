package client

import "core:mem"
import "core:nbio"
import "core:strings"
import ws "libs:websocket"
import wire "src:wire"

// Ceiling on concurrently outstanding requests. Bounds `pending` growth against a
// peer that never answers; a send past the cap fails with `.Too_Many_Pending`.
MAX_PENDING_REQUESTS :: 256

// Driver protocol exchange: send `client.hello`, then await the server `hello`.
Protocol_State :: enum {
    // TCP dial and WebSocket upgrade in flight; nothing sent yet.
    Connecting,

    // `client.hello` sent; waiting for the server `hello`.
    Awaiting_Hello,

    // `hello` accepted; requests may be sent and frames are routed.
    Ready,

    // A close has been initiated; waiting for the transport's terminal callback.
    Closing,

    // Fully closed; the terminal callback has fired.
    Closed,
}

// Protocol-layer error. A transport failure is surfaced as `.Ws_Error`; read the
// underlying code with `c.ws_error`.
Protocol_Error :: enum {
    // No error.
    None,

    // A transport-level failure; the specific `ws.Client_Error` is on `ws_error`.
    Ws_Error,

    // The server `hello` failed to decode or validate.
    Bad_Hello,

    // A `hello` frame arrived after the connection was already Ready.
    Unexpected_Hello,

    // A success `response` referenced a request id that is not pending.
    Unknown_Response,

    // A server frame failed to decode or validate, or held trailing bytes.
    Decode_Failed,

    // A binary WebSocket frame arrived; the v1 protocol carries only text frames.
    Bad_Frame,

    // Driver-owned protocol state could not be allocated.
    Out_Of_Memory,

    // The request id space (`wire.MAX_REQUEST_ID`) is exhausted.
    Request_Id_Exhausted,

    // `pending` is at `MAX_PENDING_REQUESTS`; back off before sending more.
    Too_Many_Pending,

    // A send was attempted before the connection reached Ready.
    Not_Ready,
}

// Event sink. Any field may be nil. The `wire.Response`/`wire.Broadcast`/`name`
// arguments borrow frame memory valid ONLY for the call (see LIFETIME CONTRACT).
Client_Callbacks :: struct {
    // Fired once the server `hello` is accepted and the driver reaches Ready.
    on_ready:             proc(c: ^Client),

    // Fired for each typed response or error. `resp` is borrowed for this call only.
    on_response:          proc(c: ^Client, resp: wire.Response),

    // Fired for each known broadcast. `bc` is borrowed for this call only; retain it
    // with `wire.broadcast_clone` into your own allocator.
    on_broadcast:         proc(c: ^Client, bc: wire.Broadcast),

    // Fired for a broadcast whose name this build does not recognize. The payload is
    // never decoded; `name` is borrowed for this call only.
    on_unknown_broadcast: proc(c: ^Client, name: string),

    // Fired once at `.Closed` with the reported (or synthesized) close code. Terminal.
    on_close:             proc(c: ^Client, code: ws.Close_Code),

    // Fired on a driver or transport error; see the TERMINAL CONTRACT for which are terminal.
    on_error:             proc(c: ^Client, err: Protocol_Error),
}

// One daemon connection past the transport handshake. Owns `pending`, the
// `daemon_version` clone, `scratch`, and the outbound `hello_frame`; borrows `loop`.
Client :: struct {
    // @private
    // Underlying WebSocket transport, driven through `ws.client_*`. The internal
    // transport callbacks recover this `^Client` via `wsc.user_data`. Named
    // `sock` (not `ws`) to avoid colliding with the `ws` import alias.
    sock:             ws.Client,

    // @private
    // Borrowed event loop the transport submits ops to; never run here.
    loop:             ^nbio.Event_Loop,

    // @private
    // Backs `pending`, the `daemon_version` clone, `scratch`, and `hello_frame`. Must
    // outlive the client.
    allocator:        mem.Allocator,

    // Protocol exchange phase.
    state:            Protocol_State,

    // @private
    // Next client-generated request id; starts at 1, increments per accepted send.
    next_request_id:  wire.Request_Id,

    // @private
    // Outstanding request method keyed by id, used to type each response result.
    // Stores only the `Method_Name` enum — no borrowed frame data.
    pending:          map[wire.Request_Id]wire.Method_Name,

    // @private
    // Per-message decode scratch, `free_all`'d after each message. A frame's borrowed
    // strings and slices live here only for the callback that consumes them.
    scratch:          mem.Dynamic_Arena,

    // @private
    // Owned, pre-built `client.hello` bytes; sent and freed in the transport `on_open`.
    // Nil once sent, or if the connection never opened.
    hello_frame:      []byte,

    // Retained protocol version from the server `hello` (value copy).
    protocol:         u32,

    // Retained session-index revision from the server `hello` (value copy).
    session_revision: wire.Session_Revision,

    // Retained cron-index revision from the server `hello` (value copy).
    cron_revision:    wire.Cron_Revision,

    // Retained catalog content hash from the server `hello` (fixed array, value copy).
    catalog_rev:      wire.Catalog_Rev,

    // The only retained hello string: an owned `strings.clone` into `allocator`, freed
    // by `client_destroy`. Never the borrowed frame slice.
    daemon_version:   string,

    // Last transport error, latched before an `on_error(.Ws_Error)`; read via
    // `c.ws_error`.
    ws_error:         ws.Client_Error,

    // @private
    // Event sink; any field may be nil.
    cbs:              Client_Callbacks,

    // Opaque application pointer, reachable from the callbacks as `c.user_data`.
    user_data:        rawptr,
}

// Initialize `c`, build the `client.hello`, and begin connecting on `loop`. The
// transport handshake runs asynchronously; readiness is reported via `on_ready`.
// Only a synchronous setup failure returns directly: `.Bad_Frame` for an invalid
// `client.hello` (name/version bounds), or `.Ws_Error` for a transport setup failure
// (the `ws.Client_Error` is on `ws_error`). A direct failure rolls back all owned
// state, so the caller must not `client_destroy` after one.
client_open :: proc(
    c: ^Client,
    loop: ^nbio.Event_Loop,
    options: ws.Options,
    name: string,
    version: string,
    cbs: Client_Callbacks,
    user_data: rawptr = nil,
    allocator := context.allocator,
) -> Protocol_Error {
    c^ = {}
    c.loop = loop
    c.allocator = allocator
    c.state = .Connecting
    c.next_request_id = 1
    c.pending = make(map[wire.Request_Id]wire.Method_Name, allocator)
    mem.dynamic_arena_init(&c.scratch, allocator, allocator)
    c.cbs = cbs
    c.user_data = user_data

    // Build and validate the outbound hello now so a bad identity fails fast; the
    // owned bytes are sent from the transport `on_open`.
    hello := wire.client_hello_build({name = name, version = version})
    if wire.client_hello_validate(hello) != .None {
        client_free_owned(c)
        return .Bad_Frame
    }

    e: wire.Emitter
    wire.emitter_init(&e, allocator)
    wire.client_hello_emit(&e, hello)
    payload := wire.to_string(&e)
    c.hello_frame = make([]byte, len(payload), allocator)
    copy(c.hello_frame, payload)
    wire.emitter_destroy(&e)

    callbacks := ws.Callbacks {
        on_open    = ws_on_open,
        on_message = ws_on_message,
        on_close   = ws_on_close,
        on_error   = ws_on_error,
    }
    werr := ws.client_connect(&c.sock, loop, options, callbacks, c, allocator)
    if werr != .None {
        c.ws_error = werr
        client_free_owned(c)
        return .Ws_Error
    }

    return .None
}

// Send a typed request and remember its method so the matching response can be typed.
// Requires Ready. `pending[id]` is recorded and `next_request_id` advanced only after
// the transport accepts the frame, so a failed send leaves no half-built state.
client_send_request :: proc(
    c: ^Client,
    method: wire.Method_Name,
    params: wire.Request_Params,
) -> (
    wire.Request_Id,
    Protocol_Error,
) {
    if c.state != .Ready {
        return 0, .Not_Ready
    }

    if u64(c.next_request_id) > wire.MAX_REQUEST_ID {
        return 0, .Request_Id_Exhausted
    }

    if len(c.pending) >= MAX_PENDING_REQUESTS {
        return 0, .Too_Many_Pending
    }

    id := c.next_request_id
    req := wire.request_build(id, method, params)
    if wire.request_validate(req) != .None {
        return 0, .Bad_Frame
    }

    e: wire.Emitter
    wire.emitter_init(&e, c.allocator)
    defer wire.emitter_destroy(&e)
    wire.request_emit(&e, req)

    serr := ws.client_send_text(&c.sock, transmute([]byte)wire.to_string(&e))
    if serr != .None {
        c.ws_error = serr
        return 0, .Ws_Error
    }

    // Only now that the frame is queued: correlate the id and advance the counter.
    c.pending[id] = method
    c.next_request_id += 1

    return id, .None
}

// Route one server text frame to the sink. The pure core of the driver: it performs
// no transport operations and returns the outcome so the caller decides whether to
// close. `scratch` is `free_all`'d before returning, so every value handed to a
// callback is valid only for that callback (see LIFETIME CONTRACT).
client_handle_text :: proc(c: ^Client, data: []byte) -> Protocol_Error {
    sa := mem.dynamic_arena_allocator(&c.scratch)
    defer free_all(sa)

    // Route from the streaming header without materializing the (possibly large) body.
    header, herr := wire.server_frame_header_stream(string(data), sa)
    if herr != .None {
        return .Decode_Failed
    }

    switch header.kind {
    case .Hello:
        // A second hello after the connection is Ready is a protocol error.
        return .Unexpected_Hello

    case .Response, .Error:
        method, ok := c.pending[header.id]

        // A success result needs the pending method to type it; an unknown id can't be
        // decoded. Error objects are method-agnostic, so they are delivered regardless.
        if !ok && header.kind == .Response {
            if c.cbs.on_error != nil {
                c.cbs.on_error(c, .Unknown_Response)
            }

            return .Unknown_Response
        }

        if ok {
            delete_key(&c.pending, header.id)
        }

        // Fresh decoder over the whole frame: `response_from_reader` opens the object
        // itself. A success result is typed by the pending method, never the payload.
        d := wire.decoder_init(string(data), sa)
        resp, derr := wire.response_from_reader(method, &d)
        if derr != .None {
            return .Decode_Failed
        }

        if wire.dec_finish(&d) != .None {
            return .Decode_Failed
        }

        if wire.response_validate(resp) != .None {
            return .Decode_Failed
        }

        if c.cbs.on_response != nil {
            c.cbs.on_response(c, resp)
        }

        return .None

    case .Broadcast:
        name, known := wire.broadcast_name_from_wire(header.name)
        if !known {
            // Route an unknown name from the header without reading its payload; trailing
            // bytes are therefore not rejected here as they are on the decoded paths.
            if c.cbs.on_unknown_broadcast != nil {
                c.cbs.on_unknown_broadcast(c, header.name)
            }

            return .None
        }

        d := wire.decoder_init(string(data), sa)
        bc, derr := wire.broadcast_from_reader(&d)
        if derr != .None {
            return .Decode_Failed
        }

        if wire.dec_finish(&d) != .None {
            return .Decode_Failed
        }

        if wire.broadcast_validate(bc) != .None {
            return .Decode_Failed
        }

        if c.cbs.on_broadcast != nil {
            c.cbs.on_broadcast(c, bc)
        }

        return .None
    }

    return .None
}

// Decode, validate, and retain the server `hello`, then advance to Ready and fire
// `on_ready`. The transport callback closes on any returned error. Called only
// while Awaiting_Hello.
client_handle_hello :: proc(c: ^Client, data: []byte) -> Protocol_Error {
    assert(c != nil && c.state == .Awaiting_Hello, "hello handled outside Awaiting_Hello")

    sa := mem.dynamic_arena_allocator(&c.scratch)
    defer free_all(sa)

    d := wire.decoder_init(string(data), sa)
    hello, derr := wire.server_hello_from_reader(&d)
    if derr != .None {
        return .Bad_Hello
    }

    if wire.dec_finish(&d) != .None {
        return .Bad_Hello
    }

    if wire.server_hello_validate(hello) != .None {
        return .Bad_Hello
    }

    // Retain the scalar snapshot by value; clone the one borrowed string we keep, so
    // nothing survives the scratch `free_all` as a dangling frame borrow.
    assert(c.daemon_version == "", "daemon version retained twice")
    daemon_version, aerr := strings.clone(hello.daemon.version, c.allocator)
    if aerr != nil {
        return .Out_Of_Memory
    }

    c.protocol = hello.protocol
    c.session_revision = hello.session_revision
    c.cron_revision = hello.cron_revision
    c.catalog_rev = hello.catalog_rev
    c.daemon_version = daemon_version
    c.state = .Ready

    if c.cbs.on_ready != nil {
        c.cbs.on_ready(c)
    }

    return .None
}

// Begin a graceful close with `code`. The terminal `on_close` fires once the close
// completes. No-op if already closing or closed.
client_close :: proc(c: ^Client, code := ws.Close_Code.Normal_Closure) {
    assert(c != nil, "client_close needs a client")

    if c.state == .Closing || c.state == .Closed {
        return
    }

    close_err := ws.client_close(&c.sock, code)
    if close_err != .None {
        assert(close_err != .Not_Open, "protocol and transport close states diverged")
        c.state = .Closing
        ws.client_abort(&c.sock, close_err)
        return
    }

    c.state = .Closing
}

// Release all driver-owned resources and the transport. Call once `c.state`
// is `.Closed` (after `on_close`, or after a transport `on_error`). Does not touch the
// borrowed loop.
client_destroy :: proc(c: ^Client) {
    client_free_owned(c)
    ws.client_destroy(&c.sock)
}


// Report a fatal driver error and begin a transport close. `on_error` fires now (at
// `.Closing`); the terminal `on_close` follows when the close completes. Idempotent.
client_abort :: proc(c: ^Client, err: Protocol_Error) {
    if c.state == .Closing || c.state == .Closed {
        return
    }

    c.state = .Closing

    if c.cbs.on_error != nil {
        c.cbs.on_error(c, err)
    }

    close_err := ws.client_close(&c.sock, .Protocol_Error)
    if close_err != .None {
        assert(close_err != .Not_Open, "protocol and transport close states diverged")
        ws.client_abort(&c.sock, close_err)
    }
}

// Free the driver-owned state allocated by `client_open`. Used both to roll back a
// failed open and by `client_destroy`.
client_free_owned :: proc(c: ^Client) {
    delete(c.pending)
    mem.dynamic_arena_destroy(&c.scratch)

    if c.hello_frame != nil {
        delete(c.hello_frame, c.allocator)
        c.hello_frame = nil
    }

    if len(c.daemon_version) > 0 {
        delete(c.daemon_version, c.allocator)
        c.daemon_version = ""
    }
}

// --- internal transport callbacks ---
//
// Each recovers the owning `^Client` from the transport's user data (proc literals
// cannot capture). Control frames (Ping/Pong/Close) are handled inside the transport
// and never surface here.

// Transport is Open: advance to Awaiting_Hello and send the pre-built `client.hello`.
ws_on_open :: proc(wsc: ^ws.Client) {
    assert(wsc != nil && wsc.user_data != nil, "transport open lost its protocol client")

    c := (^Client)(wsc.user_data)
    assert(&c.sock == wsc && c.state == .Connecting, "transport open crossed client ownership")
    c.state = .Awaiting_Hello

    send_err := ws.client_send_text(&c.sock, c.hello_frame)
    delete(c.hello_frame, c.allocator)
    c.hello_frame = nil
    if send_err != .None {
        c.state = .Closing
        ws.client_abort(&c.sock, send_err)
    }
}

// One complete transport message. Only text frames carry protocol data.
ws_on_message :: proc(wsc: ^ws.Client, kind: ws.Message_Kind, data: []byte) {
    c := (^Client)(wsc.user_data)

    // Frames only matter while awaiting the hello or routing; ignore anything that
    // arrives while connecting, closing, or closed.
    if c.state != .Awaiting_Hello && c.state != .Ready {
        return
    }

    switch kind {
    case .Text:
        if c.state == .Awaiting_Hello {
            if err := client_handle_hello(c, data); err != .None {
                client_abort(c, err)
            }
        } else {
            err := client_handle_text(c, data)

            // A per-frame diagnostic keeps the connection; a protocol error closes it.
            #partial switch err {
            case .Unexpected_Hello, .Decode_Failed:
                client_abort(c, err)
            }
        }

    case .Binary:
        client_abort(c, .Bad_Frame)

    case .Ping, .Pong, .Close:
    // Handled by the transport; never delivered here.
    }
}

// Transport reached Closed via a graceful or peer close: fire the terminal `on_close`.
ws_on_close :: proc(wsc: ^ws.Client, code: ws.Close_Code) {
    c := (^Client)(wsc.user_data)
    c.state = .Closed

    if c.cbs.on_close != nil {
        c.cbs.on_close(c, code)
    }
}

// Transport failed terminally: latch the code and surface it as `.Ws_Error`. The
// connection is Closed; no `on_close` follows.
ws_on_error :: proc(wsc: ^ws.Client, err: ws.Client_Error) {
    c := (^Client)(wsc.user_data)
    c.state = .Closed
    c.ws_error = err

    if c.cbs.on_error != nil {
        c.cbs.on_error(c, .Ws_Error)
    }
}
