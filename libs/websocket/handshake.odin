package websocket

import "base:runtime"
import "core:crypto/legacy/sha1"
import "core:encoding/base64"
import "core:strings"
import "libs:http"

// Raw Sec-WebSocket-Key length before base64 (RFC 6455 §4.1).
SEC_WEBSOCKET_KEY_BYTES :: 16

// Base64-encoded Sec-WebSocket-Key length: encoded_len(16) == 24.
SEC_WEBSOCKET_KEY_ENCODED_BYTES :: 24

// Base64-encoded Sec-WebSocket-Accept length: encoded_len(sha1 digest, 20) == 28.
SEC_WEBSOCKET_ACCEPT_ENCODED_BYTES :: 28

// Magic GUID concatenated with the client key before hashing (RFC 6455 §4.2.2).
WS_GUID :: "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

// Whether `parse_upgrade_response` saw a complete header block or needs more bytes.
Response_Status :: enum {
    // The header terminator was found; `Handshake_Result` and `consumed` are valid.
    Ready,

    // The `\r\n\r\n` terminator has not arrived yet; feed more bytes and retry.
    Need_More,
}

// Whether `parse_upgrade_request` saw a complete header block or needs more bytes.
Request_Status :: enum {
    // The header terminator was found; `Handshake_Result` and `consumed` are valid.
    Ready,

    // The `\r\n\r\n` terminator has not arrived yet; feed more bytes and retry.
    Need_More,
}

// Validation outcome of a complete upgrade handshake (HTTP layer), shared by the
// response and request parsers. For a request, `Bad_Status` reports a malformed
// start line (bad method or HTTP version) — the request-line analogue of a bad
// response status line.
Handshake_Result :: enum {
    // 101 (response) or a valid `GET` upgrade (request), all required headers present.
    Ok,

    // Start line was not `101 Switching Protocols` (response) or not a `GET` on
    // HTTP/1.1 (request).
    Bad_Status,

    // A header line had no colon, a required header duplicated, or a required
    // header had an invalid value.
    Bad_Headers,

    // A required upgrade header was absent.
    Missing_Headers,
}

// Derive Sec-WebSocket-Accept from a base64 key into `out`, returning the used
// prefix. `out` must hold `SEC_WEBSOCKET_ACCEPT_ENCODED_BYTES`. Computes
// base64(sha1(key_encoded ++ WS_GUID)).
make_sec_websocket_accept :: proc(key_encoded: []byte, out: []byte) -> []byte {
    assert(len(key_encoded) == SEC_WEBSOCKET_KEY_ENCODED_BYTES, "accept derivation needs a WebSocket key")
    assert(len(out) >= SEC_WEBSOCKET_ACCEPT_ENCODED_BYTES, "accept output buffer is too small")

    ctx: sha1.Context
    sha1.init(&ctx)
    sha1.update(&ctx, key_encoded)
    sha1.update(&ctx, transmute([]byte)string(WS_GUID))

    digest: [sha1.DIGEST_SIZE]byte
    sha1.final(&ctx, digest[:])

    encoded, _ := base64.encode_into_buf(out, digest[:])

    return encoded
}

// Build the HTTP upgrade request bytes for `path`, caller-owned.
// `host_header` is the full `Host:` value (e.g. `127.0.0.1:7880`); `key_encoded`
// is the base64 key verified against the response. `extra_headers`, if non-empty,
// is spliced verbatim and each line must end in CRLF. `host_header`, `path`, and
// `extra_headers` are spliced verbatim and must not contain CR/LF/control bytes —
// the caller validates them, not this proc. Free with `delete(request, allocator)`.
build_upgrade_request :: proc(
    path: string,
    host_header: string,
    key_encoded: []byte,
    extra_headers: string = "",
    allocator := context.allocator,
) -> (
    request: []byte,
    err: runtime.Allocator_Error,
) #optional_allocator_error {
    assert(http.request_target_valid(path), "upgrade request needs an origin-form target")
    assert(http.field_value_valid(host_header) && len(host_header) > 0, "upgrade request needs a valid Host value")
    assert(len(key_encoded) == SEC_WEBSOCKET_KEY_ENCODED_BYTES, "upgrade request needs a validated key")

    text := strings.concatenate(
        {
            "GET ",
            path,
            " HTTP/1.1\r\nhost: ",
            host_header,
            "\r\nupgrade: websocket\r\nconnection: Upgrade\r\nsec-websocket-version: 13\r\nsec-websocket-key: ",
            string(key_encoded),
            "\r\n",
            extra_headers,
            "\r\n",
        },
        allocator,
    ) or_return

    return transmute([]byte)text, nil
}

