package term

import "core:io"
import "core:mem"
import "core:nbio"
import "core:net"
import "core:time"

// How long a partial escape sequence may sit before `reader_flush` (lone Esc).
ESC_TIMEOUT :: 50 * time.Millisecond

// Application sink. Always invoked on the nbio I/O thread.
Event_Handler :: proc(user: rawptr, ev: Event)

// One OS read granule. Reader accepts larger public pushes, but the transports keep their
// resident buffers small and feed a burst over successive readiness callbacks.
DRIVE_READ_BYTES :: 8 * 1024
#assert(DRIVE_READ_BYTES <= MAX_PUSH_BYTES)

// Failure modes of `drive_start`. `None` is success.
Drive_Error :: enum {
    None = 0,
    Invalid_Args,
    Session_Failed,
    Source_Failed,
    Thread_Failed,
    Reader_Failed,
}

// Options for `drive_start`.
//
// Zero value is not enough for a real session: when `enter_session` is true you
// must set `tty` (terminal handle) and `out` (mode-sequence writer, usually
// stdout). Harness mode sets `enter_session = false` and `source` to an inject FD.
Drive_Options :: struct {
    // Modes for `session_enter`. Ignored when `enter_session` is false.
    session:       Options,

    // When true, call `session_enter` on `tty` and restore on stop.
    // Requires non-nil `out` and a usable `tty`.
    enter_session: bool,

    // TTY for raw mode and input when `enter_session` is true. On Windows this is the
    // console INPUT handle.
    tty:           Tty_Handle,

    // Console screen-buffer OUTPUT handle, required on Windows for a real session and
    // ignored on POSIX, where `tty` is used for size queries too.
    size_handle:   Tty_Handle,

    // Input used only when `enter_session` is false, normally a harness inject pipe.
    source:        Tty_Handle,

    // Writer for mode sequences when entering a session (usually stdout).
    // Required when `enter_session` is true.
    out:           io.Writer,

    // How long a partial CSI/ESC may wait before flush. Zero → ESC_TIMEOUT.
    esc_timeout:   time.Duration,
}

// Default options: negotiate a real session (caller still must set `tty` and `out`).
DRIVE_DEFAULT_OPTIONS :: Drive_Options {
    session       = DEFAULT_OPTIONS,
    enter_session = true,
    esc_timeout   = ESC_TIMEOUT,
}

// One live term→nbio drive. Zero before `drive_start`; tear down with `drive_stop`.
Drive :: struct {
    // Borrowed event loop; must outlive the drive.
    loop:         ^nbio.Event_Loop,
    on_event:     Event_Handler,
    user:         rawptr,
    session:      Session,
    has_session:  bool,
    reader:       Reader,

    // Reader source handle (tty or harness inject pipe).
    source:       Tty_Handle,

    // Set when stop begins; every transport callback honors it.
    stopping:     bool,

    // In-flight partial-escape timeout; removed on stop.
    esc_op:       ^nbio.Operation,
    esc_timeout:  time.Duration,
    size:         Size,
    caps:         Capabilities,

    // Handle `get_size` acts on; see `Drive_Options.size_handle`.
    size_handle:  Tty_Handle,

    // Set true after start until stop finishes.
    live:         bool,

    // Last input-close reason; `.None` while input is open.
    input_closed: Input_Closed_Reason,

    // Per-OS input transport: direct descriptor readiness on POSIX, one handoff slot and
    // a blocking reader thread on Windows.
    relay:        Relay_State,

    // SIGWINCH path when session negotiate did not enable DEC 2048 (POSIX only;
    // Windows never arms these). Pipe read end is cast to TCP_Socket for
    // nbio.poll only (not a real TCP socket).
    resize:       Resize_Notifier,
    has_resize:   bool,
    resize_op:    ^nbio.Operation,
    resize_sock:  net.TCP_Socket,
}
#assert(size_of(Drive) <= 12 * 1024, "Drive must stay below its bounded transport budget")

// Start the platform input transport. On failure, no resources are left live.
// Refusing a second start on a live drive returns `.Invalid_Args` (does not wipe it).
drive_start :: proc(
    d: ^Drive,
    loop: ^nbio.Event_Loop,
    opts: Drive_Options,
    on_event: Event_Handler,
    user: rawptr = nil,
    allocator := context.allocator,
) -> Drive_Error {
    assert(d != nil, "drive_start needs storage")
    assert(loop != nil, "drive_start needs an event loop")
    assert(on_event != nil, "drive_start needs an event handler")

    if d.live {
        return .Invalid_Args
    }

    when ODIN_OS == .Windows {
        return drive_start_windows(d, loop, opts, on_event, user, allocator)
    } else {
        return drive_start_posix(d, loop, opts, on_event, user, allocator)
    }
}

// Drop the terminal side of a drive: leave the session if one was entered, then destroy
// the reader. Used by both the failed-start unwind and the stop paths.
drive_release_term :: proc(d: ^Drive) {
    assert(d != nil, "drive_release_term needs a drive")

    if d.has_session {
        session_leave(&d.session)
        d.has_session = false
    }

    reader_destroy(&d.reader)
}

