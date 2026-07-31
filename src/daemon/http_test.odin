package daemon

import "core:crypto"
import "core:encoding/base64"
import "core:fmt"
import "core:nbio"
import "core:net"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import ws "libs:websocket"
import client "src:client"
import wire "src:wire"

// --- Front-door route tests ---------------------------------------------------
//
// These drive raw HTTP against the daemon's `/ws` and `/blob/<hash>` routes with a
// blocking peer on a worker thread while the daemon drives the loop on the main
// thread. Helpers bind an OS-assigned ephemeral port (port 0).

// A 64-hex blob name, and the bytes stored under it.
BLOB_HASH :: "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
BLOB_BODY :: "blob bytes"

// `BLOB_HASH` is the real SHA-256 of these bytes, so an upload of `UPLOAD_BODY` to
// `PUT /blob/BLOB_HASH` verifies; any other body is a content-address mismatch.
UPLOAD_BODY :: "hello"

// A blocking HTTP peer: send one request, read until the daemon closes.
Http_Peer :: struct {
    // Port to connect to.
    port:     int,

    // Request bytes to write (borrowed; read-only across the thread).
    request:  string,

    // Everything read back before the close.
    response: [4096]byte,
    length:   int,

    // The peer ran its script to completion.
    ok:       bool,
}

daemon_http_peer :: proc(p: ^Http_Peer) {
    sock, ok := daemon_raw_dial(p.port)
    if !ok {
        return
    }
    defer net.close(sock)

    if _, serr := net.send_tcp(sock, transmute([]byte)p.request); serr != nil {
        return
    }

    for p.length < len(p.response) {
        n, rerr := net.recv_tcp(sock, p.response[p.length:])
        if rerr != nil || n == 0 {
            break
        }

        p.length += n

        // A 101 keeps the socket open for frames, so stop at its head; every other
        // answer is followed by a close, and reading on to EOF collects the body.
        got := string(p.response[:p.length])
        if strings.has_prefix(got, "HTTP/1.1 101") && strings.contains(got, "\r\n\r\n") {
            break
        }
    }

    sync.atomic_store(&p.ok, true)
}

// Serve one raw HTTP request against a daemon started with `options`, returning
// what the peer read back. Binds an OS-assigned ephemeral port.
daemon_run_http :: proc(t: ^testing.T, request: string, options: Daemon_Options = {}) -> string {
    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    opts := options
    opts.host = "127.0.0.1"
    opts.port = 0

    d: Daemon
    testing.expect_value(t, daemon_start(&d, loop, opts), Daemon_Error.None)

    p := Http_Peer {
        port    = daemon_bound_port(&d),
        request = request,
    }
    peer := thread.create_and_start_with_poly_data(&p, daemon_http_peer)
    defer {
        thread.join(peer)
        thread.destroy(peer)
    }

    for _ in 0 ..< 2000 {
        nbio.tick(time.Millisecond)
        if sync.atomic_load(&p.ok) {
            break
        }
    }

    thread.join(peer)
    daemon_test_teardown(&d)

    return strings.clone(string(p.response[:p.length]), context.temp_allocator)
}

// A well-formed upgrade request for `target`, with optional extra headers.
daemon_upgrade_request :: proc(target: string, extra_headers := "") -> string {
    key_raw: [ws.SEC_WEBSOCKET_KEY_BYTES]byte
    crypto.rand_bytes(key_raw[:])
    key_encoded: [ws.SEC_WEBSOCKET_KEY_ENCODED_BYTES]byte
    base64.encode_into_buf(key_encoded[:], key_raw[:])

    request := ws.build_upgrade_request(target, "127.0.0.1", key_encoded[:], extra_headers, context.temp_allocator)

    return string(request)
}

// A blob directory holding `BLOB_HASH`.
daemon_test_make_blob_dir :: proc(name: string) -> string {
    dir := daemon_test_make_dir(name)
    path, _ := os.join_path({dir, BLOB_HASH}, context.temp_allocator)
    werr := os.write_entire_file(path, transmute([]byte)string(BLOB_BODY))
    assert(werr == nil, "test blob should be writable")

    return dir
}

// Count directory entries, or -1 if the directory cannot be read.
daemon_blob_dir_count :: proc(dir: string) -> int {
    infos, err := os.read_all_directory_by_path(dir, context.temp_allocator)
    if err != nil {
        return -1
    }

    return len(infos)
}

// Whether any in-flight upload temp file was left behind under `dir`.
daemon_blob_dir_has_temp :: proc(dir: string) -> bool {
    infos, err := os.read_all_directory_by_path(dir, context.temp_allocator)
    if err != nil {
        return false
    }

    for info in infos {
        if strings.has_prefix(info.name, BLOB_TEMP_PREFIX) {
            return true
        }
    }

    return false
}

// Write an empty in-flight upload temp file under `dir` for `hash`, returning its path.
daemon_test_write_temp :: proc(dir: string, hash: string) -> string {
    name := strings.concatenate({BLOB_TEMP_PREFIX, hash, ".nonce"}, context.temp_allocator)
    path, _ := os.join_path({dir, name}, context.temp_allocator)
    werr := os.write_entire_file(path, transmute([]byte)string("partial"))
    assert(werr == nil, "test upload temp should be writable")

    return path
}

