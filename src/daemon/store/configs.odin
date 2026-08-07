package store

import "core:mem"

import "src:daemon/store/queries"
import "src:wire"

import "libs:bindings/sqlite"

// Fold one durable event into the config projection, inside the append transaction.
// Truncation isn't a case: it leaves announced revisions intact. A revision is minted once,
// so a repeat insert here is drift, not an update.
@(private)
configs_apply :: proc(s: ^Store, session: wire.Session_Id, data: wire.Broadcast_Data) -> Error {
    assert(s != nil, "configs_apply needs a store")
    assert(s.writer != nil, "configs_apply needs an open writer")

    changed, is_config := data.(wire.Config_Changed_Data)

    if !is_config {
        return nil
    }

    return sqlite.execute(
        &s.inserts.insert_config,
        &queries.Insert_Config_Params {
            session_id = session,
            config_rev = changed.config.config_rev,
            model = changed.config.model,
            reasoning = changed.config.reasoning,
        },
    )
}

// Every announced config revision for the session, oldest first, as `wire.Run_Config`.
// resync resolves a message's `config_rev` against this instead of folding the log. Row strings live in `allocator`.
session_configs :: proc(
    s: ^Store,
    session: wire.Session_Id,
    allocator: mem.Allocator,
) -> (
    configs: []wire.Run_Config,
    err: Error,
) {
    assert(s != nil, "session_configs needs a store")
    assert(s.writer != nil, "an open store always holds its writer")
    assert(allocator.procedure != nil, "a config read needs an allocator")

    read, sqlite_err := queries.session_configs(&s.queries, {session_id = session}, allocator)
    if sqlite_err != nil {
        return nil, read_err(sqlite_err)
    }

    out, alloc_err := make([]wire.Run_Config, len(read), allocator)
    if alloc_err != nil {
        return nil, Store_Error.Alloc_Failed
    }

    for row, i in read {
        out[i] = wire.Run_Config {
            config_rev = row.config_rev,
            model      = row.model,
            reasoning  = row.reasoning,
        }
    }

    return out, nil
}

// `Default` is resolved to its text before it reaches here; nil stores nothing
// and reads back as `system_prompt: null`.
@(private)
session_prompt_set :: proc(s: ^Store, session: wire.Session_Id, prompt: Maybe(string)) -> Error {
    assert(s != nil, "session_prompt_set needs a store")
    assert(s.writer != nil, "an open store always holds its writer")

    return queries.set_prompt(&s.queries, {session_id = session, prompt = prompt})
}
