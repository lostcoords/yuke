package daemon

import "core:crypto/sha2"
import "core:encoding/hex"
import "core:encoding/json"
import "core:log"
import "core:nbio"
import "core:os"
import "core:strings"
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
FRONT_DOOR_MIDDLEWARE := [?]Http_Middleware{{middleware_mark_private}, {middleware_admit}, {middleware_auth}}

// Front-door routes.
@(rodata)
FRONT_DOOR_ROUTES := [?]Http_Route {
    {method = "GET", pattern = "/ws", handler = route_ws},
    {method = "GET", pattern = "/identity", handler = route_identity},
    {method = "OPTIONS", pattern = "/identity", handler = route_identity_preflight},
    {method = "GET", pattern = "/blob/*", handler = route_blob_get},
    {method = "HEAD", pattern = "/blob/*", handler = route_blob_get},
    {method = "PUT", pattern = "/blob/*", handler = route_blob_put},
}

// Build the daemon's HTTP router; `router_listen` validates it and derives the server's
// `user_data` from it, so no callback can be paired with the wrong daemon.
router_init :: proc(d: ^Daemon) {
    assert(d != nil, "router init needs a daemon")

    // A step inserted ahead of the marker would answer a `?token=` request unmarked, and
    // no test covers a middleware that does not exist yet.
    assert(
        FRONT_DOOR_MIDDLEWARE[0].run == middleware_mark_private,
        "the private marker must precede every middleware that can answer",
    )

    d.router = {
        middleware            = FRONT_DOOR_MIDDLEWARE[:],
        routes                = FRONT_DOOR_ROUTES[:],
        user_data             = d,
        on_not_found          = router_not_found,
        on_method_not_allowed = router_method_not_allowed,
    }

}

// A `?token=` credential rides in the URL, so every response the application reaches is
// marked private, not just 2xx as RFC 6750 §2.3 asks; framing refusals answer unmarked.
middleware_mark_private :: proc(ctx: ^Http_Context) -> http_server.Middleware_Result {
    // A duplicated `token` still carries a credential, so its 400 is marked too.
    if _, lookup := http.query_value(ctx.request.query, "token"); lookup == .Missing {
        return .Continue
    }

    if !http_server.conn_add_header(ctx.conn, "Cache-Control", "private, no-store") {
        return .Stop
    }

    return .Continue
}

