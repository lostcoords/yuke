package main

// Load-test / memory-stress client for `libs:websocket`, driven on a single
// `core:nbio` event loop. It doubles as a usage example: every bit of per-run
// state is reached through `c.user_data` because Odin proc literals cannot
// capture, exactly as the driver README prescribes.
//
// The whole run executes under a `core:mem.Tracking_Allocator`. At exit the
// program prints leaked-allocation and bad-free counts and returns a non-zero
// process exit code if either is non-zero — proving the connection lifecycle
// frees everything it allocates is the primary purpose of this tool.
//
// Modes (see bench/SPEC.md):
//   echo   — connect once, send N messages, wait for every echo, report throughput.
//   flood  — connect to the flood server, drain N inbound messages, report throughput.
//   soak   — run the full connect/handshake/exchange/close/destroy lifecycle N times
//            on one loop; the leak hunt.
//   attack — connect to the adversarial server and report the single terminal outcome.

import "core:fmt"
import "core:mem"
import "core:nbio"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import ws "libs:websocket"

// Which of the four run behaviours the client performs.
Mode :: enum {
    Echo,
    Flood,
    Soak,
    Attack,
}

// Parsed command-line configuration. Zero-valued numeric fields are replaced by
// mode-appropriate defaults in `resolve_defaults`.
Config :: struct {
    // Target host (dotted IPv4 or resolvable name).
    host:       string,

    // Target TCP port; defaults to 8765 (clean server) or 8766 (attack).
    port:       int,

    // Whether `--port` was given, so the mode default only applies otherwise.
    port_set:   bool,

    // Request path with a leading slash.
    path:       string,

    // Selected run behaviour.
    mode:       Mode,

    // echo: messages to send. flood: messages to drain.
    count:      int,

    // echo/soak: payload size in bytes per outbound message.
    size:       int,

    // soak: number of full connection lifecycles to run.
    iterations: int,

    // echo: maximum outstanding (unechoed) messages, to bound send-queue growth.
    window:     int,

    // Global wall-clock backstop; if it fires before completion the run aborts.
    deadline:   time.Duration,
}

// All mutable per-run state, reached from every callback via `c.user_data`
// (proc literals cannot capture). One `App` backs an entire run — including all
// soak iterations — so cumulative counters survive across reconnects.
App :: struct {
    // Immutable run configuration.
    cfg:          Config,

    // Drives `nbio.run_until`; set by a terminal callback or the deadline.
    done:         bool,

    // The deadline backstop fired before the run completed.
    timed_out:    bool,

    // Outstanding deadline timer op, so it can be cancelled once the run ends.
    deadline_op:  ^nbio.Operation,

    // Shared outbound payload, owned by the tracked allocator for the whole run.
    payload:      []byte,

    // Cumulative messages sent and received across the run.
    sent:         int,
    recv:         int,

    // Cumulative application bytes sent and received.
    bytes_sent:   int,
    bytes_recv:   int,

    // The connection reached Open (`on_open` fired) at least once this run.
    opened:       bool,

    // Exchange start, sampled in `on_open` so connect cost is excluded.
    start:        time.Tick,

    // A terminal callback (close or error) fired.
    got_terminal: bool,

    // The terminal callback was `on_error` rather than `on_close`.
    is_error:     bool,

    // Terminal error, when `is_error`.
    err:          ws.Client_Error,

    // Close code reported to `on_close`.
    close_code:   ws.Close_Code,

    // soak: index of the iteration in progress.
    iter:         int,

    // soak: messages exchanged per iteration.
    iter_target:  int,

    // soak: echoes received in the current iteration.
    iter_recv:    int,

    // soak: an iteration failed unexpectedly, so the run is a failure.
    failed:       bool,
}

