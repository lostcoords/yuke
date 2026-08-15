package store

import "core:fmt"
import "core:mem"
import "core:testing"

import model_catalog "src:daemon/catalog"
import provider "src:provider"
import wire "src:wire"

import "libs:bindings/sqlite"
import "libs:testsupport"

@(private, rodata)
TEST_CATALOG_ENV := [?]string{"OPENAI_API_KEY"}

@(private, rodata)
TEST_CATALOG_LEVELS := [?]string{"low", "medium", "high"}

TEST_CATALOG_ETAG :: `"feed-v1"`

@(test)
test_catalog_round_trips_a_provider_and_its_models :: proc(t: ^testing.T) {
    s, err := open_memory()
    testing.expect_value(t, err, nil)
    defer close(s)

    item := test_catalog_provider(t, "openai", "gpt-5", "gpt-5-mini")
    testing.expect_value(t, catalog_imported_replace(s, item, TEST_CATALOG_ETAG), nil)

    catalog, load_err := catalog_load(s)
    testing.expect_value(t, load_err, nil)
    defer catalog_destroy(&catalog)

    testing.expect_value(t, catalog.feed_etag, TEST_CATALOG_ETAG)

    if !testing.expect_value(t, len(catalog.providers), 1) {
        return
    }

    loaded := catalog.providers[0]
    testing.expect_value(t, loaded.id, wire.Provider_Id("openai"))
    testing.expect_value(t, loaded.source_id, "openai")
    testing.expect_value(t, loaded.name, "OpenAI")
    testing.expect_value(t, loaded.endpoint.base_url, "https://api.openai.com/v1")
    testing.expect_value(t, loaded.endpoint.protocol, wire.Provider_Protocol.Openai_Chat)

    if testing.expect_value(t, len(loaded.credential_env), 1) {
        testing.expect_value(t, loaded.credential_env[0], "OPENAI_API_KEY")
    }

    // The provider carries its own models, in public-id order.
    if testing.expect_value(t, len(loaded.models), 2) {
        testing.expect_value(t, loaded.models[0].info.id, wire.Model_Id("openai/gpt-5"))
        testing.expect_value(t, loaded.models[1].info.id, wire.Model_Id("openai/gpt-5-mini"))

        model := loaded.models[0]
        testing.expect_value(t, model.upstream_id, "gpt-5")
        testing.expect_value(t, model.max_tokens_field, provider.Openai_Max_Tokens_Field.Max_Tokens)
        testing.expect_value(t, model.reasoning_replay, provider.Openai_Reasoning_Replay.Reasoning_Details)
        testing.expect_value(t, model.thinking_format, provider.Openai_Thinking_Format.Openrouter)
        testing.expect_value(t, model.info.cost.output, 10.0)

        // Derived on load rather than stored, so it cannot disagree with the level set.
        testing.expect_value(t, model.info.default_reasoning, "medium")
        if testing.expect_value(t, len(model.info.reasoning_levels), 3) {
            testing.expect_value(t, model.info.reasoning_levels[0], "low")
            testing.expect_value(t, model.info.reasoning_levels[2], "high")
        }
    }
}

@(test)
test_catalog_feed_etag_clear_nulls_the_validator :: proc(t: ^testing.T) {
    s, err := open_memory()
    testing.expect_value(t, err, nil)
    defer close(s)

    testing.expect_value(
        t,
        catalog_imported_replace(s, test_catalog_provider(t, "openai", "gpt-5"), TEST_CATALOG_ETAG),
        nil,
    )
    testing.expect_value(t, catalog_feed_etag_clear(s), nil)

    catalog, load_err := catalog_load(s)
    testing.expect_value(t, load_err, nil)
    defer catalog_destroy(&catalog)

    // etag nulled; providers survive.
    testing.expect_value(t, catalog.feed_etag, "")
    testing.expect_value(t, len(catalog.providers), 1)
}

