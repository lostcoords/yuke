package daemon

import "core:nbio"
import "core:testing"

import "libs:bindings/sqlite"
import "libs:testsupport"
import ws "libs:websocket"
import client "src:client"
import store "src:daemon/store"
import wire "src:wire"

// --- session.resync cut tests --------------------------------------------------
//
// The cut is folded from the durable log alone; fixtures seed it through `broadcast`.
// One test carries a cut into a `src/client` replica, the fold's real consumer.

// A committed user message; empty content keeps the fixtures about the fold.
resync_user :: proc(session: wire.Session_Id, id: wire.Message_Id) -> wire.Broadcast_Data {
    return wire.Message_Committed_Data {
        session_id = session,
        message = wire.User_Message{id = id, input_id = wire.Input_Id(id), time = {created_at_ms = 1}},
    }
}

// A committed assistant message, which is what carries a `config_rev` reference.
resync_assistant :: proc(
    session: wire.Session_Id,
    id: wire.Message_Id,
    config_rev: wire.Config_Rev,
) -> wire.Broadcast_Data {
    return wire.Message_Committed_Data {
        session_id = session,
        message = wire.Assistant_Message {
            id = id,
            run_id = 1,
            config_rev = config_rev,
            agent = "main",
            finish = wire.Stop_Reason.Stop,
            time = {created_at_ms = 1, completed_at_ms = u64(2)},
        },
    }
}

resync_config :: proc(session: wire.Session_Id, rev: wire.Config_Rev, model: string) -> wire.Broadcast_Data {
    return wire.Config_Changed_Data {
        session_id = session,
        config = {config_rev = rev, model = model, reasoning = "low"},
    }
}

resync_truncated :: proc(session: wire.Session_Id, first_removed: wire.Message_Id) -> wire.Broadcast_Data {
    return wire.Transcript_Truncated_Data{session_id = session, first_removed_id = first_removed}
}

resync_run_started :: proc(session: wire.Session_Id, run_id: wire.Run_Id, started_at_ms: u64) -> wire.Broadcast_Data {
    return wire.Run_Started_Data {
        session_id = session,
        run_id = run_id,
        kind = .Turn,
        config_rev = 1,
        started_at_ms = started_at_ms,
    }
}

resync_run_done :: proc(session: wire.Session_Id, run_id: wire.Run_Id) -> wire.Broadcast_Data {
    return wire.Run_Done_Data {
        session_id = session,
        run_id = run_id,
        kind = .Turn,
        timing = {started_at_ms = u64(1), ended_at_ms = 2},
        outcome = wire.Run_Outcome_Turn{finish = .Stop, rounds = 1},
    }
}

resync_compaction_started :: proc(
    session: wire.Session_Id,
    run_id: wire.Run_Id,
    reason: wire.Compaction_Reason,
    started_at_ms: u64,
) -> wire.Broadcast_Data {
    return wire.Run_Started_Data {
        session_id = session,
        run_id = run_id,
        kind = .Compaction,
        reason = reason,
        config_rev = 1,
        started_at_ms = started_at_ms,
    }
}

resync_compaction_done :: proc(session: wire.Session_Id, run_id: wire.Run_Id) -> wire.Broadcast_Data {
    return wire.Run_Done_Data {
        session_id = session,
        run_id = run_id,
        kind = .Compaction,
        timing = {started_at_ms = u64(1), ended_at_ms = 2},
        outcome = wire.Run_Outcome_Compacted{message_id = 1},
    }
}

// Put a codec-valid but semantically impossible historical row directly on the log.
// Corruption fixtures bypass the pump so they do not model impossible daemon output as accepted.
resync_append_corrupt_fixture :: proc(t: ^testing.T, d: ^Daemon, data: wire.Broadcast_Data) {
    assert(d != nil, "a corruption fixture needs daemon state")
    assert(d.store != nil, "a corruption fixture needs an open store")

    session, named := wire.broadcast_data_session_id(data).?
    assert(named, "a durable corruption fixture names its session")

    hw, herr := store.high_water(d.store, session)
    testing.expect_value(t, herr, nil)
    seq := hw.seq + 1
    stamped := pump_stamp_seq(data, seq)

    e: wire.Emitter
    wire.emitter_init(&e, d.allocator)
    defer wire.emitter_destroy(&e)
    wire.broadcast_data_emit(&e, stamped)

    testing.expect_value(t, store.event_append(d.store, session, seq, stamped, wire.to_string(&e), {}), nil)
}

