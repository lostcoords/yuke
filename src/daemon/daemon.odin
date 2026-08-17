package daemon

import "core:log"
import "core:mem"
import "core:nbio"
import "core:net"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

import "core:mem/virtual"
import http_server "libs:http/server"
import "libs:offload"
import ws "libs:websocket"
import "src:daemon/store"
import "src:js"
import "src:paths"
import "src:relay"
import "src:secret"
import "src:wire"

// nbio offload workers, for blocking filesystem calls off the reactor.
WORKER_COUNT :: 4

// `yuke:exec` commands run on their own workers: one command holds a worker for its whole
// timeout, and `WORKER_COUNT` is what every filesystem call already waits on.
EXEC_WORKER_COUNT :: 4

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

    // A required pointer, startup option, or script definition was invalid.
    Invalid_Options,

    // Binding/listening on the endpoint failed.
    Listen_Failed,

    // Configuration or server storage could not be allocated.
    Out_Of_Memory,

    // The configured database could not be opened, is damaged, or was written by a
    // newer daemon.
    Store_Failed,

    // The OAuth HTTP client could not be initialized.
    Auth_Failed,

    // The models.dev refresh HTTP client could not be initialized.
    Catalog_Failed,

    // The provider inference transport could not be initialized.
    Provider_Failed,

    // The configured script root's entry script raised. Serving with a script tier the
    // operator believes is loaded would be worse than refusing to start.
    Script_Failed,
}

// Hosted control plane the relay fetches link tickets from when `yuked.js` sets no `relayCloudUrl`.
RELAY_CLOUD_URL_DEFAULT :: "https://platform.yuke.sh"

// Owner-only mode for the data directory the store and blobs live under, matching the blobs.
DATA_DIR_PERMISSIONS :: os.Permissions{.Read_User, .Write_User, .Execute_User}

// Listen and identity options; zero-valued fields default in `start`. `defineConfig` in
// `yuked.js` supersedes every field but `daemon_version` and `config_dir`.
Options :: struct {
    // Dotted IPv4 bind address (no scheme). Defaults to the front door's `127.0.0.1`.
    host:            string,

    // TCP port to bind; `/ws` and `/blob/<hash>` share it.
    port:            int,

    // Daemon build/version string reported in `initialize`. Defaults to `"0.0.0"`.
    daemon_version:  string,

    // Blob store directory, created if absent. Empty disables `/blob`. The launcher derives
    // it as `<data-dir>/blobs`.
    blob_dir:        string,

    // Required bearer token. Empty disables authorization; non-empty values use
    // the RFC 3986 unreserved alphabet so the same token is safe in a query.
    auth_token:      string,

    // SQLite event log, created if absent. Empty uses a process-lifetime in-memory database.
    // The launcher derives it as `<data-dir>/yuked.db`.
    db_path:         string,

    // Platform data directory holding the device identity, read at start for the /identity device
    // id. Empty omits it. Same source the relay reads; the manifest never relocates it.
    data_dir:        string,

    // Directory holding `yuked.js`. Empty uses `paths.config_dir` (the TUI's folder). A
    // test build treats empty as "no script" so the developer's config is not loaded.
    config_dir:      string,

    // Control-plane base URL the relay fetches link tickets from. Empty defaults to
    // `RELAY_CLOUD_URL_DEFAULT` in `start`.
    relay_cloud_url: string,

    // Browser origins the front door admits, each a full `scheme://host[:port]`. Empty admits none.
    allowed_origins: []string,
}

