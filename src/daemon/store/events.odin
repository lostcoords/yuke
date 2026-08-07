package store

import "src:daemon/store/queries"
import "src:wire"

import "libs:bindings/sqlite"

// Session-scoped ids. Zero means no bump: the store keeps the larger of the
// stored and offered mark, so a stale bump can never rewind one.
Id_Marks :: struct {
    // Highest draft or committed message id handed out.
    message_id: wire.Message_Id `sql:"message_id_high"`,

    // Highest run id handed out.
    run_id:     wire.Run_Id `sql:"run_id_high"`,

    // Highest queued-input id handed out.
    input_id:   wire.Input_Id `sql:"input_id_high"`,

    // Highest run-config revision handed out.
    config_rev: wire.Config_Rev `sql:"config_rev_high"`,
}

// Everything a session's minting state is recovered from at daemon start. Zero
// throughout for a session that has never been written.
High_Water :: struct {
    // Last committed durable seq; the next append is `seq + 1`.
    seq:       wire.Seq `sql:"seq_high"`,

    // Id families, recovered with the seq so one read restores minting state.
    using ids: Id_Marks,
}

// One persisted event. Its payload is cloned into the caller's allocator and the
// visitor it is handed to owns it.
Event :: struct {
    // Position on the session's durable stream.
    seq:     wire.Seq,

    // Broadcast this row replays as.
    name:    wire.Broadcast_Name,

    // Wire JSON verbatim; the codec, not the store, is its validator.
    payload: string,
}

Event_Visit :: enum {
    Continue,
    Stop,
}

// The event payload belongs to the visitor, including when it stops the read.
Event_Visitor :: #type proc(user: rawptr, event: Event) -> Event_Visit

// One row scanned from `events`. `name` is borrowed from SQLite's column memory and dies with
// this row — do not retain it. `payload` is owned by the row allocator, freed unless transferred out.
@(private)
Event_Row :: struct {
    seq:     wire.Seq,
    name:    string `sql:",borrowed"`,
    payload: string,
}

@(private)
Events_After_Params :: struct {
    session_id: wire.Session_Id,
    seq:        wire.Seq,
    limit:      int,
}

// `events_by_session_seq` is this read's index.
@(private)
EVENTS_AFTER_SQL :: `SELECT seq, name, payload FROM events
    WHERE session_id = :session_id AND seq > :seq ORDER BY seq LIMIT :limit`

// `Event_Row.name` is borrowed, which `sqlite.Reader` refuses at prepare time since it would
// dangle past the read loop's own step. Hand-rolled bind and scan mirror what `Reader` bundles.
@(private)
Events_After_Reader :: struct {
    statement: ^sqlite.Stmt,
    bind:      sqlite.Bind_Mapping(Events_After_Params),
    scan:      sqlite.Scan_Mapping(Event_Row),
}

@(private)
events_after_prepare :: proc(
    db: ^sqlite.Conn,
    allocator := context.allocator,
) -> (
    r: Events_After_Reader,
    err: Error,
) {
    assert(db != nil, "events_after_prepare needs a connection")

    st := sqlite.prepare(db, EVENTS_AFTER_SQL) or_return

    bind, bind_err := sqlite.bind_prepare(st, Events_After_Params)
    assert(bind_err == .None, "the tail read's SQL matches Events_After_Params")

    scan, scan_err := sqlite.scan_prepare(st, Event_Row, allocator)
    if scan_err == .Out_Of_Memory {
        sqlite.finalize(st)

        return {}, scan_err
    }

    assert(scan_err == .None, "the tail read matches Event_Row")

    return Events_After_Reader{statement = st, bind = bind, scan = scan}, nil
}

@(private)
events_after_destroy :: proc(r: ^Events_After_Reader, allocator := context.allocator) {
    assert(r != nil, "events_after_destroy needs a reader")

    sqlite.scan_mapping_destroy(&r.scan, allocator)
    sqlite.finalize(r.statement)
    r^ = {}
}

