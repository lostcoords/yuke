package store

import "core:mem"
import "core:strings"
import "core:unicode/utf8"

import model_catalog "src:daemon/catalog"
import "src:daemon/store/queries"
import provider "src:provider"
import wire "src:wire"

import "libs:bindings/sqlite"

CATALOG_PROVIDERS_PER_SOURCE_MAX :: 256
CATALOG_MODELS_PER_SOURCE_MAX :: wire.LIMITS.max_catalog_models
CATALOG_CREDENTIAL_ENV_MAX :: 32
CATALOG_ETAG_MAX_BYTES :: 4096

// Load every provider. A run passes one provider id instead, so it reads only the rows
// that can affect its own model; `?1` is that filter.
CATALOG_ALL_PROVIDERS :: ""

@(private)
CATALOG_PROVIDERS_LOAD_SQL :: `SELECT
    provider_id, source, models_dev_id, name, base_url, protocol, etag
FROM catalog_providers
WHERE (?1 = '' OR provider_id = ?1)
ORDER BY provider_id, source`

@(private)
CATALOG_PROVIDER_ENV_LOAD_SQL :: `SELECT
    e.provider_id, e.source, e.ordinal, e.name,
    (SELECT count(*) FROM catalog_provider_env AS all_env
        WHERE all_env.provider_id = e.provider_id AND all_env.source = e.source) AS total
FROM catalog_provider_env AS e
WHERE (?1 = '' OR e.provider_id = ?1)
ORDER BY e.provider_id, e.source, e.ordinal`

@(private)
CATALOG_MODELS_LOAD_SQL :: `SELECT
    public_model_id, provider_id, source, kind,
    upstream_id, name, context_window, max_output_tokens,
    base_url, protocol, supports_temperature,
    reasoning_replay, reasoning_format, max_tokens_field,
    reasoning_budget_min, reasoning_budget_max,
    supports_vision, supports_tools,
    cost_input, cost_output, cost_cache_read, cost_cache_write
FROM catalog_models
WHERE (?1 = '' OR provider_id = ?1)
ORDER BY public_model_id, source, kind`

// Levels carry no provider id of their own, so the filter joins through the model row
// the levels belong to. The `total` subselect stays unscoped: it counts one model's set.
@(private)
CATALOG_MODEL_LEVELS_LOAD_SQL :: `SELECT
    l.public_model_id, l.source, l.kind, l.ordinal, l.level,
    (SELECT count(*) FROM catalog_model_reasoning_levels AS all_levels
        WHERE all_levels.public_model_id = l.public_model_id
          AND all_levels.source = l.source AND all_levels.kind = l.kind) AS total
FROM catalog_model_reasoning_levels AS l
JOIN catalog_models AS m
    ON m.public_model_id = l.public_model_id AND m.source = l.source AND m.kind = l.kind
WHERE (?1 = '' OR m.provider_id = ?1)
ORDER BY l.public_model_id, l.source, l.kind, l.ordinal`

// Durable origin of a provider/model record. Source stays in every primary key.
Catalog_Source :: enum {
    Models_Dev,
    Javascript,
}

// Whether a model row is a complete inference record or a partial JavaScript overlay.
// Kind stays in the primary key so an overlay never overwrites the record it overlays.
Catalog_Kind :: enum {
    Model,
    Override,
}

@(private, rodata)
catalog_source_string := [Catalog_Source]string {
    .Models_Dev = "models_dev",
    .Javascript = "javascript",
}

@(private, rodata)
catalog_kind_string := [Catalog_Kind]string {
    .Model    = "model",
    .Override = "override",
}

// One source-specific provider. Empty optional strings mean absent; `has_endpoint`
// distinguishes a JavaScript overlay that inherits its endpoint from models.dev.
Catalog_Provider :: struct {
    id:             wire.Provider_Id,
    source:         Catalog_Source,
    models_dev_id:  string,
    name:           string,
    endpoint:       provider.Endpoint,
    has_endpoint:   bool,
    etag:           string,
    credential_env: []string,
}

// A complete imported or custom model, including private inference metadata. The embedded
// `model` is the canonical `catalog.Model` field set shared with the decoder and resolver.
Catalog_Complete_Model :: struct {
    source:      Catalog_Source,
    using model: model_catalog.Model,
}

Catalog_Model :: union {
    Catalog_Complete_Model,
    model_catalog.Model_Override,
}

// Owned raw source records. Complete model provider ids and override provider ids
// borrow their matching provider's owned id; destroy models before providers.
Catalog_Data :: struct {
    providers: [dynamic]Catalog_Provider,
    models:    [dynamic]Catalog_Model,
    allocator: mem.Allocator,
}

@(private)
Catalog_Provider_Row :: struct {
    provider_id:   string `sql:",borrowed"`,
    source:        string `sql:",borrowed"`,
    models_dev_id: Maybe(string) `sql:",borrowed"`,
    name:          Maybe(string) `sql:",borrowed"`,
    base_url:      Maybe(string) `sql:",borrowed"`,
    protocol:      Maybe(string) `sql:",borrowed"`,
    etag:          Maybe(string) `sql:",borrowed"`,
}