// Build a `101 Switching Protocols` response, with validated extra fields.
build_upgrade_response :: proc(
    key_encoded: []byte,
    allocator := context.allocator,
    extra_headers: []http.Header = nil,
) -> (
    response: []byte,
    err: runtime.Allocator_Error,
) #optional_allocator_error {
    assert(sec_websocket_key_valid(string(key_encoded)), "upgrade response needs a validated key")

    accept_buf: [SEC_WEBSOCKET_ACCEPT_ENCODED_BYTES]byte
    accept := make_sec_websocket_accept(key_encoded, accept_buf[:])
    total :=
        len(
            "HTTP/1.1 101 Switching Protocols\r\nupgrade: websocket\r\nconnection: Upgrade\r\nsec-websocket-accept: \r\n\r\n",
        ) +
        len(accept)
    for field, i in extra_headers {
        assert(
            http.field_name_valid(field.name) && http.field_value_valid(field.value),
            "invalid upgrade response field",
        )
        assert(!upgrade_response_reserved(field.name), "upgrade response field conflicts with handshake")

        for previous in extra_headers[:i] {
            assert(!strings.equal_fold(previous.name, field.name), "duplicate upgrade response field")
        }

        total += len(field.name) + 2 + len(field.value) + 2
    }

    response = make([]byte, total, allocator) or_return
    at := 0
    at += copy(
        response[at:],
        transmute([]byte)string(
            "HTTP/1.1 101 Switching Protocols\r\nupgrade: websocket\r\nconnection: Upgrade\r\nsec-websocket-accept: ",
        ),
    )
    at += copy(response[at:], accept)
    at += copy(response[at:], transmute([]byte)string("\r\n"))
    for field in extra_headers {
        at += copy(response[at:], transmute([]byte)field.name)
        at += copy(response[at:], transmute([]byte)string(": "))
        at += copy(response[at:], transmute([]byte)field.value)
        at += copy(response[at:], transmute([]byte)string("\r\n"))
    }
    at += copy(response[at:], transmute([]byte)string("\r\n"))
    assert(at == len(response), "upgrade response length mismatch")

    return response, nil
}

upgrade_response_reserved :: proc(name: string) -> bool {
    return(
        strings.equal_fold(name, "upgrade") ||
        strings.equal_fold(name, "connection") ||
        strings.equal_fold(name, "sec-websocket-accept") \
    )
}

// Validate a buffered upgrade response against the sent `key_encoded`. `consumed`
// stops at the `\r\n\r\n` terminator, leaving any pipelined bytes (often the first
// frame) for the caller to feed the decoder.
parse_upgrade_response :: proc(
    buf: []byte,
    key_encoded: []byte,
) -> (
    result: Handshake_Result,
    consumed: int,
    status: Response_Status,
) {
    head, head_status, head_err := http.parse_response_head(buf)
    if head_status == .Need_More do return .Ok, 0, .Need_More

    consumed = head.consumed
    switch head_err {
    case .None:

    case .Bad_Start_Line, .Unsupported_Version:
        return .Bad_Status, consumed, .Ready

    case .Bad_Header, .Missing_Host, .Duplicate_Host, .Unsupported_Target:
        return .Bad_Headers, consumed, .Ready
    }

    if head.status_code != 101 do return .Bad_Status, consumed, .Ready

    accept_buf: [SEC_WEBSOCKET_ACCEPT_ENCODED_BYTES]byte
    expected_accept := string(make_sec_websocket_accept(key_encoded, accept_buf[:]))

    upgrade, upgrade_lookup := http.response_header(head, "upgrade")
    connection, connection_lookup := http.response_header(head, "connection")
    accept, accept_lookup := http.response_header(head, "sec-websocket-accept")
    if upgrade_lookup == .Duplicate || connection_lookup == .Duplicate || accept_lookup == .Duplicate do return .Bad_Headers, consumed, .Ready

    if upgrade_lookup == .Missing || connection_lookup == .Missing || accept_lookup == .Missing do return .Missing_Headers, consumed, .Ready

    if !strings.equal_fold(upgrade, "websocket") || !connection_has_upgrade(connection) || accept != expected_accept do return .Bad_Headers, consumed, .Ready

    return .Ok, consumed, .Ready
}

// The parts a server needs from a validated client upgrade request. Both fields
// borrow the buffer passed to `parse_upgrade_request`/`parse_upgrade_request_head`
// and are valid only for that buffer's lifetime; copy them if they must outlive it
// (e.g. the key before deriving the accept, though `build_upgrade_response` can
// take it directly).
Upgrade_Request :: struct {
    // Request target from the `GET` line (e.g. `/ws`); borrows the input buffer.
    path: string,

    // Sec-WebSocket-Key value, exactly 24 base64 chars; borrows the input buffer.
    key:  string,
}

