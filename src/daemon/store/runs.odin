package store

import "core:mem"

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

// A session's `message_count` and open-run state, read together from its row. resync
// reads this after `high_water` has confirmed the session exists.
Session_Activity :: struct {
    message_count: u64,
    open_run:      Maybe(Open_Run),
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

// A session's message count and open-run state. Called after `high_water` has confirmed the
// session exists, so the row is always present. A stored value the codec rejects is `Invalid_Row`.
session_activity :: proc(
    s: ^Store,
    session: wire.Session_Id,
    allocator: mem.Allocator,
) -> (
    activity: Session_Activity,
    err: Error,
) {
    assert(s != nil, "session_activity needs a store")
    assert(s.writer != nil, "an open store always holds its writer")

    row, sqlite_err := queries.session_activity(&s.queries, {session_id = session}, allocator)
    if sqlite_err != nil {
        return {}, read_err(sqlite_err)
    }

    activity.message_count = row.message_count

    run_id, running := row.open_run_id.?
    if !running {
        return activity, nil
    }

    kind_wire, _ := row.open_run_kind.?
    kind, kind_ok := wire.run_kind_from_wire(kind_wire)
    if !kind_ok {
        return {}, Store_Error.Invalid_Row
    }

    reason: Maybe(wire.Compaction_Reason)
    if reason_wire, has_reason := row.open_run_reason.?; has_reason {
        parsed, reason_ok := wire.compaction_reason_from_wire(reason_wire)
        if !reason_ok {
            return {}, Store_Error.Invalid_Row
        }

        reason = parsed
    }

    config_rev, _ := row.open_run_config_rev.?
    started_at_ms, _ := row.open_run_started_at_ms.?

    activity.open_run = Open_Run {
        run_id        = run_id,
        kind          = kind,
        reason        = reason,
        config_rev    = config_rev,
        started_at_ms = started_at_ms,
    }

    return activity, nil
}
