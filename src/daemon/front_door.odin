package daemon

import "base:runtime"
import "core:crypto"
import "core:crypto/sha2"
import "core:encoding/hex"
import "core:log"
import "core:mem"
import "core:nbio"
import "core:net"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:time"
import http "libs:http"
import http_server "libs:http/server"
import "libs:offload"
import ws "libs:websocket"
import wire "src:wire"

// WebSocket endpoint; every protocol method rides this one connection.
WS_PATH :: "/ws"

// Content-addressed media endpoint (`wire.Media_Blob.hash`): the hash is the `/*`
// capture, and its grammar is the hex rendering of the digest it verifies.
BLOB_ROUTE_PATTERN :: "/blob/*"
BLOB_HASH_HEX_LEN :: sha2.DIGEST_SIZE_256 * 2

// Blob bodies are opaque bytes; the referencing `Media_Source` carries the MIME.
BLOB_CONTENT_TYPE :: "application/octet-stream"

// Temp-name prefix for an in-flight blob upload under `<blob_dir>`. A per-request
// random nonce follows so concurrent uploads of the same hash never share a temp file.
BLOB_TEMP_PREFIX :: ".upload."

// How stale an upload temp must be before a boot sweep treats it as crash residue
// rather than a slow in-flight upload that merely looks old.
UPLOAD_TEMP_GRACE :: 1 * time.Hour

// The store is private to the daemon: HTTP reads need the bearer token, a local reader
// does not. `core:os` defaults to 0777/0666, so both modes are always passed.
BLOB_DIR_PERMISSIONS :: os.Permissions{.Read_User, .Write_User, .Execute_User}
BLOB_FILE_PERMISSIONS :: os.Permissions{.Read_User, .Write_User}

// Workers publishing uploads. Each one spends its time inside `fsync` rather than
// competing for a core, and concurrent publishes are already bounded by the front door's
// connection cap, so a small count is enough.
BLOB_WORKER_COUNT :: 2

// Pre-match steps: admit, then auth. Route/method disclosure happens only after both.
@(rodata)
DAEMON_MIDDLEWARE := [?]http_server.Middleware{daemon_middleware_admit, daemon_middleware_auth}

// Front-door routes. Handlers receive `Router.user_data` as `^Daemon`.
@(rodata)
DAEMON_ROUTES := [?]http_server.Route {
    {method = "GET", pattern = WS_PATH, handler = daemon_route_ws},
    {method = "GET", pattern = BLOB_ROUTE_PATTERN, handler = daemon_route_blob_get},
    {method = "PUT", pattern = BLOB_ROUTE_PATTERN, handler = daemon_route_blob_put},
}

// Build the daemon's HTTP router; `router_listen` validates it. `user_data` is this daemon; the server's
// `user_data` is the `^Router` stored on the daemon.
daemon_router_init :: proc(d: ^Daemon) {
    assert(d != nil, "router init needs a daemon")

    d.router = {
        middleware            = DAEMON_MIDDLEWARE[:],
        routes                = DAEMON_ROUTES[:],
        user_data             = d,
        on_not_found          = daemon_router_not_found,
        on_method_not_allowed = daemon_router_method_not_allowed,
    }

}

// Refuse browser-originated or DNS-rebound requests before any credential check.
daemon_middleware_admit :: proc(
    c: ^http_server.Conn,
    req: http_server.Request,
    user_data: rawptr,
) -> http_server.Middleware_Result {
    d := (^Daemon)(user_data)
    assert(c != nil && d != nil, "admit middleware needs connection and daemon")

    if !daemon_admit_request(d, req.head) {
        log.warnf("daemon: refused browser-originated or rebound request %s %s", req.head.method, req.path)
        daemon_respond_text(c, .Forbidden, "forbidden", daemon_query_response_headers(req.query))
        return .Stop
    }

    return .Continue
}