@(private)
Catalog_Provider_Env_Row :: struct {
    provider_id: string `sql:",borrowed"`,
    source:      string `sql:",borrowed"`,
    ordinal:     int,
    name:        string `sql:",borrowed"`,
    total:       u64,
}

@(private)
Catalog_Model_Row :: struct {
    public_model_id:      string `sql:",borrowed"`,
    provider_id:          string `sql:",borrowed"`,
    source:               string `sql:",borrowed"`,
    kind:                 string `sql:",borrowed"`,
    upstream_id:          Maybe(string) `sql:",borrowed"`,
    name:                 Maybe(string) `sql:",borrowed"`,
    context_window:       Maybe(u64),
    max_output_tokens:    Maybe(u64),
    base_url:             Maybe(string) `sql:",borrowed"`,
    protocol:             Maybe(string) `sql:",borrowed"`,
    supports_temperature: Maybe(bool),
    reasoning_replay:     Maybe(string) `sql:",borrowed"`,
    reasoning_format:     Maybe(string) `sql:",borrowed"`,
    max_tokens_field:     Maybe(string) `sql:",borrowed"`,
    reasoning_budget_min: Maybe(i64),
    reasoning_budget_max: Maybe(u64),
    supports_vision:      Maybe(bool),
    supports_tools:       Maybe(bool),
    cost_input:           Maybe(f64),
    cost_output:          Maybe(f64),
    cost_cache_read:      Maybe(f64),
    cost_cache_write:     Maybe(f64),
}

@(private)
Catalog_Model_Level_Row :: struct {
    public_model_id: string `sql:",borrowed"`,
    source:          string `sql:",borrowed"`,
    kind:            string `sql:",borrowed"`,
    ordinal:         int,
    level:           string `sql:",borrowed"`,
    total:           u64,
}

// Replace one imported provider snapshot atomically. Other imported providers and
// every JavaScript source row remain untouched if validation or the transaction fails.
catalog_imported_replace :: proc(s: ^Store, item: Catalog_Provider, models: []Catalog_Model) -> (err: Error) {
    assert(s != nil, "catalog_imported_replace needs a store")
    assert(s.writer != nil, "an open store always holds its writer")

    if item.source != .Models_Dev ||
       !catalog_provider_valid(item) ||
       len(models) > CATALOG_MODELS_PER_SOURCE_MAX ||
       !catalog_models_valid(models, []Catalog_Provider{item}, .Models_Dev) {
        return .Invalid_Catalog
    }

    sqlite.txn_begin(s.writer, .Immediate) or_return

    defer if err != nil {
        if rollback := sqlite.txn_rollback(s.writer); rollback != .Ok {
            err = rollback
        }
    }

    queries.delete_catalog_provider(
        &s.queries,
        {provider_id = item.id, source = catalog_source_string[.Models_Dev]},
    ) or_return

    size, size_err := queries.catalog_source_size(&s.queries, {source = catalog_source_string[.Models_Dev]})
    if size_err != nil {
        return read_err(size_err)
    }
    if size.providers >= CATALOG_PROVIDERS_PER_SOURCE_MAX ||
       size.models > u64(CATALOG_MODELS_PER_SOURCE_MAX - len(models)) {
        return .Invalid_Catalog
    }

    catalog_provider_insert(s, item) or_return
    for model in models {
        catalog_model_insert(s, model) or_return
    }
    sqlite.txn_commit(s.writer) or_return

    return nil
}

// Replace the complete startup JavaScript source set atomically. Deleting the old
// source first removes definitions absent from this restart while imported rows survive.
catalog_javascript_replace :: proc(s: ^Store, providers: []Catalog_Provider, models: []Catalog_Model) -> (err: Error) {
    assert(s != nil, "catalog_javascript_replace needs a store")
    assert(s.writer != nil, "an open store always holds its writer")

    if len(providers) > CATALOG_PROVIDERS_PER_SOURCE_MAX ||
       len(models) > CATALOG_MODELS_PER_SOURCE_MAX ||
       !catalog_providers_valid(providers, .Javascript) ||
       !catalog_models_valid(models, providers, .Javascript) {
        return .Invalid_Catalog
    }

    sqlite.txn_begin(s.writer, .Immediate) or_return

    defer if err != nil {
        if rollback := sqlite.txn_rollback(s.writer); rollback != .Ok {
            err = rollback
        }
    }

    queries.delete_catalog_source(&s.queries, {source = catalog_source_string[.Javascript]}) or_return
    for item in providers {
        catalog_provider_insert(s, item) or_return
    }
    for model in models {
        catalog_model_insert(s, model) or_return
    }
    sqlite.txn_commit(s.writer) or_return

    return nil
}

