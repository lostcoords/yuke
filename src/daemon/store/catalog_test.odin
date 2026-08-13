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

@(test)
test_catalog_sources_round_trip_without_flattening_collisions :: proc(t: ^testing.T) {
    s, err := open_memory()
    testing.expect_value(t, err, nil)
    defer close(s)

    imported_provider := test_catalog_provider(.Models_Dev, "openai")
    imported_model: Catalog_Model = test_catalog_model(.Models_Dev, "openai", "gpt-5")
    testing.expect_value(t, catalog_imported_replace(s, imported_provider, []Catalog_Model{imported_model}), nil)

    javascript_provider := test_catalog_provider(.Javascript, "openai")
    javascript_model: Catalog_Model = test_catalog_model(.Javascript, "openai", "gpt-5")
    override: Catalog_Model = model_catalog.Model_Override {
        id                = "openai/gpt-5",
        provider_id       = "openai",
        reasoning_levels  = []string{"low", "max"},
        default_reasoning = "max",
    }
    testing.expect_value(
        t,
        catalog_javascript_replace(
            s,
            []Catalog_Provider{javascript_provider},
            []Catalog_Model{javascript_model, override},
        ),
        nil,
    )

    data, load_err := catalog_data_load(s)
    testing.expect_value(t, load_err, nil)
    defer catalog_data_destroy(&data)
    testing.expect_value(t, len(data.providers), 2)
    testing.expect_value(t, len(data.models), 3)

    imported_provider_index, imported_provider_found := catalog_provider_find(data.providers[:], "openai", .Models_Dev)
    testing.expect(t, imported_provider_found, "the imported provider survives beside its JavaScript overlay")
    if imported_provider_found {
        item := data.providers[imported_provider_index]
        testing.expect_value(t, item.models_dev_id, "openai")
        testing.expect_value(t, item.name, "OpenAI")
        testing.expect_value(t, item.etag, `"feed-v1"`)
        testing.expect_value(t, item.endpoint.base_url, "https://api.openai.com/v1")
        testing.expect_value(t, item.endpoint.protocol, wire.Provider_Protocol.Openai_Responses)
        if testing.expect_value(t, len(item.credential_env), 1) {
            testing.expect_value(t, item.credential_env[0], "OPENAI_API_KEY")
        }
    }

    imported_index, imported_found := catalog_model_find(data.models[:], "openai/gpt-5", .Models_Dev, .Model)
    testing.expect(t, imported_found, "the imported model row remains distinct")
    if imported_found {
        model, model_ok := data.models[imported_index].(Catalog_Complete_Model)
        testing.expect(t, model_ok, "the imported row is complete")
        if model_ok {
            testing.expect_value(t, model.upstream_id, "gpt-5")
            testing.expect_value(t, model.max_tokens_field, provider.Openai_Max_Tokens_Field.Max_Tokens)
            testing.expect_value(t, model.info.default_reasoning, "medium")
            testing.expect_value(t, model.reasoning_replay, model_catalog.Reasoning_Replay.Reasoning_Details)
            testing.expect_value(t, model.reasoning_format, model_catalog.Reasoning_Format.Native)
            testing.expect_value(t, model.info.cost.output, 10.0)
        }
    }

    _, custom_found := catalog_model_find(data.models[:], "openai/gpt-5", .Javascript, .Model)
    override_index, override_found := catalog_model_find(data.models[:], "openai/gpt-5", .Javascript, .Override)
    testing.expect(t, custom_found, "a colliding custom row is preserved for overlay validation")
    testing.expect(t, override_found, "a colliding override row is preserved for overlay validation")
    if override_found {
        model, model_ok := data.models[override_index].(model_catalog.Model_Override)
        testing.expect(t, model_ok, "the override remains a partial arm")
        if model_ok {
            testing.expect_value(t, model.default_reasoning, "max")
            testing.expect_value(t, len(model.reasoning_levels), 2)
        }
    }
}