// Append one durable event and advance the session's seq high-water in a single transaction.
// `events.seq` and `sessions.seq_high` are bound from the same parameter, so they cannot disagree.
event_append :: proc(
    s: ^Store,
    session: wire.Session_Id,
    seq: wire.Seq,
    data: wire.Broadcast_Data,
    payload: string,
    ids: Id_Marks,
) -> (
    err: Error,
) {
    assert(s != nil, "event_append needs a store")
    assert(s.writer != nil, "an open store always holds its writer")
    assert(seq > 0, "seq numbering starts at 1")
    assert(len(payload) > 0, "a durable event carries its encoded payload")

    // The typed payload is the single source: the row's name is derived from it, not
    // passed alongside, so the two cannot disagree, and the projection folds the same value.
    name, named := wire.broadcast_data_name(data)
    assert(named, "a durable payload names its broadcast")
    assert(wire.broadcast_name_class(name) == .Durable_Gated, "only durable broadcasts are logged")

    sqlite.txn_begin(s.writer, .Immediate) or_return

    // A failed ROLLBACK leaves the transaction open, which outlives this call, so it
    // replaces the original error rather than being dropped.
    defer if err != nil {
        if rollback := sqlite.txn_rollback(s.writer); rollback != .Ok {
            err = rollback
        }
    }

    append_body(s, session, seq, name, payload, ids) or_return
    messages_apply(s, session, seq, data) or_return
    configs_apply(s, session, data) or_return
    runs_apply(s, session, data) or_return
    sqlite.txn_commit(s.writer) or_return

    return nil
}

// Read a session's recovery marks. A session with no row has never been written
// and recovers as zeros, which makes its first minted seq 1.
high_water :: proc(s: ^Store, session: wire.Session_Id) -> (hw: High_Water, err: Error) {
    assert(s != nil, "high_water needs a store")
    assert(s.writer != nil, "an open store always holds its writer")

    reader := &s.queries.read_high
    defer _ = sqlite.reset_and_clear(reader.statement)

    sqlite.bind(&reader.bind, &queries.Read_High_Params{session_id = session}) or_return

    step := sqlite.step(reader.statement)

    if step == .Row {
        row: queries.Read_High_Row
        scan_err := sqlite.scan(&reader.scan, &row, context.allocator)

        if scan_err != .None {
            err = scan_err
        } else {
            hw = High_Water {
                seq = row.seq_high,
                ids = Id_Marks {
                    message_id = row.message_id_high,
                    run_id = row.run_id_high,
                    input_id = row.input_id_high,
                    config_rev = row.config_rev_high,
                },
            }
            step = sqlite.step(reader.statement)
        }
    }

    if err == nil && sqlite.is_error(step) {
        err = step
    }

    // `session_id` is the primary key, so the second step completes the statement;
    // a further row means the read is not the one this proc believes it is.
    if err == nil && step != .Done {
        err = .Invalid_Row
    }

    if err != nil {
        return {}, err
    }

    return hw, nil
}

// Visit up to `limit` owned events after `seq`, oldest first. The callback runs
// while the cached statement is active and must not re-enter this store.
events_visit_after :: proc(
    s: ^Store,
    session: wire.Session_Id,
    seq: wire.Seq,
    limit: int,
    visitor: Event_Visitor,
    user: rawptr,
    allocator := context.allocator,
) -> (
    visited: int,
    stopped: bool,
    err: Error,
) {
    assert(s != nil, "events_visit_after needs a store")
    assert(s.writer != nil, "an open store always holds its writer")
    assert(limit > 0, "a tail read is bounded")
    assert(visitor != nil, "an event visit needs a callback")
    assert(allocator.procedure != nil, "an event visit needs an allocator")

    st := s.events_after.statement
    defer _ = sqlite.reset_and_clear(st)

    sqlite.bind(&s.events_after.bind, &Events_After_Params{session_id = session, seq = seq, limit = limit}) or_return

    step: sqlite.Result
    previous := seq
    for {
        step = sqlite.step(st)
        if step != .Row {
            break
        }

        row: Event_Row
        scan_err := sqlite.scan(&s.events_after.scan, &row, allocator)

        if scan_err != .None {
            err = scan_err
            break
        }

        // The scan's clones die with this iteration on every path; a payload handed
        // to `rows` clears itself out of the row first.
        defer sqlite.scan_destroy(&row, allocator)

        // The cursor is non-negative and rows are ordered, so this also rejects
        // the never-minted seq 0.
        if row.seq <= previous {
            err = .Invalid_Row
            break
        }

        name, known := wire.broadcast_name_from_wire(row.name)
        if !known || wire.broadcast_name_class(name) != .Durable_Gated || len(row.payload) == 0 {
            err = .Invalid_Row
            break
        }

        event := Event {
            seq     = row.seq,
            name    = name,
            payload = row.payload,
        }
        row.payload = ""
        previous = event.seq
        visited += 1

        if visitor(user, event) == .Stop {
            stopped = true
            break
        }
    }

    if err == nil && sqlite.is_error(step) {
        err = step
    }

    if err != nil {
        return 0, false, err
    }

    if stopped {
        assert(step == .Row, "a visitor stops on the row it owns")
        assert(visited > 0, "only a visited row can stop iteration")

        return visited, true, nil
    }

    assert(step == .Done, "the row loop ends on completion")
    assert(visited <= limit, "a tail read never exceeds its limit")

    return visited, false, nil
}

