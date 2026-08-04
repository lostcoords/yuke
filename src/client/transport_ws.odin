package client

import "core:mem"
import "core:nbio"
import ws "libs:websocket"

// The default transport: one `ws://` WebSocket on an `nbio` loop. Allocated by
// `ws_transport_create` and freed by the `destroy` the driver owns.
@(private = "file")
Ws_Transport :: struct {
    // @private
    // Underlying socket, driven through `ws.client_*`. The socket callbacks recover
    // this transport via `sock.user_data`.
    sock:      ws.Client,

    // @private
    // Borrowed event loop the socket submits ops to; never run here.
    loop:      ^nbio.Event_Loop,

    // @private
    // Connect options, borrowed until `client_open` returns.
    options:   ws.Options,

    // @private
    // Backs this transport and the socket's buffers. Must outlive both.
    allocator: mem.Allocator,

    // @private
    // Driver the socket reports to. Nil until `start`.
    client:    ^Client,
}

// A transport dialing `options` on `loop`, ready to hand to `client_open`, which owns
// it from then on. Nothing is connected until that call, and `options` is borrowed only
// until it returns. Allocation failure is carried in the value and reported by
// `client_open` as `.Transport_Failed` with `.Out_Of_Memory`, so the transport can be
// built in an expression.
ws_transport_create :: proc(loop: ^nbio.Event_Loop, options: ws.Options, allocator := context.allocator) -> Transport {
    assert(loop != nil, "ws_transport_create needs an event loop")

    transport := Transport {
        start     = ws_transport_start,
        send_text = ws_transport_send_text,
        close     = ws_transport_close,
        abort     = ws_transport_abort,
        destroy   = ws_transport_destroy,
    }

    t, aerr := new(Ws_Transport, allocator)
    if aerr != nil {
        return transport
    }

    t.loop = loop
    t.options = options
    t.allocator = allocator
    transport.self = t

    return transport
}

@(private = "file")
ws_transport_start :: proc(self: rawptr, c: ^Client) -> Transport_Error {
    assert(c != nil, "transport start needs a client")

    // `ws_transport_create` could not allocate; this is the first place that can say so.
    if self == nil {
        return .Out_Of_Memory
    }

    t := (^Ws_Transport)(self)
    assert(t.client == nil, "transport started twice")

    t.client = c

    callbacks := ws.Callbacks {
        on_open    = ws_on_open,
        on_message = ws_on_message,
        on_close   = ws_on_close,
        on_error   = ws_on_error,
    }

    return TRANSPORT_ERROR_FROM_WS[ws.client_connect(&t.sock, t.loop, t.options, callbacks, t, t.allocator)]
}

@(private = "file")
ws_transport_send_text :: proc(self: rawptr, data: []byte) -> Transport_Error {
    t := (^Ws_Transport)(self)
    assert(t != nil, "transport send needs a transport")

    return TRANSPORT_ERROR_FROM_WS[ws.client_send_text(&t.sock, data)]
}

@(private = "file")
ws_transport_close :: proc(self: rawptr, code: Close_Code) -> Transport_Error {
    t := (^Ws_Transport)(self)
    assert(t != nil, "transport close needs a transport")

    return TRANSPORT_ERROR_FROM_WS[ws.client_close(&t.sock, ws.Close_Code(code))]
}

@(private = "file")
ws_transport_abort :: proc(self: rawptr, err: Transport_Error) {
    t := (^Ws_Transport)(self)
    assert(t != nil, "transport abort needs a transport")
    assert(err != .None && err != .Not_Open, "transport abort needs a terminal error")

    ws.client_abort(&t.sock, WS_ERROR_FROM_TRANSPORT[err])
}

// Safe after a failed `start`: `ws.client_connect` rolls its own storage back, a socket
// that never dialed is zero-valued, and an unallocated transport has nothing to free.
@(private = "file")
ws_transport_destroy :: proc(self: rawptr) {
    if self == nil {
        return
    }

    t := (^Ws_Transport)(self)
    ws.client_destroy(&t.sock)
    free(t, t.allocator)
}

// --- socket callbacks ---
//
// Each recovers the owning transport from the socket's user data (proc literals cannot
// capture). Control frames are handled inside the socket and never surface here.

@(private = "file")
ws_on_open :: proc(sock: ^ws.Client) {
    t := ws_transport_from_socket(sock)
    transport_on_open(t.client)
}

@(private = "file")
ws_on_message :: proc(sock: ^ws.Client, kind: ws.Message_Kind, data: []byte) {
    t := ws_transport_from_socket(sock)

    switch kind {
    case .Text:
        transport_on_text(t.client, data)

    case .Binary:
        transport_on_binary(t.client)

    case .Ping, .Pong, .Close:
    // Handled by the socket; never delivered here.
    }
}

@(private = "file")
ws_on_close :: proc(sock: ^ws.Client, code: ws.Close_Code) {
    t := ws_transport_from_socket(sock)
    transport_on_close(t.client, Close_Code(code))
}

@(private = "file")
ws_on_error :: proc(sock: ^ws.Client, err: ws.Client_Error) {
    t := ws_transport_from_socket(sock)
    transport_on_error(t.client, TRANSPORT_ERROR_FROM_WS[err])
}

@(private = "file")
ws_transport_from_socket :: proc(sock: ^ws.Client) -> ^Ws_Transport {
    assert(sock != nil && sock.user_data != nil, "socket callback lost its transport")

    t := (^Ws_Transport)(sock.user_data)
    assert(&t.sock == sock, "socket callback crossed transport ownership")
    assert(t.client != nil, "socket callback ran before start")

    return t
}

// Both maps are exhaustive by construction: an arm added to either enum fails to
// compile until it is mapped, so a failure can never silently become a different one.
@(private = "file")
TRANSPORT_ERROR_FROM_WS := [ws.Client_Error]Transport_Error {
    .None               = .None,
    .Invalid_Options    = .Invalid_Options,
    .Resolve_Failed     = .Resolve_Failed,
    .Dial_Failed        = .Dial_Failed,
    .Handshake_Failed   = .Handshake_Failed,
    .Protocol_Violation = .Protocol_Violation,
    .Send_Failed        = .Send_Failed,
    .Recv_Failed        = .Recv_Failed,
    .Timed_Out          = .Timed_Out,
    .Out_Of_Memory      = .Out_Of_Memory,
    .Message_Too_Large  = .Message_Too_Large,
    .Send_Queue_Full    = .Send_Queue_Full,
    .Invalid_Close_Code = .Invalid_Close_Code,
    .Not_Open           = .Not_Open,
}

@(private = "file")
WS_ERROR_FROM_TRANSPORT := [Transport_Error]ws.Client_Error {
    .None               = .None,
    .Invalid_Options    = .Invalid_Options,
    .Resolve_Failed     = .Resolve_Failed,
    .Dial_Failed        = .Dial_Failed,
    .Handshake_Failed   = .Handshake_Failed,
    .Protocol_Violation = .Protocol_Violation,
    .Send_Failed        = .Send_Failed,
    .Recv_Failed        = .Recv_Failed,
    .Timed_Out          = .Timed_Out,
    .Out_Of_Memory      = .Out_Of_Memory,
    .Message_Too_Large  = .Message_Too_Large,
    .Send_Queue_Full    = .Send_Queue_Full,
    .Invalid_Close_Code = .Invalid_Close_Code,
    .Not_Open           = .Not_Open,
}
