package daemon

import "core:mem"
import "core:strings"

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

// Why a public model id produced no row.
Run_Resolve_Error :: enum {
    None,
    Unknown_Model,
    Store_Failed,
}

// Load and resolve only the provider that owns `public_id`. Collisions and overrides are
// provider-scoped, so one provider's rows decide the outcome and the run never reads the
// whole catalog. The returned model borrows `effective`, which the caller destroys.
run_model_load :: proc(
    d: ^Daemon,
    public_id: string,
    allocator: mem.Allocator,
) -> (
    effective: store.Effective_Catalog,
    model: ^catalog.Model,
    err: Run_Resolve_Error,
) {
    assert(d != nil, "model load needs daemon state")
    assert(d.store != nil, "model load needs an open store")

    provider_id, named := run_provider_of(public_id)
    if !named {
        return {}, nil, .Unknown_Model
    }

    data, load_err := store.catalog_data_load(d.store, provider_id, allocator)
    if load_err != nil {
        return {}, nil, .Store_Failed
    }
    defer store.catalog_data_destroy(&data)

    resolved, resolve_err := store.catalog_resolve(data, allocator)
    if resolve_err != nil {
        return {}, nil, .Store_Failed
    }

    row, found := run_model_resolve(resolved, public_id)
    if !found {
        store.effective_catalog_destroy(&resolved)
        return {}, nil, .Unknown_Model
    }

    return resolved, row, .None
}

// The provider that owns a public model id: everything before the first `/`. The rest may
// itself contain slashes, as `openrouter/openai/gpt-5` does.
@(private)
run_provider_of :: proc(public_id: string) -> (string, bool) {
    slash := strings.index_byte(public_id, '/')
    if slash <= 0 || slash == len(public_id) - 1 {
        return "", false
    }

    return public_id[:slash], true
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
