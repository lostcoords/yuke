package daemon

import "core:fmt"
import "core:log"
import "core:nbio"
import "core:net"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

import "libs:bindings/sqlite"
import "libs:testsupport"
import ws "libs:websocket"
import client "src:client"
import store "src:daemon/store"
import wire "src:wire"

// --- Pump, fan-out, and subscription tests ------------------------------------
//
// These drive real `src/client` connections against a daemon on one shared loop, then
// call `broadcast` from the test body — the entry point the session engine will
// use — and observe what each connection received. Durable cases run against a real
// on-disk store so persistence and delivery are exercised together.

// A session id is 16 lowercase-hex characters on the wire; repeat one for a fixture.
pump_test_session :: proc(c: u8) -> wire.Session_Id {
    sid: [16]u8
    for i in 0 ..< 16 {
        sid[i] = c
    }

    return wire.Session_Id(sid)
}

// Observations recorded by one subscribing client, reached through `user_data`.
Pump_Obs :: struct {
    // Sessions to subscribe to at Ready; empty sends no `subscription.set`.
    sessions:   []wire.Session_Id,

    // The connection is Ready and its subscription set (if any) is installed.
    armed:      bool,

    // The `subscription.set` response was an error rather than a result.
    sub_failed: bool,

    // Broadcast names delivered, in arrival order.
    names:      [dynamic]wire.Broadcast_Name,

    // Durable seq carried by each delivered broadcast; 0 for an unsequenced one.
    seqs:       [dynamic]wire.Seq,

    // Terminal driver error, if any.
    err:        client.Protocol_Error,

    // Terminal callback fired.
    done:       bool,
}

pump_on_ready :: proc(c: ^client.Client, _: wire.Initialize_Result) {
    o := (^Pump_Obs)(c.user_data)

    if len(o.sessions) == 0 {
        o.armed = true
        return
    }

    client.client_send_request(c, .Subscription_Set, wire.Subscription_Set_Params{sessions = o.sessions}, pump_on_sub)
}

pump_on_sub :: proc(c: ^client.Client, resp: wire.Response, _: rawptr) {
    o := (^Pump_Obs)(c.user_data)

    if _, ok := resp.(wire.Response_Ok); !ok {
        o.sub_failed = true
    }

    o.armed = true
}

pump_on_broadcast :: proc(c: ^client.Client, bc: wire.Notification) {
    o := (^Pump_Obs)(c.user_data)
    append(&o.names, bc.method)

    seq, sequenced := wire.broadcast_data_seq(bc.params).?
    append(&o.seqs, sequenced ? seq : 0)
}

pump_on_close :: proc(c: ^client.Client, _: ws.Close_Code) {
    o := (^Pump_Obs)(c.user_data)
    o.done = true
}

pump_on_error :: proc(c: ^client.Client, err: client.Protocol_Error) {
    o := (^Pump_Obs)(c.user_data)
    o.err = err
    o.done = true
}

pump_callbacks :: proc() -> client.Client_Callbacks {
    return client.Client_Callbacks {
        on_ready = pump_on_ready,
        on_broadcast = pump_on_broadcast,
        on_close = pump_on_close,
        on_error = pump_on_error,
    }
}

// Prepare an observation whose collections live in the temp arena.
pump_obs_init :: proc(o: ^Pump_Obs, sessions: []wire.Session_Id) {
    o.sessions = sessions
    o.names = make([dynamic]wire.Broadcast_Name, context.temp_allocator)
    o.seqs = make([dynamic]wire.Seq, context.temp_allocator)
}

// Open one driver against the daemon and run the loop until it is Ready with its
// subscription set installed.
pump_client_arm :: proc(t: ^testing.T, c: ^client.Client, loop: ^nbio.Event_Loop, port: int, o: ^Pump_Obs) {
    cerr := client.client_open(
        c,
        loop,
        {host = "127.0.0.1", port = port, path = "/ws"},
        "yuke-test",
        "0.1.0",
        pump_callbacks(),
        o,
        context.temp_allocator,
    )
    testing.expect_value(t, cerr, client.Protocol_Error.None)
    testing.expect(t, pump_tick_until(&o.armed), "the client should reach Ready and install its subscriptions")
}

// Drive the loop until `flag` is set or the tick budget runs out.
pump_tick_until :: proc(flag: ^bool, ticks := 600) -> bool {
    for _ in 0 ..< ticks {
        if flag^ {
            return true
        }

        nbio.tick(time.Millisecond)
    }

    return flag^
}

