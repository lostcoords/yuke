package store

import "core:mem"
import "core:mem/virtual"
import "core:slice"

import model_catalog "src:daemon/catalog"
import provider "src:provider"
import wire "src:wire"

// Why a provider produced no effective models. Resolution is atomic per provider: a
// collision or unmatched override drops the whole provider and records one issue.
Effective_Error :: enum {
    Collision,
    Unmatched_Override,
}

// One provider skipped during resolution, with the reason.
Effective_Issue :: struct {
    provider_id: wire.Provider_Id,
    error:       Effective_Error,
}

// The owned effective catalog overlaid from the raw sources, independent of `Catalog_Data`.
// Providers are ordered by id; each provider's models by public model id.
Effective_Catalog :: struct {
    providers: [dynamic]model_catalog.Provider,
    issues:    [dynamic]Effective_Issue,
    allocator: mem.Allocator,
}

// One raw public provider id and the source records that contribute to it. Pointers
// borrow the caller's `Catalog_Data`; the group set lives in resolve scratch.
@(private)
Resolve_Group :: struct {
    id:              string,
    imported:        ^Catalog_Provider,
    javascript:      ^Catalog_Provider,
    imported_models: [dynamic]^Catalog_Complete_Model,
    custom_models:   [dynamic]^Catalog_Complete_Model,
    overrides:       [dynamic]^Catalog_Model_Override,
}

// Resolve the raw catalog into its owned effective form. Pure (no SQLite/network/creds):
// per-provider issues are isolated, only a model-count overflow fails; `data` stays the caller's.
catalog_resolve :: proc(
    data: Catalog_Data,
    allocator := context.allocator,
) -> (
    result: Effective_Catalog,
    err: Error,
) {
    assert(allocator.procedure != nil, "catalog_resolve needs an allocator")

    result.allocator = allocator
    result.providers.allocator = allocator
    result.issues.allocator = allocator
    defer if err != nil {
        effective_catalog_destroy(&result)
    }

    scratch: virtual.Arena
    if virtual.arena_init_growing(&scratch) != nil {
        return result, .Alloc_Failed
    }
    defer virtual.arena_destroy(&scratch)

    groups := resolve_groups_build(data, virtual.arena_allocator(&scratch)) or_return

    total_models := 0
    for &group in groups {
        resolve_group(&group, &result, &total_models, virtual.arena_allocator(&scratch)) or_return
    }

    slice.sort_by(result.providers[:], proc(a, b: model_catalog.Provider) -> bool {
        return string(a.id) < string(b.id)
    })

    return result, nil
}

effective_catalog_destroy :: proc(result: ^Effective_Catalog) {
    assert(result != nil, "effective catalog cleanup needs a result")

    for &item in result.providers {
        model_catalog.provider_destroy(&item, result.allocator)
    }
    delete(result.providers)
    for issue in result.issues {
        delete(issue.provider_id, result.allocator)
    }
    delete(result.issues)
    result^ = {}
}

// Group the raw provider and model records by public provider id. Every group entry
// borrows the caller's data; the group structures allocate into `scratch`.
@(private)
resolve_groups_build :: proc(
    data: Catalog_Data,
    scratch: mem.Allocator,
) -> (
    groups: [dynamic]Resolve_Group,
    err: Error,
) {
    groups.allocator = scratch

    find :: proc(groups: ^[dynamic]Resolve_Group, id: string, scratch: mem.Allocator) -> (^Resolve_Group, Error) {
        for &group in groups {
            if group.id == id {
                return &group, nil
            }
        }

        entry := Resolve_Group {
            id = id,
        }
        entry.imported_models.allocator = scratch
        entry.custom_models.allocator = scratch
        entry.overrides.allocator = scratch
        if _, append_err := append(groups, entry); append_err != nil {
            return nil, .Alloc_Failed
        }

        return &groups[len(groups) - 1], nil
    }

    for i in 0 ..< len(data.providers) {
        item := &data.providers[i]
        group := find(&groups, string(item.id), scratch) or_return
        switch item.source {
        case .Models_Dev:
            group.imported = item

        case .Javascript:
            group.javascript = item
        }
    }

    for i in 0 ..< len(data.models) {
        model := &data.models[i]
        #partial switch &value in model {
        case Catalog_Complete_Model:
            group := find(&groups, string(value.info.provider), scratch) or_return
            switch value.source {
            case .Models_Dev:
                if _, append_err := append(&group.imported_models, &value); append_err != nil {
                    return groups, .Alloc_Failed
                }

            case .Javascript:
                if _, append_err := append(&group.custom_models, &value); append_err != nil {
                    return groups, .Alloc_Failed
                }
            }

        case Catalog_Model_Override:
            group := find(&groups, string(value.provider_id), scratch) or_return
            if _, append_err := append(&group.overrides, &value); append_err != nil {
                return groups, .Alloc_Failed
            }
        }
    }

    return groups, nil
}