// Authenticate before route or method disclosure. Missing/invalid → 401; ambiguous → 400.
daemon_middleware_auth :: proc(
    c: ^http_server.Conn,
    req: http_server.Request,
    user_data: rawptr,
) -> http_server.Middleware_Result {
    d := (^Daemon)(user_data)
    assert(c != nil && d != nil, "auth middleware needs connection and daemon")

    auth, query_credential := daemon_authenticate(d, req.head, req.query)
    switch auth {
    case .Missing, .Invalid, .Unsupported_Scheme:
        log.warnf("daemon: unauthorized %s %s", req.head.method, req.path)
        daemon_respond_text(c, .Unauthorized, "unauthorized", daemon_auth_error_headers(auth, query_credential))
        return .Stop

    case .Ambiguous:
        log.warnf("daemon: ambiguous credentials %s %s", req.head.method, req.path)
        daemon_respond_text(
            c,
            .Bad_Request,
            "ambiguous credentials",
            daemon_auth_error_headers(auth, query_credential),
        )
        return .Stop

    case .Disabled, .Header, .Query:
    }

    return .Continue
}

// Unmatched path after auth.
daemon_router_not_found :: proc(c: ^http_server.Conn, req: http_server.Request, user_data: rawptr) {
    assert(c != nil && (^Daemon)(user_data) != nil, "not-found fallback needs connection and daemon")

    headers := daemon_query_response_headers(req.query)
    if daemon_reject_pipelined(c, req, headers) {
        return
    }

    log.debugf("daemon: not found %s", req.path)
    daemon_respond_text(c, .Not_Found, "not found", headers)
}

// Path pattern matched a registered route, but not this method. `allow` borrows router
// scratch; the response serializes its headers before returning.
daemon_router_method_not_allowed :: proc(
    c: ^http_server.Conn,
    req: http_server.Request,
    allow: string,
    user_data: rawptr,
) {
    assert(c != nil && (^Daemon)(user_data) != nil, "method-not-allowed fallback needs connection and daemon")

    // Cache marker last so the slice length selects it, as in `AUTH_CHALLENGE_HEADERS`.
    headers := [2]http_server.Header{{name = "Allow", value = allow}, {name = "Cache-Control", value = CACHE_PRIVATE}}
    count := 1
    if daemon_query_credential(req.query) {
        count = 2
    }

    log.debugf("daemon: method not allowed %s %s", req.head.method, req.path)
    daemon_respond_text(c, .Method_Not_Allowed, "method not allowed", headers[:count])
}

// Refuse a pipelined follow-up request. `/ws` is exempt: a hijacking route keeps its
// trailing bytes as the peer's eager first frame.
daemon_reject_pipelined :: proc(
    c: ^http_server.Conn,
    req: http_server.Request,
    headers: []http_server.Header,
) -> (
    answered: bool,
) {
    if !req.pipelined {
        return false
    }

    log.debug("daemon: rejecting pipelined request")
    daemon_respond_text(c, .Bad_Request, "pipelining not supported", headers)

    return true
}

// Recover the daemon from a front-door connection and check router ownership.
daemon_from_http :: proc(c: ^http_server.Conn, user_data: rawptr) -> ^Daemon {
    d := (^Daemon)(user_data)
    assert(d != nil && c != nil && c.server != nil, "http route needs daemon and connection")

    r := (^http_server.Router)(c.server.user_data)
    assert(r == &d.router && r.user_data == d, "http route crossed daemon ownership")

    return d
}

// Refuse traffic a browser can be made to send. `Origin` marks a page-driven
// request, which CORS does not block for the WebSocket handshake; a named `Host` is
// the DNS-rebinding shape, which needs a name resolving at the daemon.
daemon_admit_request :: proc(d: ^Daemon, head: http.Request_Head) -> bool {
    assert(d != nil, "admission needs a daemon")
    assert(head.consumed == len(head.bytes), "admission received an inconsistent parsed head")

    if _, lookup := http.request_header(head, "origin"); lookup != .Missing {
        return false
    }

    host, host_lookup := http.request_header(head, "host")
    assert(host_lookup == .One, "head parser admitted a request without exactly one Host")

    return daemon_host_is_literal(d, host)
}

