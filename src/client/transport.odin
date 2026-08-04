package client

import "core:mem"
import "core:nbio"
import ws "libs:websocket"

// Numeric close status reported by the transport. The daemon's reasons are `wire.CLOSE`;
// 1000 is a normal closure.
Close_Code :: u16

// Close status `client_close` sends when the caller names no other reason.
CLOSE_NORMAL :: Close_Code(1000)

// Ops bag for a text-frame pipe. Successful create only; `client_open` takes ownership.
// Failures are `ws.Client_Error`.
Transport :: struct {
    // Backend state, passed back to every operation.
    self:      rawptr,

    // Begin opening the pipe. Should be called once; success is reported via on_open.
    open:      proc(self: rawptr, c: ^Client) -> ws.Client_Error,

    // Queue one text frame.
    send_text: proc(self: rawptr, data: []byte) -> ws.Client_Error,

    // Begin a graceful close with `code`.
    close:     proc(self: rawptr, code: Close_Code) -> ws.Client_Error,

    // Fail without a close handshake. `err` is never `.None` or `.Not_Open`.
    abort:     proc(self: rawptr, err: ws.Client_Error),

    // Release backend storage. Safe after a failed `open`.
    destroy:   proc(self: rawptr),
}

// WebSocket backend behind a `Transport` (`ws://` on an `nbio` loop).
@(private = "file")
Ws_Backend :: struct {
    sock:      ws.Client,
    loop:      ^nbio.Event_Loop,
    // Pointer fields borrowed until `open` returns.
    options:   ws.Options,
    allocator: mem.Allocator,
    // Driver reported to; nil until `open`.
    client:    ^Client,
}

// Allocates a WS backend; dials only on `open`. On error there is no handle to destroy.
// `options` pointer fields are borrowed until `Transport.open` returns.
ws_create :: proc(
    loop: ^nbio.Event_Loop,
    options: ws.Options,
    allocator := context.allocator,
) -> (
    Transport,
    ws.Client_Error,
) {
    assert(loop != nil, "ws_create needs an event loop")

    backend, aerr := new(Ws_Backend, allocator)
    if aerr != nil {
        return {}, .Out_Of_Memory
    }

    backend.loop = loop
    backend.options = options
    backend.allocator = allocator

    return Transport {
            self = backend,
            open = ws_open,
            send_text = ws_send_text,
            close = ws_close,
            abort = ws_abort,
            destroy = ws_destroy,
        },
        .None
}

@(private = "file")
ws_open :: proc(self: rawptr, c: ^Client) -> ws.Client_Error {
    assert(c != nil, "ws_open needs a client")
    assert(self != nil, "ws_open needs a backend from a successful create")

    backend := (^Ws_Backend)(self)
    assert(backend.client == nil, "ws backend opened twice")

    backend.client = c

    callbacks := ws.Callbacks {
        on_open    = ws_on_open,
        on_message = ws_on_message,
        on_close   = ws_on_close,
        on_error   = ws_on_error,
    }

    return ws.client_connect(&backend.sock, backend.loop, backend.options, callbacks, backend, backend.allocator)
}

@(private = "file")
ws_send_text :: proc(self: rawptr, data: []byte) -> ws.Client_Error {
    backend := (^Ws_Backend)(self)
    assert(backend != nil, "ws_send_text needs a backend")
    return ws.client_send_text(&backend.sock, data)
}

@(private = "file")
ws_close :: proc(self: rawptr, code: Close_Code) -> ws.Client_Error {
    backend := (^Ws_Backend)(self)
    assert(backend != nil, "ws_close needs a backend")

    return ws.client_close(&backend.sock, ws.Close_Code(code))
}

@(private = "file")
ws_abort :: proc(self: rawptr, err: ws.Client_Error) {
    backend := (^Ws_Backend)(self)
    assert(backend != nil, "ws_abort needs a backend")
    assert(err != .None && err != .Not_Open, "ws_abort needs a terminal error")

    ws.client_abort(&backend.sock, err)
}

// Safe after a failed `open`.
@(private = "file")
ws_destroy :: proc(self: rawptr) {
    assert(self != nil, "ws_destroy needs a backend from a successful create")

    backend := (^Ws_Backend)(self)
    ws.client_destroy(&backend.sock)
    free(backend, backend.allocator)
}

@(private = "file")
ws_on_open :: proc(sock: ^ws.Client) {
    backend := ws_backend_from_socket(sock)
    transport_on_open(backend.client)
}

@(private = "file")
ws_on_message :: proc(sock: ^ws.Client, kind: ws.Message_Kind, data: []byte) {
    backend := ws_backend_from_socket(sock)

    switch kind {
    case .Text:
        transport_on_text(backend.client, data)

    case .Binary:
        transport_on_binary(backend.client)

    case .Ping, .Pong, .Close:
    // Handled by the socket; never delivered here.
    }
}

@(private = "file")
ws_on_close :: proc(sock: ^ws.Client, code: ws.Close_Code) {
    backend := ws_backend_from_socket(sock)
    transport_on_close(backend.client, Close_Code(code))
}

@(private = "file")
ws_on_error :: proc(sock: ^ws.Client, err: ws.Client_Error) {
    backend := ws_backend_from_socket(sock)
    transport_on_error(backend.client, err)
}

@(private = "file")
ws_backend_from_socket :: proc(sock: ^ws.Client) -> ^Ws_Backend {
    assert(sock != nil && sock.user_data != nil, "socket callback lost its backend")

    backend := (^Ws_Backend)(sock.user_data)
    assert(&backend.sock == sock, "socket callback crossed backend ownership")
    assert(backend.client != nil, "socket callback ran before open")

    return backend
}
