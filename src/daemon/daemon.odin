package daemon

import "core:log"
import "core:mem"
import "core:nbio"
import "core:net"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"

import http_server "libs:http/server"
import "libs:offload"
import ws "libs:websocket"
import store "src:daemon/store"
import wire "src:wire"

Protocol_State :: enum {
    // Connection is Open; awaiting the client's `initialize` request.
    Awaiting_Initialize,

    // `initialize` answered; requests are routed to their handlers.
    Ready,

    // A close has been initiated; no further frames are processed.
    Closed,
}

// Synchronous `start` failures.
Error :: enum {
    // No error.
    None,

    // A required pointer, host, or authentication option was invalid.
    Invalid_Options,

    // Binding/listening on the endpoint failed.
    Listen_Failed,

    // Configuration or server storage could not be allocated.
    Out_Of_Memory,

    // The configured database could not be opened, is damaged, or was written by a
    // newer daemon.
    Store_Failed,
}

// Listen and identity options. Zero-valued fields default in `start`.
Options :: struct {
    // Dotted IPv4 bind address (no scheme). Defaults to the front door's `127.0.0.1`.
    host:           string,

    // TCP port to bind; `/ws` and `/blob/<hash>` share it.
    port:           int,

    // Daemon build/version string reported in `initialize`. Defaults to `"0.0.0"`.
    daemon_version: string,

    // Directory holding content-addressed blobs, created if absent. Empty disables
    // `/blob`.
    blob_dir:       string,

    // Required bearer token. Empty disables authorization; non-empty values use
    // the RFC 3986 unreserved alphabet so the same token is safe in a query.
    auth_token:     string,

    // SQLite database holding the event log, created if absent. Empty disables the
    // store, and with it every durable broadcast.
    db_path:        string,
}

// A listening yuke daemon on a caller-supplied nbio loop. Owns the HTTP front door
// that binds the port, the WebSocket server it upgrades into, and its own string
// clones. Start with `start`, stop with `shutdown`, reclaim with
// `destroy`.
Daemon :: struct {
    // Front door: binds the port; `user_data` is `&router`.
    front_door:     http_server.Server,

    // HTTP routes and pre-match middleware for the front door. `user_data` is this
    // `^Daemon`, and every callback receives it typed as `Http_Context.user_data`.
    router:         Http_Router,

    // WebSocket server fed by `http`, driven through `ws.server_*`. Its
    // per-connection callbacks recover this `^Daemon` via `wsc.server.user_data`.
    ws_server:      ws.Server,

    // @private
    // Borrowed event loop the transport submits ops to; never run here.
    loop:           ^nbio.Event_Loop,

    // @private
    // Backs the string clones and every connection's `Conn`. Must outlive the daemon.
    allocator:      mem.Allocator,

    // @private
    // Owned daemon version string, reported in every `initialize` result.
    daemon_version: string,

    // @private
    // Owned blob directory; empty when `/blob` is disabled.
    blob_dir:       string,

    // @private
    // Workers for the blob store's blocking filesystem calls. `fsync`, `rename`, and
    // `unlink` have no nbio operation, so publishing an upload from a reactor callback
    // would stall every other connection. Only started when `blob_dir` is set.
    blobs:          offload.Pool,

    // @private
    // Owned bearer token; empty when authorization is disabled.
    auth_token:     string,

    // @private
    // Event log of record, open for the daemon's whole serving life. Nil when no
    // database is configured, which is what makes a durable broadcast impossible.
    store:          ^store.Store,

    // @private
    // Per-session durable high-water: the pump's seq authority. Recovered from the
    // store on first touch, so an absent entry is re-read rather than assumed zero.
    seq_high:       map[wire.Session_Id]wire.Seq,
}