// Overwrite one stored payload without touching seq, marks, or the projection. This models
// a damaged file: the daemon's own write path could not have produced the replacement.
resync_damage_payload :: proc(
    t: ^testing.T,
    d: ^Daemon,
    session: wire.Session_Id,
    seq: wire.Seq,
    data: wire.Broadcast_Data,
) {
    assert(d != nil, "damaging a row needs daemon state")
    assert(d.store != nil, "damaging a row needs an open store")

    e: wire.Emitter
    wire.emitter_init(&e, d.allocator)
    defer wire.emitter_destroy(&e)
    wire.broadcast_data_emit(&e, pump_stamp_seq(data, seq))

    st, prep := sqlite.prepare(d.store.writer, "UPDATE events SET payload = ?1 WHERE session_id = ?2 AND seq = ?3")
    testing.expect_value(t, prep, sqlite.Result.Ok)
    defer sqlite.finalize(st)

    sid := ([16]u8)(session)
    testing.expect_value(t, sqlite.bind_text(st, 1, wire.to_string(&e)), sqlite.Result.Ok)
    testing.expect_value(t, sqlite.bind_blob(st, 2, sid[:]), sqlite.Result.Ok)
    testing.expect_value(t, sqlite.bind_i64(st, 3, i64(seq)), sqlite.Result.Ok)
    testing.expect_value(t, sqlite.execute(st), sqlite.Result.Ok)
    testing.expect_value(t, sqlite.changes(d.store.writer), 1)
}

// Build a cut with resync's own error logging silenced, then restore the testing logger so
// the caller's `expect` still counts; a corruption path logs an error the test logger would otherwise fail on.
resync_build_quiet :: proc(
    t: ^testing.T,
    d: ^Daemon,
    params: wire.Session_Resync_Params,
) -> (
    wire.Session_Resync_Result,
    Resync_Error,
) {
    saved := context.logger
    quiet_logger: testsupport.Assert_Only_Logger
    context.logger = testsupport.assert_only_logger(&quiet_logger, saved)
    result, err := resync_build(d, params, context.temp_allocator)
    context.logger = saved

    return result, err
}

// Attempt a codec-valid but semantically impossible append and assert the store rejects
// it at write time — the schema's own CHECK/PK guards, not a read-time fold.
resync_expect_write_rejected :: proc(t: ^testing.T, d: ^Daemon, data: wire.Broadcast_Data) {
    session, named := wire.broadcast_data_session_id(data).?
    assert(named, "a durable corruption fixture names its session")

    hw, herr := store.high_water(d.store, session)
    testing.expect_value(t, herr, nil)
    seq := hw.seq + 1
    stamped := pump_stamp_seq(data, seq)

    e: wire.Emitter
    wire.emitter_init(&e, d.allocator)
    defer wire.emitter_destroy(&e)
    wire.broadcast_data_emit(&e, stamped)

    rejected := store.event_append(d.store, session, seq, stamped, wire.to_string(&e), {}) != nil
    testing.expect(t, rejected, "the store rejects the corrupt write")
}

// Bring up a daemon on a real database and run `body` against it.
resync_with_daemon :: proc(t: ^testing.T, name: string, body: proc(t: ^testing.T, d: ^Daemon)) {
    path := testsupport.sqlite_db_path(t, name)
    defer testsupport.sqlite_db_remove(path)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    d: Daemon
    testing.expect_value(t, start(&d, loop, {host = "127.0.0.1", port = 0, db_path = path}), Error.None)
    testing.expect(t, d.store != nil, "a configured database opens the store at start")

    body(t, &d)

    test_teardown(&d)
}

@(test)
test_daemon_resync_cut_derives_from_the_log :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    resync_with_daemon(
        t,
        "daemon-resync-derive",
        proc(t: ^testing.T, d: ^Daemon) {
            session := pump_test_session('a')
            daemon_test_session_create(t, d, session)

            testing.expect_value(t, broadcast(d, resync_config(session, 1, "m1")), Pump_Error.None)
            testing.expect_value(t, broadcast(d, resync_user(session, 1)), Pump_Error.None)
            testing.expect_value(t, broadcast(d, resync_assistant(session, 2, 1)), Pump_Error.None)

            cut, err := resync_build(d, {session_id = session}, context.temp_allocator)
            testing.expect_value(t, err, Resync_Error.None)

            // The high-water and the fold are read at one instant on the reactor.
            hw, herr := store.high_water(d.store, session)
            testing.expect_value(t, herr, nil)
            testing.expect_value(t, cut.base_seq, hw.seq)
            testing.expect_value(t, cut.base_seq, wire.Seq(3))

            if testing.expect_value(t, len(cut.messages), 2) {
                testing.expect_value(t, wire.message_id(cut.messages[0]), wire.Message_Id(1))
                testing.expect_value(t, wire.message_id(cut.messages[1]), wire.Message_Id(2))
            }

            highest, finalized := cut.highest_finalized_message_id.?
            testing.expect(t, finalized, "a committed transcript has a finalized boundary")
            testing.expect_value(t, highest, wire.Message_Id(2))
            testing.expect(t, !cut.has_more, "the whole transcript fits the default page")
            testing.expect_value(t, cut.item.session.id, session)
            testing.expect_value(t, cut.item.session.message_count, u64(2))
            testing.expect_value(t, cut.item.session.workspace_id, wire.Workspace_Id(pump_test_session('f')))
            testing.expect_value(t, cut.item.session.profile, "default")
            testing.expect_value(t, cut.item.session.model, "m1")
            testing.expect_value(t, cut.item.session.reasoning, "low")
            testing.expect_value(t, cut.item.session.permission, wire.Permission_Mode.Normal)
            testing.expect_value(t, cut.item.session.title, "test")

            // Only the revision the page references is carried.
            if testing.expect_value(t, len(cut.configs), 1) {
                testing.expect_value(t, cut.configs[0].config_rev, wire.Config_Rev(1))
                testing.expect_value(t, cut.configs[0].model, "m1")
            }

            _, idle := cut.item.activity.state.(wire.Activity_State_Idle)
            testing.expect(t, idle, "no open run means idle")
            testing.expect_value(t, wire.session_resync_result_validate(cut), wire.Validation_Error.None)
        },
    )
}