// A PUT request to `PUT /blob/<hash>` carrying `body`, with an optional extra header
// block (for auth) and an override for the declared Content-Length.
daemon_blob_put_request :: proc(hash: string, body: string, extra := "", content_length := -1) -> string {
    length := content_length
    if length < 0 {
        length = len(body)
    }

    return fmt.tprintf(
        "PUT /blob/%s HTTP/1.1\r\nhost: 127.0.0.1\r\ncontent-length: %d\r\n%s\r\n%s",
        hash,
        length,
        extra,
        body,
    )
}

@(test)
test_daemon_stores_an_uploaded_blob :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    dir := daemon_test_make_dir("yuke-blob-upload")
    defer os.remove_all(dir)

    put := daemon_run_http(t, daemon_blob_put_request(BLOB_HASH, UPLOAD_BODY), {blob_dir = dir})
    testing.expect(t, strings.has_prefix(put, "HTTP/1.1 201 Created\r\n"), "a fresh, verified blob should 201")

    testing.expect_value(t, daemon_blob_dir_count(dir), 1)
    testing.expect(t, !daemon_blob_dir_has_temp(dir), "no upload temp should remain")

    get := daemon_run_http(t, "GET /blob/" + BLOB_HASH + " HTTP/1.1\r\nhost: 127.0.0.1\r\n\r\n", {blob_dir = dir})
    testing.expect(t, strings.has_prefix(get, "HTTP/1.1 200 OK\r\n"), "the stored blob should be served")
    testing.expect(t, strings.has_suffix(get, UPLOAD_BODY), "the served body should be the uploaded bytes")
}

@(test)
test_daemon_upload_is_idempotent :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    dir := daemon_test_make_dir("yuke-blob-upload-idempotent")
    defer os.remove_all(dir)

    first := daemon_run_http(t, daemon_blob_put_request(BLOB_HASH, UPLOAD_BODY), {blob_dir = dir})
    testing.expect(t, strings.has_prefix(first, "HTTP/1.1 201 Created\r\n"), "the first store should 201")

    second := daemon_run_http(t, daemon_blob_put_request(BLOB_HASH, UPLOAD_BODY), {blob_dir = dir})
    testing.expect(t, strings.has_prefix(second, "HTTP/1.1 200 OK\r\n"), "a repeat store should 200")

    testing.expect_value(t, daemon_blob_dir_count(dir), 1)
    testing.expect(t, !daemon_blob_dir_has_temp(dir), "an idempotent store leaves no temp")

    get := daemon_run_http(t, "GET /blob/" + BLOB_HASH + " HTTP/1.1\r\nhost: 127.0.0.1\r\n\r\n", {blob_dir = dir})
    testing.expect(t, strings.has_suffix(get, UPLOAD_BODY), "the stored content should be intact")
}

@(test)
test_daemon_rejects_upload_hash_mismatch :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    dir := daemon_test_make_dir("yuke-blob-upload-mismatch")
    defer os.remove_all(dir)

    // Bytes that are not `UPLOAD_BODY`, so their digest cannot equal `BLOB_HASH`.
    put := daemon_run_http(t, daemon_blob_put_request(BLOB_HASH, "world"), {blob_dir = dir})
    testing.expect(t, strings.has_prefix(put, "HTTP/1.1 400 Bad Request\r\n"), "a lied-about address should 400")

    stored, _ := os.join_path({dir, BLOB_HASH}, context.temp_allocator)
    testing.expect(t, !os.exists(stored), "a mismatched blob must not be stored under its claimed hash")
    testing.expect_value(t, daemon_blob_dir_count(dir), 0)
    testing.expect(t, !daemon_blob_dir_has_temp(dir), "a rejected upload must delete its temp")
}

// Drives the cap on the declared Content-Length: it advertises one byte over
// `max_blob_bytes` while sending a tiny body, so the daemon rejects before reading it.
@(test)
test_daemon_rejects_oversized_upload :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    dir := daemon_test_make_dir("yuke-blob-upload-oversized")
    defer os.remove_all(dir)

    over := int(wire.LIMITS.max_blob_bytes) + 1
    put := daemon_run_http(t, daemon_blob_put_request(BLOB_HASH, "x", content_length = over), {blob_dir = dir})
    testing.expect(t, strings.has_prefix(put, "HTTP/1.1 413 Content Too Large\r\n"), "an over-cap upload should 413")

    testing.expect_value(t, daemon_blob_dir_count(dir), 0)
    testing.expect(t, !daemon_blob_dir_has_temp(dir), "a rejected upload opens no temp")
}

@(test)
test_daemon_rejects_unauthorized_upload :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    dir := daemon_test_make_dir("yuke-blob-upload-unauth")
    defer os.remove_all(dir)

    put := daemon_run_http(t, daemon_blob_put_request(BLOB_HASH, UPLOAD_BODY), {blob_dir = dir, auth_token = "s3cret"})
    testing.expect(t, strings.has_prefix(put, "HTTP/1.1 401 Unauthorized\r\n"), "an unauthenticated upload must 401")

    testing.expect_value(t, daemon_blob_dir_count(dir), 0)
}

