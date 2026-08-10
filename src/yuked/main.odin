/*
yuke daemon: the front door, the WebSocket protocol, the event store, and the script tier.

This process owns two things the `daemon` package deliberately does not. It owns the
logger — `src/daemon/doc.odin` is explicit that whoever drives the loop installs it, since
nbio callbacks inherit that context — and it owns the loop itself, because a signal handler
cannot wake a loop on its own thread: `nbio.wake_up` returns immediately when the loop
belongs to the caller. So rather than `nbio.run`, the loop is ticked here with a bounded
timeout and a flag checked between ticks, which is also what bounds shutdown latency.
*/
package main

import "base:intrinsics"
import "core:c/libc"
import "core:log"
import "core:nbio"
import "core:os"
import "core:time"

import daemon "src:daemon"

// Reported in every `initialize` result. Identifies the build, so it is compiled in rather
// than configured.
DAEMON_VERSION :: "0.1.0"

// How long one tick may block. This is the worst-case delay between a signal arriving and
// the loop noticing it, so it trades idle wakeups against shutdown latency.
TICK_TIMEOUT :: 100 * time.Millisecond

// How long a graceful shutdown may take before the process stops waiting for it. A wedged
// transport must not leave a daemon that cannot be killed with a signal.
SHUTDOWN_TIMEOUT :: 5 * time.Second

// Set from a signal handler; the one C-standard-blessed type for that, touched only via
// atomics. A second signal past the first stops waiting for the graceful path.
@(private = "file")
g_signals: libc.sig_atomic_t

@(private = "file")
on_signal :: proc "c" (_: i32) {
    intrinsics.atomic_add(&g_signals, 1)
}

@(private = "file")
signals_seen :: proc() -> int {
    return int(intrinsics.atomic_load(&g_signals))
}

main :: proc() {
    // Installed before anything else so a start failure is reported through the same channel as
    // everything after it. The manifest's log level is not known until `start` has evaluated it,
    // so the daemon's own startup runs at info and the level is reinstalled below.
    context.logger = log.create_console_logger(.Info)

    // Bootstrap only: `yuked.js` supplies host, port, db_path, blob_dir, auth_token, and the
    // log level. `start` reads the manifest and fills them in before it binds anything.
    options := boot_options(DAEMON_VERSION)

    if options.auth_path == "" {
        log.warn("yuked: no config directory could be resolved; provider OAuth is disabled")
    }

    if err := nbio.acquire_thread_event_loop(); err != nil {
        log.errorf("yuked: event loop unavailable: %v", err)
        os.exit(1)
    }

    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    // Installed before the daemon binds, so a signal arriving during startup is still seen
    // by the run loop rather than killing the process mid-listen.
    libc.signal(libc.SIGINT, on_signal)
    libc.signal(libc.SIGTERM, on_signal)

    d: daemon.Daemon
    if err := daemon.start(&d, loop, options); err != .None {
        log.errorf("yuked: %v", err)
        os.exit(1)
    }

    // Install the level the manifest chose, now that `start` has resolved it. The daemon runs
    // on this process's context, so nbio callbacks during `serve` inherit this logger.
    if d.log_level != .Info {
        log.destroy_console_logger(context.logger)
        context.logger = log.create_console_logger(d.log_level)
    }
    defer log.destroy_console_logger(context.logger)

    // Optional relay link, dialed after the front door binds so a relay failure never
    // blocks the local daemon. Driven from here rather than the daemon package: parking
    // needs only the loop, and the front-door bridge lands in a later stage.
    relay_start(loop)

    serve()

    if !stop(&d) {
        // The transport did not finish closing; `destroy` asserts that it did, so the
        // process leaves its memory to the OS instead of tripping that assertion on exit.
        log.error("yuked: shutdown did not complete; exiting without releasing the daemon")
        os.exit(1)
    }

    daemon.destroy(&d)
    relay_finish()
    log.info("yuked: stopped")
}

// Drive the loop until a signal arrives. `num_waiting` is the second exit: the front door
// keeps an accept outstanding, so reaching zero means blocking again would hang.
@(private = "file")
serve :: proc() {
    for signals_seen() == 0 && nbio.num_waiting() > 0 {
        if err := nbio.tick(TICK_TIMEOUT); err != nil {
            log.errorf("yuked: event loop failed: %v", err)
            return
        }
    }
}

// Close both halves and keep ticking until they report it. Returns false when the deadline
// passes first, or when a second signal says the operator is done waiting.
@(private = "file")
stop :: proc(d: ^daemon.Daemon) -> bool {
    log.info("yuked: stopping")
    daemon.shutdown(d)
    relay_begin_close()

    deadline := time.time_add(time.now(), SHUTDOWN_TIMEOUT)
    first := signals_seen()

    for !daemon.shutdown_complete(d) || !relay_closed() {
        if time.now()._nsec >= deadline._nsec {
            return false
        }

        if signals_seen() > first {
            log.warn("yuked: second signal; abandoning the graceful shutdown")
            return false
        }

        if err := nbio.tick(TICK_TIMEOUT); err != nil {
            log.errorf("yuked: event loop failed during shutdown: %v", err)
            return false
        }
    }

    return true
}
