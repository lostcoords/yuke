package websocket

import "core:crypto/legacy/sha1"
import "core:encoding/base64"
import "core:fmt"
import "core:strings"

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

// Validation outcome of a complete upgrade response (HTTP layer).
Handshake_Result :: enum {
    // 101 with all required upgrade headers present and correct.
    Ok,

    // Status line was not `101 Switching Protocols`.
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
) {
    text := fmt.aprintf(
        "GET %s HTTP/1.1\r\n" +
        "host: %s\r\n" +
        "upgrade: websocket\r\n" +
        "connection: Upgrade\r\n" +
        "sec-websocket-version: 13\r\n" +
        "sec-websocket-key: %s\r\n" +
        "%s\r\n",
        path,
        host_header,
        string(key_encoded),
        extra_headers,
        allocator = allocator,
    )

    return transmute([]byte)text
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
    end := index_of_header_terminator(buf)
    if end < 0 {
        return .Ok, 0, .Need_More
    }

    consumed = end + 4
    head := string(buf[:end])

    // Status line first, then CRLF-separated header lines.
    line, rest := next_line(head)
    if !status_is_switching_protocols(line) {
        return .Bad_Status, consumed, .Ready
    }

    accept_buf: [SEC_WEBSOCKET_ACCEPT_ENCODED_BYTES]byte
    expected_accept := string(make_sec_websocket_accept(key_encoded, accept_buf[:]))

    seen_upgrade, seen_connection, seen_accept := false, false, false

    for len(rest) > 0 {
        line, rest = next_line(rest)
        name, value, ok := split_header(line)
        if !ok {
            // A non-empty line before the terminator with no colon is malformed.
            return .Bad_Headers, consumed, .Ready
        }

        switch {
        case strings.equal_fold(name, "upgrade"):
            if seen_upgrade || !strings.equal_fold(value, "websocket") {
                return .Bad_Headers, consumed, .Ready
            }

            seen_upgrade = true

        case strings.equal_fold(name, "connection"):
            if seen_connection || !connection_has_upgrade(value) {
                return .Bad_Headers, consumed, .Ready
            }

            seen_connection = true

        case strings.equal_fold(name, "sec-websocket-accept"):
            if seen_accept || value != expected_accept {
                return .Bad_Headers, consumed, .Ready
            }

            seen_accept = true
        }
    }

    if !(seen_upgrade && seen_connection && seen_accept) {
        return .Missing_Headers, consumed, .Ready
    }

    return .Ok, consumed, .Ready
}

// Index of the `\r\n\r\n` header terminator, or -1 if not yet buffered.
index_of_header_terminator :: proc(buf: []byte) -> int {
    return strings.index(string(buf), "\r\n\r\n")
}

// Split the leading CRLF-terminated line from `s`, returning it and the remainder.
// A final line without a trailing CRLF is returned whole with an empty remainder.
next_line :: proc(s: string) -> (line: string, rest: string) {
    idx := strings.index(s, "\r\n")
    if idx < 0 {
        return s, ""
    }

    return s[:idx], s[idx + 2:]
}

// True when `line` is an HTTP status line reporting `101` on HTTP/1.1.
status_is_switching_protocols :: proc(line: string) -> bool {
    // Expect `HTTP/1.1 101 Switching Protocols`; the code is the second field.
    // RFC 6455 §4.1 requires HTTP >= 1.1, and 1.1 is the only upgrade version.
    after_version := strings.index_byte(line, ' ')
    if after_version < 0 {
        return false
    }

    if line[:after_version] != "HTTP/1.1" {
        return false
    }

    rest := strings.trim_left_space(line[after_version + 1:])
    code_end := strings.index_byte(rest, ' ')
    if code_end < 0 {
        code_end = len(rest)
    }

    return rest[:code_end] == "101"
}

// Split `line` into a header name and its whitespace-trimmed value at the first
// colon. ok is false when the line has no colon.
split_header :: proc(line: string) -> (name: string, value: string, ok: bool) {
    colon := strings.index_byte(line, ':')
    if colon < 0 {
        return "", "", false
    }

    return line[:colon], strings.trim_space(line[colon + 1:]), true
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

        if strings.equal_fold(strings.trim_space(token), "upgrade") {
            return true
        }
    }

    return false
}
