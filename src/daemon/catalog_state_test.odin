package daemon

import "core:testing"

import store "src:daemon/store"
import wire "src:wire"

@(private, rodata)
STATE_LEVELS := [?]string{"low", "medium", "high"}

@(private, rodata)
STATE_ENV := [?]string{"OPENAI_API_KEY"}

@(private)
state_provider :: proc(
    source: store.Catalog_Source,
    id, models_dev_id, name, base_url: string,
    has_endpoint: bool,
    cred: []string,
) -> store.Catalog_Provider {
    item := store.Catalog_Provider {
        id = wire.Provider_Id(id),
        source = source,
        models_dev_id = models_dev_id,
        name = name,
        endpoint = {base_url = base_url, protocol = .Openai_Responses},
        has_endpoint = has_endpoint,
        credential_env = cred,
    }
    if source == .Models_Dev {
        item.etag = `"e"`
    }

    return item
}

@(private)
state_model :: proc(
    source: store.Catalog_Source,
    provider_id, public_id, upstream, base_url: string,
) -> store.Catalog_Model {
    return store.Catalog_Complete_Model {
        source = source,
        model = {
            info = {
                id = wire.Model_Id(public_id),
                provider = provider_id,
                name = "Model",
                context_window = 1000,
                max_output_tokens = 100,
                reasoning_levels = STATE_LEVELS[:],
                default_reasoning = "medium",
                supports_tools = true,
            },
            upstream_id = upstream,
            endpoint = {base_url = base_url, protocol = .Openai_Responses},
            supports_temperature = true,
            reasoning_replay = .None,
            reasoning_format = .Native,
            max_tokens_field = .Max_Tokens,
        },
    }
}

@(test)
test_catalog_state_resolves_on_load :: proc(t: ^testing.T) {
    d: Daemon
    s := catalog_test_store(t, &d)
    defer store.close(s)
    defer catalog_state_destroy(&d)

    // An empty store resolves to a valid, stable, model-free revision.
    testing.expect_value(t, catalog_state_load(&d), nil)
    empty_rev := d.catalog.rev
    for value in ([64]u8)(empty_rev) {
        is_hex := (value >= '0' && value <= '9') || (value >= 'a' && value <= 'f')
        testing.expect(t, is_hex, "the empty revision is lowercase hex")
    }
    testing.expect_value(t, len(d.catalog.health.skipped), 0)
    testing.expect_value(t, empty_rev, catalog_rev(nil, {}))

    // Persist one imported provider and model.
    provider := state_provider(
        .Models_Dev,
        "openai",
        "openai",
        "OpenAI",
        "https://api.openai.com/v1",
        true,
        STATE_ENV[:],
    )
    model := state_model(.Models_Dev, "openai", "openai/gpt-5", "gpt-5", "https://api.openai.com/v1")
    testing.expect_value(t, store.catalog_imported_replace(s, provider, []store.Catalog_Model{model}), nil)

    // Reloading moves the revision and makes the model visible.
    testing.expect_value(t, catalog_state_load(&d), nil)
    testing.expect(t, d.catalog.rev != empty_rev, "adding a model changes the revision")

    effective, resolve_err := catalog_resolve_current(&d, context.allocator)
    testing.expect_value(t, resolve_err, nil)
    defer store.effective_catalog_destroy(&effective)
    view, ok := catalog_models_view(effective, context.allocator)
    defer delete(view)
    testing.expect(t, ok, "the view allocates")
    testing.expect_value(t, len(view), 1)
    testing.expect_value(t, string(view[0].id), "openai/gpt-5")

    // The held revision matches a freshly re-resolved view — the invariant catalog.list
    // relies on when it derives models from scratch but replies with the held rev.
    testing.expect_value(t, d.catalog.rev, catalog_rev(view, d.catalog.health))
}

@(test)
test_catalog_state_reload_frees_prior_health :: proc(t: ^testing.T) {
    d: Daemon
    s := catalog_test_store(t, &d)
    defer store.close(s)
    defer catalog_state_destroy(&d)

    imported := state_provider(
        .Models_Dev,
        "openai",
        "openai",
        "OpenAI",
        "https://api.openai.com/v1",
        true,
        STATE_ENV[:],
    )
    imported_model := state_model(.Models_Dev, "openai", "openai/gpt-5", "gpt-5", "https://api.openai.com/v1")
    testing.expect_value(t, store.catalog_imported_replace(s, imported, []store.Catalog_Model{imported_model}), nil)

    // A JavaScript custom model colliding with the imported public id invalidates the
    // whole provider, producing one skip in health.
    js := state_provider(.Javascript, "openai", "openai", "Custom", "https://api.openai.com/v1", true, nil)
    js_model := state_model(.Javascript, "openai", "openai/gpt-5", "custom", "https://api.openai.com/v1")
    testing.expect_value(
        t,
        store.catalog_javascript_replace(s, []store.Catalog_Provider{js}, []store.Catalog_Model{js_model}),
        nil,
    )

    testing.expect_value(t, catalog_state_load(&d), nil)
    testing.expect_value(t, len(d.catalog.health.skipped), 1)
    testing.expect_value(t, d.catalog.health.skipped[0].provider, "openai")
    _, is_invalid := d.catalog.health.skipped[0].reason.(wire.Skip_Reason_Invalid_Config)
    testing.expect(t, is_invalid, "a collision is reported as invalid config")

    // Dropping the JavaScript source reveals the imported model; reloading frees the old
    // non-empty health (its cloned provider name) without leaking and clears the skip.
    testing.expect_value(t, store.catalog_javascript_replace(s, nil, nil), nil)
    testing.expect_value(t, catalog_state_load(&d), nil)
    testing.expect_value(t, len(d.catalog.health.skipped), 0)
}