@(private)
catalog_provider_insert :: proc(s: ^Store, item: Catalog_Provider) -> Error {
    assert(s != nil, "catalog provider insert needs a store")
    assert(catalog_provider_valid(item), "catalog provider insert needs validated input")

    params := queries.Insert_Catalog_Provider_Params {
        provider_id = item.id,
        source      = catalog_source_string[item.source],
    }
    if item.models_dev_id != "" {
        params.models_dev_id = item.models_dev_id
    }
    if item.name != "" {
        params.name = item.name
    }
    if item.has_endpoint {
        params.base_url = item.endpoint.base_url
        params.protocol = wire.provider_protocol_to_wire(item.endpoint.protocol)
    }
    if item.etag != "" {
        params.etag = item.etag
    }

    queries.insert_catalog_provider(&s.queries, params) or_return
    for name, ordinal in item.credential_env {
        queries.insert_catalog_provider_env(
            &s.queries,
            {provider_id = item.id, source = catalog_source_string[item.source], ordinal = ordinal, name = name},
        ) or_return
    }

    return nil
}

@(private)
catalog_model_insert :: proc(s: ^Store, value: Catalog_Model) -> Error {
    assert(s != nil, "catalog model insert needs a store")
    assert(value != nil, "catalog model insert needs a model arm")

    params: queries.Insert_Catalog_Model_Params
    levels: []string

    switch model in value {
    case Catalog_Complete_Model:
        assert(catalog_complete_model_valid(model), "catalog model insert needs validated input")
        params = {
            public_model_id      = model.info.id,
            provider_id          = model.info.provider,
            source               = catalog_source_string[model.source],
            kind                 = catalog_kind_string[.Model],
            upstream_id          = model.upstream_id,
            name                 = model.info.name,
            context_window       = model.info.context_window,
            max_output_tokens    = model.info.max_output_tokens,
            base_url             = model.endpoint.base_url,
            protocol             = wire.provider_protocol_to_wire(model.endpoint.protocol),
            supports_temperature = model.supports_temperature,
            reasoning_replay     = model_catalog.reasoning_replay_string[model.reasoning_replay],
            reasoning_format     = model_catalog.reasoning_format_string[model.reasoning_format],
            max_tokens_field     = model_catalog.max_tokens_field_string[model.max_tokens_field],
            reasoning_budget_min = model.reasoning_budget_min,
            reasoning_budget_max = model.reasoning_budget_max,
            supports_vision      = model.info.supports_vision,
            supports_tools       = model.info.supports_tools,
            cost_input           = model.info.cost.input,
            cost_output          = model.info.cost.output,
            cost_cache_read      = model.info.cost.cache_read,
            cost_cache_write     = model.info.cost.cache_write,
        }
        levels = model.info.reasoning_levels

    case model_catalog.Model_Override:
        assert(catalog_override_valid(model), "catalog model insert needs a validated override")
        params = {
            public_model_id = model.id,
            provider_id     = model.provider_id,
            source          = catalog_source_string[.Javascript],
            kind            = catalog_kind_string[.Override],
        }
        levels = model.reasoning_levels
    }

    queries.insert_catalog_model(&s.queries, params) or_return
    for level, ordinal in levels {
        queries.insert_catalog_model_level(
            &s.queries,
            {
                public_model_id = params.public_model_id,
                source = params.source,
                kind = params.kind,
                ordinal = ordinal,
                level = level,
            },
        ) or_return
    }

    return nil
}

// Load every raw source row in stable key order. This does not apply JavaScript
// overlays; it preserves the records the later resolver must compare.
catalog_data_load :: proc(
    s: ^Store,
    provider_id: string,
    allocator := context.allocator,
) -> (
    data: Catalog_Data,
    err: Error,
) {
    assert(s != nil, "catalog_data_load needs a store")
    assert(s.writer != nil, "an open store always holds its writer")
    assert(allocator.procedure != nil, "a catalog read needs an allocator")

    loaded: Catalog_Data
    loaded.allocator = allocator
    loaded.providers.allocator = allocator
    loaded.models.allocator = allocator
    defer if err != nil {
        catalog_data_destroy(&loaded)
    }

    catalog_providers_load(s, &loaded, provider_id) or_return
    catalog_provider_env_load(s, &loaded, provider_id) or_return
    catalog_models_load(s, &loaded, provider_id) or_return
    catalog_model_levels_load(s, &loaded, provider_id) or_return

    for &model in loaded.models {
        catalog_loaded_model_finalize(&model, allocator) or_return
    }
    if !catalog_loaded_data_valid(loaded) {
        return {}, .Invalid_Row
    }

    return loaded, nil
}

catalog_data_destroy :: proc(data: ^Catalog_Data) {
    assert(data != nil, "catalog_data_destroy needs data")
    assert(data.allocator.procedure != nil, "owned catalog data carries its allocator")

    for &model in data.models {
        catalog_model_destroy(&model, data.allocator)
    }
    delete(data.models)

    for &item in data.providers {
        catalog_provider_destroy(&item, data.allocator)
    }
    delete(data.providers)
    data^ = {}
}

