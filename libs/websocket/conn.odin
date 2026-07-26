package websocket

import "base:runtime"
import "core:crypto"
import "core:log"
import "core:mem"
import "core:nbio"
import "core:net"
import "core:time"

// Connection lifecycle: Idle -> Dialing -> Upgrading -> Open -> Closing -> Closed.
// `Idle` and `Dialing` are client-only; an adopted server connection starts at
// `Upgrading` with its socket already established.
Conn_State :: enum {
    Idle,

    // TCP connect in flight.
    Dialing,

    // The upgrade is in flight: a client awaits the 101, a server writes it.
    Upgrading,
    Open,

    // Close handshake in progress; waiting for our Close write and the peer's Close.
    Closing,

    // Fully torn down; no further callbacks will run.
    Closed,
}

// Driver-internal failure reasons. Every value of both public error enums has a
// counterpart here so a terminal error survives in `Conn_Core`; each role maps it
// back to its own enum at the API boundary, where the other role's values are
// unreachable.
Conn_Error :: enum {
    None,
    Invalid_Options,
    Resolve_Failed,
    Dial_Failed,
    Handshake_Failed,
    Protocol_Violation,
    Send_Failed,
    Recv_Failed,
    Timed_Out,
    Out_Of_Memory,
    Message_Too_Large,
    Send_Queue_Full,
    Invalid_Close_Code,
    Not_Open,
    Too_Many_Connections,
}

// The connection driver shared by both roles: socket, decoder, send queue, close
// sequence and teardown. `Client` and `Server_Conn` embed it as their first field,
// so a `^Conn_Core` converts back to its owner (see `terminal`).
Conn_Core :: struct {
    // @private
    // Which side of the connection this is. Clients mask every frame they send and
    // reject masked frames; servers do the reverse (RFC 6455 §5.3).
    role:                      Role,

    // @private
    // Borrowed event loop; the driver submits ops to it but never runs it.
    loop:                      ^nbio.Event_Loop,

    // @private
    allocator:                 mem.Allocator,
    socket:                    net.TCP_Socket,

    // @private
    // Whether `socket` was acquired; guards teardown from `close(0)` when a client
    // dial failed before one existed. Always set for an adopted server connection.
    has_socket:                bool,
    state:                     Conn_State,

    // @private
    // Sans-IO reassembler fed by every receive.
    decoder:                   Decoder,

    // @private
    // Reused destination for each socket receive.
    recv_buf:                  []byte,

    // @private
    // Inbound single-frame cap (mirrors the decoder's cap for send-side checks).
    max_frame_bytes:           int,

    // @private
    // Maximum application-frame bytes pending in `send_queue` + `send_batch`.
    max_send_queue_bytes:      int,

    // @private
    // Overall deadline for a WebSocket closing handshake.
    close_timeout:             time.Duration,

    // @private
    // Encoded frames waiting to be written, in order; each is owned.
    send_queue:                [dynamic][]byte,

    // @private
    // The frames of the in-flight coalesced send, in order; each is owned until the
    // one vectored send covering the whole batch completes. Empty when idle; the
    // backing capacity is reused across sends (no per-send allocation once warm).
    send_batch:                [dynamic][]byte,

    // @private
    // True while a send is in flight; gates the one-frame-at-a-time queue.
    sending:                   bool,

    // @private
    // Bytes currently owned by `send_queue` + `send_batch`.
    pending_send_bytes:        int,

    // @private
    // Whether this endpoint's Close frame finished writing.
    close_sent:                bool,

    // @private
    // Whether a valid peer Close frame was received.
    close_received:            bool,

    // @private
    // Close code to report to the close callback after teardown completes.
    close_code:                Close_Code,

    // @private
    // Error to report to the error callback; `.None` selects the close callback
    // instead. Latched before teardown so the terminal callback can fire on socket
    // close.
    terminal_error:            Conn_Error,

    // @private
    // Outstanding op handles, one per lane (recv and send overlap while Open).
    // Cleared at the top of their own callback; teardown removes the rest.
    // `dial_op` is client-only.
    dial_op, recv_op, send_op: ^nbio.Operation,

    // @private
    // Closing-handshake deadline; independent of the steady-state receive.
    close_timeout_op:          ^nbio.Operation,

    // @private
    // Guards exactly one terminal callback.
    terminal_fired:            bool,

    // @private
    // Role adapter delivering one complete application message. `data` is borrowed
    // for the call and freed after it returns. Set at init, never nil.
    message:                   proc(core: ^Conn_Core, kind: Message_Kind, data: []byte),

    // @private
    // Role adapter for the one terminal callback: recovers the owner from `core`
    // and dispatches its close/error callback. Set at init, never nil.
    terminal:                  proc(core: ^Conn_Core),

    // @private
    // Role adapter fired when the send queue drains empty while Open. nil when the
    // role has no drain notification (the client driver has none).
    drained:                   proc(core: ^Conn_Core),

    // Opaque application pointer, assigned directly (nil until set). The driver never
    // touches it; a callback reaches it as `c.user_data` and may free any state it
    // owns from the close/error callback.
    user_data:                 rawptr,
}

