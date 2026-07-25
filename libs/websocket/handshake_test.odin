package websocket

import "core:strings"
import "core:testing"
import http "libs:http"

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
        transmute([]byte)string("dGhlIHNhbXBsZSBub25jZQ=="),
        "",
        context.temp_allocator,
    )
    s := string(req)

    testing.expect(t, strings.has_prefix(s, "GET /ws HTTP/1.1\r\n"), "request line")
    testing.expect(t, strings.contains(s, "\r\nhost: 127.0.0.1:7880\r\n"), "host header")
    testing.expect(t, strings.contains(s, "\r\nupgrade: websocket\r\n"), "upgrade header")
    testing.expect(t, strings.contains(s, "\r\nconnection: Upgrade\r\n"), "connection header")
    testing.expect(t, strings.contains(s, "\r\nsec-websocket-version: 13\r\n"), "version header")
    testing.expect(t, strings.contains(s, "\r\nsec-websocket-key: dGhlIHNhbXBsZSBub25jZQ==\r\n"), "key header")
    testing.expect(t, strings.has_suffix(s, "\r\n\r\n"), "blank line terminator")
}

// A well-formed client upgrade request validates, returns the target and key
// (both borrowing the buffer), consumes exactly the header block, and leaves any
// pipelined trailing bytes (an eager first frame) for the caller.
@(test)
test_parse_upgrade_request_ok :: proc(t: ^testing.T) {
    request :=
        "GET /ws HTTP/1.1\r\n" +
        "Host: 127.0.0.1:7880\r\n" +
        "Upgrade: websocket\r\n" +
        "Connection: Upgrade\r\n" +
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" +
        "Sec-WebSocket-Version: 13\r\n" +
        "\r\n" +
        "TRAILING"

    req, result, consumed, status := parse_upgrade_request(transmute([]byte)request)

    testing.expect_value(t, status, Request_Status.Ready)
    testing.expect_value(t, result, Handshake_Result.Ok)
    testing.expect_value(t, req.path, "/ws")
    testing.expect_value(t, req.key, "dGhlIHNhbXBsZSBub25jZQ==")
    testing.expect_value(t, string(transmute([]byte)request)[consumed:], "TRAILING")
}

// A caller that already ran `http.parse_request_head` (e.g. a dispatcher routing
// by request line) validates the same request through `parse_upgrade_request_head`
// without re-parsing, and gets the same result as the byte-parsing wrapper.
@(test)
test_parse_upgrade_request_head_ok :: proc(t: ^testing.T) {
    request :=
        "GET /ws HTTP/1.1\r\n" +
        "Host: 127.0.0.1:7880\r\n" +
        "Upgrade: websocket\r\n" +
        "Connection: Upgrade\r\n" +
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" +
        "Sec-WebSocket-Version: 13\r\n" +
        "\r\n"

    head, head_status, head_err := http.parse_request_head(transmute([]byte)request)
    testing.expect_value(t, head_status, http.Head_Status.Ready)
    testing.expect_value(t, head_err, http.Head_Error.None)

    req, result := parse_upgrade_request_head(head)

    testing.expect_value(t, result, Handshake_Result.Ok)
    testing.expect_value(t, req.path, "/ws")
    testing.expect_value(t, req.key, "dGhlIHNhbXBsZSBub25jZQ==")
}

// Header names and the upgrade/connection tokens are matched case-insensitively;
// only the method, HTTP version, and version value are exact.
@(test)
test_parse_upgrade_request_case_insensitive :: proc(t: ^testing.T) {
    request :=
        "GET / HTTP/1.1\r\n" +
        "HOST: example.com\r\n" +
        "UPGRADE: WebSocket\r\n" +
        "CONNECTION: keep-alive, Upgrade\r\n" +
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" +
        "Sec-WebSocket-Version: 13\r\n" +
        "\r\n"

    req, result, _, status := parse_upgrade_request(transmute([]byte)request)

    testing.expect_value(t, status, Request_Status.Ready)
    testing.expect_value(t, result, Handshake_Result.Ok)
    testing.expect_value(t, req.path, "/")
}

// A request with no header terminator yet reports `.Need_More`, not failure.
@(test)
test_parse_upgrade_request_need_more :: proc(t: ^testing.T) {
    partial := "GET /ws HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\n"

    _, result, consumed, status := parse_upgrade_request(transmute([]byte)partial)

    testing.expect_value(t, status, Request_Status.Need_More)
    testing.expect_value(t, consumed, 0)
    testing.expect_value(t, result, Handshake_Result.Ok) // result is unused while Need_More
}