// Drive the loop for a fixed span, so an absent delivery has every chance to arrive
// before a test concludes it was gated out.
pump_settle :: proc(ticks := 120) {
    for _ in 0 ..< ticks {
        nbio.tick(time.Millisecond)
    }
}

// A durable payload whose validation is the session id alone, so the fixtures stay
// about sequencing rather than transcript shape. The pump stamps `seq`.
pump_run_started :: proc(session: wire.Session_Id) -> wire.Broadcast_Data {
    return wire.Run_Started_Data{session_id = session, run_id = 1, kind = .Turn, config_rev = 1, started_at_ms = 1}
}

// A live payload validated by its session id and a short agent name.
pump_message_started :: proc(session: wire.Session_Id) -> wire.Broadcast_Data {
    return wire.Message_Started_Data {
        session_id = session,
        message_id = 1,
        run_id = 1,
        config_rev = 1,
        agent = "main",
        created_at_ms = 1,
    }
}

@(test)
test_daemon_subscription_set_replaces_the_prior_set :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    d: Daemon
    derr := start(&d, loop, {host = "127.0.0.1", port = 0})
    testing.expect_value(t, derr, Error.None)

    dropped := pump_test_session('a')
    daemon_test_session_create(t, &d, dropped)
    kept := pump_test_session('b')
    daemon_test_session_create(t, &d, kept)

    obs: Pump_Obs
    pump_obs_init(&obs, {dropped})
    c: client.Client
    pump_client_arm(t, &c, loop, bound_port(&d), &obs)
    testing.expect(t, !obs.sub_failed, "subscription.set should answer with a result")

    // The replacement drops `dropped` and adds `kept`; only the second set is live.
    obs.armed = false
    obs.sessions = {kept}
    client.client_send_request(
        &c,
        .Subscription_Set,
        wire.Subscription_Set_Params{sessions = obs.sessions},
        pump_on_sub,
    )
    testing.expect(t, pump_tick_until(&obs.armed), "the replacement should be answered")

    testing.expect_value(t, broadcast(&d, pump_message_started(dropped)), Pump_Error.None)
    testing.expect_value(t, broadcast(&d, pump_message_started(kept)), Pump_Error.None)
    pump_settle()

    if testing.expect_value(t, len(obs.names), 1) {
        testing.expect_value(t, obs.names[0], wire.Broadcast_Name.Message_Started)
    }

    client.client_close(&c)
    testing.expect(t, pump_tick_until(&obs.done), "the client should close cleanly")
    client.client_destroy(&c)
    test_teardown(&d)
}

@(test)
test_daemon_durable_broadcast_is_persisted_and_delivered :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    path := testsupport.sqlite_db_path(t, "daemon-pump-durable")
    defer testsupport.sqlite_db_remove(path)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    d: Daemon
    derr := start(&d, loop, {host = "127.0.0.1", port = 0, db_path = path})
    testing.expect_value(t, derr, Error.None)
    testing.expect(t, d.store != nil, "a configured database opens the store at start")

    session := pump_test_session('c')
    daemon_test_session_create(t, &d, session)
    port := bound_port(&d)

    subscribed: Pump_Obs
    pump_obs_init(&subscribed, {session})
    sub_client: client.Client
    pump_client_arm(t, &sub_client, loop, port, &subscribed)

    idle: Pump_Obs
    pump_obs_init(&idle, nil)
    idle_client: client.Client
    pump_client_arm(t, &idle_client, loop, port, &idle)

    testing.expect_value(t, broadcast(&d, pump_run_started(session)), Pump_Error.None)
    pump_settle()

    if testing.expect_value(t, len(subscribed.names), 1) {
        testing.expect_value(t, subscribed.names[0], wire.Broadcast_Name.Run_Started)
        // The pump is the seq authority: the caller emitted without one.
        testing.expect_value(t, subscribed.seqs[0], wire.Seq(1))
    }

    testing.expect_value(t, len(idle.names), 0)

    rows, rerr := store.events_after(d.store, session, 0, 8, context.temp_allocator)
    testing.expect_value(t, rerr, nil)

    if testing.expect_value(t, len(rows), 1) {
        testing.expect_value(t, rows[0].seq, wire.Seq(1))
        testing.expect_value(t, rows[0].name, wire.Broadcast_Name.Run_Started)
    }

    client.client_close(&sub_client)
    client.client_close(&idle_client)
    testing.expect(t, pump_tick_until(&subscribed.done), "the subscribed client should close cleanly")
    testing.expect(t, pump_tick_until(&idle.done), "the idle client should close cleanly")
    client.client_destroy(&sub_client)
    client.client_destroy(&idle_client)
    test_teardown(&d)
}

