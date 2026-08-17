package provider

import "base:runtime"
import "core:strconv"
import "core:strings"
import "libs:bindings/curl"
import "src:wire"

// Path appended to `Endpoint.base_url` for each protocol's streaming call.
@(rodata)
protocol_path := [wire.Provider_Protocol]string {
    .Anthropic_Messages = "/messages",
    .Openai_Chat        = "/chat/completions",
    .Openai_Responses   = "/responses",
}

// Header value pinned for every Anthropic Messages request, including
// Anthropic-compatible third parties.
ANTHROPIC_VERSION :: "2023-06-01"

// The only host that takes the `x-api-key` credential form; every other host
// speaking Anthropic Messages is a compatible third party and takes Bearer.
ANTHROPIC_HOST :: "api.anthropic.com"
CODEX_BASE_URL :: "https://chatgpt.com/backend-api/codex"

// xAI's OpenAI-compatible API. The Grok/X subscription OAuth token authenticates
// here directly as a bearer with no account header; this pins the only host the
// token may be sent to.
XAI_API_BASE_URL :: "https://api.x.ai/v1"

// API key credential. The value is a resolved secret and never leaves this
// package except as a request header.
Api_Key :: struct {
    // Credential as configured, sent verbatim.
    key: string,
}

// ChatGPT-account OAuth credential for the first-party Codex backend. Both
// values come from the private daemon credential store.
Codex_OAuth :: struct {
    access_token: string,
    account_id:   string,
}

// Grok/X subscription OAuth credential for xAI's API. The access token comes from
// the private daemon credential store; unlike Codex it carries no account id.
Xai_OAuth :: struct {
    access_token: string,
}

// Resolved credential for an endpoint. A nil `Auth` is an endpoint that takes
// no credential at all (a local runtime).
Auth :: union {
    Api_Key,
    Codex_OAuth,
    Xai_OAuth,
}

// A resolved provider endpoint. Model selection happens above the transport, so
// nothing here describes a model.
Endpoint :: struct {
    // Absolute base URL with no trailing slash, e.g. `https://api.anthropic.com/v1`.
    // `protocol_path` is appended to it.
    base_url: string,

    // Streaming protocol this base URL speaks.
    protocol: wire.Provider_Protocol,
}

// Endpoint plus its resolved credential. Keeping the pair together prevents a
// credential resolved for one provider from being sent to another endpoint.
Connection :: struct {
    // Destination and streaming protocol.
    endpoint: Endpoint,

    // Credential resolved for this endpoint; nil for an unauthenticated runtime.
    auth:     Auth,
}

// Why an endpoint is not a valid resolved provider destination.
Endpoint_Validation_Error :: enum {
    // Valid endpoint.
    None,

    // No base URL was configured.
    Empty_Base_Url,

    // Protocol is outside the closed wire set.
    Invalid_Protocol,

    // Only absolute HTTP and HTTPS URLs are supported.
    Invalid_Scheme,

    // Host, brackets, or port are malformed.
    Invalid_Authority,

    // Credentials in the URL authority are forbidden.
    Userinfo_Not_Allowed,

    // A base URL cannot carry request-specific query or fragment data.
    Query_Or_Fragment_Not_Allowed,

    // Protocol paths are appended with their own leading slash.
    Trailing_Slash,
}

// Verify a configured endpoint before it becomes resolved internal state.
endpoint_validate :: proc(ep: Endpoint) -> Endpoint_Validation_Error {
    if len(ep.base_url) == 0 {
        return .Empty_Base_Url
    }

    protocol_index := int(ep.protocol)
    if protocol_index < 0 || protocol_index >= len(protocol_path) {
        return .Invalid_Protocol
    }

    if strings.index_any(ep.base_url, "?#") >= 0 {
        return .Query_Or_Fragment_Not_Allowed
    }

    if strings.has_suffix(ep.base_url, "/") {
        return .Trailing_Slash
    }

    scheme_end := strings.index(ep.base_url, "://")
    if scheme_end <= 0 {
        return .Invalid_Scheme
    }

    scheme := ep.base_url[:scheme_end]
    if !strings.equal_fold(scheme, "http") && !strings.equal_fold(scheme, "https") {
        return .Invalid_Scheme
    }

    authority := url_authority(ep.base_url)
    if len(authority) == 0 {
        return .Invalid_Authority
    }

    if strings.index_byte(authority, '@') >= 0 {
        return .Userinfo_Not_Allowed
    }

    for b in transmute([]byte)ep.base_url {
        if b <= ' ' || b == 0x7f {
            return .Invalid_Authority
        }
    }

    if len(url_host(ep.base_url)) == 0 {
        return .Invalid_Authority
    }

    return .None
}

// Full request URL for `ep`. Allocates into `allocator` and frees nothing.
endpoint_url :: proc(ep: Endpoint, allocator := context.allocator) -> (string, runtime.Allocator_Error) {
    assert(endpoint_validate(ep) == .None, "endpoint_url needs a validated endpoint")
    return strings.concatenate({ep.base_url, protocol_path[ep.protocol]}, allocator)
}

