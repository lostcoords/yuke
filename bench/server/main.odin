package main

// Odin drop-in for `bench/server.py`: a clean echo/flood WebSocket benchmark
// server built on the `libs:websocket` nbio server driver. See `bench/SPEC.md` for
// the shared wire contract. It is intentionally thin — CLI parse, per-connection
// callbacks, counters, and a single `nbio.run` loop that serves until the process
// is killed.
//
// Modes:
//   echo  — echo every inbound text/binary message back unchanged, same kind.
//           The server never closes first.
//   flood — on connect, stream `--flood-count` text messages of `--flood-size`
//           bytes, then idle until the client closes. The messages are streamed
//           from the driver's send-completion (`on_drain`) with a bounded queue
//           depth, never enqueued up front, so RSS stays flat.

import "core:fmt"
import "core:nbio"
import "core:os"
import "core:strconv"
import "core:strings"
import http "libs:http/server"
import ws "libs:websocket"

// 1 MiB single-frame / reassembled-message cap, matching the `websockets` v16
// defaults the Python server runs with.
MAX_BYTES :: 1 << 20

// Frames queued per refill in flood mode. The driver's send queue never holds more
// than this, so the 100k-message stream costs O(FLOOD_BATCH) memory, not O(count).
FLOOD_BATCH :: 64

// Which behaviour the server performs. Server-side only; the upgrade path is
// ignored.
Mode :: enum {
    Echo,
    Flood,
}

// Parsed command-line configuration.
Config :: struct {
    // Bind address (dotted IPv4).
    host:        string,

    // Bind port.
    port:        int,

    // Selected behaviour.
    mode:        Mode,

    // flood: messages to send per connection.
    flood_count: int,

    // flood: bytes per flood message.
    flood_size:  int,
}

// Server-level state, reached from every callback via `conn.server.user_data`.
App :: struct {
    // Immutable run configuration.
    cfg:     Config,

    // Shared read-only flood payload (`"x" * flood_size`), allocated once for the
    // whole run in flood mode; nil in echo mode.
    payload: []byte,
}

// Per-connection flood progress, assigned to `conn.user_data` in `on_open` and
// freed in the terminal callback. Echo connections carry none.
Flood_Conn :: struct {
    // Messages already sent on this connection.
    sent: int,
}

// The server-level app behind a connection.
app_of :: proc(conn: ^ws.Server_Conn) -> ^App {
    return (^App)(conn.server.user_data)
}

main :: proc() {
    cfg, ok := parse_args(os.args[1:])
    if !ok {
        usage()
        os.exit(2)
    }

    resolve_defaults(&cfg)

    app: App
    app.cfg = cfg

    if cfg.mode == .Flood {
        app.payload = make([]byte, cfg.flood_size)
        for &b in app.payload {
            b = 'x'
        }
    }

    defer delete(app.payload)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    callbacks := ws.Server_Callbacks {
        on_open    = on_open,
        on_message = on_message,
        on_close   = on_close,
        on_error   = on_error,
        on_drain   = on_drain,
    }

    s: ws.Server
    ws_err := ws.server_init(&s, loop, {max_frame_bytes = MAX_BYTES, max_message_bytes = MAX_BYTES}, callbacks, &app)
    if ws_err != .None {
        fmt.eprintfln("bench-server: websocket init failed: %v", ws_err)
        os.exit(1)
    }

    front: http.Server
    herr := http.listen(&front, loop, {host = cfg.host, port = cfg.port}, on_request, &s)
    if herr != .None {
        fmt.eprintfln("bench-server: listen failed: %v", herr)
        os.exit(1)
    }

    fmt.printfln("bench-server listening on ws://%s:%d/ (mode=%v)", cfg.host, cfg.port, cfg.mode)

    // Serve until the process is killed; the outstanding accept keeps the loop busy.
    nbio.run()
}

// --- Callbacks ----------------------------------------------------------------

// Front door: every request is expected to be a WebSocket upgrade; the bench has
// no other route.
on_request :: proc(c: ^http.Conn, req: http.Request) {
    s := (^ws.Server)(c.server.user_data)

    ws.accept_upgrade(s, c, req.head, req.trailing)
}

on_open :: proc(conn: ^ws.Server_Conn) {
    app := app_of(conn)
    if app.cfg.mode != .Flood {
        return
    }

    fc := new(Flood_Conn)
    conn.user_data = fc

    // Prime the stream; subsequent batches follow from `on_drain`.
    flood_pump(conn, app, fc)
}

