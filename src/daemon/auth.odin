package daemon

import "core:crypto"
import "core:strings"
import http "libs:http"
import http_server "libs:http/server"

// Sanity ceiling on a configured token's length; well above any realistic credential.
MAX_AUTH_TOKEN_BYTES :: 4096

// Authentication result for one syntactically valid request.
Auth_Result :: enum {
    // No token is configured; every request is admitted.
    Disabled,

    // A matching token arrived in `Authorization: Bearer`.
    Header,

    // A matching token arrived in the `token` query parameter.
    Query,

    // A token is required and the request presented no credential.
    Missing,

    // A `Bearer` credential was presented and was wrong or malformed.
    Invalid,

    // `Authorization` used some other scheme. RFC 6750 §3.1 groups this with an absent
    // credential: the client is unaware of the scheme, so it gets no error code.
    Unsupported_Scheme,

    // More than one credential source, or a duplicate of one. Rejected rather than
    // resolved by precedence so no client can depend on an ordering rule.
    Ambiguous,
}

// `error` code on a refusal's challenge, per RFC 6750 §3.1.
Auth_Challenge :: enum {
    // No code: an absent credential or an unsupported scheme.
    None,

    // A credential that was presented and rejected.
    Invalid_Token,

    // A request that carried more than one credential source.
    Invalid_Request,
}

BEARER_CHALLENGE :: "Bearer realm=\"yuked\""
BEARER_CHALLENGE_INVALID_TOKEN :: "Bearer realm=\"yuked\", error=\"invalid_token\""
BEARER_CHALLENGE_INVALID_REQUEST :: "Bearer realm=\"yuked\", error=\"invalid_request\""
CACHE_PRIVATE :: "private, no-store"

// Refusal headers per challenge. The cache marker is last so `[:1]` is the challenge
// alone and `[:2]` adds the marker a `?token=` request needs (RFC 6750 §2.3).
@(rodata)
AUTH_CHALLENGE_HEADERS := [Auth_Challenge][2]http_server.Header {
    .None            = {
        {name = "WWW-Authenticate", value = BEARER_CHALLENGE},
        {name = "Cache-Control", value = CACHE_PRIVATE},
    },
    .Invalid_Token   = {
        {name = "WWW-Authenticate", value = BEARER_CHALLENGE_INVALID_TOKEN},
        {name = "Cache-Control", value = CACHE_PRIVATE},
    },
    .Invalid_Request = {
        {name = "WWW-Authenticate", value = BEARER_CHALLENGE_INVALID_REQUEST},
        {name = "Cache-Control", value = CACHE_PRIVATE},
    },
}

@(rodata)
AUTH_QUERY_HEADERS := [1]http_server.Header{{name = "Cache-Control", value = CACHE_PRIVATE}}

// Authenticate a request. Exactly one credential source is accepted; duplicate
// headers, duplicate query parameters, and header+query combinations are rejected as
// ambiguous rather than resolved by precedence. `query_credential` reports whether the
// request carried a `token` query parameter (present even when duplicate); it is
// computed on every path, including when auth is disabled, so the caller can mark
// every token-bearing response private.
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
        presented, parse := daemon_bearer_token(authorization)
        switch parse {
        case .Other_Scheme:
            return .Unsupported_Scheme, query_credential

        case .Malformed:
            return .Invalid, query_credential

        case .Ok:
            if !daemon_secret_equal(presented, d.auth_token) {
                return .Invalid, query_credential
            }
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

// Outcome of parsing an `Authorization` value. A different scheme and a malformed
// `Bearer` credential are distinct: only the latter earns an `invalid_token` challenge.
Bearer_Parse :: enum {
    // A syntactically valid `Bearer <token>`.
    Ok,

    // Some other authentication scheme.
    Other_Scheme,

    // The `Bearer` scheme with an unusable credential.
    Malformed,
}

// Extract credentials from `Authorization: Bearer <token>`. The scheme is
// case-insensitive and the separator is one or more spaces, as required by the
// HTTP authentication grammar.
daemon_bearer_token :: proc(value: string) -> (token: string, result: Bearer_Parse) {
    separator := strings.index_byte(value, ' ')
    if separator <= 0 {
        // No credential at all: a bare `Bearer` is a malformed one, anything else is
        // another scheme.
        return "", strings.equal_fold(value, "bearer") ? .Malformed : .Other_Scheme
    }

    if !strings.equal_fold(value[:separator], "bearer") {
        return "", .Other_Scheme
    }

    first := separator
    for first < len(value) && value[first] == ' ' {
        first += 1
    }

    if first == len(value) {
        return "", .Malformed
    }

    token = value[first:]
    for i in 0 ..< len(token) {
        if token[i] == ' ' || token[i] == '\t' {
            return "", .Malformed
        }
    }

    return token, .Ok
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

// Whether the request carried a `token` query parameter, present even when duplicated.
daemon_query_credential :: proc(query: string) -> bool {
    _, lookup := http.query_value(query, "token")
    return lookup != .Missing
}

// Cache-private headers when the request carried a `?token=` credential; nil otherwise.
daemon_query_response_headers :: proc(query: string) -> []http_server.Header {
    if daemon_query_credential(query) {
        return AUTH_QUERY_HEADERS[:]
    }

    return nil
}

// Challenge headers for a refused request, with the cache-private marker when a
// `?token=` credential was used.
daemon_auth_error_headers :: proc(result: Auth_Result, query_credential: bool) -> []http_server.Header {
    challenge: Auth_Challenge
    switch result {
    case .Missing, .Unsupported_Scheme:
        challenge = .None

    case .Invalid:
        challenge = .Invalid_Token

    case .Ambiguous:
        challenge = .Invalid_Request

    case .Disabled, .Header, .Query:
        assert(false, "auth challenge built for a result that is not a refusal")
    }

    row := &AUTH_CHALLENGE_HEADERS[challenge]
    assert(row[1].name == "Cache-Control", "the cache marker must stay last for the slice to select it")

    return row[:query_credential ? 2 : 1]
}