// Submit the next steady-state receive (no timeout; the peer may idle).
@(private)
conn_start_recv :: proc(core: ^Conn_Core) {
    assert(core.state == .Open, "steady-state recv on a connection that is not open")
    assert(core.recv_op == nil, "a receive is already in flight")

    core.recv_op = nbio.recv_poly(
        core.socket,
        [][]byte{core.recv_buf},
        core,
        conn_on_recv,
        false,
        nbio.NO_TIMEOUT,
        core.loop,
    )
}

@(private)
conn_on_recv :: proc(op: ^nbio.Operation, core: ^Conn_Core) {
    assert(op == core.recv_op, "receive completion does not match stored operation")
    core.recv_op = nil

    if core.state != .Open && core.state != .Closing {
        return
    }

    if op.recv.err != nil {
        conn_fail(core, .Recv_Failed)
        return
    }

    if op.recv.received == 0 {
        // Peer closed the TCP connection without a WebSocket close frame.
        conn_finalize_close(core, .Abnormal_Closure)
        return
    }

    if decoder_feed(&core.decoder, core.recv_buf[:op.recv.received]) != nil {
        conn_fail(core, .Out_Of_Memory)
        return
    }

    if !conn_drain_decoder(core) {
        return
    }

    if core.state == .Open {
        conn_start_recv(core)
    } else if core.state == .Closing {
        conn_ensure_close_recv(core)
    }
}

// Returns false once it has terminated the connection (protocol error or close), so
// the caller stops draining.
@(private)
conn_drain_decoder :: proc(core: ^Conn_Core) -> bool {
    assert(core != nil && (core.state == .Open || core.state == .Closing), "decoder drain outside active states")
    assert(core.message != nil, "decoder drain without a message adapter")

    for {
        // An application message callback may tear the connection down. Preserve
        // graceful Closing drains, but stop immediately after hard teardown.
        if core.state == .Closed {
            return false
        }

        msg, has, err := decoder_next(&core.decoder, core.allocator)
        if err != .None {
            conn_fail(core, err == .Out_Of_Memory ? .Out_Of_Memory : .Protocol_Violation)
            return false
        }

        if !has {
            return true
        }

        switch msg.kind {
        case .Text, .Binary:
            if core.state == .Open {
                core.message(core, msg.kind, msg.data)
            }

            delete(msg.data, core.allocator)

        case .Ping:
            if core.state == .Open {
                control_err := conn_enqueue_control(core, .Pong, msg.data)
                if control_err != .None {
                    delete(msg.data, core.allocator)
                    conn_fail(core, control_err)
                    return false
                }
            }
            delete(msg.data, core.allocator)

        case .Pong:
            delete(msg.data, core.allocator)

        case .Close:
            parsed, perr := parse_close(msg.data)
            had_body := len(msg.data) != 0
            delete(msg.data, core.allocator)
            if perr != .None {
                conn_fail(core, .Protocol_Violation)
                return false
            }

            // Echo the peer's code only when it sent one; an empty body must be
            // answered with an empty-body close, never a synthesized 1005 (invalid
            // on the wire, RFC 6455 §7.4.1). The synthesized code is still reported
            // locally.
            wire_code: Maybe(Close_Code)
            if had_body {
                wire_code = parsed.code
            }

            core.close_received = true
            core.close_code = parsed.code
            if core.state == .Open {
                if close_err := conn_begin_close(core, wire_code, parsed.code); close_err != .None {
                    conn_fail(core, close_err)
                }
            } else if core.close_sent {
                conn_finalize_close(core, parsed.code)
            }

            return false
        }
    }
}

