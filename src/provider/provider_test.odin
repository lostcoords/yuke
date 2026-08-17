package provider

import "core:strings"
import "core:testing"
import "libs:bindings/curl"
import "src:wire"

@(private = "file")
test_auth_headers :: proc(t: ^testing.T, connection: Connection) -> []curl.Header {
    out := make([]curl.Header, MAX_REQUEST_HEADERS, context.temp_allocator)
    n, err := auth_headers(connection, out, context.temp_allocator)
    testing.expect_value(t, err, Transport_Error.None)

    return out[:n]
}

@(test)
test_protocol_paths :: proc(t: ^testing.T) {
    testing.expect_value(t, protocol_path[.Anthropic_Messages], "/messages")
    testing.expect_value(t, protocol_path[.Openai_Chat], "/chat/completions")
    testing.expect_value(t, protocol_path[.Openai_Responses], "/responses")
}

@(test)
test_endpoint_url_appends_protocol_path :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    ep := Endpoint {
        base_url = "https://api.anthropic.com/v1",
        protocol = .Anthropic_Messages,
    }
    url := endpoint_url(ep, context.temp_allocator)
    testing.expect_value(t, url, "https://api.anthropic.com/v1/messages")

    ep = Endpoint {
        base_url = "https://api.openai.com/v1",
        protocol = .Openai_Chat,
    }
    url = endpoint_url(ep, context.temp_allocator)
    testing.expect_value(t, url, "https://api.openai.com/v1/chat/completions")
}

@(test)
test_endpoint_validation :: proc(t: ^testing.T) {
    Case :: struct {
        base_url: string,
        protocol: wire.Provider_Protocol,
        want:     Endpoint_Validation_Error,
    }

    cases := [?]Case {
        {"https://api.anthropic.com/v1", .Anthropic_Messages, .None},
        {"HTTP://127.0.0.1:11434/v1", .Openai_Chat, .None},
        {"http://[::1]:8080/v1", .Anthropic_Messages, .None},
        {"", .Openai_Chat, .Empty_Base_Url},
        {"api.openai.com/v1", .Openai_Chat, .Invalid_Scheme},
        {"ftp://api.openai.com/v1", .Openai_Chat, .Invalid_Scheme},
        {"https:///v1", .Openai_Chat, .Invalid_Authority},
        {"https://api.openai.com:bad/v1", .Openai_Chat, .Invalid_Authority},
        {"https://api.openai.com:65536/v1", .Openai_Chat, .Invalid_Authority},
        {"https://user:pass@api.openai.com/v1", .Openai_Chat, .Userinfo_Not_Allowed},
        {"https://api.openai.com/v1?tenant=x", .Openai_Chat, .Query_Or_Fragment_Not_Allowed},
        {"https://api.openai.com/v1#fragment", .Openai_Chat, .Query_Or_Fragment_Not_Allowed},
        {"https://api.openai.com/v1/", .Openai_Chat, .Trailing_Slash},
        {"https://api.openai.com/v 1", .Openai_Chat, .Invalid_Authority},
    }

    for c in cases {
        ep := Endpoint {
            base_url = c.base_url,
            protocol = c.protocol,
        }
        got := endpoint_validate(ep)
        testing.expectf(t, got == c.want, "%q must validate as %v, got %v", c.base_url, c.want, got)
    }

    invalid_protocol := Endpoint {
        base_url = "https://api.openai.com/v1",
        protocol = wire.Provider_Protocol(99),
    }
    testing.expect_value(t, endpoint_validate(invalid_protocol), Endpoint_Validation_Error.Invalid_Protocol)
}

@(test)
test_url_host_strips_scheme_port_and_path :: proc(t: ^testing.T) {
    Case :: struct {
        url:  string,
        host: string,
    }

    cases := [?]Case {
        {"https://api.anthropic.com/v1", "api.anthropic.com"},
        {"https://api.anthropic.com", "api.anthropic.com"},
        {"http://api.anthropic.com:8443/v1", "api.anthropic.com"},
        {"https://user:pass@api.anthropic.com/v1", "api.anthropic.com"},
        {"https://api.z.ai/api/anthropic", "api.z.ai"},
        {"http://127.0.0.1:11434/v1", "127.0.0.1"},
        {"http://[::1]/v1", "::1"},
        {"http://[::1]:8080/v1", "::1"},
        {"api.anthropic.com/v1", ""},
        {"https://[::1:8080/v1", ""},
        {"https://api.anthropic.com:bad/v1", ""},
        {"", ""},
        {"https://api.anthropic.com?x=1", "api.anthropic.com"},
    }

    for c in cases {
        testing.expectf(t, url_host(c.url) == c.host, "host of %q must be %q, got %q", c.url, c.host, url_host(c.url))
    }
}