@(private)
catalog_providers_load :: proc(s: ^Store, data: ^Catalog_Data, provider_id: string) -> Error {
    assert(s != nil, "catalog provider load needs a store")
    assert(data != nil, "catalog provider load needs output data")
    assert(len(data.providers) == 0, "catalog provider load starts empty")

    st := sqlite.prepare(s.writer, CATALOG_PROVIDERS_LOAD_SQL) or_return
    defer sqlite.finalize(st)
    sqlite.bind_text(st, 1, provider_id) or_return

    for {
        if has_row := sqlite.step_row(st) or_return; !has_row {
            break
        }

        row: Catalog_Provider_Row
        sqlite.scan_row(st, &row, data.allocator) or_return
        item := catalog_provider_from_row(row, data.allocator) or_return

        if len(data.providers) >= CATALOG_PROVIDERS_PER_SOURCE_MAX * len(Catalog_Source) {
            catalog_provider_destroy(&item, data.allocator)
            return .Invalid_Row
        }
        if _, append_err := append(&data.providers, item); append_err != nil {
            catalog_provider_destroy(&item, data.allocator)
            return .Alloc_Failed
        }
    }

    return nil
}

@(private)
catalog_provider_from_row :: proc(
    row: Catalog_Provider_Row,
    allocator: mem.Allocator,
) -> (
    item: Catalog_Provider,
    err: Error,
) {
    defer if err != nil {
        catalog_provider_destroy(&item, allocator)
    }

    source, source_ok := catalog_source_from_string(row.source)
    if !source_ok {
        return item, .Invalid_Row
    }

    models_dev_id, has_models_dev := row.models_dev_id.?
    name, has_name := row.name.?
    base_url, has_base_url := row.base_url.?
    protocol_name, has_protocol := row.protocol.?
    etag, has_etag := row.etag.?
    if has_base_url != has_protocol {
        return item, .Invalid_Row
    }

    protocol: wire.Provider_Protocol
    if has_base_url {
        protocol_ok: bool
        protocol, protocol_ok = wire.provider_protocol_from_wire(protocol_name)
        if !protocol_ok {
            return item, .Invalid_Row
        }
    }

    borrowed := Catalog_Provider {
        id = wire.Provider_Id(row.provider_id),
        source = source,
        models_dev_id = models_dev_id,
        name = name,
        endpoint = {base_url = base_url, protocol = protocol},
        has_endpoint = has_base_url,
        etag = etag,
        credential_env = nil,
    }
    if !catalog_provider_valid(borrowed) {
        return item, .Invalid_Row
    }

    item.source = source
    item.has_endpoint = has_base_url
    item.endpoint.protocol = protocol
    item.id = wire.Provider_Id(catalog_string_clone(row.provider_id, allocator) or_return)
    if has_models_dev {
        item.models_dev_id = catalog_string_clone(models_dev_id, allocator) or_return
    }
    if has_name {
        item.name = catalog_string_clone(name, allocator) or_return
    }
    if has_base_url {
        item.endpoint.base_url = catalog_string_clone(base_url, allocator) or_return
    }
    if has_etag {
        item.etag = catalog_string_clone(etag, allocator) or_return
    }

    return item, nil
}

@(private)
catalog_provider_env_load :: proc(s: ^Store, data: ^Catalog_Data, provider_id: string) -> Error {
    assert(s != nil, "catalog provider environment load needs a store")
    assert(data != nil, "catalog provider environment load needs output data")

    st := sqlite.prepare(s.writer, CATALOG_PROVIDER_ENV_LOAD_SQL) or_return
    defer sqlite.finalize(st)
    sqlite.bind_text(st, 1, provider_id) or_return

    for {
        if has_row := sqlite.step_row(st) or_return; !has_row {
            break
        }

        row: Catalog_Provider_Env_Row
        sqlite.scan_row(st, &row, data.allocator) or_return
        source, source_ok := catalog_source_from_string(row.source)
        if !source_ok || !model_catalog.env_name_valid(row.name) {
            return .Invalid_Row
        }

        provider_index, provider_ok := catalog_provider_find(data.providers[:], row.provider_id, source)
        if !provider_ok ||
           row.total == 0 ||
           row.total > CATALOG_CREDENTIAL_ENV_MAX ||
           row.ordinal < 0 ||
           u64(row.ordinal) >= row.total {
            return .Invalid_Row
        }

        item := &data.providers[provider_index]
        catalog_ordinal_fill(&item.credential_env, row.ordinal, row.total, row.name, data.allocator) or_return
    }

    return nil
}

@(private)
catalog_models_load :: proc(s: ^Store, data: ^Catalog_Data, provider_id: string) -> Error {
    assert(s != nil, "catalog model load needs a store")
    assert(data != nil, "catalog model load needs output data")
    assert(len(data.models) == 0, "catalog model load starts empty")

    st := sqlite.prepare(s.writer, CATALOG_MODELS_LOAD_SQL) or_return
    defer sqlite.finalize(st)
    sqlite.bind_text(st, 1, provider_id) or_return

    for {
        if has_row := sqlite.step_row(st) or_return; !has_row {
            break
        }

        row: Catalog_Model_Row
        sqlite.scan_row(st, &row, data.allocator) or_return
        model := catalog_model_from_row(row, data, data.allocator) or_return

        if len(data.models) >= CATALOG_MODELS_PER_SOURCE_MAX * len(Catalog_Source) {
            catalog_model_destroy(&model, data.allocator)
            return .Invalid_Row
        }
        if _, append_err := append(&data.models, model); append_err != nil {
            catalog_model_destroy(&model, data.allocator)
            return .Alloc_Failed
        }
    }

    return nil
}