// A session exists from the moment `session.create` writes its row, which is before
// anything has been appended to it. The cut is empty rather than refused: a client that
// creates a session and resyncs it immediately is asking about a session that is real.
@(test)
test_daemon_resync_of_a_session_with_no_events_is_an_empty_cut :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    resync_with_daemon(t, "daemon-resync-eventless", proc(t: ^testing.T, d: ^Daemon) {
        session := pump_test_session('a')
        daemon_test_session_create(t, d, session)

        cut, err := resync_build(d, {session_id = session}, context.temp_allocator)
        testing.expect_value(t, err, Resync_Error.None)
        testing.expect_value(t, cut.base_seq, wire.Seq(0))
        testing.expect_value(t, len(cut.messages), 0)
        testing.expect_value(t, len(cut.configs), 0)
        testing.expect(t, !cut.has_more, "an empty transcript has nothing older")
        testing.expect_value(t, cut.item.session.id, session)

        _, finalized := cut.highest_finalized_message_id.?
        testing.expect(t, !finalized, "a session that minted no message id has no boundary")

        _, idle := cut.item.activity.state.(wire.Activity_State_Idle)
        testing.expect(t, idle, "a session with no run is idle")
        testing.expect_value(t, wire.session_resync_result_validate(cut), wire.Validation_Error.None)
    })
}

@(test)
test_daemon_resync_of_an_unknown_session_is_refused :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    resync_with_daemon(
        t,
        "daemon-resync-unknown",
        proc(t: ^testing.T, d: ^Daemon) {
            written := pump_test_session('b')
            daemon_test_session_create(t, d, written)
            testing.expect_value(t, broadcast(d, resync_user(written, 1)), Pump_Error.None)

            // A session with no durable stream was never written by anything.
            _, err := resync_build(d, {session_id = pump_test_session('c')}, context.temp_allocator)
            testing.expect_value(t, err, Resync_Error.Unknown_Session)
        },
    )
}

@(test)
test_daemon_resync_in_empty_memory_store_is_unknown :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    d: Daemon
    testing.expect_value(t, start(&d, loop, {host = "127.0.0.1", port = 0}), Error.None)
    testing.expect(t, d.store != nil, "no database path selects the in-memory store")

    _, err := resync_build(&d, {session_id = pump_test_session('d')}, context.temp_allocator)
    testing.expect_value(t, err, Resync_Error.Unknown_Session)

    test_teardown(&d)
}

@(test)
test_daemon_resync_survives_a_restart :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    path := testsupport.sqlite_db_path(t, "daemon-resync-restart")
    defer testsupport.sqlite_db_remove(path)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    session := pump_test_session('e')

    first: Daemon
    testing.expect_value(t, start(&first, loop, {host = "127.0.0.1", port = 0, db_path = path}), Error.None)
    daemon_test_session_create(t, &first, session)
    testing.expect_value(t, broadcast(&first, resync_config(session, 1, "m1")), Pump_Error.None)
    testing.expect_value(t, broadcast(&first, resync_user(session, 1)), Pump_Error.None)

    before, berr := resync_build(&first, {session_id = session}, context.temp_allocator)
    testing.expect_value(t, berr, Resync_Error.None)
    test_teardown(&first)

    // Nothing about the cut lives in the daemon: a fresh process folds the same log.
    second: Daemon
    testing.expect_value(t, start(&second, loop, {host = "127.0.0.1", port = 0, db_path = path}), Error.None)

    after, aerr := resync_build(&second, {session_id = session}, context.temp_allocator)
    testing.expect_value(t, aerr, Resync_Error.None)
    testing.expect_value(t, after.base_seq, before.base_seq)
    testing.expect_value(t, len(after.messages), len(before.messages))
    testing.expect_value(t, after.item.session.message_count, before.item.session.message_count)

    if testing.expect_value(t, len(after.messages), 1) {
        testing.expect_value(t, wire.message_id(after.messages[0]), wire.Message_Id(1))
    }

    test_teardown(&second)
}

