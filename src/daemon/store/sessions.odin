package store

import "core:mem"

import "src:daemon/store/queries"
import "src:wire"

import "libs:bindings/sqlite"

// Which sessions a page selects. Both members are the wire unions `session.list` carries,
// passed through rather than re-spelled, so the store cannot drift from the protocol.
Session_Filter :: struct {
    // Workspace restriction.
    scope:      wire.Session_Scope,

    // Relationship population.
    population: wire.Session_Population,
}

// Where a page resumes, ordered `(updated_at_ms DESC, id DESC)`. Both members are needed:
// `updated_at_ms` alone isn't unique, so dropping the tiebreak would repeat or skip rows.
Session_Cursor :: struct {
    updated_at_ms: u64,
    id:            wire.Session_Id,
}

// The four selectors a filter reduces to: `scope` supplies `workspace_id`, `population` supplies at most
// one of the rest. Not a generated Params struct — `Session_Page` and `Session_Count` name/type it differently.
@(private)
Session_Filter_Values :: struct {
    workspace_id: Maybe(wire.Workspace_Id),
    parent_id:    Maybe(wire.Session_Id),
    job_id:       Maybe(wire.Job_Id),
    top_level:    bool,
}

// Flatten a filter to its four selectors. A nil union would select every session
// regardless of intent, so it's refused — the decoder already fills both members' defaults.
@(private)
session_filter_values :: proc(filter: Session_Filter) -> Session_Filter_Values {
    assert(filter.scope != nil, "a session filter carries its scope")
    assert(filter.population != nil, "a session filter carries its population")

    values: Session_Filter_Values

    switch scope in filter.scope {
    case wire.Session_Scope_All:

    case wire.Session_Scope_Workspace:
        values.workspace_id = scope.workspace_id
    }

    switch population in filter.population {
    case wire.Session_Population_Top_Level:
        values.top_level = true

    case wire.Session_Population_Children:
        values.parent_id = population.parent_id

    case wire.Session_Population_Job_Runs:
        values.job_id = population.job_id

    case wire.Session_Population_All:
    }

    return values
}