@(test)
test_daemon_durable_seq_recovers_across_restart :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    path := testsupport.sqlite_db_path(t, "daemon-pump-restart")
    defer testsupport.sqlite_db_remove(path)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    session := pump_test_session('d')

    first: Daemon
    testing.expect_value(t, start(&first, loop, {host = "127.0.0.1", port = 0, db_path = path}), Error.None)
    daemon_test_session_create(t, &first, session)
    testing.expect_value(t, broadcast(&first, pump_run_started(session)), Pump_Error.None)
    testing.expect_value(t, broadcast(&first, pump_run_started(session)), Pump_Error.None)
    test_teardown(&first)

    // The high-water lives in the store, so a fresh daemon continues the stream
    // instead of reissuing numbers.
    second: Daemon
    testing.expect_value(t, start(&second, loop, {host = "127.0.0.1", port = 0, db_path = path}), Error.None)
    testing.expect_value(t, broadcast(&second, pump_run_started(session)), Pump_Error.None)

    rows, rerr := store.events_after(second.store, session, 0, 8, context.temp_allocator)
    testing.expect_value(t, rerr, nil)

    if testing.expect_value(t, len(rows), 3) {
        testing.expect_value(t, rows[0].seq, wire.Seq(1))
        testing.expect_value(t, rows[1].seq, wire.Seq(2))
        testing.expect_value(t, rows[2].seq, wire.Seq(3))
    }

    test_teardown(&second)
}

@(test)
test_daemon_id_marks_recover_across_restart :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    path := testsupport.sqlite_db_path(t, "daemon-pump-marks")
    defer testsupport.sqlite_db_remove(path)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    session := pump_test_session('5')

    first: Daemon
    testing.expect_value(t, start(&first, loop, {host = "127.0.0.1", port = 0, db_path = path}), Error.None)
    daemon_test_session_create(t, &first, session)

    // Each arm carries a different family: the config rev, an assistant message's id
    // and run, a run id, then a user message's id and the input it came from.
    testing.expect_value(t, broadcast(&first, resync_config(session, 4, "m1")), Pump_Error.None)
    testing.expect_value(t, broadcast(&first, resync_assistant(session, 7, 4)), Pump_Error.None)
    testing.expect_value(t, broadcast(&first, resync_run_started(session, 5, 1)), Pump_Error.None)
    testing.expect_value(t, broadcast(&first, resync_user(session, 8)), Pump_Error.None)
    test_teardown(&first)

    // Every minting family recovers with the seq; a zero here would let the next
    // session engine reissue an id the transcript already folded.
    second: Daemon
    testing.expect_value(t, start(&second, loop, {host = "127.0.0.1", port = 0, db_path = path}), Error.None)

    hw, herr := store.high_water(second.store, session)
    testing.expect_value(t, herr, nil)
    testing.expect_value(t, hw.seq, wire.Seq(4))
    testing.expect_value(t, hw.message_id, wire.Message_Id(8))
    testing.expect_value(t, hw.run_id, wire.Run_Id(5))
    testing.expect_value(t, hw.config_rev, wire.Config_Rev(4))
    testing.expect_value(t, hw.input_id, wire.Input_Id(8))

    test_teardown(&second)
}