// A listening daemon on a caller-supplied nbio loop, owning the front door, the WebSocket
// server, and its own clones. Start/stop/reclaim with `start`/`shutdown`/`destroy`.
Daemon :: struct {
    // Front door: binds the port; `user_data` is `&router`.
    front_door:       http_server.Server,

    // HTTP routes and pre-match middleware for the front door. `user_data` is this
    // `^Daemon`, and every callback receives it typed as `Http_Context.user_data`.
    router:           Http_Router,

    // WebSocket server fed by `http`, driven through `ws.server_*`. Its
    // per-connection callbacks recover this `^Daemon` via `wsc.server.user_data`.
    ws_server:        ws.Server,

    // @private
    // Borrowed event loop the transport submits ops to; never run here.
    loop:             ^nbio.Event_Loop,

    // @private
    // Backs the owned config strings and every connection's `Conn`. Must outlive
    // the daemon.
    allocator:        mem.Allocator,

    // @private
    // Owned daemon version string, reported in every `initialize` result.
    daemon_version:   string,

    // @private
    // Enrolled device id advertised on /identity for local discovery, loaded at start from the
    // same device identity the relay uses. Empty when this machine is not enrolled. Owned.
    device_id:        string,

    // @private
    // Owned blob directory; empty when `/blob` is disabled.
    blob_dir:         string,

    // @private
    // See `WORKER_COUNT`.
    workers:          offload.Pool,

    // @private
    // See `EXEC_WORKER_COUNT`.
    exec_workers:     offload.Pool,

    // @private
    // Live bounded filesystem jobs across all connections.
    fs_jobs:          int,

    // @private
    // Owned bearer token; empty when authorization is disabled.
    auth_token:       string,

    // @private
    // Owned browser-origin allowlist consulted by `middleware_admit`. Empty admits none.
    allowed_origins:  []string,

    // @private
    // Event log of record, open for the daemon's whole serving life. File-backed
    // when configured and process-lifetime in-memory otherwise.
    store:            ^store.Store,

    // @private
    // Provider credentials, OAuth transfers, callback listener, and active work.
    provider_auth:    Provider_Auth,

    // @private
    // Current catalog identity: the revision plus the small health block, resolved at
    // startup. The full model list is re-derived per catalog.list, never retained.
    catalog:          Daemon_Catalog,

    // @private
    // The async models.dev fetch service: shared curl client and single-flight slot.
    catalog_refresh:  Catalog_Refresh,

    // @private
    // The provider inference service. One slot for the whole daemon, so one turn runs at a
    // time; a session whose turn cannot start right now is told the session is busy.
    runs:             Run_Service,

    // @private
    // The turn in flight and the inputs behind it, per session. An entry exists only while a
    // session has one, and is owned here because a canceled turn fires no completion.
    sessions:         map[wire.Session_Id]^Session_Live,

    // @private
    // Per-session durable high-water: the pump's seq authority. Recovered from the
    // store on first touch, so an absent entry is re-read rather than assumed zero.
    seq_high:         map[wire.Session_Id]wire.Seq,

    // @private
    // Session-index revision, raised by every change. Deliberately not recovered: a restart
    // resets it to 0, the "nothing announced yet" a reconnecting client refetches against.
    session_revision: wire.Session_Revision,

    // @private
    // Scratch for one broadcast's encode; a single `Arena_Temp` spans the whole fan-out so
    // a shed marker minted mid-send shares it with the frame in flight.
    pump_scratch:     virtual.Arena,

    // @private
    // Shared scratch for one inbound frame; each `handle_text` wraps it in an `Arena_Temp`.
    frame_scratch:    virtual.Arena,

    // @private
    // Scratch for assembling one turn: transcript page, decoded messages, provider body.
    // Separate from `frame_scratch`, which pays a byte-wipe a transcript does not need.
    turn_scratch:     virtual.Arena,

    // @private
    // Live connections keyed by the ticket that outlives them. Sized for the transport's
    // connection cap in `start`, so an admitted connection never allocates to register.
    conns:            map[Conn_Ticket]^Conn,

    // @private
    // Monotonic ticket source; incremented before use so zero is never issued.
    next_ticket:      Conn_Ticket,

    // @private
    // The outbound relay link, or nil when no relay is configured. Shares this daemon's
    // loop, store, and connection table; connected after `start` via `relay_connect`.
    relay:            ^Relay,

    // @private
    // Control-plane base URL the relay fetches link tickets from, resolved in `start` from the
    // manifest's `relayCloudUrl` or the hosted default. Owned; freed in the config cleanup.
    relay_cloud_url:  string,

    // @private
    // Script tier: one QuickJS runtime for the whole daemon. Torn down after the worker
    // pool drains, since an in-flight host op owns a promise in its context.
    js:               js.Host,

    // @private
    // Owned clone of the script directory when it exists; empty when no host modules.
    config_dir:       string,

    // @private
    // Tools `yuked.js` registered, in registration order. Each owns a live JS handler, so
    // this is released before the context that made them.
    tools:            [dynamic]Daemon_Tool,

    // @private
    // Manifest config from `defineConfig`, and whether it was called. Startup-transient:
    // `start` decodes and frees it before serving, leaving both zero.
    config_json:      string,
    config_seen:      bool,

    // Log level resolved from the manifest (`info` when unset). The caller owns
    // the logger, so it reads this after `start` and installs the matching one.
    log_level:        log.Level,
}