@(private)
catalog_model_from_row :: proc(
    row: Catalog_Model_Row,
    data: ^Catalog_Data,
    allocator: mem.Allocator,
) -> (
    model: Catalog_Model,
    err: Error,
) {
    assert(data != nil, "catalog model row needs provider data")
    defer if err != nil {
        catalog_model_destroy(&model, allocator)
    }

    source, source_ok := catalog_source_from_string(row.source)
    if !source_ok {
        return nil, .Invalid_Row
    }
    provider_index, provider_ok := catalog_provider_find(data.providers[:], row.provider_id, source)
    if !provider_ok {
        return nil, .Invalid_Row
    }
    provider_id := data.providers[provider_index].id

    kind, kind_ok := catalog_kind_from_string(row.kind)
    if !kind_ok {
        return nil, .Invalid_Row
    }

    // Every row is first assembled borrowing the SQLite columns and validated in that
    // form; only a row that passes is cloned into owned storage.
    borrowed: Catalog_Model
    switch kind {
    case .Model:
        complete, complete_ok := catalog_complete_model_from_row(row, source, provider_id)
        if !complete_ok {
            return nil, .Invalid_Row
        }
        borrowed = complete

    case .Override:
        if source != .Javascript || !catalog_model_row_is_override(row) {
            return nil, .Invalid_Row
        }
        borrowed = model_catalog.Model_Override {
            id          = wire.Model_Id(row.public_model_id),
            provider_id = provider_id,
        }
    }

    if !catalog_model_provider_valid(borrowed, data.providers[provider_index]) {
        return nil, .Invalid_Row
    }

    switch value in borrowed {
    case Catalog_Complete_Model:
        owned, clone_err := model_catalog.model_clone(value.model, wire.Provider_Id(provider_id), allocator)
        if clone_err != nil {
            return nil, .Alloc_Failed
        }
        model = Catalog_Complete_Model {
            source = source,
            model  = owned,
        }

    case model_catalog.Model_Override:
        model = model_catalog.Model_Override {
            id          = wire.Model_Id(catalog_string_clone(row.public_model_id, allocator) or_return),
            provider_id = provider_id,
        }
    }

    return model, nil
}

// Assemble a complete model borrowing the row's columns. Every complete-model column is
// required; the schema enforces the same shape, so a missing one is a corrupt row.
@(private)
catalog_complete_model_from_row :: proc(
    row: Catalog_Model_Row,
    source: Catalog_Source,
    provider_id: string,
) -> (
    model: Catalog_Complete_Model,
    ok: bool,
) {
    upstream_id, has_upstream := row.upstream_id.?
    name, has_name := row.name.?
    context_window, has_context := row.context_window.?
    max_output_tokens, has_output := row.max_output_tokens.?
    base_url, has_base_url := row.base_url.?
    protocol_name, has_protocol := row.protocol.?
    supports_temperature, has_temperature := row.supports_temperature.?
    replay_name, has_replay := row.reasoning_replay.?
    format_name, has_format := row.reasoning_format.?
    max_tokens_name, has_max_tokens := row.max_tokens_field.?
    supports_vision, has_vision := row.supports_vision.?
    supports_tools, has_tools := row.supports_tools.?
    cost_input, has_cost_input := row.cost_input.?
    cost_output, has_cost_output := row.cost_output.?
    cost_cache_read, has_cost_read := row.cost_cache_read.?
    cost_cache_write, has_cost_write := row.cost_cache_write.?
    if !has_upstream ||
       !has_name ||
       !has_context ||
       !has_output ||
       !has_base_url ||
       !has_protocol ||
       !has_temperature ||
       !has_replay ||
       !has_format ||
       !has_max_tokens ||
       !has_vision ||
       !has_tools ||
       !has_cost_input ||
       !has_cost_output ||
       !has_cost_read ||
       !has_cost_write {
        return {}, false
    }

    protocol, protocol_ok := wire.provider_protocol_from_wire(protocol_name)
    replay, replay_ok := model_catalog.reasoning_replay_from_string(replay_name)
    format, format_ok := model_catalog.reasoning_format_from_string(format_name)
    max_tokens_field, max_tokens_ok := model_catalog.max_tokens_field_from_string(max_tokens_name)
    if !protocol_ok || !replay_ok || !format_ok || !max_tokens_ok {
        return {}, false
    }

    return Catalog_Complete_Model {
            source = source,
            model = {
                info = {
                    id = wire.Model_Id(row.public_model_id),
                    provider = provider_id,
                    name = name,
                    context_window = context_window,
                    max_output_tokens = max_output_tokens,
                    supports_vision = supports_vision,
                    supports_tools = supports_tools,
                    cost = {
                        input = cost_input,
                        output = cost_output,
                        cache_read = cost_cache_read,
                        cache_write = cost_cache_write,
                    },
                },
                upstream_id = upstream_id,
                endpoint = {base_url = base_url, protocol = protocol},
                supports_temperature = supports_temperature,
                reasoning_replay = replay,
                reasoning_format = format,
                reasoning_budget_min = row.reasoning_budget_min,
                reasoning_budget_max = row.reasoning_budget_max,
                max_tokens_field = max_tokens_field,
            },
        },
        true
}

