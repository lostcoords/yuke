package daemon

import "core:testing"

import store "src:daemon/store"
import provider "src:provider"

@(private)
run_test_effective :: proc(t: ^testing.T, d: ^Daemon, s: ^store.Store) -> store.Effective_Catalog {
    imported := state_provider(
        .Models_Dev,
        "openai",
        "openai",
        "OpenAI",
        "https://api.openai.com/v1",
        true,
        STATE_ENV[:],
    )
    model := state_model(.Models_Dev, "openai", "openai/gpt-5", "gpt-5", "https://api.openai.com/v1")
    testing.expect_value(t, store.catalog_imported_replace(s, imported, []store.Catalog_Model{model}), nil)

    effective, resolve_err := catalog_resolve_current(d, context.allocator)
    testing.expect_value(t, resolve_err, nil)
    return effective
}

@(test)
test_run_model_resolve_finds_exact_and_misses :: proc(t: ^testing.T) {
    d: Daemon
    s := catalog_test_store(t, &d)
    defer store.close(s)

    effective := run_test_effective(t, &d, s)
    defer store.effective_catalog_destroy(&effective)

    hit, found := run_model_resolve(effective, "openai/gpt-5")
    testing.expect(t, found, "the model resolves by its public id")
    testing.expect_value(t, string(hit.info.id), "openai/gpt-5")
    testing.expect_value(t, hit.upstream_id, "gpt-5")
    testing.expect_value(t, hit.endpoint.base_url, "https://api.openai.com/v1")
    testing.expect_value(t, hit.max_tokens_field, provider.Openai_Max_Tokens_Field.Max_Tokens)

    _, unknown := run_model_resolve(effective, "openai/nope")
    testing.expect(t, !unknown, "an unknown public id does not resolve")

    _, empty := run_model_resolve({}, "openai/gpt-5")
    testing.expect(t, !empty, "an empty catalog resolves nothing")
}

@(test)
test_run_connection_build_binds_the_provider_credential :: proc(t: ^testing.T) {
    d: Daemon
    s := catalog_test_store(t, &d)
    defer store.close(s)

    effective := run_test_effective(t, &d, s)
    defer store.effective_catalog_destroy(&effective)
    row, found := run_model_resolve(effective, "openai/gpt-5")
    testing.expect(t, found, "the model resolves")

    d.provider_auth.api_keys = make(map[string]string, 2, context.allocator)
    defer delete(d.provider_auth.api_keys)

    // No credential for this provider yet.
    _, missing := run_connection_build(&d, row)
    testing.expect_value(t, missing, Run_Bind_Error.Missing_Credential)

    // Another provider's key does not bind.
    d.provider_auth.api_keys["xai"] = "other"
    _, isolated := run_connection_build(&d, row)
    testing.expect_value(t, isolated, Run_Bind_Error.Missing_Credential)

    // The provider's own key binds, after the endpoint validates.
    d.provider_auth.api_keys["openai"] = "sk-test"
    connection, ok := run_connection_build(&d, row)
    testing.expect_value(t, ok, Run_Bind_Error.None)
    testing.expect_value(t, connection.endpoint.base_url, "https://api.openai.com/v1")
    api_key, is_api := connection.auth.(provider.Api_Key)
    testing.expect(t, is_api, "an api-key provider binds an Api_Key auth")
    testing.expect_value(t, api_key.key, "sk-test")
}

@(test)
test_run_model_load_reads_only_the_owning_provider :: proc(t: ^testing.T) {
    d: Daemon
    s := catalog_test_store(t, &d)
    defer store.close(s)

    // Two providers persisted; a run for one of them must not surface the other.
    openai := state_provider(
        .Models_Dev,
        "openai",
        "openai",
        "OpenAI",
        "https://api.openai.com/v1",
        true,
        STATE_ENV[:],
    )
    openai_model := state_model(.Models_Dev, "openai", "openai/gpt-5", "gpt-5", "https://api.openai.com/v1")
    testing.expect_value(t, store.catalog_imported_replace(s, openai, []store.Catalog_Model{openai_model}), nil)

    xai := state_provider(.Models_Dev, "xai", "xai", "xAI", "https://api.x.ai/v1", true, STATE_ENV[:])
    xai_model := state_model(.Models_Dev, "xai", "xai/grok-4", "grok-4", "https://api.x.ai/v1")
    testing.expect_value(t, store.catalog_imported_replace(s, xai, []store.Catalog_Model{xai_model}), nil)

    effective, row, err := run_model_load(&d, "openai/gpt-5", context.allocator)
    testing.expect_value(t, err, Run_Resolve_Error.None)
    defer store.effective_catalog_destroy(&effective)

    testing.expect_value(t, string(row.info.id), "openai/gpt-5")
    testing.expect_value(t, row.upstream_id, "gpt-5")
    if testing.expect_value(t, len(effective.providers), 1) {
        testing.expect_value(t, string(effective.providers[0].id), "openai")
    }

    // A model that exists under a different provider prefix does not resolve.
    _, _, cross_provider := run_model_load(&d, "openai/grok-4", context.allocator)
    testing.expect_value(t, cross_provider, Run_Resolve_Error.Unknown_Model)

    // An id that names no provider is rejected before any store read.
    for id in ([?]string{"", "gpt-5", "/gpt-5", "openai/"}) {
        _, _, malformed := run_model_load(&d, id, context.allocator)
        testing.expect_value(t, malformed, Run_Resolve_Error.Unknown_Model)
    }
}

@(test)
test_run_responses_dialect_follows_the_credential :: proc(t: ^testing.T) {
    testing.expect_value(t, run_responses_dialect(nil), provider.Openai_Responses_Dialect.Standard)
    testing.expect_value(
        t,
        run_responses_dialect(provider.Api_Key{key = "sk-test"}),
        provider.Openai_Responses_Dialect.Standard,
    )
    testing.expect_value(
        t,
        run_responses_dialect(provider.Xai_OAuth{access_token = "token"}),
        provider.Openai_Responses_Dialect.Standard,
    )

    // Only the ChatGPT-account backend takes the restricted dialect.
    testing.expect_value(
        t,
        run_responses_dialect(provider.Codex_OAuth{access_token = "token", account_id = "acct"}),
        provider.Openai_Responses_Dialect.Codex,
    )
}