// Encode and queue a data frame. Fails unless the connection is Open.
@(private)
conn_send_data_frame :: proc(core: ^Conn_Core, opcode: Op_Code, data: []byte) -> Conn_Error {
    assert(core != nil, "conn_send_data_frame needs a connection")
    assert(opcode == .Text || opcode == .Binary, "data frame path given a control opcode")

    if core.state != .Open {
        return .Not_Open
    }

    if len(data) > core.max_frame_bytes {
        return .Message_Too_Large
    }

    if len(data) + MAX_HEADER_BYTES > core.max_send_queue_bytes - core.pending_send_bytes {
        return .Send_Queue_Full
    }

    frame, aerr := conn_encode(core, opcode, data)
    if aerr != nil {
        return .Out_Of_Memory
    }

    return conn_enqueue(core, frame, false)
}

// Encode one outbound frame. RFC 6455 §5.3: a client masks every frame it sends with
// a fresh random key; a server never masks.
@(private)
conn_encode :: proc(
    core: ^Conn_Core,
    opcode: Op_Code,
    payload: []byte,
) -> (
    frame: []byte,
    err: runtime.Allocator_Error,
) #optional_allocator_error {
    assert(core != nil, "conn_encode needs a connection")
    assert(core.role == core.decoder.role, "send and receive roles disagree")

    mask_key: Maybe([MASK_KEY_BYTES]byte)
    if core.role == .Client {
        key: [MASK_KEY_BYTES]byte
        crypto.rand_bytes(key[:])
        mask_key = key
    }

    return encode_frame(true, opcode, payload, mask_key, core.allocator)
}

// Append an owned frame to the send queue and pump the writer.
@(private)
conn_enqueue :: proc(core: ^Conn_Core, frame: []byte, control: bool) -> Conn_Error {
    assert(core != nil, "conn_enqueue needs a connection")
    assert(len(frame) >= 2, "queued a frame smaller than its header")
    assert(
        core.pending_send_bytes == send_queue_bytes(core.send_queue[:], core.send_batch[:]),
        "pending send byte mismatch",
    )

    limit := core.max_send_queue_bytes
    if control {
        limit += SEND_CONTROL_RESERVE_BYTES
    }

    if core.pending_send_bytes > limit - len(frame) {
        delete(frame, core.allocator)
        return .Send_Queue_Full
    }

    if _, aerr := append(&core.send_queue, frame); aerr != nil {
        delete(frame, core.allocator)
        return .Out_Of_Memory
    }

    core.pending_send_bytes += len(frame)
    assert(
        core.pending_send_bytes == send_queue_bytes(core.send_queue[:], core.send_batch[:]),
        "queued byte accounting mismatch",
    )

    conn_pump_send(core)

    return .None
}

// Encode and queue a control frame (Pong), using the control-frame send reserve.
@(private)
conn_enqueue_control :: proc(core: ^Conn_Core, opcode: Op_Code, payload: []byte) -> Conn_Error {
    assert(opcode == .Pong, "unexpected automatic control opcode")
    assert(len(payload) <= 125, "control payload exceeds protocol maximum")

    frame, aerr := conn_encode(core, opcode, payload)
    if aerr != nil {
        return .Out_Of_Memory
    }

    return conn_enqueue(core, frame, true)
}

