package daemon

import catalog "src:daemon/catalog"
import "src:daemon/oauth"
import store "src:daemon/store"
import provider "src:provider"

// Why a resolved model could not become a live provider connection.
Run_Bind_Error :: enum {
    None,
    Invalid_Endpoint,
    Missing_Credential,
}

// The id is matched exactly and used as a key, never as an index. The returned pointer
// borrows `effective` and is valid only while it lives.
run_model_resolve :: proc(effective: store.Effective_Catalog, public_id: string) -> (^catalog.Model, bool) {
    for &provider in effective.providers {
        for &model in provider.models {
            if string(model.info.id) == public_id {
                return &model, true
            }
        }
    }

    return nil, false
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
    if bind_err != .None {
        return {}, bind_err
    }

    return {endpoint = endpoint, auth = auth}, .None
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