// Host of an absolute URL, without scheme, userinfo, port, or path; empty when
// `url` is malformed or has no host.
url_host :: proc(url: string) -> string {
    authority := url_authority(url)
    if len(authority) == 0 {
        return ""
    }

    if i := strings.last_index_byte(authority, '@'); i >= 0 {
        authority = authority[i + 1:]
    }

    if len(authority) == 0 {
        return ""
    }

    if authority[0] == '[' {
        close := strings.index_byte(authority, ']')
        if close <= 1 || !url_port_valid(authority[close + 1:]) {
            return ""
        }

        return authority[1:close]
    }

    colon := strings.index_byte(authority, ':')
    if colon >= 0 {
        if colon != strings.last_index_byte(authority, ':') || colon == 0 || !url_port_valid(authority[colon:]) {
            return ""
        }

        authority = authority[:colon]
    }

    return authority
}

// Authority of an absolute URL, borrowing `url`, or empty when absent.
@(private)
url_authority :: proc(url: string) -> string {
    scheme_end := strings.index(url, "://")
    if scheme_end <= 0 {
        return ""
    }

    authority := url[scheme_end + 3:]
    if end := strings.index_any(authority, "/?#"); end >= 0 {
        authority = authority[:end]
    }

    return authority
}

// Empty means no port. A present port is decimal and fits the URL port range.
@(private)
url_port_valid :: proc(suffix: string) -> bool {
    if len(suffix) == 0 {
        return true
    }

    if suffix[0] != ':' || len(suffix) == 1 {
        return false
    }

    port, ok := strconv.parse_uint(suffix[1:], 10)
    return ok && port <= 65535
}

// Does `url` name Anthropic's API host? DNS names are case-insensitive and a
// single trailing root dot names the same host.
@(private)
url_is_anthropic :: proc(url: string) -> bool {
    host := url_host(url)
    if strings.has_suffix(host, ".") {
        host = host[:len(host) - 1]
    }

    return strings.equal_fold(host, ANTHROPIC_HOST)
}

// Upper bound on the closed request-header set: content-type, accept, the
// optional anthropic-version, and one credential line. A stack buffer of this
// size holds every case, and curl copies the descriptors at transfer_start.
MAX_REQUEST_HEADERS :: 4

// Fill `out` with the protocol version and credential lines carried by
// `connection.auth`, returning the count written. Credential values are cloned
// into `allocator`; no value borrows the credential in `connection`. `out` holds
// at most two entries and may be caller stack storage.
@(private)
auth_headers :: proc(
    connection: Connection,
    out: []curl.Header,
    allocator: runtime.Allocator,
) -> (
    n: int,
    err: Transport_Error,
) {
    ep := connection.endpoint
    assert(endpoint_validate(ep) == .None, "auth_headers needs a validated endpoint")
    assert(len(out) >= 2, "auth header buffer holds the version and credential lines")

    if ep.protocol == .Anthropic_Messages {
        out[n] = {
            name  = "anthropic-version",
            value = ANTHROPIC_VERSION,
        }
        n += 1
    }

    switch a in connection.auth {
    case Api_Key:
        if len(a.key) == 0 {
            return 0, .Invalid_Request
        }

        credential: curl.Header
        if ep.protocol == .Anthropic_Messages && url_is_anthropic(ep.base_url) {
            value, clone_err := strings.clone(a.key, allocator)
            if clone_err != nil {
                return 0, .Resource_Exhausted
            }

            credential = {
                name  = "x-api-key",
                value = value,
            }
        } else {
            value, concat_err := strings.concatenate({"Bearer ", a.key}, allocator)
            if concat_err != nil {
                return 0, .Resource_Exhausted
            }

            credential = {
                name  = "Authorization",
                value = value,
            }
        }

        assert(len(credential.value) > 0, "a resolved credential produces a non-empty header value")
        out[n] = credential
        n += 1

    case Codex_OAuth:
        if ep.protocol != .Openai_Responses ||
           ep.base_url != CODEX_BASE_URL ||
           a.access_token == "" ||
           a.account_id == "" {
            return 0, .Invalid_Request
        }

        authorization, authorization_err := strings.concatenate({"Bearer ", a.access_token}, allocator)
        if authorization_err != nil {
            return 0, .Resource_Exhausted
        }

        account, account_err := strings.clone(a.account_id, allocator)
        if account_err != nil {
            delete(authorization, allocator)
            return 0, .Resource_Exhausted
        }

        out[n] = {
            name  = "Authorization",
            value = authorization,
        }
        n += 1
        out[n] = {
            name  = "ChatGPT-Account-ID",
            value = account,
        }
        n += 1

    case Xai_OAuth:
        if (ep.protocol != .Openai_Chat && ep.protocol != .Openai_Responses) ||
           ep.base_url != XAI_API_BASE_URL ||
           a.access_token == "" {
            return 0, .Invalid_Request
        }

        value, concat_err := strings.concatenate({"Bearer ", a.access_token}, allocator)
        if concat_err != nil {
            return 0, .Resource_Exhausted
        }

        out[n] = {
            name  = "Authorization",
            value = value,
        }
        n += 1

    case:
    }

    return n, .None
}