main :: proc() {
    // Wrap the entire run in a tracking allocator so every allocation this program
    // or the driver makes is accounted for. nbio's own event loop allocates through
    // `runtime.heap_allocator()` internally, not `context.allocator`, so the report
    // below reflects only client/payload buffers — precisely what we want to audit.
    track: mem.Tracking_Allocator
    mem.tracking_allocator_init(&track, context.allocator)
    // Collect bad frees into an array instead of panicking, so we can report a count.
    track.bad_free_callback = mem.tracking_allocator_bad_free_callback_add_to_array
    context.allocator = mem.tracking_allocator(&track)

    args := os.args[1:]

    for arg in args {
        if arg == "--help" || arg == "-h" {
            usage()
            os.exit(0)
        }
    }

    cfg, ok := parse_args(args)
    if !ok {
        usage()
        os.exit(2)
    }

    resolve_defaults(&cfg)

    app: App
    app.cfg = cfg

    run_ok := run(&app)

    // Free anything still owned before the leak check: the payload buffer and any
    // stray temp allocations. The client is already destroyed inside `run`.
    delete(app.payload)
    free_all(context.temp_allocator)

    leaks := len(track.allocation_map)
    bad := len(track.bad_free_array)

    leaked_bytes := 0
    for _, entry in track.allocation_map {
        leaked_bytes += entry.size
    }

    fmt.println("--- memory report ---")
    fmt.printfln("leaked allocations : %d (%d bytes)", leaks, leaked_bytes)
    fmt.printfln("bad frees          : %d", bad)
    fmt.printfln("peak allocated     : %d bytes", track.peak_memory_allocated)
    fmt.printfln("total allocations  : %d", track.total_allocation_count)

    // Show the first few leak sites to make a regression actionable.
    shown := 0
    for _, entry in track.allocation_map {
        if shown >= 8 {
            break
        }

        fmt.printfln("  leak: %d bytes @ %v", entry.size, entry.location)
        shown += 1
    }

    mem.tracking_allocator_destroy(&track)

    clean := run_ok && leaks == 0 && bad == 0
    fmt.printfln("result: %s", clean ? "PASS" : "FAIL")

    if !clean {
        os.exit(1)
    }
}

// Dispatch to the selected mode after arming the global deadline backstop. Every
// mode drives one borrowed loop and returns whether it met its own expectations
// (independent of the leak check, which `main` folds in afterwards).
run :: proc(app: ^App) -> bool {
    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    // The deadline flips `done` so a hung server can never wedge the benchmark
    // forever. It stays armed for the whole run (all soak iterations included).
    app.deadline_op = nbio.timeout_poly(app.cfg.deadline, app, on_deadline, loop)

    ok: bool
    switch app.cfg.mode {
    case .Echo:
        ok = drive_echo(app, loop)

    case .Flood:
        ok = drive_flood(app, loop)

    case .Soak:
        ok = drive_soak(app, loop)

    case .Attack:
        ok = drive_attack(app, loop)
    }

    // Cancel the deadline if it never fired, so no timer op outlives the run.
    if app.deadline_op != nil {
        nbio.remove(app.deadline_op)
        app.deadline_op = nil
    }

    return ok
}

// Global wall-clock backstop. Marks the run timed-out and releases `run_until`.
on_deadline :: proc(op: ^nbio.Operation, app: ^App) {
    app.deadline_op = nil
    app.timed_out = true
    app.done = true
}

// A hung connection cannot be torn down safely (a canceled kernel op may still
// reference its buffers), so on a deadline we print and hard-exit rather than
// risk a use-after-free in `client_destroy`. Exit code 2 marks the abort; the
// leak report is intentionally skipped because state cannot be reclaimed cleanly.
abort_deadline :: proc(app: ^App) {
    fmt.eprintfln(
        "DEADLINE EXCEEDED after %v: no completion — server hung or unreachable. Aborting.",
        app.cfg.deadline,
    )
    os.exit(2)
}