@(test)
test_daemon_ungated_broadcast_reaches_every_connection :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    path := testsupport.sqlite_db_path(t, "daemon-pump-ungated")
    defer testsupport.sqlite_db_remove(path)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    d: Daemon
    derr := start(&d, loop, {host = "127.0.0.1", port = 0, db_path = path})
    testing.expect_value(t, derr, Error.None)

    session := pump_test_session('e')
    daemon_test_session_create(t, &d, session)
    port := bound_port(&d)

    subscribed: Pump_Obs
    pump_obs_init(&subscribed, {pump_test_session('f')})
    sub_client: client.Client
    pump_client_arm(t, &sub_client, loop, port, &subscribed)

    idle: Pump_Obs
    pump_obs_init(&idle, nil)
    idle_client: client.Client
    pump_client_arm(t, &idle_client, loop, port, &idle)

    // `session.removed` is Ungated: it bypasses subscriptions and the log both.
    removed := wire.Session_Removed_Data {
        revision   = 1,
        session_id = session,
    }
    testing.expect_value(t, broadcast(&d, removed), Pump_Error.None)
    pump_settle()

    testing.expect_value(t, len(subscribed.names), 1)
    testing.expect_value(t, len(idle.names), 1)

    rows, rerr := store.events_after(d.store, session, 0, 8, context.temp_allocator)
    testing.expect_value(t, rerr, nil)
    testing.expect_value(t, len(rows), 0)

    client.client_close(&sub_client)
    client.client_close(&idle_client)
    testing.expect(t, pump_tick_until(&subscribed.done), "the subscribed client should close cleanly")
    testing.expect(t, pump_tick_until(&idle.done), "the idle client should close cleanly")
    client.client_destroy(&sub_client)
    client.client_destroy(&idle_client)
    test_teardown(&d)
}

@(test)
test_daemon_live_gated_broadcast_is_not_persisted :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    path := testsupport.sqlite_db_path(t, "daemon-pump-live")
    defer testsupport.sqlite_db_remove(path)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    d: Daemon
    derr := start(&d, loop, {host = "127.0.0.1", port = 0, db_path = path})
    testing.expect_value(t, derr, Error.None)

    session := pump_test_session('0')
    daemon_test_session_create(t, &d, session)

    obs: Pump_Obs
    pump_obs_init(&obs, {session})
    c: client.Client
    pump_client_arm(t, &c, loop, bound_port(&d), &obs)

    testing.expect_value(t, broadcast(&d, pump_message_started(session)), Pump_Error.None)
    pump_settle()

    if testing.expect_value(t, len(obs.names), 1) {
        testing.expect_value(t, obs.names[0], wire.Broadcast_Name.Message_Started)
        testing.expect_value(t, obs.seqs[0], wire.Seq(0))
    }

    rows, rerr := store.events_after(d.store, session, 0, 8, context.temp_allocator)
    testing.expect_value(t, rerr, nil)
    testing.expect_value(t, len(rows), 0)

    client.client_close(&c)
    testing.expect(t, pump_tick_until(&obs.done), "the client should close cleanly")
    client.client_destroy(&c)
    test_teardown(&d)
}

@(test)
test_daemon_durable_broadcast_without_a_store_is_refused :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    d: Daemon
    derr := start(&d, loop, {host = "127.0.0.1", port = 0})
    testing.expect_value(t, derr, Error.None)
    testing.expect(t, d.store == nil, "no database configured means no store")

    session := pump_test_session('1')
    daemon_test_session_create(t, &d, session)

    obs: Pump_Obs
    pump_obs_init(&obs, {session})
    c: client.Client
    pump_client_arm(t, &c, loop, bound_port(&d), &obs)

    // Nothing can be sequenced, so nothing is delivered either.
    testing.expect_value(t, broadcast(&d, pump_run_started(session)), Pump_Error.No_Store)
    pump_settle()
    testing.expect_value(t, len(obs.names), 0)

    client.client_close(&c)
    testing.expect(t, pump_tick_until(&obs.done), "the client should close cleanly")
    client.client_destroy(&c)
    test_teardown(&d)
}

@(test)
test_daemon_exhausted_sequence_is_reported :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    path := testsupport.sqlite_db_path(t, "daemon-pump-seq-exhausted")
    defer testsupport.sqlite_db_remove(path)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    context.logger = log.nil_logger()

    d: Daemon
    derr := start(&d, loop, {host = "127.0.0.1", port = 0, db_path = path})
    testing.expect_value(t, derr, Error.None)

    session := pump_test_session('e')
    daemon_test_session_create(t, &d, session)
    testing.expect_value(t, broadcast(&d, pump_run_started(session)), Pump_Error.None)
    exhaust := fmt.tprintf("UPDATE session_meta SET seq_high = %d", wire.MAX_WIRE_INTEGER)
    testing.expect_value(t, sqlite.exec(d.store.writer, exhaust), sqlite.Result.Ok)
    delete_key(&d.seq_high, session)

    testing.expect_value(t, broadcast(&d, pump_run_started(session)), Pump_Error.Sequence_Exhausted)

    rows, rerr := store.events_after(d.store, session, 0, 8, context.temp_allocator)
    testing.expect_value(t, rerr, nil)
    testing.expect_value(t, len(rows), 1)

    test_teardown(&d)
}