@(private)
catalog_model_levels_load :: proc(s: ^Store, data: ^Catalog_Data, provider_id: string) -> Error {
    assert(s != nil, "catalog model level load needs a store")
    assert(data != nil, "catalog model level load needs output data")

    st := sqlite.prepare(s.writer, CATALOG_MODEL_LEVELS_LOAD_SQL) or_return
    defer sqlite.finalize(st)
    sqlite.bind_text(st, 1, provider_id) or_return

    for {
        if has_row := sqlite.step_row(st) or_return; !has_row {
            break
        }

        row: Catalog_Model_Level_Row
        sqlite.scan_row(st, &row, data.allocator) or_return
        source, source_ok := catalog_source_from_string(row.source)
        kind, kind_ok := catalog_kind_from_string(row.kind)
        if !source_ok || !kind_ok || !catalog_bounded_string_valid(row.level, 32) {
            return .Invalid_Row
        }

        model_index, model_ok := catalog_model_find(data.models[:], row.public_model_id, source, kind)
        if !model_ok ||
           row.total == 0 ||
           row.total > u64(wire.LIMITS.max_reasoning_levels) ||
           row.ordinal < 0 ||
           u64(row.ordinal) >= row.total {
            return .Invalid_Row
        }

        levels := catalog_model_levels(&data.models[model_index])
        catalog_ordinal_fill(levels, row.ordinal, row.total, row.level, data.allocator) or_return
    }

    return nil
}

@(private)
catalog_loaded_model_finalize :: proc(model: ^Catalog_Model, allocator: mem.Allocator) -> Error {
    assert(model != nil, "catalog loaded model finalization needs a model")
    assert(model^ != nil, "catalog loaded model finalization needs an arm")

    levels := catalog_model_levels(model)^
    derived := model_catalog.default_reasoning_level(levels)
    owned := catalog_string_clone(derived, allocator) or_return

    switch &value in model {
    case Catalog_Complete_Model:
        assert(value.info.default_reasoning == "", "loaded complete model derives its default once")
        value.info.default_reasoning = owned

    case model_catalog.Model_Override:
        assert(value.default_reasoning == "", "loaded override derives its default once")
        value.default_reasoning = owned
    }

    return nil
}

@(private)
catalog_providers_valid :: proc(items: []Catalog_Provider, source: Catalog_Source) -> bool {
    if len(items) > CATALOG_PROVIDERS_PER_SOURCE_MAX {
        return false
    }

    for item, i in items {
        if item.source != source || !catalog_provider_valid(item) {
            return false
        }

        for previous in items[:i] {
            if previous.id == item.id {
                return false
            }
        }
    }

    return true
}

@(private)
catalog_provider_valid :: proc(item: Catalog_Provider) -> bool {
    if wire.provider_id_validate(item.id) != .None || len(item.credential_env) > CATALOG_CREDENTIAL_ENV_MAX {
        return false
    }

    switch item.source {
    case .Models_Dev:
        if wire.provider_id_validate(item.models_dev_id) != .None ||
           !catalog_bounded_string_valid(item.name, 128) ||
           !item.has_endpoint {
            return false
        }

    case .Javascript:
        if item.etag != "" || (!item.has_endpoint && item.models_dev_id == "") {
            return false
        }
        if item.models_dev_id != "" && wire.provider_id_validate(item.models_dev_id) != .None {
            return false
        }
        if item.name != "" && !catalog_bounded_string_valid(item.name, 128) {
            return false
        }
    }

    if item.has_endpoint {
        if !catalog_bounded_string_valid(item.endpoint.base_url, 4096) ||
           provider.endpoint_validate(item.endpoint) != .None {
            return false
        }
    } else if item.endpoint.base_url != "" || item.endpoint.protocol != .Anthropic_Messages {
        return false
    }

    if item.etag != "" && !catalog_bounded_string_valid(item.etag, CATALOG_ETAG_MAX_BYTES) {
        return false
    }

    for name, i in item.credential_env {
        if !model_catalog.env_name_valid(name) {
            return false
        }

        for previous in item.credential_env[:i] {
            if previous == name {
                return false
            }
        }
    }

    return true
}

@(private)
catalog_models_valid :: proc(models: []Catalog_Model, providers: []Catalog_Provider, source: Catalog_Source) -> bool {
    if len(models) > CATALOG_MODELS_PER_SOURCE_MAX {
        return false
    }

    for model, i in models {
        if model == nil {
            return false
        }

        provider_id, model_source, kind := catalog_model_key(model)
        if model_source != source {
            return false
        }
        provider_index, found := catalog_provider_find(providers, provider_id, source)
        if !found {
            return false
        }
        if !catalog_model_provider_valid(model, providers[provider_index]) {
            return false
        }

        public_id := catalog_model_public_id(model)
        for previous in models[:i] {
            _, previous_source, previous_kind := catalog_model_key(previous)
            if catalog_model_public_id(previous) == public_id &&
               previous_source == model_source &&
               previous_kind == kind {
                return false
            }
        }
    }

    return true
}