@(test)
test_daemon_rejects_a_traversing_upload_path :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    dir := daemon_test_make_dir("yuke-blob-upload-traversal")
    defer os.remove_all(dir)

    put := daemon_run_http(t, daemon_blob_put_request("../../etc/passwd", UPLOAD_BODY), {blob_dir = dir})
    testing.expect(
        t,
        strings.has_prefix(put, "HTTP/1.1 404 Not Found\r\n"),
        "a non-hash upload path must never resolve",
    )

    testing.expect_value(t, daemon_blob_dir_count(dir), 0)
    testing.expect(t, !daemon_blob_dir_has_temp(dir), "a rejected path opens no temp")
}

@(test)
test_daemon_serves_a_blob :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    dir := daemon_test_make_blob_dir("yuke-blob-serve")
    defer os.remove_all(dir)

    got := daemon_run_http(t, "GET /blob/" + BLOB_HASH + " HTTP/1.1\r\nhost: 127.0.0.1\r\n\r\n", {blob_dir = dir})

    testing.expect(t, strings.has_prefix(got, "HTTP/1.1 200 OK\r\n"), "a stored blob should be served")
    testing.expect(t, strings.contains(got, "Content-Type: application/octet-stream\r\n"), "blobs are opaque bytes")
    testing.expect(t, strings.has_suffix(got, BLOB_BODY), "the body should be the stored bytes")
}

@(test)
test_daemon_unknown_blob_is_not_found :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    dir := daemon_test_make_blob_dir("yuke-blob-unknown")
    defer os.remove_all(dir)

    // Well-formed hash, nothing stored under it.
    MISSING :: "0000000000000000000000000000000000000000000000000000000000000000"
    got := daemon_run_http(t, "GET /blob/" + MISSING + " HTTP/1.1\r\nhost: 127.0.0.1\r\n\r\n", {blob_dir = dir})

    testing.expect(t, strings.has_prefix(got, "HTTP/1.1 404 Not Found\r\n"), "an unknown blob should 404")
}

@(test)
test_daemon_rejects_a_traversing_blob_path :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    dir := daemon_test_make_blob_dir("yuke-blob-traversal")
    defer os.remove_all(dir)

    got := daemon_run_http(t, "GET /blob/../../etc/passwd HTTP/1.1\r\nhost: 127.0.0.1\r\n\r\n", {blob_dir = dir})

    testing.expect(t, strings.has_prefix(got, "HTTP/1.1 404 Not Found\r\n"), "a non-hash path must never resolve")
}

@(test)
test_daemon_unknown_route_is_not_found :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    got := daemon_run_http(t, "GET /nope HTTP/1.1\r\nhost: 127.0.0.1\r\n\r\n")

    testing.expect(t, strings.has_prefix(got, "HTTP/1.1 404 Not Found\r\n"), "an unrouted path should 404")
}

@(test)
test_daemon_rejects_a_non_get :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    got := daemon_run_http(t, "POST /ws HTTP/1.1\r\nhost: 127.0.0.1\r\ncontent-length: 0\r\n\r\n")

    testing.expect(t, strings.has_prefix(got, "HTTP/1.1 405 Method Not Allowed\r\n"), "only GET is routed")
    testing.expectf(t, strings.contains(got, "Allow: GET\r\n"), "405 must carry Allow, got %q", got)
}

// The blob routes register two methods, and a `?token=` 405 must keep both the cache
// marker and `Allow`.
@(test)
test_daemon_405_on_blob_lists_both_methods :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    got := daemon_run_http(
        t,
        "DELETE /blob/" + BLOB_HASH + "?token=s3cret HTTP/1.1\r\nhost: 127.0.0.1\r\n\r\n",
        {auth_token = "s3cret"},
    )

    testing.expect(t, strings.has_prefix(got, "HTTP/1.1 405 Method Not Allowed\r\n"), "DELETE is not routed")
    testing.expectf(t, strings.contains(got, "Allow: GET, PUT\r\n"), "405 must list both methods, got %q", got)
    testing.expectf(
        t,
        strings.contains(got, "Cache-Control: private, no-store\r\n"),
        "a ?token= response must stay private, got %q",
        got,
    )
}

@(test)
test_daemon_rejects_a_non_upgrade_on_ws :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    got := daemon_run_http(t, "GET /ws HTTP/1.1\r\nhost: 127.0.0.1\r\n\r\n")

    testing.expect(t, strings.has_prefix(got, "HTTP/1.1 400 Bad Request\r\n"), "a bare GET /ws is not an upgrade")
}

@(test)
test_daemon_upgrades_without_auth :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    got := daemon_run_http(t, daemon_upgrade_request("/ws"))

    testing.expect(t, strings.has_prefix(got, "HTTP/1.1 101 Switching Protocols\r\n"), "a valid upgrade should 101")
}