// Connection identity that outlives its `Conn`, so async work resolves it instead of holding
// a pointer. Never reused: a stale ticket resolves to nil, not to a later connection.
Conn_Ticket :: distinct u64

// A relay client's slot on the shared link: the `Relay` plus the one-byte `channel` the relay
// multiplexes it under. Its Noise session and bridged `Conn` live in `relay.peers[channel]`.
Relay_Client :: struct {
    relay:   ^Relay,
    channel: u8,
}

// The transport a `Conn` rides: the WebSocket server, or one channel of the relay link.
// Exactly one variant is set; only send/close/liveness differ below it.
Conn_Transport :: union {
    ^ws.Server_Conn,
    Relay_Client,
}

// One accepted connection. A local one is created in `ws_on_open` and freed from its terminal
// callback; a relay one by the bridge, freed when the peer leaves.
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

    // Filesystem jobs still owned by this connection's ticket.
    fs_jobs:            int,

    // Retained client name from `initialize`; an owned `strings.clone` for
    // identity/logging, freed with the `Conn`. Never the borrowed frame slice.
    client_name:        string,

    // Retained client version from `initialize`; owned like `client_name`.
    client_version:     string,

    // Sessions this connection subscribes to, replaced wholesale by `subscription.set`.
    // Inline and protocol-bounded, so gating never allocates on the fan-out path.
    subscriptions:      [wire.LIMITS.max_subscriptions]wire.Session_Id,

    // Live prefix length of `subscriptions`.
    subscription_count: int,

    // Deltas shed since the last `session.deltas_shed` this connection accepted, positionally
    // parallel to `subscriptions`. Inline for the same reason: backpressure allocates nothing.
    shed_counts:        [wire.LIMITS.max_subscriptions]u64,
}

