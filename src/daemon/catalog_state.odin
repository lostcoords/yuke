package daemon

import "core:mem"
import "core:mem/virtual"
import "core:slice"
import "core:strings"

import store "src:daemon/store"
import wire "src:wire"

// Every resolver issue comes from a distinct imported provider, and imported providers
// are capped per source, so the skipped list always fits its wire bound. Keep the caps
// coupled: raising the provider cap without the skipped bound would make legitimate
// persisted data fail the bound assertion in `catalog_health_build`.
#assert(store.CATALOG_PROVIDERS_PER_SOURCE_MAX <= wire.LIMITS.max_skipped_providers)

// The daemon's current catalog identity. It holds only the revision and the small
// health block — never the full model list, which is re-derived into request scratch
// on demand. Rebuilt at startup and after every refresh.
Daemon_Catalog :: struct {
    rev:    wire.Catalog_Rev,
    health: wire.Catalog_Health,
}

// Resolve the persisted catalog, recompute the revision, and rebuild the owned health
// block. Idempotent: any previous health is freed first, so refresh reuses it. The full
// effective catalog is built in local scratch and dropped; only `rev` and `health` last.
catalog_state_load :: proc(d: ^Daemon) -> store.Error {
    assert(d != nil, "catalog state load needs daemon state")
    assert(d.store != nil, "catalog state load needs an open store")

    scratch: virtual.Arena
    if virtual.arena_init_growing(&scratch) != nil {
        return .Alloc_Failed
    }
    defer virtual.arena_destroy(&scratch)
    sa := virtual.arena_allocator(&scratch)

    data := store.catalog_data_load(d.store, sa) or_return
    effective := store.catalog_resolve(data, sa) or_return

    models, ok := catalog_models_view(effective, sa)
    if !ok {
        return .Alloc_Failed
    }

    health := catalog_health_build(effective.issues[:], nil, d.allocator) or_return

    catalog_state_destroy(d)
    d.catalog.health = health
    d.catalog.rev = catalog_rev(models, health)

    return nil
}

catalog_state_destroy :: proc(d: ^Daemon) {
    assert(d != nil, "catalog state teardown needs daemon state")

    catalog_health_destroy(&d.catalog.health, d.allocator)
    d.catalog.rev = {}
}

// Load and resolve the current persisted catalog into `allocator`. The caller reads the
// bounded result from request scratch and never retains it; the raw rows and the effective
// catalog both live in `allocator` and its borrowed views are valid until it is reset.
catalog_resolve_current :: proc(
    d: ^Daemon,
    allocator: mem.Allocator,
) -> (
    effective: store.Effective_Catalog,
    err: store.Error,
) {
    assert(d != nil, "catalog resolve needs daemon state")
    assert(d.store != nil, "catalog resolve needs an open store")

    data := store.catalog_data_load(d.store, allocator) or_return
    defer store.catalog_data_destroy(&data)

    // The resolver clones everything it keeps, so the raw rows are freed here and the
    // effective catalog is independent of them.
    return store.catalog_resolve(data, allocator)
}

// Build the owned health block from resolver issues. Resolver skips are configuration
// problems; credential-driven skips are layered on elsewhere. `skipped` is sorted by
// provider so the block — and the revision that covers it — is deterministic.
catalog_health_build :: proc(
    issues: []store.Effective_Issue,
    load_error: Maybe(string),
    allocator: mem.Allocator,
) -> (
    health: wire.Catalog_Health,
    err: store.Error,
) {
    assert(len(issues) <= wire.LIMITS.max_skipped_providers, "resolver issues fit the skipped-provider bound")

    defer if err != nil {
        catalog_health_destroy(&health, allocator)
    }

    if len(issues) > 0 {
        skipped, make_err := make([]wire.Skipped_Provider, len(issues), allocator)
        if make_err != nil {
            return health, .Alloc_Failed
        }
        health.skipped = skipped

        for issue, index in issues {
            name, clone_err := strings.clone(string(issue.provider_id), allocator)
            if clone_err != nil {
                return health, .Alloc_Failed
            }

            health.skipped[index] = wire.Skipped_Provider {
                provider = name,
                reason = wire.Skip_Reason_Invalid_Config{message = catalog_skip_message(issue.error)},
            }
        }

        slice.sort_by(health.skipped, proc(a, b: wire.Skipped_Provider) -> bool {
            return a.provider < b.provider
        })
    }

    if message, present := load_error.?; present {
        owned, clone_err := strings.clone(message, allocator)
        if clone_err != nil {
            return health, .Alloc_Failed
        }
        health.load_error = owned
    }

    return health, nil
}

// Static description for a resolver skip. Kept static so the health block owns no skip
// message and `catalog_health_destroy` frees only the cloned provider name.
@(private)
catalog_skip_message :: proc(reason: store.Effective_Error) -> string {
    switch reason {
    case .Collision:
        return "a custom model id collides with an imported model"

    case .Unmatched_Override:
        return "an override matches no imported model"
    }

    return ""
}

catalog_health_destroy :: proc(health: ^wire.Catalog_Health, allocator: mem.Allocator) {
    assert(health != nil, "catalog health teardown needs a health block")

    for skipped in health.skipped {
        delete(skipped.provider, allocator)
    }
    delete(health.skipped, allocator)
    if message, present := health.load_error.?; present {
        delete(message, allocator)
    }

    health^ = {}
}