@(test)
test_daemon_requires_the_auth_token :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    got := daemon_run_http(t, daemon_upgrade_request("/ws"), {auth_token = "s3cret"})

    testing.expect(t, strings.has_prefix(got, "HTTP/1.1 401 Unauthorized\r\n"), "an unauthorized upgrade should 401")
    testing.expect(
        t,
        strings.contains(got, "WWW-Authenticate: Bearer realm=\"yuked\"\r\n"),
        "a 401 should carry a bearer challenge",
    )
}

@(test)
test_daemon_rejects_a_wrong_auth_token :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    got := daemon_run_http(
        t,
        daemon_upgrade_request("/ws", "Authorization: Bearer wrong1\r\n"),
        {auth_token = "s3cret"},
    )

    testing.expect(t, strings.has_prefix(got, "HTTP/1.1 401 Unauthorized\r\n"), "a wrong token should 401")
}

@(test)
test_daemon_accepts_a_query_token :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    got := daemon_run_http(t, daemon_upgrade_request("/ws?token=s3cret"), {auth_token = "s3cret"})

    testing.expect(t, strings.has_prefix(got, "HTTP/1.1 101 Switching Protocols\r\n"), "?token= should authorize")
    testing.expect(
        t,
        strings.contains(got, "Cache-Control: private, no-store\r\n"),
        "token-bearing upgrades must not be cached",
    )
}

@(test)
test_daemon_auth_gate_covers_blob_and_unknown_routes :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    blob := daemon_run_http(
        t,
        "GET /blob/" + BLOB_HASH + " HTTP/1.1\r\nhost: 127.0.0.1\r\n\r\n",
        {auth_token = "s3cret"},
    )
    testing.expect(t, strings.has_prefix(blob, "HTTP/1.1 401 Unauthorized\r\n"), "blob access must be authenticated")

    unknown := daemon_run_http(t, "GET /nope HTTP/1.1\r\nhost: 127.0.0.1\r\n\r\n", {auth_token = "s3cret"})
    testing.expect(
        t,
        strings.has_prefix(unknown, "HTTP/1.1 401 Unauthorized\r\n"),
        "auth must precede route disclosure",
    )

    non_get := daemon_run_http(
        t,
        "POST /ws HTTP/1.1\r\nhost: 127.0.0.1\r\ncontent-length: 0\r\n\r\n",
        {auth_token = "s3cret"},
    )
    testing.expect(
        t,
        strings.has_prefix(non_get, "HTTP/1.1 401 Unauthorized\r\n"),
        "auth must precede method disclosure",
    )
}

@(test)
test_daemon_accepts_case_insensitive_bearer_for_blob :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    dir := daemon_test_make_blob_dir("yuke-blob-auth")
    defer os.remove_all(dir)

    got := daemon_run_http(
        t,
        "GET /blob/" + BLOB_HASH + " HTTP/1.1\r\nhost: 127.0.0.1\r\nauthorization: bEaReR  s3cret\r\n\r\n",
        {blob_dir = dir, auth_token = "s3cret"},
    )

    testing.expect(t, strings.has_prefix(got, "HTTP/1.1 200 OK\r\n"), "the bearer scheme is case-insensitive")
    testing.expect(t, strings.has_suffix(got, BLOB_BODY), "an authorized blob response should stream the file")
}

@(test)
test_daemon_rejects_ambiguous_credentials :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    both := daemon_run_http(
        t,
        daemon_upgrade_request("/ws?token=s3cret", "Authorization: Bearer s3cret\r\n"),
        {auth_token = "s3cret"},
    )
    testing.expect(
        t,
        strings.has_prefix(both, "HTTP/1.1 400 Bad Request\r\n"),
        "header plus query credentials are ambiguous",
    )

    duplicate_header := daemon_run_http(
        t,
        daemon_upgrade_request("/ws", "Authorization: Bearer s3cret\r\nAuthorization: Bearer s3cret\r\n"),
        {auth_token = "s3cret"},
    )
    testing.expect(
        t,
        strings.has_prefix(duplicate_header, "HTTP/1.1 400 Bad Request\r\n"),
        "duplicate authorization fields are ambiguous",
    )

    duplicate_query := daemon_run_http(
        t,
        daemon_upgrade_request("/ws?token=s3cret&token=s3cret"),
        {auth_token = "s3cret"},
    )
    testing.expect(
        t,
        strings.has_prefix(duplicate_query, "HTTP/1.1 400 Bad Request\r\n"),
        "duplicate token parameters are ambiguous",
    )
}

// Even with auth disabled, a request carrying a `?token=` is marked private so no
// intermediary caches a would-be credentialed response; a request with no token is
// freely cacheable.
@(test)
test_daemon_disabled_auth_marks_token_responses_private :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    with_token := daemon_run_http(t, "GET /nope?token=whatever HTTP/1.1\r\nhost: 127.0.0.1\r\n\r\n")
    testing.expect(
        t,
        strings.has_prefix(with_token, "HTTP/1.1 404 Not Found\r\n"),
        "an unrouted path 404s even with auth disabled",
    )
    testing.expect(
        t,
        strings.contains(with_token, "Cache-Control: private, no-store\r\n"),
        "a token-bearing request is private even when auth is disabled",
    )

    without := daemon_run_http(t, "GET /nope HTTP/1.1\r\nhost: 127.0.0.1\r\n\r\n")
    testing.expect(t, strings.has_prefix(without, "HTTP/1.1 404 Not Found\r\n"), "an unrouted path 404s")
    testing.expect(t, !strings.contains(without, "Cache-Control:"), "a request with no token is freely cacheable")
}

