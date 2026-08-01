package daemon

import "core:log"
import "core:nbio"
import "core:testing"

import "libs:testsupport"
import ws "libs:websocket"
import client "src:client"
import store "src:daemon/store"
import wire "src:wire"

// --- session.resync cut tests --------------------------------------------------
//
// The cut is folded from the durable log alone, so each fixture seeds the log through
// `broadcast` — the pump entry point the session engine will use — and then
// builds the cut the handler would send. One test carries a cut over a real
// connection and installs it into a `src/client` replica, which is the consumer whose
// invariants the fold exists to satisfy.

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

// Put a codec-valid but semantically impossible historical row directly on the
// log. Corruption fixtures bypass the pump so they do not model impossible daemon
// output as an accepted internal operation.
resync_append_corrupt_fixture :: proc(t: ^testing.T, d: ^Daemon, data: wire.Broadcast_Data) {
    assert(d != nil, "a corruption fixture needs daemon state")
    assert(d.store != nil, "a corruption fixture needs an open store")

    name, typed := wire.broadcast_data_name(data)
    assert(typed, "a corruption fixture uses a typed payload")
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

    testing.expect_value(t, store.event_append(d.store, session, seq, name, wire.to_string(&e), {}), nil)
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
test_daemon_resync_without_a_store_is_unknown :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    d: Daemon
    testing.expect_value(t, start(&d, loop, {host = "127.0.0.1", port = 0}), Error.None)
    testing.expect(t, d.store == nil, "no database configured means no store")

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
test_daemon_resync_reports_the_open_run :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    resync_with_daemon(
        t,
        "daemon-resync-run",
        proc(t: ^testing.T, d: ^Daemon) {
            session := pump_test_session('3')
            daemon_test_session_create(t, d, session)

            testing.expect_value(t, broadcast(d, resync_config(session, 1, "m1")), Pump_Error.None)
            testing.expect_value(t, broadcast(d, pump_run_started(session)), Pump_Error.None)

            running, rerr := resync_build(d, {session_id = session}, context.temp_allocator)
            testing.expect_value(t, rerr, Resync_Error.None)

            state, is_running := running.item.activity.state.(wire.Activity_State_Running)
            testing.expect(t, is_running, "a run with no terminal is still open at the cut")
            testing.expect_value(t, state.run_id, wire.Run_Id(1))

            // A running activity hoists the run's config, which must be one the log named.
            cfg, hoisted := running.item.activity.config.?
            testing.expect(t, hoisted, "a running activity carries its config")
            testing.expect_value(t, cfg.config_rev, wire.Config_Rev(1))
            testing.expect_value(t, len(running.configs), 1)

            testing.expect_value(t, broadcast(d, resync_run_done(session, 1)), Pump_Error.None)

            idle, ierr := resync_build(d, {session_id = session}, context.temp_allocator)
            testing.expect_value(t, ierr, Resync_Error.None)
            _, is_idle := idle.item.activity.state.(wire.Activity_State_Idle)
            testing.expect(t, is_idle, "the run's terminal closes it")
            testing.expect(t, idle.item.activity.config == nil, "an idle activity hoists no config")
        },
    )
}

@(test)
test_daemon_resync_of_an_undeclared_config_is_refused :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    // The unresolvable revision is logged as an error, which the runner would
    // otherwise count as a test failure; the assertion below is the check.
    context.logger = log.nil_logger()

    resync_with_daemon(
        t,
        "daemon-resync-unknown-config",
        proc(t: ^testing.T, d: ^Daemon) {
            session := pump_test_session('4')
            daemon_test_session_create(t, d, session)

            // A run under a revision no `config.changed` announced cannot be resolved,
            // and an unresolvable cut is our own log's fault, not a peer's.
            resync_append_corrupt_fixture(t, d, pump_run_started(session))

            _, err := resync_build(d, {session_id = session}, context.temp_allocator)
            testing.expect_value(t, err, Resync_Error.Corrupt_Log)
        },
    )
}

@(test)
test_daemon_resync_of_a_conflicting_config_revision_is_refused :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    context.logger = log.nil_logger()

    resync_with_daemon(t, "daemon-resync-conflicting-config", proc(t: ^testing.T, d: ^Daemon) {
        session := pump_test_session('5')
        daemon_test_session_create(t, d, session)
        testing.expect_value(t, broadcast(d, resync_config(session, 1, "m1")), Pump_Error.None)
        resync_append_corrupt_fixture(t, d, resync_config(session, 1, "m2"))

        _, err := resync_build(d, {session_id = session}, context.temp_allocator)
        testing.expect_value(t, err, Resync_Error.Corrupt_Log)
    })
}

@(test)
test_daemon_resync_of_a_zero_message_id_is_refused :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    context.logger = log.nil_logger()

    resync_with_daemon(
        t,
        "daemon-resync-zero-id",
        proc(t: ^testing.T, d: ^Daemon) {
            session := pump_test_session('6')
            daemon_test_session_create(t, d, session)

            // Id 0 is never minted, and a cut carrying it would pass our wire validator:
            // the fold refuses the damaged historical row before it reaches a replica.
            resync_append_corrupt_fixture(t, d, resync_user(session, 0))

            _, err := resync_build(d, {session_id = session}, context.temp_allocator)
            testing.expect_value(t, err, Resync_Error.Corrupt_Log)
        },
    )
}