@(test)
test_catalog_replace_touches_one_provider :: proc(t: ^testing.T) {
    s, err := open_memory()
    testing.expect_value(t, err, nil)
    defer close(s)

    testing.expect_value(t, catalog_imported_replace(s, test_catalog_provider(t, "openai", "gpt-5"), ""), nil)
    testing.expect_value(t, catalog_imported_replace(s, test_catalog_provider(t, "xai", "grok-4"), ""), nil)

    // Replacing one provider's snapshot drops its stale models and leaves the other whole.
    testing.expect_value(t, catalog_imported_replace(s, test_catalog_provider(t, "openai", "gpt-6"), ""), nil)

    catalog, load_err := catalog_load(s)
    testing.expect_value(t, load_err, nil)
    defer catalog_destroy(&catalog)

    if !testing.expect_value(t, len(catalog.providers), 2) {
        return
    }

    for item in catalog.providers {
        if !testing.expect_value(t, len(item.models), 1) {
            continue
        }

        switch item.id {
        case "openai":
            testing.expect_value(t, item.models[0].info.id, wire.Model_Id("openai/gpt-6"))

        case "xai":
            testing.expect_value(t, item.models[0].info.id, wire.Model_Id("xai/grok-4"))

        case:
            testing.expectf(t, false, "unexpected provider %s", item.id)
        }
    }
}

@(test)
test_catalog_survives_store_restart :: proc(t: ^testing.T) {
    path := testsupport.sqlite_db_path(t, "catalog-restart")
    defer testsupport.sqlite_db_remove(path)

    {
        s, err := open(path)
        testing.expect_value(t, err, nil)
        defer close(s)

        testing.expect_value(
            t,
            catalog_imported_replace(s, test_catalog_provider(t, "openai", "gpt-5"), TEST_CATALOG_ETAG),
            nil,
        )
    }

    s, err := open(path)
    testing.expect_value(t, err, nil)
    defer close(s)

    catalog, load_err := catalog_load(s)
    testing.expect_value(t, load_err, nil)
    defer catalog_destroy(&catalog)

    testing.expect_value(t, catalog.feed_etag, TEST_CATALOG_ETAG)
    if testing.expect_value(t, len(catalog.providers), 1) {
        testing.expect_value(t, len(catalog.providers[0].models), 1)
    }
}

@(test)
test_catalog_replace_is_transactional :: proc(t: ^testing.T) {
    s, err := open_memory()
    testing.expect_value(t, err, nil)
    defer close(s)

    testing.expect_value(t, catalog_imported_replace(s, test_catalog_provider(t, "openai", "gpt-5"), ""), nil)

    // A model the schema refuses aborts the whole replacement, so the old snapshot stands
    // rather than being deleted and half-rewritten.
    broken := test_catalog_provider(t, "openai", "gpt-6")
    broken.models[0].endpoint.base_url = "https://api.openai.com/v1\x00truncated"

    testing.expect_value(t, catalog_imported_replace(s, broken, ""), Store_Error.Invalid_Catalog)

    catalog, load_err := catalog_load(s)
    testing.expect_value(t, load_err, nil)
    defer catalog_destroy(&catalog)

    if testing.expect_value(t, len(catalog.providers), 1) &&
       testing.expect_value(t, len(catalog.providers[0].models), 1) {
        testing.expect_value(t, catalog.providers[0].models[0].info.id, wire.Model_Id("openai/gpt-5"))
    }
}

@(test)
test_catalog_input_is_validated_before_replacement :: proc(t: ^testing.T) {
    s, err := open_memory()
    testing.expect_value(t, err, nil)
    defer close(s)

    // The default level is derived, never authored: one that disagrees with the level set
    // is refused before a single row is written.
    item := test_catalog_provider(t, "openai", "gpt-5")
    item.models[0].info.default_reasoning = "wrong"
    testing.expect_value(t, catalog_imported_replace(s, item, ""), Store_Error.Invalid_Catalog)

    // A model naming another provider cannot ride in on this provider's snapshot.
    mismatched := test_catalog_provider(t, "openai", "gpt-5")
    mismatched.models[0].info.provider = "xai"
    testing.expect_value(t, catalog_imported_replace(s, mismatched, ""), Store_Error.Invalid_Catalog)

    count, count_err := sqlite.query_one_i64(s.writer, "SELECT count(*) FROM catalog_providers")
    testing.expect_value(t, count_err, sqlite.Result.Ok)
    testing.expect_value(t, count, i64(0))
}