@(test)
test_daemon_resync_pages_the_transcript_tail :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    resync_with_daemon(
        t,
        "daemon-resync-paging",
        proc(t: ^testing.T, d: ^Daemon) {
            session := pump_test_session('f')
            daemon_test_session_create(t, d, session)

            for id in 1 ..= 5 {
                testing.expect_value(t, broadcast(d, resync_user(session, wire.Message_Id(id))), Pump_Error.None)
            }

            cut, err := resync_build(d, {session_id = session, limit = u64(2)}, context.temp_allocator)
            testing.expect_value(t, err, Resync_Error.None)

            // The page is the newest end of the transcript; `has_more` announces the rest.
            if testing.expect_value(t, len(cut.messages), 2) {
                testing.expect_value(t, wire.message_id(cut.messages[0]), wire.Message_Id(4))
                testing.expect_value(t, wire.message_id(cut.messages[1]), wire.Message_Id(5))
            }

            testing.expect(t, cut.has_more, "older messages remain beyond the page")
            testing.expect_value(t, cut.item.session.message_count, u64(5))
        },
    )
}

@(test)
test_daemon_resync_configs_cover_the_page :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    resync_with_daemon(
        t,
        "daemon-resync-configs",
        proc(t: ^testing.T, d: ^Daemon) {
            session := pump_test_session('1')
            daemon_test_session_create(t, d, session)

            testing.expect_value(t, broadcast(d, resync_config(session, 1, "m1")), Pump_Error.None)
            testing.expect_value(t, broadcast(d, resync_assistant(session, 1, 1)), Pump_Error.None)
            testing.expect_value(t, broadcast(d, resync_config(session, 2, "m2")), Pump_Error.None)
            testing.expect_value(t, broadcast(d, resync_assistant(session, 2, 2)), Pump_Error.None)
            testing.expect_value(t, broadcast(d, resync_assistant(session, 3, 2)), Pump_Error.None)

            cut, err := resync_build(d, {session_id = session}, context.temp_allocator)
            testing.expect_value(t, err, Resync_Error.None)

            // Every referenced revision appears exactly once.
            if testing.expect_value(t, len(cut.configs), 2) {
                testing.expect_value(t, cut.configs[0].config_rev, wire.Config_Rev(1))
                testing.expect_value(t, cut.configs[1].config_rev, wire.Config_Rev(2))
            }

            // The summary's future-run config is the newest announcement.
            testing.expect_value(t, cut.item.session.config_rev, wire.Config_Rev(2))
            testing.expect_value(t, cut.item.session.model, "m2")

            // A page that leaves the older revision behind stops carrying it.
            narrow, nerr := resync_build(d, {session_id = session, limit = u64(1)}, context.temp_allocator)
            testing.expect_value(t, nerr, Resync_Error.None)

            if testing.expect_value(t, len(narrow.configs), 1) {
                testing.expect_value(t, narrow.configs[0].config_rev, wire.Config_Rev(2))
            }
        },
    )
}

@(test)
test_daemon_resync_drops_truncated_messages :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    resync_with_daemon(
        t,
        "daemon-resync-truncate",
        proc(t: ^testing.T, d: ^Daemon) {
            session := pump_test_session('2')
            daemon_test_session_create(t, d, session)

            for id in 1 ..= 3 {
                testing.expect_value(t, broadcast(d, resync_user(session, wire.Message_Id(id))), Pump_Error.None)
            }

            testing.expect_value(t, broadcast(d, resync_truncated(session, 2)), Pump_Error.None)

            cut, err := resync_build(d, {session_id = session}, context.temp_allocator)
            testing.expect_value(t, err, Resync_Error.None)

            if testing.expect_value(t, len(cut.messages), 1) {
                testing.expect_value(t, wire.message_id(cut.messages[0]), wire.Message_Id(1))
            }

            // A discarded id is finalized too, so the boundary does not move back.
            highest, finalized := cut.highest_finalized_message_id.?
            testing.expect(t, finalized, "the boundary survives truncation")
            testing.expect_value(t, highest, wire.Message_Id(3))
            testing.expect_value(t, cut.item.session.message_count, u64(1))
        },
    )
}