// Resolve one public provider id into at most one effective provider. Appends either
// the built provider or an issue; only allocation failure returns an error.
@(private)
resolve_group :: proc(
    group: ^Resolve_Group,
    result: ^Effective_Catalog,
    total_models: ^int,
    scratch: mem.Allocator,
) -> Error {
    imp := group.imported
    js := group.javascript
    assert(imp != nil || js != nil, "a resolve group borrows at least one provider row")

    // Whether the JavaScript provider adopts the imported models.dev snapshot: it
    // must name a models.dev source and that source must match the imported one.
    snapshot := imp != nil && js != nil && js.models_dev_id != "" && js.models_dev_id == imp.models_dev_id

    // Effective provider metadata. A matched snapshot inherits imported values that
    // JavaScript leaves unset; otherwise the present source stands alone.
    id: string
    source_id: string
    name: string
    endpoint: provider.Endpoint
    credential_env: []string

    if js != nil {
        id = string(js.id)
        source_id = js.models_dev_id
        name = js.name
        endpoint = js.endpoint
        credential_env = js.credential_env
        if snapshot {
            if name == "" {
                name = imp.name
            }
            if !js.has_endpoint {
                endpoint = imp.endpoint
            }
            if len(credential_env) == 0 {
                credential_env = imp.credential_env
            }
        }
    } else {
        id = string(imp.id)
        source_id = imp.models_dev_id
        name = imp.name
        endpoint = imp.endpoint
        credential_env = imp.credential_env
    }

    // Imported models are adopted only by a plain imported provider or a matched
    // snapshot. A stale or endpoint-only JavaScript overlay drops them.
    use_imported := imp != nil && (js == nil || snapshot)

    // Overrides apply only against an adopted snapshot; each must match exactly one imported
    // public model id, and an unmatched override invalidates the whole provider.
    override_for := make([]^Catalog_Model_Override, len(group.imported_models) if use_imported else 0, scratch)
    if snapshot {
        for override in group.overrides {
            matched := false
            for imported_model, index in group.imported_models {
                if imported_model.info.id == override.id {
                    override_for[index] = override
                    matched = true
                    break
                }
            }
            if !matched {
                return resolve_issue_append(result, imp.id, .Unmatched_Override)
            }
        }
    }

    // A custom model whose public id collides with an imported model invalidates the
    // provider rather than choosing a winner.
    if use_imported {
        for custom in group.custom_models {
            for imported_model in group.imported_models {
                if custom.info.id == imported_model.info.id {
                    return resolve_issue_append(result, wire.Provider_Id(id), .Collision)
                }
            }
        }
    }

    return resolve_provider_build(
        id,
        source_id,
        name,
        endpoint,
        credential_env,
        group,
        use_imported,
        override_for,
        result,
        total_models,
    )
}