@(test)
test_catalog_replace_preserves_bounds :: proc(t: ^testing.T) {
    s, err := open_memory()
    testing.expect_value(t, err, nil)
    defer close(s)

    testing.expect_value(
        t,
        sqlite.exec(
            s.writer,
            `WITH RECURSIVE provider_number(value) AS (
                VALUES (0) UNION ALL SELECT value + 1 FROM provider_number WHERE value < 255
             )
             INSERT INTO catalog_providers(provider_id, models_dev_id, name, base_url, protocol)
             SELECT printf('p%03d', value), printf('p%03d', value),
                    'Provider', 'https://example.test/v1', 'openai-responses'
             FROM provider_number`,
        ),
        sqlite.Result.Ok,
    )

    empty := test_catalog_provider(t, "overflow")
    testing.expect_value(t, catalog_imported_replace(s, empty, ""), Store_Error.Invalid_Catalog)

    testing.expect_value(
        t,
        sqlite.exec(
            s.writer,
            `WITH RECURSIVE model_number(value) AS (
                VALUES (0) UNION ALL SELECT value + 1 FROM model_number WHERE value < 4095
             )
             INSERT INTO catalog_models(
                public_model_id, provider_id,
                upstream_id, name, context_window, max_output_tokens,
                base_url, protocol, supports_temperature,
                reasoning_replay, thinking_format, anthropic_adaptive, max_tokens_field,
                supports_vision, supports_tools,
                cost_input, cost_output, cost_cache_read, cost_cache_write
             )
             SELECT printf('p000/m%04d', value), 'p000',
                    printf('m%04d', value), 'Model', 1, 1,
                    'https://example.test/v1', 'openai-responses', 1,
                    'none', 'none', 0, 'max-tokens', 0, 0, 0.0, 0.0, 0.0, 0.0
             FROM model_number`,
        ),
        sqlite.Result.Ok,
    )

    testing.expect_value(
        t,
        catalog_imported_replace(s, test_catalog_provider(t, "p001", "new"), ""),
        Store_Error.Invalid_Catalog,
    )

    providers, providers_err := sqlite.query_one_i64(s.writer, "SELECT count(*) FROM catalog_providers")
    testing.expect_value(t, providers_err, sqlite.Result.Ok)
    testing.expect_value(t, providers, i64(CATALOG_PROVIDERS_MAX))
    models, models_err := sqlite.query_one_i64(s.writer, "SELECT count(*) FROM catalog_models")
    testing.expect_value(t, models_err, sqlite.Result.Ok)
    testing.expect_value(t, models, i64(CATALOG_MODELS_MAX))

    // The refused replacement rolled back, so its target keeps the row it already had.
    old_target, target_err := sqlite.query_one_i64(
        s.writer,
        `SELECT count(*) FROM catalog_providers WHERE provider_id = 'p001' AND name = 'Provider'`,
    )
    testing.expect_value(t, target_err, sqlite.Result.Ok)
    testing.expect_value(t, old_target, i64(1))
}

