package store

import "core:strings"

import "libs:sqlite"
import "src:wire"

// Session-scoped ids. Zero means no bump: the store keeps the larger of the
// stored and offered mark, so a stale bump can never rewind one.
Id_Marks :: struct {
    // Highest draft or committed message id handed out.
    message_id: wire.Message_Id,

    // Highest run id handed out.
    run_id:     wire.Run_Id,

    // Highest queued-input id handed out.
    input_id:   wire.Input_Id,

    // Highest run-config revision handed out.
    config_rev: wire.Config_Rev,
}

// Everything a session's minting state is recovered from at daemon start. Zero
// throughout for a session that has never been written.
High_Water :: struct {
    // Last committed durable seq; the next append is `seq + 1`.
    seq:       wire.Seq,

    // Id families, recovered with the seq so one read restores minting state.
    using ids: Id_Marks,
}

// One persisted event. Column memory dies at the next step, so the strings are
// cloned into the caller's allocator; release with `events_destroy`.
Event :: struct {
    // Position on the session's durable stream.
    seq:     wire.Seq,

    // Broadcast this row replays as.
    name:    wire.Broadcast_Name,

    // Wire JSON verbatim; the codec, not the store, is its validator.
    payload: string,
}

// Append one durable event and advance the session's seq high-water in a single
// transaction. `events.seq` and `session_meta.seq_high` are bound from the same
// parameter, so a commit can never leave them disagreeing.
event_append :: proc(
    s: ^Store,
    session: wire.Session_Id,
    seq: wire.Seq,
    name: wire.Broadcast_Name,
    payload: string,
    ids: Id_Marks = {},
) -> (
    err: Error,
) {
    assert(s != nil, "event_append needs a store")
    assert(s.writer != nil, "an open store always holds its writer")
    assert(seq > 0, "seq numbering starts at 1")
    assert(u64(seq) <= wire.MAX_WIRE_INTEGER, "seq stays in the JSON safe integer range")
    assert(wire.broadcast_name_class(name) == .Durable_Gated, "only durable broadcasts are logged")
    assert(len(payload) > 0, "a durable event carries its encoded payload")
    id_marks_assert(ids)

    txn_begin(s.writer, .Write_Failed) or_return

    defer if err != .None {
        rollback := sqlite.exec(s.writer, "ROLLBACK")

        if rollback == .Ok {
            assert(sqlite.autocommit(s.writer), "a successful ROLLBACK ends the append transaction")
        }
    }

    append_body(s, session, seq, name, payload, ids) or_return
    txn_commit(s.writer, .Write_Failed) or_return

    return .None
}

// Raise id marks without logging an event: some ids are minted outside an
// append, yet must not be reused after a restart.
bump_ids :: proc(s: ^Store, session: wire.Session_Id, ids: Id_Marks) -> Error {
    assert(s != nil, "bump_ids needs a store")
    assert(s.writer != nil, "an open store always holds its writer")
    assert(ids != Id_Marks{}, "a bump raises at least one mark")
    id_marks_assert(ids)

    sid := ([16]u8)(session)
    ensure := s.stmts[.Ensure_Meta]
    assert(ensure != nil, "the statement set is prepared at open")

    // Two autocommits rather than a transaction: an all-zero row left behind by a
    // failed bump reads exactly like the absent row it replaced.
    stmt_bind(s.writer, ensure, sqlite.bind_blob(ensure, 1, sid[:]), .Write_Failed) or_return
    stmt_exec(s.writer, ensure, .Write_Failed) or_return

    return bump_ids_body(s, session, ids)
}

