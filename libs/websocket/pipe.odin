package websocket

import "core:nbio"
import "core:net"
import "core:time"
import "libs:bindings/curl"

// How one pipe operation ended. A timeout is only ever asked for during a handshake;
// the steady-state read and write carry none.
@(private)
Io_Result :: enum {
    Ok,
    Failed,
    Timed_Out,
}

// Everything a TLS connection needs beyond a plain one: libcurl's connection plus the
// progress of the write it has in flight. Owned by `Client`, since only a client ever
// dials; `Conn_Core.tls` points at it and stays nil for every plain connection, which
// is every server connection.
Tls_Pipe :: struct {
    // @private
    // libcurl's connection. It owns the socket and the TLS session; the descriptor in
    // `Conn_Core.socket` is polled for readiness but never closed by this package.
    sock:          curl.Socket,

    // @private
    // Bytes read at submission time, delivered on the following tick.
    recv_pending:  int,

    // @private
    // Frames still to write, front-trimmed as they complete, with the byte offset
    // reached in the first. `curl_easy_send` takes one buffer at a time and may take
    // part of one, so this progress is the pipe's own.
    send_pending:  [][]byte,
    send_offset:   int,

    // @private
    // Timeout to re-park a read against. A read may be woken repeatedly without
    // yielding plaintext, and each wait carries the caller's original bound — which
    // matches the plain arm, where every handshake read re-submits with a fresh one.
    recv_timeout:  time.Duration,

    // @private
    // When the write as a whole must be done, or the zero time when it is unbounded.
    // Absolute rather than a duration, so a peer that dribbles cannot restart the
    // handshake's deadline on every partial write.
    send_deadline: time.Time,
}

// Classify an nbio receive error the way the handshake needs it: a timeout there is
// its own failure, and every other error is just a failed read.
@(private)
recv_io_result :: proc(err: net.Recv_Error) -> Io_Result {
    if err == nil {
        return .Ok
    }

    return .Timed_Out if recv_timed_out(err) else .Failed
}

@(private)
send_io_result :: proc(err: net.Send_Error) -> Io_Result {
    if err == nil {
        return .Ok
    }

    return .Timed_Out if send_timed_out(err) else .Failed
}

// Submit a receive into `recv_buf` on whichever pipe this connection runs over. The
// outcome reaches `pipe_recv_completed` either way.
@(private)
conn_submit_recv :: proc(core: ^Conn_Core, timeout: time.Duration) {
    assert(core != nil, "a receive needs a connection")
    assert(core.recv_op == nil, "a receive is already in flight")

    if core.tls != nil {
        tls_submit_recv(core, timeout)
        return
    }

    core.recv_op = nbio.recv_poly(core.socket, [][]byte{core.recv_buf}, core, conn_on_recv, false, timeout, core.loop)
}

// Submit `batch` on whichever pipe this connection runs over. The outcome reaches
// `pipe_send_completed` either way.
@(private)
conn_submit_send :: proc(core: ^Conn_Core, batch: [][]byte, timeout: time.Duration) {
    assert(core != nil, "a send needs a connection")
    assert(core.send_op == nil, "a send is already in flight")
    assert(len(batch) > 0, "a send needs something to write")

    if core.tls != nil {
        tls_submit_send(core, batch, timeout)
        return
    }

    core.send_op = nbio.send_poly(core.socket, batch, core, conn_on_sent, {}, true, timeout, core.loop)
}

// Route a finished receive to the phase that asked for it. Only a client reads while
// Upgrading — a server's handshake read happened in the front door before adoption.
@(private)
pipe_recv_completed :: proc(core: ^Conn_Core, received: int, result: Io_Result) {
    if core.state == .Upgrading {
        assert(core.role == .Client, "a server connection never reads while Upgrading")
        client_handshake_received((^Client)(core), received, result)
        return
    }

    conn_recv_completed(core, received, result != .Ok)
}

// Route a finished send to the phase that asked for it. A server's `101` send has its
// own completion and never arrives here.
@(private)
pipe_send_completed :: proc(core: ^Conn_Core, result: Io_Result) {
    if core.state == .Upgrading {
        assert(core.role == .Client, "a server connection never sends through the pipe while Upgrading")
        client_upgrade_sent((^Client)(core), result)
        return
    }

    conn_send_completed(core, result != .Ok)
}

// --- TLS pipe ------------------------------------------------------------------
//
// libcurl owns the socket and the TLS session; we own the readiness waits. A read is
// attempted before parking, because TLS arrives in whole records: a wait entered with
// plaintext already decrypted inside curl would never be woken for it.
//
// Each submission ends in exactly one of three completions, which is what tells the
// callback whether `op.poll` holds anything worth reading.

@(private)
tls_submit_recv :: proc(core: ^Conn_Core, timeout: time.Duration) {
    assert(core.tls != nil, "the TLS pipe needs a curl connection")

    core.tls.recv_timeout = timeout

    received, code := curl.socket_recv(&core.tls.sock, core.recv_buf)

    if code == .Ok {
        // Delivered on a later tick so a completion never runs inside its own
        // submission, which is the ordering every caller here is written against.
        core.tls.recv_pending = received
        core.recv_op = nbio.next_tick_poly(core, tls_on_recv_delivered, core.loop)

        return
    }

    if code == .Again {
        core.recv_op = nbio.poll_poly(core.socket, .Receive, core, tls_on_recv_ready, timeout, core.loop)

        return
    }

    core.recv_op = nbio.next_tick_poly(core, tls_on_recv_failed, core.loop)
}

