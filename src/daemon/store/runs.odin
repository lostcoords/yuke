package store

import "core:mem"

import "src:daemon/store/queries"
import "src:wire"

import "libs:bindings/sqlite"

// A run that still owes a terminal. Not what a session is doing — a run dies with its
// daemon — but the repair list the next start works through. The fields `run.done` needs.
Open_Run :: struct {
    run_id:        wire.Run_Id,
    kind:          wire.Run_Kind,
    started_at_ms: u64,
}

// One repair-list entry; the sweep reads every session at once, so it names its own.
Open_Run_Row :: struct {
    session: wire.Session_Id,
    run:     Open_Run,
}

// What one sessions-row read yields: the client-facing summary and the recovery marker.
Session_Snapshot :: struct {
    session:  wire.Session,
    open_run: Maybe(Open_Run),
}

// Fold a run lifecycle event into the recovery marker, inside the append transaction.
// `run.started` records that a terminal is owed, `run.done` clears it, everything else is silent.
@(private)
runs_apply :: proc(s: ^Store, session: wire.Session_Id, data: wire.Broadcast_Data) -> Error {
    assert(s != nil, "runs_apply needs a store")
    assert(s.writer != nil, "runs_apply needs an open writer")

    #partial switch v in data {
    case wire.Run_Started_Data:
        queries.set_open_run(
            &s.queries,
            {
                session_id = session,
                open_run_id = v.run_id,
                open_run_kind = wire.run_kind_to_wire(v.kind),
                open_run_started_at_ms = v.started_at_ms,
            },
        ) or_return

        // Drift alarm, like the count update: a run's session row is always present.
        assert(sqlite.changes(s.writer) == 1, "an open-run set lands on the append's session row")

        return nil

    case wire.Run_Done_Data:
        return queries.clear_open_run(&s.queries, {session_id = session, open_run_id = v.run_id})
    }

    return nil
}

// Decode the nullable open-run columns embedded in a session snapshot.
@(private)
open_run_from_row :: proc(row: $Row) -> (Maybe(Open_Run), bool) {
    run_id, running := row.open_run_id.?
    kind_wire, has_kind := row.open_run_kind.?
    started_at_ms, has_started := row.open_run_started_at_ms.?
    if !running do return nil, !has_kind && !has_started

    if !has_kind || !has_started do return nil, false

    kind, kind_ok := wire.run_kind_from_wire(kind_wire)
    if !kind_ok do return nil, false

    return Open_Run{run_id = run_id, kind = kind, started_at_ms = started_at_ms}, true
}

// Every run still owing a terminal, oldest first. Read once, by the recovery sweep.
open_runs :: proc(s: ^Store, allocator: mem.Allocator) -> (runs: []Open_Run_Row, err: Error) {
    assert(s != nil, "open_runs needs a store")
    assert(s.writer != nil, "an open store always holds its writer")
    assert(allocator.procedure != nil, "an open-run read needs an allocator")

    rows, sqlite_err := queries.open_runs(&s.queries, {}, allocator)
    if sqlite_err != nil do return nil, read_err(sqlite_err)

    out := make([]Open_Run_Row, len(rows), allocator)

    for row, index in rows {
        kind, kind_ok := wire.run_kind_from_wire(row.open_run_kind)

        if !kind_ok do return nil, Store_Error.Invalid_Row

        out[index] = Open_Run_Row {
            session = row.session_id,
            run = {run_id = row.open_run_id, kind = kind, started_at_ms = row.open_run_started_at_ms},
        }
    }

    return out, nil
}
