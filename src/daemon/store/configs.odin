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

    sqlite.execute(
        &s.inserts.insert_config,
        &queries.Insert_Config_Params {
            session_id = session,
            config_rev = changed.config.config_rev,
            model = changed.config.model,
            reasoning = changed.config.reasoning,
        },
    ) or_return

    queries.set_session_config(
        &s.queries,
        {
            session_id = session,
            config_rev = changed.config.config_rev,
            model = changed.config.model,
            reasoning = changed.config.reasoning,
        },
    ) or_return
    assert(sqlite.changes(s.writer) == 1, "a config announcement updates its session summary")

    return nil
}

// Resolve one announced revision without folding the event log.
session_config :: proc(
    s: ^Store,
    session: wire.Session_Id,
    revision: wire.Config_Rev,
    allocator: mem.Allocator,
) -> (
    config: wire.Run_Config,
    found: bool,
    err: Error,
) {
    assert(s != nil, "session_config needs a store")
    assert(s.writer != nil, "an open store always holds its writer")
    assert(allocator.procedure != nil, "a config read needs an allocator")

    row, sqlite_err := queries.session_config(&s.queries, {session_id = session, requested_rev = revision}, allocator)
    return config_read_result(row, sqlite_err)
}

@(private)
config_read_result :: proc(
    row: queries.Session_Config_Row,
    sqlite_err: sqlite.Error,
) -> (
    config: wire.Run_Config,
    found: bool,
    err: Error,
) {
    if sqlite_err != nil {
        if count_err, is_count := sqlite_err.(sqlite.Read_Error); is_count && count_err == .Row_Count {
            return {}, false, nil
        }

        return {}, false, read_err(sqlite_err)
    }

    #assert(size_of(queries.Session_Config_Row) == size_of(wire.Run_Config))
    #assert(offset_of(queries.Session_Config_Row, config_rev) == offset_of(wire.Run_Config, config_rev))
    #assert(offset_of(queries.Session_Config_Row, model) == offset_of(wire.Run_Config, model))
    #assert(offset_of(queries.Session_Config_Row, reasoning) == offset_of(wire.Run_Config, reasoning))

    return wire.Run_Config(row), true, nil
}

// The system prompt a run sends, cloned into `allocator`. A session that was created
// without one has no row, which is `found = false` rather than an error.
session_prompt_get :: proc(
    s: ^Store,
    session: wire.Session_Id,
    allocator: mem.Allocator,
) -> (
    prompt: string,
    found: bool,
    err: Error,
) {
    assert(s != nil, "session_prompt_get needs a store")
    assert(s.writer != nil, "an open store always holds its writer")
    assert(allocator.procedure != nil, "a prompt read needs an allocator")

    row, sqlite_err := queries.session_prompt(&s.queries, {session_id = session}, allocator)
    if sqlite_err != nil {
        if count_err, is_count := sqlite_err.(sqlite.Read_Error); is_count && count_err == .Row_Count {
            return "", false, nil
        }

        return "", false, read_err(sqlite_err)
    }

    return row.prompt, true, nil
}

// `Default` is resolved to its text before it reaches here; nil stores nothing
// and reads back as `system_prompt: null`.
@(private)
session_prompt_set :: proc(s: ^Store, session: wire.Session_Id, prompt: Maybe(string)) -> Error {
    assert(s != nil, "session_prompt_set needs a store")
    assert(s.writer != nil, "an open store always holds its writer")
    return queries.set_prompt(&s.queries, {session_id = session, prompt = prompt})
}
