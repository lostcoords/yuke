package store

import "src:daemon/store/queries"
import "src:wire"

import "libs:bindings/sqlite"

// A session's open run, decoded from the projection columns. Present exactly when a
// `run.started` has no matching `run.done`.
Open_Run :: struct {
    run_id:        wire.Run_Id,
    kind:          wire.Run_Kind,
    reason:        Maybe(wire.Compaction_Reason),
    config_rev:    wire.Config_Rev,
    started_at_ms: u64,
}

// The two projections resync needs from one sessions-row read.
Session_Snapshot :: struct {
    session:  wire.Session,
    open_run: Maybe(Open_Run),
}

// Fold a run lifecycle event into the open-run projection, inside the append transaction.
// `run.started` records the run left open; a matching `run.done` clears it; every other event says nothing.
@(private)
runs_apply :: proc(s: ^Store, session: wire.Session_Id, data: wire.Broadcast_Data) -> Error {
    assert(s != nil, "runs_apply needs a store")
    assert(s.writer != nil, "runs_apply needs an open writer")

    #partial switch v in data {
    case wire.Run_Started_Data:
        reason: Maybe(string)
        if r, ok := v.reason.?; ok {
            reason = wire.compaction_reason_to_wire(r)
        }

        queries.set_open_run(
            &s.queries,
            {
                session_id = session,
                open_run_id = v.run_id,
                open_run_kind = wire.run_kind_to_wire(v.kind),
                open_run_reason = reason,
                open_run_config_rev = v.config_rev,
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
    reason_wire, has_reason := row.open_run_reason.?
    config_rev, has_config := row.open_run_config_rev.?
    started_at_ms, has_started := row.open_run_started_at_ms.?
    if !running {
        return nil, !has_kind && !has_reason && !has_config && !has_started
    }

    if !has_kind || !has_config || !has_started {
        return nil, false
    }

    kind, kind_ok := wire.run_kind_from_wire(kind_wire)
    if !kind_ok {
        return nil, false
    }

    if has_reason != (kind == .Compaction) {
        return nil, false
    }

    reason: Maybe(wire.Compaction_Reason)
    if has_reason {
        parsed, reason_ok := wire.compaction_reason_from_wire(reason_wire)
        if !reason_ok {
            return nil, false
        }

        reason = parsed
    }

    open := Open_Run {
        run_id        = run_id,
        kind          = kind,
        reason        = reason,
        config_rev    = config_rev,
        started_at_ms = started_at_ms,
    }

    return open, true
}