// Shared prologue for both transports: reset the drive, resolve the source and size handles,
// bring up the reader, and enter the session when asked. Each arm then wires its own
// transport on top.
drive_start_common :: proc(
    d: ^Drive,
    loop: ^nbio.Event_Loop,
    opts: Drive_Options,
    on_event: Event_Handler,
    user: rawptr,
    allocator: mem.Allocator,
) -> Drive_Error {
    assert(d != nil, "drive_start needs storage")
    assert(loop != nil, "drive_start needs an event loop")
    assert(on_event != nil, "drive_start needs an event handler")
    assert(!d.live, "drive_start on a live drive")

    d^ = {}
    d.loop = loop
    d.on_event = on_event
    d.user = user
    d.esc_timeout = opts.esc_timeout if opts.esc_timeout > 0 else ESC_TIMEOUT
    d.source = opts.tty if opts.enter_session else opts.source

    when ODIN_OS == .Windows {
        if opts.enter_session && opts.size_handle == nil {
            return .Invalid_Args
        }

        d.size_handle = opts.size_handle
    } else {
        d.size_handle = opts.tty
    }

    reader_init(&d.reader, allocator)

    if !opts.enter_session {
        // Harness: no raw mode; invent a usable size for callers.
        d.size = {
            width  = 80,
            height = 24,
        }

        return .None
    }

    if opts.out.procedure == nil {
        reader_destroy(&d.reader)
        return .Invalid_Args
    }

    // Size before raw mode; some hosts are flaky with TIOCGWINSZ afterward.
    if size, gerr := get_size(d.size_handle); gerr == .None {
        d.size = size
    } else {
        d.size = {
            width  = 80,
            height = 24,
        }
    }

    // Session borrows the reader for negotiation only.
    session, serr := session_enter(opts.tty, d.size_handle, opts.out, &d.reader, opts.session)
    if serr != .None {
        reader_destroy(&d.reader)
        return .Session_Failed
    }

    d.session = session
    d.has_session = true
    d.caps = session.caps

    return .None
}

// Idempotent. Safe if start failed or was never called.
//
// Must run on the nbio I/O thread: it removes in-flight ops and, on Windows, joins the
// reader. Calling from another thread races the reactor and can deadlock under backpressure.
drive_stop :: proc(d: ^Drive) {
    if d == nil || !d.live {
        return
    }

    when ODIN_OS == .Windows {
        drive_stop_windows(d)
    } else {
        drive_stop_posix(d)
    }
}

// Whether the transport is still feeding the reader.
drive_is_input_open :: proc(d: ^Drive) -> bool {
    return d != nil && d.live && !d.stopping && d.input_closed == .None
}

// Why input closed; `.None` while open or before start.
drive_input_closed_reason :: proc(d: ^Drive) -> Input_Closed_Reason {
    if d == nil {
        return .None
    }

    return d.input_closed
}

// Push bytes from the transport into the reader and emit events. False means the Reader
// failed and the drive was stopped after reporting `.Reader_Failed`.
drive_feed :: proc(d: ^Drive, bytes: []u8) -> bool {
    assert(d != nil, "drive_feed needs a drive")
    assert(d.loop == nbio.current_thread_event_loop(), "drive_feed off the I/O thread")

    if len(bytes) == 0 || d.stopping {
        return true
    }

    if err := reader_push(&d.reader, bytes); err != .None {
        drive_reader_failed(d)
        return false
    }

    return drive_drain_reader(d)
}

drive_drain_reader :: proc(d: ^Drive) -> bool {
    assert(d != nil, "drive_drain_reader needs a drive")

    for {
        ev, err := reader_next(&d.reader)
        if err != .None {
            drive_reader_failed(d)
            return false
        }

        if ev == nil {
            break
        }

        // Best-effort size refresh on in-band resize when we have a session.
        if _, is_resize := ev.(Resize); is_resize {
            if d.has_session {
                if size, gerr := get_size(d.size_handle); gerr == .None {
                    d.size = size
                }
            }
        }

        if d.on_event != nil {
            d.on_event(d.user, ev)
        }

        // Event handlers may stop and release the drive synchronously.
        if !d.live || d.stopping {
            return true
        }
    }

    // Partial sequence: arm ESC timeout. More bytes will re-arm.
    if len(reader_pending(&d.reader)) > 0 {
        drive_arm_esc(d)
    } else {
        drive_cancel_esc(d)
    }

    return true
}

// Reader errors are fatal to the byte stream: continuing after a dropped batch could
// reinterpret the suffix of an escape sequence or paste. Report once, then restore/stop.
drive_reader_failed :: proc(d: ^Drive) {
    assert(d != nil, "reader failure needs a drive")
    assert(d.live, "reader failure on a dead drive")

    drive_mark_input_closed(d, .Reader_Failed)
    if d.live {
        drive_stop(d)
    }
}

drive_arm_esc :: proc(d: ^Drive) {
    assert(d != nil, "drive_arm_esc needs a drive")

    drive_cancel_esc(d)
    d.esc_op = nbio.timeout_poly(d.esc_timeout, d, drive_on_esc_timeout, d.loop)
}

drive_cancel_esc :: proc(d: ^Drive) {
    assert(d != nil, "drive_cancel_esc needs a drive")

    if d.esc_op != nil {
        nbio.remove(d.esc_op)
        d.esc_op = nil
    }
}

drive_on_esc_timeout :: proc(_: ^nbio.Operation, d: ^Drive) {
    assert(d != nil, "drive_on_esc_timeout needs a drive")
    d.esc_op = nil
    if d.stopping || !d.live {
        return
    }

    ev := reader_flush(&d.reader)
    if ev != nil && d.on_event != nil {
        d.on_event(d.user, ev)
    }
}

// Mark input closed once and emit the lifecycle event. Does not call `drive_stop`.
drive_mark_input_closed :: proc(d: ^Drive, reason: Input_Closed_Reason) {
    assert(d != nil, "drive_mark_input_closed needs a drive")
    assert(reason != .None, "drive_mark_input_closed needs a reason")

    if d.input_closed != .None {
        return
    }

    d.input_closed = reason
    drive_cancel_esc(d)

    if d.on_event != nil {
        d.on_event(d.user, Input_Closed{reason = reason})
    }
}