@(test)
test_catalog_javascript_replace_removes_stale_rows_and_reveals_imported :: proc(t: ^testing.T) {
    s, err := open_memory()
    testing.expect_value(t, err, nil)
    defer close(s)

    imported_provider := test_catalog_provider(.Models_Dev, "openai")
    imported_model: Catalog_Model = test_catalog_model(.Models_Dev, "openai", "gpt-5")
    testing.expect_value(t, catalog_imported_replace(s, imported_provider, []Catalog_Model{imported_model}), nil)

    javascript_provider := test_catalog_provider(.Javascript, "openai")
    override: Catalog_Model = model_catalog.Model_Override {
        id                = "openai/gpt-5",
        provider_id       = "openai",
        reasoning_levels  = []string{"high"},
        default_reasoning = "high",
    }
    testing.expect_value(
        t,
        catalog_javascript_replace(s, []Catalog_Provider{javascript_provider}, []Catalog_Model{override}),
        nil,
    )
    testing.expect_value(t, catalog_javascript_replace(s, nil, nil), nil)

    data, load_err := catalog_data_load(s)
    testing.expect_value(t, load_err, nil)
    defer catalog_data_destroy(&data)
    testing.expect_value(t, len(data.providers), 1)
    testing.expect_value(t, len(data.models), 1)
    testing.expect_value(t, data.providers[0].source, Catalog_Source.Models_Dev)
    _, imported_found := catalog_model_find(data.models[:], "openai/gpt-5", .Models_Dev, .Model)
    testing.expect(t, imported_found, "source cleanup reveals the imported model")
}

@(test)
test_catalog_sources_survive_store_restart :: proc(t: ^testing.T) {
    path := testsupport.sqlite_db_path(t, "catalog-restart")
    defer testsupport.sqlite_db_remove(path)

    s, err := open(path)
    testing.expect_value(t, err, nil)

    imported_provider := test_catalog_provider(.Models_Dev, "openai")
    imported_model: Catalog_Model = test_catalog_model(.Models_Dev, "openai", "gpt-5")
    testing.expect_value(t, catalog_imported_replace(s, imported_provider, []Catalog_Model{imported_model}), nil)

    javascript_provider := test_catalog_provider(.Javascript, "openai")
    override: Catalog_Model = model_catalog.Model_Override {
        id                = "openai/gpt-5",
        provider_id       = "openai",
        reasoning_levels  = []string{"high"},
        default_reasoning = "high",
    }
    testing.expect_value(
        t,
        catalog_javascript_replace(s, []Catalog_Provider{javascript_provider}, []Catalog_Model{override}),
        nil,
    )
    close(s)

    reopened, reopen_err := open(path)
    testing.expect_value(t, reopen_err, nil)
    defer close(reopened)

    data, load_err := catalog_data_load(reopened)
    testing.expect_value(t, load_err, nil)
    defer catalog_data_destroy(&data)
    testing.expect_value(t, len(data.providers), 2)
    testing.expect_value(t, len(data.models), 2)
    _, imported_found := catalog_model_find(data.models[:], "openai/gpt-5", .Models_Dev, .Model)
    _, override_found := catalog_model_find(data.models[:], "openai/gpt-5", .Javascript, .Override)
    testing.expect(t, imported_found && override_found, "both source identities survive reopening yuked.db")
}

