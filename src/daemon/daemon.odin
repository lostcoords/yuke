package daemon

import "core:log"
import "core:mem"
import "core:nbio"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

import "core:mem/virtual"
import curl "libs:bindings/curl"
import http_server "libs:http/server"
import "libs:offload"
import ws "libs:websocket"
import provider_auth "src:auth"
import store "src:daemon/store"
import js "src:js"
import "src:paths"
import wire "src:wire"

// nbio offload workers, for blocking filesystem calls off the reactor.
WORKER_COUNT :: 2

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

    // The private credential store, OAuth client, or loopback callback listener
    // could not be initialized.
    Auth_Failed,

    // The configured script root's entry script raised. Serving with a script tier the
    // operator believes is loaded would be worse than refusing to start.
    Script_Failed,
}

// Hosted control plane the relay fetches link tickets from when `yuked.js` sets no `relayCloudUrl`.
RELAY_CLOUD_URL_DEFAULT :: "https://platform.yuke.sh"

// Listen and identity options. Zero-valued fields default in `start`. When `yuked.js` in the
// script root calls `defineConfig`, its values supersede `host`, `port`, `db_path`, `blob_dir`,
// `auth_token`, and `relay_cloud_url` here; `daemon_version`, `js_root`, and `auth_path` are
// always the caller's.
Options :: struct {
    // Dotted IPv4 bind address (no scheme). Defaults to the front door's `127.0.0.1`.
    host:            string,

    // TCP port to bind; `/ws` and `/blob/<hash>` share it.
    port:            int,

    // Daemon build/version string reported in `initialize`. Defaults to `"0.0.0"`.
    daemon_version:  string,

    // Directory holding content-addressed blobs, created if absent. Empty disables
    // `/blob`.
    blob_dir:        string,

    // Required bearer token. Empty disables authorization; non-empty values use
    // the RFC 3986 unreserved alphabet so the same token is safe in a query.
    auth_token:      string,

    // SQLite database holding the event log, created if absent. Empty disables the
    // store, and with it every durable broadcast.
    db_path:         string,

    // Private provider credential file. Empty disables WebSocket OAuth methods.
    auth_path:       string,

    // Directory the script tier reads: `yuked.js` is evaluated at startup and every
    // `yuke:fs` path must resolve inside it. Empty disables `yuke:fs` and runs no script.
    js_root:         string,

    // Control-plane base URL the relay fetches link tickets from. Empty defaults to
    // `RELAY_CLOUD_URL_DEFAULT` in `start`.
    relay_cloud_url: string,
}