@(test)
test_daemon_a_logged_run_no_engine_tracks_reads_back_idle :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    resync_with_daemon(
        t,
        "daemon-resync-run",
        proc(t: ^testing.T, d: ^Daemon) {
            session := pump_test_session('3')
            daemon_test_session_create(t, d, session)

            testing.expect_value(t, broadcast(d, resync_config(session, 1, "m1")), Pump_Error.None)
            testing.expect_value(t, broadcast(d, pump_run_started(session)), Pump_Error.None)

            // The log says a run began and never ended. No engine state backs it, so it is
            // a run whose daemon is gone — the state a restart used to report as `running`
            // forever. Activity comes from the engine, so the cut reports idle.
            cut, rerr := resync_build(d, {session_id = session}, context.temp_allocator)
            testing.expect_value(t, rerr, Resync_Error.None)
            _, is_idle := cut.item.activity.state.(wire.Activity_State_Idle)
            testing.expect(t, is_idle, "a run the engine does not track is not activity")
            testing.expect(t, cut.item.activity.config == nil, "an idle activity hoists no config")
            testing.expect(t, cut.active == nil, "an untracked run has no draft to report")

            // The projection still records it, because the recovery sweep is its only reader.
            snapshot, found, serr := store.session_snapshot(d.store, session, context.temp_allocator)
            testing.expect_value(t, serr, nil)
            testing.expect(t, found, "the session has a registry row")

            open, running := snapshot.open_run.?
            testing.expect(t, running, "a run with no terminal stays open in the projection")
            testing.expect_value(t, open.run_id, wire.Run_Id(1))

            testing.expect_value(t, broadcast(d, resync_run_done(session, 1)), Pump_Error.None)

            closed, _, cerr := store.session_snapshot(d.store, session, context.temp_allocator)
            testing.expect_value(t, cerr, nil)
            testing.expect(t, closed.open_run == nil, "the run's terminal closes the projection")
        },
    )
}

@(test)
test_daemon_resync_of_an_undeclared_config_is_refused :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    resync_with_daemon(
        t,
        "daemon-resync-unknown-config",
        proc(t: ^testing.T, d: ^Daemon) {
            session := pump_test_session('4')
            daemon_test_session_create(t, d, session)

            // A committed message under a revision no `config.changed` announced cannot be
            // resolved, and an unresolvable cut is our own log's fault, not a peer's.
            resync_append_corrupt_fixture(t, d, resync_assistant(session, 1, 7))

            _, err := resync_build_quiet(t, d, {session_id = session})
            testing.expect_value(t, err, Resync_Error.Corrupt_Log)
        },
    )
}

@(test)
test_daemon_resync_of_a_conflicting_config_revision_is_rejected_at_write :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    resync_with_daemon(
        t,
        "daemon-resync-conflicting-config",
        proc(t: ^testing.T, d: ^Daemon) {
            session := pump_test_session('5')
            daemon_test_session_create(t, d, session)
            testing.expect_value(t, broadcast(d, resync_config(session, 1, "m1")), Pump_Error.None)

            // A revision is minted once; re-announcing it with different settings is drift the
            // config projection's primary key refuses at append, not a read-time fold.
            resync_expect_write_rejected(t, d, resync_config(session, 1, "m2"))
        },
    )
}

@(test)
test_daemon_resync_of_a_damaged_message_payload_is_refused :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    resync_with_daemon(
        t,
        "daemon-resync-zero-id",
        proc(t: ^testing.T, d: ^Daemon) {
            session := pump_test_session('6')
            daemon_test_session_create(t, d, session)

            // Id 0 is never minted; the daemon could never emit this, so it is written as
            // on-disk damage. The projection read validates each payload and refuses it.
            resync_append_corrupt_fixture(t, d, resync_user(session, 1))
            resync_damage_payload(t, d, session, 1, resync_user(session, 0))

            _, err := resync_build_quiet(t, d, {session_id = session})
            testing.expect_value(t, err, Resync_Error.Store_Failed)
        },
    )
}

@(test)
test_daemon_resync_of_a_lagging_message_mark_is_refused :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    resync_with_daemon(
        t,
        "daemon-resync-lagging-mark",
        proc(t: ^testing.T, d: ^Daemon) {
            session := pump_test_session('a')
            daemon_test_session_create(t, d, session)

            // The fixture logs the row without the mark the pump raises in the same transaction,
            // so the boundary the cut would report sits below an id the log already committed.
            resync_append_corrupt_fixture(t, d, resync_user(session, 1))

            _, err := resync_build_quiet(t, d, {session_id = session})
            testing.expect_value(t, err, Resync_Error.Corrupt_Log)
        },
    )
}

@(test)
test_daemon_open_run_survives_a_mismatched_terminal :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    resync_with_daemon(
        t,
        "daemon-resync-run-mismatch",
        proc(t: ^testing.T, d: ^Daemon) {
            session := pump_test_session('8')
            daemon_test_session_create(t, d, session)

            testing.expect_value(t, broadcast(d, resync_config(session, 1, "m1")), Pump_Error.None)
            testing.expect_value(t, broadcast(d, resync_run_started(session, 1, 10)), Pump_Error.None)

            // A run canceled while queued terminates without ever having started, so its
            // terminal must not close the run that is actually open — the recovery sweep
            // reads this projection, and closing the wrong run would strand a live one.
            testing.expect_value(t, broadcast(d, resync_run_done(session, 2)), Pump_Error.None)

            snapshot, _, serr := store.session_snapshot(d.store, session, context.temp_allocator)
            testing.expect_value(t, serr, nil)

            open, running := snapshot.open_run.?
            testing.expect(t, running, "another run's terminal leaves this one open")
            testing.expect_value(t, open.run_id, wire.Run_Id(1))
            testing.expect_value(t, open.started_at_ms, u64(10))
        },
    )
}