@(private)
catalog_model_provider_valid :: proc(model: Catalog_Model, item: Catalog_Provider) -> bool {
    if model == nil {
        return false
    }

    provider_id, source, _ := catalog_model_key(model)
    if item.id != provider_id || item.source != source {
        return false
    }

    switch value in model {
    case Catalog_Complete_Model:
        return(
            catalog_complete_model_valid(value) &&
            (source != .Javascript || (item.has_endpoint && item.endpoint == value.endpoint)) \
        )

    case model_catalog.Model_Override:
        return source == .Javascript && item.models_dev_id != "" && catalog_override_valid(value)
    }

    unreachable()
}

@(private)
catalog_complete_model_valid :: proc(model: Catalog_Complete_Model) -> bool {
    if wire.model_info_validate(model.info) != .None ||
       wire.provider_id_validate(model.info.provider) != .None ||
       !catalog_public_model_id_valid(model.info.id, model.info.provider) ||
       !catalog_bounded_string_valid(model.info.name, 128) ||
       !catalog_bounded_string_valid(model.upstream_id, 128) ||
       model.info.context_window == 0 ||
       model.info.context_window > wire.MAX_WIRE_INTEGER ||
       model.info.max_output_tokens == 0 ||
       model.info.max_output_tokens > wire.MAX_WIRE_INTEGER ||
       !catalog_bounded_string_valid(model.endpoint.base_url, 4096) ||
       provider.endpoint_validate(model.endpoint) != .None ||
       !catalog_reasoning_levels_valid(model.info.reasoning_levels, model.info.default_reasoning) ||
       !model_catalog.reasoning_format_compatible(model.endpoint.protocol, model.reasoning_format) {
        return false
    }

    if minimum, has_minimum := model.reasoning_budget_min.?; has_minimum {
        if minimum < -1 || minimum > wire.MAX_WIRE_INTEGER {
            return false
        }
    }
    if maximum, has_maximum := model.reasoning_budget_max.?; has_maximum {
        if maximum > u64(wire.MAX_WIRE_INTEGER) {
            return false
        }
    }
    if minimum, has_minimum := model.reasoning_budget_min.?; has_minimum {
        if maximum, has_maximum := model.reasoning_budget_max.?; has_maximum && minimum > i64(maximum) {
            return false
        }
    }

    return true
}

@(private)
catalog_override_valid :: proc(model: model_catalog.Model_Override) -> bool {
    return(
        wire.provider_id_validate(model.provider_id) == .None &&
        catalog_public_model_id_valid(model.id, model.provider_id) &&
        catalog_reasoning_levels_valid(model.reasoning_levels, model.default_reasoning) \
    )
}

@(private)
catalog_reasoning_levels_valid :: proc(levels: []string, default: string) -> bool {
    if len(levels) > wire.LIMITS.max_reasoning_levels || default != model_catalog.default_reasoning_level(levels) {
        return false
    }

    for level, i in levels {
        if !catalog_bounded_string_valid(level, 32) {
            return false
        }

        for previous in levels[:i] {
            if previous == level {
                return false
            }
        }
    }

    return true
}

@(private)
catalog_public_model_id_valid :: proc(id: wire.Model_Id, provider_id: wire.Provider_Id) -> bool {
    if !catalog_bounded_string_valid(id, 128) ||
       len(id) <= len(provider_id) + 1 ||
       !strings.has_prefix(id, provider_id) ||
       id[len(provider_id)] != '/' {
        return false
    }

    return utf8.valid_string(id[len(provider_id) + 1:])
}

@(private)
catalog_loaded_data_valid :: proc(data: Catalog_Data) -> bool {
    providers_by_source: [Catalog_Source]int
    for item, i in data.providers {
        providers_by_source[item.source] += 1
        if providers_by_source[item.source] > CATALOG_PROVIDERS_PER_SOURCE_MAX || !catalog_provider_valid(item) {
            return false
        }

        for previous in data.providers[:i] {
            if previous.id == item.id && previous.source == item.source {
                return false
            }
        }
    }

    models_by_source: [Catalog_Source]int
    for model, i in data.models {
        provider_id, source, kind := catalog_model_key(model)
        models_by_source[source] += 1
        if models_by_source[source] > CATALOG_MODELS_PER_SOURCE_MAX {
            return false
        }
        provider_index, found := catalog_provider_find(data.providers[:], provider_id, source)
        if !found || !catalog_model_provider_valid(model, data.providers[provider_index]) {
            return false
        }

        for previous in data.models[:i] {
            _, previous_source, previous_kind := catalog_model_key(previous)
            if catalog_model_public_id(previous) == catalog_model_public_id(model) &&
               previous_source == source &&
               previous_kind == kind {
                return false
            }
        }
    }

    return true
}

// An override row carries only its key: every complete-model column must be NULL.
@(private)
catalog_model_row_is_override :: proc(row: Catalog_Model_Row) -> bool {
    present :=
        row.upstream_id != nil ||
        row.name != nil ||
        row.context_window != nil ||
        row.max_output_tokens != nil ||
        row.base_url != nil ||
        row.protocol != nil ||
        row.supports_temperature != nil ||
        row.reasoning_replay != nil ||
        row.reasoning_format != nil ||
        row.max_tokens_field != nil ||
        row.reasoning_budget_min != nil ||
        row.reasoning_budget_max != nil ||
        row.supports_vision != nil ||
        row.supports_tools != nil ||
        row.cost_input != nil ||
        row.cost_output != nil ||
        row.cost_cache_read != nil ||
        row.cost_cache_write != nil

    return !present
}