// A non-GET method fails the request line as `.Bad_Status`.
@(test)
test_parse_upgrade_request_bad_method :: proc(t: ^testing.T) {
    request :=
        "POST /ws HTTP/1.1\r\n" +
        "Host: x\r\n" +
        "Upgrade: websocket\r\n" +
        "Connection: Upgrade\r\n" +
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" +
        "Sec-WebSocket-Version: 13\r\n" +
        "\r\n"

    _, result, _, status := parse_upgrade_request(transmute([]byte)request)

    testing.expect_value(t, status, Request_Status.Ready)
    testing.expect_value(t, result, Handshake_Result.Bad_Status)
}

// An HTTP version other than 1.1 fails the request line as `.Bad_Status`.
@(test)
test_parse_upgrade_request_bad_version_line :: proc(t: ^testing.T) {
    request :=
        "GET /ws HTTP/1.0\r\n" +
        "Host: x\r\n" +
        "Upgrade: websocket\r\n" +
        "Connection: Upgrade\r\n" +
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" +
        "Sec-WebSocket-Version: 13\r\n" +
        "\r\n"

    _, result, _, status := parse_upgrade_request(transmute([]byte)request)

    testing.expect_value(t, status, Request_Status.Ready)
    testing.expect_value(t, result, Handshake_Result.Bad_Status)
}

// Each required header, when absent, yields `.Missing_Headers`.
@(test)
test_parse_upgrade_request_missing_each_header :: proc(t: ^testing.T) {
    cases := []string {
        // missing Host
        "GET /ws HTTP/1.1\r\n" +
        "Upgrade: websocket\r\n" +
        "Connection: Upgrade\r\n" +
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" +
        "Sec-WebSocket-Version: 13\r\n" +
        "\r\n",
        // missing Upgrade
        "GET /ws HTTP/1.1\r\n" +
        "Host: x\r\n" +
        "Connection: Upgrade\r\n" +
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" +
        "Sec-WebSocket-Version: 13\r\n" +
        "\r\n",
        // missing Connection
        "GET /ws HTTP/1.1\r\n" +
        "Host: x\r\n" +
        "Upgrade: websocket\r\n" +
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" +
        "Sec-WebSocket-Version: 13\r\n" +
        "\r\n",
        // missing Sec-WebSocket-Key
        "GET /ws HTTP/1.1\r\n" +
        "Host: x\r\n" +
        "Upgrade: websocket\r\n" +
        "Connection: Upgrade\r\n" +
        "Sec-WebSocket-Version: 13\r\n" +
        "\r\n",
        // missing Sec-WebSocket-Version
        "GET /ws HTTP/1.1\r\n" +
        "Host: x\r\n" +
        "Upgrade: websocket\r\n" +
        "Connection: Upgrade\r\n" +
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" +
        "\r\n",
    }

    for request in cases {
        _, result, _, status := parse_upgrade_request(transmute([]byte)request)
        testing.expect_value(t, status, Request_Status.Ready)
        testing.expect_value(t, result, Handshake_Result.Missing_Headers)
    }
}

// Each required header, when duplicated, is rejected as `.Bad_Headers` even when
// both instances agree — a request-smuggling defense mirroring the response parser.
@(test)
test_parse_upgrade_request_duplicate_each_header :: proc(t: ^testing.T) {
    cases := []string {
        // duplicate Host
        "GET /ws HTTP/1.1\r\n" +
        "Host: x\r\n" +
        "Host: x\r\n" +
        "Upgrade: websocket\r\n" +
        "Connection: Upgrade\r\n" +
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" +
        "Sec-WebSocket-Version: 13\r\n" +
        "\r\n",
        // duplicate Upgrade
        "GET /ws HTTP/1.1\r\n" +
        "Host: x\r\n" +
        "Upgrade: websocket\r\n" +
        "Upgrade: websocket\r\n" +
        "Connection: Upgrade\r\n" +
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" +
        "Sec-WebSocket-Version: 13\r\n" +
        "\r\n",
        // duplicate Connection
        "GET /ws HTTP/1.1\r\n" +
        "Host: x\r\n" +
        "Upgrade: websocket\r\n" +
        "Connection: Upgrade\r\n" +
        "Connection: Upgrade\r\n" +
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" +
        "Sec-WebSocket-Version: 13\r\n" +
        "\r\n",
        // duplicate Sec-WebSocket-Key
        "GET /ws HTTP/1.1\r\n" +
        "Host: x\r\n" +
        "Upgrade: websocket\r\n" +
        "Connection: Upgrade\r\n" +
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" +
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" +
        "Sec-WebSocket-Version: 13\r\n" +
        "\r\n",
        // duplicate Sec-WebSocket-Version
        "GET /ws HTTP/1.1\r\n" +
        "Host: x\r\n" +
        "Upgrade: websocket\r\n" +
        "Connection: Upgrade\r\n" +
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" +
        "Sec-WebSocket-Version: 13\r\n" +
        "Sec-WebSocket-Version: 13\r\n" +
        "\r\n",
    }

    for request in cases {
        _, result, _, status := parse_upgrade_request(transmute([]byte)request)
        testing.expect_value(t, status, Request_Status.Ready)
        testing.expect_value(t, result, Handshake_Result.Bad_Headers)
    }
}