// The admit refusal is the one path that answers before authentication, so it is the
// one most easily left out of the token-bearing-response invariant.
@(test)
test_daemon_refusal_marks_token_responses_private :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    refused := daemon_run_http(t, "GET /nope?token=whatever HTTP/1.1\r\nhost: rebind.example\r\n\r\n")
    testing.expect(t, strings.has_prefix(refused, "HTTP/1.1 403 Forbidden\r\n"), "a named Host is refused")
    testing.expectf(
        t,
        strings.contains(refused, "Cache-Control: private, no-store\r\n"),
        "a token-bearing 403 must stay private, got %q",
        refused,
    )

    without := daemon_run_http(t, "GET /nope HTTP/1.1\r\nhost: rebind.example\r\n\r\n")
    testing.expect(t, strings.has_prefix(without, "HTTP/1.1 403 Forbidden\r\n"), "a named Host is refused")
    testing.expect(t, !strings.contains(without, "Cache-Control:"), "a 403 with no token needs no marker")
}

// A symlink standing in for a stored blob is refused: `lstat` sees the link, not a
// regular file, and the post-open identity re-check guards the open against a swap.
@(test)
test_daemon_rejects_a_symlinked_blob :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    dir := daemon_test_make_blob_dir("yuke-blob-symlink")
    defer os.remove_all(dir)

    SYMHASH :: "1111111111111111111111111111111111111111111111111111111111111111"
    target, _ := os.join_path({dir, BLOB_HASH}, context.temp_allocator)
    link, _ := os.join_path({dir, SYMHASH}, context.temp_allocator)
    if serr := os.symlink(target, link); serr != nil {
        fmt.printfln("skipping: filesystem rejected a symlink: %v", serr)
        return
    }
    defer os.remove_all(link)

    got := daemon_run_http(t, "GET /blob/" + SYMHASH + " HTTP/1.1\r\nhost: 127.0.0.1\r\n\r\n", {blob_dir = dir})

    testing.expect(t, strings.has_prefix(got, "HTTP/1.1 404 Not Found\r\n"), "a symlinked blob path must be refused")
}

@(test)
test_daemon_query_authenticated_blob_is_not_cacheable :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    dir := daemon_test_make_blob_dir("yuke-blob-query-auth")
    defer os.remove_all(dir)

    got := daemon_run_http(
        t,
        "GET /blob/" + BLOB_HASH + "?token=s3cret HTTP/1.1\r\nhost: 127.0.0.1\r\n\r\n",
        {blob_dir = dir, auth_token = "s3cret"},
    )

    testing.expect(t, strings.has_prefix(got, "HTTP/1.1 200 OK\r\n"), "a query token should authorize blob access")
    testing.expect(
        t,
        strings.contains(got, "Cache-Control: private, no-store\r\n"),
        "token-bearing responses must not be cached",
    )
}

@(test)
test_daemon_auth_token_uses_url_safe_grammar :: proc(t: ^testing.T) {
    testing.expect(t, daemon_auth_token_valid("AZaz09-._~"), "the unreserved alphabet should be accepted")
    testing.expect(t, !daemon_auth_token_valid("has space"), "spaces require URL encoding and should be rejected")
    testing.expect(t, !daemon_auth_token_valid("has/slash"), "reserved query bytes should be rejected")
}

// End to end: the real client driver reaches Ready through the token gate, carrying
// the bearer header the daemon expects.
@(test)
test_daemon_bearer_token_reaches_ready :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    d: Daemon
    testing.expect_value(
        t,
        daemon_start(&d, loop, {host = "127.0.0.1", port = 0, auth_token = "s3cret"}),
        Daemon_Error.None,
    )

    obs: Cli_Obs
    c: client.Client
    cerr := client.client_open(
        &c,
        loop,
        ws.Options {
            host = "127.0.0.1",
            port = daemon_bound_port(&d),
            path = "/ws",
            extra_headers = "Authorization: Bearer s3cret\r\n",
        },
        "yuke-test",
        "0.1.0",
        cli_callbacks(),
        &obs,
        context.temp_allocator,
    )
    testing.expect_value(t, cerr, client.Protocol_Error.None)

    nbio.run_until(&obs.done)

    testing.expect(t, obs.ready, "an authorized client should reach Ready")
    testing.expect_value(t, obs.err, client.Protocol_Error.None)

    client.client_destroy(&c)
    daemon_test_teardown(&d)
}

// --- Boot-time upload-temp sweep -----------------------------------------------
//
// `daemon_blob_sweep_temps` takes its cutoff as an explicit parameter, so staleness is
// forced by choosing a future or past cutoff rather than manipulating mtimes.

