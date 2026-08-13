package daemon

import catalog "src:daemon/catalog"
import store "src:daemon/store"

// Resolve a public model id to its effective row. The row carries everything a run
// needs: upstream id, endpoint/protocol, temperature support, and reasoning metadata.
// The returned pointer borrows `effective` and is valid only while it lives; the id is
// matched exactly and used as a key, never as an index.
run_model_resolve :: proc(effective: store.Effective_Catalog, public_id: string) -> (^catalog.Model, bool) {
    for &provider in effective.providers {
        for &model in provider.models {
            if string(model.info.id) == public_id {
                return &model, true
            }
        }
    }

    return nil, false
}
