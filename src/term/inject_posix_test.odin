#+build linux, darwin
package term

import "core:nbio"
import "core:sys/posix"
import "core:testing"

// Inject primitives for drive_test.odin: a plain pipe standing in for the tty.

inject_open :: proc() -> (r, w: Tty_Handle, ok: bool) {
    fds: [2]posix.FD
    if posix.pipe(&fds) != .OK {
        return -1, -1, false
    }

    return fds[0], fds[1], true
}

inject_close :: proc(h: Tty_Handle) {
    posix.close(h)
}

// One write attempt; <= 0 means would-block or error.
inject_write_some :: proc(w: Tty_Handle, data: []u8) -> int {
    return int(posix.write(w, raw_data(data), uint(len(data))))
}

inject_nonblocking :: proc(w: Tty_Handle) -> bool {
    return posix.fcntl(w, .SETFL, posix.O_Flags{.NONBLOCK}) != -1
}

@(test)
test_drive_posix_preserves_aliased_source_flags :: proc(t: ^testing.T) {
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

    alias_raw := posix.fcntl(src_r, .DUPFD, 0)
    testing.expect(t, alias_raw >= 0, "source alias")
    if alias_raw < 0 {
        return
    }
    alias := posix.FD(alias_raw)
    defer inject_close(alias)

    original_raw := posix.fcntl(src_r, .GETFL, 0)
    testing.expect(t, original_raw >= 0, "source flags")
    original := transmute(posix.O_Flags)original_raw
    alias_original_raw := posix.fcntl(alias, .GETFL, 0)
    testing.expect(t, alias_original_raw >= 0, "source alias flags")
    testing.expect_value(t, transmute(posix.O_Flags)alias_original_raw, original)

    h: Harness
    d: Drive
    derr := drive_start(&d, loop, {enter_session = false, source = src_r}, harness_on_event, &h)
    testing.expect_value(t, derr, Drive_Error.None)

    live_raw := posix.fcntl(src_r, .GETFL, 0)
    testing.expect(t, live_raw >= 0, "live source flags")
    testing.expect_value(t, transmute(posix.O_Flags)live_raw, original)
    alias_live_raw := posix.fcntl(alias, .GETFL, 0)
    testing.expect(t, alias_live_raw >= 0, "live source alias flags")
    testing.expect_value(t, transmute(posix.O_Flags)alias_live_raw, original)

    drive_stop(&d)
    restored_raw := posix.fcntl(src_r, .GETFL, 0)
    testing.expect(t, restored_raw >= 0, "stopped source flags")
    testing.expect_value(t, transmute(posix.O_Flags)restored_raw, original)
    alias_stopped_raw := posix.fcntl(alias, .GETFL, 0)
    testing.expect(t, alias_stopped_raw >= 0, "stopped source alias flags")
    testing.expect_value(t, transmute(posix.O_Flags)alias_stopped_raw, original)
}