@(test)
test_daemon_resync_of_a_reused_truncated_message_id_is_refused :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    context.logger = log.nil_logger()

    resync_with_daemon(t, "daemon-resync-reused-id", proc(t: ^testing.T, d: ^Daemon) {
        session := pump_test_session('7')
        daemon_test_session_create(t, d, session)

        testing.expect_value(t, broadcast(d, resync_user(session, 1)), Pump_Error.None)
        testing.expect_value(t, broadcast(d, resync_user(session, 2)), Pump_Error.None)
        testing.expect_value(t, broadcast(d, resync_truncated(session, 2)), Pump_Error.None)
        resync_append_corrupt_fixture(t, d, resync_user(session, 2))

        _, err := resync_build(d, {session_id = session}, context.temp_allocator)
        testing.expect_value(t, err, Resync_Error.Corrupt_Log)
    })
}

@(test)
test_daemon_resync_of_a_lagging_message_mark_is_refused :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    context.logger = log.nil_logger()

    resync_with_daemon(
        t,
        "daemon-resync-lagging-mark",
        proc(t: ^testing.T, d: ^Daemon) {
            session := pump_test_session('a')
            daemon_test_session_create(t, d, session)

            // The fixture logs the row without the mark the pump raises in the same
            // transaction, which is how a damaged `session_meta` reads: the boundary the cut
            // would report sits below an id the log already committed.
            resync_append_corrupt_fixture(t, d, resync_user(session, 1))

            _, err := resync_build(d, {session_id = session}, context.temp_allocator)
            testing.expect_value(t, err, Resync_Error.Corrupt_Log)
        },
    )
}

@(test)
test_daemon_resync_keeps_a_run_open_past_a_mismatched_terminal :: proc(t: ^testing.T) {
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
            // terminal must not close the run that is actually open.
            testing.expect_value(t, broadcast(d, resync_run_done(session, 2)), Pump_Error.None)

            cut, err := resync_build(d, {session_id = session}, context.temp_allocator)
            testing.expect_value(t, err, Resync_Error.None)

            state, running := cut.item.activity.state.(wire.Activity_State_Running)
            testing.expect(t, running, "another run's terminal leaves this one open")
            testing.expect_value(t, state.run_id, wire.Run_Id(1))
        },
    )
}

@(test)
test_daemon_resync_refuses_overlapping_runs :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    context.logger = log.nil_logger()

    resync_with_daemon(t, "daemon-resync-run-replace", proc(t: ^testing.T, d: ^Daemon) {
        session := pump_test_session('9')
        daemon_test_session_create(t, d, session)

        testing.expect_value(t, broadcast(d, resync_config(session, 1, "m1")), Pump_Error.None)
        testing.expect_value(t, broadcast(d, resync_run_started(session, 1, 10)), Pump_Error.None)
        resync_append_corrupt_fixture(t, d, resync_run_started(session, 2, 20))

        _, err := resync_build(d, {session_id = session}, context.temp_allocator)
        testing.expect_value(t, err, Resync_Error.Corrupt_Log)
    })
}

@(test)
test_daemon_resync_folds_a_log_past_one_chunk :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    resync_with_daemon(
        t,
        "daemon-resync-chunks",
        proc(t: ^testing.T, d: ^Daemon) {
            session := pump_test_session('c')
            daemon_test_session_create(t, d, session)

            // One row past the read chunk, so the fold's continuation is exercised.
            rows := RESYNC_CHUNK + 1
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
resync_on_response :: proc(c: ^client.Client, resp: wire.Response, _: rawptr) {
    o := (^Resync_Obs)(c.user_data)
    o.responded = true

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

    outcome, ierr := client.replica_install_snapshot(&r, cut)
    testing.expect_value(o.t, ierr, client.Replica_Error.None)
    testing.expect_value(o.t, outcome, client.Install_Outcome.Live)
    o.installed = ierr == .None
    o.messages = len(r.messages)

    client.client_close(c)
}

resync_on_close :: proc(c: ^client.Client, _: ws.Close_Code) {
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
    cerr := client.client_open(
        &c,
        loop,
        {host = "127.0.0.1", port = bound_port(&d), path = "/ws"},
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

corrupt_on_resync :: proc(c: ^client.Client, resp: wire.Response, _: rawptr) {
    o := (^Corrupt_Obs)(c.user_data)

    if bad, is_error := resp.(wire.Response_Error); is_error {
        o.refused = true
        o.resync_code = bad.error.code
    }

    // The connection outlives the fault: a log we cannot fold is not a protocol
    // violation, so the next request must still be answered.
    client.client_send_request(c, .Session_List, wire.Session_List_Params{}, corrupt_on_list)
}

corrupt_on_list :: proc(c: ^client.Client, resp: wire.Response, _: rawptr) {
    o := (^Corrupt_Obs)(c.user_data)
    _, ok := resp.(wire.Response_Ok)
    o.survived = ok
    client.client_close(c)
}

corrupt_on_close :: proc(c: ^client.Client, _: ws.Close_Code) {
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
    context.logger = log.nil_logger()

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    d: Daemon
    testing.expect_value(t, start(&d, loop, {host = "127.0.0.1", port = 0, db_path = path}), Error.None)

    session := pump_test_session('0')
    daemon_test_session_create(t, &d, session)

    // The store validates only the class and a non-empty payload, so a payload the
    // codec rejects reaches the log the way real corruption would.
    testing.expect_value(t, store.event_append(d.store, session, 1, .Message_Committed, "{}", {}), nil)

    obs := Corrupt_Obs {
        t       = t,
        session = session,
    }
    c: client.Client
    cerr := client.client_open(
        &c,
        loop,
        {host = "127.0.0.1", port = bound_port(&d), path = "/ws"},
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
