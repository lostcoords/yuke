package daemon

import "core:crypto/sha2"
import "core:encoding/hex"
import "core:log"
import "core:nbio"
import "core:os"
import "core:strings"
import "core:sys/posix"
import http "libs:http"
import http_server "libs:http/server"
import ws "libs:websocket"
import wire "src:wire"

// The front door's router types bound to this daemon, so the application type is
// spelled once rather than at every table and callback.
Http_Context :: http_server.Context(Daemon)
Http_Router :: http_server.Router(Daemon)
Http_Middleware :: http_server.Middleware(Daemon)
Http_Route :: http_server.Route(Daemon)

// Pre-match steps: mark, admit, then auth. Route/method disclosure happens only after
// all three, and the mark is set before anything can answer.
@(rodata)
DAEMON_MIDDLEWARE := [?]Http_Middleware {
    {daemon_middleware_mark_private},
    {daemon_middleware_admit},
    {daemon_middleware_auth},
}

// Front-door routes.
@(rodata)
DAEMON_ROUTES := [?]Http_Route {
    {method = "GET", pattern = "/ws", handler = daemon_route_ws},
    {method = "GET", pattern = "/blob/*", handler = daemon_route_blob_get},
    {method = "PUT", pattern = "/blob/*", handler = daemon_route_blob_put},
}

// Build the daemon's HTTP router; `router_listen` validates it and derives the server's
// `user_data` from it, so no callback can be paired with the wrong daemon.
daemon_router_init :: proc(d: ^Daemon) {
    assert(d != nil, "router init needs a daemon")

    // A step inserted ahead of the marker would answer a `?token=` request unmarked, and
    // no test covers a middleware that does not exist yet.
    assert(
        DAEMON_MIDDLEWARE[0].run == daemon_middleware_mark_private,
        "the private marker must precede every middleware that can answer",
    )

    d.router = {
        middleware            = DAEMON_MIDDLEWARE[:],
        routes                = DAEMON_ROUTES[:],
        user_data             = d,
        on_not_found          = daemon_router_not_found,
        on_method_not_allowed = daemon_router_method_not_allowed,
    }

}

// A `?token=` credential rides in the URL. RFC 6750 §2.3 asks this only of 2xx; every
// response the application reaches is marked, since the URL itself is the secret. The
// driver's framing refusals answer before any middleware and go out unmarked.
daemon_middleware_mark_private :: proc(ctx: ^Http_Context) -> http_server.Middleware_Result {
    // A duplicated `token` still carries a credential, so its 400 is marked too.
    if _, lookup := http.query_value(ctx.request.query, "token"); lookup == .Missing {
        return .Continue
    }

    if !http_server.conn_add_header(ctx.conn, "Cache-Control", "private, no-store") {
        return .Stop
    }

    return .Continue
}

// Refuse browser-originated or DNS-rebound requests before any credential check.
daemon_middleware_admit :: proc(ctx: ^Http_Context) -> http_server.Middleware_Result {
    if !http_server.request_is_local(ctx.conn, ctx.request.head) {
        log.warnf(
            "daemon: refused browser-originated or rebound request %s %s",
            ctx.request.head.method,
            ctx.request.path,
        )
        http_server.respond_text(ctx.conn, .Forbidden, "forbidden")

        return .Stop
    }

    return .Continue
}

// Authenticate before route or method disclosure. Missing/invalid → 401; ambiguous → 400.
daemon_middleware_auth :: proc(ctx: ^Http_Context) -> http_server.Middleware_Result {
    d := ctx.user_data

    auth := daemon_authenticate(d, ctx.request.head, ctx.request.query)
    switch auth {
    case .Missing, .Invalid, .Unsupported_Scheme:
        log.warnf("daemon: unauthorized %s %s", ctx.request.head.method, ctx.request.path)
        if !http_server.conn_add_header(ctx.conn, "WWW-Authenticate", daemon_auth_challenge(auth)) {
            return .Stop
        }

        http_server.respond_text(ctx.conn, .Unauthorized, "unauthorized")

        return .Stop

    case .Ambiguous:
        log.warnf("daemon: ambiguous credentials %s %s", ctx.request.head.method, ctx.request.path)
        if !http_server.conn_add_header(ctx.conn, "WWW-Authenticate", daemon_auth_challenge(auth)) {
            return .Stop
        }

        http_server.respond_text(ctx.conn, .Bad_Request, "ambiguous credentials")

        return .Stop

    case .Disabled, .Header, .Query:
    }

    return .Continue
}

// Unmatched path after auth.
daemon_router_not_found :: proc(ctx: ^Http_Context) {
    if daemon_reject_pipelined(ctx) {
        return
    }

    log.debugf("daemon: not found %s", ctx.request.path)
    http_server.respond_text(ctx.conn, .Not_Found, "not found")
}