// Validate a buffered client upgrade request. `consumed` stops at the `\r\n\r\n`
// terminator, leaving any pipelined bytes (an eager first client frame) for the
// caller to feed a server-role decoder. Enforces RFC 6455 §4.1: a `GET` on
// HTTP/1.1, a Host header, `Upgrade: websocket`, a `Connection` list containing the
// `Upgrade` token, a 24-char base64 `Sec-WebSocket-Key`, and `Sec-WebSocket-Version:
// 13`. Any of these headers appearing twice is rejected as a request-smuggling
// defense, mirroring the response parser.
parse_upgrade_request :: proc(
    buf: []byte,
) -> (
    req: Upgrade_Request,
    result: Handshake_Result,
    consumed: int,
    status: Request_Status,
) {
    head, head_status, head_err := http.parse_request_head(buf)
    if head_status == .Need_More do return {}, .Ok, 0, .Need_More

    consumed = head.consumed
    switch head_err {
    case .None:

    case .Missing_Host:
        return {}, .Missing_Headers, consumed, .Ready

    case .Bad_Start_Line, .Unsupported_Version, .Unsupported_Target:
        return {}, .Bad_Status, consumed, .Ready

    case .Bad_Header, .Duplicate_Host:
        return {}, .Bad_Headers, consumed, .Ready
    }

    req, result = parse_upgrade_request_head(head)

    return req, result, consumed, .Ready
}

// Same validation as `parse_upgrade_request`, for a caller that already parsed the
// HTTP head (e.g. a front door dispatching by request line before recognizing the
// upgrade). `head` must come from a successful `http.parse_request_head`.
parse_upgrade_request_head :: proc(head: http.Request_Head) -> (req: Upgrade_Request, result: Handshake_Result) {
    if head.method != "GET" do return {}, .Bad_Status

    upgrade, upgrade_lookup := http.request_header(head, "upgrade")
    connection, connection_lookup := http.request_header(head, "connection")
    key, key_lookup := http.request_header(head, "sec-websocket-key")
    version, version_lookup := http.request_header(head, "sec-websocket-version")
    if upgrade_lookup == .Duplicate ||
       connection_lookup == .Duplicate ||
       key_lookup == .Duplicate ||
       version_lookup == .Duplicate {
        return {}, .Bad_Headers
    }

    if upgrade_lookup == .Missing ||
       connection_lookup == .Missing ||
       key_lookup == .Missing ||
       version_lookup == .Missing {
        return {}, .Missing_Headers
    }

    if !strings.equal_fold(upgrade, "websocket") ||
       !connection_has_upgrade(connection) ||
       !sec_websocket_key_valid(key) ||
       version != "13" {
        return {}, .Bad_Headers
    }

    return {path = head.target, key = key}, .Ok
}

// Whether `value` is a well-formed Sec-WebSocket-Key: exactly 24 characters (the
// canonical base64 encoding of a 16-byte nonce (RFC 6455 §4.1).
sec_websocket_key_valid :: proc(value: string) -> bool {
    if len(value) != SEC_WEBSOCKET_KEY_ENCODED_BYTES || value[22:] != "==" do return false

    for i in 0 ..< 22 {
        c := value[i]
        switch c {
        case 'A' ..= 'Z', 'a' ..= 'z', '0' ..= '9', '+', '/':
            continue

        case:
            return false
        }
    }

    raw: [SEC_WEBSOCKET_KEY_BYTES]byte
    decoded, decode_err := base64.decode_into_buf(raw[:], value)
    if decode_err != nil || len(decoded) != SEC_WEBSOCKET_KEY_BYTES do return false

    canonical: [SEC_WEBSOCKET_KEY_ENCODED_BYTES]byte
    encoded, encode_err := base64.encode_into_buf(canonical[:], raw[:])

    return encode_err == nil && string(encoded) == value
}

// True when a `Connection` header value contains the `upgrade` token (it may be
// a comma-separated list such as `keep-alive, Upgrade`).
connection_has_upgrade :: proc(value: string) -> bool {
    rest := value
    for len(rest) > 0 {
        token: string
        comma := strings.index_byte(rest, ',')
        if comma < 0 {
            token = rest
            rest = ""
        } else {
            token = rest[:comma]
            rest = rest[comma + 1:]
        }

        if strings.equal_fold(strings.trim_space(token), "upgrade") do return true
    }

    return false
}