// A listening yuke daemon on a caller-supplied nbio loop. Owns the HTTP front door, the
// WebSocket server it upgrades into, and its own string clones. Start/stop/reclaim with
// `start`/`shutdown`/`destroy`.
Daemon :: struct {
    // Front door: binds the port; `user_data` is `&router`.
    front_door:          http_server.Server,

    // HTTP routes and pre-match middleware for the front door. `user_data` is this
    // `^Daemon`, and every callback receives it typed as `Http_Context.user_data`.
    router:              Http_Router,

    // WebSocket server fed by `http`, driven through `ws.server_*`. Its
    // per-connection callbacks recover this `^Daemon` via `wsc.server.user_data`.
    ws_server:           ws.Server,

    // @private
    // Borrowed event loop the transport submits ops to; never run here.
    loop:                ^nbio.Event_Loop,

    // @private
    // Backs the owned config strings and every connection's `Conn`. Must outlive
    // the daemon.
    allocator:           mem.Allocator,

    // @private
    // Owned daemon version string, reported in every `initialize` result.
    daemon_version:      string,

    // @private
    // Owned blob directory; empty when `/blob` is disabled.
    blob_dir:            string,

    // @private
    // See `WORKER_COUNT`.
    workers:             offload.Pool,

    // @private
    // Owned bearer token; empty when authorization is disabled.
    auth_token:          string,

    // @private
    // Event log of record, open for the daemon's whole serving life. Nil when no
    // database is configured, which is what makes a durable broadcast impossible.
    store:               ^store.Store,

    // @private
    // Owned credential-file path; empty when WebSocket OAuth is disabled.
    auth_path:           string,

    // @private
    // Current private credential snapshot; nil exactly when `auth_path` is empty.
    auth_store:          ^provider_auth.Store,

    // @private
    // Loopback-only OAuth callback listener and its route table. The single route
    // is filled per browser login with that provider's registered callback path.
    auth_callback:       http_server.Server,
    auth_router:         Http_Router,
    auth_callback_route: [1]Http_Route,

    // @private
    // Bounded OAuth control-plane HTTP transfers on the daemon loop.
    auth_curl:           curl.Client,
    auth_curl_ready:     bool,

    // @private
    // At most one login/refresh/credential-write is active across all providers.
    // Refresh is daemon-owned and never appears on the wire.
    auth_login:          ^Provider_Login,
    auth_refresh:        ^Provider_Refresh,
    auth_refresh_timer:  ^nbio.Operation,
    auth_write_job:      ^Credential_Job,
    auth_stopping:       bool,

    // @private
    // Per-session durable high-water: the pump's seq authority. Recovered from the
    // store on first touch, so an absent entry is re-read rather than assumed zero.
    seq_high:            map[wire.Session_Id]wire.Seq,

    // @private
    // Scratch for one broadcast's encode; a single `Arena_Temp` spans the whole fan-out so
    // a shed marker minted mid-send shares it with the frame in flight.
    pump_scratch:        virtual.Arena,

    // @private
    // Shared scratch for one inbound frame; each `handle_text` wraps it in an `Arena_Temp`.
    frame_scratch:       virtual.Arena,

    // @private
    // Live connections keyed by the ticket that outlives them. Sized for the transport's
    // connection cap in `start`, so an admitted connection never allocates to register.
    conns:               map[Conn_Ticket]^Conn,

    // @private
    // Monotonic ticket source; incremented before use so zero is never issued.
    next_ticket:         Conn_Ticket,

    // @private
    // The outbound relay link, or nil when no relay is configured. Shares this daemon's
    // loop, store, and connection table; connected after `start` via `relay_connect`.
    relay:               ^Relay,

    // @private
    // Control-plane base URL the relay fetches link tickets from, resolved in `start` from the
    // manifest's `relayCloudUrl` or the hosted default. Owned; freed in the config cleanup.
    relay_cloud_url:     string,

    // @private
    // Script tier: one QuickJS runtime for the whole daemon. Torn down after the worker
    // pool drains, since an in-flight host op owns a promise in its context.
    js:                  js.Host,

    // @private
    // Manifest config captured by `yuke:daemon` `defineConfig` during entry eval, and the flag
    // recording that it was called. Startup-transient: `start` decodes and frees `config_json`
    // before serving, leaving both zero.
    config_json:         string,
    config_seen:         bool,

    // Log level resolved from the manifest (`info` when unset or storeless). The caller owns
    // the logger, so it reads this after `start` and installs the matching one.
    log_level:           log.Level,
}

// Connection identity that outlives the `Conn`, so async work can resolve it later
// instead of holding a dangling pointer. Never reused, so a stale ticket resolves to
// `nil` rather than a later connection.
Conn_Ticket :: distinct u64

// The transport a `Conn` rides. A local client rides the WebSocket server; a relay client
// rides the daemon's single relay link, whose session and socket live on `d.relay`. Exactly
// one variant is set. The session, store, and pump below the transport are identical for
// both — only the send/close/liveness ops differ.
Conn_Transport :: union {
    ^ws.Server_Conn,
    ^Relay,
}

// One accepted connection, local or relay. A local connection is created in `ws_on_open`
// and freed from its transport terminal callback; a relay connection is created by the
// bridge once the client's handshake completes and freed when the peer leaves.
Conn :: struct {
    // The transport this connection rides. Exactly one variant is set for its whole life.
    tx:                 Conn_Transport,

    // Owning daemon, for the version string and allocator.
    daemon:             ^Daemon,

    // See `Conn_Ticket`.
    ticket:             Conn_Ticket,

    // Allocator backing `scratch` and the retained client identity (the daemon's).
    allocator:          mem.Allocator,
    state:              Protocol_State,

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

    // Live deltas shed to this connection since the last `session.deltas_shed` it
    // accepted, positionally parallel to `subscriptions`. Inline for the same reason:
    // the fan-out's backpressure path allocates no per-connection state.
    shed_counts:        [wire.LIMITS.max_subscriptions]u64,
}