// One accepted connection past the WebSocket handshake. Allocated in the transport
// `ws_on_open` and freed in the terminal callback.
Conn :: struct {
    // Transport connection this wraps; borrowed, owned by the WebSocket server.
    wsc:                ^ws.Server_Conn,

    // Owning daemon, for the version string and allocator.
    daemon:             ^Daemon,

    // Allocator backing `scratch` and the retained client identity (the daemon's).
    allocator:          mem.Allocator,
    state:              Protocol_State,

    // Per-frame decode scratch, `free_all`'d after each inbound frame. A frame's
    // borrowed strings and slices live here only for the handler that consumes them.
    scratch:            mem.Dynamic_Arena,

    // Retained client name from `initialize`; an owned `strings.clone` for
    // identity/logging, freed with the `Conn`. Never the borrowed frame slice.
    client_name:        string,

    // Retained client version from `initialize`; owned like `client_name`.
    client_version:     string,

    // Sessions this connection subscribes to, replaced wholesale by
    // `subscription.set`. Inline and bounded by the protocol's own cap, so gating
    // never allocates on the fan-out path.
    subscriptions:      [wire.LIMITS.max_subscriptions]wire.Session_Id,

    // Live prefix length of `subscriptions`.
    subscription_count: int,
}

// Begin listening. A synchronous failure returns directly and rolls back the clones
// and the WebSocket server; past the bind, everything runs on the loop.
start :: proc(d: ^Daemon, loop: ^nbio.Event_Loop, options: Options, allocator := context.allocator) -> Error {
    if d == nil || loop == nil {
        return .Invalid_Options
    }

    if !auth_token_valid(options.auth_token) {
        return .Invalid_Options
    }

    d^ = {}
    d.loop = loop
    d.allocator = allocator

    version := options.daemon_version
    if version == "" {
        version = "0.0.0"
    }

    aerr: mem.Allocator_Error
    d.daemon_version, aerr = strings.clone(version, allocator)
    if aerr != nil {
        return .Out_Of_Memory
    }

    d.blob_dir, aerr = strings.clone(options.blob_dir, allocator)
    if aerr != nil {
        free_config(d)
        return .Out_Of_Memory
    }

    d.auth_token, aerr = strings.clone(options.auth_token, allocator)
    if aerr != nil {
        free_config(d)
        return .Out_Of_Memory
    }

    // The `initialize` result advertises `blob_upload` from this field alone, so an
    // unusable directory must fail the start rather than 500 every upload.
    if d.blob_dir != "" {
        if mkerr := os.make_directory_all(d.blob_dir, BLOB_DIR_PERMISSIONS); mkerr != nil && !os.is_dir(d.blob_dir) {
            free_config(d)
            return .Invalid_Options
        }

        warn_exposed_blob_dir(d.blob_dir, allocator)

        if perr := offload.pool_init(&d.blobs, loop, BLOB_WORKER_COUNT); perr != .None {
            free_config(d)
            return .Invalid_Options
        }
    }

    // The log of record has to be usable before anything is adopted: a damaged or
    // future-versioned database is a start failure, never a per-request one.
    if options.db_path != "" {
        opened, serr := store.open(options.db_path, allocator)
        if serr != nil {
            log.errorf("daemon: event store unavailable at %s: %v", options.db_path, serr)
            blobs_stop(d)
            free_config(d)
            return .Store_Failed
        }

        marks, merr := make(map[wire.Session_Id]wire.Seq, 16, allocator)
        if merr != nil {
            store.close(opened)
            blobs_stop(d)
            free_config(d)
            return .Out_Of_Memory
        }

        d.store = opened
        d.seq_high = marks
    }

    callbacks := ws.Server_Callbacks {
        on_open    = ws_on_open,
        on_message = ws_on_message,
        on_close   = ws_on_close,
        on_error   = ws_on_error,
    }
    server_options := ws.Server_Options {
        // A yuke frame carries exactly one JSON value; cap frame and message at the
        // protocol's 8 MiB ceiling.
        max_frame_bytes   = wire.LIMITS.max_frame_bytes,
        max_message_bytes = wire.LIMITS.max_frame_bytes,
    }
    ws_err := ws.server_init(&d.ws_server, loop, server_options, callbacks, d, allocator)
    switch ws_err {
    case .None:

    case .Invalid_Options:
        blobs_stop(d)
        store_close(d)
        free_config(d)
        return .Invalid_Options

    case .Out_Of_Memory:
        blobs_stop(d)
        store_close(d)
        free_config(d)
        return .Out_Of_Memory

    case .Too_Many_Connections,
         .Message_Too_Large,
         .Send_Queue_Full,
         .Invalid_Close_Code,
         .Protocol_Violation,
         .Send_Failed,
         .Recv_Failed,
         .Not_Open:
        assert(false, "server_init returned a connection-only error")
    }

    router_init(d)

    herr := http_server.router_listen(
        &d.front_door,
        loop,
        {host = options.host, port = options.port, max_body_bytes = i64(wire.LIMITS.max_blob_bytes)},
        &d.router,
        allocator,
    )
    switch herr {
    case .None:

    case .Invalid_Options:
        start_rollback(d)
        return .Invalid_Options

    case .Listen_Failed:
        start_rollback(d)
        return .Listen_Failed

    case .Out_Of_Memory:
        start_rollback(d)
        return .Out_Of_Memory
    }

    assert(d.loop == loop, "daemon lost its event loop during startup")
    assert(d.front_door.user_data == &d.router, "front door user_data must be the daemon router")
    assert(d.router.user_data == d, "router has the wrong owner")
    assert(d.ws_server.user_data == d, "websocket server has the wrong owner")
    assert(d.front_door.state == .Serving, "front door did not reach Serving")
    assert(d.ws_server.state == .Serving, "websocket server did not reach Serving")
    assert((d.store != nil) == (options.db_path != ""), "the store is open exactly when a database is configured")

    if d.blob_dir != "" {
        removed := blob_sweep_temps(d.blob_dir, time.time_add(time.now(), -UPLOAD_TEMP_GRACE))
        if removed > 0 {
            log.infof("daemon: swept %d stale upload temp file(s) from %s", removed, d.blob_dir)
        }
    }

    log.infof(
        "daemon: listening on %s:%d version=%s auth=%v blob=%v store=%v",
        net.to_string(net.Address(d.front_door.bind_address), context.temp_allocator),
        http_server.bound_port(&d.front_door),
        d.daemon_version,
        d.auth_token != "",
        d.blob_dir != "",
        d.store != nil,
    )

    return .None
}