@(test)
test_daemon_removed_session_drops_its_seq_mark :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    path := testsupport.sqlite_db_path(t, "daemon-pump-removed-mark")
    defer testsupport.sqlite_db_remove(path)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    d: Daemon
    derr := start(&d, loop, {host = "127.0.0.1", port = 0, db_path = path})
    testing.expect_value(t, derr, Error.None)

    session := pump_test_session('9')
    daemon_test_session_create(t, &d, session)
    testing.expect_value(t, broadcast(&d, pump_run_started(session)), Pump_Error.None)
    testing.expect_value(t, d.seq_high[session], wire.Seq(1))

    removed := wire.Session_Removed_Data {
        revision   = 1,
        session_id = session,
    }
    testing.expect_value(t, broadcast(&d, removed), Pump_Error.None)

    _, tracked := d.seq_high[session]
    testing.expect(t, !tracked, "a removed session must not keep its memoized mark")

    // The mark is memoization only: the next durable broadcast recovers the same
    // high-water from the log and continues the stream contiguously.
    testing.expect_value(t, broadcast(&d, pump_run_started(session)), Pump_Error.None)
    testing.expect_value(t, d.seq_high[session], wire.Seq(2))

    rows, rerr := store.events_after(d.store, session, 0, 8, context.temp_allocator)
    testing.expect_value(t, rerr, nil)

    if testing.expect_value(t, len(rows), 2) {
        testing.expect_value(t, rows[1].seq, wire.Seq(2))
    }

    test_teardown(&d)
}

@(test)
test_daemon_start_refuses_a_damaged_database :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    path := testsupport.sqlite_db_path(t, "daemon-pump-damaged")
    defer testsupport.sqlite_db_remove(path)

    werr := os.write_entire_file(path, transmute([]byte)string("this is not a database"))
    testing.expect(t, werr == nil, "the fixture file should be writable")

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    // The refusal is logged as an error, which the runner would otherwise count as a
    // test failure; the assertions below are the check.
    context.logger = log.nil_logger()

    // A damaged database is reported, not crashed on, and nothing is left listening.
    d: Daemon
    testing.expect_value(t, start(&d, loop, {host = "127.0.0.1", port = 0, db_path = path}), Error.Store_Failed)
    testing.expect(t, d.store == nil, "a refused start leaves no store open")
}

// A droppable payload; like the live one it validates by session id alone.
pump_part_delta :: proc(session: wire.Session_Id) -> wire.Broadcast_Data {
    return wire.Message_Part_Delta_Data(
        wire.Part_Delta{session_id = session, message_id = 1, part_id = 0, delta = "hi", offset = 0},
    )
}

@(test)
test_daemon_live_droppable_broadcast_is_gated_and_not_persisted :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    path := testsupport.sqlite_db_path(t, "daemon-pump-droppable")
    defer testsupport.sqlite_db_remove(path)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    d: Daemon
    derr := start(&d, loop, {host = "127.0.0.1", port = 0, db_path = path})
    testing.expect_value(t, derr, Error.None)

    session := pump_test_session('4')
    daemon_test_session_create(t, &d, session)
    port := bound_port(&d)

    subscribed: Pump_Obs
    pump_obs_init(&subscribed, {session})
    sub_client: client.Client
    pump_client_arm(t, &sub_client, loop, port, &subscribed)

    idle: Pump_Obs
    pump_obs_init(&idle, nil)
    idle_client: client.Client
    pump_client_arm(t, &idle_client, loop, port, &idle)

    // Droppable is still subscription-gated and still never logged; only the send path
    // treats it differently.
    testing.expect_value(t, broadcast(&d, pump_part_delta(session)), Pump_Error.None)
    pump_settle()

    if testing.expect_value(t, len(subscribed.names), 1) {
        testing.expect_value(t, subscribed.names[0], wire.Broadcast_Name.Message_Part_Delta)
        testing.expect_value(t, subscribed.seqs[0], wire.Seq(0))
    }

    testing.expect_value(t, len(idle.names), 0)

    rows, rerr := store.events_after(d.store, session, 0, 8, context.temp_allocator)
    testing.expect_value(t, rerr, nil)
    testing.expect_value(t, len(rows), 0)

    client.client_close(&sub_client)
    client.client_close(&idle_client)
    testing.expect(t, pump_tick_until(&subscribed.done), "the subscribed client should close cleanly")
    testing.expect(t, pump_tick_until(&idle.done), "the idle client should close cleanly")
    client.client_destroy(&sub_client)
    client.client_destroy(&idle_client)
    test_teardown(&d)
}

