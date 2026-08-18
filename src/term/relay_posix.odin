#+build linux, darwin
package term

import "core:fmt"
import "core:mem"
import "core:nbio"
import "core:net"
import "core:sys/posix"

// Direct source-read state. The source is borrowed and its descriptor flags are never
// changed: stdin may share its open-file description with terminal output.
Relay_State :: struct {
    source_sock: net.TCP_Socket,
    source_op:   ^nbio.Operation,
    read_buf:    [DRIVE_READ_BYTES]u8,
}

drive_start_posix :: proc(
    d: ^Drive,
    loop: ^nbio.Event_Loop,
    opts: Drive_Options,
    on_event: Event_Handler,
    user: rawptr,
    allocator: mem.Allocator,
) -> Drive_Error {
    if err := drive_start_common(d, loop, opts, on_event, user, allocator); err != .None do return err

    flags_raw := posix.fcntl(d.source, .GETFL, 0)
    if flags_raw < 0 {
        drive_release_term(d)
        return .Source_Failed
    }

    // Readiness polling works with a blocking descriptor. Do not associate this borrowed
    // source: Darwin's nbio association sets O_NONBLOCK on the shared open-file description.
    d.relay.source_sock = net.TCP_Socket(d.source)

    // Hosts without DEC 2048 (tmux, classic TTYs): SIGWINCH → self-pipe → nbio.poll.
    // Soft-fail if init/associate fails; keys still work, resize just stays stale.
    if d.has_session && !d.caps.in_band_resize do drive_try_start_resize(d, loop)

    d.live = true
    drive_arm_source(d)
    drive_arm_resize(d)

    // Negotiation / prior pushes may have left complete events or a partial ESC.
    if !drive_drain_reader(d) do return .Reader_Failed

    return .None
}

drive_arm_source :: proc(d: ^Drive) {
    assert(d != nil, "drive_arm_source needs a drive")

    if d.stopping || !drive_is_input_open(d) do return

    assert(d.relay.source_sock == net.TCP_Socket(d.source), "source poll handle changed")
    assert(d.relay.source_op == nil, "drive_arm_source with in-flight op")
    d.relay.source_op = nbio.poll_poly(d.relay.source_sock, .Receive, d, drive_on_source_poll, l = d.loop)
}

drive_cancel_source :: proc(d: ^Drive) {
    assert(d != nil, "drive_cancel_source needs a drive")

    if d.relay.source_op != nil {
        nbio.remove(d.relay.source_op)
        d.relay.source_op = nil
    }
}

// Read one bounded batch per readiness completion, then re-arm. This preserves event-loop
// fairness while level readiness delivers the rest of a burst on later ticks.
drive_on_source_poll :: proc(op: ^nbio.Operation, d: ^Drive) {
    assert(op != nil, "source poll needs an operation")
    assert(d != nil, "source poll needs a drive")
    assert(d.relay.source_op == op, "source poll completed for another operation")
    d.relay.source_op = nil

    if d.stopping || !drive_is_input_open(d) do return

    if op.poll.result != .Ready {
        drive_mark_input_closed(d, .Recv_Error)
        return
    }

    n := posix.read(d.source, raw_data(d.relay.read_buf[:]), len(d.relay.read_buf))
    if n > 0 {
        if !drive_feed(d, d.relay.read_buf[:n]) do return

        drive_arm_source(d)
        return
    }

    if n == 0 {
        drive_mark_input_closed(d, .Peer_EOF)
        return
    }

    #partial switch posix.errno() {
    case .EINTR, .EAGAIN:
        drive_arm_source(d)

    case:
        drive_mark_input_closed(d, .Recv_Error)
    }
}

// Install SIGWINCH notifier and associate its pipe with nbio. Call only when
// `!caps.in_band_resize` and a real session tty is live. Failure is non-fatal.
drive_try_start_resize :: proc(d: ^Drive, loop: ^nbio.Event_Loop) {
    assert(d != nil, "drive_try_start_resize needs a drive")
    assert(loop != nil, "drive_try_start_resize needs a loop")
    assert(d.has_session, "drive_try_start_resize needs a session tty")
    assert(!d.has_resize, "drive_try_start_resize already armed")

    n, rerr := resize_notifier_init(d.session.tty)
    if rerr != .None {
        fmt.eprintfln("term: SIGWINCH notifier init failed (%v); resize disabled", rerr)
        return
    }

    // Pipe fd is already O_NONBLOCK; cast only so nbio.poll can watch it.
    sock := net.TCP_Socket(n.read_fd)
    if aerr := nbio.associate_socket(sock, loop); aerr != .None {
        resize_notifier_destroy(&n)
        fmt.eprintfln("term: SIGWINCH pipe associate failed (%v); resize disabled", aerr)
        return
    }

    d.resize = n
    d.resize_sock = sock
    d.has_resize = true
}

// Drop in-flight resize poll and destroy the notifier. Idempotent.
drive_teardown_resize :: proc(d: ^Drive) {
    assert(d != nil, "drive_teardown_resize needs a drive")

    drive_cancel_resize(d)

    if d.has_resize {
        resize_notifier_destroy(&d.resize)
        d.resize = {}
        d.resize_sock = 0
        d.has_resize = false
    }
}

drive_cancel_resize :: proc(d: ^Drive) {
    assert(d != nil, "drive_cancel_resize needs a drive")

    if d.resize_op != nil {
        nbio.remove(d.resize_op)
        d.resize_op = nil
    }
}

drive_arm_resize :: proc(d: ^Drive) {
    assert(d != nil, "drive_arm_resize needs a drive")

    if d.stopping || !d.live || !d.has_resize do return

    assert(d.resize_op == nil, "drive_arm_resize with in-flight op")
    d.resize_op = nbio.poll_poly(d.resize_sock, .Receive, d, drive_on_resize_poll, l = d.loop)
}

// SIGWINCH self-pipe became readable: consume → update size → emit Resize → re-arm.
drive_on_resize_poll :: proc(op: ^nbio.Operation, d: ^Drive) {
    assert(d != nil, "drive_on_resize_poll needs a drive")
    assert(op != nil, "drive_on_resize_poll needs an operation")
    d.resize_op = nil

    if d.stopping || !d.live || !d.has_resize do return

    if op.poll.result == .Ready {
        size, cerr := resize_notifier_consume(&d.resize)
        if cerr == .None {
            d.size = size
            if d.on_event != nil do d.on_event(d.user, Resize{})
        }
        // Size_Query_Failed: soft skip emit; still re-arm for later resizes.
    }

    // Timeout/Error/Invalid_Argument: re-arm while live so a transient failure
    // does not permanently disable SIGWINCH. Destroy tears down on stop.
    drive_arm_resize(d)
}

// Must run on the nbio I/O thread because it removes in-flight operations.
drive_stop_posix :: proc(d: ^Drive) {
    assert(d != nil, "drive_stop_posix needs a drive")

    if !d.live do return

    assert(d.loop == nbio.current_thread_event_loop(), "drive_stop off the I/O thread")
    d.stopping = true
    drive_cancel_esc(d)
    drive_cancel_source(d)
    drive_teardown_resize(d)
    drive_release_term(d)
    d.live = false
}
