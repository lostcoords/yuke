package store

import "libs:bindings/sqlite"
import "src:wire"

@(private)
Insert_Config_Params :: struct {
    session_id: wire.Session_Id,
    config_rev: wire.Config_Rev,
    model:      string,
    reasoning:  string,
}

@(private)
Set_Prompt_Params :: struct {
    session_id: wire.Session_Id,
    prompt:     Maybe(string),
}

// Fold one durable event into the config projection, inside the append
// transaction. Truncation is not a case here: dropping a message tail leaves the
// revisions announced before it intact.
@(private)
configs_apply :: proc(s: ^Store, session: wire.Session_Id, data: wire.Broadcast_Data) -> Error {
    assert(s != nil, "configs_apply needs a store")
    assert(s.writer != nil, "configs_apply needs an open writer")

    changed, is_config := data.(wire.Config_Changed_Data)

    if !is_config {
        return nil
    }

    return sqlite.execute(
        &s.binds.insert_config,
        &Insert_Config_Params {
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

    return sqlite.execute(&s.binds.set_prompt, &Set_Prompt_Params{session_id = session, prompt = prompt})
}