// Read a session's recovery marks. A session with no row has never been written
// and recovers as zeros, which makes its first minted seq 1.
high_water :: proc(s: ^Store, session: wire.Session_Id) -> (hw: High_Water, err: Error) {
    assert(s != nil, "high_water needs a store")
    assert(s.writer != nil, "an open store always holds its writer")

    st := s.stmts[.Read_High]
    assert(st != nil, "the statement set is prepared at open")

    sid := ([16]u8)(session)
    stmt_bind(s.writer, st, sqlite.bind_blob(st, 1, sid[:]), .Read_Failed) or_return

    step := sqlite.step(st)

    if step == .Row {
        values: [5]u64
        for &slot, col in values {
            value, ok := stored_wire_integer(st, col, true)

            if !ok {
                err = .Read_Failed

                break
            }

            slot = value
        }

        if err == .None {
            hw = High_Water {
                seq = wire.Seq(values[0]),
                ids = {
                    message_id = wire.Message_Id(values[1]),
                    run_id = wire.Run_Id(values[2]),
                    input_id = wire.Input_Id(values[3]),
                    config_rev = wire.Config_Rev(values[4]),
                },
            }

            step = sqlite.step(st)
        }
    }

    if sqlite.is_error(step) && err == .None {
        err = error_from(s.writer, step, .Read_Failed)
    }

    reset := sqlite.reset(st)
    cleared := sqlite.clear_bindings(st)

    if err != .None {
        return {}, err
    }

    if step != .Done {
        return {}, .Read_Failed
    }

    if reset != .Ok {
        return {}, error_from(s.writer, reset, .Read_Failed)
    }

    if cleared != .Ok {
        return {}, error_from(s.writer, cleared, .Read_Failed)
    }

    return hw, .None
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
    assert(u64(seq) <= wire.MAX_WIRE_INTEGER, "the cursor stays in the JSON safe integer range")
    assert(limit > 0, "a tail read is bounded")
    assert(u64(limit) <= wire.MAX_WIRE_INTEGER, "the row limit fits SQLite and the wire range")

    st := s.stmts[.Events_After]
    assert(st != nil, "the statement set is prepared at open")

    sid := ([16]u8)(session)
    stmt_bind(s.writer, st, sqlite.bind_blob(st, 1, sid[:]), .Read_Failed) or_return
    stmt_bind(s.writer, st, sqlite.bind_i64(st, 2, i64(seq)), .Read_Failed) or_return
    stmt_bind(s.writer, st, sqlite.bind_i64(st, 3, i64(limit)), .Read_Failed) or_return

    rows, make_err := make([dynamic]Event, 0, min(limit, 16), allocator)

    if make_err != nil {
        _ = sqlite.reset(st)
        _ = sqlite.clear_bindings(st)

        return nil, .Out_Of_Memory
    }

    defer if err != .None {
        for e in rows {
            delete(e.payload, allocator)
        }

        delete(rows)
    }

    step: sqlite.Result
    for {
        step = sqlite.step(st)

        if step != .Row {
            break
        }

        stored_seq, seq_ok := stored_wire_integer(st, 0, false)

        if !seq_ok || stored_seq <= u64(seq) {
            err = .Read_Failed

            break
        }

        if len(rows) > 0 && stored_seq <= u64(rows[len(rows) - 1].seq) {
            err = .Read_Failed

            break
        }

        if sqlite.column_type(st, 1) != .Text {
            err = .Read_Failed

            break
        }

        name, known := wire.broadcast_name_from_wire(sqlite.column_text(st, 1))

        if !known || wire.broadcast_name_class(name) != .Durable_Gated {
            err = .Read_Failed

            break
        }

        if sqlite.column_type(st, 2) != .Text || len(sqlite.column_text(st, 2)) == 0 {
            err = .Read_Failed

            break
        }

        payload, clone_err := strings.clone(sqlite.column_text(st, 2), allocator)

        if clone_err != nil {
            err = .Out_Of_Memory

            break
        }

        _, append_err := append(&rows, Event{seq = wire.Seq(stored_seq), name = name, payload = payload})

        if append_err != nil {
            delete(payload, allocator)
            err = .Out_Of_Memory

            break
        }
    }

    step_err := Error.None

    if sqlite.is_error(step) {
        step_err = error_from(s.writer, step, .Read_Failed)
    }

    reset := sqlite.reset(st)
    cleared := sqlite.clear_bindings(st)

    if err != .None {
        return nil, err
    }

    if step_err != .None {
        return nil, step_err
    }

    assert(step == .Done, "the row loop ends on completion")
    assert(len(rows) <= limit, "a tail read never exceeds its limit")

    if reset != .Ok {
        return nil, error_from(s.writer, reset, .Read_Failed)
    }

    if cleared != .Ok {
        return nil, error_from(s.writer, cleared, .Read_Failed)
    }

    return rows, .None
}

