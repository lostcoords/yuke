package main

// Per-mode drivers and the shared callback set. Callbacks dispatch on
// `app.cfg.mode` and reach `App` through `c.user_data`; none of them capture.
// `data` handed to `on_message` is borrowed for the call only, so the callbacks
// read `len(data)` and never retain the slice.

import "core:fmt"
import "core:nbio"
import "core:time"
import ws "libs:websocket"

// soak exchanges a small, fixed number of messages per connection — enough to
// exercise send, receive, and reassembly without inflating each iteration.
SOAK_MESSAGES_PER_ITER :: 3

// Build the connect options from the parsed config.
client_options :: proc(app: ^App) -> ws.Options {
    return {host = app.cfg.host, port = app.cfg.port, path = app.cfg.path}
}

// The one callback set shared by every mode; behaviour forks inside each handler.
make_callbacks :: proc() -> ws.Callbacks {
    return ws.Callbacks {
        on_open = cb_on_open,
        on_message = cb_on_message,
        on_close = cb_on_close,
        on_error = cb_on_error,
    }
}

// Allocate and fill the reusable outbound payload once for a run.
alloc_payload :: proc(app: ^App) {
    app.payload = make([]byte, app.cfg.size)
    for &b in app.payload {
        b = 'a'
    }
}

// Queue one text message if the echo budget is not yet exhausted, keeping at most
// `window` messages outstanding so the send queue cannot grow without bound.
echo_send_more :: proc(c: ^ws.Client, app: ^App) {
    if app.sent >= app.cfg.count {
        return
    }

    send_err := ws.client_send_text(c, app.payload)
    if send_err == .None {
        app.sent += 1
        app.bytes_sent += len(app.payload)
    } else if send_err != .Send_Queue_Full {
        ws.client_abort(c, send_err)
    }
}

close_connection :: proc(c: ^ws.Client) {
    if close_err := ws.client_close(c); close_err != .None {
        ws.client_abort(c, close_err)
    }
}

// --- Shared callbacks ---------------------------------------------------------

cb_on_open :: proc(c: ^ws.Client) {
    app := (^App)(c.user_data)
    app.opened = true

    switch app.cfg.mode {
    case .Echo:
        app.start = time.tick_now()
        prime := min(app.cfg.window, app.cfg.count)
        for _ in 0 ..< prime {
            echo_send_more(c, app)
        }

    case .Flood:
        // The server floods on connect; time the drain from the moment we are Open.
        app.start = time.tick_now()

    case .Soak:
        for _ in 0 ..< app.iter_target {
            if ws.client_send_text(c, app.payload) == .None {
                app.sent += 1
                app.bytes_sent += len(app.payload)
            }
        }

    case .Attack:
    // Observe only; the adversarial server drives the connection to a terminal.
    }
}

cb_on_message :: proc(c: ^ws.Client, kind: ws.Message_Kind, data: []byte) {
    app := (^App)(c.user_data)

    // `data` is borrowed for this call — only its length is retained.
    app.recv += 1
    app.bytes_recv += len(data)

    switch app.cfg.mode {
    case .Echo:
        echo_send_more(c, app)
        if app.recv >= app.cfg.count {
            close_connection(c)
        }

    case .Flood:
        if app.recv >= app.cfg.count {
            close_connection(c)
        }

    case .Soak:
        app.iter_recv += 1
        if app.iter_recv >= app.iter_target {
            close_connection(c)
        }

    case .Attack:
    // Ignore any payload the attacker sends before abusing the connection.
    }
}

cb_on_close :: proc(c: ^ws.Client, code: ws.Close_Code) {
    app := (^App)(c.user_data)
    app.got_terminal = true
    app.is_error = false
    app.close_code = code
    app.done = true
}

cb_on_error :: proc(c: ^ws.Client, err: ws.Client_Error) {
    app := (^App)(c.user_data)
    app.got_terminal = true
    app.is_error = true
    app.err = err
    app.done = true
}

// --- Mode drivers -------------------------------------------------------------

// echo: connect once, keep `window` messages in flight until `count` are sent,
// wait for every echo, then close cleanly. Reports round-trip throughput.
drive_echo :: proc(app: ^App, loop: ^nbio.Event_Loop) -> bool {
    alloc_payload(app)

    c: ws.Client
    cerr := ws.client_connect(&c, loop, client_options(app), make_callbacks(), app)
    if cerr != .None {
        fmt.eprintfln("echo: connect setup failed: %v", cerr)
        return false
    }

    nbio.run_until(&app.done)

    if app.timed_out {
        abort_deadline(app)
    }

    ws.client_destroy(&c)

    report_throughput(app, "echo")

    return app.got_terminal && !app.is_error && app.recv == app.cfg.count
}