// Undo what `start` built before the bind failed — nothing was ever adopted,
// so the WebSocket server needs no shutdown pass.
start_rollback :: proc(d: ^Daemon) {
    assert(d != nil, "daemon rollback needs daemon state")
    assert(d.front_door.state == .Idle, "failed front door retained active state")
    assert(d.ws_server.state == .Serving, "websocket server was not initialized before rollback")

    blobs_stop(d)
    store_close(d)
    ws.server_destroy(&d.ws_server)
    free_config(d)
}

// Drain and release the blob workers. Idempotent, so every teardown path can call it
// without knowing how far `start` got. Draining runs each finished task's
// completion on this loop, which is why it must precede releasing the front door: a
// completion resolves its connection ticket against that server.
blobs_stop :: proc(d: ^Daemon) {
    assert(d != nil, "blob worker teardown needs daemon state")

    if !offload.pool_is_running(&d.blobs) {
        return
    }

    if derr := offload.pool_drain(&d.blobs); derr != nil {
        log.errorf("daemon: blob worker drain failed: %v", derr)
    }

    offload.pool_destroy(&d.blobs)
}

// Stop accepting and close every live connection. Closing is async: run the loop
// until both halves report `shutdown_complete` before
// calling `destroy`.
shutdown :: proc(d: ^Daemon) {
    assert(d != nil, "shutdown needs daemon state")
    assert(d.front_door.user_data == &d.router, "front door user_data must be the daemon router")
    assert(d.router.user_data == d, "router has the wrong owner")
    assert(d.ws_server.user_data == d, "websocket server has the wrong owner")

    log.info("daemon: shutdown started")
    http_server.shutdown(&d.front_door)
    ws.server_shutdown(&d.ws_server)
}