// Clone the effective provider and its resolved models into owned storage and append
// it. On any allocation failure the half-built provider is destroyed before returning.
@(private)
resolve_provider_build :: proc(
    id, source_id, name: string,
    endpoint: provider.Endpoint,
    credential_env: []string,
    group: ^Resolve_Group,
    use_imported: bool,
    override_for: []^Catalog_Model_Override,
    result: ^Effective_Catalog,
    total_models: ^int,
) -> (
    err: Error,
) {
    allocator := result.allocator

    item: model_catalog.Provider
    item.models.allocator = allocator
    defer if err != nil {
        model_catalog.provider_destroy(&item, allocator)
    }

    item.id = wire.Provider_Id(catalog_string_clone(id, allocator) or_return)
    item.source_id = catalog_string_clone(source_id, allocator) or_return
    item.name = catalog_string_clone(name, allocator) or_return
    item.endpoint.base_url = catalog_string_clone(endpoint.base_url, allocator) or_return
    item.endpoint.protocol = endpoint.protocol
    item.credential_env = resolve_string_slice_clone(credential_env, allocator) or_return

    if use_imported {
        for imported_model, index in group.imported_models {
            model := resolve_model_clone(&imported_model.model, item.id, override_for[index], allocator) or_return
            if _, append_err := append(&item.models, model); append_err != nil {
                model_catalog.model_destroy(&model, allocator)
                return .Alloc_Failed
            }
        }
    }

    for custom in group.custom_models {
        model := resolve_model_clone(&custom.model, item.id, nil, allocator) or_return
        if _, append_err := append(&item.models, model); append_err != nil {
            model_catalog.model_destroy(&model, allocator)
            return .Alloc_Failed
        }
    }

    slice.sort_by(item.models[:], proc(a, b: model_catalog.Model) -> bool {
        return string(a.info.id) < string(b.info.id)
    })

    // A provider with no effective models can never be a resolution target and may carry
    // no usable endpoint (a stale snapshot). Drop it rather than emit a degenerate entry.
    if len(item.models) == 0 {
        model_catalog.provider_destroy(&item, allocator)
        return nil
    }

    total_models^ += len(item.models)
    if total_models^ > int(wire.LIMITS.max_catalog_models) {
        return .Invalid_Catalog
    }

    if _, append_err := append(&result.providers, item); append_err != nil {
        return .Alloc_Failed
    }

    return nil
}

// Deep-clone one resolved model into owned storage. `provider_id` is borrowed by the
// model's `info.provider`. An override substitutes only the reasoning levels and default.
@(private)
resolve_model_clone :: proc(
    src: ^model_catalog.Model,
    provider_id: wire.Provider_Id,
    override: ^Catalog_Model_Override,
    allocator: mem.Allocator,
) -> (
    model: model_catalog.Model,
    err: Error,
) {
    model.info.provider = string(provider_id)
    model.info.context_window = src.info.context_window
    model.info.max_output_tokens = src.info.max_output_tokens
    model.info.supports_vision = src.info.supports_vision
    model.info.supports_tools = src.info.supports_tools
    model.info.cost = src.info.cost
    model.supports_temperature = src.supports_temperature
    model.reasoning_replay = src.reasoning_replay
    model.reasoning_format = src.reasoning_format
    model.reasoning_budget_min = src.reasoning_budget_min
    model.reasoning_budget_max = src.reasoning_budget_max
    model.endpoint.protocol = src.endpoint.protocol

    defer if err != nil {
        model_catalog.model_destroy(&model, allocator)
    }

    levels := src.info.reasoning_levels
    default := src.info.default_reasoning
    if override != nil {
        levels = override.reasoning_levels
        default = override.default_reasoning
    }

    model.info.id = wire.Model_Id(catalog_string_clone(string(src.info.id), allocator) or_return)
    model.info.name = catalog_string_clone(src.info.name, allocator) or_return
    model.info.reasoning_levels = resolve_string_slice_clone(levels, allocator) or_return
    model.info.default_reasoning = catalog_string_clone(default, allocator) or_return
    model.upstream_id = catalog_string_clone(src.upstream_id, allocator) or_return
    model.endpoint.base_url = catalog_string_clone(src.endpoint.base_url, allocator) or_return

    return model, nil
}

@(private)
resolve_string_slice_clone :: proc(values: []string, allocator: mem.Allocator) -> (owned: []string, err: Error) {
    if len(values) == 0 {
        return nil, nil
    }

    allocation_err: mem.Allocator_Error
    owned, allocation_err = make([]string, len(values), allocator)
    if allocation_err != nil {
        return nil, .Alloc_Failed
    }
    defer if err != nil {
        for value in owned {
            delete(value, allocator)
        }
        delete(owned, allocator)
    }

    for value, index in values {
        owned[index] = catalog_string_clone(value, allocator) or_return
    }

    return owned, nil
}

@(private)
resolve_issue_append :: proc(
    result: ^Effective_Catalog,
    provider_id: wire.Provider_Id,
    reason: Effective_Error,
) -> Error {
    owned := wire.Provider_Id(catalog_string_clone(string(provider_id), result.allocator) or_return)
    if _, append_err := append(&result.issues, Effective_Issue{provider_id = owned, error = reason});
       append_err != nil {
        delete(owned, result.allocator)
        return .Alloc_Failed
    }

    return nil
}