// Refuse browser-originated or DNS-rebound requests before any credential check. An `allowedOrigins`
// entry exempts a matching `Origin`, admitting it past both the origin and Host checks.
middleware_admit :: proc(ctx: ^Http_Context) -> http_server.Middleware_Result {
    d := ctx.user_data

    // Exact-match against operator config; a duplicated Origin falls through to the refusal.
    if origin, lookup := http.request_header(ctx.request.head, "origin"); lookup == .One {
        if origin_allowed(d.allowed_origins, origin) {
            return .Continue
        }
    }

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

// The official web client's origin, admitted by default so a stock daemon serves it without
// per-install configuration. Other origins must be listed in `allowedOrigins`.
OFFICIAL_ORIGIN :: "https://client.yuke.sh"

// Whether `origin` is the official client or an operator-configured allowlist entry.
origin_allowed :: proc(allowed: []string, origin: string) -> bool {
    // @Todo(xyaman): Require pairing before an allowed browser origin can control
    // an otherwise unauthenticated loopback daemon.
    if origin == OFFICIAL_ORIGIN {
        return true
    }
    for entry in allowed {
        if entry == origin {
            return true
        }
    }
    return false
}

// Authenticate before route or method disclosure. Missing/invalid → 401; ambiguous → 400.
middleware_auth :: proc(ctx: ^Http_Context) -> http_server.Middleware_Result {
    // /identity is a public discovery endpoint: no secret, and it must answer before a client holds
    // any credential, so it skips authentication. Admission still gates its origin.
    if ctx.request.path == "/identity" {
        return .Continue
    }

    d := ctx.user_data

    auth := authenticate(d, ctx.request.head, ctx.request.query)
    if auth == .Allowed {
        return .Continue
    }

    status := http.Status.Unauthorized
    message := "unauthorized"
    if auth == .Ambiguous {
        status = .Bad_Request
        message = "ambiguous credentials"
        log.warnf("daemon: ambiguous credentials %s %s", ctx.request.head.method, ctx.request.path)
    } else {
        log.warnf("daemon: unauthorized %s %s", ctx.request.head.method, ctx.request.path)
    }

    if !http_server.conn_add_header(ctx.conn, "WWW-Authenticate", auth_challenge(auth)) {
        return .Stop
    }

    http_server.respond_text(ctx.conn, status, message)
    return .Stop
}

// Unmatched path after auth.
router_not_found :: proc(ctx: ^Http_Context) {
    if reject_pipelined(ctx) {
        return
    }

    log.debugf("daemon: not found %s", ctx.request.path)
    http_server.respond_text(ctx.conn, .Not_Found, "not found")
}

// Path pattern matched a registered route, but not this method. `ctx.allow` borrows router
// scratch, which `conn_add_header` clones. Pipelining isn't refused: `Allow` says more.
router_method_not_allowed :: proc(ctx: ^Http_Context) {
    if !http_server.conn_add_header(ctx.conn, "Allow", ctx.allow) {
        return
    }

    log.debugf("daemon: method not allowed %s %s", ctx.request.head.method, ctx.request.path)
    http_server.respond_text(ctx.conn, .Method_Not_Allowed, "method not allowed")
}

// Refuse a pipelined follow-up request. `/ws` is exempt: a hijacking route keeps its
// trailing bytes as the peer's eager first frame.
reject_pipelined :: proc(ctx: ^Http_Context) -> (answered: bool) {
    if !ctx.request.pipelined {
        return false
    }

    log.debug("daemon: rejecting pipelined request")
    http_server.respond_text(ctx.conn, .Bad_Request, "pipelining not supported")
    return true
}

// Validate the upgrade, then transfer the socket to the WebSocket server. `accept_upgrade`
// answers every refusal itself and logs the reason.
route_ws :: proc(ctx: ^Http_Context) {
    d := ctx.user_data
    assert(len(ctx.params.path_rest) == 0, "websocket route has no path capture")
    ws.accept_upgrade(&d.ws_server, ctx.conn, ctx.request.head, ctx.request.trailing)
}

// The /identity response: service name, build version, and the enrolled device id when present.
// No secret; `device_id` is already visible to a signed-in browser via /browser/devices.
Identity_Info :: struct {
    service:   string `json:"service"`,
    version:   string `json:"version"`,
    device_id: string `json:"device_id,omitempty"`,
}

// Public discovery endpoint a browser probes to detect a local daemon before any WebSocket upgrade.
// No secret, answers without a credential (admission still gates the origin); CORS lets it be read.
route_identity :: proc(ctx: ^Http_Context) {
    d := ctx.user_data
    identity_cors(ctx)

    info := Identity_Info {
        service   = "yuke",
        version   = d.daemon_version,
        device_id = d.device_id,
    }

    body, merr := json.marshal(info, {}, context.temp_allocator)
    if merr != nil {
        http_server.respond_text(ctx.conn, .Internal_Server_Error, "identity encode failed")
        return
    }

    http_server.respond(ctx.conn, .Ok, "application/json", body)
}

// Answer the CORS + Private Network Access preflight for /identity: Chrome sends this `OPTIONS`
// before a public page may reach a loopback address.
route_identity_preflight :: proc(ctx: ^Http_Context) {
    identity_cors(ctx)
    if !http_server.conn_add_header(ctx.conn, "Access-Control-Allow-Methods", "GET, OPTIONS") {
        return
    }
    if !http_server.conn_add_header(ctx.conn, "Access-Control-Allow-Private-Network", "true") {
        return
    }
    http_server.respond_text(ctx.conn, .No_Content, "")
}

// Echo the request Origin into the CORS allow headers so an admitted browser can read /identity.
// Admission has already vetted the origin, so this reflects an allowed value, not an arbitrary one.
identity_cors :: proc(ctx: ^Http_Context) {
    origin, lookup := http.request_header(ctx.request.head, "origin")
    if lookup != .One {
        return
    }
    _ = http_server.conn_add_header(ctx.conn, "Access-Control-Allow-Origin", origin)
    _ = http_server.conn_add_header(ctx.conn, "Vary", "Origin")
}

// Serve one content-addressed blob without reading it into the reactor's heap.
// The HTTP driver stats and sends the same opened handle, so Content-Length and
// the configured limit cannot race a path replacement after open.
route_blob_get :: proc(ctx: ^Http_Context) {
    d := ctx.user_data
    c := ctx.conn

    if reject_pipelined(ctx) {
        return
    }

    hash := ctx.params.path_rest
    if d.blob_dir == "" || wire.enforce_fixed_lower_hex(BLOB_HASH_HEX_LEN, hash) != .None {
        blob_not_found(c)
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
        blob_not_found(c)
        return
    }
    defer os.file_info_delete(info, c.allocator)

    if info.type != .Regular {
        blob_not_found(c)
        return
    }

    file, open_err := nbio.open_sync(path, l = d.loop)
    if open_err != nil {
        blob_not_found(c)
        return
    }

    // Closes the lstat/open TOCTOU: `nbio.open_sync` has no O_NOFOLLOW, so a path swap
    // could hand back a symlink target. Confirm the opened handle still refers to the file
    // we validated before serving its bytes.
    if !blob_handle_matches(file, info) {
        nbio.close(file, l = d.loop)
        blob_not_found(c)
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
blob_not_found :: proc(c: ^http_server.Conn) {
    assert(c != nil && c.server != nil, "blob failure needs an owned connection")

    http_server.respond_text(c, .Not_Found, "unknown blob")
}

// Stream a blob body to a temp file, verify its digest against the URL hash, and
// atomically publish it. Bounded by `LIMITS.max_blob_bytes`; skips `reject_pipelined`,
// which can't see past a streamed body.
route_blob_put :: proc(ctx: ^Http_Context) {
    d := ctx.user_data
    c := ctx.conn

    hash := ctx.params.path_rest

    if d.blob_dir == "" || wire.enforce_fixed_lower_hex(BLOB_HASH_HEX_LEN, hash) != .None {
        blob_not_found(c)
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

    if perr := blob_paths_build(up, d.blob_dir, hash); perr != nil {
        blob_upload_free(up)
        http_server.abort(c)
        return
    }

    copy(up.claimed[:], hash)

    // Already validated as fixed-length lower hex above, so every pair decodes.
    for i in 0 ..< len(up.claimed_raw) {
        b, ok := hex.decode_sequence(string(up.claimed[i * 2:][:2]))
        assert(ok, "validated blob hash failed to decode")
        up.claimed_raw[i] = b
    }

    file, oerr := os.open(up.temp_path, {.Write, .Create, .Excl}, BLOB_FILE_PERMISSIONS)
    if oerr != nil {
        log.errorf("daemon: blob temp open failed: %v", oerr)
        blob_upload_free(up)
        http_server.respond_text(c, .Internal_Server_Error, "cannot store blob")

        return
    }

    up.file = file
    sha2.init_256(&up.sha)

    http_server.receive_body(c, up, blob_upload_chunk, blob_upload_end)
}