// Release both connection sets and the owned clones. Call only once both halves
// report `shutdown_complete`; every connection must already be released.
destroy :: proc(d: ^Daemon) {
    assert(d != nil, "destroy needs daemon state")
    assert(d.front_door.shutdown_complete, "destroy before HTTP shutdown completed")
    assert(d.ws_server.shutdown_complete, "destroy before WebSocket shutdown completed")

    blobs_stop(d)
    ws.server_destroy(&d.ws_server)
    http_server.destroy(&d.front_door)

    store_close(d)
    free_config(d)
}

// Close the event store and drop the pump's tracked marks. Idempotent, so every
// teardown path can call it without knowing how far `start` got.
store_close :: proc(d: ^Daemon) {
    assert(d != nil, "store teardown needs daemon state")

    if d.store == nil {
        assert(len(d.seq_high) == 0, "seq marks outlived the store that recovered them")
        return
    }

    store.close(d.store)
    delete(d.seq_high)
    d.store = nil
    d.seq_high = nil
}

// Release the owned config strings and reset them to empty.
free_config :: proc(d: ^Daemon) {
    assert(d != nil, "daemon config cleanup needs daemon state")

    delete(d.daemon_version, d.allocator)
    delete(d.blob_dir, d.allocator)
    delete(d.auth_token, d.allocator)
    d.daemon_version = ""
    d.blob_dir = ""
    d.auth_token = ""
}

// --- internal transport callbacks ---
//
// Each recovers the owning `^Daemon` from the server user data and the per-connection
// `^Conn` from the connection user data (proc literals cannot capture). Control
// frames (Ping/Pong/Close) are handled inside the transport and never surface here.

// A connection reached Open: allocate its `Conn`, enter Awaiting_Initialize, and attach
// it to the transport connection.
ws_on_open :: proc(wsc: ^ws.Server_Conn) {
    assert(wsc != nil, "open callback needs a transport connection")
    assert(wsc.server != nil, "open callback needs an owning server")
    assert(wsc.user_data == nil, "open callback found preexisting application state")

    d := (^Daemon)(wsc.server.user_data)
    assert(d != nil, "open callback needs daemon state")
    assert(&d.ws_server == wsc.server, "open callback crossed daemon ownership")

    conn, err := new(Conn, d.allocator)
    if err != nil {
        // Out of memory admitting the connection: refuse it cleanly. It opened, so a
        // terminal fires — with no `Conn` attached, the terminal callbacks no-op.
        log.error("daemon: out of memory admitting websocket connection")
        ws.server_abort(wsc, .Out_Of_Memory)
        return
    }

    conn^ = {}
    conn.wsc = wsc
    conn.daemon = d
    conn.allocator = d.allocator
    conn.state = .Awaiting_Initialize
    mem.dynamic_arena_init(&conn.scratch, d.allocator, d.allocator)

    wsc.user_data = conn
    assert(conn.wsc.user_data == conn, "connection state was not attached to its transport")
    log.debug("daemon: websocket connection open, awaiting initialize")
}

// One complete transport message. Only text frames carry protocol data; a binary
// frame is a v1 protocol error.
ws_on_message :: proc(wsc: ^ws.Server_Conn, kind: ws.Message_Kind, data: []byte) {
    assert(wsc != nil, "message callback needs a transport connection")
    assert(wsc.server != nil, "message callback needs an owning server")

    conn := (^Conn)(wsc.user_data)
    assert(conn != nil, "message callback lost its daemon connection")
    assert(conn.wsc == wsc, "message callback crossed connection ownership")
    if conn.state == .Closed {
        return
    }

    switch kind {
    case .Text:
        handle_text(conn, data)

    case .Binary:
        conn_protocol_close(conn)

    case .Ping, .Pong, .Close:
    }
}

// Transport terminal callback on a clean close: latch Closed and free the `Conn`.
ws_on_close :: proc(wsc: ^ws.Server_Conn, code: ws.Close_Code) {
    assert(wsc != nil, "close callback needs a transport connection")
    assert(wsc.server != nil, "close callback needs an owning server")

    conn := (^Conn)(wsc.user_data)
    if conn == nil {
        return
    }

    assert(conn.wsc == wsc, "close callback crossed connection ownership")
    log.debugf("daemon: websocket closed code=%v client=%s", code, conn.client_name)
    conn.state = .Closed
    conn_free(conn)
}