// Coalesce the queued frames into one vectored send if none is in flight. Whole
// frames are submitted as iovecs (zero copy); nbio owns the partial-send retry via
// `all`. Finalizes the TCP close when the queue empties during Closing.
@(private)
conn_pump_send :: proc(core: ^Conn_Core) {
    // A terminal failure stops the pipeline: never send on a closed socket. The
    // queue and `send_batch` are left for the owner to release.
    if core.state == .Closed {
        return
    }

    if core.sending {
        return
    }

    if len(core.send_queue) == 0 {
        if core.state == .Closing {
            core.close_sent = true
            if core.close_received {
                conn_finalize_close(core, core.close_code)
            } else {
                conn_ensure_close_recv(core)
            }
        }

        return
    }

    assert(len(core.send_batch) == 0, "previous batch was not released")

    if coalesce_send_batch(&core.send_queue, &core.send_batch) != nil {
        conn_fail(core, .Out_Of_Memory)
        return
    }
    assert(len(core.send_batch) > 0, "coalesced an empty batch from a non-empty queue")

    core.sending = true
    core.send_op = nbio.send_poly(
        core.socket,
        core.send_batch[:],
        core,
        conn_on_sent,
        {},
        true,
        nbio.NO_TIMEOUT,
        core.loop,
    )
}

@(private)
conn_on_sent :: proc(op: ^nbio.Operation, core: ^Conn_Core) {
    assert(core.sending, "send completed while none was in flight")
    assert(op == core.send_op, "send completion does not match stored operation")

    core.send_op = nil

    for frame in core.send_batch {
        assert(len(frame) <= core.pending_send_bytes, "send byte accounting underflow")
        core.pending_send_bytes -= len(frame)
        delete(frame, core.allocator)
    }
    clear(&core.send_batch)
    core.sending = false
    assert(
        core.pending_send_bytes == send_queue_bytes(core.send_queue[:], core.send_batch[:]),
        "sent byte accounting mismatch",
    )

    if op.send.err != nil {
        conn_fail(core, .Send_Failed)
        return
    }

    // Queue drained while Open: signal a streaming producer to refill. It may enqueue
    // here, pumping the next send, so the trailing pump below is a no-op.
    if core.state == .Open && len(core.send_queue) == 0 && core.drained != nil {
        core.drained(core)
    }

    conn_pump_send(core)
}

// Queue a close frame and enter Closing. `wire_code` is serialized into the body; nil
// sends an empty-body close (required when echoing a peer that sent no code — 1005/1006
// must never go on the wire). `report_code` is what the close callback receives.
// Idempotent once closing has begun.
@(private)
conn_begin_close :: proc(core: ^Conn_Core, wire_code: Maybe(Close_Code), report_code: Close_Code) -> Conn_Error {
    assert(core != nil, "conn_begin_close needs a connection")

    if core.state == .Closing || core.state == .Closed {
        return .Not_Open
    }

    assert(core.state == .Open, "close began outside Open")
    assert(!core.close_sent, "new close already marked sent")
    assert(core.close_timeout_op == nil, "new close already has a deadline")

    body: []byte
    buf: [2]byte
    if code, ok := wire_code.?; ok {
        buf[0] = byte(u16(code) >> 8)
        buf[1] = byte(code)
        body = buf[:]
    }

    frame, aerr := conn_encode(core, .Connection_Close, body)
    if aerr != nil {
        return .Out_Of_Memory
    }

    core.state = .Closing
    core.close_code = report_code
    if err := conn_enqueue(core, frame, true); err != .None {
        core.state = .Open
        return err
    }

    core.close_timeout_op = nbio.timeout_poly(core.close_timeout, core, conn_on_close_timeout, core.loop)
    conn_ensure_close_recv(core)

    return .None
}

