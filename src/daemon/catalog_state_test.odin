package daemon

import "core:testing"

import catalog "src:daemon/catalog"
import store "src:daemon/store"
import wire "src:wire"

@(private, rodata)
STATE_LEVELS := [?]string{"low", "medium", "high"}

@(private, rodata)
STATE_ENV := [?]string{"OPENAI_API_KEY"}

// One provider carrying a model per public id. Models allocate into the temp allocator, so
// a caller may edit them before writing.
@(private)
state_provider :: proc(t: ^testing.T, id, base_url: string, public_ids: ..string) -> catalog.Provider {
    item := catalog.Provider {
        id = wire.Provider_Id(id),
        source_id = id,
        name = "OpenAI",
        endpoint = {base_url = base_url, protocol = .Openai_Responses},
        credential_env = STATE_ENV[:],
    }
    item.models.allocator = context.temp_allocator

    for public_id in public_ids {
        _, append_err := append(&item.models, state_model(id, public_id, base_url))
        testing.expect_value(t, append_err, nil)
    }

    return item
}

@(private)
state_model :: proc(provider_id, public_id, base_url: string) -> catalog.Model {
    return catalog.Model {
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
        upstream_id = "upstream",
        endpoint = {base_url = base_url, protocol = .Openai_Responses},
        supports_temperature = true,
        reasoning_replay = .None,
        thinking_format = .None,
        max_tokens_field = .Max_Tokens,
    }
}

@(test)
test_catalog_state_holds_the_snapshot_it_revised :: proc(t: ^testing.T) {
    d: Daemon
    s := catalog_test_store(t, &d)
    defer store.close(s)
    defer catalog_state_destroy(&d)

    // An empty store loads to a valid, stable, model-free revision.
    testing.expect_value(t, catalog_state_load(&d), nil)
    empty_rev := d.catalog.rev
    for value in ([64]u8)(empty_rev) {
        is_hex := (value >= '0' && value <= '9') || (value >= 'a' && value <= 'f')
        testing.expect(t, is_hex, "the empty revision is lowercase hex")
    }
    testing.expect_value(t, len(d.catalog.health.skipped), 0)
    testing.expect_value(t, empty_rev, catalog_rev(nil, {}))
    testing.expect_value(t, len(d.catalog.snapshot.providers), 0)

    item := state_provider(t, "openai", "https://api.openai.com/v1", "openai/gpt-5")
    testing.expect_value(t, store.catalog_imported_replace(s, item, `"e"`), nil)

    // Reloading moves the revision, holds the new snapshot, and carries the feed's ETag.
    testing.expect_value(t, catalog_state_load(&d), nil)
    testing.expect(t, d.catalog.rev != empty_rev, "adding a model changes the revision")
    testing.expect_value(t, d.catalog.snapshot.feed_etag, `"e"`)

    view, ok := catalog_models_view(d.catalog.snapshot, context.allocator)
    defer delete(view)
    testing.expect(t, ok, "the view allocates")
    if testing.expect_value(t, len(view), 1) {
        testing.expect_value(t, string(view[0].id), "openai/gpt-5")
    }

    // The held revision covers the held snapshot — the invariant `catalog.list` relies on
    // when it answers with the held rev and a view built from the same rows.
    testing.expect_value(t, d.catalog.rev, catalog_rev(view, d.catalog.health))

    // The run path resolves against the same snapshot rather than reading the store.
    found := catalog_model_find(&d, "openai/gpt-5")
    if testing.expect(t, found != nil, "the held snapshot resolves a model by public id") {
        testing.expect_value(t, found.upstream_id, "upstream")
    }

    testing.expect(t, catalog_model_find(&d, "openai/absent") == nil, "an unknown id resolves to nothing")
}

@(test)
test_catalog_state_reload_replaces_the_snapshot :: proc(t: ^testing.T) {
    d: Daemon
    s := catalog_test_store(t, &d)
    defer store.close(s)
    defer catalog_state_destroy(&d)

    testing.expect_value(
        t,
        store.catalog_imported_replace(
            s,
            state_provider(t, "openai", "https://api.openai.com/v1", "openai/gpt-5"),
            "",
        ),
        nil,
    )
    testing.expect_value(t, catalog_state_load(&d), nil)
    first := d.catalog.rev

    // A second load frees the snapshot it replaces rather than accumulating them, which
    // the leak check on this package's tests is what actually proves.
    testing.expect_value(
        t,
        store.catalog_imported_replace(
            s,
            state_provider(t, "openai", "https://api.openai.com/v1", "openai/gpt-6"),
            "",
        ),
        nil,
    )
    testing.expect_value(t, catalog_state_load(&d), nil)

    testing.expect(t, d.catalog.rev != first, "replacing the model changes the revision")
    testing.expect(t, catalog_model_find(&d, "openai/gpt-5") == nil, "the replaced model is gone")
    testing.expect(t, catalog_model_find(&d, "openai/gpt-6") != nil, "the replacement is held")
}
