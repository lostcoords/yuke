package store

import "core:fmt"
import "core:mem"
import "core:testing"

import model_catalog "src:daemon/catalog"
import wire "src:wire"

import "libs:testsupport"

@(private, rodata)
RES_LEVELS := [?]string{"low", "medium", "high"}

@(private, rodata)
RES_OVERRIDE_LEVELS := [?]string{"low", "high"}

@(private, rodata)
RES_ENV := [?]string{"OPENAI_API_KEY"}

@(private, rodata)
RES_ENV_ALT := [?]string{"CUSTOM_KEY"}

@(private)
res_provider :: proc(
    source: Catalog_Source,
    id, models_dev_id, name, base_url: string,
    has_endpoint: bool,
    cred: []string,
) -> Catalog_Provider {
    return {
        id = wire.Provider_Id(id),
        source = source,
        models_dev_id = models_dev_id,
        name = name,
        endpoint = {base_url = base_url, protocol = .Openai_Responses},
        has_endpoint = has_endpoint,
        credential_env = cred,
    }
}

@(private)
res_complete :: proc(
    source: Catalog_Source,
    provider_id, public_id, upstream, base_url: string,
    levels: []string,
    default: string,
) -> Catalog_Complete_Model {
    return {
        source = source,
        model = {
            info = {
                id = wire.Model_Id(public_id),
                provider = provider_id,
                name = "Model",
                context_window = 1000,
                max_output_tokens = 100,
                reasoning_levels = levels,
                default_reasoning = default,
                supports_tools = true,
            },
            upstream_id = upstream,
            endpoint = {base_url = base_url, protocol = .Openai_Responses},
            supports_temperature = true,
            reasoning_replay = .None,
            reasoning_format = .Native,
        },
    }
}

@(private)
res_data :: proc(providers: []Catalog_Provider, models: []Catalog_Model) -> Catalog_Data {
    data: Catalog_Data
    data.allocator = context.allocator
    for item in providers {
        append(&data.providers, item)
    }
    for model in models {
        append(&data.models, model)
    }

    return data
}

@(private)
res_data_destroy :: proc(data: ^Catalog_Data) {
    delete(data.providers)
    delete(data.models)
    data^ = {}
}

@(private)
res_find_provider :: proc(result: Effective_Catalog, id: string) -> (^model_catalog.Provider, bool) {
    for &item in result.providers {
        if string(item.id) == id {
            return &item, true
        }
    }

    return nil, false
}

@(private)
res_find_model :: proc(item: ^model_catalog.Provider, public_id: string) -> (^model_catalog.Model, bool) {
    for &model in item.models {
        if string(model.info.id) == public_id {
            return &model, true
        }
    }

    return nil, false
}

@(test)
test_resolve_imported_only_passes_through :: proc(t: ^testing.T) {
    providers := []Catalog_Provider {
        res_provider(.Models_Dev, "openai", "openai", "OpenAI", "https://api.openai.com/v1", true, RES_ENV[:]),
    }
    models := []Catalog_Model {
        res_complete(
            .Models_Dev,
            "openai",
            "openai/gpt-5",
            "gpt-5",
            "https://api.openai.com/v1",
            RES_LEVELS[:],
            "medium",
        ),
    }
    data := res_data(providers, models)
    defer res_data_destroy(&data)

    result, err := catalog_resolve(data)
    defer effective_catalog_destroy(&result)
    testing.expect_value(t, err, nil)
    testing.expect_value(t, len(result.providers), 1)
    testing.expect_value(t, len(result.issues), 0)

    item, found := res_find_provider(result, "openai")
    testing.expect(t, found, "the imported provider resolves")
    testing.expect_value(t, item.name, "OpenAI")
    testing.expect_value(t, len(item.models), 1)
    testing.expect_value(t, string(item.models[0].info.id), "openai/gpt-5")
    testing.expect_value(t, item.models[0].info.default_reasoning, "medium")
}

