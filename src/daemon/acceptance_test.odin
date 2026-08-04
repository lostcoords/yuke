package daemon

import "core:nbio"
import "core:testing"

import "libs:testsupport"
import ws "libs:websocket"
import client "src:client"
import store "src:daemon/store"
import wire "src:wire"

// --- Acceptance: durable fan-out, gating, restart, and resync -------------------
//
// One flowing scenario over real `src/client` connections and a real on-disk store,
// proving the store, pump, and resync work together end to end rather than piecemeal: a
// durable broadcast reaches a subscribed client and survives a daemon restart.
// Reuses `Pump_Obs`/`pump_client_arm` from pump_test.odin, `resync_config`/
// `resync_user`/`resync_assistant` from resync_test.odin, and `test_teardown`.

// Observations for the post-restart client, reached through `user_data`. Chains
// `subscription.set` then `session.resync`, installs the snapshot into a real
// replica, and feeds every later broadcast through it.
Acceptance_Obs :: struct {
    // Session resynced and subscribed to.
    session:         wire.Session_Id,

    // The `subscription.set` response was an error rather than a result.
    sub_failed:      bool,

    // The `session.resync` request was answered.
    resync_done:     bool,

    // The answer decoded as a snapshot and installed cleanly.
    resync_ok:       bool,

    // The replica the snapshot installed into and later broadcasts feed; initialized
    // and released by the test body, so a failing path still tears it down.
    replica:         client.Session_Replica,

    // Outcome of installing the snapshot.
    install_outcome: client.Install_Outcome,

    // Error from installing the snapshot.
    install_err:     client.Replica_Error,

    // Result of applying the post-restart broadcast.
    post_result:     client.Apply_Result,

    // Error from applying the post-restart broadcast.
    post_err:        client.Replica_Error,

    // The post-restart broadcast was delivered and applied.
    post_seen:       bool,

    // Terminal callback fired.
    done:            bool,
}

acceptance_on_ready :: proc(c: ^client.Client, _: wire.Initialize_Result) {
    o := (^Acceptance_Obs)(c.user_data)
    client.client_send_request(
        c,
        .Subscription_Set,
        wire.Subscription_Set_Params{sessions = {o.session}},
        acceptance_on_sub,
    )
}

acceptance_on_sub :: proc(c: ^client.Client, resp: wire.Response, _: rawptr) {
    o := (^Acceptance_Obs)(c.user_data)

    if _, ok := resp.(wire.Response_Ok); !ok {
        o.sub_failed = true
    }

    client.client_send_request(
        c,
        .Session_Resync,
        wire.Session_Resync_Params{session_id = o.session},
        acceptance_on_resync,
    )
}

acceptance_on_resync :: proc(c: ^client.Client, resp: wire.Response, _: rawptr) {
    o := (^Acceptance_Obs)(c.user_data)
    o.resync_done = true

    ok, is_ok := resp.(wire.Response_Ok)
    if !is_ok {
        return
    }

    cut, is_cut := ok.result.(wire.Session_Resync_Result)
    if !is_cut {
        return
    }

    o.install_outcome, o.install_err = client.replica_install_snapshot(&o.replica, cut)
    o.resync_ok = o.install_err == .None
}

acceptance_on_broadcast :: proc(c: ^client.Client, bc: wire.Notification) {
    o := (^Acceptance_Obs)(c.user_data)
    if !o.resync_ok {
        return
    }

    o.post_result, o.post_err = client.replica_apply_broadcast(&o.replica, bc)
    o.post_seen = true
}

acceptance_on_close :: proc(c: ^client.Client, _: client.Close_Code) {
    o := (^Acceptance_Obs)(c.user_data)
    o.done = true
}

acceptance_on_error :: proc(c: ^client.Client, _: client.Protocol_Error) {
    o := (^Acceptance_Obs)(c.user_data)
    o.done = true
}

