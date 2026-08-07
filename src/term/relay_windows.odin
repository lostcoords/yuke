#+build windows
package term

import "core:fmt"
import "core:mem"
import "core:nbio"
import "core:sync"
import "core:sys/windows"
import "core:thread"
import "core:time"

// A console HANDLE cannot be IOCP-associated and `nbio.poll` is socket-only here, so the
// reader blocks in `ReadFile` and hands one bounded byte batch to the loop at a time.

// Gap between stop's cancel attempts while the reader is still running. Short because a
// cancelled read returns in microseconds, and stop pays at least one of these.
RELAY_STOP_RETRY :: 1 * time.Millisecond

// Cancel attempts before stop complains once. It never gives up: the reader holds
// pointers into the Drive.
RELAY_STOP_WARN_RETRIES :: 1000

// Only the existence of this op matters, not its period: input latency comes from the
// reader's wake, which breaks the sleep immediately.
RELAY_IDLE_HEARTBEAT :: 1 * time.Second

// Lives inside the relay. `drive` is only passed back as the callback's user pointer and
// is never dereferenced off the loop thread.
Relay_Thread_Args :: struct {
    source:   windows.HANDLE,
    relay:    ^Relay_State,
    drive:    ^Drive,
    loop:     ^nbio.Event_Loop,
    stopping: ^bool,
    exited:   bool,
}

// Exactly one source batch may wait for the loop. Backpressure stays in the OS console or
// pipe buffer while this slot is occupied, so no input is dropped and no byte ring is needed.
Relay_State :: struct {
    mutex:        sync.Mutex,
    space:        sync.Cond,
    buf:          [DRIVE_READ_BYTES]u8,
    count:        int,
    scheduled:    bool,
    closed:       bool,
    close_reason: Input_Closed_Reason,
    args:         Relay_Thread_Args,
    thread:       ^thread.Thread,
    idle_op:      ^nbio.Operation,
    dispatch_op:  ^nbio.Operation,
}

drive_start_windows :: proc(
    d: ^Drive,
    loop: ^nbio.Event_Loop,
    opts: Drive_Options,
    on_event: Event_Handler,
    user: rawptr,
    allocator: mem.Allocator,
) -> Drive_Error {
    if err := drive_start_common(d, loop, opts, on_event, user, allocator); err != .None {
        return err
    }

    q := &d.relay
    q.args = {
        source   = d.source,
        relay    = q,
        drive    = d,
        loop     = loop,
        stopping = &d.stopping,
    }
    assert(q.args.relay == q, "relay args point at another drive's slot")

    // Set before the thread starts: the dispatch it schedules bails on a dead drive.
    d.live = true
    q.thread = thread.create_and_start_with_data(&q.args, relay_thread_main)
    if q.thread == nil {
        d.live = false
        drive_release_term(d)
        return .Thread_Failed
    }

    drive_arm_idle(d)

    // Negotiation may have left complete events or a partial ESC in the reader.
    if !drive_drain_reader(d) {
        return .Reader_Failed
    }

    return .None
}

// One outstanding op so the caller's loop sleeps; without it `nbio.tick` returns
// immediately and the loop spins.
drive_arm_idle :: proc(d: ^Drive) {
    assert(d != nil, "drive_arm_idle needs a drive")
    assert(d.relay.idle_op == nil, "drive_arm_idle with an op already armed")

    if d.stopping || !d.live {
        return
    }

    d.relay.idle_op = nbio.timeout_poly(RELAY_IDLE_HEARTBEAT, d, drive_on_idle, d.loop)
}

drive_cancel_idle :: proc(d: ^Drive) {
    assert(d != nil, "drive_cancel_idle needs a drive")

    if d.relay.idle_op != nil {
        nbio.remove(d.relay.idle_op)
        d.relay.idle_op = nil
    }
}

drive_on_idle :: proc(_: ^nbio.Operation, d: ^Drive) {
    assert(d != nil, "idle heartbeat needs a drive")
    d.relay.idle_op = nil

    drive_poll_size(d)
    drive_arm_idle(d)
}

