package client

import "core:mem"
import "core:strings"
import ws "libs:websocket"
import wire "src:wire"

// Ceiling on concurrently outstanding requests. Bounds `pending` growth against a
// peer that never answers; a send past the cap fails with `.Too_Many_Pending`.
MAX_PENDING_REQUESTS :: 256

// Id the driver's opening `initialize` request claims; the counter starts past it.
INITIALIZE_REQUEST_ID :: 1

// Driver protocol exchange: send `initialize`, then await its response.
Protocol_State :: enum {
    // The transport is connecting; nothing sent yet.
    Connecting,

    // `initialize` sent; waiting for its response.
    Awaiting_Initialize,

    // `initialize` result accepted; requests may be sent and frames are routed.
    Ready,

    // A close has been initiated; waiting for the transport's terminal callback.
    Closing,

    // Fully closed; the terminal callback has fired.
    Closed,
}

// Protocol-layer error. A transport failure is surfaced as `.Transport_Failed`; read
// the underlying reason with `c.transport_error`.
Protocol_Error :: enum {
    // No error.
    None,

    // A transport-level failure; the specific `ws.Client_Error` is on `transport_error`.
    Transport_Failed,

    // The `initialize` result failed to decode or validate.
    Bad_Initialize,

    // A success `response` referenced a request id that is not pending.
    Unknown_Response,

    // A server frame failed to decode or validate, or held trailing bytes.
    Decode_Failed,

    // A binary frame arrived; the v1 protocol carries only text frames.
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

// Fired exactly once for one request's response. `resp` borrows frame memory valid only
// for the call.
Response_Proc :: proc(c: ^Client, resp: wire.Response, user_data: rawptr)

// One outstanding request. Holds no borrowed frame data.
Pending_Request :: struct {
    // Method the request was sent with; types its success result on decode.
    method:      wire.Method_Name,

    // Completion for this request's response. May be nil to discard it.
    on_response: Response_Proc,

    // Opaque pointer handed back to `on_response`.
    user_data:   rawptr,
}

// Event sink for connection-wide events. Any field may be nil. The `wire.Initialize_Result`,
// `wire.Notification`, and `method` arguments borrow frame memory valid ONLY for the call
// (see LIFETIME CONTRACT). Responses are not routed here; they reach their request's
// `Response_Proc`.
Client_Callbacks :: struct {
    // Fired once when the `initialize` result is accepted and the driver reaches Ready.
    // `hello` is borrowed.
    on_ready:             proc(c: ^Client, hello: wire.Initialize_Result),

    // Fired for each known broadcast. `bc` is borrowed; retain with `wire.notification_clone`.
    on_broadcast:         proc(c: ^Client, bc: wire.Notification),

    // Fired for a broadcast this build does not recognize. The payload is not decoded;
    // `method` is borrowed.
    on_unknown_broadcast: proc(c: ^Client, method: string),

    // Fired once at `.Closed` with the reported (or synthesized) close code. Terminal.
    on_close:             proc(c: ^Client, code: Close_Code),

    // Fired on a driver or transport error; see the TERMINAL CONTRACT for which are terminal.
    on_error:             proc(c: ^Client, err: Protocol_Error),
}

// One daemon connection past the transport handshake. Owns `pending`, the
// `daemon_version` clone, `scratch`, the outbound `initialize_frame`, and — from
// `client_open` onward — the transport.
Client :: struct {
    // @private
    // The pipe this connection runs over, owned from `client_open` until
    // `client_destroy`.
    transport:        Transport,

    // @private
    // Backs `pending`, the `daemon_version` clone, `scratch`, and `initialize_frame`. Must
    // outlive the client.
    allocator:        mem.Allocator,
    state:            Protocol_State,

    // @private
    // Next client-generated request id; starts at 1, increments per accepted send.
    // The driver only ever originates numbers, so the counter is numeric and the
    // wire token is formatted per send.
    next_request_id:  u64,

    // @private
    // Outstanding requests keyed by id: the method that types each response result,
    // plus the completion that receives it. Entries still outstanding when the
    // connection closes or errors are dropped, never completed — the terminal
    // `on_close`/`on_error` is the one signal to reclaim their `user_data`.
    pending:          map[u64]Pending_Request,

    // @private
    // Per-message decode scratch, `free_all`'d after each message. A frame's borrowed
    // strings and slices live here only for the callback that consumes them.
    scratch:          mem.Dynamic_Arena,

    // @private
    // Owned, pre-built `initialize` request bytes; sent and freed by `transport_on_open`.
    // Nil once sent, or if the connection never opened.
    initialize_frame: []byte,

    // Retained protocol version from the `initialize` result (value copy).
    protocol:         u32,

    // Retained session-index revision from the `initialize` result (value copy).
    session_revision: wire.Session_Revision,

    // Retained cron-index revision from the `initialize` result (value copy).
    cron_revision:    wire.Cron_Revision,

    // Retained catalog content hash from the `initialize` result (fixed array, value copy).
    catalog_rev:      wire.Catalog_Rev,

    // Optional daemon surfaces advertised by the `initialize` result. Names this build
    // does not know were already dropped by the tolerant decode.
    capabilities:     bit_set[wire.Capability],

    // The only retained string from the `initialize` result: an owned `strings.clone`
    // into `allocator`, freed by `client_destroy`. Never the borrowed frame slice.
    daemon_version:   string,

    // Last transport failure, latched before an `on_error(.Transport_Failed)`.
    transport_error:  ws.Client_Error,

    // @private
    // Outcome of the `initialize` completion, which cannot return one. Consumed by
    // `client_handle_text` on the frame that carried it.
    initialize_error: Protocol_Error,

    // @private
    cbs:              Client_Callbacks,

    // Opaque application pointer, reachable from the callbacks as `c.user_data`.
    user_data:        rawptr,
}

// Begin connecting over `transport`, whose ownership this takes; readiness arrives via
// `on_ready`. Only setup failures return directly — `.Bad_Frame` for an invalid client
// identity, `.Transport_Failed` for the transport — and each rolls back all owned state
// including the transport, so the caller must not `client_destroy` after one.
client_open :: proc(
    c: ^Client,
    transport: Transport,
    name: string,
    version: string,
    cbs: Client_Callbacks,
    user_data: rawptr = nil,
    allocator := context.allocator,
) -> Protocol_Error {
    assert(
        transport.open != nil &&
        transport.send_text != nil &&
        transport.close != nil &&
        transport.abort != nil &&
        transport.destroy != nil,
        "client_open needs a complete transport",
    )

    c^ = {}
    c.transport = transport
    c.allocator = allocator
    c.state = .Connecting
    c.pending = make(map[u64]Pending_Request, allocator)
    mem.dynamic_arena_init(&c.scratch, allocator, allocator)
    c.cbs = cbs
    c.user_data = user_data

    // Build and validate the outbound `initialize` now so a bad identity fails fast;
    // the owned bytes are sent by `transport_on_open`. It claims id 1, so the
    // counter starts past it.
    id_buf: [20]u8
    init := wire.request_build(
        wire.req_id(INITIALIZE_REQUEST_ID, id_buf[:]),
        .Initialize,
        wire.initialize_params_build({name = name, version = version}),
    )
    if wire.request_validate(init) != .None {
        client_destroy(c)
        return .Bad_Frame
    }

    c.next_request_id = INITIALIZE_REQUEST_ID + 1

    e, ok := wire.request_encode(init, allocator)
    defer wire.emitter_destroy(&e)
    if !ok {
        client_destroy(c)
        return .Out_Of_Memory
    }

    payload := wire.to_string(&e)
    c.initialize_frame = make([]byte, len(payload), allocator)
    copy(c.initialize_frame, payload)

    terr := transport->open(c)
    if terr != .None {
        c.transport_error = terr
        client_destroy(c)
        return .Transport_Failed
    }

    return .None
}

// Send a typed request and register the completion its response routes to. Requires
// Ready. `on_response` fires exactly once, or may be nil to discard the response, which
// is decoded and validated either way. A failed send leaves no half-built state.
client_send_request :: proc(
    c: ^Client,
    method: wire.Method_Name,
    params: wire.Request_Params,
    on_response: Response_Proc,
    user_data: rawptr = nil,
) -> (
    u64,
    Protocol_Error,
) {
    assert(c != nil, "client_send_request needs a client")

    if c.state != .Ready {
        return 0, .Not_Ready
    }

    if c.next_request_id > wire.MAX_REQUEST_ID {
        return 0, .Request_Id_Exhausted
    }

    if len(c.pending) >= MAX_PENDING_REQUESTS {
        return 0, .Too_Many_Pending
    }

    id := c.next_request_id
    id_buf: [20]u8
    req := wire.request_build(wire.req_id(id, id_buf[:]), method, params)
    if wire.request_validate(req) != .None {
        return 0, .Bad_Frame
    }

    e, _ := wire.request_encode(req, c.allocator)
    defer wire.emitter_destroy(&e)

    serr := c.transport->send_text(transmute([]byte)wire.to_string(&e))
    if serr != .None {
        c.transport_error = serr
        return 0, .Transport_Failed
    }

    // Correlate and advance only once the frame is queued.
    assert(id not_in c.pending, "request id reused while still outstanding")
    c.pending[id] = {
        method      = method,
        on_response = on_response,
        user_data   = user_data,
    }
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
    case .Response, .Error:
        // The driver only originates numeric ids, so an echo that is not one cannot
        // correlate: the peer altered it.
        id, numeric := wire.req_id_to_u64(header.id)

        if !numeric {
            return .Decode_Failed
        }

        req, ok := c.pending[id]

        // A success result needs the pending method to type it; an unknown id can't be
        // decoded. Error objects are method-agnostic, so an uncorrelated one is still
        // decoded and validated — it simply has no completion to reach.
        if !ok && header.kind == .Response {
            if c.cbs.on_error != nil {
                c.cbs.on_error(c, .Unknown_Response)
            }

            return .Unknown_Response
        }

        // Consume the correlation before decoding: this response answers the request
        // exactly once, whether or not the frame turns out to be well-formed.
        if ok {
            delete_key(&c.pending, id)
        }

        // Fresh decoder over the whole frame: `response_from_reader` opens the object
        // itself. A success result is typed by the pending method, never the payload.
        d := wire.decoder_init(string(data), sa)
        resp, derr := wire.response_from_reader(req.method, &d)
        if derr != .None {
            return .Decode_Failed
        }

        if wire.dec_finish(&d) != .None {
            return .Decode_Failed
        }

        if wire.response_validate(resp) != .None {
            return .Decode_Failed
        }

        if req.on_response != nil {
            req.on_response(c, resp, req.user_data)
        }

        if c.initialize_error != .None {
            err := c.initialize_error
            c.initialize_error = .None

            return err
        }

        return .None

    case .Notification:
        // Nothing is pushed before the handshake completes.
        if c.state != .Ready {
            return .Bad_Initialize
        }

        _, known := wire.broadcast_name_from_wire(header.method)
        if !known {
            // Route an unknown method from the header without reading its payload;
            // trailing bytes are therefore not rejected here as they are on the
            // decoded paths.
            if c.cbs.on_unknown_broadcast != nil {
                c.cbs.on_unknown_broadcast(c, header.method)
            }

            return .None
        }

        d := wire.decoder_init(string(data), sa)
        bc, derr := wire.notification_from_reader(&d)
        if derr != .None {
            return .Decode_Failed
        }

        if wire.dec_finish(&d) != .None {
            return .Decode_Failed
        }

        if wire.notification_validate(bc) != .None {
            return .Decode_Failed
        }

        if c.cbs.on_broadcast != nil {
            c.cbs.on_broadcast(c, bc)
        }

        return .None
    }

    return .None
}

