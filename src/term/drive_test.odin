package term

import "core:nbio"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import ts "libs:testsupport"

// The relay differs per OS but owes callers the same contract, so the tests are shared
// and only the inject primitives are per-OS.

// Collects events for harness tests.
//
// Only `Key` values are retained long-term: `Paste` borrows the reader
// buffer and is invalid after the next paste/drain.
Harness :: struct {
    keys:          [dynamic]Key,
    done:          bool,
    input_closed:  bool,
    closed_reason: Input_Closed_Reason,
}

harness_on_event :: proc(user: rawptr, ev: Event) {
    h := (^Harness)(user)

    switch e in ev {
    case Key:
        append(&h.keys, e)
        // First complete key ends the wait for simple tests.
        h.done = true

    case Input_Closed:
        h.input_closed = true
        h.closed_reason = e.reason

    case Mouse, Paste, Resize:
    // Do not store Paste: it borrows the reader buffer.
    }
}

// Write everything, tolerating a nonblocking sink that reports "not now".
inject_write :: proc(w: Tty_Handle, data: string) -> bool {
    bytes := transmute([]u8)data
    off := 0
    stalls := 0

    for off < len(bytes) {
        n := inject_write_some(w, bytes[off:])
        if n > 0 {
            off += n
            stalls = 0
            continue
        }

        stalls += 1
        if stalls > 1000 do return false

        time.sleep(time.Millisecond)
    }

    return true
}

@(test)
test_drive_literal_key_via_pipe :: proc(t: ^testing.T) {
    err := nbio.acquire_thread_event_loop()
    testing.expect_value(t, err, nbio.General_Error.None)
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    src_r, src_w, ok := inject_open()
    testing.expect(t, ok, "pipe")
    defer {
        inject_close(src_r)
        inject_close(src_w)
    }

    h: Harness
    h.keys = make([dynamic]Key, context.allocator)
    defer delete(h.keys)

    d: Drive
    derr := drive_start(&d, loop, {enter_session = false, source = src_r}, harness_on_event, &h)
    testing.expect_value(t, derr, Drive_Error.None)
    defer drive_stop(&d)

    testing.expect(t, inject_write(src_w, "a"), "inject a")
    ts.nbio_run_until(t, &h.done, "key a")
    testing.expect(t, len(h.keys) >= 1, "one key")
    if len(h.keys) > 0 {
        testing.expect_value(t, h.keys[0].code, Key_Code.Char)
        testing.expect_value(t, h.keys[0].char, 'a')
    }
}

@(test)
test_drive_arrow_up_via_pipe :: proc(t: ^testing.T) {
    err := nbio.acquire_thread_event_loop()
    testing.expect_value(t, err, nbio.General_Error.None)
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    src_r, src_w, ok := inject_open()
    testing.expect(t, ok, "pipe")
    defer {
        inject_close(src_r)
        inject_close(src_w)
    }

    h: Harness
    h.keys = make([dynamic]Key, context.allocator)
    defer delete(h.keys)

    d: Drive
    derr := drive_start(&d, loop, {enter_session = false, source = src_r}, harness_on_event, &h)
    testing.expect_value(t, derr, Drive_Error.None)
    defer drive_stop(&d)

    testing.expect(t, inject_write(src_w, "\x1b[A"), "inject CSI up")
    ts.nbio_run_until(t, &h.done, "arrow up")
    testing.expect(t, len(h.keys) >= 1, "one key")
    if len(h.keys) > 0 do testing.expect_value(t, h.keys[0].code, Key_Code.Up)
}

@(test)
test_drive_burst_larger_than_one_read_is_lossless :: proc(t: ^testing.T) {
    err := nbio.acquire_thread_event_loop()
    testing.expect_value(t, err, nbio.General_Error.None)
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    src_r, src_w, ok := inject_open()
    testing.expect(t, ok, "pipe")
    defer {
        inject_close(src_r)
        inject_close(src_w)
    }
    testing.expect(t, inject_nonblocking(src_w), "nonblocking inject")

    h: Harness
    h.keys = make([dynamic]Key, context.allocator)
    defer delete(h.keys)

    d: Drive
    derr := drive_start(&d, loop, {enter_session = false, source = src_r}, harness_on_event, &h)
    testing.expect_value(t, derr, Drive_Error.None)
    defer drive_stop(&d)

    bytes: [DRIVE_READ_BYTES + 17]u8
    for &b in bytes {
        b = 'x'
    }

    sent := 0
    start := time.tick_now()
    for len(h.keys) < len(bytes) && time.tick_since(start) < 2 * time.Second {
        if sent < len(bytes) {
            if n := inject_write_some(src_w, bytes[sent:]); n > 0 do sent += n
        }

        _ = nbio.tick(5 * time.Millisecond)
    }

    testing.expect_value(t, sent, len(bytes))
    testing.expect_value(t, len(h.keys), len(bytes))
    for key in h.keys {
        testing.expect_value(t, key.char, 'x')
    }
}

