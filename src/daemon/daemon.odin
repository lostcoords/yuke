package daemon

import "core:hash"
import "core:log"
import "core:mem"
import "core:nbio"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import "core:unicode/utf8"

import http_server "libs:http/server"
import ws "libs:websocket"
import wire "src:wire"

// Per-connection protocol exchange. The inverse of the client driver's: the daemon
// waits for the client's hello, then replies with its own.
Protocol_State :: enum {
    // Connection is Open; awaiting the client's `client.hello`.
    Awaiting_Hello,

    // `hello` sent; requests are routed to their handlers.
    Ready,

    // A close has been initiated; no further frames are processed.
    Closed,
}

// Synchronous `daemon_start` failures.
Daemon_Error :: enum {
    // No error.
    None,

    // A required pointer, host, or authentication option was invalid.
    Invalid_Options,

    // Binding/listening on the endpoint failed.
    Listen_Failed,

    // Configuration or server storage could not be allocated.
    Out_Of_Memory,
}

// Listen and identity options. Zero-valued fields default in `daemon_start`.
Daemon_Options :: struct {
    // Dotted IPv4 bind address (no scheme). Defaults to the front door's `127.0.0.1`.
    host:           string,

    // TCP port to bind; `/ws` and `/blob/<hash>` share it.
    port:           int,

    // Daemon build/version string reported in `hello`. Defaults to `"0.0.0"`.
    daemon_version: string,

    // Directory holding content-addressed blobs. Empty disables `/blob`.
    blob_dir:       string,

    // Required bearer token. Empty disables authorization; non-empty values use
    // the RFC 3986 unreserved alphabet so the same token is safe in a query.
    auth_token:     string,
}

// A listening yuke daemon on a caller-supplied nbio loop. Owns the HTTP front door
// that binds the port, the WebSocket server it upgrades into, and its own string
// clones; every accepted connection owns its own `Conn`. Start with `daemon_start`,
// stop with `daemon_shutdown`, reclaim with `daemon_destroy`.
Daemon :: struct {
    // Front door: binds the port and routes `/ws` and `/blob/<hash>`. Its handler
    // recovers this `^Daemon` via `c.server.user_data`.
    front_door:     http_server.Server,

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
    // Owned daemon version string, reported in every `hello`.
    daemon_version: string,

    // @private
    // Owned blob directory; empty when `/blob` is disabled.
    blob_dir:       string,

    // @private
    // Owned bearer token; empty when authorization is disabled.
    auth_token:     string,
}

// One accepted connection past the WebSocket handshake. Allocated in the transport
// `on_open` and freed in the terminal callback. Borrows the transport's
// `ws.Server_Conn`; the transport owns that and frees it after the terminal.
Conn :: struct {
    // Transport connection this wraps; borrowed, owned by the WebSocket server.
    wsc:            ^ws.Server_Conn,

    // Owning daemon, for the version string and allocator.
    daemon:         ^Daemon,

    // Allocator backing `scratch` and the retained client identity (the daemon's).
    allocator:      mem.Allocator,

    // Per-connection state machine.
    state:          Protocol_State,

    // Per-frame decode scratch, `free_all`'d after each inbound frame. A frame's
    // borrowed strings and slices live here only for the handler that consumes them.
    scratch:        mem.Dynamic_Arena,

    // Retained client name from `client.hello`; an owned `strings.clone` for
    // identity/logging, freed with the `Conn`. Never the borrowed frame slice.
    client_name:    string,

    // Retained client version from `client.hello`; owned like `client_name`.
    client_version: string,
}