// Transport terminal callback on an error: latch Closed and free the `Conn`.
ws_on_error :: proc(wsc: ^ws.Server_Conn, err: ws.Server_Error) {
    assert(wsc != nil, "error callback needs a transport connection")
    assert(wsc.server != nil, "error callback needs an owning server")
    assert(err != .None, "error callback received no error")

    conn := (^Conn)(wsc.user_data)
    if conn == nil {
        log.warnf("daemon: websocket error before app state: %v", err)
        return
    }

    assert(conn.wsc == wsc, "error callback crossed connection ownership")
    log.warnf("daemon: websocket error %v client=%s", err, conn.client_name)
    conn.state = .Closed
    conn_free(conn)
}

// Handle one inbound text frame: any decode/validate failure or sequence violation
// closes the connection.
handle_text :: proc(conn: ^Conn, data: []byte) {
    assert(conn != nil, "text handler needs connection state")
    assert(conn.wsc != nil, "text handler needs transport state")
    assert(conn.daemon != nil, "text handler needs daemon state")
    assert(conn.wsc.user_data == conn, "text handler crossed transport ownership")
    assert(conn.state != .Closed, "text handler ran after protocol close")

    sa := mem.dynamic_arena_allocator(&conn.scratch)
    defer free_all(sa)

    d := wire.decoder_init(string(data), sa)
    req, derr := wire.request_from_reader(&d)
    if derr != .None {
        conn_protocol_close(conn)
        return
    }

    // One JSON value per frame: trailing bytes after the root are a protocol error.
    if wire.dec_finish(&d) != .None {
        conn_protocol_close(conn)
        return
    }

    handle_request(conn, req, sa)
}

// Answer `initialize`. On success the daemon retains the client identity, responds
// with its snapshot, and reaches Ready.
handle_initialize :: proc(conn: ^Conn, req: wire.Request) {
    assert(conn != nil, "initialize handler needs connection state")
    assert(conn.wsc != nil, "initialize handler needs transport state")
    assert(conn.state == .Awaiting_Initialize, "initialize ran outside Awaiting_Initialize")

    // `request_validate` already checked the params, including the protocol version.
    params, ok := req.params.(wire.Initialize_Params)

    if !ok {
        conn_protocol_close(conn)
        return
    }

    // Retain the client identity as owned clones: the frame arena is reclaimed when
    // this handler returns, so the borrowed name/version cannot be kept directly.
    assert(conn.client_name == "", "client name retained twice")
    assert(conn.client_version == "", "client version retained twice")

    client_name, aerr := strings.clone(params.client.name, conn.allocator)
    if aerr != nil {
        conn_abort(conn, .Out_Of_Memory)
        return
    }

    client_version, version_aerr := strings.clone(params.client.version, conn.allocator)
    if version_aerr != nil {
        delete(client_name, conn.allocator)
        conn_abort(conn, .Out_Of_Memory)
        return
    }

    conn.client_name = client_name
    conn.client_version = client_version

    if send_initialize_result(conn, req.id) {
        conn.state = .Ready
    }
}