// Whether a `Host` addresses the daemon by IP literal rather than naming it.
// `localhost` is the one name a browser cannot be made to resolve elsewhere.
daemon_host_is_literal :: proc(d: ^Daemon, host: string) -> bool {
    name, bracketed := http.split_host(host) or_return

    // Brackets enclose an IP-literal only, so `[localhost]` gets no name exemption.
    if !bracketed && strings.equal_fold(name, "localhost") {
        return true
    }

    addr := net.parse_address(name)
    if addr == nil {
        return false
    }

    return daemon_address_addresses_us(d, addr)
}

// Whether `addr` is a way this daemon can legitimately be reached: loopback, or the
// address it bound. The unspecified address is a bind wildcard, never a destination —
// and `0.0.0.0` reaches a loopback-bound socket while escaping the browser
// local-network gating that `127.0.0.1` receives.
daemon_address_addresses_us :: proc(d: ^Daemon, addr: net.Address) -> bool {
    assert(d != nil && addr != nil, "address admission needs a daemon and an address")

    switch a in addr {
    case net.IP4_Address:
        if a == net.IP4_Any {
            return false
        }

        return a[0] == 127 || a == d.bind_address

    case net.IP6_Address:
        if a == net.IP6_Any {
            return false
        }

        return a == net.IP6_Loopback || daemon_ip6_maps_loopback(a)
    }

    return false
}

// Whether `a` is an IPv4-mapped loopback literal (`::ffff:127.0.0.1`), which addresses
// loopback by another spelling.
daemon_ip6_maps_loopback :: proc(a: net.IP6_Address) -> bool {
    for i in 0 ..< 5 {
        if a[i] != 0 {
            return false
        }
    }

    return a[5] == 0xffff && u16(a[6]) >> 8 == 127
}


// Validate the upgrade, then transfer the socket to the WebSocket server.
daemon_route_ws :: proc(
    c: ^http_server.Conn,
    req: http_server.Request,
    params: http_server.Params,
    user_data: rawptr,
) {
    d := daemon_from_http(c, user_data)
    assert(len(params.path_rest) == 0, "websocket route has no path capture")

    response_headers := daemon_query_response_headers(req.query)

    upgrade, result := ws.parse_upgrade_request_head(req.head)
    if result != .Ok {
        log.debugf("daemon: bad websocket upgrade: %v", result)
        daemon_respond_text(c, .Bad_Request, "expected a websocket upgrade", response_headers)
        return
    }

    if !ws.server_can_adopt(&d.ws_server) {
        log.warn("daemon: websocket at capacity")
        daemon_respond_text(c, .Service_Unavailable, "at capacity", response_headers)
        return
    }

    socket, loop := http_server.hijack(c)
    if _, err := ws.server_adopt(&d.ws_server, socket, upgrade.key, req.trailing, response_headers); err != .None {
        log.errorf("daemon: server_adopt failed: %v", err)
        nbio.close(socket, l = loop)
    }
}

// Serve one content-addressed blob without reading it into the reactor's heap.
// The HTTP driver stats and sends the same opened handle, so Content-Length and
// the configured limit cannot race a path replacement after open.
daemon_route_blob_get :: proc(
    c: ^http_server.Conn,
    req: http_server.Request,
    params: http_server.Params,
    user_data: rawptr,
) {
    d := daemon_from_http(c, user_data)

    response_headers := daemon_query_response_headers(req.query)
    if daemon_reject_pipelined(c, req, response_headers) {
        return
    }

    hash := params.path_rest
    if d.blob_dir == "" || wire.enforce_fixed_lower_hex(BLOB_HASH_HEX_LEN, hash) != .None {
        daemon_blob_not_found(c, response_headers)
        return
    }

    path, aerr := daemon_blob_final_path(d.blob_dir, hash, c.allocator)
    if aerr != nil {
        http_server.abort(c)
        return
    }
    defer delete(path, c.allocator)

    // Reject a symlink at the resolved content-addressed path. The driver repeats
    // type and size validation on the opened handle before emitting its response.
    info, stat_err := os.lstat(path, c.allocator)
    if stat_err != nil {
        daemon_blob_not_found(c, response_headers)
        return
    }
    defer os.file_info_delete(info, c.allocator)

    if info.type != .Regular {
        daemon_blob_not_found(c, response_headers)
        return
    }

    file, open_err := nbio.open_sync(path, l = d.loop)
    if open_err != nil {
        daemon_blob_not_found(c, response_headers)
        return
    }

    // Close the lstat/open TOCTOU: `nbio.open_sync` has no O_NOFOLLOW, so a path swap
    // after the lstat could hand back a symlink target. Confirm the opened handle is
    // the file that was type-checked by comparing serial numbers; `os.File_Info`
    // exposes only the inode, so that is the identity checked.
    opened: posix.stat_t
    if posix.fstat(posix.FD(i32(file)), &opened) != .OK || u128(u64(opened.st_ino)) != info.inode {
        nbio.close(file, l = d.loop)
        daemon_blob_not_found(c, response_headers)
        return
    }

    response_err := http_server.respond_file(
        c,
        .Ok,
        BLOB_CONTENT_TYPE,
        file,
        i64(wire.LIMITS.max_blob_bytes),
        .Not_Found,
        "unknown blob",
        response_headers,
    )
    if response_err != .None {
        log.errorf("daemon: respond_file failed: %v", response_err)
        nbio.close(file, l = d.loop)
        http_server.abort(c)
        return
    }

    log.debugf("daemon: serving blob %s", hash)
}