// Path pattern matched a registered route, but not this method. `ctx.allow` borrows router
// scratch, which `conn_add_header` clones. Pipelining is not refused here: `Allow` says
// more than a 400 would.
daemon_router_method_not_allowed :: proc(ctx: ^Http_Context) {
    if !http_server.conn_add_header(ctx.conn, "Allow", ctx.allow) {
        return
    }

    log.debugf("daemon: method not allowed %s %s", ctx.request.head.method, ctx.request.path)
    http_server.respond_text(ctx.conn, .Method_Not_Allowed, "method not allowed")
}

// Refuse a pipelined follow-up request. `/ws` is exempt: a hijacking route keeps its
// trailing bytes as the peer's eager first frame.
daemon_reject_pipelined :: proc(ctx: ^Http_Context) -> (answered: bool) {
    if !ctx.request.pipelined {
        return false
    }

    log.debug("daemon: rejecting pipelined request")
    http_server.respond_text(ctx.conn, .Bad_Request, "pipelining not supported")

    return true
}

// Validate the upgrade, then transfer the socket to the WebSocket server. `accept_upgrade`
// answers every refusal itself and logs the reason.
daemon_route_ws :: proc(ctx: ^Http_Context) {
    d := ctx.user_data
    assert(len(ctx.params.path_rest) == 0, "websocket route has no path capture")

    ws.accept_upgrade(&d.ws_server, ctx.conn, ctx.request.head, ctx.request.trailing)
}

// Serve one content-addressed blob without reading it into the reactor's heap.
// The HTTP driver stats and sends the same opened handle, so Content-Length and
// the configured limit cannot race a path replacement after open.
daemon_route_blob_get :: proc(ctx: ^Http_Context) {
    d := ctx.user_data
    c := ctx.conn

    if daemon_reject_pipelined(ctx) {
        return
    }

    hash := ctx.params.path_rest
    if d.blob_dir == "" || wire.enforce_fixed_lower_hex(BLOB_HASH_HEX_LEN, hash) != .None {
        daemon_blob_not_found(c)
        return
    }

    path, aerr := strings.concatenate({d.blob_dir, "/", hash}, c.allocator)
    if aerr != nil {
        http_server.abort(c)
        return
    }
    defer delete(path, c.allocator)

    // Reject a symlink at the resolved content-addressed path. The driver repeats
    // type and size validation on the opened handle before emitting its response.
    info, stat_err := os.lstat(path, c.allocator)
    if stat_err != nil {
        daemon_blob_not_found(c)
        return
    }
    defer os.file_info_delete(info, c.allocator)

    if info.type != .Regular {
        daemon_blob_not_found(c)
        return
    }

    file, open_err := nbio.open_sync(path, l = d.loop)
    if open_err != nil {
        daemon_blob_not_found(c)
        return
    }

    // Close the lstat/open TOCTOU: `nbio.open_sync` has no O_NOFOLLOW, so a path swap
    // after the lstat could hand back a symlink target. Confirm the opened handle is
    // the file that was type-checked by comparing serial numbers; `os.File_Info`
    // exposes only the inode, so that is the identity checked.
    opened: posix.stat_t
    if posix.fstat(posix.FD(i32(file)), &opened) != .OK || u128(u64(opened.st_ino)) != info.inode {
        nbio.close(file, l = d.loop)
        daemon_blob_not_found(c)
        return
    }

    // Blob bodies are opaque bytes; the referencing `Media_Source` carries the MIME.
    http_server.respond_file(
        c,
        .Ok,
        "application/octet-stream",
        file,
        i64(wire.LIMITS.max_blob_bytes),
        .Not_Found,
        "unknown blob",
    )

    log.debugf("daemon: serving blob %s", hash)
}

// Respond `404 unknown blob` for a missing or malformed blob request.
daemon_blob_not_found :: proc(c: ^http_server.Conn) {
    assert(c != nil && c.server != nil, "blob failure needs an owned connection")

    http_server.respond_text(c, .Not_Found, "unknown blob")
}

// Stream a blob body to a temp file, verify its digest against the URL hash, and
// atomically publish it. Content-addressed: a digest mismatch is a client lie about
// the address. Idempotent: an already-stored hash short-circuits. The body is
// streamed and bounded by `LIMITS.max_blob_bytes`, never buffered whole.
// No pipelining check: `pipelined` cannot see past a streamed body.
daemon_route_blob_put :: proc(ctx: ^Http_Context) {
    d := ctx.user_data
    c := ctx.conn

    hash := ctx.params.path_rest

    if d.blob_dir == "" || wire.enforce_fixed_lower_hex(BLOB_HASH_HEX_LEN, hash) != .None {
        daemon_blob_not_found(c)
        return
    }

    // Reject an over-cap upload up front on its declared length, before opening a temp
    // file or reading a byte of the body.
    if ctx.request.content_length > i64(wire.LIMITS.max_blob_bytes) {
        http_server.respond_text(c, .Content_Too_Large, "blob too large")

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
        http_server.respond_text(c, .Internal_Server_Error, "cannot store blob")

        return
    }

    up.file = file
    sha2.init_256(&up.sha)

    http_server.receive_body(c, up, daemon_blob_upload_chunk, daemon_blob_upload_end)
}