// Route a request to its handler. Result data is built in `sa`, the per-frame arena
// `handle_text` reclaims after this returns.
handle_request :: proc(conn: ^Conn, req: wire.Request, sa: mem.Allocator) {
    assert(conn != nil, "request handler needs connection state")
    assert(conn.wsc != nil, "request handler needs transport state")

    // Validate the request (id shape, params bounds) before echoing its id back; a
    // malformed request is a protocol error, not an error response.
    if verr := wire.request_validate(req); verr != .None {
        // A version mismatch gets the dedicated close code.
        if verr == .Unsupported_Protocol {
            conn_close(conn, ws.Close_Code(wire.CLOSE.unsupported_protocol))
        } else {
            conn_protocol_close(conn)
        }

        return
    }

    // `initialize` is the only method accepted before Ready, and the only one refused
    // after it.
    if (req.method == .Initialize) != (conn.state == .Awaiting_Initialize) {
        conn_protocol_close(conn)
        return
    }

    switch req.method {
    case .Initialize:
        handle_initialize(conn, req)

    case .Session_List:
        method_session_list(conn, req)

    case .Catalog_List:
        method_catalog_list(conn, req)

    case .Workspace_Describe:
        method_workspace_describe(conn, req, sa)

    case .Workspace_Browse:
        method_workspace_browse(conn, req, sa)

    case .Subscription_Set:
        method_subscription_set(conn, req)

    case .Session_Resync:
        method_session_resync(conn, req, sa)

    case .Session_Create,
         .Session_Patch,
         .Session_Remove,
         .Session_Fork,
         .Session_Compact,
         .Session_Rewind,
         .Session_Send_Input,
         .Session_Cancel_Input,
         .Session_Cancel_Run,
         .Session_History,
         .Permission_Decide,
         .Session_Config,
         .Catalog_Refresh,
         .Workspace_Remove,
         .Workspace_Skills,
         .Permission_Rules,
         .Permission_Forget,
         .Cron_Create,
         .Cron_Patch,
         .Cron_Remove,
         .Cron_List,
         .Cron_Run_Now:
        send_error(conn, req.id, .Unknown_Method, "method not implemented")
    }
}

// `session.list` before the session engine exists: an empty page pinned to revision 0,
// matching the session revision the initialize snapshot claims.
method_session_list :: proc(conn: ^Conn, req: wire.Request) {
    assert(conn != nil, "session.list needs connection state")
    assert(conn.state == .Ready, "session.list ran outside Ready")
    assert(req.method == .Session_List, "session.list received another method")

    result := wire.Session_List_Result {
        revision    = 0,
        items       = nil,
        next_cursor = nil,
        total       = 0,
    }

    send_result(conn, req.id, result)
}

// `catalog.list` before any catalog is loaded: `unchanged` when the client already
// holds the empty revision, otherwise a `full` snapshot with no models and empty
// health. Both carry the all-zero catalog hash the initialize snapshot reports.
method_catalog_list :: proc(conn: ^Conn, req: wire.Request) {
    assert(conn != nil, "catalog.list needs connection state")
    assert(conn.state == .Ready, "catalog.list ran outside Ready")
    assert(req.method == .Catalog_List, "catalog.list received another method")

    params := req.params.(wire.Catalog_List_Params)
    empty := empty_catalog_rev()

    result: wire.Catalog_List_Result
    if since, ok := params.since_rev.?; ok && since == empty {
        result = wire.Catalog_List_Result_Unchanged {
            catalog_rev = empty,
        }
    } else {
        result = wire.Catalog_List_Result_Full {
            catalog_rev = empty,
            models = nil,
            health = {skipped = nil, load_error = nil},
        }
    }

    send_result(conn, req.id, result)
}

// `workspace.describe` on a real path: canonicalize it (a missing path or a
// non-directory is `Bad_Request`), then report the derived id, basename title, git
// branch, and directory mtime. With no session engine yet, there is no `last_used_model`.
method_workspace_describe :: proc(conn: ^Conn, req: wire.Request, sa: mem.Allocator) {
    assert(conn != nil, "workspace.describe needs connection state")
    assert(conn.state == .Ready, "workspace.describe ran outside Ready")
    assert(req.method == .Workspace_Describe, "workspace.describe received another method")

    params := req.params.(wire.Workspace_Describe_Params)

    canonical, cerr := os.get_absolute_path(params.path, sa)
    if cerr != nil {
        send_error(conn, req.id, .Bad_Request, "invalid workspace path")
        return
    }

    if !os.is_dir(canonical) {
        send_error(conn, req.id, .Bad_Request, "workspace path is not a directory")
        return
    }

    result := wire.Workspace_Describe_Result {
        workspace = wire.Workspace{id = workspace_id(canonical), root = canonical, title = workspace_title(canonical)},
        git = git_info(canonical, sa),
        last_modified_ms = path_mtime_ms(canonical, sa),
        last_used_model = nil,
    }

    send_result(conn, req.id, result)
}

// Longest browse cursor we could have minted. `strconv.parse_int` wraps silently
// and still reports success, so a longer one is rejected before it is parsed.
@(private)
MAX_BROWSE_CURSOR_DIGITS :: 16