// `x-api-key` is reserved for Anthropic's own host; the version pin is not.
@(test)
test_auth_headers_anthropic_official_host :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    ep := Endpoint {
        base_url = "https://api.anthropic.com/v1",
        protocol = .Anthropic_Messages,
    }

    got := test_auth_headers(t, Connection{endpoint = ep, auth = Api_Key{key = "sk-ant-secret"}})
    testing.expect_value(t, len(got), 2)
    testing.expect_value(t, got[0], curl.Header{name = "anthropic-version", value = "2023-06-01"})
    testing.expect_value(t, got[1], curl.Header{name = "x-api-key", value = "sk-ant-secret"})
}

// An Anthropic-compatible third party still gets the version pin, but Bearer.
@(test)
test_auth_headers_anthropic_compatible_host :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    ep := Endpoint {
        base_url = "https://api.z.ai/api/anthropic",
        protocol = .Anthropic_Messages,
    }

    got := test_auth_headers(t, Connection{endpoint = ep, auth = Api_Key{key = "zk-secret"}})
    testing.expect_value(t, len(got), 2)
    testing.expect_value(t, got[0], curl.Header{name = "anthropic-version", value = "2023-06-01"})
    testing.expect_value(t, got[1], curl.Header{name = "Authorization", value = "Bearer zk-secret"})
}

// A host that merely ends in the official one is not the official one.
@(test)
test_auth_headers_anthropic_lookalike_host_gets_bearer :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    ep := Endpoint {
        base_url = "https://evil-api.anthropic.com.example/v1",
        protocol = .Anthropic_Messages,
    }

    got := test_auth_headers(t, Connection{endpoint = ep, auth = Api_Key{key = "sk-ant-secret"}})
    testing.expect_value(t, len(got), 2)
    testing.expect_value(t, got[1], curl.Header{name = "Authorization", value = "Bearer sk-ant-secret"})
}

@(test)
test_auth_headers_openai_family_is_always_bearer :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    for protocol in ([?]wire.Provider_Protocol{.Openai_Chat, .Openai_Responses}) {
        ep := Endpoint {
            base_url = "https://api.openai.com/v1",
            protocol = protocol,
        }

        got := test_auth_headers(t, Connection{endpoint = ep, auth = Api_Key{key = "sk-openai"}})
        testing.expect_value(t, len(got), 1)
        testing.expect_value(t, got[0], curl.Header{name = "Authorization", value = "Bearer sk-openai"})
    }
}

@(test)
test_auth_headers_codex_oauth_is_bound_to_first_party_responses :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    auth := Codex_OAuth {
        access_token = "access-token",
        account_id   = "workspace-123",
    }
    connection := Connection {
        endpoint = Endpoint{base_url = CODEX_BASE_URL, protocol = .Openai_Responses},
        auth = auth,
    }
    got := test_auth_headers(t, connection)
    testing.expect_value(t, len(got), 2)
    testing.expect_value(t, got[0], curl.Header{name = "Authorization", value = "Bearer access-token"})
    testing.expect_value(t, got[1], curl.Header{name = "ChatGPT-Account-ID", value = "workspace-123"})

    for endpoint in ([?]Endpoint {
            {base_url = "https://api.openai.com/v1", protocol = .Openai_Responses},
            {base_url = CODEX_BASE_URL, protocol = .Openai_Chat},
        }) {
        out: [MAX_REQUEST_HEADERS]curl.Header
        n, err := auth_headers(Connection{endpoint = endpoint, auth = auth}, out[:], context.temp_allocator)
        testing.expect_value(t, err, Transport_Error.Invalid_Request)
        testing.expect_value(t, n, 0)
    }
}