// Bytes were already in hand at submission time.
@(private)
tls_on_recv_delivered :: proc(op: ^nbio.Operation, core: ^Conn_Core) {
    assert(op == core.recv_op, "a TLS receive completion does not match the stored operation")
    core.recv_op = nil

    pipe_recv_completed(core, core.tls.recv_pending, .Ok)
}

@(private)
tls_on_recv_failed :: proc(op: ^nbio.Operation, core: ^Conn_Core) {
    assert(op == core.recv_op, "a TLS receive completion does not match the stored operation")
    core.recv_op = nil

    pipe_recv_completed(core, 0, .Failed)
}

// Parked on readability, so the read still has to happen.
@(private)
tls_on_recv_ready :: proc(op: ^nbio.Operation, core: ^Conn_Core) {
    assert(op == core.recv_op, "a TLS receive completion does not match the stored operation")
    core.recv_op = nil

    #partial switch op.poll.result {
    case .Timeout:
        pipe_recv_completed(core, 0, .Timed_Out)
        return

    case .Invalid_Argument, .Error:
        pipe_recv_completed(core, 0, .Failed)
        return
    }

    received, code := curl.socket_recv(&core.tls.sock, core.recv_buf)

    if code == .Ok {
        // Zero bytes with no error is the peer's EOF, exactly as on the plain arm.
        pipe_recv_completed(core, received, .Ok)
        return
    }

    if code == .Again {
        // Readable, but no plaintext came out: a TLS record that has not finished
        // arriving, or one carrying no application data (a session ticket). Not EOF —
        // reporting it as one would tear down a healthy connection mid-stream.
        core.recv_op = nbio.poll_poly(core.socket, .Receive, core, tls_on_recv_ready, core.tls.recv_timeout, core.loop)

        return
    }

    pipe_recv_completed(core, 0, .Failed)
}

@(private)
tls_submit_send :: proc(core: ^Conn_Core, batch: [][]byte, timeout: time.Duration) {
    assert(core.tls != nil, "the TLS pipe needs a curl connection")

    core.tls.send_pending = batch
    core.tls.send_offset = 0
    core.tls.send_deadline = time.time_add(time.now(), timeout) if timeout > 0 else {}

    tls_pump_send(core)
}

// Write as much of the batch as curl accepts, then wait for writability and resume.
// Completed frames are trimmed off the front, so the remaining work is always
// `send_pending[0][send_offset:]` followed by the rest.
@(private)
tls_pump_send :: proc(core: ^Conn_Core) {
    assert(core.tls != nil, "the TLS pipe needs a curl connection")
    assert(core.send_op == nil, "a TLS send is already waiting")

    tls := core.tls

    for len(tls.send_pending) > 0 {
        frame := tls.send_pending[0]
        assert(tls.send_offset < len(frame), "a frame was left on the queue with nothing to write")

        sent, code := curl.socket_send(&tls.sock, frame[tls.send_offset:])

        // A zero-byte accept is treated as backpressure rather than asserted on: it is
        // libcurl's behaviour to answer for, and parking cannot spin.
        if code == .Ok && sent > 0 {
            tls.send_offset += sent

            if tls.send_offset == len(frame) {
                tls.send_pending = tls.send_pending[1:]
                tls.send_offset = 0
            }

            continue
        }

        if code == .Again || code == .Ok {
            remaining, expired := tls_send_remaining(tls)
            if expired {
                tls_send_finished(core, .Timed_Out)

                return
            }

            core.send_op = nbio.poll_poly(core.socket, .Send, core, tls_on_send_ready, remaining, core.loop)

            return
        }

        core.send_op = nbio.next_tick_poly(core, tls_on_send_failed, core.loop)

        return
    }

    core.send_op = nbio.next_tick_poly(core, tls_on_send_done, core.loop)
}

@(private)
tls_on_send_ready :: proc(op: ^nbio.Operation, core: ^Conn_Core) {
    assert(op == core.send_op, "a TLS send completion does not match the stored operation")
    core.send_op = nil

    #partial switch op.poll.result {
    case .Timeout:
        tls_send_finished(core, .Timed_Out)
        return

    case .Invalid_Argument, .Error:
        tls_send_finished(core, .Failed)
        return
    }

    tls_pump_send(core)
}

@(private)
tls_on_send_done :: proc(op: ^nbio.Operation, core: ^Conn_Core) {
    assert(op == core.send_op, "a TLS send completion does not match the stored operation")
    core.send_op = nil

    tls_send_finished(core, .Ok)
}

@(private)
tls_on_send_failed :: proc(op: ^nbio.Operation, core: ^Conn_Core) {
    assert(op == core.send_op, "a TLS send completion does not match the stored operation")
    core.send_op = nil

    tls_send_finished(core, .Failed)
}

// What is left of the write's overall deadline. The bound covers the whole batch, so a
// peer accepting a byte at a time cannot extend it park by park.
@(private)
tls_send_remaining :: proc(tls: ^Tls_Pipe) -> (remaining: time.Duration, expired: bool) {
    if tls.send_deadline == (time.Time{}) {
        return nbio.NO_TIMEOUT, false
    }

    left := time.diff(time.now(), tls.send_deadline)
    if left <= 0 {
        return 0, true
    }

    return left, false
}

// The one exit from a TLS send: release the borrowed batch before the driver, which
// owns those frames, is told the write is over.
@(private)
tls_send_finished :: proc(core: ^Conn_Core, result: Io_Result) {
    core.tls.send_pending = nil
    core.tls.send_offset = 0
    core.tls.send_deadline = {}

    pipe_send_completed(core, result)
}