@(test)
test_daemon_refused_append_broadcasts_nothing :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    path := testsupport.sqlite_db_path(t, "daemon-pump-refused")
    defer testsupport.sqlite_db_remove(path)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    // The refused append is logged as an error, which the runner would otherwise count
    // as a test failure; the assertions below are the check.
    context.logger = log.nil_logger()

    d: Daemon
    derr := start(&d, loop, {host = "127.0.0.1", port = 0, db_path = path})
    testing.expect_value(t, derr, Error.None)

    session := pump_test_session('2')
    daemon_test_session_create(t, &d, session)

    obs: Pump_Obs
    pump_obs_init(&obs, {session})
    c: client.Client
    pump_client_arm(t, &c, loop, bound_port(&d), &obs)

    // Take the log out from under the writer, so the append fails inside its
    // transaction.
    testing.expect_value(t, sqlite.exec(d.store.writer, "DROP TABLE events"), sqlite.Result.Ok)

    testing.expect_value(t, broadcast(&d, pump_run_started(session)), Pump_Error.Store_Failed)
    pump_settle()

    testing.expect_value(t, len(obs.names), 0)
    _, tracked := d.seq_high[session]
    testing.expect(t, !tracked, "a refused append must not burn the seq")

    client.client_close(&c)
    testing.expect(t, pump_tick_until(&obs.done), "the client should close cleanly")
    client.client_destroy(&c)
    test_teardown(&d)
}

// --- Subscription bound rejection over a raw peer ------------------------------
//
// The `src/client` driver validates outbound params, so an over-bound
// `subscription.set` can only come from a peer that hand-builds it: initialize first
// (the daemon accepts nothing else before Ready), then the oversized frame.

Sub_Peer :: struct {
    // Port to connect to.
    port:       int,

    // Frame sent once the initialize response arrives.
    frame:      string,

    // The peer ran its script to completion.
    ok:         bool,

    // The server sent a WebSocket Close frame.
    got_close:  bool,

    // Close code carried by that Close frame.
    close_code: u16,
}

sub_peer :: proc(p: ^Sub_Peer) {
    defer free_all(context.temp_allocator)

    sock, dialed := raw_dial(p.port)
    if !dialed {
        return
    }
    defer net.close(sock)

    if !raw_upgrade(sock) {
        return
    }

    hello := `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocol":1,"client":{"name":"x","version":"y"}}}`
    if !peer_send_text(sock, hello) {
        return
    }

    dec: ws.Decoder
    ws.decoder_init(&dec, 1 << 20, 1 << 20, .Client, context.temp_allocator)
    defer ws.decoder_destroy(&dec)

    sent := false
    buf: [4096]byte
    for {
        msg, has, derr := ws.decoder_next(&dec, context.temp_allocator)
        if derr != .None {
            break
        }

        if has {
            if msg.kind == .Close {
                parsed, _ := ws.parse_close(msg.data)
                p.got_close = true
                p.close_code = u16(parsed.code)
                break
            }

            if msg.kind == .Text && !sent {
                if !peer_send_text(sock, p.frame) {
                    return
                }

                sent = true
            }

            continue
        }

        got, rerr := net.recv_tcp(sock, buf[:])
        if rerr != nil || got == 0 {
            break
        }

        ws.decoder_feed(&dec, buf[:got])
    }

    p.ok = true
}

// Send one masked text frame, as a real client always does.
peer_send_text :: proc(sock: net.TCP_Socket, payload: string) -> bool {
    key: [ws.MASK_KEY_BYTES]byte
    for i in 0 ..< len(key) {
        key[i] = u8(i + 1)
    }

    frame := ws.encode_frame(true, .Text, transmute([]byte)payload, key, context.temp_allocator)
    _, serr := net.send_tcp(sock, frame)

    return serr == nil
}

