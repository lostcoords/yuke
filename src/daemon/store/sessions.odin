package store

import "libs:bindings/sqlite"
import "src:wire"

// `wire.Session` flattened to columns. The origin union widens to a
// discriminator plus the ids of its own arm; every other arm's ids stay nil, and
// the table's CHECK constraints hold the pairing to exactly that shape.
@(private)
Create_Session_Params :: struct {
    session_id:         wire.Session_Id,
    workspace_id:       wire.Workspace_Id,
    origin:             string,
    parent_id:          Maybe(wire.Session_Id),
    parent_message_id:  Maybe(wire.Message_Id),
    parent_part_id:     Maybe(wire.Part_Id),
    source_id:          Maybe(wire.Session_Id),
    job_id:             Maybe(wire.Job_Id),
    profile:            string,
    model:              string,
    reasoning:          string,
    config_rev:         wire.Config_Rev,
    permission:         string,
    max_rounds:         Maybe(u64),
    title:              string,
    agent:              Maybe(string),
    created_by_name:    Maybe(string),
    created_by_version: Maybe(string),
    created_at_ms:      u64,
    updated_at_ms:      u64,
}

// Write the registry row for a session. Events and projected messages carry a
// foreign key into it, so it exists before anything references it. The system
// prompt belongs to creation because no method changes it after; nil means none.
session_create :: proc(s: ^Store, session: wire.Session, system_prompt: Maybe(string)) -> Error {
    assert(s != nil, "session_create needs a store")
    assert(s.writer != nil, "an open store always holds its writer")
    assert(session.origin != nil, "a session carries its origin")
    assert(session.updated_at_ms >= session.created_at_ms, "a session is never updated before it was created")

    params := Create_Session_Params {
        session_id    = session.id,
        workspace_id  = session.workspace_id,
        profile       = session.profile,
        model         = session.model,
        reasoning     = session.reasoning,
        config_rev    = session.config_rev,
        permission    = wire.permission_mode_to_wire(session.permission),
        max_rounds    = session.max_rounds,
        title         = session.title,
        agent         = session.agent,
        created_at_ms = session.created_at_ms,
        updated_at_ms = session.updated_at_ms,
    }

    params.origin = wire.session_origin_type_to_wire(session.origin)

    switch v in session.origin {
    case wire.Session_Origin_Root:

    case wire.Session_Origin_Child:
        params.parent_id = v.parent_id
        params.parent_message_id = v.parent_message_id
        params.parent_part_id = v.parent_part_id

    case wire.Session_Origin_Fork:
        params.source_id = v.source_id

    case wire.Session_Origin_Cron:
        params.job_id = v.job_id
    }

    if cb, ok := session.created_by.?; ok {
        params.created_by_name = cb.name
        params.created_by_version = cb.version
    }

    sqlite.execute(&s.binds.create_session, &params) or_return

    return session_prompt_set(s, session.id, system_prompt)
}