@(test)
test_resolve_matched_snapshot_overlays_metadata_and_keeps_imported_models :: proc(t: ^testing.T) {
    providers := []Catalog_Provider {
        res_provider(.Models_Dev, "openai", "openai", "OpenAI", "https://api.openai.com/v1", true, RES_ENV[:]),
        res_provider(.Javascript, "openai", "openai", "Custom", "https://proxy.test/v1", true, RES_ENV_ALT[:]),
    }
    models := []Catalog_Model {
        res_complete(
            .Models_Dev,
            "openai",
            "openai/gpt-5",
            "gpt-5",
            "https://api.openai.com/v1",
            RES_LEVELS[:],
            "medium",
        ),
        res_complete(
            .Javascript,
            "openai",
            "openai/custom",
            "custom-1",
            "https://proxy.test/v1",
            RES_LEVELS[:],
            "medium",
        ),
    }
    data := res_data(providers, models)
    defer res_data_destroy(&data)

    result, err := catalog_resolve(data)
    defer effective_catalog_destroy(&result)
    testing.expect_value(t, err, nil)
    testing.expect_value(t, len(result.providers), 1)

    item, found := res_find_provider(result, "openai")
    testing.expect(t, found, "the overlaid provider resolves")
    testing.expect_value(t, item.name, "Custom")
    testing.expect_value(t, item.endpoint.base_url, "https://proxy.test/v1")
    testing.expect_value(t, len(item.credential_env), 1)
    testing.expect_value(t, item.credential_env[0], "CUSTOM_KEY")
    testing.expect_value(t, len(item.models), 2)

    imported, imported_found := res_find_model(item, "openai/gpt-5")
    testing.expect(t, imported_found, "the imported model survives beside the custom one")
    // The imported model keeps its own per-model endpoint, not the overlay endpoint.
    testing.expect_value(t, imported.endpoint.base_url, "https://api.openai.com/v1")
    custom, custom_found := res_find_model(item, "openai/custom")
    testing.expect(t, custom_found, "the custom model is added")
    // A custom model carries its own (provider) endpoint.
    testing.expect_value(t, custom.endpoint.base_url, "https://proxy.test/v1")
}

@(test)
test_resolve_inherits_imported_metadata_when_js_leaves_unset :: proc(t: ^testing.T) {
    providers := []Catalog_Provider {
        res_provider(.Models_Dev, "openai", "openai", "OpenAI", "https://api.openai.com/v1", true, RES_ENV[:]),
        res_provider(.Javascript, "openai", "openai", "", "", false, nil),
    }
    models := []Catalog_Model {
        res_complete(
            .Models_Dev,
            "openai",
            "openai/gpt-5",
            "gpt-5",
            "https://api.openai.com/v1",
            RES_LEVELS[:],
            "medium",
        ),
    }
    data := res_data(providers, models)
    defer res_data_destroy(&data)

    result, err := catalog_resolve(data)
    defer effective_catalog_destroy(&result)
    testing.expect_value(t, err, nil)

    item, found := res_find_provider(result, "openai")
    testing.expect(t, found, "the provider resolves")
    testing.expect_value(t, item.name, "OpenAI")
    testing.expect_value(t, item.endpoint.base_url, "https://api.openai.com/v1")
    testing.expect_value(t, len(item.credential_env), 1)
    testing.expect_value(t, item.credential_env[0], "OPENAI_API_KEY")
    testing.expect_value(t, len(item.models), 1)
}