@(test)
test_blob_sweep_removes_stale_temp :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    dir := daemon_test_make_dir("yuke-blob-sweep-stale")
    defer os.remove_all(dir)

    temp_path := daemon_test_write_temp(dir, BLOB_HASH)

    // A cutoff in the future: the temp's real mtime is necessarily before it.
    removed := daemon_blob_sweep_temps(dir, time.time_add(time.now(), time.Hour))

    testing.expect_value(t, removed, 1)
    testing.expect(t, !os.exists(temp_path), "a stale upload temp should be removed")
}

@(test)
test_blob_sweep_keeps_fresh_temp_and_blobs :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    dir := daemon_test_make_blob_dir("yuke-blob-sweep-fresh")
    defer os.remove_all(dir)

    temp_path := daemon_test_write_temp(dir, BLOB_HASH)
    blob_path, _ := os.join_path({dir, BLOB_HASH}, context.temp_allocator)

    // A cutoff in the past: nothing written just now can be older than it.
    removed := daemon_blob_sweep_temps(dir, time.time_add(time.now(), -time.Hour))

    testing.expect_value(t, removed, 0)
    testing.expect(t, os.exists(temp_path), "a fresh upload temp must survive the sweep")
    testing.expect(t, os.exists(blob_path), "a published blob must never be swept")
}

@(test)
test_blob_sweep_missing_dir_is_noop :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    dir := daemon_test_make_dir("yuke-blob-sweep-missing")
    os.remove_all(dir)

    removed := daemon_blob_sweep_temps(dir, time.now())
    testing.expect_value(t, removed, 0)
}

// --- Admission tests ----------------------------------------------------------
//
// The front door refuses traffic a browser can be made to send at it, before the
// credential check. The two refusals are independent: a rebound page is same-origin
// with the daemon and sends no `Origin` at all.

@(test)
test_daemon_refuses_a_browser_origin :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    got := daemon_run_http(t, "GET /ws HTTP/1.1\r\nhost: 127.0.0.1\r\norigin: https://evil.example\r\n\r\n")

    testing.expect(t, strings.has_prefix(got, "HTTP/1.1 403 Forbidden\r\n"), "an Origin marks a page-driven request")
}

// Admission must precede authentication. With no credential and a token configured,
// auth alone would answer 401, so only the ordering can produce 403.
@(test)
test_daemon_refuses_an_origin_before_authenticating :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    got := daemon_run_http(
        t,
        "GET /ws HTTP/1.1\r\nhost: 127.0.0.1\r\norigin: https://evil.example\r\n\r\n",
        {auth_token = "s3cret"},
    )

    testing.expectf(
        t,
        strings.has_prefix(got, "HTTP/1.1 403 Forbidden\r\n"),
        "admission must answer before auth could 401, got %q",
        got,
    )
}

@(test)
test_daemon_refuses_a_named_host :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    got := daemon_run_http(t, "GET /blob/" + BLOB_HASH + " HTTP/1.1\r\nhost: rebind.example\r\n\r\n")

    testing.expect(t, strings.has_prefix(got, "HTTP/1.1 403 Forbidden\r\n"), "a named Host is the rebinding shape")
}

@(test)
test_daemon_admits_literal_hosts :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    hosts := []string {
        "127.0.0.1",
        "127.0.0.1:65535",
        "127.0.0.2",
        "127.1.2.3",
        "localhost",
        "localhost:8080",
        "[::1]",
        "[::1]:8080",
        "[::ffff:127.0.0.1]",
    }
    for host in hosts {
        got := daemon_run_http(t, fmt.tprintf("GET /nope HTTP/1.1\r\nhost: %s\r\n\r\n", host))
        testing.expectf(
            t,
            strings.has_prefix(got, "HTTP/1.1 404 Not Found\r\n"),
            "host %q addresses the daemon and should reach routing, got %q",
            host,
            got,
        )
    }
}

// An IP literal is only admissible if it addresses this daemon. `0.0.0.0` is the one
// that matters: it reaches a loopback-bound socket while escaping the browser
// local-network gating `127.0.0.1` receives.
@(test)
test_daemon_refuses_literals_that_do_not_address_it :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    hosts := []string{"0.0.0.0", "0.0.0.0:8080", "[::]", "192.168.1.50", "10.0.0.1", "8.8.8.8", "[2001:db8::1]"}
    for host in hosts {
        got := daemon_run_http(t, fmt.tprintf("GET /nope HTTP/1.1\r\nhost: %s\r\n\r\n", host))
        testing.expectf(
            t,
            strings.has_prefix(got, "HTTP/1.1 403 Forbidden\r\n"),
            "host %q does not address a loopback-bound daemon, got %q",
            host,
            got,
        )
    }
}