// No SIGWINCH here, and DEC 2048 is unrecognized by conhost and Windows Terminal, so the
// size is sampled on the heartbeat instead. Loop-thread only.
drive_poll_size :: proc(d: ^Drive) {
    assert(d != nil, "drive_poll_size needs a drive")
    assert(d.loop == nbio.current_thread_event_loop(), "drive_poll_size off the I/O thread")

    if d.stopping || !d.live || !d.has_session {
        return
    }

    size, gerr := get_size(d.size_handle)
    if gerr != .None || size == d.size {
        return
    }

    d.size = size

    if d.on_event != nil {
        d.on_event(d.user, Resize{})
    }
}

// Must run on the nbio I/O thread: it removes in-flight ops and joins the reader.
drive_stop_windows :: proc(d: ^Drive) {
    assert(d != nil, "drive_stop_windows needs a drive")

    if !d.live {
        return
    }

    assert(d.loop == nbio.current_thread_event_loop(), "drive_stop off the I/O thread")
    assert(d.relay.thread != nil, "live Windows drive without a reader thread")

    sync.atomic_store(&d.stopping, true)

    // Taking the mutex first waits out a reader between its `stopping` check and
    // `cond_wait`, so the broadcast cannot be missed.
    q := &d.relay
    sync.mutex_lock(&q.mutex)
    sync.mutex_unlock(&q.mutex)
    sync.cond_broadcast(&q.space)

    drive_cancel_esc(d)
    drive_cancel_idle(d)
    drive_cancel_relay_dispatch(d)

    // CancelIoEx aborts only a pending read, so a stop that beats the reader into
    // ReadFile is a no-op and must be re-issued.
    source := d.source
    retries := 0
    for !thread.is_done(q.thread) {
        windows.CancelIoEx(source, nil)
        time.sleep(RELAY_STOP_RETRY)
        retries += 1

        if retries == RELAY_STOP_WARN_RETRIES {
            fmt.eprintln("term: reader thread has not stopped; still cancelling")
        }
    }

    thread.join(q.thread)
    assert(sync.atomic_load(&q.args.exited), "reader thread finished without running its exit path")
    thread.destroy(q.thread)
    q.thread = nil

    // After the join: restoring console mode under a pending read changes what the
    // console hands back mid-translation.
    drive_release_term(d)
    d.live = false
}

// Block on the source and publish each read through the single handoff slot.
relay_thread_main :: proc(data: rawptr) {
    assert(data != nil, "relay_thread_main needs args")
    args := (^Relay_Thread_Args)(data)
    assert(args.stopping != nil, "relay thread needs a stopping flag")
    assert(args.relay != nil, "relay thread needs a handoff slot")
    assert(args.drive != nil && args.loop != nil, "relay thread needs a dispatch target")
    assert(!sync.atomic_load(&args.exited), "relay thread ran twice")

    // `.None` means stopped on request — nothing to report to the app.
    reason := Input_Closed_Reason.None

    for !sync.atomic_load(args.stopping) {
        if !relay_slot_wait_empty(args) {
            break
        }

        read: windows.DWORD
        if !windows.ReadFile(args.source, raw_data(args.relay.buf[:]), DRIVE_READ_BYTES, &read, nil) {
            err := windows.GetLastError()

            // Our own stop cancelled the read; an external cancellation is an input error.
            if err == windows.ERROR_OPERATION_ABORTED && sync.atomic_load(args.stopping) {
                break
            }

            reason = .Peer_EOF if err == windows.ERROR_BROKEN_PIPE || err == windows.ERROR_HANDLE_EOF else .Recv_Error
            break
        }

        if read == 0 {
            reason = .Peer_EOF
            break
        }

        assert(int(read) <= len(args.relay.buf), "ReadFile reported more bytes than the slot holds")
        if !relay_slot_publish(args, int(read)) {
            break
        }
    }

    if reason != .None {
        relay_slot_close(args, reason)
    }

    sync.atomic_store(&args.exited, true)
}

// Wait until the loop has copied the previous slot into Reader. The stop-side mutex
// handshake plus broadcast makes this wait lossless without a polling timeout.
relay_slot_wait_empty :: proc(args: ^Relay_Thread_Args) -> bool {
    assert(args != nil && args.relay != nil, "slot wait needs args")

    q := args.relay
    sync.mutex_lock(&q.mutex)
    for q.count != 0 && !sync.atomic_load(args.stopping) {
        sync.cond_wait(&q.space, &q.mutex)
    }

    stopped := sync.atomic_load(args.stopping)
    if !stopped {
        assert(q.count == 0 && !q.scheduled, "empty slot still has a dispatch")
    }
    sync.mutex_unlock(&q.mutex)

    return !stopped
}