// Reach Ready from the `initialize` response. Registered as that request's
// completion, so decode and validation already happened on the shared path.
client_on_initialize_result :: proc(c: ^Client, resp: wire.Response, user_data: rawptr) {
    assert(c != nil && c.state == .Awaiting_Initialize, "initialize completed outside Awaiting_Initialize")

    ok, is_ok := resp.(wire.Response_Ok)

    if !is_ok {
        c.initialize_error = .Bad_Initialize
        return
    }

    hello, is_hello := ok.result.(wire.Initialize_Result)

    if !is_hello {
        c.initialize_error = .Bad_Initialize
        return
    }

    // Retain the scalar snapshot by value; clone the one borrowed string we keep, so
    // nothing survives the scratch `free_all` as a dangling frame borrow.
    assert(c.daemon_version == "", "daemon version retained twice")
    daemon_version, aerr := strings.clone(hello.daemon.version, c.allocator)
    if aerr != nil {
        c.initialize_error = .Out_Of_Memory
        return
    }

    c.protocol = hello.protocol
    c.session_revision = hello.session_revision
    c.cron_revision = hello.cron_revision
    c.catalog_rev = hello.catalog_rev
    c.capabilities = hello.capabilities
    c.daemon_version = daemon_version
    c.state = .Ready

    if c.cbs.on_ready != nil {
        c.cbs.on_ready(c, hello)
    }
}