// flood: connect to the flood server, drain `count` inbound messages, then close.
// Reports inbound throughput.
drive_flood :: proc(app: ^App, loop: ^nbio.Event_Loop) -> bool {
    c: ws.Client
    cerr := ws.client_connect(&c, loop, client_options(app), make_callbacks(), app)
    if cerr != .None {
        fmt.eprintfln("flood: connect setup failed: %v", cerr)
        return false
    }

    nbio.run_until(&app.done)

    if app.timed_out {
        abort_deadline(app)
    }

    ws.client_destroy(&c)

    report_throughput(app, "flood")

    return app.got_terminal && !app.is_error && app.recv >= app.cfg.count
}

// soak: run the full connect -> handshake -> exchange -> close -> destroy cycle
// `iterations` times on one loop. Each iteration runs to Closed (its terminal
// callback sets `done`, releasing `run_until`) *before* the next connect begins,
// so connections never overlap and every iteration's buffers are freed by
// `client_destroy` before the next allocates. This is the leak hunt.
drive_soak :: proc(app: ^App, loop: ^nbio.Event_Loop) -> bool {
    app.iter_target = SOAK_MESSAGES_PER_ITER
    alloc_payload(app)

    cbs := make_callbacks()
    opts := client_options(app)
    progress_step := max(1, app.cfg.iterations / 10)

    completed := 0
    for app.iter = 0; app.iter < app.cfg.iterations; app.iter += 1 {
        // Reset per-iteration terminal state; cumulative counters carry over.
        app.done = false
        app.iter_recv = 0
        app.got_terminal = false
        app.is_error = false
        app.err = .None

        c: ws.Client
        cerr := ws.client_connect(&c, loop, opts, cbs, app)
        if cerr != .None {
            fmt.eprintfln("soak: iter %d connect setup failed: %v", app.iter, cerr)
            app.failed = true
            break
        }

        nbio.run_until(&app.done)

        // A hung iteration leaves `c` live and unsafe to destroy; abort the process.
        if app.timed_out {
            abort_deadline(app)
        }

        if app.is_error {
            fmt.eprintfln("soak: iter %d unexpected error %v", app.iter, app.err)
            ws.client_destroy(&c)
            app.failed = true
            break
        }

        ws.client_destroy(&c)
        completed += 1

        if completed % progress_step == 0 {
            fmt.printfln("soak: %d/%d iterations", completed, app.cfg.iterations)
        }
    }

    fmt.printfln(
        "soak: completed %d/%d iterations, %d msgs sent, %d echoed",
        completed,
        app.cfg.iterations,
        app.sent,
        app.recv,
    )

    return !app.failed && !app.timed_out && completed == app.cfg.iterations
}

// attack: connect to the adversarial server and report the single terminal
// outcome. Any terminal (a protocol-violation error or a documented close) with
// no crash, leak, or hang is success — the client rejected the abuse safely.
drive_attack :: proc(app: ^App, loop: ^nbio.Event_Loop) -> bool {
    c: ws.Client
    cerr := ws.client_connect(&c, loop, client_options(app), make_callbacks(), app)
    if cerr != .None {
        // A synchronous rejection (bad options / resolve) is also a clean refusal.
        fmt.printfln("attack: connect setup rejected: %v", cerr)
        return true
    }

    nbio.run_until(&app.done)

    if app.timed_out {
        fmt.eprintln(
            "attack: no terminal callback within deadline — client did not terminate (possible hang or endless ping/pong)",
        )
        abort_deadline(app)
    }

    ws.client_destroy(&c)

    if app.is_error {
        fmt.printfln("attack: on_error fired — %v (client rejected the attack)", app.err)
    } else {
        fmt.printfln("attack: on_close fired — code %v", app.close_code)
    }

    return app.got_terminal
}

// Print message/byte counts, wall time, and throughput for echo/flood. When the
// connection never reached Open there is nothing to measure, so report the
// terminal outcome instead of a meaningless timing.
report_throughput :: proc(app: ^App, label: string) {
    if !app.opened {
        if app.is_error {
            fmt.printfln("%s: connection failed before Open — %v", label, app.err)
        } else {
            fmt.printfln("%s: connection closed before Open — code %v", label, app.close_code)
        }

        return
    }

    elapsed := time.tick_since(app.start)
    secs := time.duration_seconds(elapsed)

    msgs_per_s := 0.0
    mib_per_s := 0.0
    if secs > 0 {
        msgs_per_s = f64(app.recv) / secs
        mib_per_s = f64(app.bytes_recv) / (1024 * 1024) / secs
    }

    fmt.println("--- throughput ---")
    fmt.printfln("mode        : %s", label)
    fmt.printfln("sent        : %d msgs (%d bytes)", app.sent, app.bytes_sent)
    fmt.printfln("received    : %d msgs (%d bytes)", app.recv, app.bytes_recv)
    fmt.printfln("wall time   : %v", elapsed)
    fmt.printfln("throughput  : %.0f msgs/s, %.2f MiB/s", msgs_per_s, mib_per_s)
}