// Bytes past the declared body are a pipelined follow-up request. Bytes *within* it are
// body, which the old check conflated: `PUT /nope` with a body must 404, not 400.
@(test)
test_daemon_rejects_pipelining_but_not_bodies :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    unrouted := daemon_run_http(t, "GET /nope HTTP/1.1\r\nhost: 127.0.0.1\r\n\r\nGET /x HTTP/1.1\r\n")
    testing.expectf(
        t,
        strings.has_prefix(unrouted, "HTTP/1.1 400 Bad Request\r\n"),
        "a pipelined follow-up should 400, got %q",
        unrouted,
    )

    blob := daemon_run_http(t, "GET /blob/" + BLOB_HASH + " HTTP/1.1\r\nhost: 127.0.0.1\r\n\r\nGET /x HTTP/1.1\r\n")
    testing.expectf(
        t,
        strings.has_prefix(blob, "HTTP/1.1 400 Bad Request\r\n"),
        "a pipelined follow-up on a blob route should 400, got %q",
        blob,
    )

    with_body := daemon_run_http(t, "PUT /nope HTTP/1.1\r\nhost: 127.0.0.1\r\ncontent-length: 5\r\n\r\nhello")
    testing.expectf(
        t,
        strings.has_prefix(with_body, "HTTP/1.1 404 Not Found\r\n"),
        "a body on an unrouted path is not pipelining, got %q",
        with_body,
    )
}

// `/ws` is the one route that keeps its trailing bytes: they are the client's eager
// first frame, handed to the WebSocket server rather than refused as pipelining.
@(test)
test_daemon_upgrade_keeps_trailing_bytes :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    request := fmt.tprintf("%s%s", daemon_upgrade_request("/ws"), "\x81\x00")
    got := daemon_run_http(t, request)

    testing.expectf(
        t,
        strings.has_prefix(got, "HTTP/1.1 101 Switching Protocols\r\n"),
        "an eager first frame must not be refused as pipelining, got %q",
        got,
    )
}

// RFC 6750 §3.1: a rejected credential earns `invalid_token`, an unsupported scheme
// earns no error code, and more than one credential source is `invalid_request`.
@(test)
test_daemon_challenge_matches_the_refusal :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    scheme := daemon_run_http(
        t,
        "GET /ws HTTP/1.1\r\nhost: 127.0.0.1\r\nauthorization: Basic abc\r\n\r\n",
        {auth_token = "s3cret"},
    )
    testing.expect(t, strings.has_prefix(scheme, "HTTP/1.1 401 Unauthorized\r\n"), "another scheme should 401")
    testing.expectf(
        t,
        strings.contains(scheme, "WWW-Authenticate: Bearer realm=\"yuked\"\r\n"),
        "an unsupported scheme gets no error code, got %q",
        scheme,
    )

    malformed := daemon_run_http(
        t,
        "GET /ws HTTP/1.1\r\nhost: 127.0.0.1\r\nauthorization: Bearer\r\n\r\n",
        {auth_token = "s3cret"},
    )
    testing.expectf(
        t,
        strings.contains(malformed, "error=\"invalid_token\""),
        "a malformed Bearer credential is invalid_token, got %q",
        malformed,
    )

    ambiguous := daemon_run_http(
        t,
        "GET /ws?token=s3cret HTTP/1.1\r\nhost: 127.0.0.1\r\nauthorization: Bearer s3cret\r\n\r\n",
        {auth_token = "s3cret"},
    )
    testing.expect(t, strings.has_prefix(ambiguous, "HTTP/1.1 400 Bad Request\r\n"), "two sources should 400")
    testing.expectf(
        t,
        strings.contains(ambiguous, "error=\"invalid_request\""),
        "two credential sources are invalid_request, got %q",
        ambiguous,
    )
    testing.expectf(
        t,
        strings.contains(ambiguous, "Cache-Control: private, no-store\r\n"),
        "a ?token= refusal stays private, got %q",
        ambiguous,
    )
}

// A HEAD on a known path is still a 405, but must carry no content.
@(test)
test_daemon_head_response_has_no_content :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    got := daemon_run_http(t, "HEAD /ws HTTP/1.1\r\nhost: 127.0.0.1\r\n\r\n")

    testing.expect(t, strings.has_prefix(got, "HTTP/1.1 405 Method Not Allowed\r\n"), "HEAD is not routed")
    testing.expect(t, strings.contains(got, "Allow: GET\r\n"), "405 still carries Allow")
    testing.expectf(t, strings.has_suffix(got, "\r\n\r\n"), "HEAD must send no content, got %q", got)
}

// HEAD on a blob path: not routed, so a 405 — and it must carry no content either.
@(test)
test_daemon_head_on_blob_has_no_content :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    dir := daemon_test_make_blob_dir("yuke-blob-head")
    defer os.remove_all(dir)

    got := daemon_run_http(t, "HEAD /blob/" + BLOB_HASH + " HTTP/1.1\r\nhost: 127.0.0.1\r\n\r\n", {blob_dir = dir})

    testing.expect(t, strings.has_prefix(got, "HTTP/1.1 405 Method Not Allowed\r\n"), "HEAD is not routed")
    testing.expectf(t, strings.has_suffix(got, "\r\n\r\n"), "HEAD must send no content, got %q", got)
}