@(test)
test_resolve_matched_override_replaces_only_levels :: proc(t: ^testing.T) {
    providers := []Catalog_Provider {
        res_provider(.Models_Dev, "openai", "openai", "OpenAI", "https://api.openai.com/v1", true, RES_ENV[:]),
        res_provider(.Javascript, "openai", "openai", "", "", false, nil),
    }
    override: Catalog_Model = Catalog_Model_Override {
        id                = "openai/gpt-5",
        provider_id       = "openai",
        reasoning_levels  = RES_OVERRIDE_LEVELS[:],
        default_reasoning = "high",
    }
    models := []Catalog_Model {
        res_complete(
            .Models_Dev,
            "openai",
            "openai/gpt-5",
            "gpt-5",
            "https://api.openai.com/v1",
            RES_LEVELS[:],
            "medium",
        ),
        override,
    }
    data := res_data(providers, models)
    defer res_data_destroy(&data)

    result, err := catalog_resolve(data)
    defer effective_catalog_destroy(&result)
    testing.expect_value(t, err, nil)

    item, _ := res_find_provider(result, "openai")
    model, found := res_find_model(item, "openai/gpt-5")
    testing.expect(t, found, "the overridden model resolves")
    testing.expect_value(t, len(model.info.reasoning_levels), 2)
    testing.expect_value(t, model.info.reasoning_levels[1], "high")
    testing.expect_value(t, model.info.default_reasoning, "high")
    // Everything else stays imported.
    testing.expect_value(t, model.upstream_id, "gpt-5")
    testing.expect_value(t, model.endpoint.base_url, "https://api.openai.com/v1")
}

@(test)
test_resolve_collision_invalidates_provider_but_not_siblings :: proc(t: ^testing.T) {
    providers := []Catalog_Provider {
        res_provider(.Models_Dev, "openai", "openai", "OpenAI", "https://api.openai.com/v1", true, RES_ENV[:]),
        res_provider(.Javascript, "openai", "openai", "", "https://api.openai.com/v1", true, nil),
        res_provider(.Models_Dev, "xai", "xai", "xAI", "https://api.x.ai/v1", true, RES_ENV[:]),
    }
    models := []Catalog_Model {
        res_complete(
            .Models_Dev,
            "openai",
            "openai/gpt-5",
            "gpt-5",
            "https://api.openai.com/v1",
            RES_LEVELS[:],
            "medium",
        ),
        res_complete(
            .Javascript,
            "openai",
            "openai/gpt-5",
            "custom-5",
            "https://api.openai.com/v1",
            RES_LEVELS[:],
            "medium",
        ),
        res_complete(.Models_Dev, "xai", "xai/grok", "grok", "https://api.x.ai/v1", RES_LEVELS[:], "medium"),
    }
    data := res_data(providers, models)
    defer res_data_destroy(&data)

    result, err := catalog_resolve(data)
    defer effective_catalog_destroy(&result)
    testing.expect_value(t, err, nil)

    _, openai_found := res_find_provider(result, "openai")
    testing.expect(t, !openai_found, "the colliding provider yields no effective models")
    xai, xai_found := res_find_provider(result, "xai")
    testing.expect(t, xai_found, "an unrelated provider still resolves")
    testing.expect_value(t, len(xai.models), 1)
    testing.expect_value(t, len(result.issues), 1)
    testing.expect_value(t, string(result.issues[0].provider_id), "openai")
    testing.expect_value(t, result.issues[0].error, Effective_Error.Collision)
}

@(test)
test_resolve_unmatched_override_invalidates_provider :: proc(t: ^testing.T) {
    providers := []Catalog_Provider {
        res_provider(.Models_Dev, "openai", "openai", "OpenAI", "https://api.openai.com/v1", true, RES_ENV[:]),
        res_provider(.Javascript, "openai", "openai", "", "", false, nil),
        res_provider(.Models_Dev, "xai", "xai", "xAI", "https://api.x.ai/v1", true, RES_ENV[:]),
    }
    override: Catalog_Model = Catalog_Model_Override {
        id                = "openai/ghost",
        provider_id       = "openai",
        reasoning_levels  = RES_OVERRIDE_LEVELS[:],
        default_reasoning = "high",
    }
    models := []Catalog_Model {
        res_complete(
            .Models_Dev,
            "openai",
            "openai/gpt-5",
            "gpt-5",
            "https://api.openai.com/v1",
            RES_LEVELS[:],
            "medium",
        ),
        override,
        res_complete(.Models_Dev, "xai", "xai/grok", "grok", "https://api.x.ai/v1", RES_LEVELS[:], "medium"),
    }
    data := res_data(providers, models)
    defer res_data_destroy(&data)

    result, err := catalog_resolve(data)
    defer effective_catalog_destroy(&result)
    testing.expect_value(t, err, nil)

    _, openai_found := res_find_provider(result, "openai")
    testing.expect(t, !openai_found, "the provider with an unmatched override is dropped")
    _, xai_found := res_find_provider(result, "xai")
    testing.expect(t, xai_found, "an unrelated provider still resolves")
    testing.expect_value(t, len(result.issues), 1)
    testing.expect_value(t, result.issues[0].error, Effective_Error.Unmatched_Override)
}