// Directory `yuked.js` is loaded from. A set `Options.config_dir` wins; otherwise the
// process config directory, except in tests where empty means no script.
@(private = "file")
script_dir_from_options :: proc(options: Options, allocator: mem.Allocator) -> (dir: string, owned: bool) {
    if options.config_dir != "" {
        return options.config_dir, false
    }

    when !ODIN_TEST {
        resolved := paths.config_dir(allocator)

        return resolved, resolved != ""
    }

    return "", false
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

    // The version does not come from the manifest.
    cloned_version, version_aerr := strings.clone(version, allocator)
    d.daemon_version = cloned_version
    if version_aerr != nil {
        return .Out_Of_Memory
    }

    // Started before the script tier: `yuke:fs` offloads onto it, and `workspace.describe`
    // walks paths on it whether or not a blob directory is configured.
    if perr := offload.pool_init(&d.workers, loop, WORKER_COUNT); perr != .None {
        return .Invalid_Options
    }

    if perr := offload.pool_init(&d.exec_workers, loop, EXEC_WORKER_COUNT); perr != .None {
        return .Invalid_Options
    }

    // The manifest runs before anything consumes config and supersedes `options` when it calls
    // `defineConfig`. A script tier that won't come up is a start failure.
    dir, dir_owned := script_dir_from_options(options, allocator)
    defer if dir_owned {
        delete(dir, allocator)
    }

    js_err := js_init(d, dir, allocator)
    evaluated := false
    if js_err == .None {
        evaluated, js_err = js_run_entry(d, allocator)
    }

    if js_err != .None {
        return js_err
    }

    // Startup is over: later host ops must carry a run signal so a cancel stops them.
    if evaluated {
        js.cancel_enforce(&d.js)
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

        secret.string_destroy(&d.config_json, allocator)

        options.host = config.host
        // A zero from the manifest (omitted, or an explicit 0) does not clobber the port the
        // launcher already chose — its `DEFAULT_PORT`, or a test's OS-assigned 0.
        if config.port != 0 {
            options.port = config.port
        }
        // A relocated base re-derives both paths; an omitted `dataDir` keeps the launcher's.
        if config.data_dir != "" {
            base := paths.expand_home(config.data_dir, sa)
            options.db_path = paths.db_path_in(base, sa)
            options.blob_dir = paths.blob_dir_in(base, sa)
        }

        options.auth_token = config.auth_token
        options.relay_cloud_url = config.relay_cloud_url
        options.allowed_origins = config.allowed_origins

        d.log_level = config_log_level(config.log_level)
    } else if evaluated {
        log.warn("daemon: yuked.js did not call defineConfig; running on defaults")
    }

    // The token's source is now final — the manifest's when it defined one, else `options`.
    if !auth_token_valid(options.auth_token) {
        return .Invalid_Options
    }
    if !listen_auth_valid(options.host, options.auth_token) {
        log.error("daemon: a non-loopback listener requires an authentication token")
        return .Invalid_Options
    }

    if options.db_path == "" {
        log.info("daemon: no data directory resolved; using an in-memory event store")
    }

    if options.relay_cloud_url == "" {
        options.relay_cloud_url = RELAY_CLOUD_URL_DEFAULT
    }

    normalized_cloud, cloud_err := relay_cloud_url_normalize(options.relay_cloud_url, allocator)
    if cloud_err != .None {
        log.error("daemon: relayCloudUrl must be HTTPS, or HTTP on a literal loopback address")
        return cloud_err
    }

    // Clone the owned config strings whose source may be the manifest, now that it has run.
    cloned_blob_dir, blob_aerr := strings.clone(options.blob_dir, allocator)
    cloned_token, token_aerr := strings.clone(options.auth_token, allocator)
    cloned_origins, origins_ok := clone_string_slice(options.allowed_origins, allocator)
    d.blob_dir = cloned_blob_dir
    d.auth_token = cloned_token
    d.relay_cloud_url = normalized_cloud
    d.allowed_origins = cloned_origins
    if blob_aerr != nil || token_aerr != nil || !origins_ok {
        return .Out_Of_Memory
    }

    // The enrolled device id for /identity, from the same device identity the relay reads. Only the
    // id is kept: it is moved out, then `identity_destroy` frees and wipes the credential and key.
    if options.data_dir != "" {
        id, ierr := relay.identity_load(options.data_dir, allocator)
        switch ierr {
        case .None:
            d.device_id = id.device_id
            id.device_id = ""
            relay.identity_destroy(&id)

        case .Absent:

        case .Unreadable, .Malformed, .Key_Invalid, .Out_Of_Memory, .Write_Failed, .Stale:
            log.warnf("daemon: device identity unusable (%v); /identity omits device_id", ierr)
        }
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
    opened: ^store.Store
    serr: store.Error
    if options.db_path == "" {
        opened, serr = store.open_memory(allocator)
    } else {
        // Create the data directory on demand; blobs make their own subdirectory above.
        db_dir := filepath.dir(options.db_path)

        if mkerr := os.make_directory_all(db_dir, DATA_DIR_PERMISSIONS); mkerr != nil && !os.is_dir(db_dir) {
            log.errorf("daemon: cannot create data directory %s: %v", db_dir, mkerr)
            return .Store_Failed
        }

        opened, serr = store.open(options.db_path, allocator)
    }
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

    if catalog_err := catalog_state_load(d); catalog_err != nil {
        return .Store_Failed
    }

    if auth_err := provider_auth_init(d); auth_err != .None {
        return auth_err
    }

    if refresh_err := catalog_refresh_init(d); refresh_err != .None {
        return refresh_err
    }

    if run_err := run_service_init(&d.runs, loop, allocator); run_err != .None {
        return run_err
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

    if virtual.arena_init_growing(&d.turn_scratch) != nil {
        return .Out_Of_Memory
    }

    if virtual.arena_init_growing(&d.frame_scratch) != nil {
        return .Out_Of_Memory
    }

    // After the pump owns its scratch and table, before the front door accepts anyone: a run
    // the previous start left open owes a terminal only this start can write.
    runs_recover(d)

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
    assert(d.store != nil, "a serving daemon always owns an event store")

    if d.blob_dir != "" {
        removed := blob_sweep_temps(d.blob_dir, time.time_add(time.now(), -UPLOAD_TEMP_GRACE))
        if removed > 0 {
            log.infof("daemon: swept %d stale upload temp file(s) from %s", removed, d.blob_dir)
        }
    }

    log.infof(
        "daemon: listening on %s:%d version=%s auth=%v blob=%v",
        net.to_string(net.Address(d.front_door.bind_address), context.temp_allocator),
        http_server.bound_port(&d.front_door),
        d.daemon_version,
        d.auth_token != "",
        d.blob_dir != "",
    )

    return .None
}

// Undo what `start` built before the bind failed. Nothing was adopted, so no shutdown
// pass; every step tolerates a resource `start` never reached.
start_rollback :: proc(d: ^Daemon) {
    assert(d != nil, "daemon rollback needs daemon state")
    assert(d.front_door.state == .Idle, "failed front door retained active state")

    catalog_refresh_shutdown(d)
    runs_stop(d)
    provider_auth_shutdown(d)
    js.ops_close(&d.js)

    if d.provider_auth.callback.state != .Idle {
        nbio.run_until(&d.provider_auth.callback.shutdown_complete)
    }

    teardown_release(d)
}

// Release everything `start` built, in the order ownership requires. Shared by `destroy` and
// rollback: every step tolerates a resource `start` never reached.
@(private = "file")
teardown_release :: proc(d: ^Daemon) {
    assert(d != nil, "daemon teardown needs daemon state")

    // Drain first: draining runs every outstanding completion on this loop, and a `yuke:fs`
    // completion settles a promise in the context released just below.
    workers_stop(d)
    provider_auth_destroy(d)
    catalog_refresh_destroy(d)
    run_service_destroy(&d.runs)
    tools_destroy(d)
    js.destroy(&d.js)

    // Unset loop means the transport never came up.
    if d.ws_server.loop != nil {
        ws.server_destroy(&d.ws_server)
    }

    relay_destroy(d)
    http_server.destroy(&d.front_door)
    assert(len(d.conns) == 0, "connections outlived the transport that owned them")

    store_close(d)
    virtual.arena_check_temp(&d.pump_scratch)
    virtual.arena_destroy(&d.pump_scratch)
    virtual.arena_check_temp(&d.frame_scratch)
    virtual.arena_destroy(&d.frame_scratch)
    virtual.arena_check_temp(&d.turn_scratch)
    virtual.arena_destroy(&d.turn_scratch)
    delete(d.conns)
    d.conns = nil
    delete(d.sessions)
    d.sessions = nil
    free_config(d)
}

// Drain and release the workers. Idempotent. Must precede releasing the connection table:
// draining runs each completion on this loop, and completions resolve tickets against it.
workers_stop :: proc(d: ^Daemon) {
    assert(d != nil, "worker teardown needs daemon state")

    pool_stop(&d.workers)
    pool_stop(&d.exec_workers)
}

@(private = "file")
pool_stop :: proc(pool: ^offload.Pool) {
    if !offload.pool_is_running(pool) {
        return
    }

    if derr := offload.pool_drain(pool); derr != nil {
        log.errorf("daemon: worker drain failed: %v", derr)
    }

    offload.pool_destroy(pool)
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
    catalog_refresh_shutdown(d)
    runs_stop(d)
    provider_auth_shutdown(d)
    js.ops_close(&d.js)
    ws.server_shutdown(&d.ws_server)
    relay_begin_close(d)
}

// Whether both halves have finished closing — the precondition `destroy` asserts. A process
// driving the loop has no other way to know the shutdown it started has landed.
shutdown_complete :: proc(d: ^Daemon) -> bool {
    assert(d != nil, "a shutdown check needs daemon state")

    callback_done := d.provider_auth.callback.state == .Idle || d.provider_auth.callback.shutdown_complete
    workers_done := pool_idle(&d.workers) && pool_idle(&d.exec_workers)

    return(
        d.front_door.shutdown_complete &&
        callback_done &&
        d.ws_server.shutdown_complete &&
        relay_closed(d) &&
        workers_done &&
        js.ops_idle(&d.js) \
    )
}

@(private = "file")
pool_idle :: proc(pool: ^offload.Pool) -> bool {
    return !offload.pool_is_running(pool) || offload.pool_outstanding(pool) == 0
}

// Release both connection sets and the owned clones. Call only once both halves
// report `shutdown_complete`; every connection must already be released.
destroy :: proc(d: ^Daemon) {
    assert(d != nil, "destroy needs daemon state")
    assert(d.front_door.shutdown_complete, "destroy before HTTP shutdown completed")
    assert(
        d.provider_auth.callback.state == .Idle || d.provider_auth.callback.shutdown_complete,
        "destroy before auth callback shutdown completed",
    )
    assert(d.ws_server.shutdown_complete, "destroy before WebSocket shutdown completed")
    assert(pool_idle(&d.workers), "destroy before workers drained")
    assert(pool_idle(&d.exec_workers), "destroy before command workers drained")
    assert(js.ops_idle(&d.js), "destroy before JavaScript host operations drained")
    assert(d.fs_jobs == 0, "destroy with filesystem jobs in flight")

    teardown_release(d)
}

// Close the event store and drop the pump's tracked marks. Idempotent, so every
// teardown path can call it without knowing how far `start` got.
store_close :: proc(d: ^Daemon) {
    assert(d != nil, "store teardown needs daemon state")

    if d.store == nil {
        assert(len(d.seq_high) == 0, "seq marks outlived the store that recovered them")
        return
    }

    catalog_state_destroy(d)
    store.close(d.store)
    delete(d.seq_high)
    d.store = nil
    d.seq_high = nil
}

// Deep-clone a string slice into `allocator`, outliving the decode arena. Returns nil/false on an
// allocation failure, freeing the partial clone.
clone_string_slice :: proc(src: []string, allocator: mem.Allocator) -> (out: []string, ok: bool) {
    if len(src) == 0 {
        return nil, true
    }

    dst, aerr := make([]string, len(src), allocator)
    if aerr != nil {
        return nil, false
    }

    for s, i in src {
        clone, cerr := strings.clone(s, allocator)
        if cerr != nil {
            for j in 0 ..< i {
                delete(dst[j], allocator)
            }
            delete(dst, allocator)
            return nil, false
        }
        dst[i] = clone
    }

    return dst, true
}

// Release the owned config and provider definitions, resetting them to empty. Every teardown
// path can call this without knowing how far `start` got.
free_config :: proc(d: ^Daemon) {
    assert(d != nil, "daemon config cleanup needs daemon state")

    delete(d.daemon_version, d.allocator)
    delete(d.device_id, d.allocator)
    delete(d.blob_dir, d.allocator)
    secret.string_destroy(&d.auth_token, d.allocator)
    secret.string_destroy(&d.config_json, d.allocator)
    delete(d.relay_cloud_url, d.allocator)
    delete(d.config_dir, d.allocator)
    for o in d.allowed_origins {
        delete(o, d.allocator)
    }
    delete(d.allowed_origins, d.allocator)
    d.daemon_version = ""
    d.device_id = ""
    d.blob_dir = ""
    d.relay_cloud_url = ""
    d.config_dir = ""
    d.allowed_origins = nil
}

// Register a `Conn` in Awaiting_Initialize, for both the accept path and the relay bridge.
// Nil means the caller refuses the connection; the caller wires the back-reference.
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

// One complete transport message. Only text carries protocol data; binary is a v1 protocol
// error. Ping/Pong/Close are handled in the transport and never reach here.
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
    defer secret.arena_temp_destroy(temp)
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

    case .Catalog_Refresh:
        method_catalog_refresh(conn, req, sa)

    case .Auth_List:
        method_auth_list(conn, req, sa)

    case .Auth_Set_Api_Key:
        method_auth_set_api_key(conn, req, sa)

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

    case .Session_Create:
        method_session_create(conn, req, sa)

    case .Session_Send_Input:
        method_session_send_input(conn, req, sa)

    case .Session_Cancel_Run:
        method_session_cancel_run(conn, req, sa)

    case .Session_Cancel_Input:
        method_session_cancel_input(conn, req, sa)

    case .Session_Patch,
         .Session_Remove,
         .Session_Fork,
         .Session_Compact,
         .Session_Rewind,
         .Session_History,
         .Permission_Decide,
         .Session_Config,
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

// Validate and emit a successful response. The result comes from trusted daemon state, so an
// invalid frame is our bug: assert rather than ship it.
send_result :: proc(conn: ^Conn, id: wire.Request_Id, result: wire.Response_Result, allocator: mem.Allocator) -> bool {
    assert(conn != nil, "result send needs connection state")
    assert(wire.response_result_validate(result) == .None, "daemon built an invalid result frame")

    return send_response(conn, wire.response_ok_build(id, result), allocator)
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

// Serialize and hand to the transport, which copies, so the emitter may be released on return.
// `allocator` is the arena of the lifetime that asked, never a longer-lived one.
send_response :: proc(conn: ^Conn, resp: wire.Response, allocator: mem.Allocator) -> bool {
    assert(conn != nil, "response send needs connection state")
    assert(conn.tx != nil, "response send needs transport state")
    // `initialize` is answered while still Awaiting_Initialize; every other response is Ready.
    assert(conn.state != .Closed, "response sent after protocol close")
    // An assert with no context is expensive to diagnose once it fires in production, and
    // this one only fires on our own bug: name the fault and the frame before dying.
    verr := wire.response_validate(resp)
    if verr != .None {
        response_invalid_report(resp, verr)
    }

    assert(verr == .None, "daemon built an invalid response frame")

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

// Answer `initialize`: workspace page, session and catalog revisions, catalog health, and the
// capabilities this config offers. Profiles and agents are not modeled yet.
send_initialize_result :: proc(conn: ^Conn, id: wire.Request_Id, allocator: mem.Allocator) -> bool {
    assert(conn != nil, "initialize send needs connection state")
    assert(conn.daemon != nil, "initialize send needs daemon state")
    assert(conn.tx != nil, "initialize send needs transport state")
    assert(conn.state == .Awaiting_Initialize, "initialize result sent outside Awaiting_Initialize")

    capabilities: bit_set[wire.Capability]
    if conn.daemon.blob_dir != "" {
        capabilities += {.Blob_Upload}
    }

    // A registry read that fails leaves the snapshot empty rather than refusing the
    // connection: a client rediscovers a workspace from the session rows it lists.
    workspaces, workspaces_err := store.workspace_page(conn.daemon.store, wire.LIMITS.max_workspaces, allocator)
    if workspaces_err != nil {
        log.errorf("daemon: initialize could not read the workspace registry: %v", workspaces_err)
        workspaces = nil
    }

    if len(workspaces) == wire.LIMITS.max_workspaces {
        log.warnf("daemon: the workspace snapshot filled its %d-row bound", wire.LIMITS.max_workspaces)
    }

    result := wire.Initialize_Result {
        protocol = wire.PROTOCOL_VERSION,
        daemon = {version = conn.daemon.daemon_version, server_now_ms = now_ms()},
        capabilities = capabilities,
        workspaces = workspaces,
        profiles = nil,
        agents = nil,
        session_revision = conn.daemon.session_revision,
        cron_revision = 0,
        catalog_rev = conn.daemon.catalog.rev,
        catalog_health = conn.daemon.catalog.health,
    }

    assert(wire.initialize_result_validate(result) == .None, "daemon built an invalid initialize result")
    return send_response(conn, wire.response_ok_build(id, result), allocator)
}

// Name the fault and its frame; one surviving `send_result`'s validation is usually the id.
// Never log the id's bytes: a stale one points into reused frame memory.
@(private = "file")
response_invalid_report :: proc(resp: wire.Response, err: wire.Validation_Error) {
    id: wire.Request_Id
    if answered, is_ok := resp.(wire.Response_Ok); is_ok {
        id = answered.id
    } else {
        id = resp.(wire.Response_Error).id
    }

    log.errorf(
        "daemon: invalid response frame: %v %T id_bytes=%d id_valid=%v",
        err,
        resp,
        len(string(id)),
        wire.req_id_validate(id) == .None,
    )
}

// Close a connection with `CLOSE.protocol_error` for a framing/sequence violation
// on unparseable or out-of-sequence input.
conn_protocol_close :: proc(conn: ^Conn) {
    assert(conn != nil, "protocol close needs connection state")
    conn_close(conn, ws.Close_Code(wire.CLOSE.protocol_error))
}

// Begin a transport close and latch Closed, so further buffered frames are ignored. The
// `Conn` is freed later, from the terminal callback. Idempotent.
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

    case Relay_Client:
        relay_conn_close(t.relay, t.channel)
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

    case Relay_Client:
        relay_conn_close(t.relay, t.channel)
    }
}

// The single write choke point: a local connection writes to the WebSocket server, a relay
// connection seals to the link. Both report `ws.Server_Error`, what the send policy speaks.
conn_send_text :: proc(conn: ^Conn, bytes: []byte) -> ws.Server_Error {
    assert(conn != nil, "send needs connection state")
    assert(conn.tx != nil, "send needs transport state")

    switch t in conn.tx {
    case ^ws.Server_Conn:
        return ws.server_send_text(t, bytes)

    case Relay_Client:
        return relay_conn_send(t.relay, t.channel, bytes)
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

    case Relay_Client:
        return relay_conn_open(t.relay, t.channel)
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

    // Both halves must agree: a connection stays registered until its terminal callback, but a
    // peer close latches the transport out of Open well before that.
    return conn.state != .Closed && conn_tx_open(conn) ? conn : nil
}

// Free the connection's owned state and the `Conn`, severing the transport back-reference so
// nothing resolves it afterwards. Called once, from whichever terminal owns it.
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

    case Relay_Client:
        peer := &t.relay.peers[t.channel]
        assert(peer.conn == conn, "relay cleanup crossed connection ownership")
        peer.conn = nil
    }

    delete(conn.client_name, conn.allocator)
    delete(conn.client_version, conn.allocator)

    free(conn, conn.allocator)
}

// Daemon wall-clock epoch milliseconds, for the `initialize` result's clock.
now_ms :: proc() -> u64 {
    return u64(time.to_unix_nanoseconds(time.now()) / 1_000_000)
}
