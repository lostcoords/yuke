package store

import "libs:sqlite"

// The store's closed set of hot statements. Adding one requires adding its SQL;
// the enum-indexed tables make partial prepare/finalize lists impossible.
@(private)
Statement_Id :: enum {
    Ensure_Meta,
    Append_Event,
    Advance_Seq,
    Bump_Ids,
    Read_High,
    Events_After,
}

@(private)
Statements :: distinct [Statement_Id]^sqlite.Stmt

// SQL remains concrete and visible; this is statement ownership, not a query
// builder or ORM.
@(private, rodata)
STATEMENT_SQL := [Statement_Id]string {
    .Ensure_Meta  = `INSERT OR IGNORE INTO session_meta(session_id) VALUES (?1)`,
    .Append_Event = `INSERT INTO events(session_id, seq, name, payload) VALUES (?1, ?2, ?3, ?4)`,

    // Contiguity lives in the update predicate: a gap matches nothing. A replay
    // never reaches it because the events primary key rejects the row first.
    .Advance_Seq  = `UPDATE session_meta SET seq_high = ?2
        WHERE session_id = ?1 AND seq_high = ?2 - 1`,

    // Marks only rise; a stale bump is a no-op rather than a rewind.
    .Bump_Ids     = `UPDATE session_meta SET
        message_id_high = MAX(message_id_high, ?2),
        run_id_high     = MAX(run_id_high, ?3),
        input_id_high   = MAX(input_id_high, ?4),
        config_rev_high = MAX(config_rev_high, ?5)
        WHERE session_id = ?1`,
    .Read_High    = `SELECT seq_high, message_id_high, run_id_high, input_id_high, config_rev_high
        FROM session_meta WHERE session_id = ?1`,

    // The composite primary key is this read's index; no extra index exists.
    .Events_After = `SELECT seq, name, payload FROM events
        WHERE session_id = ?1 AND seq > ?2 ORDER BY seq LIMIT ?3`,
}

// Prepare the whole set or none of it: a failure part-way finalizes what it
// already prepared, so the connection is never left holding statements it cannot
// be closed with.
@(private)
statements_prepare :: proc(db: ^sqlite.Conn, set: ^Statements) -> (err: Error) {
    assert(db != nil, "statements_prepare needs a connection")
    assert(set != nil, "statements_prepare needs a set to fill")
    assert(set^ == (Statements{}), "the statement set is prepared once")

    defer if err != .None {
        statements_finalize(set)
    }

    for sql, i in STATEMENT_SQL {
        id := Statement_Id(i)
        set[id] = statement_prepare(db, sql) or_return
    }

    return .None
}

// Finalize whatever is prepared and blank the set; safe on a partial set.
@(private)
statements_finalize :: proc(set: ^Statements) {
    assert(set != nil, "statements_finalize needs a set")

    for st in set {
        if st != nil {
            _ = sqlite.finalize(st)
        }
    }

    set^ = {}
}

@(private)
statement_prepare :: proc(db: ^sqlite.Conn, sql: string) -> (st: ^sqlite.Stmt, err: Error) {
    assert(db != nil, "statement_prepare needs a connection")
    assert(len(sql) > 0, "statement_prepare needs SQL")

    prepared, rc := sqlite.prepare(db, sql)

    if rc != .Ok {
        return nil, error_from(db, rc, .Open_Failed)
    }

    assert(prepared != nil, "a successful prepare yields a statement")

    return prepared, .None
}

// Step a bound statement to completion, then reset and clear it for reuse.
// `reset` reports the preceding step's failure, so both codes are consulted.
@(private)
stmt_exec :: proc(db: ^sqlite.Conn, st: ^sqlite.Stmt, fallback: Error) -> Error {
    assert(db != nil, "stmt_exec needs a connection")
    assert(st != nil, "stmt_exec needs a prepared statement")
    assert(fallback != .None, "a failure never classifies as None")

    step := sqlite.step(st)
    step_err := Error.None

    if sqlite.is_error(step) {
        step_err = error_from(db, step, fallback)
    }

    reset := sqlite.reset(st)
    cleared := sqlite.clear_bindings(st)

    if step_err != .None {
        return step_err
    }

    assert(step == .Done, "the store's write statements return no rows")

    if reset != .Ok {
        return error_from(db, reset, fallback)
    }

    if cleared != .Ok {
        return error_from(db, cleared, fallback)
    }

    return .None
}

// A failed bind clears every parameter already copied into this statement. RANGE
// is our SQL/call-site mismatch; allocation and size failures are operating errors.
@(private)
stmt_bind :: proc(db: ^sqlite.Conn, st: ^sqlite.Stmt, rc: sqlite.Result, fallback: Error) -> Error {
    assert(db != nil, "stmt_bind needs a connection")
    assert(st != nil, "stmt_bind needs a prepared statement")
    assert(rc != .Range, "bound a parameter the statement does not have")

    if rc == .Ok {
        return .None
    }

    _ = sqlite.reset(st)
    _ = sqlite.clear_bindings(st)

    return error_from(db, rc, fallback)
}