// Begin listening. A synchronous failure returns directly and rolls back the clones
// and the WebSocket server; past the bind, everything runs on the loop.
start :: proc(d: ^Daemon, loop: ^nbio.Event_Loop, options: Options, allocator := context.allocator) -> (err: Error) {
    if d == nil || loop == nil {
        return .Invalid_Options
    }

    options := options

    d^ = {}
    d.loop = loop
    d.allocator = allocator
    d.log_level = .Info

    defer if err != .None {
        start_rollback(d)
    }

    version := options.daemon_version
    if version == "" {
        version = "0.0.0"
    }

    // Bootstrap clones: version and the credential path do not come from the manifest — the
    // path is where the manifest itself lives, and secrets stay out of it.
    cloned_version, version_aerr := strings.clone(version, allocator)
    cloned_auth_path, auth_path_aerr := strings.clone(options.auth_path, allocator)
    d.daemon_version = cloned_version
    d.auth_path = cloned_auth_path
    if version_aerr != nil || auth_path_aerr != nil {
        return .Out_Of_Memory
    }

    // Started before the script tier: `yuke:fs` offloads onto it, and `workspace.describe`
    // walks paths on it whether or not a blob directory is configured.
    if perr := offload.pool_init(&d.workers, loop, WORKER_COUNT); perr != .None {
        return .Invalid_Options
    }

    // The manifest runs before anything consumes config: `yuked.js`'s `defineConfig` is the
    // source of host/port/db/blob/auth_token/log_level, superseding `options` when it is called.
    // A script tier that won't come up is a start failure, not a surprise the first request finds.
    js_err := js_init(d, options.js_root, allocator)
    evaluated := false
    if js_err == .None {
        evaluated, js_err = js_run_entry(d, allocator)
    }

    if js_err != .None {
        return js_err
    }

    // Backs the config decode; proc-scoped because `host`/`db_path` are read later in `start`.
    config_scratch: [16 * mem.Kilobyte]byte

    if d.config_seen {
        scratch := mem.Arena{}
        mem.arena_init(&scratch, config_scratch[:])
        sa := mem.arena_allocator(&scratch)

        config, ok := config_decode(d.config_json, sa)
        if !ok {
            log.error("daemon: yuked.js defineConfig is not valid configuration")

            return .Invalid_Options
        }

        delete(d.config_json, allocator)
        d.config_json = ""

        options.host = config.host
        options.port = config.port
        options.db_path = paths.expand_home(config.db_path, sa)
        options.blob_dir = paths.expand_home(config.blob_dir, sa)
        options.auth_token = config.auth_token
        options.relay_cloud_url = config.relay_cloud_url

        d.log_level = config_log_level(config.log_level)
    } else if evaluated {
        log.warn("daemon: yuked.js did not call defineConfig; running on defaults")
    }

    // The token's source is now final — the manifest's when it defined one, else `options`.
    if !auth_token_valid(options.auth_token) {
        return .Invalid_Options
    }

    if options.db_path == "" {
        log.warn("daemon: no db_path configured; durable broadcasts and the session index are disabled")
    }

    if options.relay_cloud_url == "" {
        options.relay_cloud_url = RELAY_CLOUD_URL_DEFAULT
    }

    // Clone the owned config strings whose source may be the manifest, now that it has run.
    cloned_blob_dir, blob_aerr := strings.clone(options.blob_dir, allocator)
    cloned_token, token_aerr := strings.clone(options.auth_token, allocator)
    cloned_cloud, cloud_aerr := strings.clone(options.relay_cloud_url, allocator)
    d.blob_dir = cloned_blob_dir
    d.auth_token = cloned_token
    d.relay_cloud_url = cloned_cloud
    if blob_aerr != nil || token_aerr != nil || cloud_aerr != nil {
        return .Out_Of_Memory
    }

    if auth_err := provider_auth_init(d); auth_err != .None {
        return auth_err
    }

    // The `initialize` result advertises `blob_upload` from this field alone, so an
    // unusable directory must fail the start rather than 500 every upload.
    if d.blob_dir != "" {
        if mkerr := os.make_directory_all(d.blob_dir, BLOB_DIR_PERMISSIONS); mkerr != nil && !os.is_dir(d.blob_dir) {
            return .Invalid_Options
        }

        warn_exposed_blob_dir(d.blob_dir, allocator)
    }

    // The log of record has to be usable before anything is adopted: a damaged or
    // future-versioned database is a start failure, never a per-request one.
    if options.db_path != "" {
        opened, serr := store.open(options.db_path, allocator)
        if serr != nil {
            log.errorf("daemon: event store unavailable at %s: %v", options.db_path, serr)
            return .Store_Failed
        }

        marks, merr := make(map[wire.Session_Id]wire.Seq, 16, allocator)
        if merr != nil {
            store.close(opened)
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
        return .Invalid_Options

    case .Out_Of_Memory:
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

    conns, conns_aerr := make(map[Conn_Ticket]^Conn, d.ws_server.max_connections, allocator)
    if conns_aerr != nil {
        return .Out_Of_Memory
    }

    d.conns = conns

    if virtual.arena_init_growing(&d.pump_scratch) != nil {
        return .Out_Of_Memory
    }

    if virtual.arena_init_growing(&d.frame_scratch) != nil {
        return .Out_Of_Memory
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
        return .Invalid_Options

    case .Listen_Failed:
        return .Listen_Failed

    case .Out_Of_Memory:
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

// Undo what `start` built before the bind failed. Nothing was adopted, so no shutdown
// pass; every step tolerates a resource `start` never reached.
start_rollback :: proc(d: ^Daemon) {
    assert(d != nil, "daemon rollback needs daemon state")
    assert(d.front_door.state == .Idle, "failed front door retained active state")

    provider_auth_shutdown(d)

    if d.auth_callback.state != .Idle {
        nbio.run_until(&d.auth_callback.shutdown_complete)
    }

    // Drain first: a completion in flight settles a promise in the context js.destroy frees.
    workers_stop(d)
    provider_auth_destroy(d)
    js.destroy(&d.js)
    store_close(d)

    // Unset loop means the transport never came up.
    if d.ws_server.loop != nil {
        ws.server_destroy(&d.ws_server)
    }

    virtual.arena_check_temp(&d.pump_scratch)
    virtual.arena_destroy(&d.pump_scratch)
    virtual.arena_check_temp(&d.frame_scratch)
    virtual.arena_destroy(&d.frame_scratch)
    delete(d.conns)
    d.conns = nil
    free_config(d)
}

// Drain and release the workers. Idempotent. Must precede releasing the connection table:
// draining runs each completion on this loop, and completions resolve tickets against it.
workers_stop :: proc(d: ^Daemon) {
    assert(d != nil, "worker teardown needs daemon state")

    if !offload.pool_is_running(&d.workers) {
        return
    }

    if derr := offload.pool_drain(&d.workers); derr != nil {
        log.errorf("daemon: worker drain failed: %v", derr)
    }

    offload.pool_destroy(&d.workers)
}

// Stop accepting and close every live connection. Closing is async: run the loop
// until both halves report `shutdown_complete` before calling `destroy`.
shutdown :: proc(d: ^Daemon) {
    assert(d != nil, "shutdown needs daemon state")
    assert(d.front_door.user_data == &d.router, "front door user_data must be the daemon router")
    assert(d.router.user_data == d, "router has the wrong owner")
    assert(d.ws_server.user_data == d, "websocket server has the wrong owner")

    log.info("daemon: shutdown started")
    http_server.shutdown(&d.front_door)
    provider_auth_shutdown(d)
    ws.server_shutdown(&d.ws_server)
    relay_begin_close(d)
}

// Whether both halves have finished closing — the precondition `destroy` asserts. A process
// driving the loop has no other way to know the shutdown it started has landed.
shutdown_complete :: proc(d: ^Daemon) -> bool {
    assert(d != nil, "a shutdown check needs daemon state")

    callback_done := d.auth_callback.state == .Idle || d.auth_callback.shutdown_complete

    return d.front_door.shutdown_complete && callback_done && d.ws_server.shutdown_complete && relay_closed(d)
}

// Release both connection sets and the owned clones. Call only once both halves
// report `shutdown_complete`; every connection must already be released.
destroy :: proc(d: ^Daemon) {
    assert(d != nil, "destroy needs daemon state")
    assert(d.front_door.shutdown_complete, "destroy before HTTP shutdown completed")
    assert(
        d.auth_callback.state == .Idle || d.auth_callback.shutdown_complete,
        "destroy before auth callback shutdown completed",
    )
    assert(d.ws_server.shutdown_complete, "destroy before WebSocket shutdown completed")

    // Order matters: draining runs every outstanding completion on this loop, and a
    // `yuke:fs` completion settles a promise in the context released just below.
    workers_stop(d)
    provider_auth_destroy(d)
    js.destroy(&d.js)
    ws.server_destroy(&d.ws_server)
    relay_destroy(d)
    http_server.destroy(&d.front_door)
    assert(len(d.conns) == 0, "connections outlived the transport that owned them")

    store_close(d)
    virtual.arena_check_temp(&d.pump_scratch)
    virtual.arena_destroy(&d.pump_scratch)
    virtual.arena_check_temp(&d.frame_scratch)
    virtual.arena_destroy(&d.frame_scratch)
    delete(d.conns)
    d.conns = nil
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

// Release the owned config strings, resetting them to empty. Every teardown path can call
// this without knowing how far `start` got.
free_config :: proc(d: ^Daemon) {
    assert(d != nil, "daemon config cleanup needs daemon state")

    delete(d.daemon_version, d.allocator)
    delete(d.blob_dir, d.allocator)
    delete(d.auth_token, d.allocator)
    delete(d.auth_path, d.allocator)
    delete(d.config_json, d.allocator)
    delete(d.relay_cloud_url, d.allocator)
    d.daemon_version = ""
    d.blob_dir = ""
    d.auth_token = ""
    d.auth_path = ""
    d.config_json = ""
    d.relay_cloud_url = ""
}

// Allocate and register a `Conn` for a transport, entering Awaiting_Initialize. Shared by
// the WebSocket accept path and the relay bridge. Returns nil on an allocation failure — the
// caller refuses the connection. The caller wires the transport's back-reference.
conn_register :: proc(d: ^Daemon, tx: Conn_Transport) -> ^Conn {
    assert(d != nil, "connection registration needs daemon state")
    assert(tx != nil, "connection registration needs a transport")

    conn, err := new(Conn, d.allocator)
    if err != nil {
        return nil
    }

    conn^ = {}
    conn.tx = tx
    conn.daemon = d
    conn.allocator = d.allocator
    conn.state = .Awaiting_Initialize

    d.next_ticket += 1
    conn.ticket = d.next_ticket
    if map_insert(&d.conns, conn.ticket, conn) == nil {
        free(conn, d.allocator)
        return nil
    }

    return conn
}

// The WebSocket transport of a local `Conn`; asserts the connection is ws-backed. Used by
// the transport callbacks, which only ever run for local connections.
@(private = "file")
conn_ws :: proc(conn: ^Conn) -> ^ws.Server_Conn {
    t, ok := conn.tx.(^ws.Server_Conn)
    assert(ok, "expected a websocket-backed connection")

    return t
}

// A connection reached Open: allocate its `Conn`, enter Awaiting_Initialize, and attach
// it to the transport connection.
ws_on_open :: proc(wsc: ^ws.Server_Conn) {
    assert(wsc != nil, "open callback needs a transport connection")
    assert(wsc.server != nil, "open callback needs an owning server")
    assert(wsc.user_data == nil, "open callback found preexisting application state")

    d := (^Daemon)(wsc.server.user_data)
    assert(d != nil, "open callback needs daemon state")
    assert(&d.ws_server == wsc.server, "open callback crossed daemon ownership")

    conn := conn_register(d, wsc)
    if conn == nil {
        // Out of memory admitting the connection: refuse it cleanly. It opened, so a
        // terminal fires — with no `Conn` attached, the terminal callbacks no-op.
        log.error("daemon: out of memory admitting websocket connection")
        ws.server_abort(wsc, .Out_Of_Memory)
        return
    }

    wsc.user_data = conn
    assert(conn_ws(conn) == wsc, "connection state was not attached to its transport")
    log.debug("daemon: websocket connection open, awaiting initialize")
}

// One complete transport message. Only text frames carry protocol data; a binary
// frame is a v1 protocol error. Ping/Pong/Close are handled inside the transport
// and never reach here.
ws_on_message :: proc(wsc: ^ws.Server_Conn, kind: ws.Message_Kind, data: []byte) {
    assert(wsc != nil, "message callback needs a transport connection")
    assert(wsc.server != nil, "message callback needs an owning server")

    conn := (^Conn)(wsc.user_data)
    assert(conn != nil, "message callback lost its daemon connection")
    assert(conn_ws(conn) == wsc, "message callback crossed connection ownership")
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

    assert(conn_ws(conn) == wsc, "close callback crossed connection ownership")
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

    assert(conn_ws(conn) == wsc, "error callback crossed connection ownership")
    log.warnf("daemon: websocket error %v client=%s", err, conn.client_name)
    conn.state = .Closed
    conn_free(conn)
}

// Handle one inbound text frame: any decode/validate failure or sequence violation
// closes the connection.
handle_text :: proc(conn: ^Conn, data: []byte) {
    assert(conn != nil, "text handler needs connection state")
    assert(conn.tx != nil, "text handler needs transport state")
    assert(conn.daemon != nil, "text handler needs daemon state")
    assert(conn.state != .Closed, "text handler ran after protocol close")

    d := conn.daemon
    temp := virtual.arena_temp_begin(&d.frame_scratch)
    defer virtual.arena_temp_end(temp)
    sa := virtual.arena_allocator(&d.frame_scratch)

    decoder := wire.decoder_init(string(data), sa)
    req, derr := wire.request_from_reader(&decoder)
    if derr != .None {
        conn_protocol_close(conn)
        return
    }

    // One JSON value per frame: trailing bytes after the root are a protocol error.
    if wire.dec_finish(&decoder) != .None {
        conn_protocol_close(conn)
        return
    }

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
        method_initialize(conn, req, sa)

    case .Session_List:
        method_session_list(conn, req, sa)

    case .Catalog_List:
        method_catalog_list(conn, req, sa)

    case .Auth_List:
        method_auth_list(conn, req, sa)

    case .Auth_Login:
        method_auth_login(conn, req, sa)

    case .Auth_Cancel_Login:
        method_auth_cancel_login(conn, req, sa)

    case .Auth_Logout:
        method_auth_logout(conn, req, sa)

    case .Workspace_Describe:
        method_workspace_describe(conn, req)

    case .Workspace_Browse:
        method_workspace_browse(conn, req, sa)

    case .Subscription_Set:
        method_subscription_set(conn, req, sa)

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
        send_error(conn, req.id, .Unknown_Method, "method not implemented", sa)
    }
}

// Answer `initialize`. On success the daemon retains the client identity, responds
// with its snapshot, and reaches Ready.
method_initialize :: proc(conn: ^Conn, req: wire.Request, sa: mem.Allocator) {
    assert(conn != nil, "initialize handler needs connection state")
    assert(conn.tx != nil, "initialize handler needs transport state")
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

    if send_initialize_result(conn, req.id, sa) {
        conn.state = .Ready
    }
}

// `catalog.list` before any catalog is loaded: `unchanged` when the client already
// holds the empty revision, otherwise a `full` snapshot with no models and empty
// health. Both carry the all-zero catalog hash the initialize snapshot reports.
method_catalog_list :: proc(conn: ^Conn, req: wire.Request, sa: mem.Allocator) {
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

    send_result(conn, req.id, result, sa)
}

// `workspace.describe` on a real path: the path walk is offloaded, and the completion
// reports the derived id, basename title, git branch, and directory mtime. A missing
// path or non-directory is `Bad_Request`; no session engine yet, so no `last_used_model`.
method_workspace_describe :: proc(conn: ^Conn, req: wire.Request) {
    assert(conn != nil, "workspace.describe needs connection state")
    assert(conn.state == .Ready, "workspace.describe ran outside Ready")
    assert(req.method == .Workspace_Describe, "workspace.describe received another method")

    params := req.params.(wire.Workspace_Describe_Params)
    workspace_job_submit(conn, req.id, .Describe, params.path, 0, 0)
}

// Longest browse cursor we could have minted. `strconv.parse_int` wraps silently
// and still reports success, so a longer one is rejected before it is parsed.
@(private)
MAX_BROWSE_CURSOR_DIGITS :: 16

// `workspace.browse`: immediate subdirectories only, sorted case-insensitively,
// paginated by an opaque decimal-offset cursor. Missing path defaults to the daemon
// user's home; cursor and page window are decided here, the listing itself is offloaded.
method_workspace_browse :: proc(conn: ^Conn, req: wire.Request, sa: mem.Allocator) {
    assert(conn != nil, "workspace.browse needs connection state")
    assert(conn.state == .Ready, "workspace.browse ran outside Ready")
    assert(req.method == .Workspace_Browse, "workspace.browse received another method")

    params := req.params.(wire.Workspace_Browse_Params)

    offset := 0
    if cursor, ok := params.cursor.?; ok {
        if len(cursor) > MAX_BROWSE_CURSOR_DIGITS {
            send_error(conn, req.id, .Bad_Request, "malformed workspace.browse cursor", sa)
            return
        }

        n, valid := strconv.parse_int(cursor, 10)
        if !valid || n < 0 {
            send_error(conn, req.id, .Bad_Request, "malformed workspace.browse cursor", sa)
            return
        }

        offset = n
    }

    // Page size is already validated to be within bounds; default when omitted.
    page_size := wire.LIMITS.default_workspace_browse_page_size
    if limit, ok := params.limit.?; ok {
        page_size = int(limit)
    }

    // Reading the environment touches no filesystem, so the default is resolved here and
    // the worker only ever sees a concrete path.
    target: string
    if p, ok := params.path.?; ok {
        target = p
    } else if home, found := os.lookup_env("HOME", sa); found {
        target = home
    } else {
        target = "/"
    }

    workspace_job_submit(conn, req.id, .Browse, target, offset, page_size)
}

// Validate and emit a successful response. The result is built from already-trusted
// daemon state, so an invalid outgoing frame is our bug, not the peer's — assert
// rather than ship it.
send_result :: proc(conn: ^Conn, id: wire.Request_Id, result: wire.Response_Result, allocator: mem.Allocator) {
    assert(conn != nil, "result send needs connection state")
    assert(wire.response_result_validate(result) == .None, "daemon built an invalid result frame")
    send_response(conn, wire.response_ok_build(id, result), allocator)
}

// Emit an error response naming `code`. `message` is diagnostic only; clients branch
// on `code`.
send_error :: proc(
    conn: ^Conn,
    id: wire.Request_Id,
    code: wire.Error_Code,
    message: string,
    allocator: mem.Allocator,
) {
    assert(conn != nil, "error response send needs connection state")

    eo := wire.Error_Object {
        code    = code,
        message = message,
    }

    send_response(conn, wire.response_error_build(id, eo), allocator)
}

// Serialize a response and hand it to the transport; `server_send_text` copies the
// payload, so the emitter buffer may be released on return. `allocator` is the arena of
// the lifetime that asked for the response, never a longer-lived one.
send_response :: proc(conn: ^Conn, resp: wire.Response, allocator: mem.Allocator) -> bool {
    assert(conn != nil, "response send needs connection state")
    assert(conn.tx != nil, "response send needs transport state")
    // `initialize` is answered while still Awaiting_Initialize; every other response is Ready.
    assert(conn.state != .Closed, "response sent after protocol close")
    assert(wire.response_validate(resp) == .None, "daemon built an invalid response frame")

    e, ok := wire.response_encode(resp, allocator)
    defer wire.emitter_destroy(&e)

    // A truncated response is damaged protocol, not a smaller one: the peer would read a
    // partial JSON value and lose framing, so the connection dies instead.
    if !ok {
        log.error("daemon: a response could not be encoded")
        conn_abort(conn, .Out_Of_Memory)
        return false
    }

    if send_err := conn_send_text(conn, transmute([]byte)wire.to_string(&e)); send_err != .None {
        conn_abort(conn, send_err)
        return false
    }

    return true
}

// Answer `initialize` with the daemon snapshot. No session engine or catalog exists yet,
// so the snapshot is empty; capabilities advertise only what this config offers.
send_initialize_result :: proc(conn: ^Conn, id: wire.Request_Id, allocator: mem.Allocator) -> bool {
    assert(conn != nil, "initialize send needs connection state")
    assert(conn.daemon != nil, "initialize send needs daemon state")
    assert(conn.tx != nil, "initialize send needs transport state")
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
    return send_response(conn, wire.response_ok_build(id, result), allocator)
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
    assert(conn.tx != nil, "connection close needs transport state")

    if conn.state == .Closed {
        return
    }

    conn.state = .Closed

    switch t in conn.tx {
    case ^ws.Server_Conn:
        if close_err := ws.server_close(t, code); close_err != .None {
            ws.server_abort(t, close_err)
        }

    case ^Relay:
        relay_conn_close(t)
    }
}

// Hard-fail the transport after an internal error made a correct frame impossible. `err` is
// the send outcome that forced it, reported to the local transport's terminal callback.
conn_abort :: proc(conn: ^Conn, err: ws.Server_Error) {
    assert(conn != nil, "connection abort needs connection state")
    assert(conn.tx != nil, "connection abort needs transport state")
    assert(err != .None, "connection abort needs an error")
    assert(err != .Not_Open, "Not_Open is already terminal")

    if conn.state == .Closed {
        return
    }

    conn.state = .Closed

    switch t in conn.tx {
    case ^ws.Server_Conn:
        ws.server_abort(t, err)

    case ^Relay:
        relay_conn_close(t)
    }
}

// Queue one text frame to the connection's transport — the single write choke point. A
// local connection writes to the WebSocket server; a relay connection seals the frame and
// writes it to the link. Both report a `ws.Server_Error`, the outcome the daemon's send
// policy speaks; the relay link's client-side result is mapped onto it.
conn_send_text :: proc(conn: ^Conn, bytes: []byte) -> ws.Server_Error {
    assert(conn != nil, "send needs connection state")
    assert(conn.tx != nil, "send needs transport state")

    switch t in conn.tx {
    case ^ws.Server_Conn:
        return ws.server_send_text(t, bytes)

    case ^Relay:
        return relay_conn_send(t, bytes)
    }

    unreachable()
}

// Whether the connection's transport can still accept a frame — the liveness half of
// `conn_resolve`, alongside the daemon-side `Closed` latch.
conn_tx_open :: proc(conn: ^Conn) -> bool {
    assert(conn != nil, "liveness needs connection state")
    assert(conn.tx != nil, "liveness needs transport state")

    switch t in conn.tx {
    case ^ws.Server_Conn:
        return t.state == .Open

    case ^Relay:
        return relay_conn_open(t)
    }

    unreachable()
}

// The connection `ticket` names, if it can still be answered, else `nil` — the safe way
// for offloaded work to ask about a connection it doesn't own. Loop thread only.
conn_resolve :: proc(d: ^Daemon, ticket: Conn_Ticket) -> ^Conn {
    assert(d != nil, "resolve needs daemon state")

    if ticket == 0 {
        return nil
    }

    conn := d.conns[ticket]
    if conn == nil {
        return nil
    }

    assert(conn.ticket == ticket, "connection table returned a mismatched ticket")
    assert(conn.tx != nil, "a registered connection has transport state")

    // A connection stays registered until its terminal callback runs, so both halves have
    // to agree it can still be answered: a peer close latches the transport out of Open
    // well before the `Conn` is freed, and a send there fails as `Not_Open`.
    return conn.state != .Closed && conn_tx_open(conn) ? conn : nil
}

// Free the connection's owned state and the `Conn` itself. For a local connection this is
// called once from the transport terminal callback, after which the transport frees `wsc`;
// for a relay connection the bridge calls it when the peer leaves. It severs the transport's
// back-reference so nothing resolves this `Conn` after it is gone.
conn_free :: proc(conn: ^Conn) {
    assert(conn != nil, "connection cleanup needs connection state")
    assert(conn.tx != nil, "connection cleanup needs transport state")
    assert(conn.state == .Closed, "connection cleanup before Closed")
    assert(conn.daemon != nil, "connection cleanup needs daemon state")
    assert(conn.ticket in conn.daemon.conns, "connection cleanup on an unregistered connection")

    delete_key(&conn.daemon.conns, conn.ticket)

    switch t in conn.tx {
    case ^ws.Server_Conn:
        assert(t.user_data == conn, "connection cleanup crossed transport ownership")
        t.user_data = nil

    case ^Relay:
        assert(t.conn == conn, "relay cleanup crossed connection ownership")
        t.conn = nil
    }

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