// Write the registry row every event and message keys into. Prompt and workspace land in the same
// transaction, so a half-created session never announces a workspace it did not keep.
session_create :: proc(
    s: ^Store,
    workspace: wire.Workspace,
    session: wire.Session,
    system_prompt: Maybe(string),
) -> (
    workspace_created: bool,
    err: Error,
) {
    assert(s != nil, "session_create needs a store")
    assert(s.writer != nil, "an open store always holds its writer")
    assert(session.origin != nil, "a session carries its origin")
    assert(session.updated_at_ms >= session.created_at_ms, "a session is never updated before it was created")
    assert(session.workspace_id == workspace.id, "a session is created into the workspace it names")

    params := queries.Create_Session_Params {
        id            = session.id,
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

    sqlite.txn_begin(s.writer, .Immediate) or_return

    // A failed ROLLBACK leaves the transaction open, which outlives this call, so it replaces the
    // original error. The workspace flag unwinds with it: `or_return` returns the named results.
    defer if err != nil {
        workspace_created = false

        if rollback := sqlite.txn_rollback(s.writer); rollback != .Ok {
            err = rollback
        }
    }

    workspace_created = workspace_insert(s, workspace) or_return
    sqlite.execute(&s.inserts.create_session, &params) or_return
    session_prompt_set(s, session.id, system_prompt) or_return
    sqlite.txn_commit(s.writer) or_return

    return workspace_created, nil
}

// Read the public summary and open-run projection from one session row. Every
// string clones into `allocator`; `found` is false only for an unknown id.
session_snapshot :: proc(
    s: ^Store,
    id: wire.Session_Id,
    allocator: mem.Allocator,
) -> (
    snapshot: Session_Snapshot,
    found: bool,
    err: Error,
) {
    assert(s != nil, "session_snapshot needs a store")
    assert(s.writer != nil, "an open store always holds its writer")
    assert(allocator.procedure != nil, "a session read needs an allocator")

    row, sqlite_err := queries.session_snapshot(&s.queries, {session_id = id}, allocator)
    if sqlite_err != nil {
        if count_err, is_count := sqlite_err.(sqlite.Read_Error); is_count && count_err == .Row_Count {
            return {}, false, nil
        }

        return {}, false, read_err(sqlite_err)
    }

    session, session_valid := session_row_to_wire(row)
    open_run, run_valid := open_run_from_row(row)
    if !session_valid || !run_valid {
        return {}, false, Store_Error.Invalid_Row
    }

    return Session_Snapshot{session = session, open_run = open_run}, true, nil
}

// Read one page of the session index, newest first, resuming after `cursor`. Every string
// clones into `allocator` and nothing is freed — built for an arena the owner reclaims in bulk.
session_page :: proc(
    s: ^Store,
    filter: Session_Filter,
    cursor: Maybe(Session_Cursor),
    limit: int,
    allocator: mem.Allocator,
) -> (
    sessions: []wire.Session,
    err: Error,
) {
    assert(s != nil, "session_page needs a store")
    assert(s.writer != nil, "an open store always holds its writer")
    assert(limit > 0, "a session page is bounded")
    assert(allocator.procedure != nil, "a session page needs an allocator")

    values := session_filter_values(filter)
    params := queries.Session_Page_Params {
        filter_workspace_id = values.workspace_id,
        parent_id           = values.parent_id,
        job_id              = values.job_id,
        top_level           = values.top_level,
        limit               = limit,
    }

    if resume, paging := cursor.?; paging {
        params.cursor_updated_at_ms = resume.updated_at_ms
        params.cursor_id = resume.id
    }

    read, sqlite_err := queries.session_page(&s.queries, params, allocator, cap_hint = limit)
    if sqlite_err != nil {
        return nil, read_err(sqlite_err)
    }

    page := make([dynamic]wire.Session, 0, len(read), allocator)

    for row in read {
        // The CHECK constraints hold every origin arm and the created_by pair to their
        // documented shape, so a row that will not rebuild was not written by this store.
        session, rebuilt := session_row_to_wire(row)

        if !rebuilt {
            return nil, Store_Error.Invalid_Row
        }

        append(&page, session)
    }

    assert(len(page) <= limit, "a page holds no more rows than the statement's LIMIT")

    return page[:], nil
}

// Count the whole view a filter selects, before paging. This is the `total` a client
// pages against, so it deliberately ignores any cursor.
session_count :: proc(s: ^Store, filter: Session_Filter) -> (total: u64, err: Error) {
    assert(s != nil, "session_count needs a store")
    assert(s.writer != nil, "an open store always holds its writer")

    values := session_filter_values(filter)
    params := queries.Session_Count_Params {
        workspace_id = values.workspace_id,
        parent_id    = values.parent_id,
        job_id       = values.job_id,
        top_level    = values.top_level,
    }

    // An aggregate with no GROUP BY produces exactly one row on every input.
    row, sqlite_err := queries.session_count(&s.queries, params, context.allocator)
    if sqlite_err != nil {
        return 0, read_err(sqlite_err)
    }

    return row.total, nil
}

// Rebuild the wire session a row was flattened from. `ok` is false for a row the protocol
// refuses: CHECK constraints are weaker than `session_validate`, so a foreign writer can leave one.
@(private)
session_row_to_wire :: proc(row: $Row) -> (session: wire.Session, ok: bool) {
    origin := session_origin_from_row(row) or_return
    permission := wire.permission_mode_from_wire(row.permission) or_return

    session = wire.Session {
        id = row.id,
        workspace_id = row.workspace_id,
        profile = row.profile,
        model = row.model,
        reasoning = row.reasoning,
        config_rev = row.config_rev,
        permission = permission,
        max_rounds = row.max_rounds,
        title = row.title,
        message_count = row.message_count,
        usage_total = wire.Token_Usage {
            input = row.usage_input_total,
            output = row.usage_output_total,
            reasoning = row.usage_reasoning_total,
            cache_read = row.usage_cache_read_total,
            cache_write = row.usage_cache_write_total,
        },
        created_at_ms = row.created_at_ms,
        updated_at_ms = row.updated_at_ms,
        origin = origin,
        agent = row.agent,
    }

    // Both halves are written together or not at all, so one without the other is a row
    // this store did not produce.
    name, named := row.created_by_name.?
    version, versioned := row.created_by_version.?

    if named != versioned {
        return {}, false
    }

    if named {
        session.created_by = wire.Client {
            name    = name,
            version = version,
        }
    }

    if wire.session_validate(session) != .None {
        return {}, false
    }

    return session, true
}

// Rebuild the origin union from the discriminator and the arm's own ids. Every arm but
// root carries ids that are non-null exactly for it.
@(private)
session_origin_from_row :: proc(row: $Row) -> (origin: wire.Session_Origin, ok: bool) {
    arm := wire.session_origin_type_from_wire(row.origin) or_return

    switch _ in arm {
    case wire.Session_Origin_Root:
        return wire.Session_Origin_Root{}, true

    case wire.Session_Origin_Child:
        parent, has_parent := row.parent_id.?
        message, has_message := row.parent_message_id.?
        part, has_part := row.parent_part_id.?

        if !has_parent || !has_message || !has_part {
            return nil, false
        }

        return wire.Session_Origin_Child{parent_id = parent, parent_message_id = message, parent_part_id = part}, true

    case wire.Session_Origin_Fork:
        source, has_source := row.source_id.?

        if !has_source {
            return nil, false
        }

        return wire.Session_Origin_Fork{source_id = source}, true

    case wire.Session_Origin_Cron:
        job, has_job := row.job_id.?

        if !has_job {
            return nil, false
        }

        return wire.Session_Origin_Cron{job_id = job}, true
    }

    return nil, false
}
