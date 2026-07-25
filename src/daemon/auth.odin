package daemon

import "core:crypto"
import "core:strings"
import http "libs:http"
import http_server "libs:http/server"

MAX_AUTH_TOKEN_BYTES :: 4096

// Authentication result for one syntactically valid request.
Auth_Result :: enum {
    Disabled,
    Header,
    Query,
    Missing,
    Invalid,
    Ambiguous,
}

@(rodata)
AUTH_CHALLENGE_HEADERS := [1]http_server.Header{{name = "WWW-Authenticate", value = "Bearer realm=\"yuked\""}}

@(rodata)
AUTH_QUERY_HEADERS := [1]http_server.Header{{name = "Cache-Control", value = "private, no-store"}}

@(rodata)
AUTH_QUERY_CHALLENGE_HEADERS := [2]http_server.Header {
    {name = "WWW-Authenticate", value = "Bearer realm=\"yuked\""},
    {name = "Cache-Control", value = "private, no-store"},
}

// Authenticate before route or method dispatch. Exactly one credential source is
// accepted; duplicate headers, duplicate query parameters, and header+query
// combinations are ambiguous rather than order-dependent. `query_credential` reports
// whether the request carried a `token` query parameter (present even when
// duplicate), so the caller can mark every token-bearing response private — including
// when authentication is disabled. It is computed on every path.
daemon_authenticate :: proc(
    d: ^Daemon,
    head: http.Request_Head,
    query: string,
) -> (
    result: Auth_Result,
    query_credential: bool,
) {
    assert(d != nil, "authentication needs a daemon")

    query_token, query_lookup := http.query_value(query, "token")
    query_credential = query_lookup != .Missing

    if d.auth_token == "" {
        return .Disabled, query_credential
    }

    assert(daemon_auth_token_valid(d.auth_token), "daemon retained an invalid auth token")
    assert(head.consumed == len(head.bytes), "authentication received an inconsistent parsed head")

    authorization, header_lookup := http.request_header(head, "authorization")
    if header_lookup == .Duplicate || query_lookup == .Duplicate || header_lookup == .One && query_lookup == .One {
        return .Ambiguous, query_credential
    }

    switch header_lookup {
    case .One:
        presented, ok := daemon_bearer_token(authorization)
        if !ok || !daemon_secret_equal(presented, d.auth_token) {
            return .Invalid, query_credential
        }

        return .Header, query_credential

    case .Missing:

    case .Duplicate:
        return .Ambiguous, query_credential
    }

    switch query_lookup {
    case .One:
        if !daemon_secret_equal(query_token, d.auth_token) {
            return .Invalid, query_credential
        }

        return .Query, query_credential

    case .Missing:
        return .Missing, query_credential

    case .Duplicate:
        return .Ambiguous, query_credential
    }

    return .Missing, query_credential
}

// Extract credentials from `Authorization: Bearer <token>`. The scheme is
// case-insensitive and the separator is one or more spaces, as required by the
// HTTP authentication grammar.
daemon_bearer_token :: proc(value: string) -> (token: string, ok: bool) {
    separator := strings.index_byte(value, ' ')
    if separator <= 0 || !strings.equal_fold(value[:separator], "bearer") {
        return "", false
    }

    first := separator
    for first < len(value) && value[first] == ' ' {
        first += 1
    }

    if first == len(value) {
        return "", false
    }

    token = value[first:]
    for i in 0 ..< len(token) {
        if token[i] == ' ' || token[i] == '\t' {
            return "", false
        }
    }

    return token, true
}

// Whether a configured token is directly safe in both a bearer field and an
// origin-form query without percent-encoding or normalization.
daemon_auth_token_valid :: proc(token: string) -> bool {
    if len(token) > MAX_AUTH_TOKEN_BYTES {
        return false
    }

    for i in 0 ..< len(token) {
        c := token[i]
        if !(c >= '0' && c <= '9' ||
               c >= 'A' && c <= 'Z' ||
               c >= 'a' && c <= 'z' ||
               c == '-' ||
               c == '.' ||
               c == '_' ||
               c == '~') {
            return false
        }
    }

    return true
}

// Constant-time token comparison; only the length is allowed to leak.
daemon_secret_equal :: proc(presented: string, expected: string) -> bool {
    assert(len(expected) > 0, "comparing against an empty configured token")
    assert(daemon_auth_token_valid(expected), "comparing against an invalid configured token")

    return crypto.compare_constant_time(transmute([]byte)presented, transmute([]byte)expected) == 1
}

daemon_response_headers :: proc(query_credential: bool) -> []http_server.Header {
    if query_credential {
        return AUTH_QUERY_HEADERS[:]
    }

    return nil
}

daemon_auth_error_headers :: proc(query_credential: bool) -> []http_server.Header {
    if query_credential {
        return AUTH_QUERY_CHALLENGE_HEADERS[:]
    }

    return AUTH_CHALLENGE_HEADERS[:]
}