@(test)
test_catalog_imported_replace_is_transactional :: proc(t: ^testing.T) {
    s, err := open_memory()
    testing.expect_value(t, err, nil)
    defer close(s)

    item := test_catalog_provider(.Models_Dev, "openai")
    old_model: Catalog_Model = test_catalog_model(.Models_Dev, "openai", "old")
    testing.expect_value(t, catalog_imported_replace(s, item, []Catalog_Model{old_model}), nil)
    testing.expect_value(
        t,
        sqlite.exec(
            s.writer,
            `CREATE TRIGGER reject_new_catalog_model
             BEFORE INSERT ON catalog_models
             WHEN NEW.public_model_id = 'openai/new'
             BEGIN SELECT RAISE(ABORT, 'reject test replacement'); END`,
        ),
        sqlite.Result.Ok,
    )

    new_model: Catalog_Model = test_catalog_model(.Models_Dev, "openai", "new")
    testing.expect_value(t, catalog_imported_replace(s, item, []Catalog_Model{new_model}), sqlite.Result.Constraint)

    data, load_err := catalog_data_load(s)
    testing.expect_value(t, load_err, nil)
    defer catalog_data_destroy(&data)
    testing.expect_value(t, len(data.providers), 1)
    testing.expect_value(t, len(data.models), 1)
    _, old_found := catalog_model_find(data.models[:], "openai/old", .Models_Dev, .Model)
    _, new_found := catalog_model_find(data.models[:], "openai/new", .Models_Dev, .Model)
    testing.expect(t, old_found, "a failed replacement rolls the deleted snapshot back")
    testing.expect(t, !new_found, "a failed replacement commits no new suffix")
}

@(test)
test_catalog_javascript_replace_is_transactional :: proc(t: ^testing.T) {
    s, err := open_memory()
    testing.expect_value(t, err, nil)
    defer close(s)

    item := test_catalog_provider(.Javascript, "openai")
    old_model: Catalog_Model = test_catalog_model(.Javascript, "openai", "old")
    testing.expect_value(t, catalog_javascript_replace(s, []Catalog_Provider{item}, []Catalog_Model{old_model}), nil)
    testing.expect_value(
        t,
        sqlite.exec(
            s.writer,
            `CREATE TRIGGER reject_new_javascript_model
             BEFORE INSERT ON catalog_models
             WHEN NEW.public_model_id = 'openai/new'
             BEGIN SELECT RAISE(ABORT, 'reject test replacement'); END`,
        ),
        sqlite.Result.Ok,
    )

    new_model: Catalog_Model = test_catalog_model(.Javascript, "openai", "new")
    testing.expect_value(
        t,
        catalog_javascript_replace(s, []Catalog_Provider{item}, []Catalog_Model{new_model}),
        sqlite.Result.Constraint,
    )

    data, load_err := catalog_data_load(s)
    testing.expect_value(t, load_err, nil)
    defer catalog_data_destroy(&data)
    testing.expect_value(t, len(data.providers), 1)
    testing.expect_value(t, len(data.models), 1)
    _, old_found := catalog_model_find(data.models[:], "openai/old", .Javascript, .Model)
    _, new_found := catalog_model_find(data.models[:], "openai/new", .Javascript, .Model)
    testing.expect(t, old_found, "a failed JavaScript replacement restores the deleted source")
    testing.expect(t, !new_found, "a failed JavaScript replacement commits no new suffix")
}