@(test)
test_daemon_open_run_records_a_compaction_kind :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    resync_with_daemon(
        t,
        "daemon-resync-compacting",
        proc(t: ^testing.T, d: ^Daemon) {
            session := pump_test_session('a')
            daemon_test_session_create(t, d, session)

            testing.expect_value(t, broadcast(d, resync_config(session, 1, "m1")), Pump_Error.None)
            testing.expect_value(t, broadcast(d, resync_compaction_started(session, 1, .Auto, 10)), Pump_Error.None)

            // The kind rides the projection because a recovery terminal must name the same
            // kind the start announced; a `run.done` that renamed it would not pair.
            snapshot, _, serr := store.session_snapshot(d.store, session, context.temp_allocator)
            testing.expect_value(t, serr, nil)

            open, running := snapshot.open_run.?
            testing.expect(t, running, "an open compaction run is recorded")
            testing.expect_value(t, open.run_id, wire.Run_Id(1))
            testing.expect_value(t, open.kind, wire.Run_Kind.Compaction)
            testing.expect_value(t, open.started_at_ms, u64(10))

            // Nothing the engine tracks, so the cut is idle and carries no config page.
            cut, err := resync_build(d, {session_id = session}, context.temp_allocator)
            testing.expect_value(t, err, Resync_Error.None)
            _, is_idle := cut.item.activity.state.(wire.Activity_State_Idle)
            testing.expect(t, is_idle, "a logged compaction run is not live activity")
            testing.expect_value(t, len(cut.configs), 0)
            testing.expect_value(t, wire.session_resync_result_validate(cut), wire.Validation_Error.None)
        },
    )
}

@(test)
test_daemon_resync_closes_a_compaction_run_before_the_cut :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    resync_with_daemon(t, "daemon-resync-compacting-closed", proc(t: ^testing.T, d: ^Daemon) {
        session := pump_test_session('b')
        daemon_test_session_create(t, d, session)

        testing.expect_value(t, broadcast(d, resync_config(session, 1, "m1")), Pump_Error.None)
        testing.expect_value(t, broadcast(d, resync_compaction_started(session, 1, .Manual, 10)), Pump_Error.None)
        testing.expect_value(t, broadcast(d, resync_compaction_done(session, 1)), Pump_Error.None)

        cut, err := resync_build(d, {session_id = session}, context.temp_allocator)
        testing.expect_value(t, err, Resync_Error.None)

        _, is_idle := cut.item.activity.state.(wire.Activity_State_Idle)
        testing.expect(t, is_idle, "the run's terminal closes it, same as a closed turn")
        testing.expect(t, cut.item.activity.config == nil, "an idle activity hoists no config")
    })
}

// A run's `reason` is present exactly for a compaction run. The recovery marker no longer
// stores it, so the store keeps no second copy to guard: `run_started_data_validate` owns
// the invariant, and `broadcast` asserts on it. `wire` covers both directions.

@(test)
test_daemon_resync_ignores_a_terminal_with_no_open_run :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    resync_with_daemon(
        t,
        "daemon-resync-done-without-open-run",
        proc(t: ^testing.T, d: ^Daemon) {
            session := pump_test_session('e')
            daemon_test_session_create(t, d, session)

            // No run.started ever preceded this terminal; the fold has nothing to close.
            testing.expect_value(t, broadcast(d, resync_run_done(session, 1)), Pump_Error.None)

            cut, err := resync_build(d, {session_id = session}, context.temp_allocator)
            testing.expect_value(t, err, Resync_Error.None)

            _, is_idle := cut.item.activity.state.(wire.Activity_State_Idle)
            testing.expect(t, is_idle, "a terminal with no open run leaves activity idle")
        },
    )
}

@(test)
test_daemon_resync_of_a_config_only_log_has_no_boundary :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    resync_with_daemon(
        t,
        "daemon-resync-config-only",
        proc(t: ^testing.T, d: ^Daemon) {
            session := pump_test_session('f')
            daemon_test_session_create(t, d, session)

            // Nothing ever finalized a message id, so the boundary stays null even
            // though the session is known and the log is not empty.
            testing.expect_value(t, broadcast(d, resync_config(session, 1, "m1")), Pump_Error.None)

            cut, err := resync_build(d, {session_id = session}, context.temp_allocator)
            testing.expect_value(t, err, Resync_Error.None)

            testing.expect(t, cut.highest_finalized_message_id == nil, "no message has ever finalized")
            testing.expect_value(t, len(cut.messages), 0)
            testing.expect(t, !cut.has_more, "an empty transcript has no more behind it")
            testing.expect_value(t, wire.session_resync_result_validate(cut), wire.Validation_Error.None)
        },
    )
}

