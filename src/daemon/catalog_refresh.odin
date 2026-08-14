package daemon

import "core:mem"
import "core:mem/virtual"

import catalog "src:daemon/catalog"
import store "src:daemon/store"
import wire "src:wire"

// Build the models.dev import selection: every provider with a saved credential.
// `allocator` should be scratch.
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

    // A credential's provider id is also its models.dev source id, and the statuses are
    // already unique per provider, so the list needs no deduplication of its own.
    statuses := store.credential_statuses_load(d.store, allocator) or_return
    for status in statuses {
        if _, append_err := append(
            &selections,
            catalog.Selection{provider_id = wire.Provider_Id(status.provider_id), source_id = status.provider_id},
        ); append_err != nil {
            return selections, .Alloc_Failed
        }
    }

    if len(selections) > catalog.SELECTIONS_MAX {
        return selections, .Invalid_Catalog
    }

    return selections, nil
}

// Apply one fetched models.dev feed: decode, transactionally replace each imported
// snapshot with `feed_etag`, then reload the held catalog. Untrusted feed: a decode
// failure preserves the old snapshot.
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

    // The decoder already produces the shape the store persists, so each provider goes
    // straight in with the feed's own validator.
    apply_err: store.Error
    for item in result.providers {
        if replace_err := store.catalog_imported_replace(d.store, item, feed_etag); replace_err != nil {
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
