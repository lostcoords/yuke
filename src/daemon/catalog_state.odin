package daemon

import "core:log"
import "core:mem/virtual"

import catalog "src:daemon/catalog"
import store "src:daemon/store"
import wire "src:wire"

// The persisted rows, the revision covering them, and the health block. Held rather than
// re-derived: only `catalog.refresh` writes it, so it is immutable between revisions.
Daemon_Catalog :: struct {
    rev:      wire.Catalog_Rev,
    health:   wire.Catalog_Health,
    snapshot: store.Catalog,
}

// Read the catalog and recompute the revision. The old snapshot is released only once the
// replacement is in hand, so a failed reload keeps serving rather than emptying it.
catalog_state_load :: proc(d: ^Daemon) -> store.Error {
    assert(d != nil, "catalog state load needs daemon state")
    assert(d.store != nil, "catalog state load needs an open store")

    loaded := store.catalog_load(d.store, d.allocator) or_return

    scratch: virtual.Arena
    if virtual.arena_init_growing(&scratch) != nil {
        store.catalog_destroy(&loaded)

        return .Alloc_Failed
    }

    defer virtual.arena_destroy(&scratch)

    models, ok := catalog_models_view(loaded, virtual.arena_allocator(&scratch))
    if !ok {
        store.catalog_destroy(&loaded)

        return .Alloc_Failed
    }

    catalog_state_destroy(d)
    d.catalog.snapshot = loaded
    d.catalog.rev = catalog_rev(models, d.catalog.health)

    return nil
}

// A credential-set change makes the held feed validator stale: the next refresh must refetch
// and re-decode with the new selection. The model set is unchanged, so the revision holds.
catalog_feed_invalidate :: proc(d: ^Daemon) {
    assert(d != nil && d.store != nil, "catalog invalidation needs an open store")

    if clear_err := store.catalog_feed_etag_clear(d.store); clear_err != nil {
        log.errorf("daemon: catalog etag invalidation failed: %v", clear_err)

        return
    }

    if load_err := catalog_state_load(d); load_err != nil {
        log.errorf("daemon: catalog reload after invalidation failed: %v", load_err)
    }
}

catalog_state_destroy :: proc(d: ^Daemon) {
    assert(d != nil, "catalog state teardown needs daemon state")

    if d.catalog.snapshot.allocator.procedure != nil {
        store.catalog_destroy(&d.catalog.snapshot)
    }

    d.catalog.rev = {}
}

// The model a public id names, or nil. Ids are unique across the catalog, so the first
// match is the only one; the pointer borrows the snapshot until a refresh replaces it.
catalog_model_find :: proc(d: ^Daemon, public_id: string) -> ^catalog.Model {
    assert(d != nil, "a model lookup needs daemon state")

    for &item in d.catalog.snapshot.providers {
        for &model in item.models {
            if string(model.info.id) == public_id {
                return &model
            }
        }
    }

    return nil
}