// Respond `404 unknown blob` for a missing or malformed blob request.
daemon_blob_not_found :: proc(c: ^http_server.Conn, response_headers: []http_server.Header) {
    assert(c != nil && c.server != nil, "blob failure needs an owned connection")

    daemon_respond_text(c, .Not_Found, "unknown blob", response_headers)
}

// What publishing an upload decided. Recorded on a worker thread, which can neither
// answer the request nor log, and acted on by the completion back on the loop.
Blob_Outcome :: enum {
    // Not yet finalized.
    Pending,

    // Body did not complete; the temp file was deleted and nobody is owed an answer.
    Discarded,

    // Published under its content-addressed name.
    Stored,

    // Another upload of the same content won the race, or it was already stored.
    Already_Present,

    // The streamed digest did not match the digest in the URL.
    Mismatch,

    // A filesystem call failed; see `err`.
    Failed,
}

// Per-request blob-upload state. Owned across the async body receive and the offloaded
// publish, then freed by the completion. Every field a worker thread reads is owned here
// rather than borrowed, so the upload outlives its connection.
Blob_Upload :: struct {
    // Publishes off the reactor; carried here so submitting never allocates.
    task:        offload.Task(Blob_Upload),

    // Owning daemon, for the worker pool.
    daemon:      ^Daemon,

    // Connection to answer, if it is still there when the publish finishes. Zero when
    // the body never completed and no answer is owed.
    ticket:      http_server.Ticket,

    // Whether the body completed, so the temp file should be published rather than
    // discarded.
    publish:     bool,

    // What the publish decided, and the failure behind `.Failed`.
    outcome:     Blob_Outcome,
    err:         os.Error,

    // Allocator backing the owned strings and this struct.
    allocator:   mem.Allocator,

    // Response headers to echo (rodata or nil; carries the private-cache marker).
    headers:     []http_server.Header,

    // Owned final content-addressed path `<blob_dir>/<hash>`.
    final_path:  string,

    // Owned temp path streamed to, then atomically renamed to `final_path`.
    temp_path:   string,

    // Owned copy of the claimed 64-hex digest from the URL, for logging.
    claimed:     string,

    // The same digest decoded once on the loop, so the worker compares raw bytes instead
    // of encoding on a thread that must not allocate.
    claimed_raw: [sha2.DIGEST_SIZE_256]byte,

    // Incremental SHA-256 over the streamed body.
    sha:         sha2.Context_256,

    // Open temp file; nil once closed.
    file:        ^os.File,
}