// A Sec-WebSocket-Key that is not exactly 24 base64 characters is rejected.
@(test)
test_parse_upgrade_request_bad_key_length :: proc(t: ^testing.T) {
    request :=
        "GET /ws HTTP/1.1\r\n" +
        "Host: x\r\n" +
        "Upgrade: websocket\r\n" +
        "Connection: Upgrade\r\n" +
        "Sec-WebSocket-Key: tooshort\r\n" +
        "Sec-WebSocket-Version: 13\r\n" +
        "\r\n"

    _, result, consumed, status := parse_upgrade_request(transmute([]byte)request)

    testing.expect_value(t, status, Request_Status.Ready)
    testing.expect_value(t, result, Handshake_Result.Bad_Headers)
    testing.expect_value(t, consumed, len(request))
}

// A key of the right length but containing a non-base64 character is rejected.
@(test)
test_parse_upgrade_request_bad_key_charset :: proc(t: ^testing.T) {
    request :=
        "GET /ws HTTP/1.1\r\n" +
        "Host: x\r\n" +
        "Upgrade: websocket\r\n" +
        "Connection: Upgrade\r\n" +
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25j!!==\r\n" +
        "Sec-WebSocket-Version: 13\r\n" +
        "\r\n" // 24 chars, '!' illegal

    _, result, _, status := parse_upgrade_request(transmute([]byte)request)

    testing.expect_value(t, status, Request_Status.Ready)
    testing.expect_value(t, result, Handshake_Result.Bad_Headers)
}

@(test)
test_parse_upgrade_request_rejects_bad_or_noncanonical_key_padding :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    cases := []string{"dGhlIHNhbXBsZSBub25jZQ=A", "dGhlIHNhbXBsZSBub25jZR==", "=GhlIHNhbXBsZSBub25jZQ=="}

    for key in cases {
        request := strings.concatenate(
            {
                "GET /ws HTTP/1.1\r\n",
                "Host: example.test\r\n",
                "Upgrade: websocket\r\n",
                "Connection: Upgrade\r\n",
                "Sec-WebSocket-Key: ",
                key,
                "\r\nSec-WebSocket-Version: 13\r\n\r\n",
            },
            context.temp_allocator,
        )
        _, result, _, status := parse_upgrade_request(transmute([]byte)request)

        testing.expect_value(t, status, Request_Status.Ready)
        testing.expect_value(t, result, Handshake_Result.Bad_Headers)
    }
}

// A Sec-WebSocket-Version other than 13 is rejected as `.Bad_Headers`.
@(test)
test_parse_upgrade_request_wrong_version_value :: proc(t: ^testing.T) {
    request :=
        "GET /ws HTTP/1.1\r\n" +
        "Host: x\r\n" +
        "Upgrade: websocket\r\n" +
        "Connection: Upgrade\r\n" +
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" +
        "Sec-WebSocket-Version: 8\r\n" +
        "\r\n"

    _, result, _, status := parse_upgrade_request(transmute([]byte)request)

    testing.expect_value(t, status, Request_Status.Ready)
    testing.expect_value(t, result, Handshake_Result.Bad_Headers)
}

// A Connection value with no Upgrade token is rejected as `.Bad_Headers`.
@(test)
test_parse_upgrade_request_connection_missing_upgrade_token :: proc(t: ^testing.T) {
    request :=
        "GET /ws HTTP/1.1\r\n" +
        "Host: x\r\n" +
        "Upgrade: websocket\r\n" +
        "Connection: keep-alive\r\n" +
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" +
        "Sec-WebSocket-Version: 13\r\n" +
        "\r\n"

    _, result, _, status := parse_upgrade_request(transmute([]byte)request)

    testing.expect_value(t, status, Request_Status.Ready)
    testing.expect_value(t, result, Handshake_Result.Bad_Headers)
}

// A non-empty header line with no colon before the terminator is malformed and
// fails the parse rather than being silently skipped.
@(test)
test_parse_upgrade_request_malformed_header_line :: proc(t: ^testing.T) {
    request :=
        "GET /ws HTTP/1.1\r\n" +
        "not-a-header-line\r\n" +
        "Host: x\r\n" +
        "Upgrade: websocket\r\n" +
        "Connection: Upgrade\r\n" +
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" +
        "Sec-WebSocket-Version: 13\r\n" +
        "\r\n"

    _, result, consumed, status := parse_upgrade_request(transmute([]byte)request)

    testing.expect_value(t, status, Request_Status.Ready)
    testing.expect_value(t, result, Handshake_Result.Bad_Headers)
    testing.expect_value(t, consumed, len(request))
}