@(test)
test_catalog_load_allocation_failures_leak_nothing :: proc(t: ^testing.T) {
    s, err := open_memory()
    testing.expect_value(t, err, nil)
    defer close(s)

    testing.expect_value(
        t,
        catalog_imported_replace(s, test_catalog_provider(t, "openai", "gpt-5"), TEST_CATALOG_ETAG),
        nil,
    )

    completed := false
    for fail_at in 0 ..< 128 {
        track: mem.Tracking_Allocator
        mem.tracking_allocator_init(&track, context.allocator)
        tracked := mem.tracking_allocator(&track)

        failing: testsupport.Failing_Allocator
        testsupport.failing_allocator_init(&failing, tracked, fail_at)
        catalog, load_err := catalog_load(s, testsupport.failing_allocator(&failing))

        if load_err == nil {
            completed = true
            catalog_destroy(&catalog)
        } else {
            testing.expect_value(t, load_err, Store_Error.Alloc_Failed)
            testing.expect(t, catalog.providers == nil, "a failed load returns no partial records")
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

    testing.expect(t, completed, "the allocation sweep eventually reaches a successful catalog load")
}

@(test)
test_catalog_load_rejects_corrupt_rows_without_leaking_prefix :: proc(t: ^testing.T) {
    s, err := open_memory()
    testing.expect_value(t, err, nil)
    defer close(s)

    testing.expect_value(t, catalog_imported_replace(s, test_catalog_provider(t, "a-valid", "model"), ""), nil)
    testing.expect_value(t, sqlite.exec(s.writer, "PRAGMA ignore_check_constraints = ON"), sqlite.Result.Ok)
    testing.expect_value(
        t,
        sqlite.exec(
            s.writer,
            `INSERT INTO catalog_providers(provider_id, models_dev_id, name, base_url, protocol)
             VALUES ('z-corrupt', 'z-corrupt', 'Corrupt', 'https://example.test/v1', 'future-protocol')`,
        ),
        sqlite.Result.Ok,
    )

    track: mem.Tracking_Allocator
    mem.tracking_allocator_init(&track, context.allocator)
    defer mem.tracking_allocator_destroy(&track)

    catalog, load_err := catalog_load(s, mem.tracking_allocator(&track))
    testing.expect_value(t, load_err, Store_Error.Invalid_Row)
    testing.expect(t, catalog.providers == nil, "a corrupt suffix returns no valid prefix")
    testing.expect_value(t, len(track.allocation_map), 0)
    testing.expect_value(t, len(track.bad_free_array), 0)
}

@(test)
test_catalog_load_validates_borrowed_text_before_cloning :: proc(t: ^testing.T) {
    s, err := open_memory()
    testing.expect_value(t, err, nil)
    defer close(s)

    testing.expect_value(t, sqlite.exec(s.writer, "PRAGMA ignore_check_constraints = ON"), sqlite.Result.Ok)
    testing.expect_value(
        t,
        sqlite.exec(
            s.writer,
            `INSERT INTO catalog_providers(provider_id, models_dev_id, name, base_url, protocol)
             VALUES (printf('%1000s', 'x'), 'openai', 'Corrupt',
                     'https://example.test/v1', 'openai-responses')`,
        ),
        sqlite.Result.Ok,
    )

    failing: testsupport.Failing_Allocator
    testsupport.failing_allocator_init(&failing, context.allocator, 0)
    catalog, load_err := catalog_load(s, testsupport.failing_allocator(&failing))
    testing.expect_value(t, load_err, Store_Error.Invalid_Row)
    testing.expect(t, catalog.providers == nil, "invalid borrowed text allocates no output")
}

// One provider carrying a model per local id, in the order given. Models allocate into the
// temp allocator, so a caller may edit them freely before writing.
@(private = "file")
test_catalog_provider :: proc(t: ^testing.T, id: string, local_ids: ..string) -> model_catalog.Provider {
    item := model_catalog.Provider {
        id = wire.Provider_Id(id),
        source_id = id,
        name = "OpenAI",
        endpoint = {base_url = "https://api.openai.com/v1", protocol = .Openai_Chat},
        credential_env = TEST_CATALOG_ENV[:],
    }
    item.models.allocator = context.temp_allocator

    for local_id in local_ids {
        _, append_err := append(&item.models, test_catalog_model(id, local_id))
        testing.expect_value(t, append_err, nil)
    }

    return item
}

@(private = "file")
test_catalog_model :: proc(provider_id, local_id: string) -> model_catalog.Model {
    public_id := fmt.tprintf("%s/%s", provider_id, local_id)

    return model_catalog.Model {
        info = {
            id = wire.Model_Id(public_id),
            provider = wire.Provider_Id(provider_id),
            name = "GPT",
            context_window = 128_000,
            max_output_tokens = 16_000,
            reasoning_levels = TEST_CATALOG_LEVELS[:],
            default_reasoning = "medium",
            supports_vision = true,
            supports_tools = true,
            cost = {input = 2.0, output = 10.0, cache_read = 0.5, cache_write = 1.0},
        },
        upstream_id = local_id,
        endpoint = {base_url = "https://api.openai.com/v1", protocol = .Openai_Chat},
        supports_temperature = true,
        reasoning_replay = .Reasoning_Details,
        thinking_format = .Openrouter,
        max_tokens_field = .Max_Tokens,
    }
}