// Submit the closing-handshake receive if one is not already pending or received.
@(private)
conn_ensure_close_recv :: proc(core: ^Conn_Core) {
    assert(core != nil && core.state == .Closing, "closing receive outside Closing")

    if core.close_received || core.recv_op != nil {
        return
    }

    core.recv_op = nbio.recv_poly(
        core.socket,
        [][]byte{core.recv_buf},
        core,
        conn_on_recv,
        false,
        nbio.NO_TIMEOUT,
        core.loop,
    )
}

// Closing-handshake deadline expired: finalize with an abnormal close.
@(private)
conn_on_close_timeout :: proc(op: ^nbio.Operation, core: ^Conn_Core) {
    assert(core.state == .Closing, "close deadline completed outside Closing")
    assert(op == core.close_timeout_op, "close deadline does not match stored operation")
    core.close_timeout_op = nil

    conn_finalize_close(core, .Abnormal_Closure)
}

// Latch a normal/abnormal close and tear down, reporting `code` to the close callback.
@(private)
conn_finalize_close :: proc(core: ^Conn_Core, code: Close_Code) {
    assert(core != nil, "conn_finalize_close needs a connection")

    if core.state == .Closed {
        return
    }

    core.state = .Closed
    core.close_code = code
    conn_teardown(core)
}

// Latch a terminal failure and tear down, reporting `err` to the error callback.
@(private)
conn_fail :: proc(core: ^Conn_Core, err: Conn_Error) {
    assert(core != nil, "conn_fail needs a connection")
    assert(err != .None, "fail without an error")

    if core.state == .Closed {
        return
    }

    log.debugf("websocket %v: fail %v", core.role, err)

    core.state = .Closed
    core.terminal_error = err
    conn_teardown(core)
}

// Cancel outstanding ops, close the socket, and fire the terminal callback only once
// the close completes. Deferring it lets the app free buffers from the callback: by
// then the kernel has dropped the recv/send buffers. `nbio.remove` stops the callback
// but not an in-flight kernel read/write of the buffer, so firing inline would
// use-after-free.
@(private)
conn_teardown :: proc(core: ^Conn_Core) {
    assert(core != nil && core.state == .Closed, "teardown before Closed")
    assert(core.terminal_error != .None || core.close_code != Close_Code(0), "teardown without terminal outcome")

    conn_cancel_pending_ops(core)

    if core.has_socket {
        nbio.close_poly(core.socket, core, conn_on_teardown_closed, core.loop)

        return
    }

    // A client dial failed before a socket existed: nothing outstanding, nothing to close.
    conn_fire_terminal(core)
}

// Socket close completed: canceled recv/send buffers are no longer referenced by the
// kernel, so it is safe to hand control back.
@(private)
conn_on_teardown_closed :: proc(op: ^nbio.Operation, core: ^Conn_Core) {
    conn_fire_terminal(core)
}

// Fire exactly one terminal callback through the role adapter.
@(private)
conn_fire_terminal :: proc(core: ^Conn_Core) {
    assert(core.state == .Closed, "terminal fired before teardown")
    assert(!core.terminal_fired, "terminal callback fired twice")
    assert(core.terminal != nil, "teardown without a terminal adapter")
    core.terminal_fired = true

    core.terminal(core)
}

// Remove each outstanding op so no completion fires into the connection after
// teardown. `nbio.remove` is final and silent: the callback never runs, even if its
// completion was already queued. An op running its own callback has already cleared
// its handle, so it is never removed here.
@(private)
conn_cancel_pending_ops :: proc(core: ^Conn_Core) {
    assert(core.role == .Client || core.dial_op == nil, "a server connection never dials")

    if core.dial_op != nil {
        nbio.remove(core.dial_op)
        core.dial_op = nil
    }

    if core.recv_op != nil {
        nbio.remove(core.recv_op)
        core.recv_op = nil
    }

    if core.send_op != nil {
        nbio.remove(core.send_op)
        core.send_op = nil
    }

    if core.close_timeout_op != nil {
        nbio.remove(core.close_timeout_op)
        core.close_timeout_op = nil
    }
}