@(test)
test_resolve_stale_snapshot_drops_imported_keeps_custom :: proc(t: ^testing.T) {
    providers := []Catalog_Provider {
        res_provider(.Models_Dev, "openai", "openai", "OpenAI", "https://api.openai.com/v1", true, RES_ENV[:]),
        res_provider(.Javascript, "openai", "stale", "Custom", "https://proxy.test/v1", true, RES_ENV_ALT[:]),
    }
    models := []Catalog_Model {
        res_complete(
            .Models_Dev,
            "openai",
            "openai/gpt-5",
            "gpt-5",
            "https://api.openai.com/v1",
            RES_LEVELS[:],
            "medium",
        ),
        res_complete(
            .Javascript,
            "openai",
            "openai/custom",
            "custom-1",
            "https://proxy.test/v1",
            RES_LEVELS[:],
            "medium",
        ),
    }
    data := res_data(providers, models)
    defer res_data_destroy(&data)

    result, err := catalog_resolve(data)
    defer effective_catalog_destroy(&result)
    testing.expect_value(t, err, nil)

    item, found := res_find_provider(result, "openai")
    testing.expect(t, found, "the provider resolves from JavaScript")
    testing.expect_value(t, item.name, "Custom")
    testing.expect_value(t, len(item.models), 1)
    _, imported_found := res_find_model(item, "openai/gpt-5")
    testing.expect(t, !imported_found, "a stale snapshot contributes no imported models")
    _, custom_found := res_find_model(item, "openai/custom")
    testing.expect(t, custom_found, "custom models still resolve on a stale snapshot")
}

@(test)
test_resolve_orders_providers_and_models :: proc(t: ^testing.T) {
    providers := []Catalog_Provider {
        res_provider(.Models_Dev, "xai", "xai", "xAI", "https://api.x.ai/v1", true, RES_ENV[:]),
        res_provider(
            .Models_Dev,
            "anthropic",
            "anthropic",
            "Anthropic",
            "https://api.anthropic.com/v1",
            true,
            RES_ENV[:],
        ),
    }
    models := []Catalog_Model {
        res_complete(.Models_Dev, "xai", "xai/grok", "grok", "https://api.x.ai/v1", RES_LEVELS[:], "medium"),
        res_complete(
            .Models_Dev,
            "anthropic",
            "anthropic/opus",
            "opus",
            "https://api.anthropic.com/v1",
            RES_LEVELS[:],
            "medium",
        ),
        res_complete(
            .Models_Dev,
            "anthropic",
            "anthropic/haiku",
            "haiku",
            "https://api.anthropic.com/v1",
            RES_LEVELS[:],
            "medium",
        ),
    }
    data := res_data(providers, models)
    defer res_data_destroy(&data)

    result, err := catalog_resolve(data)
    defer effective_catalog_destroy(&result)
    testing.expect_value(t, err, nil)
    testing.expect_value(t, len(result.providers), 2)
    testing.expect_value(t, string(result.providers[0].id), "anthropic")
    testing.expect_value(t, string(result.providers[1].id), "xai")
    testing.expect_value(t, string(result.providers[0].models[0].info.id), "anthropic/haiku")
    testing.expect_value(t, string(result.providers[0].models[1].info.id), "anthropic/opus")
}

