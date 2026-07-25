package daemon

import "core:crypto"
import "core:crypto/sha2"
import "core:encoding/hex"
import "core:log"
import "core:mem"
import "core:nbio"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:time"
import http "libs:http"
import http_server "libs:http/server"
import ws "libs:websocket"
import wire "src:wire"

// WebSocket endpoint; every protocol method rides this one connection.
WS_PATH :: "/ws"

// Content-addressed media endpoint (`wire.Media_Blob.hash`).
BLOB_PREFIX :: "/blob/"

// Blob bodies are opaque bytes; the referencing `Media_Source` carries the MIME.
BLOB_CONTENT_TYPE :: "application/octet-stream"

// Temp-name prefix for an in-flight blob upload under `<blob_dir>`. A per-request
// random nonce follows so concurrent uploads of the same hash never share a temp file.
BLOB_TEMP_PREFIX :: ".upload."

// How stale an upload temp must be before a boot sweep treats it as crash residue
// rather than a slow in-flight upload that merely looks old.
UPLOAD_TEMP_GRACE :: 1 * time.Hour

// Authenticate a syntactically valid request before method or route disclosure,
// then dispatch the two supported GET routes.
daemon_on_request :: proc(c: ^http_server.Conn, req: http_server.Request) {
    assert(c != nil && c.server != nil, "front door request needs an owned connection")
    assert(req.head.consumed == len(req.head.bytes), "front door received an inconsistent parsed head")

    d := (^Daemon)(c.server.user_data)
    assert(d != nil, "front door request has no daemon")

    path, query := http.split_target(req.head.target)
    auth, query_credential := daemon_authenticate(d, req.head, query)
    switch auth {
    case .Missing, .Invalid:
        log.warnf("daemon: unauthorized %s %s", req.head.method, path)
        daemon_respond_text(c, .Unauthorized, "unauthorized", daemon_auth_error_headers(query_credential))
        return

    case .Ambiguous:
        log.warnf("daemon: ambiguous credentials %s %s", req.head.method, path)
        daemon_respond_text(c, .Bad_Request, "ambiguous credentials", daemon_response_headers(query_credential))
        return

    case .Disabled, .Header, .Query:
    }

    response_headers := daemon_response_headers(query_credential)
    is_blob := strings.has_prefix(path, BLOB_PREFIX)
    method := req.head.method

    // GET everywhere; PUT only on `/blob` (upload). Every other method on a known route
    // stays rejected — the method is disclosed only after authentication.
    if method != "GET" && !(method == "PUT" && is_blob) {
        log.debugf("daemon: method not allowed %s %s", method, path)
        daemon_respond_text(c, .Method_Not_Allowed, "method not allowed", response_headers)
        return
    }

    switch {
    case path == WS_PATH:
        daemon_route_ws(d, c, req, response_headers)

    case is_blob:
        hash := path[len(BLOB_PREFIX):]
        if method == "PUT" {
            daemon_route_blob_put(d, c, req, hash, response_headers)
        } else if len(req.trailing) > 0 {
            log.debug("daemon: rejecting pipelined request")
            daemon_respond_text(c, .Bad_Request, "pipelining not supported", response_headers)
        } else {
            daemon_route_blob(d, c, hash, response_headers)
        }

    case len(req.trailing) > 0:
        log.debug("daemon: rejecting pipelined request")
        daemon_respond_text(c, .Bad_Request, "pipelining not supported", response_headers)

    case:
        log.debugf("daemon: not found %s", path)
        daemon_respond_text(c, .Not_Found, "not found", response_headers)
    }
}