// The bind-address arm of admission cannot be reached by binding a non-loopback address
// portably, so it is checked directly.
@(test)
test_daemon_admits_its_own_bind_address :: proc(t: ^testing.T) {
    d := Daemon {
        bind_address = {192, 168, 1, 50},
    }

    testing.expect(t, daemon_address_addresses_us(&d, net.IP4_Address{192, 168, 1, 50}), "its own bind address")
    testing.expect(t, daemon_address_addresses_us(&d, net.IP4_Loopback), "loopback regardless of bind")
    testing.expect(t, !daemon_address_addresses_us(&d, net.IP4_Address{192, 168, 1, 51}), "a neighbour")
    testing.expect(t, !daemon_address_addresses_us(&d, net.IP4_Any), "the unspecified address")

    wildcard := Daemon {
        bind_address = net.IP4_Any,
    }
    testing.expect(t, !daemon_address_addresses_us(&wildcard, net.IP4_Any), "a wildcard bind admits no wildcard Host")
    testing.expect(
        t,
        daemon_address_addresses_us(&wildcard, net.IP4_Loopback),
        "a wildcard bind still admits loopback",
    )
}

// A `Host` starting with `]:` panics `net.split_port`, pre-auth: refuse, never abort.
@(test)
test_daemon_refuses_a_malformed_host_without_crashing :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    hosts := []string {
        "]:80",
        "]:",
        "]:abc",
        "]",
        "[",
        "[]",
        "[]:80",
        "[::1",
        "[::1]x",
        "[::1]:80]:90",
        "a127.0.0.1]:80",
        "[localhost]",
        "127.0.0.1:notaport",
        ":80",
    }
    for host in hosts {
        got := daemon_run_http(t, fmt.tprintf("GET /nope HTTP/1.1\r\nhost: %s\r\n\r\n", host))
        testing.expectf(
            t,
            strings.has_prefix(got, "HTTP/1.1 403 Forbidden\r\n"),
            "host %q is not a literal addressing the daemon, got %q",
            host,
            got,
        )
    }
}

@(test)
test_daemon_challenge_names_an_invalid_token :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    missing := daemon_run_http(t, "GET /ws HTTP/1.1\r\nhost: 127.0.0.1\r\n\r\n", {auth_token = "s3cret"})
    testing.expect(t, strings.has_prefix(missing, "HTTP/1.1 401 Unauthorized\r\n"), "an absent credential should 401")
    testing.expect(
        t,
        !strings.contains(missing, "error=\"invalid_token\""),
        "an absent credential must not be reported as a rejected one",
    )

    wrong := daemon_run_http(
        t,
        "GET /ws HTTP/1.1\r\nhost: 127.0.0.1\r\nauthorization: Bearer nope\r\n\r\n",
        {auth_token = "s3cret"},
    )
    testing.expect(t, strings.has_prefix(wrong, "HTTP/1.1 401 Unauthorized\r\n"), "a wrong credential should 401")
    testing.expect(
        t,
        strings.contains(wrong, "error=\"invalid_token\""),
        "a rejected credential should name the error",
    )
}

@(test)
test_daemon_creates_a_missing_blob_dir :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    dir := daemon_test_make_dir("yuke-blob-create")
    defer os.remove_all(dir)

    nested, _ := os.join_path({dir, "blobs"}, context.temp_allocator)

    put := daemon_run_http(t, daemon_blob_put_request(BLOB_HASH, UPLOAD_BODY), {blob_dir = nested})

    testing.expect(t, os.is_dir(nested), "a missing blob directory should be created at start")
    testing.expect(t, strings.has_prefix(put, "HTTP/1.1 201 Created\r\n"), "an upload into it should 201")
}

// The created directory and the published blob must both be owner-only.
@(test)
test_daemon_blob_store_is_owner_only :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    dir := daemon_test_make_dir("yuke-blob-perms")
    defer os.remove_all(dir)

    nested, _ := os.join_path({dir, "blobs"}, context.temp_allocator)

    put := daemon_run_http(t, daemon_blob_put_request(BLOB_HASH, UPLOAD_BODY), {blob_dir = nested})
    testing.expect(t, strings.has_prefix(put, "HTTP/1.1 201 Created\r\n"), "the upload should store a blob")

    dir_info, dir_err := os.stat(nested, context.temp_allocator)
    testing.expect(t, dir_err == nil, "the blob directory should exist")
    testing.expectf(
        t,
        dir_info.mode & ~BLOB_DIR_PERMISSIONS == {},
        "blob dir reachable beyond its owner: %v",
        dir_info.mode,
    )

    blob_path, _ := os.join_path({nested, BLOB_HASH}, context.temp_allocator)
    blob_info, blob_err := os.stat(blob_path, context.temp_allocator)
    testing.expect(t, blob_err == nil, "the published blob should exist")
    testing.expectf(
        t,
        blob_info.mode & ~BLOB_FILE_PERMISSIONS == {},
        "published blob readable beyond its owner: %v",
        blob_info.mode,
    )
}

@(test)
test_daemon_rejects_an_unusable_blob_dir :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    dir := daemon_test_make_dir("yuke-blob-unusable")
    defer os.remove_all(dir)

    // A regular file where the blob directory should be: it can never hold a blob.
    occupied, _ := os.join_path({dir, "occupied"}, context.temp_allocator)
    testing.expect(t, os.write_entire_file(occupied, transmute([]byte)string("x")) == nil, "test setup")

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    d: Daemon
    err := daemon_start(&d, loop, {host = "127.0.0.1", port = 0, blob_dir = occupied})

    testing.expect_value(t, err, Daemon_Error.Invalid_Options)
}
