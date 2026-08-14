package daemon

import "core:net"
import "core:strings"

import http_server "libs:http/server"
import catalog "src:daemon/catalog"
import "src:daemon/oauth"
import provider "src:provider"

// Why a resolved model could not become a live provider connection.
Run_Bind_Error :: enum {
    None,
    Invalid_Endpoint,
    Missing_Credential,
}

// The endpoint validates before any credential is attached. A missing credential is a
// normal error, never an assertion.
run_connection_build :: proc(d: ^Daemon, model: ^catalog.Model) -> (provider.Connection, Run_Bind_Error) {
    assert(d != nil && model != nil, "connection build needs a daemon and a model")

    endpoint := model.endpoint
    if provider.endpoint_validate(endpoint) != .None {
        return {}, .Invalid_Endpoint
    }

    auth, bind_err := run_credential_bind(d, model.info.provider)

    // A model server on this machine authenticates nothing, so a missing credential is
    // not an error there. Every routable endpoint still requires one.
    if bind_err == .Missing_Credential && endpoint_is_loopback(endpoint) {
        auth, bind_err = nil, .None
    }
    if bind_err != .None {
        return {}, bind_err
    }

    return {endpoint = endpoint, auth = auth}, .None
}

// Whether an endpoint addresses this machine. `localhost` and the reserved `.localhost`
// suffix count without a lookup; anything else must parse as a loopback IP literal.
endpoint_is_loopback :: proc(endpoint: provider.Endpoint) -> bool {
    host := provider.url_host(endpoint.base_url)
    if host == "" {
        return false
    }

    if strings.has_suffix(host, ".") {
        host = host[:len(host) - 1]
    }
    if strings.equal_fold(host, "localhost") ||
       strings.has_suffix(strings.to_lower(host, context.temp_allocator), ".localhost") {
        return true
    }

    address := net.parse_address(host)
    if address == nil {
        return false
    }

    return http_server.address_is_loopback(address)
}

// The ChatGPT-account Codex backend rejects the sampling limits an OpenAI API key
// accepts, so the Responses dialect follows the bound credential, not model metadata.
run_responses_dialect :: proc(auth: provider.Auth) -> provider.Openai_Responses_Dialect {
    if _, codex := auth.(provider.Codex_OAuth); codex {
        return .Codex
    }

    return .Standard
}

// Resolve the credential for a logical provider: its saved API key, else its OAuth
// tokens, else missing. The credential is bound to this provider only.
@(private)
run_credential_bind :: proc(d: ^Daemon, provider_id: string) -> (provider.Auth, Run_Bind_Error) {
    if key, present := d.provider_auth.api_keys[provider_id]; present {
        return provider.Api_Key{key = key}, .None
    }

    if kind, known := oauth.kind_from_id(provider_id); known {
        if credentials, present := provider_credentials_get(d, kind); present {
            switch kind {
            case .Codex:
                return provider.Codex_OAuth {
                        access_token = credentials.access_token,
                        account_id = credentials.account_id,
                    },
                    .None

            case .Xai:
                return provider.Xai_OAuth{access_token = credentials.access_token}, .None
            }
        }
    }

    return nil, .Missing_Credential
}
