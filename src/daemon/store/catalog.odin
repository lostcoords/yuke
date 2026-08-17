package store

import "core:mem"
import "core:strings"
import "core:unicode/utf8"

import model_catalog "src:daemon/catalog"
import "src:daemon/store/queries"
import "src:provider"
import "src:wire"

import "libs:bindings/sqlite"

CATALOG_PROVIDERS_MAX :: 256
CATALOG_MODELS_MAX :: wire.LIMITS.max_catalog_models
CATALOG_CREDENTIAL_ENV_MAX :: 32
CATALOG_ETAG_MAX_BYTES :: 4096

@(private)
CATALOG_PROVIDERS_LOAD_SQL :: `SELECT
    provider_id, models_dev_id, name, base_url, protocol, etag
FROM catalog_providers
ORDER BY provider_id`

@(private)
CATALOG_PROVIDER_ENV_LOAD_SQL :: `SELECT
    e.provider_id, e.ordinal, e.name,
    (SELECT count(*) FROM catalog_provider_env AS all_env
        WHERE all_env.provider_id = e.provider_id) AS total
FROM catalog_provider_env AS e
ORDER BY e.provider_id, e.ordinal`

@(private)
CATALOG_MODELS_LOAD_SQL :: `SELECT
    public_model_id, provider_id,
    upstream_id, name, context_window, max_output_tokens,
    base_url, protocol, supports_temperature,
    reasoning_replay, thinking_format, anthropic_adaptive, max_tokens_field,
    reasoning_budget_min, reasoning_budget_max,
    supports_vision, supports_tools,
    cost_input, cost_output, cost_cache_read, cost_cache_write
FROM catalog_models
ORDER BY public_model_id`

// The `total` subselect counts one model's level set.
@(private)
CATALOG_MODEL_LEVELS_LOAD_SQL :: `SELECT
    l.public_model_id, l.ordinal, l.level,
    (SELECT count(*) FROM catalog_model_reasoning_levels AS all_levels
        WHERE all_levels.public_model_id = l.public_model_id) AS total
FROM catalog_model_reasoning_levels AS l
ORDER BY l.public_model_id, l.ordinal`

// The whole persisted catalog, owned and nested the way every reader wants it. `feed_etag`
// is the feed's own validator, written onto every provider row and read back once here.
Catalog :: struct {
    providers: [dynamic]model_catalog.Provider,
    feed_etag: string,
    allocator: mem.Allocator,
}

catalog_destroy :: proc(catalog: ^Catalog) {
    assert(catalog != nil, "catalog cleanup needs a catalog")
    assert(catalog.allocator.procedure != nil, "an owned catalog carries its allocator")

    for &item in catalog.providers {
        model_catalog.provider_destroy(&item, catalog.allocator)
    }

    delete(catalog.providers)
    delete(catalog.feed_etag, catalog.allocator)
    catalog^ = {}
}

@(private)
Catalog_Provider_Row :: struct {
    provider_id:   string `sql:",borrowed"`,
    models_dev_id: string `sql:",borrowed"`,
    name:          string `sql:",borrowed"`,
    base_url:      string `sql:",borrowed"`,
    protocol:      string `sql:",borrowed"`,
    etag:          Maybe(string) `sql:",borrowed"`,
}

@(private)
Catalog_Provider_Env_Row :: struct {
    provider_id: string `sql:",borrowed"`,
    ordinal:     int,
    name:        string `sql:",borrowed"`,
    total:       u64,
}

@(private)
Catalog_Model_Row :: struct {
    public_model_id:      string `sql:",borrowed"`,
    provider_id:          string `sql:",borrowed"`,
    upstream_id:          string `sql:",borrowed"`,
    name:                 string `sql:",borrowed"`,
    context_window:       u64,
    max_output_tokens:    u64,
    base_url:             string `sql:",borrowed"`,
    protocol:             string `sql:",borrowed"`,
    supports_temperature: bool,
    reasoning_replay:     string `sql:",borrowed"`,
    thinking_format:      string `sql:",borrowed"`,
    anthropic_adaptive:   bool,
    max_tokens_field:     string `sql:",borrowed"`,
    reasoning_budget_min: Maybe(i64),
    reasoning_budget_max: Maybe(u64),
    supports_vision:      bool,
    supports_tools:       bool,
    cost_input:           f64,
    cost_output:          f64,
    cost_cache_read:      f64,
    cost_cache_write:     f64,
}

