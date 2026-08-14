package daemon

import "core:testing"

import store "src:daemon/store"
import provider "src:provider"

// Persist one provider and hold the resulting snapshot, the way a started daemon does.
@(private)
run_test_catalog :: proc(t: ^testing.T, d: ^Daemon, s: ^store.Store) {
    item := state_provider(t, "openai", "https://api.openai.com/v1", "openai/gpt-5")
    testing.expect_value(t, store.catalog_imported_replace(s, item, ""), nil)
    testing.expect_value(t, catalog_state_load(d), nil)
}

@(test)
test_run_connection_build_binds_the_provider_credential :: proc(t: ^testing.T) {
    d: Daemon
    s := catalog_test_store(t, &d)
    defer store.close(s)

    defer catalog_state_destroy(&d)
    run_test_catalog(t, &d, s)

    row := catalog_model_find(&d, "openai/gpt-5")
    testing.expect(t, row != nil, "the model resolves")

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
test_catalog_model_find_matches_the_whole_public_id :: proc(t: ^testing.T) {
    d: Daemon
    s := catalog_test_store(t, &d)
    defer store.close(s)
    defer catalog_state_destroy(&d)

    // Two providers held at once; resolving one must not surface the other's model.
    testing.expect_value(
        t,
        store.catalog_imported_replace(
            s,
            state_provider(t, "openai", "https://api.openai.com/v1", "openai/gpt-5"),
            "",
        ),
        nil,
    )
    testing.expect_value(
        t,
        store.catalog_imported_replace(s, state_provider(t, "xai", "https://api.x.ai/v1", "xai/grok-4"), ""),
        nil,
    )
    testing.expect_value(t, catalog_state_load(&d), nil)

    row := catalog_model_find(&d, "openai/gpt-5")
    if testing.expect(t, row != nil, "the model resolves by its public id") {
        testing.expect_value(t, string(row.info.id), "openai/gpt-5")
        testing.expect_value(t, row.upstream_id, "upstream")
        testing.expect_value(t, row.endpoint.base_url, "https://api.openai.com/v1")
        testing.expect_value(t, row.max_tokens_field, provider.Openai_Max_Tokens_Field.Max_Tokens)
    }

    // The id is a key, never a prefix or an index: only an exact match resolves.
    for id in ([?]string{"openai/grok-4", "openai/nope", "", "gpt-5", "/gpt-5", "openai/", "openai"}) {
        testing.expectf(t, catalog_model_find(&d, id) == nil, "%q should not resolve", id)
    }
}

@(test)
test_endpoint_is_loopback :: proc(t: ^testing.T) {
    Case :: struct {
        base_url: string,
        loopback: bool,
    }

    cases := [?]Case {
        {"http://127.0.0.1:11434/v1", true},
        {"http://127.5.6.7:8080/v1", true},
        {"http://localhost:1234/v1", true},
        {"http://LOCALHOST:1234/v1", true},
        {"http://ollama.localhost:1234/v1", true},
        {"http://[::1]:1234/v1", true},
        {"https://api.openai.com/v1", false},
        {"https://api.minimax.io/anthropic/v1", false},
        {"http://10.0.0.4:11434/v1", false},
        {"http://notlocalhost.example.com/v1", false},
    }
    for c in cases {
        endpoint := provider.Endpoint {
            base_url = c.base_url,
            protocol = .Openai_Chat,
        }
        testing.expectf(
            t,
            endpoint_is_loopback(endpoint) == c.loopback,
            "%s loopback should be %v",
            c.base_url,
            c.loopback,
        )
    }
}

@(test)
test_run_connection_build_allows_an_unauthenticated_local_endpoint :: proc(t: ^testing.T) {
    d: Daemon
    s := catalog_test_store(t, &d)
    defer store.close(s)

    defer catalog_state_destroy(&d)

    local := state_provider(t, "ollama", "http://127.0.0.1:11434/v1", "ollama/llama")
    testing.expect_value(t, store.catalog_imported_replace(s, local, ""), nil)
    testing.expect_value(t, catalog_state_load(&d), nil)

    row := catalog_model_find(&d, "ollama/llama")
    testing.expect(t, row != nil, "the local model resolves")

    d.provider_auth.api_keys = make(map[string]string, 2, context.allocator)
    defer delete(d.provider_auth.api_keys)

    // No credential is saved for this provider, but the endpoint is on this machine.
    connection, bind_err := run_connection_build(&d, row)
    testing.expect_value(t, bind_err, Run_Bind_Error.None)
    testing.expect(t, connection.auth == nil, "a local endpoint binds no credential")
    testing.expect_value(t, connection.endpoint.base_url, "http://127.0.0.1:11434/v1")
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