// Begin a graceful close with `code`. The terminal `on_close` fires once the close
// completes. No-op if already closing or closed.
client_close :: proc(c: ^Client, code := CLOSE_NORMAL) {
    assert(c != nil, "client_close needs a client")

    if c.state == .Closing || c.state == .Closed {
        return
    }

    t := c.transport
    close_err := t->close(code)
    if close_err != .None {
        assert(close_err != .Not_Open, "protocol and transport close states diverged")
        c.state = .Closing
        t->abort(close_err)
        return
    }

    c.state = .Closing
}

// Release all driver-owned state and the transport. Valid at `.Closed` (after the
// terminal callback) or at `.Connecting` on a `client_open` rollback; anything between
// still has transport work outstanding. Leaves `transport_error` readable.
client_destroy :: proc(c: ^Client) {
    assert(c.state == .Connecting || c.state == .Closed, "client_destroy with transport work still outstanding")

    delete(c.pending)
    mem.dynamic_arena_destroy(&c.scratch)

    delete(c.initialize_frame, c.allocator)
    c.initialize_frame = nil

    delete(c.daemon_version, c.allocator)
    c.daemon_version = ""

    c.transport->destroy()
    c.transport = {}
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

    t := c.transport
    close_err := t->close(wire.CLOSE.protocol_error)
    if close_err != .None {
        assert(close_err != .Not_Open, "protocol and transport close states diverged")
        t->abort(close_err)
    }
}