@(test)
test_resolve_reveal_after_javascript_removed :: proc(t: ^testing.T) {
    // With a matched override the imported levels are hidden.
    with_js := []Catalog_Provider {
        res_provider(.Models_Dev, "openai", "openai", "OpenAI", "https://api.openai.com/v1", true, RES_ENV[:]),
        res_provider(.Javascript, "openai", "openai", "", "", false, nil),
    }
    override: Catalog_Model = Catalog_Model_Override {
        id                = "openai/gpt-5",
        provider_id       = "openai",
        reasoning_levels  = RES_OVERRIDE_LEVELS[:],
        default_reasoning = "high",
    }
    with_models := []Catalog_Model {
        res_complete(
            .Models_Dev,
            "openai",
            "openai/gpt-5",
            "gpt-5",
            "https://api.openai.com/v1",
            RES_LEVELS[:],
            "medium",
        ),
        override,
    }
    data := res_data(with_js, with_models)
    result, err := catalog_resolve(data)
    testing.expect_value(t, err, nil)
    item, _ := res_find_provider(result, "openai")
    model, _ := res_find_model(item, "openai/gpt-5")
    testing.expect_value(t, len(model.info.reasoning_levels), 2)
    effective_catalog_destroy(&result)
    res_data_destroy(&data)

    // Recomputed without the JavaScript rows, the imported model reappears unchanged.
    without_js := []Catalog_Provider {
        res_provider(.Models_Dev, "openai", "openai", "OpenAI", "https://api.openai.com/v1", true, RES_ENV[:]),
    }
    without_models := []Catalog_Model {
        res_complete(
            .Models_Dev,
            "openai",
            "openai/gpt-5",
            "gpt-5",
            "https://api.openai.com/v1",
            RES_LEVELS[:],
            "medium",
        ),
    }
    data2 := res_data(without_js, without_models)
    defer res_data_destroy(&data2)
    result2, err2 := catalog_resolve(data2)
    defer effective_catalog_destroy(&result2)
    testing.expect_value(t, err2, nil)
    item2, _ := res_find_provider(result2, "openai")
    model2, _ := res_find_model(item2, "openai/gpt-5")
    testing.expect_value(t, len(model2.info.reasoning_levels), 3)
    testing.expect_value(t, model2.info.default_reasoning, "medium")
}

@(test)
test_resolve_rejects_global_model_overflow :: proc(t: ^testing.T) {
    arena_backing: mem.Dynamic_Arena
    mem.dynamic_arena_init(&arena_backing)
    defer mem.dynamic_arena_destroy(&arena_backing)
    arena := mem.dynamic_arena_allocator(&arena_backing)

    providers := []Catalog_Provider {
        res_provider(.Models_Dev, "openai", "openai", "OpenAI", "https://api.openai.com/v1", true, RES_ENV[:]),
    }

    models: [dynamic]Catalog_Model
    models.allocator = context.allocator
    defer delete(models)
    for i in 0 ..< wire.LIMITS.max_catalog_models + 1 {
        public_id := fmt.aprintf("openai/m%d", i, allocator = arena)
        append(
            &models,
            res_complete(.Models_Dev, "openai", public_id, "up", "https://api.openai.com/v1", RES_LEVELS[:], "medium"),
        )
    }

    data := res_data(providers, models[:])
    defer res_data_destroy(&data)

    result, err := catalog_resolve(data)
    defer effective_catalog_destroy(&result)
    testing.expect_value(t, err, Store_Error.Invalid_Catalog)
    testing.expect_value(t, len(result.providers), 0)
}