@(private)
Catalog_Model_Level_Row :: struct {
    public_model_id: string `sql:",borrowed"`,
    ordinal:         int,
    level:           string `sql:",borrowed"`,
    total:           u64,
}

// Replace one provider's snapshot atomically, models and all; other providers are untouched
// if validation or the transaction fails.
catalog_imported_replace :: proc(s: ^Store, item: model_catalog.Provider, feed_etag: string) -> (err: Error) {
    assert(s != nil, "catalog_imported_replace needs a store")
    assert(s.writer != nil, "an open store always holds its writer")

    if !catalog_provider_valid(item, feed_etag) || len(item.models) > CATALOG_MODELS_MAX {
        return .Invalid_Catalog
    }

    for model, index in item.models {
        if !catalog_model_valid(model) || model.info.provider != item.id {
            return .Invalid_Catalog
        }

        for previous in item.models[:index] {
            if previous.info.id == model.info.id {
                return .Invalid_Catalog
            }
        }
    }

    sqlite.txn_begin(s.writer, .Immediate) or_return

    defer if err != nil {
        if rollback := sqlite.txn_rollback(s.writer); rollback != .Ok {
            err = rollback
        }
    }

    queries.delete_catalog_provider(&s.queries, {provider_id = item.id}) or_return

    size, size_err := queries.catalog_size(&s.queries, {})
    if size_err != nil {
        return read_err(size_err)
    }
    if size.providers >= CATALOG_PROVIDERS_MAX || size.models > u64(CATALOG_MODELS_MAX - len(item.models)) {
        return .Invalid_Catalog
    }

    catalog_provider_insert(s, item, feed_etag) or_return
    for model in item.models {
        catalog_model_insert(s, model) or_return
    }
    sqlite.txn_commit(s.writer) or_return

    return nil
}

// Drop every provider's feed validator (etag -> NULL) so the next refresh refetches unconditionally.
catalog_feed_etag_clear :: proc(s: ^Store) -> Error {
    assert(s != nil, "catalog_feed_etag_clear needs a store")
    assert(s.writer != nil, "an open store always holds its writer")

    return queries.clear_catalog_etag(&s.queries, {})
}

@(private)
catalog_provider_insert :: proc(s: ^Store, item: model_catalog.Provider, feed_etag: string) -> Error {
    assert(s != nil, "catalog provider insert needs a store")
    assert(catalog_provider_valid(item, feed_etag), "catalog provider insert needs validated input")

    params := queries.Insert_Catalog_Provider_Params {
        provider_id   = item.id,
        models_dev_id = item.source_id,
        name          = item.name,
        base_url      = item.endpoint.base_url,
        protocol      = wire.provider_protocol_to_wire(item.endpoint.protocol),
    }

    if feed_etag != "" {
        params.etag = feed_etag
    }

    queries.insert_catalog_provider(&s.queries, params) or_return
    for name, ordinal in item.credential_env {
        queries.insert_catalog_provider_env(
            &s.queries,
            {provider_id = item.id, ordinal = ordinal, name = name},
        ) or_return
    }

    return nil
}