@(test)
test_daemon_subscription_set_over_bound_closes :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    d: Daemon
    derr := start(&d, loop, {host = "127.0.0.1", port = 0})
    testing.expect_value(t, derr, Error.None)

    // One past `LIMITS.max_subscriptions`: a bound violation is a protocol error, not
    // an error response.
    b := strings.builder_make(context.temp_allocator)
    strings.write_string(&b, `{"jsonrpc":"2.0","id":2,"method":"subscription.set","params":{"sessions":[`)
    for i in 0 ..< wire.LIMITS.max_subscriptions + 1 {
        if i > 0 {
            strings.write_string(&b, ",")
        }

        fmt.sbprintf(&b, `"%04x%012x"`, i, i)
    }

    strings.write_string(&b, `]}}`)

    p := Sub_Peer {
        port  = bound_port(&d),
        frame = strings.to_string(b),
    }
    peer := thread.create_and_start_with_poly_data(&p, sub_peer)
    defer {
        thread.join(peer)
        thread.destroy(peer)
    }

    for _ in 0 ..< 2000 {
        nbio.tick(time.Millisecond)
        if sync.atomic_load(&p.ok) && len(d.ws_server.conns) == 0 {
            break
        }
    }

    thread.join(peer)

    testing.expect(t, p.got_close, "an over-bound subscription set should close the connection")
    testing.expect_value(t, p.close_code, wire.CLOSE.protocol_error)

    test_teardown(&d)
}

// One encoding serves the log and the fan-out, so a reasoning signature and a turn's
// provenance survive the append and a re-encode of the stored row is byte-identical.
@(test)
test_daemon_round_trips_provider_turn_members :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    path := testsupport.sqlite_db_path(t, "daemon-pump-private")
    defer testsupport.sqlite_db_remove(path)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    d: Daemon
    derr := start(&d, loop, {host = "127.0.0.1", port = 0, db_path = path})
    testing.expect_value(t, derr, Error.None)

    session := pump_test_session('3')
    daemon_test_session_create(t, &d, session)
    parts := []wire.Assistant_Part{wire.Reasoning_Part{id = 0, text = "hm", signature = "ErUBCkYIB"}}
    committed := wire.Message_Committed_Data {
        session_id = session,
        message = wire.Assistant_Message {
            id = 1,
            run_id = 1,
            config_rev = 1,
            agent = "main",
            content = parts,
            finish = wire.Stop_Reason.Stop,
            time = {created_at_ms = 1, completed_at_ms = 2},
            provenance = wire.Turn_Provenance{protocol = .Anthropic_Messages, model = "claude-sonnet-4-5"},
        },
    }
    testing.expect_value(t, broadcast(&d, committed), Pump_Error.None)

    rows, rerr := store.events_after(d.store, session, 0, 8, context.temp_allocator)
    testing.expect_value(t, rerr, nil)

    if testing.expect_value(t, len(rows), 1) {
        testing.expect(t, strings.contains(rows[0].payload, `"signature":"ErUBCkYIB"`), "the log keeps the signature")
        testing.expect(t, strings.contains(rows[0].payload, `"provenance":`), "the log keeps the provenance")

        dec := wire.decoder_init(rows[0].payload, context.temp_allocator)
        data, cerr := wire.broadcast_data_from_reader(.Message_Committed, &dec)
        testing.expect_value(t, cerr, wire.Validation_Error.None)

        e: wire.Emitter
        wire.emitter_init(&e, context.temp_allocator)
        defer wire.emitter_destroy(&e)
        wire.broadcast_data_emit(&e, data)
        replayed := wire.to_string(&e)
        testing.expect_value(t, replayed, rows[0].payload)
    }

    test_teardown(&d)
}

// Every event carries a foreign key into `sessions`, so a synthetic id needs its
// registry row before the pump can log anything for it. The daemon has no session
// engine yet, so tests stand in for what `session.create` will do.
daemon_test_session_create :: proc(t: ^testing.T, d: ^Daemon, ids: ..wire.Session_Id) {
    if d.store == nil {
        return
    }

    for id in ids {
        summary := wire.Session {
            id = id,
            profile = "default",
            model = "test/model",
            reasoning = "low",
            permission = .Normal,
            title = "test",
            created_at_ms = 1,
            updated_at_ms = 1,
            created_by = wire.Client{name = "yuke-test", version = "0.1.0"},
            origin = wire.Session_Origin_Root{},
        }

        testing.expect_value(t, store.session_create(d.store, summary), nil)
    }
}