// --- transport events ---
//
// The inbound half of the transport seam: every implementation reports here, in the
// order `on_open` … `on_text`/`on_binary` … one of `on_close`/`on_error`. Keepalives
// and control frames are the transport's own business and never surface.

// Connected: advance to Awaiting_Initialize and send the pre-built `initialize` request.
transport_on_open :: proc(c: ^Client) {
    assert(c != nil, "transport open needs a client")
    assert(c.state == .Connecting, "transport opened outside Connecting")
    c.state = .Awaiting_Initialize

    t := c.transport
    send_err := t->send_text(c.initialize_frame)
    delete(c.initialize_frame, c.allocator)
    c.initialize_frame = nil
    if send_err != .None {
        c.state = .Closing
        t->abort(send_err)
        return
    }

    // Correlate only once the frame is queued, as `client_send_request` does. The
    // handshake then routes through the one response path.
    c.pending[INITIALIZE_REQUEST_ID] = {
        method      = .Initialize,
        on_response = client_on_initialize_result,
    }
}

// One complete text frame, borrowed for this call.
transport_on_text :: proc(c: ^Client, data: []byte) {
    assert(c != nil, "transport text needs a client")

    // Frames only matter in Awaiting_Initialize (the initialize response) or Ready; ignore
    // anything that arrives while connecting, closing, or closed.
    if c.state != .Awaiting_Initialize && c.state != .Ready {
        return
    }

    err := client_handle_text(c, data)

    // A per-frame diagnostic keeps the connection; a protocol error closes it.
    #partial switch err {
    case .Decode_Failed, .Bad_Initialize, .Out_Of_Memory:
        client_abort(c, err)
    }
}

// A frame arrived that cannot carry protocol data. The v1 wire is text only, so this
// is a peer that is not speaking it.
transport_on_binary :: proc(c: ^Client) {
    assert(c != nil, "transport binary needs a client")

    if c.state != .Awaiting_Initialize && c.state != .Ready {
        return
    }

    client_abort(c, .Bad_Frame)
}

// Closed by a graceful or peer close: fire the terminal `on_close`.
transport_on_close :: proc(c: ^Client, code: Close_Code) {
    assert(c != nil, "transport close needs a client")
    c.state = .Closed

    if c.cbs.on_close != nil {
        c.cbs.on_close(c, code)
    }
}

// Failed terminally: latch the reason and surface it as `.Transport_Failed`. The
// connection is Closed; no `on_close` follows.
transport_on_error :: proc(c: ^Client, err: ws.Client_Error) {
    assert(c != nil, "transport error needs a client")
    assert(err != .None, "transport reported a failure with no reason")
    c.state = .Closed
    c.transport_error = err

    if c.cbs.on_error != nil {
        c.cbs.on_error(c, .Transport_Failed)
    }
}