@(private)
catalog_model_insert :: proc(s: ^Store, model: model_catalog.Model) -> Error {
    assert(s != nil, "catalog model insert needs a store")
    assert(catalog_model_valid(model), "catalog model insert needs validated input")

    params := queries.Insert_Catalog_Model_Params {
        public_model_id      = model.info.id,
        provider_id          = model.info.provider,
        upstream_id          = model.upstream_id,
        name                 = model.info.name,
        context_window       = model.info.context_window,
        max_output_tokens    = model.info.max_output_tokens,
        base_url             = model.endpoint.base_url,
        protocol             = wire.provider_protocol_to_wire(model.endpoint.protocol),
        supports_temperature = model.supports_temperature,
        reasoning_replay     = model_catalog.reasoning_replay_string[model.reasoning_replay],
        thinking_format      = model_catalog.thinking_format_string[model.thinking_format],
        anthropic_adaptive   = model.anthropic_adaptive,
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

    queries.insert_catalog_model(&s.queries, params) or_return
    for level, ordinal in model.info.reasoning_levels {
        queries.insert_catalog_model_level(
            &s.queries,
            {public_model_id = params.public_model_id, ordinal = ordinal, level = level},
        ) or_return
    }

    return nil
}

// Read the whole catalog back. Every string is owned by `allocator` and nothing is freed
// piecemeal — `catalog_destroy` reclaims it all.
catalog_load :: proc(s: ^Store, allocator := context.allocator) -> (catalog: Catalog, err: Error) {
    assert(s != nil, "catalog_load needs a store")
    assert(s.writer != nil, "an open store always holds its writer")
    assert(allocator.procedure != nil, "a catalog read needs an allocator")

    loaded: Catalog
    loaded.allocator = allocator
    loaded.providers.allocator = allocator
    defer if err != nil {
        catalog_destroy(&loaded)
    }

    catalog_providers_load(s, &loaded) or_return
    catalog_provider_env_load(s, &loaded) or_return
    catalog_models_load(s, &loaded) or_return
    catalog_model_levels_load(s, &loaded) or_return

    for &item in loaded.providers {
        for &model in item.models {
            catalog_loaded_model_finalize(&model, allocator) or_return
        }

        // The order is what a client pages against, so it is checked rather than assumed.
        for model, index in item.models {
            if index > 0 && !(string(item.models[index - 1].info.id) < string(model.info.id)) {
                return {}, .Invalid_Row
            }
        }
    }

    if !catalog_loaded_valid(loaded) {
        return {}, .Invalid_Row
    }

    return loaded, nil
}

@(private)
catalog_providers_load :: proc(s: ^Store, catalog: ^Catalog) -> Error {
    assert(s != nil, "catalog provider load needs a store")
    assert(catalog != nil, "catalog provider load needs output")
    assert(len(catalog.providers) == 0, "catalog provider load starts empty")

    st := sqlite.prepare(s.writer, CATALOG_PROVIDERS_LOAD_SQL) or_return
    defer sqlite.finalize(st)

    for {
        if has_row := sqlite.step_row(st) or_return; !has_row {
            break
        }

        row: Catalog_Provider_Row
        sqlite.scan_row(st, &row, catalog.allocator) or_return
        item := catalog_provider_from_row(row, catalog.allocator) or_return

        if len(catalog.providers) >= CATALOG_PROVIDERS_MAX {
            model_catalog.provider_destroy(&item, catalog.allocator)
            return .Invalid_Row
        }
        append(&catalog.providers, item)

        // Every row carries the same validator, so the first one answers for all.
        if etag, has_etag := row.etag.?; has_etag && catalog.feed_etag == "" {
            catalog.feed_etag = string_clone(etag, catalog.allocator)
        }
    }

    return nil
}

@(private)
catalog_provider_from_row :: proc(
    row: Catalog_Provider_Row,
    allocator: mem.Allocator,
) -> (
    item: model_catalog.Provider,
    err: Error,
) {
    defer if err != nil {
        model_catalog.provider_destroy(&item, allocator)
    }

    protocol, protocol_ok := wire.provider_protocol_from_wire(row.protocol)
    if !protocol_ok {
        return item, .Invalid_Row
    }

    etag, _ := row.etag.?

    // Assembled borrowing the SQLite columns and validated in that form; only a row that
    // passes is cloned into owned storage.
    borrowed := model_catalog.Provider {
        id = wire.Provider_Id(row.provider_id),
        source_id = row.models_dev_id,
        name = row.name,
        endpoint = {base_url = row.base_url, protocol = protocol},
    }
    if !catalog_provider_valid(borrowed, etag) {
        return item, .Invalid_Row
    }

    item.models.allocator = allocator
    item.endpoint.protocol = protocol
    item.id = wire.Provider_Id(string_clone(row.provider_id, allocator))
    item.source_id = string_clone(row.models_dev_id, allocator)
    item.name = string_clone(row.name, allocator)
    item.endpoint.base_url = string_clone(row.base_url, allocator)

    return item, nil
}

@(private)
catalog_provider_env_load :: proc(s: ^Store, catalog: ^Catalog) -> Error {
    assert(s != nil, "catalog provider environment load needs a store")
    assert(catalog != nil, "catalog provider environment load needs output")

    st := sqlite.prepare(s.writer, CATALOG_PROVIDER_ENV_LOAD_SQL) or_return
    defer sqlite.finalize(st)

    for {
        if has_row := sqlite.step_row(st) or_return; !has_row {
            break
        }

        row: Catalog_Provider_Env_Row
        sqlite.scan_row(st, &row, catalog.allocator) or_return

        if !model_catalog.env_name_valid(row.name) {
            return .Invalid_Row
        }

        index, found := catalog_provider_find(catalog.providers[:], row.provider_id)
        if !found ||
           row.total == 0 ||
           row.total > CATALOG_CREDENTIAL_ENV_MAX ||
           row.ordinal < 0 ||
           u64(row.ordinal) >= row.total {
            return .Invalid_Row
        }

        item := &catalog.providers[index]
        catalog_ordinal_fill(&item.credential_env, row.ordinal, row.total, row.name, catalog.allocator) or_return
    }

    return nil
}

@(private)
catalog_models_load :: proc(s: ^Store, catalog: ^Catalog) -> Error {
    assert(s != nil, "catalog model load needs a store")
    assert(catalog != nil, "catalog model load needs output")

    st := sqlite.prepare(s.writer, CATALOG_MODELS_LOAD_SQL) or_return
    defer sqlite.finalize(st)

    total := 0

    for {
        if has_row := sqlite.step_row(st) or_return; !has_row {
            break
        }

        row: Catalog_Model_Row
        sqlite.scan_row(st, &row, catalog.allocator) or_return

        index, found := catalog_provider_find(catalog.providers[:], row.provider_id)
        if !found {
            return .Invalid_Row
        }

        item := &catalog.providers[index]
        model := catalog_model_from_row(row, item.id, catalog.allocator) or_return

        total += 1
        if total > CATALOG_MODELS_MAX {
            model_catalog.model_destroy(&model, catalog.allocator)
            return .Invalid_Row
        }
        append(&item.models, model)
    }

    return nil
}

// Assemble borrowing the row's columns, validate, then clone. The schema requires every
// inference column, so a row that will not rebuild is corrupt.
@(private)
catalog_model_from_row :: proc(
    row: Catalog_Model_Row,
    provider_id: wire.Provider_Id,
    allocator: mem.Allocator,
) -> (
    model: model_catalog.Model,
    err: Error,
) {
    protocol, protocol_ok := wire.provider_protocol_from_wire(row.protocol)
    replay, replay_ok := model_catalog.reasoning_replay_from_string(row.reasoning_replay)
    format, format_ok := model_catalog.thinking_format_from_string(row.thinking_format)
    max_tokens_field, max_tokens_ok := model_catalog.max_tokens_field_from_string(row.max_tokens_field)
    if !protocol_ok || !replay_ok || !format_ok || !max_tokens_ok {
        return {}, .Invalid_Row
    }

    borrowed := model_catalog.Model {
        info = {
            id = wire.Model_Id(row.public_model_id),
            provider = provider_id,
            name = row.name,
            context_window = row.context_window,
            max_output_tokens = row.max_output_tokens,
            supports_vision = row.supports_vision,
            supports_tools = row.supports_tools,
            cost = {
                input = row.cost_input,
                output = row.cost_output,
                cache_read = row.cost_cache_read,
                cache_write = row.cost_cache_write,
            },
        },
        upstream_id = row.upstream_id,
        endpoint = {base_url = row.base_url, protocol = protocol},
        supports_temperature = row.supports_temperature,
        reasoning_replay = replay,
        thinking_format = format,
        anthropic_adaptive = row.anthropic_adaptive,
        reasoning_budget_min = row.reasoning_budget_min,
        reasoning_budget_max = row.reasoning_budget_max,
        max_tokens_field = max_tokens_field,
    }

    // Levels arrive later, so `catalog_loaded_valid` makes the level check.
    if !catalog_model_shape_valid(borrowed) {
        return {}, .Invalid_Row
    }

    return model_catalog.model_clone(borrowed, provider_id, allocator), nil
}

@(private)
catalog_model_levels_load :: proc(s: ^Store, catalog: ^Catalog) -> Error {
    assert(s != nil, "catalog model level load needs a store")
    assert(catalog != nil, "catalog model level load needs output")

    st := sqlite.prepare(s.writer, CATALOG_MODEL_LEVELS_LOAD_SQL) or_return
    defer sqlite.finalize(st)

    for {
        if has_row := sqlite.step_row(st) or_return; !has_row {
            break
        }

        row: Catalog_Model_Level_Row
        sqlite.scan_row(st, &row, catalog.allocator) or_return

        if !catalog_bounded_string_valid(row.level, 32) {
            return .Invalid_Row
        }

        levels, found := catalog_model_levels_find(catalog, row.public_model_id)
        if !found ||
           row.total == 0 ||
           row.total > u64(wire.LIMITS.max_reasoning_levels) ||
           row.ordinal < 0 ||
           u64(row.ordinal) >= row.total {
            return .Invalid_Row
        }

        catalog_ordinal_fill(levels, row.ordinal, row.total, row.level, catalog.allocator) or_return
    }

    return nil
}

@(private)
catalog_loaded_model_finalize :: proc(model: ^model_catalog.Model, allocator: mem.Allocator) -> Error {
    assert(model != nil, "catalog loaded model finalization needs a model")
    assert(model.info.default_reasoning == "", "a loaded model derives its default once")

    derived := model_catalog.default_reasoning_level(model.info.reasoning_levels)
    model.info.default_reasoning = string_clone(derived, allocator)

    return nil
}

@(private)
catalog_provider_valid :: proc(item: model_catalog.Provider, feed_etag: string) -> bool {
    if wire.provider_id_validate(item.id) != .None ||
       wire.provider_id_validate(item.source_id) != .None ||
       !catalog_bounded_string_valid(item.name, 128) ||
       !catalog_bounded_string_valid(item.endpoint.base_url, 4096) ||
       provider.endpoint_validate(item.endpoint) != .None ||
       len(item.credential_env) > CATALOG_CREDENTIAL_ENV_MAX {
        return false
    }

    if feed_etag != "" && !catalog_bounded_string_valid(feed_etag, CATALOG_ETAG_MAX_BYTES) {
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

// Everything but the reasoning levels, which their own rows supply later.
@(private)
catalog_model_shape_valid :: proc(model: model_catalog.Model) -> bool {
    return(
        wire.provider_id_validate(model.info.provider) == .None &&
        catalog_public_model_id_valid(model.info.id, model.info.provider) &&
        catalog_bounded_string_valid(model.info.name, 128) &&
        catalog_bounded_string_valid(model.upstream_id, 128) &&
        model.info.context_window > 0 &&
        model.info.context_window <= wire.MAX_WIRE_INTEGER &&
        model.info.max_output_tokens > 0 &&
        model.info.max_output_tokens <= wire.MAX_WIRE_INTEGER &&
        catalog_bounded_string_valid(model.endpoint.base_url, 4096) &&
        provider.endpoint_validate(model.endpoint) == .None &&
        model_catalog.reasoning_shape_compatible(model) &&
        catalog_budget_valid(model) \
    )
}

@(private)
catalog_model_valid :: proc(model: model_catalog.Model) -> bool {
    return(
        wire.model_info_validate(model.info) == .None &&
        catalog_model_shape_valid(model) &&
        catalog_reasoning_levels_valid(model.info.reasoning_levels, model.info.default_reasoning) \
    )
}

@(private)
catalog_budget_valid :: proc(model: model_catalog.Model) -> bool {
    minimum, has_minimum := model.reasoning_budget_min.?
    maximum, has_maximum := model.reasoning_budget_max.?

    if has_minimum && (minimum < -1 || minimum > wire.MAX_WIRE_INTEGER) {
        return false
    }

    if has_maximum && maximum > u64(wire.MAX_WIRE_INTEGER) {
        return false
    }

    return !has_minimum || !has_maximum || minimum <= i64(maximum)
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
catalog_loaded_valid :: proc(catalog: Catalog) -> bool {
    if len(catalog.providers) > CATALOG_PROVIDERS_MAX {
        return false
    }

    total := 0

    for item, i in catalog.providers {
        if !catalog_provider_valid(item, catalog.feed_etag) {
            return false
        }

        for previous in catalog.providers[:i] {
            if previous.id == item.id {
                return false
            }
        }

        total += len(item.models)
        if total > CATALOG_MODELS_MAX {
            return false
        }

        for model in item.models {
            if model.info.provider != item.id || !catalog_model_valid(model) {
                return false
            }
        }
    }

    return true
}

@(private)
catalog_provider_find :: proc(providers: []model_catalog.Provider, provider_id: string) -> (index: int, found: bool) {
    for item, i in providers {
        if item.id == provider_id {
            return i, true
        }
    }

    return -1, false
}

// Model ids are unique across the whole catalog, so the first match is the only one.
@(private)
catalog_model_levels_find :: proc(catalog: ^Catalog, public_model_id: string) -> (levels: ^[]string, found: bool) {
    for &item in catalog.providers {
        for &model in item.models {
            if model.info.id == public_model_id {
                return &model.info.reasoning_levels, true
            }
        }
    }

    return nil, false
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

        slot^ = make([]string, int(total), allocator)
    } else if len(slot^) != int(total) {
        return .Invalid_Row
    }

    if slot^[ordinal] != "" {
        return .Invalid_Row
    }
    slot^[ordinal] = string_clone(value, allocator)

    return nil
}

@(private)
catalog_bounded_string_valid :: proc(value: string, max_bytes: int) -> bool {
    assert(max_bytes > 0, "a catalog string bound is positive")

    return len(value) > 0 && len(value) <= max_bytes && utf8.valid_string(value)
}