// Required headers in a different order still parse: header order carries no meaning.
@(test)
test_parse_upgrade_request_header_order_independent :: proc(t: ^testing.T) {
    request :=
        "GET /ws HTTP/1.1\r\n" +
        "Sec-WebSocket-Version: 13\r\n" +
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" +
        "Connection: Upgrade\r\n" +
        "Upgrade: websocket\r\n" +
        "Host: x\r\n" +
        "\r\n"

    _, result, _, status := parse_upgrade_request(transmute([]byte)request)

    testing.expect_value(t, status, Request_Status.Ready)
    testing.expect_value(t, result, Handshake_Result.Ok)
}

// Feeding the same request incrementally — split mid request line, then mid header
// block at two points — reports `.Need_More` until the terminator is buffered, then
// succeeds with the same `consumed` a single-shot parse would produce.
@(test)
test_parse_upgrade_request_incremental_chunks :: proc(t: ^testing.T) {
    request :=
        "GET /ws HTTP/1.1\r\n" +
        "Host: 127.0.0.1:7880\r\n" +
        "Upgrade: websocket\r\n" +
        "Connection: Upgrade\r\n" +
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" +
        "Sec-WebSocket-Version: 13\r\n" +
        "\r\n" +
        "TRAILING"
    buf := transmute([]byte)request

    // Mid request line.
    _, _, consumed, status := parse_upgrade_request(buf[:10])
    testing.expect_value(t, status, Request_Status.Need_More)
    testing.expect_value(t, consumed, 0)

    // Mid header block, early.
    _, _, consumed, status = parse_upgrade_request(buf[:60])
    testing.expect_value(t, status, Request_Status.Need_More)
    testing.expect_value(t, consumed, 0)

    // Mid header block, partway through the Key line.
    _, _, consumed, status = parse_upgrade_request(buf[:100])
    testing.expect_value(t, status, Request_Status.Need_More)
    testing.expect_value(t, consumed, 0)

    // Full header block plus pipelined trailing bytes.
    req, result, consumed2, status2 := parse_upgrade_request(buf)
    testing.expect_value(t, status2, Request_Status.Ready)
    testing.expect_value(t, result, Handshake_Result.Ok)
    testing.expect_value(t, req.key, "dGhlIHNhbXBsZSBub25jZQ==")
    testing.expect_value(t, string(buf)[consumed2:], "TRAILING")
}

// The 101 response built from the RFC 6455 §1.3 sample key carries the sample
// accept value and validates back through the client-side response parser.
@(test)
test_build_upgrade_response_round_trip :: proc(t: ^testing.T) {
    key := "dGhlIHNhbXBsZSBub25jZQ=="

    response := build_upgrade_response(transmute([]byte)key, context.temp_allocator)
    s := string(response)

    testing.expect(t, strings.has_prefix(s, "HTTP/1.1 101 Switching Protocols\r\n"), "status line")
    testing.expect(
        t,
        strings.contains(s, "sec-websocket-accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n"),
        "accept header carries the RFC vector",
    )
    testing.expect(t, strings.has_suffix(s, "\r\n\r\n"), "blank line terminator")

    // The client-side parser accepts the server's own response for the same key.
    result, _, status := parse_upgrade_response(response, transmute([]byte)key)
    testing.expect_value(t, status, Response_Status.Ready)
    testing.expect_value(t, result, Handshake_Result.Ok)
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

    result, consumed, status := parse_upgrade_response(transmute([]byte)response, transmute([]byte)key)

    testing.expect_value(t, status, Response_Status.Ready)
    testing.expect_value(t, result, Handshake_Result.Bad_Headers)
    testing.expect_value(t, consumed, len(response))
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

// An empty reason phrase is valid, but RFC 9112 still requires the separating
// space after the status code.
@(test)
test_parse_upgrade_response_status_line_no_reason_phrase :: proc(t: ^testing.T) {
    key := "dGhlIHNhbXBsZSBub25jZQ=="
    response :=
        "HTTP/1.1 101 \r\n" +
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

    result, consumed, status := parse_upgrade_response(transmute([]byte)response, transmute([]byte)key)

    testing.expect_value(t, status, Response_Status.Ready)
    testing.expect_value(t, result, Handshake_Result.Bad_Headers)
    testing.expect_value(t, consumed, len(response))
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
