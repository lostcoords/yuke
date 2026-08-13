package daemon

import "core:mem"
import "core:mem/virtual"

import catalog "src:daemon/catalog"
import store "src:daemon/store"
import wire "src:wire"

// Build the models.dev import selection from what this daemon cares about: JavaScript
// providers that name a models.dev source, and providers with a saved credential (the
// public id is used as the source key). Deduplicated by provider id. `allocator` should
// be scratch — intermediates and the borrowed selection strings live there and are not
// freed individually.
//
// Not yet covered: selecting a provider solely because one of its declared credential
// env vars is set — that needs the feed's env names, so it belongs to a feed pre-scan.
catalog_selections_build :: proc(
    d: ^Daemon,
    allocator: mem.Allocator,
) -> (
    selections: [dynamic]catalog.Selection,
    err: store.Error,
) {
    assert(d != nil, "selection build needs daemon state")
    assert(d.store != nil, "selection build needs an open store")

    selections.allocator = allocator

    for definition in d.providers.definitions {
        if definition.models_dev == "" {
            continue
        }

        catalog_selection_add(&selections, string(definition.id), definition.models_dev) or_return
    }

    statuses := store.credential_statuses_load(d.store, allocator) or_return
    for status in statuses {
        catalog_selection_add(&selections, status.provider_id, status.provider_id) or_return
    }

    if len(selections) > catalog.SELECTIONS_MAX {
        return selections, .Invalid_Catalog
    }

    return selections, nil
}

@(private)
catalog_selection_add :: proc(selections: ^[dynamic]catalog.Selection, id, source: string) -> store.Error {
    for existing in selections {
        if string(existing.provider_id) == id {
            return nil
        }
    }

    if _, append_err := append(selections, catalog.Selection{provider_id = wire.Provider_Id(id), source_id = source});
       append_err != nil {
        return .Alloc_Failed
    }

    return nil
}

// Apply one fetched models.dev feed: decode the selected provider subtrees, replace each
// imported snapshot transactionally with `feed_etag`, then re-resolve so `d.catalog`
// reflects the new content. Reports whether the effective revision moved. The feed is
// untrusted: a decode failure replaces nothing and preserves the previous snapshot; a
// per-provider replace is transactional, so a mid-run failure leaves committed providers
// intact and still re-syncs `d.catalog` to the store.
catalog_refresh_apply :: proc(
    d: ^Daemon,
    feed: []byte,
    feed_etag: string,
    selections: []catalog.Selection,
) -> (
    changed: bool,
    err: store.Error,
) {
    assert(d != nil, "catalog refresh needs daemon state")
    assert(d.store != nil, "catalog refresh needs an open store")

    old_rev := d.catalog.rev

    scratch: virtual.Arena
    if virtual.arena_init_growing(&scratch) != nil {
        return false, .Alloc_Failed
    }
    defer virtual.arena_destroy(&scratch)
    sa := virtual.arena_allocator(&scratch)

    result, decode_err := catalog.decode(feed, selections, sa)
    if decode_err != .None {
        return false, catalog_decode_error(decode_err)
    }

    apply_err: store.Error
    for &provider in result.providers {
        item := store.Catalog_Provider {
            id             = provider.id,
            source         = .Models_Dev,
            models_dev_id  = provider.source_id,
            name           = provider.name,
            endpoint       = provider.endpoint,
            has_endpoint   = true,
            etag           = feed_etag,
            credential_env = provider.credential_env,
        }

        models, make_err := make([]store.Catalog_Model, len(provider.models), sa)
        if make_err != nil {
            apply_err = .Alloc_Failed
            break
        }
        for model, index in provider.models {
            models[index] = store.Catalog_Complete_Model {
                source = .Models_Dev,
                model  = model,
            }
        }

        if replace_err := store.catalog_imported_replace(d.store, item, models); replace_err != nil {
            apply_err = replace_err
            break
        }
    }

    // Always re-sync the held state with the store, even after a partial failure, so the
    // revision and health never disagree with the persisted rows.
    load_err := catalog_state_load(d)
    changed = d.catalog.rev != old_rev

    if apply_err != nil {
        return changed, apply_err
    }

    return changed, load_err
}

@(private)
catalog_decode_error :: proc(err: catalog.Error) -> store.Error {
    #partial switch err {
    case .Out_Of_Memory:
        return .Alloc_Failed
    }

    return .Invalid_Catalog
}