@(test)
test_drive_stop_is_idempotent :: proc(t: ^testing.T) {
    err := nbio.acquire_thread_event_loop()
    testing.expect_value(t, err, nbio.General_Error.None)
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    src_r, src_w, ok := inject_open()
    testing.expect(t, ok, "pipe")
    defer {
        inject_close(src_r)
        inject_close(src_w)
    }

    h: Harness
    d: Drive
    derr := drive_start(&d, loop, {enter_session = false, source = src_r}, harness_on_event, &h)
    testing.expect_value(t, derr, Drive_Error.None)

    drive_stop(&d)
    drive_stop(&d)
    testing.expect(t, !d.live)
    testing.expect(t, !drive_is_input_open(&d))
}

@(test)
test_drive_double_start_rejected :: proc(t: ^testing.T) {
    err := nbio.acquire_thread_event_loop()
    testing.expect_value(t, err, nbio.General_Error.None)
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    src_r, src_w, ok := inject_open()
    testing.expect(t, ok, "pipe")
    defer {
        inject_close(src_r)
        inject_close(src_w)
    }

    h: Harness
    d: Drive
    opts := Drive_Options {
        enter_session = false,
        source        = src_r,
    }
    derr := drive_start(&d, loop, opts, harness_on_event, &h)
    testing.expect_value(t, derr, Drive_Error.None)
    defer drive_stop(&d)

    // Second start must not wipe the live drive.
    derr2 := drive_start(&d, loop, opts, harness_on_event, &h)
    testing.expect_value(t, derr2, Drive_Error.Invalid_Args)
    testing.expect(t, d.live)
}

@(test)
test_drive_esc_timeout_flushes_lone_esc :: proc(t: ^testing.T) {
    err := nbio.acquire_thread_event_loop()
    testing.expect_value(t, err, nbio.General_Error.None)
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    src_r, src_w, ok := inject_open()
    testing.expect(t, ok, "pipe")
    defer {
        inject_close(src_r)
        inject_close(src_w)
    }

    h: Harness
    h.keys = make([dynamic]Key, context.allocator)
    defer delete(h.keys)

    d: Drive
    derr := drive_start(
        &d,
        loop,
        {enter_session = false, source = src_r, esc_timeout = 20 * time.Millisecond},
        harness_on_event,
        &h,
    )
    testing.expect_value(t, derr, Drive_Error.None)
    defer drive_stop(&d)

    testing.expect(t, inject_write(src_w, "\x1b"), "inject lone ESC")
    // ESC is incomplete until timeout flush.
    ts.nbio_run_until(t, &h.done, "lone ESC flush")
    testing.expect(t, len(h.keys) >= 1, "esc key")
    if len(h.keys) > 0 do testing.expect_value(t, h.keys[0].code, Key_Code.Esc)
}

@(test)
test_drive_source_eof_marks_input_closed :: proc(t: ^testing.T) {
    err := nbio.acquire_thread_event_loop()
    testing.expect_value(t, err, nbio.General_Error.None)
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    src_r, src_w, ok := inject_open()
    testing.expect(t, ok, "pipe")
    // Close write end after start to signal EOF to the reader.
    defer inject_close(src_r)

    h: Harness
    d: Drive
    derr := drive_start(&d, loop, {enter_session = false, source = src_r}, harness_on_event, &h)
    testing.expect_value(t, derr, Drive_Error.None)
    defer drive_stop(&d)

    inject_close(src_w)
    ts.nbio_run_until(t, &h.input_closed, "input close on source EOF")
    testing.expect(t, !drive_is_input_open(&d), "input open flag")
    testing.expect(t, d.live, "drive stays live until stop")
    testing.expect_value(t, drive_input_closed_reason(&d), Input_Closed_Reason.Peer_EOF)
}