// The transactional part of an append; the caller owns the transaction.
@(private)
append_body :: proc(
    s: ^Store,
    session: wire.Session_Id,
    seq: wire.Seq,
    name: wire.Broadcast_Name,
    payload: string,
    ids: Id_Marks,
) -> (
    err: Error,
) {
    assert(s != nil, "append_body needs a store")
    assert(s.writer != nil, "append_body needs an open writer")
    assert(seq > 0, "append_body receives a positive seq")
    assert(wire.broadcast_name_class(name) == .Durable_Gated, "append_body receives a durable name")
    assert(len(payload) > 0, "append_body receives an encoded payload")

    // The guard is the contiguity rule itself: only the row whose high-water is `seq - 1`
    // advances, so every gap, replay, or never-created session matches nothing; the existence read tells them apart.
    queries.advance_seq(&s.queries, {session_id = session, seq = seq}) or_return

    changed := sqlite.changes(s.writer)
    assert(changed <= 1, "the seq guard updates at most one session row")

    if changed == 0 {
        // Inside the caller's transaction, so no concurrent writer can create or
        // remove the row between the guard and this read.
        known := session_exists(s, session) or_return

        return known ? .Seq_Conflict : .Unknown_Session
    }

    assert(changed == 1, "a contiguous append advances its session row")

    queries.append_event(
        &s.queries,
        {session_id = session, seq = seq, name = wire.broadcast_name_to_wire(name), payload = payload},
    ) or_return

    // `config_rev` 0 means "no revision", so a config change can raise nothing at
    // all; the bump would be a no-op UPDATE and `id_marks_advance` asserts otherwise.
    if ids != (Id_Marks{}) {
        id_marks_advance(s, session, ids) or_return
    }

    return nil
}

// Whether the session has a registry row. `id` is the primary key, so one step
// settles it.
@(private)
session_exists :: proc(s: ^Store, session: wire.Session_Id) -> (exists: bool, err: Error) {
    assert(s != nil, "the existence read needs a store")
    assert(s.writer != nil, "an open store always holds its writer")

    st := s.queries.session_exists.statement
    defer _ = sqlite.reset_and_clear(st)

    sqlite.bind(&s.queries.session_exists, &queries.Session_Exists_Params{session_id = session}) or_return

    step := sqlite.step(st)

    if sqlite.is_error(step) {
        return false, step
    }

    assert(step == .Row || step == .Done, "a keyed existence read either matches or completes")

    return step == .Row, nil
}

// Raise the four id columns of the append's existing `sessions` row.
@(private)
id_marks_advance :: proc(s: ^Store, session: wire.Session_Id, ids: Id_Marks) -> (err: Error) {
    assert(s != nil, "id mark advance needs a store")
    assert(s.writer != nil, "id mark advance needs an open writer")
    assert(ids != Id_Marks{}, "an id mark advance raises at least one family")

    queries.bump_ids(
        &s.queries,
        {
            session_id = session,
            message_id_high = ids.message_id,
            run_id_high = ids.run_id,
            input_id_high = ids.input_id,
            config_rev_high = ids.config_rev,
        },
    ) or_return
    assert(sqlite.changes(s.writer) == 1, "id marks advance an existing session row")

    return nil
}