// Stream a blob body to a temp file, verify its digest against the URL hash, and
// atomically publish it. Content-addressed: a digest mismatch is a client lie about
// the address. Idempotent: an already-stored hash short-circuits. The body is
// streamed and bounded by `LIMITS.max_blob_bytes`, never buffered whole.
daemon_route_blob_put :: proc(
    c: ^http_server.Conn,
    req: http_server.Request,
    params: http_server.Params,
    user_data: rawptr,
) {
    d := daemon_from_http(c, user_data)

    response_headers := daemon_query_response_headers(req.query)
    hash := params.path_rest

    if d.blob_dir == "" || wire.enforce_fixed_lower_hex(BLOB_HASH_HEX_LEN, hash) != .None {
        daemon_blob_not_found(c, response_headers)
        return
    }

    // Reject an over-cap upload up front on its declared length, before opening a temp
    // file or reading a byte of the body.
    if req.content_length > i64(wire.LIMITS.max_blob_bytes) {
        daemon_respond_text(c, .Payload_Too_Large, "blob too large", response_headers)
        return
    }

    up, aerr := new(Blob_Upload, d.allocator)
    if aerr != nil {
        http_server.abort(c)
        return
    }

    up^ = {}
    up.daemon = d
    up.allocator = d.allocator
    up.headers = response_headers

    paths_ok: bool
    up.final_path, up.temp_path, paths_ok = daemon_blob_paths(d.blob_dir, hash, d.allocator)
    if !paths_ok {
        daemon_blob_upload_free(up)
        http_server.abort(c)
        return
    }

    claimed, cerr := strings.clone(hash, d.allocator)
    if cerr != nil {
        daemon_blob_upload_free(up)
        http_server.abort(c)
        return
    }
    up.claimed = claimed

    // Already validated as fixed-length lower hex above, so every pair decodes.
    for i in 0 ..< len(up.claimed_raw) {
        b, ok := hex.decode_sequence(up.claimed[i * 2:][:2])
        assert(ok, "validated blob hash failed to decode")
        up.claimed_raw[i] = b
    }

    file, oerr := os.open(up.temp_path, {.Write, .Create, .Excl}, BLOB_FILE_PERMISSIONS)
    if oerr != nil {
        log.errorf("daemon: blob temp open failed: %v", oerr)
        daemon_blob_upload_free(up)
        daemon_respond_text(c, .Internal_Server_Error, "cannot store blob", response_headers)
        return
    }

    up.file = file
    sha2.init_256(&up.sha)

    http_server.receive_body(c, up, daemon_blob_upload_chunk, daemon_blob_upload_end)
}

// Fold one body chunk into the running digest and the temp file. A write error or
// shortfall aborts; the server then finalizes via the end callback with `ok = false`,
// which deletes the partial temp.
daemon_blob_upload_chunk :: proc(c: ^http_server.Conn, user_data: rawptr, chunk: []byte) -> bool {
    up := (^Blob_Upload)(user_data)
    assert(up != nil && up.file != nil, "blob chunk sink needs an open upload")
    assert(len(up.claimed) == BLOB_HASH_HEX_LEN, "blob upload lost its claimed digest")

    sha2.update(&up.sha, chunk)

    n, werr := os.write(up.file, chunk)
    if werr != nil || n != len(chunk) {
        log.errorf("daemon: blob temp write failed: %v", werr)
        return false
    }

    return true
}

// Hand the finished (or abandoned) upload to a worker. `fsync`, `rename`, and `unlink`
// have no nbio operation, so publishing on the reactor would stall every other
// connection; the whole finalize runs off it instead. The upload owns every path the
// worker reads, so it outlives this connection.
daemon_blob_upload_end :: proc(c: ^http_server.Conn, user_data: rawptr, ok: bool) {
    up := (^Blob_Upload)(user_data)
    assert(up != nil, "blob end callback needs upload state")
    assert(up.daemon != nil, "blob upload lost its daemon")
    assert(up.outcome == .Pending, "blob upload finalized twice")
    assert(up.file != nil, "blob upload reached its end callback with no temp file")

    up.publish = ok

    // Only a completed body has anyone to answer: `ok == false` also arrives from
    // connection teardown, where there is no longer a request in flight.
    if ok {
        up.ticket = http_server.conn_ticket(c)
        http_server.defer_response(c)
    }

    offload.submit(&up.daemon.blobs, &up.task, up, daemon_blob_publish, daemon_blob_published)
}