// `workspace.browse` of a real directory: its immediate subdirectories (never files,
// never `.git`), sorted case-insensitively, paginated by an opaque decimal-offset
// cursor. A missing path defaults to the daemon user's home. Path and cursor faults
// are `Bad_Request`; a weird path never crashes the daemon.
method_workspace_browse :: proc(conn: ^Conn, req: wire.Request, sa: mem.Allocator) {
    assert(conn != nil, "workspace.browse needs connection state")
    assert(conn.state == .Ready, "workspace.browse ran outside Ready")
    assert(req.method == .Workspace_Browse, "workspace.browse received another method")

    params := req.params.(wire.Workspace_Browse_Params)

    target: string
    if p, ok := params.path.?; ok {
        target = p
    } else if home, found := os.lookup_env("HOME", sa); found {
        target = home
    } else {
        target = "/"
    }

    dir, derr := os.get_absolute_path(target, sa)
    if derr != nil {
        send_error(conn, req.id, .Bad_Request, "cannot open path")
        return
    }

    entries, lerr := browse_entries(dir, sa)
    if lerr != nil {
        send_error(conn, req.id, .Bad_Request, "cannot list path")
        return
    }

    offset := 0
    if cursor, ok := params.cursor.?; ok {
        if len(cursor) > MAX_BROWSE_CURSOR_DIGITS {
            send_error(conn, req.id, .Bad_Request, "malformed workspace.browse cursor")
            return
        }

        n, valid := strconv.parse_int(cursor, 10)
        if !valid || n < 0 {
            send_error(conn, req.id, .Bad_Request, "malformed workspace.browse cursor")
            return
        }

        offset = n
    }

    // Page size is already validated to be within bounds; default when omitted.
    page_size := wire.LIMITS.default_workspace_browse_page_size
    if limit, ok := params.limit.?; ok {
        page_size = int(limit)
    }

    total := len(entries)
    lo := min(offset, total)
    hi := min(lo + page_size, total)
    page := entries[lo:hi]

    next_cursor: Maybe(string)
    cursor_buf: [24]u8
    if hi < total {
        next_cursor = strconv.write_int(cursor_buf[:], i64(hi), 10)
    }

    result := wire.Workspace_Browse_Result {
        path        = dir,
        parent      = parent_dir(dir),
        entries     = page,
        next_cursor = next_cursor,
    }

    send_result(conn, req.id, result)
}

// Validate and emit a successful response. The result is built from already-trusted
// daemon state, so an invalid outgoing frame is our bug, not the peer's — assert
// rather than ship it.
send_result :: proc(conn: ^Conn, id: wire.Request_Id, result: wire.Response_Result) {
    assert(conn != nil, "result send needs connection state")
    assert(wire.response_result_validate(result) == .None, "daemon built an invalid result frame")
    send_response(conn, wire.response_ok_build(id, result))
}

// Emit an error response naming `code`. `message` is diagnostic only; clients branch
// on `code`.
send_error :: proc(conn: ^Conn, id: wire.Request_Id, code: wire.Error_Code, message: string) {
    assert(conn != nil, "error response send needs connection state")

    eo := wire.Error_Object {
        code    = code,
        message = message,
    }

    send_response(conn, wire.response_error_build(id, eo))
}

// Serialize a response and hand it to the transport. `server_send_text` copies the
// payload into an owned frame, so the emitter buffer may be released on return.
send_response :: proc(conn: ^Conn, resp: wire.Response) -> bool {
    assert(conn != nil, "response send needs connection state")
    assert(conn.wsc != nil, "response send needs transport state")
    // `initialize` is answered while still Awaiting_Initialize; every other response is Ready.
    assert(conn.state != .Closed, "response sent after protocol close")
    assert(wire.response_validate(resp) == .None, "daemon built an invalid response frame")

    e: wire.Emitter
    wire.emitter_init(&e, conn.allocator)
    defer wire.emitter_destroy(&e)
    wire.response_emit(&e, resp)

    if send_err := ws.server_send_text(conn.wsc, transmute([]byte)wire.to_string(&e)); send_err != .None {
        conn_abort(conn, send_err)
        return false
    }

    return true
}