@(test)
test_daemon_resync_pages_a_transcript_past_one_page :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    resync_with_daemon(
        t,
        "daemon-resync-chunks",
        proc(t: ^testing.T, d: ^Daemon) {
            session := pump_test_session('c')
            daemon_test_session_create(t, d, session)

            // One row past a page, so the tail page is full and `has_more` is set.
            rows := wire.LIMITS.default_page_size + 1
            for id in 1 ..= rows {
                testing.expect_value(t, broadcast(d, resync_user(session, wire.Message_Id(id))), Pump_Error.None)
            }

            cut, err := resync_build(d, {session_id = session}, context.temp_allocator)
            testing.expect_value(t, err, Resync_Error.None)
            testing.expect_value(t, cut.base_seq, wire.Seq(rows))
            testing.expect_value(t, cut.item.session.message_count, u64(rows))
            testing.expect_value(t, len(cut.messages), wire.LIMITS.default_page_size)
            testing.expect(t, cut.has_more, "the page is the tail of a longer transcript")

            highest, finalized := cut.highest_finalized_message_id.?
            testing.expect(t, finalized, "the whole log folded")
            testing.expect_value(t, highest, wire.Message_Id(rows))
        },
    )
}

// --- end to end: the cut over a real connection, into the replica ---------------

// Observations for the round-trip test, reached through the driver's `user_data`.
Resync_Obs :: struct {
    // The active testing context, so the response check can assert in the callback.
    t:         ^testing.T,

    // Session the request resyncs.
    session:   wire.Session_Id,

    // The response was delivered and checked.
    responded: bool,

    // The delivered snapshot installed into a fresh replica.
    installed: bool,

    // Committed messages the replica retained from the snapshot.
    messages:  int,

    // Terminal callback fired.
    done:      bool,
}

resync_on_ready :: proc(c: ^client.Client, _: wire.Initialize_Result) {
    o := (^Resync_Obs)(c.user_data)
    client.client_send_request(
        c,
        .Session_Resync,
        wire.Session_Resync_Params{session_id = o.session},
        resync_on_response,
    )
}

// The driver reclaims its decode arena when this returns, so the snapshot is consumed
// here, inside the callback that owns it.
resync_on_response :: proc(c: ^client.Client, outcome: client.Request_Outcome, _: rawptr) {
    o := (^Resync_Obs)(c.user_data)
    o.responded = true
    answered, has_response := outcome.(client.Request_Response)
    if !testing.expect(o.t, has_response, "session.resync should receive a response") {
        client.client_close(c)
        return
    }

    resp := answered.response

    ok, is_ok := resp.(wire.Response_Ok)
    if !testing.expect(o.t, is_ok, "session.resync should answer with a result") {
        client.client_close(c)
        return
    }

    cut, is_cut := ok.result.(wire.Session_Resync_Result)
    if !testing.expect(o.t, is_cut, "the result should decode as a resync snapshot") {
        client.client_close(c)
        return
    }

    testing.expect_value(o.t, cut.base_seq, wire.Seq(3))

    r: client.Session_Replica
    client.replica_init(&r, context.allocator, o.session)
    defer client.replica_destroy(&r)

    ierr := client.replica_install_snapshot(&r, cut)
    testing.expect_value(o.t, ierr, client.Replica_Error.None)
    o.installed = ierr == .None
    o.messages = len(r.messages)

    client.client_close(c)
}

resync_on_close :: proc(c: ^client.Client, _: client.Close_Code) {
    o := (^Resync_Obs)(c.user_data)
    o.done = true
}

resync_on_error :: proc(c: ^client.Client, _: client.Protocol_Error) {
    o := (^Resync_Obs)(c.user_data)
    o.done = true
}

@(test)
test_daemon_resync_snapshot_installs_in_the_replica :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    path := testsupport.sqlite_db_path(t, "daemon-resync-e2e")
    defer testsupport.sqlite_db_remove(path)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    d: Daemon
    testing.expect_value(t, start(&d, loop, {host = "127.0.0.1", port = 0, db_path = path}), Error.None)

    session := pump_test_session('5')
    daemon_test_session_create(t, &d, session)
    testing.expect_value(t, broadcast(&d, resync_config(session, 1, "m1")), Pump_Error.None)
    testing.expect_value(t, broadcast(&d, resync_user(session, 1)), Pump_Error.None)
    testing.expect_value(t, broadcast(&d, resync_assistant(session, 2, 1)), Pump_Error.None)

    obs := Resync_Obs {
        t       = t,
        session = session,
    }
    c: client.Client
    transport, terr := client.ws_create(
        loop,
        {host = "127.0.0.1", port = bound_port(&d), path = "/ws"},
        context.temp_allocator,
    )
    testing.expect_value(t, terr, ws.Client_Error.None)

    cerr := client.client_open(
        &c,
        transport,
        "yuke-test",
        "0.1.0",
        client.Client_Callbacks{on_ready = resync_on_ready, on_close = resync_on_close, on_error = resync_on_error},
        &obs,
        context.temp_allocator,
    )
    testing.expect_value(t, cerr, client.Protocol_Error.None)
    testing.expect(t, pump_tick_until(&obs.done), "the exchange should finish and the client close")

    testing.expect(t, obs.responded, "the daemon should have answered the request")
    testing.expect(t, obs.installed, "the snapshot should install into a fresh replica")
    testing.expect_value(t, obs.messages, 2)

    client.client_destroy(&c)
    test_teardown(&d)
}