// Worker thread. Touches only `up`, every path of which is an owned clone. Records an
// outcome rather than answering or logging: there may be no connection left to answer,
// and the logger belongs to the loop thread.
daemon_blob_publish :: proc(up: ^Blob_Upload) {
    assert(up.file != nil, "publish needs the temp file still open")
    assert(up.outcome == .Pending, "publish ran on a finalized upload")

    up.outcome = daemon_blob_finalize(up)
    assert(up.file == nil, "finalize left the temp file open")

    // The temp survives only when the rename turned it into the blob; every other outcome
    // leaves nothing behind for the boot sweep to find.
    if up.outcome != .Stored {
        os.remove(up.temp_path)
    }
}

// Close the temp file and decide the upload's fate, without touching the temp path: the
// single caller removes it for every outcome but `.Stored`. Sets `err` on a failure.
daemon_blob_finalize :: proc(up: ^Blob_Upload) -> Blob_Outcome {
    // Flush before the rename publishes a content-addressed name over bytes nothing
    // re-verifies on read. Narrows the power-loss window rather than closing it: darwin
    // needs `F_FULLFSYNC` for a media barrier. Directory durability is not forced.
    if up.publish {
        up.err = os.sync(up.file)
    }

    os.close(up.file)
    up.file = nil

    if !up.publish {
        return .Discarded
    }

    if up.err != nil {
        return .Failed
    }

    digest: [sha2.DIGEST_SIZE_256]byte
    sha2.final(&up.sha, digest[:])

    if digest != up.claimed_raw {
        return .Mismatch
    }

    // Content-addressed and idempotent: an already-present store makes the upload a
    // no-op, so drop the temp and report success without replacing the file.
    if os.exists(up.final_path) {
        return .Already_Present
    }

    if rerr := os.rename(up.temp_path, up.final_path); rerr != nil {
        // A concurrent upload of the same content may have published it between the
        // existence check and the rename; a now-present target is still success.
        if os.exists(up.final_path) {
            return .Already_Present
        }

        up.err = rerr
        return .Failed
    }

    return .Stored
}

// Loop thread. Answers the request when the connection is still there, and frees the
// upload either way: a publish that completed is correct whether or not anyone is left
// to hear about it. A mismatch, an already-present store, and a fresh store map to 400,
// 200, and 201. No bodies.
daemon_blob_published :: proc(up: ^Blob_Upload) {
    assert(up.outcome != .Pending, "publish completed without an outcome")
    assert(up.file == nil, "publish left the temp file open")
    defer daemon_blob_upload_free(up)

    switch up.outcome {
    case .Stored:
        log.debugf("daemon: stored blob %s", up.claimed)

    case .Failed:
        log.errorf("daemon: blob publish failed: %v", up.err)

    case .Pending, .Discarded, .Already_Present, .Mismatch:
    }

    c := http_server.conn_resolve(&up.daemon.front_door, up.ticket)
    if c == nil {
        return
    }

    switch up.outcome {
    case .Stored:
        daemon_respond_text(c, .Created, "", up.headers)

    case .Already_Present:
        daemon_respond_text(c, .Ok, "", up.headers)

    case .Mismatch:
        daemon_respond_text(c, .Bad_Request, "hash mismatch", up.headers)

    case .Failed:
        daemon_respond_text(c, .Internal_Server_Error, "cannot store blob", up.headers)

    case .Pending, .Discarded:
        assert(false, "an upload with no answer owed resolved a connection")
    }
}

// Owned `<blob_dir>/<hash>` path: the content-addressed store layout shared by the
// GET and PUT routes and the boot-time sweep.
daemon_blob_final_path :: proc(
    blob_dir: string,
    hash: string,
    allocator: mem.Allocator,
) -> (
    string,
    mem.Allocator_Error,
) {
    assert(len(blob_dir) > 0 && len(hash) == 64, "blob path needs a directory and a 64-hex name")
    return strings.concatenate({blob_dir, "/", hash}, allocator)
}