// Answer `initialize` with the daemon snapshot. No session engine or catalog exists yet,
// so the snapshot is empty; capabilities advertise only what this config
// offers (`blob_upload` when a blob directory is configured).
send_initialize_result :: proc(conn: ^Conn, id: wire.Request_Id) -> bool {
    assert(conn != nil, "initialize send needs connection state")
    assert(conn.daemon != nil, "initialize send needs daemon state")
    assert(conn.wsc != nil, "initialize send needs transport state")
    assert(conn.state == .Awaiting_Initialize, "initialize result sent outside Awaiting_Initialize")

    capabilities: bit_set[wire.Capability]
    if conn.daemon.blob_dir != "" {
        capabilities += {.Blob_Upload}
    }

    result := wire.Initialize_Result {
        protocol = wire.PROTOCOL_VERSION,
        daemon = {version = conn.daemon.daemon_version, server_now_ms = now_ms()},
        capabilities = capabilities,
        workspaces = nil,
        profiles = nil,
        agents = nil,
        session_revision = 0,
        cron_revision = 0,
        catalog_rev = empty_catalog_rev(),
        catalog_health = {skipped = nil, load_error = nil},
    }
    assert(wire.initialize_result_validate(result) == .None, "daemon built an invalid initialize result")

    return send_response(conn, wire.response_ok_build(id, result))
}

// Close a connection with `CLOSE.protocol_error` for a framing/sequence violation
// on unparseable or out-of-sequence input.
conn_protocol_close :: proc(conn: ^Conn) {
    assert(conn != nil, "protocol close needs connection state")
    conn_close(conn, ws.Close_Code(wire.CLOSE.protocol_error))
}

// Begin a transport close with `code` and latch the local Closed state so any
// further buffered frames on this connection are ignored. The `Conn` is freed later,
// from the transport terminal callback. Idempotent.
conn_close :: proc(conn: ^Conn, code: ws.Close_Code) {
    assert(conn != nil, "connection close needs connection state")
    assert(conn.wsc != nil, "connection close needs transport state")

    if conn.state == .Closed {
        return
    }

    conn.state = .Closed
    if close_err := ws.server_close(conn.wsc, code); close_err != .None {
        ws.server_abort(conn.wsc, close_err)
    }
}

// Hard-fail the transport after an internal error made a correct frame impossible.
conn_abort :: proc(conn: ^Conn, err: ws.Server_Error) {
    assert(conn != nil, "connection abort needs connection state")
    assert(conn.wsc != nil, "connection abort needs transport state")
    assert(err != .None, "connection abort needs an error")
    assert(err != .Not_Open, "Not_Open is already terminal")

    if conn.state == .Closed {
        return
    }

    conn.state = .Closed
    ws.server_abort(conn.wsc, err)
}

// Free the connection's owned state and the `Conn` itself. Called once from the
// transport terminal callback, after which the transport frees `wsc`.
conn_free :: proc(conn: ^Conn) {
    assert(conn != nil, "connection cleanup needs connection state")
    assert(conn.wsc != nil, "connection cleanup needs transport state")
    assert(conn.state == .Closed, "connection cleanup before Closed")
    assert(conn.wsc.user_data == conn, "connection cleanup crossed transport ownership")

    conn.wsc.user_data = nil
    mem.dynamic_arena_destroy(&conn.scratch)

    delete(conn.client_name, conn.allocator)
    delete(conn.client_version, conn.allocator)

    free(conn, conn.allocator)
}

// Daemon wall-clock epoch milliseconds, for the `initialize` result's clock.
now_ms :: proc() -> u64 {
    return u64(time.to_unix_nanoseconds(time.now()) / 1_000_000)
}

// Catalog revision emitted before any catalog is loaded: the all-zero hash, which
// is valid lowercase hex and so passes `initialize_result_validate`.
empty_catalog_rev :: proc() -> wire.Catalog_Rev {
    out: [64]u8
    for i in 0 ..< 64 {
        out[i] = '0'
    }

    return wire.Catalog_Rev(out)
}
