package store

import "src:daemon/store/queries"
import "src:wire"

import "libs:bindings/sqlite"

// Fold one durable event into the config projection, inside the append transaction.
// Truncation isn't a case: it leaves announced revisions intact. A revision is minted
// once, so a repeat insert here is drift, not an update.
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

// `Default` is resolved to its text before it reaches here; nil stores nothing
// and reads back as `system_prompt: null`.
@(private)
session_prompt_set :: proc(s: ^Store, session: wire.Session_Id, prompt: Maybe(string)) -> Error {
    assert(s != nil, "session_prompt_set needs a store")
    assert(s.writer != nil, "an open store always holds its writer")

    return queries.set_prompt(&s.queries, {session_id = session, prompt = prompt})
}