// Build the owned final and temp paths for `hash` under `blob_dir`.
daemon_blob_paths :: proc(
    blob_dir: string,
    hash: string,
    allocator: mem.Allocator,
) -> (
    final_path: string,
    temp_path: string,
    ok: bool,
) {
    assert(len(blob_dir) > 0 && len(hash) == 64, "blob paths need a directory and a 64-hex name")

    nonce_raw: [8]byte
    crypto.rand_bytes(nonce_raw[:])
    nonce, herr := hex.encode(nonce_raw[:], allocator)
    if herr != nil {
        return "", "", false
    }
    defer delete(nonce, allocator)

    ferr: mem.Allocator_Error
    final_path, ferr = daemon_blob_final_path(blob_dir, hash, allocator)
    if ferr != nil {
        return "", "", false
    }

    terr: mem.Allocator_Error
    temp_path, terr = strings.concatenate({blob_dir, "/", BLOB_TEMP_PREFIX, hash, ".", string(nonce)}, allocator)
    if terr != nil {
        delete(final_path, allocator)
        return "", "", false
    }

    return final_path, temp_path, true
}

// `make_directory_all` leaves an existing directory's mode alone, so a store predating
// `BLOB_DIR_PERMISSIONS` stays exposed. Reported, not tightened: narrowing an
// operator's directory is theirs to decide.
daemon_warn_exposed_blob_dir :: proc(blob_dir: string, allocator := context.allocator) {
    assert(len(blob_dir) > 0, "blob dir exposure check needs a configured directory")

    info, err := os.stat(blob_dir, allocator)
    if err != nil {
        return
    }
    defer os.file_info_delete(info, allocator)

    if exposed := info.mode & ~BLOB_DIR_PERMISSIONS; exposed != {} {
        log.warnf(
            "daemon: blob dir %s is reachable beyond its owner (%v); stored blobs bypass token auth on disk",
            blob_dir,
            exposed,
        )
    }
}

// Delete upload temp files (`.upload.<hash>.<nonce>`) under `blob_dir` older than
// `cutoff`: published blobs and other non-temp entries are never matched, and a temp
// at or after `cutoff` is left alone (an in-flight upload's temp is always fresh).
//
// Temp residue only accrues on a crash — a clean shutdown always renames or removes
// its temp — so a boot-only pass covers the threat model. Best-effort: an unreadable
// directory is not an error.
daemon_blob_sweep_temps :: proc(blob_dir: string, cutoff: time.Time) -> (removed: int) {
    assert(len(blob_dir) > 0, "blob temp sweep needs a configured blob directory")

    // The listing covers every entry in the store, so release it rather than retaining
    // it in the temp arena for the process lifetime.
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

    infos, err := os.read_all_directory_by_path(blob_dir, context.temp_allocator)
    if err != nil {
        return 0
    }

    for info in infos {
        if !strings.has_prefix(info.name, BLOB_TEMP_PREFIX) {
            continue
        }

        if time.diff(info.modification_time, cutoff) <= 0 {
            continue
        }

        path, aerr := strings.concatenate({blob_dir, "/", info.name}, context.temp_allocator)
        if aerr != nil {
            continue
        }

        if os.remove(path) == nil {
            removed += 1
        }
    }

    return removed
}

// Release the upload's owned strings and the `Blob_Upload`; the temp file must
// already be closed.
daemon_blob_upload_free :: proc(up: ^Blob_Upload) {
    assert(up != nil, "blob upload free needs state")
    assert(up.file == nil, "freeing an upload with its temp file still open")

    if len(up.final_path) > 0 {
        delete(up.final_path, up.allocator)
    }

    if len(up.temp_path) > 0 {
        delete(up.temp_path, up.allocator)
    }

    if len(up.claimed) > 0 {
        delete(up.claimed, up.allocator)
    }

    free(up, up.allocator)
}

// Respond with a short text body, aborting the connection if the write fails.
// `response_headers` is deliberately not defaulted: every token-bearing response must
// carry the cache-private marker, and a default let one path silently skip it.
daemon_respond_text :: proc(
    c: ^http_server.Conn,
    status: http.Status,
    text: string,
    response_headers: []http_server.Header,
) {
    assert(c != nil && c.server != nil, "daemon response needs an owned connection")
    assert(http_server.conn_can_respond(c), "daemon response began after the connection was answered")

    if http_server.respond_text(c, status, text, response_headers) != .None {
        http_server.abort(c)
    }
}
