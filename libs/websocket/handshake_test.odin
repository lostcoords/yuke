package websocket

import "core:strings"
import "core:testing"

// RFC 6455 §1.3 worked example: the sample key derives the sample accept value.
@(test)
test_make_sec_websocket_accept_rfc_vector :: proc(t: ^testing.T) {
    key_encoded := "dGhlIHNhbXBsZSBub25jZQ=="
    out: [SEC_WEBSOCKET_ACCEPT_ENCODED_BYTES]byte

    accept := make_sec_websocket_accept(transmute([]byte)key_encoded, out[:])

    testing.expect_value(t, string(accept), "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
}

// The upgrade request carries the required RFC 6455 headers and the sent key.
@(test)
test_build_upgrade_request_headers :: proc(t: ^testing.T) {
    req := build_upgrade_request(
        "/ws",
        "127.0.0.1:7880",
        transmute([]byte)string("abc123key=="),
        "",
        context.temp_allocator,
    )
    s := string(req)

    testing.expect(t, strings.has_prefix(s, "GET /ws HTTP/1.1\r\n"), "request line")
    testing.expect(t, strings.contains(s, "\r\nhost: 127.0.0.1:7880\r\n"), "host header")
    testing.expect(t, strings.contains(s, "\r\nupgrade: websocket\r\n"), "upgrade header")
    testing.expect(t, strings.contains(s, "\r\nconnection: Upgrade\r\n"), "connection header")
    testing.expect(t, strings.contains(s, "\r\nsec-websocket-version: 13\r\n"), "version header")
    testing.expect(t, strings.contains(s, "\r\nsec-websocket-key: abc123key==\r\n"), "key header")
    testing.expect(t, strings.has_suffix(s, "\r\n\r\n"), "blank line terminator")
}

// A correct 101 response with a matching accept validates and consumes exactly
// the header block, leaving any pipelined trailing bytes for the caller.
@(test)
test_parse_upgrade_response_ok :: proc(t: ^testing.T) {
    key := "dGhlIHNhbXBsZSBub25jZQ=="
    response :=
        "HTTP/1.1 101 Switching Protocols\r\n" +
        "Upgrade: websocket\r\n" +
        "Connection: Upgrade\r\n" +
        "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n" +
        "\r\n" +
        "TRAILING"

    result, consumed, status := parse_upgrade_response(transmute([]byte)response, transmute([]byte)key)

    testing.expect_value(t, status, Response_Status.Ready)
    testing.expect_value(t, result, Handshake_Result.Ok)
    testing.expect_value(t, string(transmute([]byte)response)[consumed:], "TRAILING")
}

// Header parsing is case-insensitive for names and for the connection token list.
@(test)
test_parse_upgrade_response_case_insensitive :: proc(t: ^testing.T) {
    key := "dGhlIHNhbXBsZSBub25jZQ=="
    response :=
        "HTTP/1.1 101 Switching Protocols\r\n" +
        "UPGRADE: WebSocket\r\n" +
        "CONNECTION: keep-alive, Upgrade\r\n" +
        "sec-websocket-accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n" +
        "\r\n"

    result, _, status := parse_upgrade_response(transmute([]byte)response, transmute([]byte)key)

    testing.expect_value(t, status, Response_Status.Ready)
    testing.expect_value(t, result, Handshake_Result.Ok)
}

// A partial response (no header terminator yet) reports `.Need_More`, not failure.
@(test)
test_parse_upgrade_response_need_more :: proc(t: ^testing.T) {
    key := "dGhlIHNhbXBsZSBub25jZQ=="
    partial := "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"

    result, consumed, status := parse_upgrade_response(transmute([]byte)partial, transmute([]byte)key)

    testing.expect_value(t, status, Response_Status.Need_More)
    testing.expect_value(t, consumed, 0)
    testing.expect_value(t, result, Handshake_Result.Ok) // result is unused while Need_More
}

// A non-101 status fails as `.Bad_Status`.
@(test)
test_parse_upgrade_response_bad_status :: proc(t: ^testing.T) {
    key := "dGhlIHNhbXBsZSBub25jZQ=="
    response := "HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n"

    result, _, status := parse_upgrade_response(transmute([]byte)response, transmute([]byte)key)

    testing.expect_value(t, status, Response_Status.Ready)
    testing.expect_value(t, result, Handshake_Result.Bad_Status)
}

// A wrong Sec-WebSocket-Accept value fails as `.Bad_Headers`.
@(test)
test_parse_upgrade_response_bad_accept :: proc(t: ^testing.T) {
    key := "dGhlIHNhbXBsZSBub25jZQ=="
    response :=
        "HTTP/1.1 101 Switching Protocols\r\n" +
        "Upgrade: websocket\r\n" +
        "Connection: Upgrade\r\n" +
        "Sec-WebSocket-Accept: wrongwrongwrongwrongwrongwr=\r\n" +
        "\r\n"

    result, _, status := parse_upgrade_response(transmute([]byte)response, transmute([]byte)key)

    testing.expect_value(t, status, Response_Status.Ready)
    testing.expect_value(t, result, Handshake_Result.Bad_Headers)
}

// A 101 missing a required upgrade header fails as `.Missing_Headers`.
@(test)
test_parse_upgrade_response_missing_headers :: proc(t: ^testing.T) {
    key := "dGhlIHNhbXBsZSBub25jZQ=="
    response := "HTTP/1.1 101 Switching Protocols\r\n" + "Upgrade: websocket\r\n" + "\r\n"

    result, _, status := parse_upgrade_response(transmute([]byte)response, transmute([]byte)key)

    testing.expect_value(t, status, Response_Status.Ready)
    testing.expect_value(t, result, Handshake_Result.Missing_Headers)
}

// A duplicate Upgrade header is rejected even when both instances agree, as a
// response-splitting / smuggling defense.
@(test)
test_parse_upgrade_response_duplicate_upgrade_header :: proc(t: ^testing.T) {
    key := "dGhlIHNhbXBsZSBub25jZQ=="
    response :=
        "HTTP/1.1 101 Switching Protocols\r\n" +
        "Upgrade: websocket\r\n" +
        "Upgrade: websocket\r\n" +
        "Connection: Upgrade\r\n" +
        "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n" +
        "\r\n"

    result, _, status := parse_upgrade_response(transmute([]byte)response, transmute([]byte)key)

    testing.expect_value(t, status, Response_Status.Ready)
    testing.expect_value(t, result, Handshake_Result.Bad_Headers)
}

// A duplicate Connection header is rejected even when both instances agree.
@(test)
test_parse_upgrade_response_duplicate_connection_header :: proc(t: ^testing.T) {
    key := "dGhlIHNhbXBsZSBub25jZQ=="
    response :=
        "HTTP/1.1 101 Switching Protocols\r\n" +
        "Upgrade: websocket\r\n" +
        "Connection: Upgrade\r\n" +
        "Connection: Upgrade\r\n" +
        "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n" +
        "\r\n"

    result, _, status := parse_upgrade_response(transmute([]byte)response, transmute([]byte)key)

    testing.expect_value(t, status, Response_Status.Ready)
    testing.expect_value(t, result, Handshake_Result.Bad_Headers)
}

// A duplicate Sec-WebSocket-Accept header is rejected even when both instances agree.
@(test)
test_parse_upgrade_response_duplicate_accept_header :: proc(t: ^testing.T) {
    key := "dGhlIHNhbXBsZSBub25jZQ=="
    response :=
        "HTTP/1.1 101 Switching Protocols\r\n" +
        "Upgrade: websocket\r\n" +
        "Connection: Upgrade\r\n" +
        "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n" +
        "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n" +
        "\r\n"

    result, _, status := parse_upgrade_response(transmute([]byte)response, transmute([]byte)key)

    testing.expect_value(t, status, Response_Status.Ready)
    testing.expect_value(t, result, Handshake_Result.Bad_Headers)
}

// A status line whose first token is not exactly `HTTP/1.1` fails as `.Bad_Status`,
// whether it names a different protocol entirely or an older HTTP version.
@(test)
test_parse_upgrade_response_bad_http_version :: proc(t: ^testing.T) {
    key := "dGhlIHNhbXBsZSBub25jZQ=="

    not_http :=
        "FOO 101 Switching Protocols\r\n" +
        "Upgrade: websocket\r\n" +
        "Connection: Upgrade\r\n" +
        "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n" +
        "\r\n"

    result, _, status := parse_upgrade_response(transmute([]byte)not_http, transmute([]byte)key)

    testing.expect_value(t, status, Response_Status.Ready)
    testing.expect_value(t, result, Handshake_Result.Bad_Status)

    http_1_0 :=
        "HTTP/1.0 101 Switching Protocols\r\n" +
        "Upgrade: websocket\r\n" +
        "Connection: Upgrade\r\n" +
        "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n" +
        "\r\n"

    result2, _, status2 := parse_upgrade_response(transmute([]byte)http_1_0, transmute([]byte)key)

    testing.expect_value(t, status2, Response_Status.Ready)
    testing.expect_value(t, result2, Handshake_Result.Bad_Status)
}

// A status line with no reason phrase at all is still a valid two-token status
// line per RFC 7230 (an empty reason phrase is allowed); the code is still
// resolvable, so this must succeed.
@(test)
test_parse_upgrade_response_status_line_no_reason_phrase :: proc(t: ^testing.T) {
    key := "dGhlIHNhbXBsZSBub25jZQ=="
    response :=
        "HTTP/1.1 101\r\n" +
        "Upgrade: websocket\r\n" +
        "Connection: Upgrade\r\n" +
        "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n" +
        "\r\n"

    result, _, status := parse_upgrade_response(transmute([]byte)response, transmute([]byte)key)

    testing.expect_value(t, status, Response_Status.Ready)
    testing.expect_value(t, result, Handshake_Result.Ok)
}

// A non-empty header line with no colon before the terminator is malformed and
// fails the parse rather than being silently skipped.
@(test)
test_parse_upgrade_response_malformed_header_line :: proc(t: ^testing.T) {
    key := "dGhlIHNhbXBsZSBub25jZQ=="
    response :=
        "HTTP/1.1 101 Switching Protocols\r\n" +
        "not-a-header-line\r\n" +
        "Upgrade: websocket\r\n" +
        "Connection: Upgrade\r\n" +
        "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n" +
        "\r\n"

    result, _, status := parse_upgrade_response(transmute([]byte)response, transmute([]byte)key)

    testing.expect_value(t, status, Response_Status.Ready)
    testing.expect_value(t, result, Handshake_Result.Bad_Headers)
}

// Required headers in an order different from the canonical fixture still parse:
// header order carries no protocol meaning.
@(test)
test_parse_upgrade_response_header_order_independent :: proc(t: ^testing.T) {
    key := "dGhlIHNhbXBsZSBub25jZQ=="
    response :=
        "HTTP/1.1 101 Switching Protocols\r\n" +
        "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n" +
        "Connection: Upgrade\r\n" +
        "Upgrade: websocket\r\n" +
        "\r\n"

    result, _, status := parse_upgrade_response(transmute([]byte)response, transmute([]byte)key)

    testing.expect_value(t, status, Response_Status.Ready)
    testing.expect_value(t, result, Handshake_Result.Ok)
}

// `Connection: Upgrade` with no other tokens is accepted.
@(test)
test_parse_upgrade_response_connection_upgrade_only :: proc(t: ^testing.T) {
    key := "dGhlIHNhbXBsZSBub25jZQ=="
    response :=
        "HTTP/1.1 101 Switching Protocols\r\n" +
        "Upgrade: websocket\r\n" +
        "Connection: Upgrade\r\n" +
        "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n" +
        "\r\n"

    result, _, status := parse_upgrade_response(transmute([]byte)response, transmute([]byte)key)

    testing.expect_value(t, status, Response_Status.Ready)
    testing.expect_value(t, result, Handshake_Result.Ok)
}

// `Connection: Upgrade, keep-alive` (Upgrade token listed first) is accepted.
@(test)
test_parse_upgrade_response_connection_upgrade_first_token :: proc(t: ^testing.T) {
    key := "dGhlIHNhbXBsZSBub25jZQ=="
    response :=
        "HTTP/1.1 101 Switching Protocols\r\n" +
        "Upgrade: websocket\r\n" +
        "Connection: Upgrade, keep-alive\r\n" +
        "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n" +
        "\r\n"

    result, _, status := parse_upgrade_response(transmute([]byte)response, transmute([]byte)key)

    testing.expect_value(t, status, Response_Status.Ready)
    testing.expect_value(t, result, Handshake_Result.Ok)
}

// A Connection value with no Upgrade token at all is rejected as `.Bad_Headers`.
@(test)
test_parse_upgrade_response_connection_missing_upgrade_token :: proc(t: ^testing.T) {
    key := "dGhlIHNhbXBsZSBub25jZQ=="
    response :=
        "HTTP/1.1 101 Switching Protocols\r\n" +
        "Upgrade: websocket\r\n" +
        "Connection: keep-alive\r\n" +
        "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n" +
        "\r\n"

    result, _, status := parse_upgrade_response(transmute([]byte)response, transmute([]byte)key)

    testing.expect_value(t, status, Response_Status.Ready)
    testing.expect_value(t, result, Handshake_Result.Bad_Headers)
}

// Feeding the same buffer incrementally — split mid status line, then mid header
// block, then the full response with pipelined trailing bytes — reports
// `.Need_More` until the terminator is buffered, then succeeds with the same
// `consumed` a single-shot parse would produce.
@(test)
test_parse_upgrade_response_incremental_chunks :: proc(t: ^testing.T) {
    key := "dGhlIHNhbXBsZSBub25jZQ=="
    response :=
        "HTTP/1.1 101 Switching Protocols\r\n" +
        "Upgrade: websocket\r\n" +
        "Connection: Upgrade\r\n" +
        "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n" +
        "\r\n" +
        "TRAILING"
    buf := transmute([]byte)response

    // Mid status line: "HTTP/1.1 1" of "HTTP/1.1 101 Switching Protocols\r\n...".
    result, consumed, status := parse_upgrade_response(buf[:10], transmute([]byte)key)
    testing.expect_value(t, status, Response_Status.Need_More)
    testing.expect_value(t, consumed, 0)

    // Mid header block: ends partway through the Connection header line.
    result, consumed, status = parse_upgrade_response(buf[:60], transmute([]byte)key)
    testing.expect_value(t, status, Response_Status.Need_More)
    testing.expect_value(t, consumed, 0)

    // Mid header block, further along: partway through the Accept header line.
    result, consumed, status = parse_upgrade_response(buf[:110], transmute([]byte)key)
    testing.expect_value(t, status, Response_Status.Need_More)
    testing.expect_value(t, consumed, 0)

    // Full header block plus pipelined trailing bytes.
    result, consumed, status = parse_upgrade_response(buf, transmute([]byte)key)
    testing.expect_value(t, status, Response_Status.Ready)
    testing.expect_value(t, result, Handshake_Result.Ok)
    testing.expect_value(t, string(buf)[consumed:], "TRAILING")
}