// The xAI subscription OAuth token is a plain bearer bound to xAI's API host and
// the OpenAI-family protocols; anywhere else is a configuration error.
@(test)
test_auth_headers_xai_oauth_is_bound_to_subscription_api :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    auth := Xai_OAuth {
        access_token = "xai-access",
    }

    for protocol in ([?]wire.Provider_Protocol{.Openai_Chat, .Openai_Responses}) {
        connection := Connection {
            endpoint = Endpoint{base_url = XAI_API_BASE_URL, protocol = protocol},
            auth = auth,
        }
        got := test_auth_headers(t, connection)
        testing.expect_value(t, len(got), 1)
        testing.expect_value(t, got[0], curl.Header{name = "Authorization", value = "Bearer xai-access"})
    }

    for endpoint in ([?]Endpoint {
            {base_url = "https://api.openai.com/v1", protocol = .Openai_Responses},
            {base_url = XAI_API_BASE_URL, protocol = .Anthropic_Messages},
        }) {
        out: [MAX_REQUEST_HEADERS]curl.Header
        n, err := auth_headers(Connection{endpoint = endpoint, auth = auth}, out[:], context.temp_allocator)
        testing.expect_value(t, err, Transport_Error.Invalid_Request)
        testing.expect_value(t, n, 0)
    }

    out: [MAX_REQUEST_HEADERS]curl.Header
    empty := Connection {
        endpoint = Endpoint{base_url = XAI_API_BASE_URL, protocol = .Openai_Chat},
        auth = Xai_OAuth{},
    }
    n, err := auth_headers(empty, out[:], context.temp_allocator)
    testing.expect_value(t, err, Transport_Error.Invalid_Request)
    testing.expect_value(t, n, 0)
}

// The OpenAI protocols never send the Anthropic version pin, even when pointed
// at Anthropic's host.
@(test)
test_auth_headers_openai_on_anthropic_host_has_no_version_pin :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    ep := Endpoint {
        base_url = "https://api.anthropic.com/v1",
        protocol = .Openai_Chat,
    }

    got := test_auth_headers(t, Connection{endpoint = ep, auth = Api_Key{key = "sk-openai"}})
    testing.expect_value(t, len(got), 1)
    testing.expect_value(t, got[0], curl.Header{name = "Authorization", value = "Bearer sk-openai"})
}

// A local runtime with no credential still gets the protocol's fixed headers.
@(test)
test_auth_headers_without_credential :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    anthropic := Endpoint {
        base_url = "http://127.0.0.1:8080/v1",
        protocol = .Anthropic_Messages,
    }

    got := test_auth_headers(t, Connection{endpoint = anthropic})
    testing.expect_value(t, len(got), 1)
    testing.expect_value(t, got[0], curl.Header{name = "anthropic-version", value = "2023-06-01"})

    openai := Endpoint {
        base_url = "http://127.0.0.1:11434/v1",
        protocol = .Openai_Chat,
    }
    got = test_auth_headers(t, Connection{endpoint = openai})
    testing.expect_value(t, len(got), 0)
}

// An empty resolved key is a configuration error, not the unauthenticated
// encoding, which is a nil `Auth`.
@(test)
test_auth_headers_reject_empty_credential :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    for protocol in ([?]wire.Provider_Protocol{.Anthropic_Messages, .Openai_Chat}) {
        connection := Connection {
            endpoint = Endpoint{base_url = "https://api.anthropic.com/v1", protocol = protocol},
            auth = Api_Key{key = ""},
        }

        out: [MAX_REQUEST_HEADERS]curl.Header
        n, err := auth_headers(connection, out[:], context.temp_allocator)
        testing.expect_value(t, err, Transport_Error.Invalid_Request)
        testing.expect_value(t, n, 0)
    }
}

// DNS host spelling must not change Anthropic's credential form.
@(test)
test_auth_headers_anthropic_host_is_case_and_root_dot_insensitive :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    for base_url in ([?]string{"https://API.ANTHROPIC.COM/v1", "https://api.anthropic.com./v1"}) {
        connection := Connection {
            endpoint = Endpoint{base_url = base_url, protocol = .Anthropic_Messages},
            auth = Api_Key{key = "sk-ant-secret"},
        }
        got := test_auth_headers(t, connection)
        testing.expect_value(t, got[1], curl.Header{name = "x-api-key", value = "sk-ant-secret"})
    }
}

// Credential values are owned by the allocator, never a borrow of the caller's
// `Api_Key`, in either credential form.
@(test)
test_auth_headers_credential_values_are_allocator_owned :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    for base_url in ([?]string{"https://api.anthropic.com/v1", "https://api.z.ai/api/anthropic"}) {
        key, _ := strings.clone("sk-secret", context.temp_allocator)
        connection := Connection {
            endpoint = Endpoint{base_url = base_url, protocol = .Anthropic_Messages},
            auth = Api_Key{key = key},
        }

        got := test_auth_headers(t, connection)
        testing.expect_value(t, len(got), 2)
        testing.expectf(
            t,
            raw_data(got[1].value) != raw_data(key),
            "%s: the credential header must not borrow the resolved key",
            base_url,
        )
        testing.expect(t, strings.has_suffix(got[1].value, "sk-secret"), "the credential value must survive intact")
    }
}