// Validate the upgrade, then transfer the socket to the WebSocket server.
daemon_route_ws :: proc(
    d: ^Daemon,
    c: ^http_server.Conn,
    req: http_server.Request,
    response_headers: []http_server.Header,
) {
    assert(d != nil && c != nil, "websocket route needs daemon state and a connection")
    assert(c.server.user_data == d, "websocket route crossed daemon ownership")

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
daemon_route_blob :: proc(d: ^Daemon, c: ^http_server.Conn, hash: string, response_headers: []http_server.Header) {
    assert(d != nil && c != nil, "blob route needs daemon state and a connection")
    assert(c.server.user_data == d, "blob route crossed daemon ownership")

    if d.blob_dir == "" || wire.enforce_fixed_lower_hex(64, hash) != .None {
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

daemon_blob_not_found :: proc(c: ^http_server.Conn, response_headers: []http_server.Header) {
    assert(c != nil && c.server != nil, "blob failure needs an owned connection")

    daemon_respond_text(c, .Not_Found, "unknown blob", response_headers)
}

// Per-request blob-upload state, owned across the async body receive and freed in
// `daemon_blob_upload_end`. The connection outlives it; the daemon allocator backs
// every owned string.
Blob_Upload :: struct {
    // Allocator backing the owned strings and this struct.
    allocator:  mem.Allocator,

    // Response headers to echo (rodata or nil; carries the private-cache marker).
    headers:    []http_server.Header,

    // Owned final content-addressed path `<blob_dir>/<hash>`.
    final_path: string,

    // Owned temp path streamed to, then atomically renamed to `final_path`.
    temp_path:  string,

    // Owned copy of the claimed 64-hex digest from the URL.
    claimed:    string,

    // Incremental SHA-256 over the streamed body.
    sha:        sha2.Context_256,

    // Open temp file; nil once closed.
    file:       ^os.File,
}

// Stream a client-supplied blob to a temp file, hashing as it writes, then verify the
// digest against the URL hash and atomically publish it. Content-addressed: a mismatch
// means the client lied about the address. Idempotent: an already-stored hash short-
// circuits. Auth (already done) and the 64-lowercase-hex path check mirror GET /blob;
// the body is bounded by `LIMITS.max_blob_bytes` and streamed, never buffered whole.
daemon_route_blob_put :: proc(
    d: ^Daemon,
    c: ^http_server.Conn,
    req: http_server.Request,
    hash: string,
    response_headers: []http_server.Header,
) {
    assert(d != nil && c != nil, "blob upload needs daemon state and a connection")
    assert(c.server.user_data == d, "blob upload crossed daemon ownership")

    if d.blob_dir == "" || wire.enforce_fixed_lower_hex(64, hash) != .None {
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

    file, oerr := os.open(up.temp_path, {.Write, .Create, .Excl}, os.Permissions_Read_Write_All)
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

// Sink one body chunk: fold it into the running digest and append it to the temp file.
// A write error or shortfall aborts the transfer; the server then finalizes and calls
// the end callback with `ok = false`, which deletes the partial temp file.
daemon_blob_upload_chunk :: proc(c: ^http_server.Conn, user_data: rawptr, chunk: []byte) -> bool {
    up := (^Blob_Upload)(user_data)
    assert(up != nil && up.file != nil, "blob chunk sink needs an open upload")
    assert(len(up.claimed) == 64, "blob upload lost its claimed digest")

    sha2.update(&up.sha, chunk)

    n, werr := os.write(up.file, chunk)
    if werr != nil || n != len(chunk) {
        log.errorf("daemon: blob temp write failed: %v", werr)
        return false
    }

    return true
}

// Finalize (success) or discard (failure) the upload, freeing its state either way. On
// success the streamed digest is checked against the claimed URL hash: a mismatch, a
// pre-existing store, and a fresh store map to 400, 200, and 201. On failure — short
// body, reset, timeout, or a sink abort — the partial temp file is deleted. No bodies.
daemon_blob_upload_end :: proc(c: ^http_server.Conn, user_data: rawptr, ok: bool) {
    up := (^Blob_Upload)(user_data)
    assert(up != nil, "blob end callback needs upload state")

    if up.file != nil {
        os.close(up.file)
        up.file = nil
    }

    defer daemon_blob_upload_free(up)

    if !ok {
        os.remove(up.temp_path)
        return
    }

    assert(len(up.claimed) == 64, "blob upload lost its claimed digest")

    digest: [sha2.DIGEST_SIZE_256]byte
    sha2.final(&up.sha, digest[:])

    encoded, herr := hex.encode(digest[:], up.allocator)
    if herr != nil {
        os.remove(up.temp_path)
        http_server.abort(c)
        return
    }
    defer delete(encoded, up.allocator)

    if string(encoded) != up.claimed {
        os.remove(up.temp_path)
        daemon_respond_text(c, .Bad_Request, "hash mismatch", up.headers)
        return
    }

    // Content-addressed and idempotent: an already-present store makes the upload a
    // no-op, so drop the temp and report success without replacing the file.
    if os.exists(up.final_path) {
        os.remove(up.temp_path)
        daemon_respond_text(c, .Ok, "", up.headers)
        return
    }

    if rerr := os.rename(up.temp_path, up.final_path); rerr != nil {
        // A concurrent upload of the same content may have published it between the
        // existence check and the rename; a now-present target is still success.
        os.remove(up.temp_path)
        if os.exists(up.final_path) {
            daemon_respond_text(c, .Ok, "", up.headers)
        } else {
            log.errorf("daemon: blob publish rename failed: %v", rerr)
            daemon_respond_text(c, .Internal_Server_Error, "cannot store blob", up.headers)
        }

        return
    }

    log.debugf("daemon: stored blob %s", up.claimed)
    daemon_respond_text(c, .Created, "", up.headers)
}

// Owned `<blob_dir>/<hash>` path: the content-addressed store layout shared by the
// GET and PUT routes (and the engine-phase sweep; see docs/blob-gc-design.md).
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

// Build the owned final and temp paths for `hash` under `blob_dir`. The temp name
// carries a random nonce so two concurrent uploads of the same hash never collide.
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

// Delete upload temp files (`.upload.<hash>.<nonce>`) under `blob_dir` older than
// `cutoff`. Published blobs (64-hex names) and any other non-temp entry are never
// matched, and a temp at or after `cutoff` is left alone — an in-flight upload's
// temp is always fresh. Never recurses into subdirectories.
//
// Temp residue only accrues on a crash: a clean shutdown always renames or removes
// its temp (`daemon_blob_upload_end`), and a crash implies the restart that runs
// this sweep. A boot-only pass therefore covers the threat model until the SQLite
// engine phase adds a periodic full sweep (docs/blob-gc-design.md). A missing or
// unreadable directory is not an error: startup must not fail because the blob
// directory is empty or not yet created.
blob_sweep_temps :: proc(blob_dir: string, cutoff: time.Time) -> (removed: int) {
    assert(len(blob_dir) > 0, "blob temp sweep needs a configured blob directory")

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

// Free the upload's owned strings and the struct. The temp file must already be closed.
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

daemon_respond_text :: proc(
    c: ^http_server.Conn,
    status: http.Status,
    text: string,
    response_headers: []http_server.Header = nil,
) {
    assert(c != nil && c.server != nil, "daemon response needs an owned connection")
    assert(c.state == .Reading, "daemon response began after the connection was answered")

    if http_server.respond_text(c, status, text, response_headers) != .None {
        http_server.abort(c)
    }
}