// Release a tail read with the allocator carried by its dynamic array.
events_destroy :: proc(events: [dynamic]Event) {
    allocator := events.allocator
    for e in events {
        delete(e.payload, allocator)
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
) -> Error {
    assert(s != nil && s.writer != nil, "append_body needs an open store")
    assert(seq > 0 && u64(seq) <= wire.MAX_WIRE_INTEGER, "append_body receives a valid seq")
    assert(wire.broadcast_name_class(name) == .Durable_Gated, "append_body receives a durable name")
    assert(len(payload) > 0, "append_body receives an encoded payload")

    sid := ([16]u8)(session)
    ensure := s.stmts[.Ensure_Meta]
    event := s.stmts[.Append_Event]
    advance := s.stmts[.Advance_Seq]
    assert(ensure != nil, "ensure_meta is prepared at open")
    assert(event != nil, "append_event is prepared at open")
    assert(advance != nil, "advance_seq is prepared at open")

    stmt_bind(s.writer, ensure, sqlite.bind_blob(ensure, 1, sid[:]), .Write_Failed) or_return
    stmt_exec(s.writer, ensure, .Write_Failed) or_return

    stmt_bind(s.writer, event, sqlite.bind_blob(event, 1, sid[:]), .Write_Failed) or_return
    stmt_bind(s.writer, event, sqlite.bind_i64(event, 2, i64(seq)), .Write_Failed) or_return
    stmt_bind(s.writer, event, sqlite.bind_text(event, 3, wire.broadcast_name_to_wire(name)), .Write_Failed) or_return
    stmt_bind(s.writer, event, sqlite.bind_text(event, 4, payload), .Write_Failed) or_return
    stmt_exec(s.writer, event, .Write_Failed) or_return

    // The guard is the contiguity rule itself: only the row whose high-water is
    // `seq - 1` advances, so a gap or a replay writes nothing.
    stmt_bind(s.writer, advance, sqlite.bind_blob(advance, 1, sid[:]), .Write_Failed) or_return
    stmt_bind(s.writer, advance, sqlite.bind_i64(advance, 2, i64(seq)), .Write_Failed) or_return
    stmt_exec(s.writer, advance, .Write_Failed) or_return

    if sqlite.changes(s.writer) == 0 {
        return .Seq_Conflict
    }

    if ids != (Id_Marks{}) {
        bump_ids_body(s, session, ids) or_return
    }

    return .None
}

// Raise the four id columns of an existing `session_meta` row.
@(private)
bump_ids_body :: proc(s: ^Store, session: wire.Session_Id, ids: Id_Marks) -> Error {
    assert(s != nil && s.writer != nil, "bump_ids_body needs an open store")
    id_marks_assert(ids)

    st := s.stmts[.Bump_Ids]
    assert(st != nil, "the statement set is prepared at open")

    sid := ([16]u8)(session)
    stmt_bind(s.writer, st, sqlite.bind_blob(st, 1, sid[:]), .Write_Failed) or_return
    stmt_bind(s.writer, st, sqlite.bind_i64(st, 2, i64(ids.message_id)), .Write_Failed) or_return
    stmt_bind(s.writer, st, sqlite.bind_i64(st, 3, i64(ids.run_id)), .Write_Failed) or_return
    stmt_bind(s.writer, st, sqlite.bind_i64(st, 4, i64(ids.input_id)), .Write_Failed) or_return
    stmt_bind(s.writer, st, sqlite.bind_i64(st, 5, i64(ids.config_rev)), .Write_Failed) or_return

    return stmt_exec(s.writer, st, .Write_Failed)
}

// SQLite conversion is permissive; durable values are accepted only in their
// exact INTEGER storage class and JSON-safe unsigned range.
@(private)
stored_wire_integer :: proc(st: ^sqlite.Stmt, col: int, zero_allowed: bool) -> (value: u64, ok: bool) {
    assert(st != nil, "stored_wire_integer needs a row")
    assert(col >= 0 && col < sqlite.column_count(st), "stored column is in range")

    if sqlite.column_type(st, col) != .Integer {
        return 0, false
    }

    signed := sqlite.column_i64(st, col)
    minimum: i64 = 0 if zero_allowed else 1

    if signed < minimum || signed > wire.MAX_WIRE_INTEGER {
        return 0, false
    }

    return u64(signed), true
}

// Minted ids are ours, already validated; the wire range is the invariant that
// keeps them representable as SQLite integers and as JSON numbers.
@(private)
id_marks_assert :: proc(ids: Id_Marks) {
    assert(u64(ids.message_id) <= wire.MAX_WIRE_INTEGER, "message ids stay in the JSON safe integer range")
    assert(u64(ids.run_id) <= wire.MAX_WIRE_INTEGER, "run ids stay in the JSON safe integer range")
    assert(u64(ids.input_id) <= wire.MAX_WIRE_INTEGER, "input ids stay in the JSON safe integer range")
    assert(u64(ids.config_rev) <= wire.MAX_WIRE_INTEGER, "config revs stay in the JSON safe integer range")
}