// --- end to end: a corrupt row is answered, not fatal ---------------------------

// Observations for the corruption round trip, reached through `user_data`.
Corrupt_Obs :: struct {
    // The active testing context, so the response checks can assert in the callback.
    t:           ^testing.T,

    // Session the request resyncs.
    session:     wire.Session_Id,

    // Error code the resync answered with.
    resync_code: wire.Error_Code,

    // The resync answer was an error response.
    refused:     bool,

    // A later request on the same connection was answered with a result.
    survived:    bool,

    // Terminal callback fired.
    done:        bool,
}

corrupt_on_ready :: proc(c: ^client.Client, _: wire.Initialize_Result) {
    o := (^Corrupt_Obs)(c.user_data)
    client.client_send_request(
        c,
        .Session_Resync,
        wire.Session_Resync_Params{session_id = o.session},
        corrupt_on_resync,
    )
}

corrupt_on_resync :: proc(c: ^client.Client, outcome: client.Request_Outcome, _: rawptr) {
    o := (^Corrupt_Obs)(c.user_data)
    answered, has_response := outcome.(client.Request_Response)
    if !has_response {
        return
    }

    resp := answered.response

    if bad, is_error := resp.(wire.Response_Error); is_error {
        o.refused = true
        o.resync_code = bad.error.code
    }

    // The connection outlives the fault: a log we cannot fold is not a protocol violation, so
    // the next request must still be answered. Valid params — a zero-value scope/population
    // emits an undecodable frame that would close the connection for the wrong reason.
    client.client_send_request(
        c,
        .Session_List,
        wire.Session_List_Params {
            scope = wire.Session_Scope_All{},
            population = wire.Session_Population_Top_Level{},
            view = .Active_Recent,
        },
        corrupt_on_list,
    )
}

corrupt_on_list :: proc(c: ^client.Client, outcome: client.Request_Outcome, _: rawptr) {
    o := (^Corrupt_Obs)(c.user_data)
    answered, has_response := outcome.(client.Request_Response)
    if !has_response {
        return
    }

    resp := answered.response
    _, ok := resp.(wire.Response_Ok)
    o.survived = ok
    client.client_close(c)
}

corrupt_on_close :: proc(c: ^client.Client, _: client.Close_Code) {
    o := (^Corrupt_Obs)(c.user_data)
    o.done = true
}

corrupt_on_error :: proc(c: ^client.Client, _: client.Protocol_Error) {
    o := (^Corrupt_Obs)(c.user_data)
    o.done = true
}

@(test)
test_daemon_resync_of_a_corrupt_row_answers_internal :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    path := testsupport.sqlite_db_path(t, "daemon-resync-corrupt")
    defer testsupport.sqlite_db_remove(path)

    // The unfoldable row is logged as an error, which the runner would otherwise count
    // as a test failure; the assertions below are the check.
    saved_logger := context.logger
    quiet_logger: testsupport.Assert_Only_Logger
    context.logger = testsupport.assert_only_logger(&quiet_logger, saved_logger)
    defer context.logger = saved_logger

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    d: Daemon
    testing.expect_value(t, start(&d, loop, {host = "127.0.0.1", port = 0, db_path = path}), Error.None)

    session := pump_test_session('0')
    daemon_test_session_create(t, &d, session)

    // The store validates only the class and a non-empty payload, so a payload the codec
    // rejects reaches the log the way real corruption would; only the stored row is corrupt.
    corrupt := wire.Message_Committed_Data {
        session_id = session,
        seq = 1,
        message = wire.User_Message{id = 1, input_id = 1, time = {created_at_ms = 1}},
    }
    testing.expect_value(t, store.event_append(d.store, session, 1, corrupt, "{}", {}), nil)

    obs := Corrupt_Obs {
        t       = t,
        session = session,
    }
    c: client.Client
    transport, terr := client.ws_create(
        loop,
        {host = "127.0.0.1", port = bound_port(&d), path = "/ws"},
        context.temp_allocator,
    )
    testing.expect_value(t, terr, ws.Client_Error.None)

    cerr := client.client_open(
        &c,
        transport,
        "yuke-test",
        "0.1.0",
        client.Client_Callbacks{on_ready = corrupt_on_ready, on_close = corrupt_on_close, on_error = corrupt_on_error},
        &obs,
        context.temp_allocator,
    )
    testing.expect_value(t, cerr, client.Protocol_Error.None)
    testing.expect(t, pump_tick_until(&obs.done), "the exchange should finish and the client close")

    testing.expect(t, obs.refused, "an unfoldable log should answer with an error response")
    testing.expect_value(t, obs.resync_code, wire.Error_Code.Internal)
    testing.expect(t, obs.survived, "the connection should outlive the fault")

    client.client_destroy(&c)
    test_teardown(&d)
}
