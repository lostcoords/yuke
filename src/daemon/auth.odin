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

// Authenticate a request. Exactly one credential source is accepted; duplicate
// headers, duplicate query parameters, and header+query combinations are rejected as
// ambiguous rather than resolved by precedence.
authenticate :: proc(d: ^Daemon, head: http.Request_Head, query: string) -> Auth_Result {
    assert(d != nil, "authentication needs a daemon")

    if d.auth_token == "" {
        return .Disabled
    }

    assert(auth_token_valid(d.auth_token), "daemon retained an invalid auth token")
    assert(head.consumed == len(head.bytes), "authentication received an inconsistent parsed head")

    query_token, query_lookup := http.query_value(query, "token")

    authorization, header_lookup := http.request_header(head, "authorization")
    if header_lookup == .Duplicate || query_lookup == .Duplicate || header_lookup == .One && query_lookup == .One {
        return .Ambiguous
    }

    switch header_lookup {
    case .One:
        presented, parse := bearer_token(authorization)
        switch parse {
        case .Other_Scheme:
            return .Unsupported_Scheme

        case .Malformed:
            return .Invalid

        case .Ok:
            if !secret_equal(presented, d.auth_token) {
                return .Invalid
            }
        }

        return .Header

    case .Missing:

    case .Duplicate:
        return .Ambiguous
    }

    switch query_lookup {
    case .One:
        if !secret_equal(query_token, d.auth_token) {
            return .Invalid
        }

        return .Query

    case .Missing:
        return .Missing

    case .Duplicate:
        return .Ambiguous
    }

    return .Missing
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
bearer_token :: proc(value: string) -> (token: string, result: Bearer_Parse) {
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
auth_token_valid :: proc(token: string) -> bool {
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
secret_equal :: proc(presented: string, expected: string) -> bool {
    assert(len(expected) > 0, "comparing against an empty configured token")
    assert(auth_token_valid(expected), "comparing against an invalid configured token")

    return crypto.compare_constant_time(transmute([]byte)presented, transmute([]byte)expected) == 1
}

// `WWW-Authenticate` value for a refused request, per RFC 6750 §3.1.
auth_challenge :: proc(result: Auth_Result) -> string {
    BEARER :: "Bearer realm=\"yuked\""

    switch result {
    case .Missing, .Unsupported_Scheme:
        return BEARER

    case .Invalid:
        return BEARER + ", error=\"invalid_token\""

    case .Ambiguous:
        return BEARER + ", error=\"invalid_request\""

    case .Disabled, .Header, .Query:
        assert(false, "auth challenge built for a result that is not a refusal")
    }

    return ""
}