// Widen and narrow between the core error and each role's public enum. These are
// enum-indexed tables rather than casts: the compiler rejects a table that misses a
// value, so adding an error to any of the three enums fails the build instead of
// silently mapping to the wrong one.

@(private, rodata)
CONN_ERROR_OF_CLIENT := [Client_Error]Conn_Error {
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

// `Too_Many_Connections` is server-only; `client_error` asserts it never arrives, so
// its entry is never read.
@(private, rodata)
CLIENT_ERROR_OF_CONN := [Conn_Error]Client_Error {
    .None                 = .None,
    .Invalid_Options      = .Invalid_Options,
    .Resolve_Failed       = .Resolve_Failed,
    .Dial_Failed          = .Dial_Failed,
    .Handshake_Failed     = .Handshake_Failed,
    .Protocol_Violation   = .Protocol_Violation,
    .Send_Failed          = .Send_Failed,
    .Recv_Failed          = .Recv_Failed,
    .Timed_Out            = .Timed_Out,
    .Out_Of_Memory        = .Out_Of_Memory,
    .Message_Too_Large    = .Message_Too_Large,
    .Send_Queue_Full      = .Send_Queue_Full,
    .Invalid_Close_Code   = .Invalid_Close_Code,
    .Not_Open             = .Not_Open,
    .Too_Many_Connections = .None,
}

@(private, rodata)
CONN_ERROR_OF_SERVER := [Server_Error]Conn_Error {
    .None                 = .None,
    .Too_Many_Connections = .Too_Many_Connections,
    .Out_Of_Memory        = .Out_Of_Memory,
    .Invalid_Options      = .Invalid_Options,
    .Message_Too_Large    = .Message_Too_Large,
    .Send_Queue_Full      = .Send_Queue_Full,
    .Invalid_Close_Code   = .Invalid_Close_Code,
    .Protocol_Violation   = .Protocol_Violation,
    .Send_Failed          = .Send_Failed,
    .Recv_Failed          = .Recv_Failed,
    .Not_Open             = .Not_Open,
}

// The client-only dial, handshake, and timeout values never reach an adopted
// connection; `server_error` asserts that, so their entries are never read.
@(private, rodata)
SERVER_ERROR_OF_CONN := [Conn_Error]Server_Error {
    .None                 = .None,
    .Invalid_Options      = .Invalid_Options,
    .Resolve_Failed       = .None,
    .Dial_Failed          = .None,
    .Handshake_Failed     = .None,
    .Protocol_Violation   = .Protocol_Violation,
    .Send_Failed          = .Send_Failed,
    .Recv_Failed          = .Recv_Failed,
    .Timed_Out            = .None,
    .Out_Of_Memory        = .Out_Of_Memory,
    .Message_Too_Large    = .Message_Too_Large,
    .Send_Queue_Full      = .Send_Queue_Full,
    .Invalid_Close_Code   = .Invalid_Close_Code,
    .Not_Open             = .Not_Open,
    .Too_Many_Connections = .Too_Many_Connections,
}

@(private)
conn_error_from_client :: proc(err: Client_Error) -> Conn_Error {
    return CONN_ERROR_OF_CLIENT[err]
}

@(private)
client_error :: proc(err: Conn_Error) -> Client_Error {
    assert(err != .Too_Many_Connections, "server-only error surfaced on a client connection")

    return CLIENT_ERROR_OF_CONN[err]
}

@(private)
conn_error_from_server :: proc(err: Server_Error) -> Conn_Error {
    return CONN_ERROR_OF_SERVER[err]
}

@(private)
server_error :: proc(err: Conn_Error) -> Server_Error {
    assert(
        err != .Resolve_Failed && err != .Dial_Failed && err != .Handshake_Failed && err != .Timed_Out,
        "client-only error surfaced on an adopted connection",
    )

    return SERVER_ERROR_OF_CONN[err]
}
