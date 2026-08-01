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

// Write the registry row for a session. Every event and projected message points
// at this row through a foreign key, so it exists before anything references it
// rather than being invented by the first append.
session_create :: proc(s: ^Store, session: wire.Session) -> Error {
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

    switch v in session.origin {
    case wire.Session_Origin_Root:
        params.origin = "root"

    case wire.Session_Origin_Child:
        params.origin = "child"
        params.parent_id = v.parent_id
        params.parent_message_id = v.parent_message_id
        params.parent_part_id = v.parent_part_id

    case wire.Session_Origin_Fork:
        params.origin = "fork"
        params.source_id = v.source_id

    case wire.Session_Origin_Cron:
        params.origin = "cron"
        params.job_id = v.job_id
    }

    assert(len(params.origin) > 0, "every origin arm names itself")

    if cb, ok := session.created_by.?; ok {
        params.created_by_name = cb.name
        params.created_by_version = cb.version
    }

    return sqlite.execute(&s.binds.create_session, &params)
}