@(test)
test_catalog_imported_replace_preserves_source_bounds :: proc(t: ^testing.T) {
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
             INSERT INTO catalog_providers(provider_id, source, models_dev_id, name, base_url, protocol)
             SELECT printf('p%03d', value), 'models_dev', printf('p%03d', value),
                    'Provider', 'https://example.test/v1', 'openai-responses'
             FROM provider_number`,
        ),
        sqlite.Result.Ok,
    )

    overflow_provider := test_catalog_provider(.Models_Dev, "overflow")
    testing.expect_value(t, catalog_imported_replace(s, overflow_provider, nil), Store_Error.Invalid_Catalog)

    testing.expect_value(
        t,
        sqlite.exec(
            s.writer,
            `WITH RECURSIVE model_number(value) AS (
                VALUES (0) UNION ALL SELECT value + 1 FROM model_number WHERE value < 4095
             )
             INSERT INTO catalog_models(
                public_model_id, provider_id, source, kind,
                upstream_id, name, context_window, max_output_tokens,
                base_url, protocol, supports_temperature,
                reasoning_replay, reasoning_format, max_tokens_field,
                supports_vision, supports_tools,
                cost_input, cost_output, cost_cache_read, cost_cache_write
             )
             SELECT printf('p000/m%04d', value), 'p000', 'models_dev', 'model',
                    printf('m%04d', value), 'Model', 1, 1,
                    'https://example.test/v1', 'openai-responses', 1,
                    'none', 'native', 'max-tokens', 0, 0, 0.0, 0.0, 0.0, 0.0
             FROM model_number`,
        ),
        sqlite.Result.Ok,
    )

    replacement_provider := test_catalog_provider(.Models_Dev, "p001")
    replacement_model: Catalog_Model = test_catalog_model(.Models_Dev, "p001", "new")
    testing.expect_value(
        t,
        catalog_imported_replace(s, replacement_provider, []Catalog_Model{replacement_model}),
        Store_Error.Invalid_Catalog,
    )

    providers, providers_err := sqlite.query_one_i64(s.writer, "SELECT count(*) FROM catalog_providers")
    testing.expect_value(t, providers_err, sqlite.Result.Ok)
    testing.expect_value(t, providers, i64(CATALOG_PROVIDERS_PER_SOURCE_MAX))
    models, models_err := sqlite.query_one_i64(s.writer, "SELECT count(*) FROM catalog_models")
    testing.expect_value(t, models_err, sqlite.Result.Ok)
    testing.expect_value(t, models, i64(CATALOG_MODELS_PER_SOURCE_MAX))
    old_target, target_err := sqlite.query_one_i64(
        s.writer,
        `SELECT count(*) FROM catalog_providers
         WHERE provider_id = 'p001' AND source = 'models_dev' AND name = 'Provider'`,
    )
    testing.expect_value(t, target_err, sqlite.Result.Ok)
    testing.expect_value(t, old_target, i64(1))
}

@(test)
test_catalog_input_is_validated_before_replacement :: proc(t: ^testing.T) {
    s, err := open_memory()
    testing.expect_value(t, err, nil)
    defer close(s)

    item := test_catalog_provider(.Models_Dev, "openai")
    model := test_catalog_model(.Models_Dev, "openai", "gpt-5")
    model.info.default_reasoning = "wrong"
    value: Catalog_Model = model
    testing.expect_value(t, catalog_imported_replace(s, item, []Catalog_Model{value}), Store_Error.Invalid_Catalog)

    count, count_err := sqlite.query_one_i64(s.writer, "SELECT count(*) FROM catalog_providers")
    testing.expect_value(t, count_err, sqlite.Result.Ok)
    testing.expect_value(t, count, i64(0))
}

@(test)
test_catalog_javascript_models_match_provider_shape :: proc(t: ^testing.T) {
    s, err := open_memory()
    testing.expect_value(t, err, nil)
    defer close(s)

    endpoint_provider := test_catalog_provider(.Javascript, "openai")
    endpoint_provider.models_dev_id = ""
    override: Catalog_Model = model_catalog.Model_Override {
        id                = "openai/gpt-5",
        provider_id       = "openai",
        reasoning_levels  = []string{"low", "high"},
        default_reasoning = "high",
    }
    testing.expect_value(
        t,
        catalog_javascript_replace(s, []Catalog_Provider{endpoint_provider}, []Catalog_Model{override}),
        Store_Error.Invalid_Catalog,
    )

    custom_model := test_catalog_model(.Javascript, "openai", "gpt-5")
    custom_model.endpoint.protocol = .Openai_Chat
    value: Catalog_Model = custom_model
    testing.expect_value(
        t,
        catalog_javascript_replace(s, []Catalog_Provider{endpoint_provider}, []Catalog_Model{value}),
        Store_Error.Invalid_Catalog,
    )

    count, count_err := sqlite.query_one_i64(s.writer, "SELECT count(*) FROM catalog_providers")
    testing.expect_value(t, count_err, sqlite.Result.Ok)
    testing.expect_value(t, count, i64(0))
}

@(test)
test_catalog_load_rejects_javascript_model_provider_mismatch :: proc(t: ^testing.T) {
    s, err := open_memory()
    testing.expect_value(t, err, nil)
    defer close(s)

    item := test_catalog_provider(.Javascript, "openai")
    custom: Catalog_Model = test_catalog_model(.Javascript, "openai", "gpt-5")
    testing.expect_value(t, catalog_javascript_replace(s, []Catalog_Provider{item}, []Catalog_Model{custom}), nil)
    testing.expect_value(
        t,
        sqlite.exec(
            s.writer,
            `UPDATE catalog_models SET protocol = 'openai-completions'
             WHERE public_model_id = 'openai/gpt-5' AND source = 'javascript' AND kind = 'model'`,
        ),
        sqlite.Result.Ok,
    )

    data, load_err := catalog_data_load(s)
    testing.expect_value(t, load_err, Store_Error.Invalid_Row)
    testing.expect(t, data.providers == nil && data.models == nil, "a mismatched custom endpoint returns no data")

    testing.expect_value(t, catalog_javascript_replace(s, nil, nil), nil)
    testing.expect_value(
        t,
        sqlite.exec(
            s.writer,
            `INSERT INTO catalog_providers(provider_id, source, base_url, protocol)
             VALUES ('openai', 'javascript', 'https://api.openai.com/v1', 'openai-responses');
             INSERT INTO catalog_models(public_model_id, provider_id, source, kind)
             VALUES ('openai/gpt-5', 'openai', 'javascript', 'override')`,
        ),
        sqlite.Result.Ok,
    )

    data, load_err = catalog_data_load(s)
    testing.expect_value(t, load_err, Store_Error.Invalid_Row)
    testing.expect(t, data.providers == nil && data.models == nil, "an unbacked override returns no data")
}

@(test)
test_catalog_schema_rejects_open_or_mixed_arms :: proc(t: ^testing.T) {
    s, err := open_memory()
    testing.expect_value(t, err, nil)
    defer close(s)

    testing.expect_value(
        t,
        sqlite.exec(
            s.writer,
            `INSERT INTO catalog_providers(provider_id, source, models_dev_id, base_url, protocol)
             VALUES ('openai', 'javascript', 'openai', 'https://api.openai.com/v1', 'openai-responses')`,
        ),
        sqlite.Result.Ok,
    )

    invalid := []string {
        `INSERT INTO catalog_providers(provider_id, source, models_dev_id, name, base_url, protocol, etag)
         VALUES ('bad-etag', 'javascript', 'openai', 'Bad', 'https://example.test/v1', 'openai-responses', 'secret')`,
        `INSERT INTO catalog_models(public_model_id, provider_id, source, kind, upstream_id)
         VALUES ('openai/gpt-5', 'openai', 'javascript', 'override', 'must-be-null')`,
        `INSERT INTO catalog_models(public_model_id, provider_id, source, kind)
         VALUES ('openai/gpt-5', 'openai', 'models_dev', 'override')`,
        `INSERT INTO catalog_models(public_model_id, provider_id, source, kind)
         VALUES ('openai/gpt-5', 'openai', 'javascript', 'future')`,
    }
    for sql in invalid {
        testing.expect_value(t, sqlite.exec(s.writer, sql), sqlite.Result.Constraint)
    }

    count, count_err := sqlite.query_one_i64(s.writer, "SELECT count(*) FROM catalog_models")
    testing.expect_value(t, count_err, sqlite.Result.Ok)
    testing.expect_value(t, count, i64(0))
}

@(test)
test_catalog_load_allocation_failures_leak_nothing :: proc(t: ^testing.T) {
    s, err := open_memory()
    testing.expect_value(t, err, nil)
    defer close(s)

    imported_provider := test_catalog_provider(.Models_Dev, "openai")
    imported_model: Catalog_Model = test_catalog_model(.Models_Dev, "openai", "gpt-5")
    testing.expect_value(t, catalog_imported_replace(s, imported_provider, []Catalog_Model{imported_model}), nil)

    javascript_provider := test_catalog_provider(.Javascript, "openai")
    override: Catalog_Model = model_catalog.Model_Override {
        id                = "openai/gpt-5",
        provider_id       = "openai",
        reasoning_levels  = []string{"low", "high"},
        default_reasoning = "high",
    }
    testing.expect_value(
        t,
        catalog_javascript_replace(s, []Catalog_Provider{javascript_provider}, []Catalog_Model{override}),
        nil,
    )

    completed := false
    for fail_at in 0 ..< 128 {
        track: mem.Tracking_Allocator
        mem.tracking_allocator_init(&track, context.allocator)
        tracked := mem.tracking_allocator(&track)

        failing: testsupport.Failing_Allocator
        testsupport.failing_allocator_init(&failing, tracked, fail_at)
        data, load_err := catalog_data_load(s, testsupport.failing_allocator(&failing))

        if load_err == nil {
            completed = true
            catalog_data_destroy(&data)
        } else {
            testing.expect_value(t, load_err, Store_Error.Alloc_Failed)
            testing.expect(t, data.providers == nil && data.models == nil, "a failed load returns no partial records")
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

    imported_provider := test_catalog_provider(.Models_Dev, "a-valid")
    imported_model: Catalog_Model = test_catalog_model(.Models_Dev, "a-valid", "model")
    testing.expect_value(t, catalog_imported_replace(s, imported_provider, []Catalog_Model{imported_model}), nil)
    testing.expect_value(t, sqlite.exec(s.writer, "PRAGMA ignore_check_constraints = ON"), sqlite.Result.Ok)
    testing.expect_value(
        t,
        sqlite.exec(
            s.writer,
            `INSERT INTO catalog_providers(provider_id, source, models_dev_id, name, base_url, protocol)
             VALUES ('z-corrupt', 'future', 'z-corrupt', 'Corrupt', 'https://example.test/v1', 'openai-responses')`,
        ),
        sqlite.Result.Ok,
    )

    track: mem.Tracking_Allocator
    mem.tracking_allocator_init(&track, context.allocator)
    defer mem.tracking_allocator_destroy(&track)

    data, load_err := catalog_data_load(s, mem.tracking_allocator(&track))
    testing.expect_value(t, load_err, Store_Error.Invalid_Row)
    testing.expect(t, data.providers == nil && data.models == nil, "a corrupt suffix returns no valid prefix")
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
            `INSERT INTO catalog_providers(provider_id, source, models_dev_id, name, base_url, protocol)
             VALUES (printf('%1000s', 'x'), 'models_dev', 'openai', 'Corrupt',
                     'https://example.test/v1', 'openai-responses')`,
        ),
        sqlite.Result.Ok,
    )

    failing: testsupport.Failing_Allocator
    testsupport.failing_allocator_init(&failing, context.allocator, 0)
    data, load_err := catalog_data_load(s, testsupport.failing_allocator(&failing))
    testing.expect_value(t, load_err, Store_Error.Invalid_Row)
    testing.expect(t, data.providers == nil && data.models == nil, "invalid borrowed text allocates no output")
}

@(private = "file")
test_catalog_provider :: proc(source: Catalog_Source, id: string) -> Catalog_Provider {
    item := Catalog_Provider {
        id = wire.Provider_Id(id),
        source = source,
        models_dev_id = id,
        name = "OpenAI",
        endpoint = {base_url = "https://api.openai.com/v1", protocol = .Openai_Responses},
        has_endpoint = true,
        credential_env = TEST_CATALOG_ENV[:],
    }
    if source == .Models_Dev {
        item.etag = `"feed-v1"`
    }

    return item
}

@(private = "file")
test_catalog_model :: proc(source: Catalog_Source, provider_id, local_id: string) -> Catalog_Complete_Model {
    public_id := fmt.tprintf("%s/%s", provider_id, local_id)

    return Catalog_Complete_Model {
        source = source,
        model = {
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
            endpoint = {base_url = "https://api.openai.com/v1", protocol = .Openai_Responses},
            supports_temperature = true,
            reasoning_replay = .Reasoning_Details,
            reasoning_format = .Native,
            max_tokens_field = .Max_Tokens,
        },
    }
}
