package client

// Numeric close status reported by the transport. The daemon's reasons are `wire.CLOSE`;
// 1000 is a normal closure.
Close_Code :: u16

// Close status `client_close` sends when the caller names no other reason.
CLOSE_NORMAL :: Close_Code(1000)

// Terminal failure reasons a transport reports. A transport that cannot reach a given
// failure simply never reports it.
Transport_Error :: enum {
    // No error.
    None,

    // Endpoint configuration was rejected before any I/O.
    Invalid_Options,

    // The endpoint host could not be resolved.
    Resolve_Failed,

    // The connection attempt failed.
    Dial_Failed,

    // The transport's own handshake did not complete.
    Handshake_Failed,

    // The peer violated a framing rule.
    Protocol_Violation,

    // A write failed.
    Send_Failed,

    // A read failed.
    Recv_Failed,

    // A connect or handshake step exceeded its timeout.
    Timed_Out,

    // Transport-owned storage could not be allocated.
    Out_Of_Memory,

    // An outbound frame exceeds the transport's frame limit.
    Message_Too_Large,

    // Enqueuing would exceed the transport's outbound-memory bound.
    Send_Queue_Full,

    // The requested close status cannot be carried.
    Invalid_Close_Code,

    // The transport is not in a state that accepts this operation.
    Not_Open,
}

// A pipe the driver speaks wire frames over: one implementation per way of reaching a
// daemon. `self` points at the implementation's own state, allocated and freed by that
// implementation. `client_open` takes ownership of the value:
// it `destroy`s the transport on every failure path, and `client_destroy` does so on
// the success path, so a caller never destroys a transport it has handed over.
Transport :: struct {
    // Implementation state, passed back to every operation.
    self:      rawptr,

    // Begin connecting and report every event to `c`. Called once, by `client_open`.
    start:     proc(self: rawptr, c: ^Client) -> Transport_Error,

    // Queue one text frame.
    send_text: proc(self: rawptr, data: []byte) -> Transport_Error,

    // Begin a graceful close with `code`.
    close:     proc(self: rawptr, code: Close_Code) -> Transport_Error,

    // Fail the connection without a close handshake. `err` is never `.None` or `.Not_Open`.
    abort:     proc(self: rawptr, err: Transport_Error),

    // Release transport-owned storage. Safe after a failed `start`.
    destroy:   proc(self: rawptr),
}