on_message :: proc(conn: ^ws.Server_Conn, kind: ws.Message_Kind, data: []byte) {
    app := app_of(conn)

    // Echo mode: return the payload verbatim in the same kind. `data` is borrowed
    // for this call only; `server_send_*` copies it into its own frame.
    if app.cfg.mode == .Echo {
        send_err: ws.Server_Error
        if kind == .Binary {
            send_err = ws.server_send_binary(conn, data)
        } else {
            send_err = ws.server_send_text(conn, data)
        }

        if send_err != .None {
            ws.server_abort(conn, send_err)
        }
    }

    // Flood mode ignores anything the client sends; it only produces.
}

on_drain :: proc(conn: ^ws.Server_Conn) {
    app := app_of(conn)
    if app.cfg.mode != .Flood {
        return
    }

    fc := (^Flood_Conn)(conn.user_data)
    if fc == nil {
        return
    }

    flood_pump(conn, app, fc)
}

on_close :: proc(conn: ^ws.Server_Conn, code: ws.Close_Code) {
    free_flood_conn(conn)
}

on_error :: proc(conn: ^ws.Server_Conn, err: ws.Server_Error) {
    free_flood_conn(conn)
}

// Queue up to `FLOOD_BATCH` more messages, stopping at `flood_count`. Called from
// `on_open` and each `on_drain`, so at most `FLOOD_BATCH` frames are buffered at a
// time regardless of how many remain — the stream never materializes up front.
flood_pump :: proc(conn: ^ws.Server_Conn, app: ^App, fc: ^Flood_Conn) {
    for _ in 0 ..< FLOOD_BATCH {
        if fc.sent >= app.cfg.flood_count {
            return
        }

        send_err := ws.server_send_text(conn, app.payload)
        if send_err == .Send_Queue_Full {
            return
        }
        if send_err != .None {
            ws.server_abort(conn, send_err)
            return
        }

        fc.sent += 1
    }
}

// Free a flood connection's per-connection state, if any. Safe for echo
// connections (which never set it) and for connections that failed before open.
free_flood_conn :: proc(conn: ^ws.Server_Conn) {
    free(conn.user_data)
    conn.user_data = nil
}

// --- CLI ----------------------------------------------------------------------

// Apply defaults for any field left at its zero value.
resolve_defaults :: proc(cfg: ^Config) {
    if cfg.host == "" {
        cfg.host = "127.0.0.1"
    }

    if cfg.port == 0 {
        cfg.port = 8765
    }

    if cfg.flood_count == 0 {
        cfg.flood_count = 100_000
    }

    if cfg.flood_size == 0 {
        cfg.flood_size = 256
    }
}

// Minimal `--flag value` / `--flag=value` parser. Returns false on an unknown
// flag, a missing value, or `--help`.
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

        if !have_inline {
            if i >= len(args) {
                fmt.eprintfln("bench-server: missing value for %s", key)
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

        case "--mode":
            m, mok := parse_mode(val)
            if !mok {
                fmt.eprintfln("bench-server: unknown mode %q", val)
                return cfg, false
            }

            cfg.mode = m

        case "--flood-count":
            cfg.flood_count = parse_int_or_die(val, key)

        case "--flood-size":
            cfg.flood_size = parse_int_or_die(val, key)

        case:
            fmt.eprintfln("bench-server: unknown flag %q", key)
            return cfg, false
        }
    }

    return cfg, true
}

// Parse a base-10 integer flag value, exiting on garbage.
parse_int_or_die :: proc(s: string, flag: string) -> int {
    v, ok := strconv.parse_int(s, 10)
    if !ok {
        fmt.eprintfln("bench-server: invalid integer %q for %s", s, flag)
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
    }

    return .Echo, false
}

usage :: proc() {
    fmt.eprintln(
        `yuke-odin bench server — echo/flood WebSocket benchmark server for libs:websocket

usage: bench-server [--mode {echo,flood}] [options]

options:
  --host H          bind address (default 127.0.0.1)
  --port N          bind port (default 8765)
  --mode M          echo | flood (default echo)
  --flood-count N   flood: messages to send per connection (default 100000)
  --flood-size N    flood: bytes per flood message (default 256)
  -h, --help        this message`,
    )
}