// Apply mode-specific defaults for any field left at its zero value.
resolve_defaults :: proc(cfg: ^Config) {
    if cfg.host == "" {
        cfg.host = "127.0.0.1"
    }

    if cfg.path == "" {
        cfg.path = "/"
    }

    if !cfg.port_set {
        cfg.port = cfg.mode == .Attack ? 8766 : 8765
    }

    if cfg.count == 0 {
        cfg.count = 10000
    }

    if cfg.size == 0 {
        cfg.size = 128
    }

    if cfg.iterations == 0 {
        cfg.iterations = 5000
    }

    if cfg.window == 0 {
        cfg.window = 64
    }

    if cfg.deadline == 0 {
        cfg.deadline = 60 * time.Second
    }
}

// Minimal `--flag value` / `--flag=value` parser over the argument slice. Returns
// false on an unknown flag, a missing value, or `--help`, letting `main` print usage.
parse_args :: proc(args: []string) -> (Config, bool) {
    cfg: Config

    i := 0
    for i < len(args) {
        arg := args[i]
        i += 1

        key := arg
        val := ""
        have_inline := false
        if eq := strings.index_byte(arg, '='); eq >= 0 {
            key = arg[:eq]
            val = arg[eq + 1:]
            have_inline = true
        }

        if key == "--help" || key == "-h" {
            return cfg, false
        }

        // Every remaining flag takes a value; pull it from the next arg if it was
        // not supplied inline with `=`.
        if !have_inline {
            if i >= len(args) {
                fmt.eprintfln("missing value for %s", key)
                return cfg, false
            }

            val = args[i]
            i += 1
        }

        switch key {
        case "--host":
            cfg.host = val

        case "--port":
            cfg.port = parse_int_or_die(val, key)
            cfg.port_set = true

        case "--path":
            cfg.path = val

        case "--mode":
            m, mok := parse_mode(val)
            if !mok {
                fmt.eprintfln("unknown mode %q", val)
                return cfg, false
            }

            cfg.mode = m

        case "--count":
            cfg.count = parse_int_or_die(val, key)

        case "--size":
            cfg.size = parse_int_or_die(val, key)

        case "--iterations":
            cfg.iterations = parse_int_or_die(val, key)

        case "--window":
            cfg.window = parse_int_or_die(val, key)

        case "--deadline":
            cfg.deadline = time.Duration(parse_int_or_die(val, key)) * time.Second

        case:
            fmt.eprintfln("unknown flag %q", key)
            return cfg, false
        }
    }

    return cfg, true
}

// Parse a base-10 integer flag value, exiting with a clear message on garbage.
parse_int_or_die :: proc(s: string, flag: string) -> int {
    v, ok := strconv.parse_int(s, 10)
    if !ok {
        fmt.eprintfln("invalid integer %q for %s", s, flag)
        os.exit(2)
    }

    return v
}

// Map a `--mode` string to its enum value.
parse_mode :: proc(s: string) -> (Mode, bool) {
    switch s {
    case "echo":
        return .Echo, true

    case "flood":
        return .Flood, true

    case "soak":
        return .Soak, true

    case "attack":
        return .Attack, true
    }

    return .Echo, false
}

usage :: proc() {
    fmt.eprintln(
        `yuke-odin bench client — load & memory-stress harness for libs:websocket

usage: bench-client --mode {echo,flood,soak,attack} [options]

options:
  --host H         target host (default 127.0.0.1)
  --port N         target port (default 8765; attack defaults to 8766)
  --path P         request path (default /)
  --mode M         echo | flood | soak | attack (default echo)
  --count N        echo: messages to send; flood: messages to drain (default 10000)
  --size N         payload bytes per outbound message (default 128)
  --iterations N   soak: connection lifecycles to run (default 5000)
  --window N       echo: max outstanding unechoed messages (default 64)
  --deadline N     global wall-clock backstop in seconds (default 60)
  -h, --help       this message

The whole run executes under a tracking allocator; exit code is 0 only when the
run met expectations AND zero leaks / zero bad frees were reported.`,
    )
}
