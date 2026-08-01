package store

import "core:mem"

import "libs:bindings/sqlite"

// The store's closed set of hot statements. Adding one requires adding its SQL;
// the enum-indexed tables make partial prepare/finalize lists impossible.
@(private)
Statement_Id :: enum {
    Create_Session,
    Append_Event,
    Advance_Seq,
    Bump_Ids,
    Read_High,
    Events_After,
}

@(private)
Statements :: distinct [Statement_Id]^sqlite.Stmt

// SQL remains concrete and visible; this is statement ownership, not a query
// builder or ORM. Parameters are named rather than ordinal so a marker binds to
// the field that shares its name and reordering the SQL cannot silently rebind.
@(private, rodata)
STATEMENT_SQL := [Statement_Id]string {
    // The registry row is created explicitly, never lazily: a session carries
    // required metadata that an append has no way to invent. The id marks and
    // message_count take their column defaults.
    .Create_Session = `INSERT INTO sessions(
            id, workspace_id,
            origin, parent_id, parent_message_id, parent_part_id, source_id, job_id,
            profile, model, reasoning, config_rev, permission, max_rounds, title, agent,
            created_by_name, created_by_version,
            created_at_ms, updated_at_ms)
        VALUES (
            :session_id, :workspace_id,
            :origin, :parent_id, :parent_message_id, :parent_part_id, :source_id, :job_id,
            :profile, :model, :reasoning, :config_rev, :permission, :max_rounds, :title, :agent,
            :created_by_name, :created_by_version,
            :created_at_ms, :updated_at_ms)`,
    .Append_Event   = `INSERT INTO events(session_id, seq, name, payload)
        VALUES (:session_id, :seq, :name, :payload)`,

    // Contiguity lives in the update predicate: a gap or replay matches nothing.
    // This runs before the insert so every high-water divergence is Seq_Conflict.
    // One `:seq` feeds both sides, so the two can never drift apart.
    .Advance_Seq    = `UPDATE sessions SET seq_high = :seq
        WHERE id = :session_id AND seq_high = :seq - 1`,

    // Marks only rise; a stale bump is a no-op rather than a rewind.
    .Bump_Ids       = `UPDATE sessions SET
        message_id_high = MAX(message_id_high, :message_id_high),
        run_id_high     = MAX(run_id_high, :run_id_high),
        input_id_high   = MAX(input_id_high, :input_id_high),
        config_rev_high = MAX(config_rev_high, :config_rev_high)
        WHERE id = :session_id`,
    .Read_High      = `SELECT seq_high, message_id_high, run_id_high, input_id_high, config_rev_high
        FROM sessions WHERE id = :session_id`,

    // The composite primary key is this read's index; no extra index exists.
    .Events_After   = `SELECT seq, name, payload FROM events
        WHERE session_id = :session_id AND seq > :seq ORDER BY seq LIMIT :limit`,
}

// The row shapes the two reading statements are scanned through. Resolving a shape
// costs one reflection walk and one column-name search per field, so it happens once
// per statement rather than once per row; a mapping belongs to its statement and is
// released just before it is finalized.
@(private)
Mappings :: struct {
    read_high:    sqlite.Scan_Mapping(High_Water),
    events_after: sqlite.Scan_Mapping(Event_Row),
}

// The parameter shapes every statement is bound through. Resolved once against the
// statement's named markers, so a struct that no longer matches its SQL fails at
// open instead of writing a wrong column. These own no memory and need no teardown.
@(private)
Binds :: struct {
    create_session: sqlite.Bind_Mapping(Create_Session_Params),
    append_event:   sqlite.Bind_Mapping(Append_Event_Params),
    advance_seq:    sqlite.Bind_Mapping(Advance_Seq_Params),
    bump_ids:       sqlite.Bind_Mapping(Bump_Ids_Params),
    read_high:      sqlite.Bind_Mapping(Session_Params),
    events_after:   sqlite.Bind_Mapping(Events_After_Params),
}

// Resolve both read shapes. The SQL and the destination structs are both ours and
// compiled in, so a mismatch between them is a programmer error and asserts; only
// allocation can fail here at runtime. Should be called once.
@(private)
mappings_prepare :: proc(set: Statements, mappings: ^Mappings, allocator: mem.Allocator) -> (err: Error) {
    assert(mappings != nil, "mappings_prepare needs a set to fill")
    assert(mappings.read_high.statement == nil, "the mapping set is prepared once")
    assert(mappings.events_after.statement == nil, "the mapping set is prepared once")
    assert(set[.Read_High] != nil, "mappings_prepare runs after the statements are prepared")
    assert(set[.Events_After] != nil, "mappings_prepare runs after the statements are prepared")

    high, high_err := sqlite.scan_prepare(set[.Read_High], High_Water, allocator)
    if high_err == .Out_Of_Memory {
        return high_err
    }

    assert(high_err == .None, "the recovery read matches High_Water")
    mappings.read_high = high

    events, events_err := sqlite.scan_prepare(set[.Events_After], Event_Row, allocator)
    if events_err == .Out_Of_Memory {
        return events_err
    }

    assert(events_err == .None, "the tail read matches Event_Row")
    mappings.events_after = events

    return nil
}

// Release whatever is resolved and blank the set; safe on a partial set.
@(private)
mappings_destroy :: proc(mappings: ^Mappings, allocator: mem.Allocator) {
    assert(mappings != nil, "mappings_destroy needs a set")

    sqlite.scan_mapping_destroy(&mappings.read_high, allocator)
    sqlite.scan_mapping_destroy(&mappings.events_after, allocator)
}

// Resolve every parameter shape. Both sides are compiled in, and a bind mapping
// allocates nothing, so there is no runtime failure to report: a statement that
// stopped matching its struct is a programmer error. Should be called once.
@(private)
binds_prepare :: proc(set: Statements, binds: ^Binds) {
    assert(binds != nil, "binds_prepare needs a set to fill")
    assert(binds^ == Binds{}, "the bind set is prepared once")

    binds.create_session = bind_expect(set, .Create_Session, Create_Session_Params)
    binds.append_event = bind_expect(set, .Append_Event, Append_Event_Params)
    binds.advance_seq = bind_expect(set, .Advance_Seq, Advance_Seq_Params)
    binds.bump_ids = bind_expect(set, .Bump_Ids, Bump_Ids_Params)
    binds.read_high = bind_expect(set, .Read_High, Session_Params)
    binds.events_after = bind_expect(set, .Events_After, Events_After_Params)
}

// `loc` is the caller's line, so a drifted statement names itself rather than
// pointing every failure at this helper.
@(private)
bind_expect :: proc(set: Statements, id: Statement_Id, $P: typeid, loc := #caller_location) -> sqlite.Bind_Mapping(P) {
    assert(set[id] != nil, "binds_prepare runs after the statements are prepared", loc)

    mapping, err := sqlite.bind_prepare(set[id], P)
    assert(err == .None, "a statement matches its parameter struct", loc)

    return mapping
}