// Stop must not hang when the reader is parked waiting for input that never comes.
// On Windows that park is a blocking ReadFile, which only an explicit cancel releases.
@(test)
test_drive_stop_while_reader_idle :: proc(t: ^testing.T) {
    err := nbio.acquire_thread_event_loop()
    testing.expect_value(t, err, nbio.General_Error.None)
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    src_r, src_w, ok := inject_open()
    testing.expect(t, ok, "pipe")
    defer {
        inject_close(src_r)
        inject_close(src_w)
    }

    h: Harness
    d: Drive
    derr := drive_start(&d, loop, {enter_session = false, source = src_r}, harness_on_event, &h)
    testing.expect_value(t, derr, Drive_Error.None)

    // Nothing is ever written, so the reader is parked on the source.
    time.sleep(50 * time.Millisecond)

    start := time.tick_now()
    drive_stop(&d)
    elapsed := time.duration_milliseconds(time.tick_since(start))

    testing.expect(t, !d.live, "stopped")
    testing.expectf(t, elapsed < 2000, "stop took %.0fms waiting on an idle reader", elapsed)
}

// A live drive must keep one nbio op in flight, or `nbio.tick` returns immediately and
// the caller's loop spins. POSIX holds a source poll; Windows holds `idle_op`.
@(test)
test_drive_tick_blocks_while_idle :: proc(t: ^testing.T) {
    err := nbio.acquire_thread_event_loop()
    testing.expect_value(t, err, nbio.General_Error.None)
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    src_r, src_w, ok := inject_open()
    testing.expect(t, ok, "pipe")
    defer {
        inject_close(src_r)
        inject_close(src_w)
    }

    h: Harness
    d: Drive
    derr := drive_start(&d, loop, {enter_session = false, source = src_r}, harness_on_event, &h)
    testing.expect_value(t, derr, Drive_Error.None)
    defer drive_stop(&d)

    // Nothing is ever written, so the only thing that can end this tick is its timeout.
    start := time.tick_now()
    _ = nbio.tick(50 * time.Millisecond)
    elapsed := time.duration_milliseconds(time.tick_since(start))

    testing.expectf(t, elapsed >= 25, "tick returned after %.1fms; the loop had nothing to sleep on", elapsed)
}

// Flood inject without draining nbio so the relay backs up; drive_stop must still join
// promptly (regression for stop/join under backpressure).
Flood_Args :: struct {
    w:       Tty_Handle,
    stop:    bool,
    started: bool,
}

flood_main :: proc(data: rawptr) {
    a := (^Flood_Args)(data)
    chunk: [4096]u8
    for i in 0 ..< len(chunk) {
        chunk[i] = 'x'
    }

    sync.atomic_store(&a.started, true)
    for !sync.atomic_load(&a.stop) {
        n := inject_write_some(a.w, chunk[:])
        if n <= 0 do time.sleep(time.Millisecond)
    }
}

@(test)
test_drive_stop_under_backpressure :: proc(t: ^testing.T) {
    err := nbio.acquire_thread_event_loop()
    testing.expect_value(t, err, nbio.General_Error.None)
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    src_r, src_w, ok := inject_open()
    testing.expect(t, ok, "pipe")
    defer {
        inject_close(src_r)
        inject_close(src_w)
    }

    // Nonblocking so a full sink cannot pin the flood thread after the reader exits.
    testing.expect(t, inject_nonblocking(src_w), "nonblocking inject")

    h: Harness
    d: Drive
    derr := drive_start(&d, loop, {enter_session = false, source = src_r}, harness_on_event, &h)
    testing.expect_value(t, derr, Drive_Error.None)

    flood: Flood_Args
    flood.w = src_w
    th := thread.create_and_start_with_data(&flood, flood_main)
    testing.expect(t, th != nil, "flood thread")
    if th == nil {
        drive_stop(&d)
        return
    }

    // Wait until flood is writing, then give it time to fill buffers. Do not tick
    // nbio so the relay is not drained.
    for _ in 0 ..< 200 {
        if sync.atomic_load(&flood.started) do break

        time.sleep(time.Millisecond)
    }
    time.sleep(50 * time.Millisecond)

    // Stop must not hang waiting for a blocked writer.
    drive_stop(&d)
    testing.expect(t, !d.live, "stopped")

    sync.atomic_store(&flood.stop, true)
    thread.join(th)
    thread.destroy(th)
}
