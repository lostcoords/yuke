/*
yuke client (default subcommand): term drive + QuickJS (`yuke:term`) + ui paint.
*/
package tui

import "core:bufio"
import "core:fmt"
import "core:io"
import "core:nbio"
import "core:os"
import "core:strings"
import term "src:term"

// Sized to hold a full repaint of a large terminal so a frame is one write.
FRAME_BUF_BYTES :: 256 * 1024

App :: struct {
    drive: term.Drive,
    host:  Host,
}

// `drive_start` drains leftover negotiation bytes before `host_init` can run, so both
// callbacks must tolerate a host that does not exist yet. Pre-init input has nowhere to go.
on_event :: proc(user: rawptr, ev: term.Event) {
    app := (^App)(user)
    if app.host.js.ctx == nil {
        return
    }

    host_on_term_event(&app.host, ev)
}

// Run the interactive TUI client until the host is done. The binary's default subcommand.
run :: proc() {
    if err := nbio.acquire_thread_event_loop(); err != nil {
        fmt.eprintfln("nbio: %v", err)
        os.exit(1)
    }
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    // Buffered on purpose. `src/ui` paints cell by cell and treats `io.flush` as "the
    // frame reached the terminal": unbuffered, every cell is a syscall and flush maps to
    // fsync, which fails on any tty, so no frame ever commits and every frame is a full
    // redraw.
    stdout_buf: bufio.Writer
    bufio.writer_init(&stdout_buf, io.to_writer(os.to_stream(os.stdout)), FRAME_BUF_BYTES)
    defer bufio.writer_destroy(&stdout_buf)
    out := bufio.writer_to_writer(&stdout_buf)

    app: App
    opts := term.DRIVE_DEFAULT_OPTIONS
    opts.tty = stdin_handle()
    opts.size_handle = stdout_handle()
    opts.out = out
    opts.session.alternate_screen = true
    opts.session.negotiate = true

    derr := term.drive_start(&app.drive, loop, opts, on_event, &app)
    if derr != .None {
        fmt.eprintfln("drive_start: %v", derr)
        os.exit(1)
    }
    defer term.drive_stop(&app.drive)

    if !host_init(&app.host, out, &app.drive, loop) {
        // Clone before destroy frees last_err.
        src := app.host.last_err if app.host.last_err != "" else "host_init failed (no exception text)"
        msg := strings.clone(src)
        term.drive_stop(&app.drive)
        host_destroy(&app.host)
        fmt.eprintfln("host: %s", msg)
        delete(msg)
        os.exit(1)
    }
    defer host_destroy(&app.host)

    host_start(&app.host)
    for !app.host.done && app.host.last_err == "" {
        if terr := nbio.tick(); terr != nil {
            break
        }
    }

    // Clone errors before defers free host state. Defers run on return (not os.exit).
    err_copy := ""
    if app.host.last_err != "" {
        err_copy = strings.clone(app.host.last_err)
    }

    if err_copy != "" {
        // Explicit teardown so we never os.exit with live alt-screen / open VM.
        host_destroy(&app.host)
        term.drive_stop(&app.drive)
        fmt.eprintfln("js: %s", err_copy)
        delete(err_copy)
        os.exit(1)
    }
}