@(private)
catalog_provider_find :: proc(
    providers: []Catalog_Provider,
    provider_id: string,
    source: Catalog_Source,
) -> (
    index: int,
    found: bool,
) {
    for item, i in providers {
        if item.id == provider_id && item.source == source {
            return i, true
        }
    }

    return -1, false
}

@(private)
catalog_model_find :: proc(
    models: []Catalog_Model,
    public_model_id: string,
    source: Catalog_Source,
    kind: Catalog_Kind,
) -> (
    index: int,
    found: bool,
) {
    for model, i in models {
        _, model_source, model_kind := catalog_model_key(model)
        if catalog_model_public_id(model) == public_model_id && model_source == source && model_kind == kind {
            return i, true
        }
    }

    return -1, false
}

@(private)
catalog_model_key :: proc(model: Catalog_Model) -> (provider_id: string, source: Catalog_Source, kind: Catalog_Kind) {
    assert(model != nil, "a catalog model key needs an arm")

    switch value in model {
    case Catalog_Complete_Model:
        return value.info.provider, value.source, .Model

    case model_catalog.Model_Override:
        return value.provider_id, .Javascript, .Override
    }

    unreachable()
}

@(private)
catalog_model_public_id :: proc(model: Catalog_Model) -> string {
    assert(model != nil, "a catalog model id needs an arm")

    switch value in model {
    case Catalog_Complete_Model:
        return value.info.id

    case model_catalog.Model_Override:
        return value.id
    }

    unreachable()
}

@(private)
catalog_model_levels :: proc(model: ^Catalog_Model) -> ^[]string {
    assert(model != nil, "catalog model levels need a model")
    assert(model^ != nil, "catalog model levels need an arm")

    switch &value in model {
    case Catalog_Complete_Model:
        return &value.info.reasoning_levels

    case model_catalog.Model_Override:
        return &value.reasoning_levels
    }

    unreachable()
}

@(private)
catalog_provider_destroy :: proc(item: ^Catalog_Provider, allocator: mem.Allocator) {
    assert(item != nil, "catalog provider cleanup needs a provider")

    delete(item.id, allocator)
    delete(item.models_dev_id, allocator)
    delete(item.name, allocator)
    delete(item.endpoint.base_url, allocator)
    delete(item.etag, allocator)
    for name in item.credential_env {
        delete(name, allocator)
    }
    delete(item.credential_env, allocator)
    item^ = {}
}

@(private)
catalog_model_destroy :: proc(model: ^Catalog_Model, allocator: mem.Allocator) {
    assert(model != nil, "catalog model cleanup needs a model")

    switch &value in model {
    case Catalog_Complete_Model:
        model_catalog.model_destroy(&value.model, allocator)

    case model_catalog.Model_Override:
        model_catalog.model_override_destroy(&value, allocator)

    case nil:
    }
    model^ = nil
}

@(private)
catalog_string_clone :: proc(value: string, allocator: mem.Allocator) -> (owned: string, err: Error) {
    allocation_err: mem.Allocator_Error
    owned, allocation_err = strings.clone(value, allocator)
    if allocation_err != nil {
        return "", .Alloc_Failed
    }

    return owned, nil
}

// Place one ordinal-indexed value into an owned slice reconstructed from source rows.
// `ordinal == 0` allocates at the declared total; later ordinals require the same total.
@(private)
catalog_ordinal_fill :: proc(
    slot: ^[]string,
    ordinal: int,
    total: u64,
    value: string,
    allocator: mem.Allocator,
) -> Error {
    assert(slot != nil, "ordinal fill needs a slot")
    assert(ordinal >= 0 && u64(ordinal) < total, "ordinal fill stays within its total")

    if ordinal == 0 {
        if slot^ != nil {
            return .Invalid_Row
        }

        allocation_err: mem.Allocator_Error
        slot^, allocation_err = make([]string, int(total), allocator)
        if allocation_err != nil {
            return .Alloc_Failed
        }
    } else if len(slot^) != int(total) {
        return .Invalid_Row
    }

    if slot^[ordinal] != "" {
        return .Invalid_Row
    }
    slot^[ordinal] = catalog_string_clone(value, allocator) or_return

    return nil
}

@(private)
catalog_bounded_string_valid :: proc(value: string, max_bytes: int) -> bool {
    assert(max_bytes > 0, "a catalog string bound is positive")

    return len(value) > 0 && len(value) <= max_bytes && utf8.valid_string(value)
}

@(private)
catalog_source_from_string :: proc(value: string) -> (Catalog_Source, bool) {
    for candidate, source in catalog_source_string {
        if candidate == value {
            return source, true
        }
    }

    return {}, false
}

@(private)
catalog_kind_from_string :: proc(value: string) -> (Catalog_Kind, bool) {
    for candidate, kind in catalog_kind_string {
        if candidate == value {
            return kind, true
        }
    }

    return {}, false
}