// Begin listening: clone the identity/config, ready the WebSocket server, then bind
// the port; the rest runs on the loop. A synchronous failure returns directly and
// rolls back the clones.
daemon_start :: proc(
    d: ^Daemon,
    loop: ^nbio.Event_Loop,
    options: Daemon_Options,
    allocator := context.allocator,
) -> Daemon_Error {
    if d == nil || loop == nil {
        return .Invalid_Options
    }

    if !daemon_auth_token_valid(options.auth_token) {
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
        daemon_free_config(d)
        return .Out_Of_Memory
    }

    d.auth_token, aerr = strings.clone(options.auth_token, allocator)
    if aerr != nil {
        daemon_free_config(d)
        return .Out_Of_Memory
    }

    callbacks := ws.Server_Callbacks {
        on_open    = daemon_on_open,
        on_message = daemon_on_message,
        on_close   = daemon_on_close,
        on_error   = daemon_on_error,
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
        daemon_free_config(d)
        return .Invalid_Options

    case .Out_Of_Memory:
        daemon_free_config(d)
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

    herr := http_server.listen(
        &d.front_door,
        loop,
        {host = options.host, port = options.port},
        daemon_on_request,
        d,
        allocator,
    )
    switch herr {
    case .None:

    case .Invalid_Options:
        daemon_start_rollback(d)
        return .Invalid_Options

    case .Listen_Failed:
        daemon_start_rollback(d)
        return .Listen_Failed

    case .Out_Of_Memory:
        daemon_start_rollback(d)
        return .Out_Of_Memory
    }

    assert(d.loop == loop, "daemon lost its event loop during startup")
    assert(d.front_door.user_data == d && d.ws_server.user_data == d, "daemon servers have the wrong owner")
    assert(d.front_door.state == .Serving && d.ws_server.state == .Serving, "daemon start did not reach Serving")

    if d.blob_dir != "" {
        removed := blob_sweep_temps(d.blob_dir, time.time_add(time.now(), -UPLOAD_TEMP_GRACE))
        if removed > 0 {
            log.infof("daemon: swept %d stale upload temp file(s) from %s", removed, d.blob_dir)
        }
    }

    host := options.host
    if host == "" {
        host = "127.0.0.1"
    }
    log.infof(
        "daemon: listening on %s:%d version=%s auth=%v blob=%v",
        host,
        http_server.bound_port(&d.front_door),
        d.daemon_version,
        d.auth_token != "",
        d.blob_dir != "",
    )

    return .None
}

// Undo what `daemon_start` built before the bind failed — nothing was ever adopted,
// so the WebSocket server needs no shutdown pass.
daemon_start_rollback :: proc(d: ^Daemon) {
    assert(d != nil, "daemon rollback needs daemon state")
    assert(d.front_door.state == .Idle, "failed front door retained active state")
    assert(d.ws_server.state == .Serving, "websocket server was not initialized before rollback")

    ws.server_destroy(&d.ws_server)
    daemon_free_config(d)
}

// Stop accepting and close every live connection. Closing is async: run the loop
// until both halves report `shutdown_complete` before
// calling `daemon_destroy`.
daemon_shutdown :: proc(d: ^Daemon) {
    assert(d != nil, "daemon_shutdown needs daemon state")
    assert(d.front_door.user_data == d && d.ws_server.user_data == d, "daemon servers have the wrong owner")

    log.info("daemon: shutdown started")
    http_server.shutdown(&d.front_door)
    ws.server_shutdown(&d.ws_server)
}

// Release both connection sets and the owned clones. Call only once both halves
// report `shutdown_complete`; every connection must already be released.
daemon_destroy :: proc(d: ^Daemon) {
    assert(d != nil, "daemon_destroy needs daemon state")
    assert(d.front_door.shutdown_complete, "daemon_destroy before HTTP shutdown completed")
    assert(d.ws_server.shutdown_complete, "daemon_destroy before WebSocket shutdown completed")

    ws.server_destroy(&d.ws_server)
    http_server.destroy(&d.front_door)
    daemon_free_config(d)
}

// Free the owned configuration clones.
daemon_free_config :: proc(d: ^Daemon) {
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

// A connection reached Open: allocate its `Conn`, enter Awaiting_Hello, and attach
// it to the transport connection.
daemon_on_open :: proc(wsc: ^ws.Server_Conn) {
    assert(wsc != nil && wsc.server != nil, "open callback needs an owned transport connection")
    assert(wsc.user_data == nil, "open callback found preexisting application state")

    d := (^Daemon)(wsc.server.user_data)
    assert(d != nil && &d.ws_server == wsc.server, "open callback crossed daemon ownership")

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
    conn.state = .Awaiting_Hello
    mem.dynamic_arena_init(&conn.scratch, d.allocator, d.allocator)

    wsc.user_data = conn
    assert(conn.wsc.user_data == conn, "connection state was not attached to its transport")
    log.debug("daemon: websocket connection open, awaiting hello")
}

// One complete transport message. Only text frames carry protocol data; a binary
// frame is a v1 protocol error.
daemon_on_message :: proc(wsc: ^ws.Server_Conn, kind: ws.Message_Kind, data: []byte) {
    assert(wsc != nil && wsc.server != nil, "message callback needs an owned transport connection")

    conn := (^Conn)(wsc.user_data)
    assert(conn != nil && conn.wsc == wsc, "message callback lost its daemon connection")
    if conn.state == .Closed {
        return
    }

    switch kind {
    case .Text:
        daemon_handle_text(conn, data)

    case .Binary:
        // The v1 protocol carries only text frames.
        daemon_conn_protocol_close(conn)

    case .Ping, .Pong, .Close:
    // Handled by the transport; never delivered here.
    }
}

// A connection closed gracefully: free its `Conn`.
daemon_on_close :: proc(wsc: ^ws.Server_Conn, code: ws.Close_Code) {
    assert(wsc != nil && wsc.server != nil, "close callback needs an owned transport connection")

    conn := (^Conn)(wsc.user_data)
    if conn == nil {
        return
    }

    assert(conn.wsc == wsc, "close callback crossed connection ownership")
    log.debugf("daemon: websocket closed code=%v client=%s", code, conn.client_name)
    conn.state = .Closed
    daemon_conn_free(conn)
}

// A connection failed terminally: free its `Conn`.
daemon_on_error :: proc(wsc: ^ws.Server_Conn, err: ws.Server_Error) {
    assert(wsc != nil && wsc.server != nil, "error callback needs an owned transport connection")
    assert(err != .None, "error callback received no error")

    conn := (^Conn)(wsc.user_data)
    if conn == nil {
        log.warnf("daemon: websocket error before app state: %v", err)
        return
    }

    assert(conn.wsc == wsc, "error callback crossed connection ownership")
    log.warnf("daemon: websocket error %v client=%s", err, conn.client_name)
    conn.state = .Closed
    daemon_conn_free(conn)
}

// Route one inbound text frame. A frame is exactly one JSON value: decode it, reject
// trailing bytes, then act on its type and the connection state. Any decode/validate
// failure or protocol-sequence violation closes the connection.
daemon_handle_text :: proc(conn: ^Conn, data: []byte) {
    assert(conn != nil && conn.wsc != nil && conn.daemon != nil, "text handler needs live connection state")
    assert(conn.wsc.user_data == conn, "text handler crossed transport ownership")
    assert(conn.state != .Closed, "text handler ran after protocol close")

    sa := mem.dynamic_arena_allocator(&conn.scratch)
    defer free_all(sa)

    d := wire.decoder_init(string(data), sa)
    frame, derr := wire.client_frame_from_reader(&d)
    if derr != .None {
        daemon_conn_protocol_close(conn)
        return
    }

    // One JSON value per frame: trailing bytes after the root are a protocol error.
    if wire.dec_finish(&d) != .None {
        daemon_conn_protocol_close(conn)
        return
    }

    switch f in frame {
    case wire.Client_Hello:
        daemon_handle_hello(conn, f)

    case wire.Request:
        daemon_handle_request(conn, f, sa)
    }
}

// Validate and answer the client's `client.hello`. A hello outside Awaiting_Hello
// (a second hello once Ready) is a protocol error; a bad protocol version closes
// with `CLOSE.unsupported_protocol`; any other validation failure is a protocol
// error. On success the daemon retains the client identity, emits its `hello`, and
// reaches Ready.
daemon_handle_hello :: proc(conn: ^Conn, hello: wire.Client_Hello) {
    assert(conn != nil && conn.wsc != nil, "hello handler needs connection state")

    if conn.state != .Awaiting_Hello {
        daemon_conn_protocol_close(conn)
        return
    }

    verr := wire.client_hello_validate(hello)
    if verr != .None {
        if verr == .Unsupported_Protocol {
            daemon_conn_close(conn, ws.Close_Code(wire.CLOSE.unsupported_protocol))
        } else {
            daemon_conn_protocol_close(conn)
        }

        return
    }

    // Retain the client identity as owned clones: the frame arena is reclaimed when
    // this handler returns, so the borrowed name/version cannot be kept directly.
    assert(conn.client_name == "" && conn.client_version == "", "client identity retained twice")

    client_name, aerr := strings.clone(hello.client.name, conn.allocator)
    if aerr != nil {
        daemon_conn_abort(conn, .Out_Of_Memory)
        return
    }

    client_version, version_aerr := strings.clone(hello.client.version, conn.allocator)
    if version_aerr != nil {
        delete(client_name, conn.allocator)
        daemon_conn_abort(conn, .Out_Of_Memory)
        return
    }

    conn.client_name = client_name
    conn.client_version = client_version

    if daemon_send_hello(conn) {
        conn.state = .Ready
    }
}

// Answer a request. A request before Ready is a protocol error; a malformed request
// after Ready is a protocol error (not an error response). A well-formed request is
// routed to its handler: the four read-only methods run real handlers, every other
// method receives an `Unknown_Method` error. Result data is built in `sa`, the
// per-frame arena `daemon_handle_text` reclaims after this returns.
daemon_handle_request :: proc(conn: ^Conn, req: wire.Request, sa: mem.Allocator) {
    assert(conn != nil && conn.wsc != nil, "request handler needs connection state")

    if conn.state != .Ready {
        daemon_conn_protocol_close(conn)
        return
    }

    // Validate the request (id range, params bounds) before echoing its id back; a
    // malformed request is a protocol error, not an error response.
    if wire.request_validate(req) != .None {
        daemon_conn_protocol_close(conn)
        return
    }

    switch req.method {
    case .Session_List:
        daemon_method_session_list(conn, req)

    case .Catalog_List:
        daemon_method_catalog_list(conn, req)

    case .Workspace_Describe:
        daemon_method_workspace_describe(conn, req, sa)

    case .Workspace_Browse:
        daemon_method_workspace_browse(conn, req, sa)

    case .Session_Create,
         .Session_Patch,
         .Session_Remove,
         .Session_Fork,
         .Session_Reload,
         .Session_Compact,
         .Session_Rewind,
         .Session_Send_Input,
         .Session_Cancel_Input,
         .Session_Cancel_Run,
         .Session_Resync,
         .Session_History,
         .Permission_Decide,
         .Session_Config,
         .Subscription_Set,
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
        daemon_send_error(conn, req.id, .Unknown_Method, "method not implemented")
    }
}

// `session.list` before any store exists: an empty page pinned to revision 0, the
// same session revision the hello snapshot claims. Params are already validated, so
// bounds are honored; there simply are no rows to page.
daemon_method_session_list :: proc(conn: ^Conn, req: wire.Request) {
    assert(conn != nil && conn.state == .Ready, "session.list ran outside Ready")
    assert(req.method == .Session_List, "session.list received another method")

    result := wire.Session_List_Result {
        revision    = 0,
        items       = nil,
        next_cursor = nil,
        total       = 0,
    }

    daemon_send_result(conn, req.id, result)
}

// `catalog.list` before any catalog is loaded: `unchanged` when the client already
// holds the empty revision, otherwise a `full` snapshot with no models and empty
// health. Both carry the all-zero catalog hash the hello snapshot reports.
daemon_method_catalog_list :: proc(conn: ^Conn, req: wire.Request) {
    assert(conn != nil && conn.state == .Ready, "catalog.list ran outside Ready")
    assert(req.method == .Catalog_List, "catalog.list received another method")

    params := req.params.(wire.Catalog_List_Params)
    empty := daemon_empty_catalog_rev()

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

    daemon_send_result(conn, req.id, result)
}

// `workspace.describe` on a real path: canonicalize it (a missing path or a
// non-directory is `Bad_Request`), then report the derived id, basename title, git
// branch, and directory mtime. With no store there is no `last_used_model`.
daemon_method_workspace_describe :: proc(conn: ^Conn, req: wire.Request, sa: mem.Allocator) {
    assert(conn != nil && conn.state == .Ready, "workspace.describe ran outside Ready")
    assert(req.method == .Workspace_Describe, "workspace.describe received another method")

    params := req.params.(wire.Workspace_Describe_Params)

    canonical, cerr := os.get_absolute_path(params.path, sa)
    if cerr != nil {
        daemon_send_error(conn, req.id, .Bad_Request, "invalid workspace path")
        return
    }

    if !os.is_dir(canonical) {
        daemon_send_error(conn, req.id, .Bad_Request, "workspace path is not a directory")
        return
    }

    result := wire.Workspace_Describe_Result {
        workspace = wire.Workspace {
            id = daemon_workspace_id(canonical),
            root = canonical,
            title = daemon_workspace_title(canonical),
        },
        git = daemon_git_info(canonical, sa),
        last_modified_ms = daemon_path_mtime_ms(canonical, sa),
        last_used_model = nil,
    }

    daemon_send_result(conn, req.id, result)
}

// `workspace.browse` of a real directory: its immediate subdirectories (never files,
// never `.git`), sorted case-insensitively, paginated by an opaque decimal-offset
// cursor. A missing path defaults to the daemon user's home. Path and cursor faults
// are `Bad_Request`; a weird path never crashes the daemon.
daemon_method_workspace_browse :: proc(conn: ^Conn, req: wire.Request, sa: mem.Allocator) {
    assert(conn != nil && conn.state == .Ready, "workspace.browse ran outside Ready")
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
        daemon_send_error(conn, req.id, .Bad_Request, "cannot open path")
        return
    }

    entries, lerr := daemon_browse_entries(dir, sa)
    if lerr != nil {
        daemon_send_error(conn, req.id, .Bad_Request, "cannot list path")
        return
    }

    offset := 0
    if cursor, ok := params.cursor.?; ok {
        n, valid := strconv.parse_int(cursor, 10)
        if !valid || n < 0 {
            daemon_send_error(conn, req.id, .Bad_Request, "malformed workspace.browse cursor")
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
        parent      = daemon_parent_dir(dir),
        entries     = page,
        next_cursor = next_cursor,
    }

    daemon_send_result(conn, req.id, result)
}

// Validate and emit a successful response. The result is built from already-trusted
// daemon state, so an invalid outgoing frame is our bug, not the peer's — assert
// rather than ship it.
daemon_send_result :: proc(conn: ^Conn, id: wire.Request_Id, result: wire.Response_Result) {
    assert(conn != nil && conn.state == .Ready, "result emitted outside Ready")
    assert(wire.response_result_validate(result) == .None, "daemon built an invalid result frame")
    daemon_send_response(conn, wire.response_ok_build(id, result))
}

// Emit an error response naming `code`. `message` is diagnostic only; clients branch
// on `code`.
daemon_send_error :: proc(conn: ^Conn, id: wire.Request_Id, code: wire.Error_Code, message: string) {
    assert(conn != nil && conn.state == .Ready, "error response emitted outside Ready")

    eo := wire.Error_Object {
        code    = code,
        message = message,
    }

    daemon_send_response(conn, wire.response_error_build(id, eo))
}

// Serialize a response and hand it to the transport. `server_send_text` copies the
// payload into an owned frame, so the emitter buffer may be released on return.
daemon_send_response :: proc(conn: ^Conn, resp: wire.Response) -> bool {
    assert(conn != nil && conn.wsc != nil, "response send needs connection state")
    assert(conn.state == .Ready, "response sent outside Ready")
    assert(wire.response_validate(resp) == .None, "daemon built an invalid response frame")

    e: wire.Emitter
    wire.emitter_init(&e, conn.allocator)
    defer wire.emitter_destroy(&e)
    wire.response_emit(&e, resp)

    if send_err := ws.server_send_text(conn.wsc, transmute([]byte)wire.to_string(&e)); send_err != .None {
        daemon_conn_abort(conn, send_err)
        return false
    }

    return true
}

// Emit the coarse `hello` snapshot. This build-order step has no store, sessions,
// or catalog, so the snapshot is empty: no workspaces or profiles, zero revisions,
// the all-zero catalog hash, and empty health. It MUST pass `server_hello_validate`.
// Capabilities advertise only what this build/config offers: `blob_upload` when a
// blob directory is configured; terminal/eval/revert/fs are not built yet.
daemon_send_hello :: proc(conn: ^Conn) -> bool {
    assert(conn != nil && conn.daemon != nil && conn.wsc != nil, "hello send needs connection state")
    assert(conn.state == .Awaiting_Hello, "server hello sent outside Awaiting_Hello")

    capabilities: bit_set[wire.Capability]
    if conn.daemon.blob_dir != "" {
        capabilities += {.Blob_Upload}
    }

    hello := wire.Server_Hello {
        type = "hello",
        protocol = wire.PROTOCOL_VERSION,
        daemon = {version = conn.daemon.daemon_version, server_now_ms = daemon_now_ms()},
        capabilities = capabilities,
        workspaces = nil,
        profiles = nil,
        session_revision = 0,
        cron_revision = 0,
        catalog_rev = daemon_empty_catalog_rev(),
        catalog_health = {skipped = nil, load_error = nil},
    }
    assert(wire.server_hello_validate(hello) == .None, "daemon built an invalid hello frame")

    e: wire.Emitter
    wire.emitter_init(&e, conn.allocator)
    defer wire.emitter_destroy(&e)
    wire.server_hello_emit(&e, hello)

    if send_err := ws.server_send_text(conn.wsc, transmute([]byte)wire.to_string(&e)); send_err != .None {
        daemon_conn_abort(conn, send_err)
        return false
    }

    return true
}

// Close a connection with `CLOSE.protocol_error` for a framing/sequence violation
// on unparseable or out-of-sequence input.
daemon_conn_protocol_close :: proc(conn: ^Conn) {
    assert(conn != nil, "protocol close needs connection state")

    daemon_conn_close(conn, ws.Close_Code(wire.CLOSE.protocol_error))
}

// Begin a transport close with `code` and latch the local Closed state so any
// further buffered frames on this connection are ignored. The `Conn` is freed later,
// from the transport terminal callback. Idempotent.
daemon_conn_close :: proc(conn: ^Conn, code: ws.Close_Code) {
    assert(conn != nil && conn.wsc != nil, "connection close needs transport state")

    if conn.state == .Closed {
        return
    }

    conn.state = .Closed
    if close_err := ws.server_close(conn.wsc, code); close_err != .None {
        ws.server_abort(conn.wsc, close_err)
    }
}

// Hard-fail the transport after an internal error made a correct frame impossible.
daemon_conn_abort :: proc(conn: ^Conn, err: ws.Server_Error) {
    assert(conn != nil && conn.wsc != nil, "connection abort needs transport state")
    assert(err != .None && err != .Not_Open, "connection abort needs a terminal internal error")

    if conn.state == .Closed {
        return
    }

    conn.state = .Closed
    ws.server_abort(conn.wsc, err)
}

// Free the connection's owned state and the `Conn` itself. Called once from the
// transport terminal callback, after which the transport frees `wsc`.
daemon_conn_free :: proc(conn: ^Conn) {
    assert(conn != nil && conn.wsc != nil, "connection cleanup needs transport state")
    assert(conn.state == .Closed, "connection cleanup before Closed")
    assert(conn.wsc.user_data == conn, "connection cleanup crossed transport ownership")

    conn.wsc.user_data = nil
    mem.dynamic_arena_destroy(&conn.scratch)

    if len(conn.client_name) > 0 {
        delete(conn.client_name, conn.allocator)
    }

    if len(conn.client_version) > 0 {
        delete(conn.client_version, conn.allocator)
    }

    free(conn, conn.allocator)
}

// Daemon wall-clock epoch milliseconds, for the `hello` clock.
daemon_now_ms :: proc() -> u64 {
    return u64(time.to_unix_nanoseconds(time.now()) / 1_000_000)
}

// Catalog revision emitted before any catalog is loaded: the all-zero hash, which
// is valid lowercase hex and so passes `server_hello_validate`.
daemon_empty_catalog_rev :: proc() -> wire.Catalog_Rev {
    out: [64]u8
    for i in 0 ..< 64 {
        out[i] = '0'
    }

    revision := wire.Catalog_Rev(out)
    assert(wire.enforce_fixed_lower_hex(64, string(out[:])) == .None, "empty catalog revision is invalid")

    return revision
}

// Derived workspace id: FNV-1a-64 over the canonical root's UTF-8 bytes, rendered as
// 16 lowercase hex chars. The same scheme the reference daemon uses, so a directory
// always maps to a stable id.
daemon_workspace_id :: proc(root: string) -> wire.Workspace_Id {
    assert(len(root) > 0, "workspace id needs a canonical root")

    h := hash.fnv64a(transmute([]byte)root)

    hex := "0123456789abcdef"
    out: [16]u8
    for i in 0 ..< 16 {
        out[i] = hex[(h >> uint((15 - i) * 4)) & 0xf]
    }

    id := wire.Workspace_Id(out)
    assert(wire.enforce_fixed_lower_hex(16, string(out[:])) == .None, "derived workspace id is invalid")

    return id
}

// Display title for a workspace: the canonical root's basename, falling back to the
// whole root when it has none (the filesystem root). Clamped to the `Workspace.title`
// bound: some filesystems (APFS) allow names past the wire's 256-byte limit.
daemon_workspace_title :: proc(root: string) -> string {
    assert(len(root) > 0, "workspace title needs a canonical root")

    base := os.base(root)
    title := base
    if title == "" {
        title = root
    }

    return daemon_clamp_utf8_bytes(title, 256)
}

// Truncate `s` to at most `max` bytes, backing off to the previous UTF-8 rune
// boundary if `max` lands mid-rune. Keeps peer-influenceable strings (git ref
// names, filesystem basenames) within a wire byte bound. Filesystem bytes are
// untrusted: an input that is not valid UTF-8 yields "" so no caller can emit an
// invalid TEXT frame.
daemon_clamp_utf8_bytes :: proc(s: string, max: int) -> string {
    assert(max >= 0, "daemon_clamp_utf8_bytes: max must be non-negative")

    if !utf8.valid_string(s) {
        return ""
    }

    if len(s) <= max {
        return s
    }

    cut := max
    for cut > 0 && s[cut] & 0xC0 == 0x80 {
        cut -= 1
    }

    return s[:cut]
}

// Git status for a workspace root: null when it is not a repo (no `.git`), else the
// branch parsed from `.git/HEAD`. Dirty detection needs the git binary, which this
// step deliberately avoids, so `dirty` is always reported false.
daemon_git_info :: proc(root: string, allocator: mem.Allocator) -> Maybe(wire.Git_Info) {
    assert(len(root) > 0, "git info needs a canonical root")

    git_marker := strings.concatenate({root, "/.git"}, allocator)
    if !os.exists(git_marker) {
        return nil
    }

    return wire.Git_Info{branch = daemon_git_branch(root, allocator), dirty = false}
}

// Current branch from `.git/HEAD`: the ref name for a symbolic HEAD, or "" for a
// detached, unreadable, or non-UTF-8 HEAD. Clamped to the `Git_Info.branch` bound so
// a pathological ref can never produce an invalid result frame.
daemon_git_branch :: proc(root: string, allocator: mem.Allocator) -> string {
    assert(len(root) > 0, "git branch needs a canonical root")

    head, err := os.read_entire_file_from_path(strings.concatenate({root, "/.git/HEAD"}, allocator), allocator)
    if err != nil {
        return ""
    }

    ref := strings.trim_space(string(head))
    PREFIX :: "ref: refs/heads/"
    if !strings.has_prefix(ref, PREFIX) {
        return ""
    }

    branch := ref[len(PREFIX):]

    return daemon_clamp_utf8_bytes(branch, 256)
}

// The directory's modification time in epoch ms, or 0 when it cannot be stat'd.
daemon_path_mtime_ms :: proc(path: string, allocator: mem.Allocator) -> u64 {
    assert(len(path) > 0, "path mtime needs a canonical path")

    info, err := os.stat(path, allocator)
    if err != nil {
        return 0
    }

    ns := time.to_unix_nanoseconds(info.modification_time)
    if ns < 0 {
        return 0
    }

    return u64(ns / 1_000_000)
}

// The parent-directory path of a canonicalized dir, or null at the filesystem root.
daemon_parent_dir :: proc(dir: string) -> Maybe(string) {
    assert(len(dir) > 0, "parent lookup needs a canonical directory")

    if dir == "/" {
        return nil
    }

    return os.dir(dir)
}

// List `dir`'s immediate subdirectories as `Dir_Entry`s, case-insensitively sorted,
// omitting files, the `.git` directory, names past the wire's 256-byte bound, and
// entries whose name or path is not valid UTF-8, and flagging git repos. Symlinks are
// followed. Errors only when the directory itself cannot be read.
daemon_browse_entries :: proc(dir: string, allocator: mem.Allocator) -> (entries: []wire.Dir_Entry, err: os.Error) {
    assert(len(dir) > 0, "browse needs a canonicalized directory")

    infos := os.read_all_directory_by_path(dir, allocator) or_return

    out := make([dynamic]wire.Dir_Entry, 0, len(infos), allocator)
    for info in infos {
        if info.name == ".git" {
            continue
        }

        if len(info.name) > 256 {
            // Some filesystems (APFS) allow names up to 255 characters, up to ~1020
            // UTF-8 bytes, past the wire's 256-byte Dir_Entry.name bound. Such an entry
            // is unrepresentable on the wire, so it is skipped rather than aborting.
            continue
        }

        if !utf8.valid_string(info.name) || !utf8.valid_string(info.fullpath) {
            // Filesystem bytes are untrusted: a non-UTF-8 name or path cannot ride a
            // WebSocket TEXT frame (RFC 6455 §5.6), so it is skipped, not emitted.
            continue
        }

        if !daemon_info_is_dir(info, allocator) {
            continue
        }

        append(
            &out,
            wire.Dir_Entry {
                name = info.name,
                path = info.fullpath,
                is_git_repo = os.exists(strings.concatenate({info.fullpath, "/.git"}, allocator)),
            },
        )
    }

    slice.sort_by(out[:], daemon_dir_entry_less)

    return out[:], nil
}

// Whether a directory entry resolves to a directory, following a symlink or an entry
// whose type the platform left undetermined.
daemon_info_is_dir :: proc(info: os.File_Info, allocator: mem.Allocator) -> bool {
    if info.type == .Directory {
        return true
    }

    if info.type == .Symlink || info.type == .Undetermined {
        resolved, err := os.stat(info.fullpath, allocator)
        return err == nil && resolved.type == .Directory
    }

    return false
}

// Case-insensitive name order for a browse listing (ASCII fold), matching the
// reference daemon's deterministic ordering.
daemon_dir_entry_less :: proc(a, b: wire.Dir_Entry) -> bool {
    an := a.name
    bn := b.name
    n := min(len(an), len(bn))

    for i in 0 ..< n {
        ca := daemon_ascii_lower(an[i])
        cb := daemon_ascii_lower(bn[i])
        if ca != cb {
            return ca < cb
        }
    }

    return len(an) < len(bn)
}

// ASCII lowercase fold of one byte.
daemon_ascii_lower :: proc(c: u8) -> u8 {
    if c >= 'A' && c <= 'Z' {
        return c + 32
    }

    return c
}