@(test)
test_daemon_acceptance_durable_broadcast_survives_restart :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    path := testsupport.sqlite_db_path(t, "daemon-acceptance")
    defer testsupport.sqlite_db_remove(path)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    session := pump_test_session('a')
    other := pump_test_session('b')

    first: Daemon
    testing.expect_value(t, start(&first, loop, {host = "127.0.0.1", port = 0, db_path = path}), Error.None)
    daemon_test_session_create(t, &first, session, other)
    port := bound_port(&first)

    subscribed: Pump_Obs
    pump_obs_init(&subscribed, {session})
    sub_client: client.Client
    pump_client_arm(t, &sub_client, loop, port, &subscribed)

    other_obs: Pump_Obs
    pump_obs_init(&other_obs, {other})
    other_client: client.Client
    pump_client_arm(t, &other_client, loop, port, &other_obs)

    // Append: the pump is the sole seq authority, and seqs are contiguous per session.
    testing.expect_value(t, broadcast(&first, resync_config(session, 1, "m1")), Pump_Error.None)
    testing.expect_value(t, broadcast(&first, resync_assistant(session, 1, 1)), Pump_Error.None)
    pump_settle()

    if testing.expect_value(t, len(subscribed.names), 2) {
        testing.expect_value(t, subscribed.seqs[0], wire.Seq(1))
        testing.expect_value(t, subscribed.seqs[1], wire.Seq(2))
    }

    // Subscription gating: a client subscribed to a different session sees nothing.
    testing.expect_value(t, len(other_obs.names), 0)

    rows := pump_events(t, first.store, session)
    testing.expect_value(t, len(rows), 2)

    client.client_close(&sub_client)
    client.client_close(&other_client)
    testing.expect(t, pump_tick_until(&subscribed.done), "the subscribed client should close cleanly")
    testing.expect(t, pump_tick_until(&other_obs.done), "the other client should close cleanly")
    client.client_destroy(&sub_client)
    client.client_destroy(&other_client)
    test_teardown(&first)

    // Full teardown, then restart against the same db path.
    second: Daemon
    testing.expect_value(t, start(&second, loop, {host = "127.0.0.1", port = 0, db_path = path}), Error.None)

    // High-water recovery: the mark survived the restart instead of resetting.
    hw, herr := store.high_water(second.store, session)
    testing.expect_value(t, herr, nil)
    testing.expect_value(t, hw.seq, wire.Seq(2))

    obs := Acceptance_Obs {
        session = session,
    }
    client.replica_init(&obs.replica, context.allocator, session)
    defer client.replica_destroy(&obs.replica)

    c: client.Client
    transport, terr := client.ws_create(
        loop,
        {host = "127.0.0.1", port = bound_port(&second), path = "/ws"},
        context.temp_allocator,
    )
    testing.expect_value(t, terr, ws.Client_Error.None)

    cerr := client.client_open(
        &c,
        transport,
        "yuke-test",
        "0.1.0",
        client.Client_Callbacks {
            on_ready = acceptance_on_ready,
            on_broadcast = acceptance_on_broadcast,
            on_close = acceptance_on_close,
            on_error = acceptance_on_error,
        },
        &obs,
        context.temp_allocator,
    )
    testing.expect_value(t, cerr, client.Protocol_Error.None)
    testing.expect(t, pump_tick_until(&obs.resync_done), "session.resync should be answered")
    testing.expect(t, !obs.sub_failed, "subscription.set should answer with a result")

    // Resync cut: derived from the rows committed before the restart, one instant with
    // the recovered high water.
    testing.expect(t, obs.resync_ok, "the snapshot should decode and install into the replica")
    testing.expect_value(t, obs.install_outcome, client.Install_Outcome.Live)
    testing.expect_value(t, obs.replica.base_seq, wire.Seq(2))

    if testing.expect_value(t, len(obs.replica.messages), 1) {
        testing.expect_value(t, wire.message_id(obs.replica.messages[0].message), wire.Message_Id(1))
    }

    testing.expect_value(t, len(obs.replica.configs), 1)

    // Emit one more durable broadcast; its seq must continue from the recovered high
    // water, never reuse or gap.
    testing.expect_value(t, broadcast(&second, resync_assistant(session, 2, 1)), Pump_Error.None)
    pump_settle()

    hw2, herr2 := store.high_water(second.store, session)
    testing.expect_value(t, herr2, nil)
    testing.expect_value(t, hw2.seq, wire.Seq(3))

    // Gap-free continuation: the replica accepts the post-restart event as the very
    // next seq after the installed cut, with no resync triggered.
    testing.expect(t, obs.post_seen, "the post-restart broadcast should be delivered")
    testing.expect_value(t, obs.post_err, client.Replica_Error.None)
    testing.expect_value(t, obs.post_result.kind, client.Apply_Kind.Committed)
    testing.expect_value(t, obs.replica.base_seq, wire.Seq(3))

    client.client_close(&c)
    testing.expect(t, pump_tick_until(&obs.done), "the client should close cleanly")
    client.client_destroy(&c)
    test_teardown(&second)
}