// Publish bytes already written into the empty slot and schedule exactly one loop dispatch.
relay_slot_publish :: proc(args: ^Relay_Thread_Args, count: int) -> bool {
    assert(args != nil && args.relay != nil, "slot publish needs args")
    assert(count > 0 && count <= len(args.relay.buf), "slot publish count out of range")

    q := args.relay
    sync.mutex_lock(&q.mutex)

    if sync.atomic_load(args.stopping) {
        sync.mutex_unlock(&q.mutex)
        return false
    }

    assert(q.count == 0 && !q.scheduled, "publishing into an occupied slot")
    q.count = count
    q.scheduled = true
    q.dispatch_op = nbio.next_tick_poly(args.drive, drive_on_relay_dispatch, args.loop)
    sync.mutex_unlock(&q.mutex)
    return true
}

// Record why the reader stopped. Any published bytes were consumed before the next read,
// so closure cannot overtake input with a one-slot handoff.
relay_slot_close :: proc(args: ^Relay_Thread_Args, reason: Input_Closed_Reason) {
    assert(args != nil && args.relay != nil, "slot close needs args")
    assert(reason != .None, "slot close needs a reason")

    q := args.relay
    sync.mutex_lock(&q.mutex)
    assert(q.count == 0 && !q.scheduled, "slot closed with input still pending")
    assert(!q.closed, "slot closed twice")
    q.closed = true
    q.close_reason = reason

    schedule := !sync.atomic_load(args.stopping)
    if schedule {
        q.scheduled = true
        q.dispatch_op = nbio.next_tick_poly(args.drive, drive_on_relay_dispatch, args.loop)
    }
    sync.mutex_unlock(&q.mutex)
}

// Cancel a queued cross-thread dispatch before Drive storage can be reused. The worker can
// no longer schedule after `stopping` plus the stop-side mutex handshake.
drive_cancel_relay_dispatch :: proc(d: ^Drive) {
    assert(d != nil, "relay dispatch cancel needs a drive")

    q := &d.relay
    sync.mutex_lock(&q.mutex)
    op := q.dispatch_op
    q.dispatch_op = nil
    q.scheduled = false
    sync.mutex_unlock(&q.mutex)

    if op != nil {
        nbio.remove(op)
    }
}

// Loop thread. Copy the slot into Reader before releasing the worker to overwrite it, then
// parse and invoke application callbacks without holding the cross-thread mutex.
drive_on_relay_dispatch :: proc(op: ^nbio.Operation, d: ^Drive) {
    assert(op != nil, "relay dispatcher needs an operation")
    assert(d != nil, "relay dispatcher needs a drive")
    assert(d.loop == nbio.current_thread_event_loop(), "relay dispatcher ran off the drive's loop thread")

    q := &d.relay
    sync.mutex_lock(&q.mutex)
    assert(q.dispatch_op == op, "relay dispatcher completed for another operation")
    q.dispatch_op = nil
    assert(q.scheduled, "relay dispatcher fired without being scheduled")
    assert(!q.closed || q.close_reason != .None, "closed relay slot without a reason")

    if !d.live || d.stopping {
        q.scheduled = false
        sync.mutex_unlock(&q.mutex)
        sync.cond_signal(&q.space)
        return
    }

    n := q.count
    closed := q.closed
    reason := q.close_reason
    push_err := Reader_Error.None
    if n > 0 {
        push_err = reader_push(&d.reader, q.buf[:n])
    }

    q.count = 0
    q.scheduled = false
    sync.mutex_unlock(&q.mutex)
    sync.cond_signal(&q.space)

    assert(n > 0 || closed, "relay dispatcher woke with nothing to deliver")

    if push_err != .None {
        drive_reader_failed(d)
        return
    }

    if n > 0 {
        if !drive_drain_reader(d) {
            return
        }
    }

    // The app handler may have stopped the drive while draining input.
    if !d.live || d.stopping {
        return
    }

    if closed {
        drive_mark_input_closed(d, reason)
    }
}