@(test)
test_resolve_releases_every_owned_allocation_on_oom :: proc(t: ^testing.T) {
    providers := []Catalog_Provider {
        res_provider(.Models_Dev, "openai", "openai", "OpenAI", "https://api.openai.com/v1", true, RES_ENV[:]),
        res_provider(.Javascript, "openai", "openai", "Custom", "https://proxy.test/v1", true, RES_ENV_ALT[:]),
    }
    override: Catalog_Model = Catalog_Model_Override {
        id                = "openai/gpt-5",
        provider_id       = "openai",
        reasoning_levels  = RES_OVERRIDE_LEVELS[:],
        default_reasoning = "high",
    }
    models := []Catalog_Model {
        res_complete(
            .Models_Dev,
            "openai",
            "openai/gpt-5",
            "gpt-5",
            "https://api.openai.com/v1",
            RES_LEVELS[:],
            "medium",
        ),
        res_complete(
            .Javascript,
            "openai",
            "openai/custom",
            "custom-1",
            "https://proxy.test/v1",
            RES_LEVELS[:],
            "medium",
        ),
        override,
    }
    data := res_data(providers, models)
    defer res_data_destroy(&data)

    completed := false
    for fail_at in 0 ..< 128 {
        track: mem.Tracking_Allocator
        mem.tracking_allocator_init(&track, context.allocator)
        tracked := mem.tracking_allocator(&track)

        failing: testsupport.Failing_Allocator
        testsupport.failing_allocator_init(&failing, tracked, fail_at)
        result, err := catalog_resolve(data, testsupport.failing_allocator(&failing))
        if err == nil {
            completed = true
            effective_catalog_destroy(&result)
        } else {
            testing.expect_value(t, err, Store_Error.Alloc_Failed)
            testing.expect_value(t, len(result.providers), 0)
            testing.expect_value(t, len(result.issues), 0)
        }

        testing.expectf(
            t,
            len(track.allocation_map) == 0,
            "fail_at %d leaked %d allocations",
            fail_at,
            len(track.allocation_map),
        )
        testing.expectf(
            t,
            len(track.bad_free_array) == 0,
            "fail_at %d made %d bad frees",
            fail_at,
            len(track.bad_free_array),
        )
        mem.tracking_allocator_destroy(&track)

        if completed {
            break
        }
    }

    testing.expect(t, completed, "fault sweep must eventually pass every effective allocation")
}

@(test)
test_resolve_endpoint_only_provider_contributes_only_custom_models :: proc(t: ^testing.T) {
    providers := []Catalog_Provider {
        res_provider(.Javascript, "local", "", "Local", "https://local.test/v1", true, RES_ENV_ALT[:]),
    }
    models := []Catalog_Model {
        res_complete(.Javascript, "local", "local/model", "m-1", "https://local.test/v1", RES_LEVELS[:], "medium"),
    }
    data := res_data(providers, models)
    defer res_data_destroy(&data)

    result, err := catalog_resolve(data)
    defer effective_catalog_destroy(&result)
    testing.expect_value(t, err, nil)
    testing.expect_value(t, len(result.providers), 1)
    testing.expect_value(t, len(result.issues), 0)

    item, found := res_find_provider(result, "local")
    testing.expect(t, found, "the endpoint-only provider resolves")
    testing.expect_value(t, item.name, "Local")
    testing.expect_value(t, item.endpoint.base_url, "https://local.test/v1")
    testing.expect_value(t, len(item.models), 1)
    model, model_found := res_find_model(item, "local/model")
    testing.expect(t, model_found, "the custom model resolves")
    testing.expect_value(t, model.endpoint.base_url, "https://local.test/v1")
}

@(test)
test_resolve_endpoint_only_shadows_same_id_import :: proc(t: ^testing.T) {
    providers := []Catalog_Provider {
        res_provider(.Models_Dev, "openai", "openai", "OpenAI", "https://api.openai.com/v1", true, RES_ENV[:]),
        res_provider(.Javascript, "openai", "", "Local", "https://local.test/v1", true, RES_ENV_ALT[:]),
    }
    models := []Catalog_Model {
        res_complete(
            .Models_Dev,
            "openai",
            "openai/gpt-5",
            "gpt-5",
            "https://api.openai.com/v1",
            RES_LEVELS[:],
            "medium",
        ),
        res_complete(
            .Javascript,
            "openai",
            "openai/custom",
            "custom-1",
            "https://local.test/v1",
            RES_LEVELS[:],
            "medium",
        ),
    }
    data := res_data(providers, models)
    defer res_data_destroy(&data)

    result, err := catalog_resolve(data)
    defer effective_catalog_destroy(&result)
    testing.expect_value(t, err, nil)

    item, found := res_find_provider(result, "openai")
    testing.expect(t, found, "the endpoint-only overlay resolves")
    testing.expect_value(t, item.name, "Local")
    testing.expect_value(t, len(item.models), 1)
    _, imported_found := res_find_model(item, "openai/gpt-5")
    testing.expect(t, !imported_found, "an endpoint-only overlay does not adopt the imported snapshot")
    _, custom_found := res_find_model(item, "openai/custom")
    testing.expect(t, custom_found, "the custom model resolves")
}

