package store

import "libs:bindings/sqlite"
import "src:wire"

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

// One persisted event. Its payload is cloned into the caller's allocator; an
// array read releases it with `events_destroy`, while a visitor takes ownership.
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

// One row scanned from the `events` table. `name` is borrowed from SQLite's column
// memory and dies with this row — it must not be retained. `payload` is owned by the
// row's allocator and freed by `scan_destroy` unless transferred out first.
@(private)
Event_Row :: struct {
    seq:     wire.Seq,
    name:    string `sql:",borrowed"`,
    payload: string,
}

// Field names are the statements' parameter names: a marker binds to the field
// that shares its name, so a parameter struct carries no ordering relationship
// to its SQL. Shared by the two statements keyed on a session alone.
@(private)
Session_Params :: struct {
    session_id: wire.Session_Id,
}

@(private)
Advance_Seq_Params :: struct {
    session_id: wire.Session_Id,
    seq:        wire.Seq,
}

// `name` is the broadcast's wire name, not its Odin identifier, so the enum is
// converted at the call site rather than bound as a discriminant.
@(private)
Append_Event_Params :: struct {
    session_id: wire.Session_Id,
    seq:        wire.Seq,
    name:       string,
    payload:    string,
}

// `Id_Marks` already names its columns for the recovery read; the bump's markers
// are those same names, so one struct serves both directions.
@(private)
Bump_Ids_Params :: struct {
    session_id: wire.Session_Id,
    using ids:  Id_Marks,
}

@(private)
Events_After_Params :: struct {
    session_id: wire.Session_Id,
    seq:        wire.Seq,
    limit:      int,
}

// Append one durable event and advance the session's seq high-water in a single
// transaction. `events.seq` and `sessions.seq_high` are bound from the same
// parameter, so a commit can never leave them disagreeing.
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

    // The typed payload is the single source: the row's name is derived from it
    // rather than passed alongside, so the two cannot disagree, and the
    // projection folds the same value the row encodes.
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
    sqlite.txn_commit(s.writer) or_return

    return nil
}

// Read a session's recovery marks. A session with no row has never been written
// and recovers as zeros, which makes its first minted seq 1.
high_water :: proc(s: ^Store, session: wire.Session_Id) -> (hw: High_Water, err: Error) {
    assert(s != nil, "high_water needs a store")
    assert(s.writer != nil, "an open store always holds its writer")

    st := s.stmts[.Read_High]
    assert(st != nil, "the statement set is prepared at open")

    defer _ = sqlite.reset_and_clear(st)

    sqlite.bind(&s.binds.read_high, &Session_Params{session_id = session}) or_return

    step := sqlite.step(st)

    if step == .Row {
        scan_err := sqlite.scan(&s.mappings.read_high, &hw, context.allocator)
        if scan_err != .None {
            err = scan_err
        } else {
            step = sqlite.step(st)
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

    st := s.stmts[.Events_After]
    assert(st != nil, "the statement set is prepared at open")

    defer _ = sqlite.reset_and_clear(st)

    sqlite.bind(&s.binds.events_after, &Events_After_Params{session_id = session, seq = seq, limit = limit}) or_return

    step: sqlite.Result
    previous := seq
    for {
        step = sqlite.step(st)
        if step != .Row {
            break
        }

        row: Event_Row
        scan_err := sqlite.scan(&s.mappings.events_after, &row, allocator)

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

@(private)
Events_Collect :: struct {
    rows: ^[dynamic]Event,
    err:  Error,
}

@(private)
events_collect :: proc(user: rawptr, event: Event) -> Event_Visit {
    collect := (^Events_Collect)(user)
    assert(collect != nil, "events_collect needs collection state")
    assert(collect.rows != nil, "events_collect needs a destination")
    assert(collect.err == nil, "events_collect stops after its first error")

    _, append_err := append(collect.rows, event)
    if append_err != nil {
        delete(event.payload, collect.rows^.allocator)
        collect.err = Store_Error.Alloc_Failed

        return .Stop
    }

    return .Continue
}

// Read up to `limit` events after `seq`, oldest first. Rows are materialized
// rather than streamed: a read transaction should not stay open across the
// caller's use of them.
events_after :: proc(
    s: ^Store,
    session: wire.Session_Id,
    seq: wire.Seq,
    limit: int,
    allocator := context.allocator,
) -> (
    events: [dynamic]Event,
    err: Error,
) {
    assert(s != nil, "events_after needs a store")
    assert(s.writer != nil, "an open store always holds its writer")
    assert(limit > 0, "a tail read is bounded")

    rows, make_err := make([dynamic]Event, 0, min(limit, 16), allocator)
    if make_err != nil {
        return nil, Store_Error.Alloc_Failed
    }
    defer if err != nil {
        events_destroy(rows)
    }

    collect := Events_Collect {
        rows = &rows,
    }
    visited, stopped, visit_err := events_visit_after(s, session, seq, limit, events_collect, &collect, allocator)

    if visit_err != nil {
        return nil, visit_err
    }

    if stopped {
        assert(collect.err != nil, "the collector stops only on append failure")

        return nil, collect.err
    }

    assert(collect.err == nil, "a completed collection did not fail")
    assert(visited == len(rows), "the collector retains every visited event")

    return rows, nil
}

// Release a tail read with the allocator carried by its dynamic array.
events_destroy :: proc(events: [dynamic]Event) {
    for e in events {
        delete(e.payload, events.allocator)
    }

    delete(events)
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
    // advances, so every gap or replay gets one error classification — including a session
    // that was never created, which has no row to match and lands here as Seq_Conflict.
    sqlite.execute(&s.binds.advance_seq, &Advance_Seq_Params{session_id = session, seq = seq}) or_return

    changed := sqlite.changes(s.writer)
    assert(changed <= 1, "the seq guard updates at most one session row")

    if changed == 0 {
        return .Seq_Conflict
    }

    assert(changed == 1, "a contiguous append advances its session row")

    sqlite.execute(
        &s.binds.append_event,
        &Append_Event_Params {
            session_id = session,
            seq = seq,
            name = wire.broadcast_name_to_wire(name),
            payload = payload,
        },
    ) or_return

    // `config_rev` 0 means "no revision", so a config change can raise nothing at
    // all; the bump would be a no-op UPDATE and `id_marks_advance` asserts otherwise.
    if ids != (Id_Marks{}) {
        id_marks_advance(s, session, ids) or_return
    }

    return nil
}

// Raise the four id columns of the append's existing `sessions` row.
@(private)
id_marks_advance :: proc(s: ^Store, session: wire.Session_Id, ids: Id_Marks) -> (err: Error) {
    assert(s != nil, "id mark advance needs a store")
    assert(s.writer != nil, "id mark advance needs an open writer")
    assert(ids != Id_Marks{}, "an id mark advance raises at least one family")

    sqlite.execute(&s.binds.bump_ids, &Bump_Ids_Params{session_id = session, ids = ids}) or_return
    assert(sqlite.changes(s.writer) == 1, "id marks advance an existing session row")

    return nil
}