@(test)
test_resolve_stale_override_is_ignored_and_does_not_collide :: proc(t: ^testing.T) {
    providers := []Catalog_Provider {
        res_provider(.Models_Dev, "openai", "openai", "OpenAI", "https://api.openai.com/v1", true, RES_ENV[:]),
        res_provider(.Javascript, "openai", "stale", "Custom", "https://proxy.test/v1", true, RES_ENV_ALT[:]),
    }
    override: Catalog_Model = Catalog_Model_Override {
        id                = "openai/gpt-5",
        provider_id       = "openai",
        reasoning_levels  = RES_OVERRIDE_LEVELS[:],
        default_reasoning = "high",
    }
    models := []Catalog_Model {
        res_complete(
            .Models_Dev,
            "openai",
            "openai/gpt-5",
            "gpt-5",
            "https://api.openai.com/v1",
            RES_LEVELS[:],
            "medium",
        ),
        // A custom model reusing the imported public id: no collision, because the
        // stale snapshot drops the imported model.
        res_complete(
            .Javascript,
            "openai",
            "openai/gpt-5",
            "custom-5",
            "https://proxy.test/v1",
            RES_LEVELS[:],
            "medium",
        ),
        override,
    }
    data := res_data(providers, models)
    defer res_data_destroy(&data)

    result, err := catalog_resolve(data)
    defer effective_catalog_destroy(&result)
    testing.expect_value(t, err, nil)
    testing.expect_value(t, len(result.issues), 0)

    item, found := res_find_provider(result, "openai")
    testing.expect(t, found, "the provider resolves from JavaScript alone")
    testing.expect_value(t, len(item.models), 1)
    model, model_found := res_find_model(item, "openai/gpt-5")
    testing.expect(t, model_found, "the custom model resolves")
    // The stale override never applied, so the imported levels were never used and
    // the custom model keeps its own three levels.
    testing.expect_value(t, model.upstream_id, "custom-5")
    testing.expect_value(t, len(model.info.reasoning_levels), 3)
}

@(test)
test_resolve_drops_provider_with_no_effective_models :: proc(t: ^testing.T) {
    // A JavaScript provider names a models.dev source but no import is present and it
    // has no endpoint of its own, so it can resolve nothing.
    providers := []Catalog_Provider {
        res_provider(.Javascript, "ghost", "ghost", "", "", false, nil),
        res_provider(.Models_Dev, "openai", "openai", "OpenAI", "https://api.openai.com/v1", true, RES_ENV[:]),
    }
    models := []Catalog_Model {
        res_complete(
            .Models_Dev,
            "openai",
            "openai/gpt-5",
            "gpt-5",
            "https://api.openai.com/v1",
            RES_LEVELS[:],
            "medium",
        ),
    }
    data := res_data(providers, models)
    defer res_data_destroy(&data)

    result, err := catalog_resolve(data)
    defer effective_catalog_destroy(&result)
    testing.expect_value(t, err, nil)
    testing.expect_value(t, len(result.issues), 0)
    testing.expect_value(t, len(result.providers), 1)
    _, ghost_found := res_find_provider(result, "ghost")
    testing.expect(t, !ghost_found, "an empty provider is dropped, not emitted")
    _, openai_found := res_find_provider(result, "openai")
    testing.expect(t, openai_found, "the usable provider still resolves")
}
