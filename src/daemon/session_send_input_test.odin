package daemon

import "core:nbio"
import "core:testing"

import "libs:testsupport"
import ws "libs:websocket"
import client "src:client"
import store "src:daemon/store"
import wire "src:wire"

// One driver that subscribes to a session and then sends inputs into it. `input.queued`
// and `message.committed` are subscription-gated; every broadcast is also folded into a
// replica, so the announced pair is checked against the client model that consumes it.
Input_Obs :: struct {
    // Session to subscribe to and address.
    session:        wire.Session_Id,

    // Inputs to send, one after the previous is answered.
    inputs:         []wire.Input,
    sent:           int,

    // Input ids answered, in request order; short when a send answered with an error.
    accepted:       [dynamic]wire.Input_Id,

    // Run ids answered, for the sends that started a turn.
    runs:           [dynamic]wire.Run_Id,

    // Error code of the last answered request; `is_error` says whether it means anything.
    is_error:       bool,
    code:           wire.Error_Code,

    // Broadcast names delivered, in arrival order, with the payloads worth reading back
    // cloned out of the frame arena they borrow.
    names:          [dynamic]wire.Broadcast_Name,

    // Arrival wall clock per broadcast, parallel to `names`, for proving that a stream is
    // delivered as it arrives rather than in one flush at the end.
    times:          [dynamic]u64,

    // Activity states delivered, in arrival order, so a test can assert the phases a turn
    // moved through rather than only that it announced something.
    activities:     [dynamic]wire.Session_Activity,
    queued:         [dynamic]wire.Queued_Input,
    committed:      [dynamic]wire.User_Message,
    assistants:     [dynamic]wire.Assistant_Message,
    turns:          [dynamic]wire.Run_Outcome_Turn,
    failures:       [dynamic]wire.Run_Error_Code,
    canceled_runs:  int,
    summaries:      [dynamic]wire.Session,

    // A `run.done` arrived, so the turn this driver started has finished.
    turn_done:      bool,

    // Issue one `session.cancel_run` once every input is answered, optionally naming a
    // run, and keep what it answered. `cancel_input` names a queued input instead.
    cancel_input:   Maybe(wire.Input_Id),
    cancel:         bool,
    cancel_run:     Maybe(wire.Run_Id),
    cancel_sent:    bool,
    canceled:       wire.Session_Cancel_Run_Result,
    canceled_input: wire.Input_Id,

    // The replica every broadcast is folded into, and the first refusal it reported.
    replica:        client.Session_Replica,
    apply_err:      client.Replica_Error,

    // Every request has been answered.
    settled:        bool,

    // Terminal callback fired.
    done:           bool,
}

input_obs_init :: proc(o: ^Input_Obs, session: wire.Session_Id, inputs: []wire.Input) {
    o.session = session
    o.inputs = inputs
    o.accepted = make([dynamic]wire.Input_Id, context.temp_allocator)
    o.runs = make([dynamic]wire.Run_Id, context.temp_allocator)
    o.names = make([dynamic]wire.Broadcast_Name, context.temp_allocator)
    o.times = make([dynamic]u64, context.temp_allocator)
    o.activities = make([dynamic]wire.Session_Activity, context.temp_allocator)
    o.queued = make([dynamic]wire.Queued_Input, context.temp_allocator)
    o.committed = make([dynamic]wire.User_Message, context.temp_allocator)
    o.assistants = make([dynamic]wire.Assistant_Message, context.temp_allocator)
    o.turns = make([dynamic]wire.Run_Outcome_Turn, context.temp_allocator)
    o.failures = make([dynamic]wire.Run_Error_Code, context.temp_allocator)
    o.summaries = make([dynamic]wire.Session, context.temp_allocator)
    client.replica_init(&o.replica, context.allocator, session)
}

input_on_ready :: proc(c: ^client.Client, _: wire.Initialize_Result) {
    o := (^Input_Obs)(c.user_data)

    client.client_send_request(
        c,
        .Subscription_Set,
        wire.Subscription_Set_Params{sessions = {o.session}},
        input_on_sub,
    )
}

input_on_sub :: proc(c: ^client.Client, outcome: client.Request_Outcome, _: rawptr) {
    o := (^Input_Obs)(c.user_data)
    answered, has_response := outcome.(client.Request_Response)
    if !has_response {
        o.settled = true
        return
    }

    if _, ok := answered.response.(wire.Response_Ok); !ok {
        o.settled = true
        return
    }

    input_send_next(c, o)
}

// Requests are serialized rather than pipelined: the second input must observe the id
// marks the first one raised.
input_send_next :: proc(c: ^client.Client, o: ^Input_Obs) {
    if o.sent == len(o.inputs) {
        if input_id, cancels_input := o.cancel_input.?; cancels_input && !o.cancel_sent {
            o.cancel_sent = true
            client.client_send_request(
                c,
                .Session_Cancel_Input,
                wire.Session_Cancel_Input_Params{session_id = o.session, input_id = input_id},
                input_on_cancel,
            )

            return
        }

        if o.cancel && !o.cancel_sent {
            o.cancel_sent = true
            client.client_send_request(
                c,
                .Session_Cancel_Run,
                wire.Session_Cancel_Run_Params{session_id = o.session, run_id = o.cancel_run},
                input_on_cancel,
            )

            return
        }

        o.settled = true
        return
    }

    input := o.inputs[o.sent]
    o.sent += 1
    client.client_send_request(
        c,
        .Session_Send_Input,
        wire.Session_Send_Input_Params{session_id = o.session, input = input},
        input_on_response,
    )
}

input_on_response :: proc(c: ^client.Client, outcome: client.Request_Outcome, _: rawptr) {
    o := (^Input_Obs)(c.user_data)
    answered, has_response := outcome.(client.Request_Response)
    if !has_response {
        o.settled = true
        return
    }

    switch resp in answered.response {
    case wire.Response_Ok:
        o.is_error = false

        if result, ok := resp.result.(wire.Session_Send_Input_Result); ok {
            switch answer in result {
            case wire.Session_Send_Input_Result_Started:
                append(&o.accepted, answer.input_id)
                append(&o.runs, answer.run_id)

            case wire.Session_Send_Input_Result_Queued:
                append(&o.accepted, answer.input_id)
            }
        }

    case wire.Response_Error:
        o.is_error = true
        o.code = resp.error.code
    }

    input_send_next(c, o)
}

// The cancel is the driver's last request, so its answer settles the run.
input_on_cancel :: proc(c: ^client.Client, outcome: client.Request_Outcome, _: rawptr) {
    o := (^Input_Obs)(c.user_data)
    o.settled = true

    answered, has_response := outcome.(client.Request_Response)
    if !has_response {
        return
    }

    switch resp in answered.response {
    case wire.Response_Ok:
        o.is_error = false

        if result, ok := resp.result.(wire.Session_Cancel_Run_Result); ok {
            o.canceled = result
        }

        if result, ok := resp.result.(wire.Session_Cancel_Input_Result); ok {
            o.canceled_input = result.canceled_input
        }

    case wire.Response_Error:
        o.is_error = true
        o.code = resp.error.code
    }
}

input_on_broadcast :: proc(c: ^client.Client, bc: wire.Notification) {
    o := (^Input_Obs)(c.user_data)
    append(&o.names, bc.method)
    append(&o.times, now_ms())

    #partial switch v in bc.params {
    case wire.Input_Queued_Data:
        append(&o.queued, wire.queued_input_clone(v.input, context.temp_allocator))

    case wire.Message_Committed_Data:
        switch message in v.message {
        case wire.User_Message:
            append(&o.committed, wire.user_message_clone(message, context.temp_allocator))

        case wire.Assistant_Message:
            append(&o.assistants, wire.assistant_message_clone(message, context.temp_allocator))

        case wire.Compaction_Message:
        }

    case wire.Session_Activity_Changed_Data:
        activity := v.activity
        activity.state = wire.activity_state_clone(v.activity.state, context.temp_allocator)
        append(&o.activities, activity)

    case wire.Run_Done_Data:
        o.turn_done = true

        switch outcome in v.outcome {
        case wire.Run_Outcome_Turn:
            turn := outcome
            append(&o.turns, turn)

        case wire.Run_Outcome_Failed:
            append(&o.failures, outcome.code)

        case wire.Run_Outcome_Canceled:
            o.canceled_runs += 1

        case wire.Run_Outcome_Compacted, wire.Run_Outcome_Skipped:
        }

    case wire.Session_Summary_Changed_Data:
        append(&o.summaries, wire.session_clone(v.session, context.temp_allocator))
    }

    if _, err := client.replica_apply_broadcast(&o.replica, bc); err != .None && o.apply_err == .None {
        o.apply_err = err
    }
}

input_on_close :: proc(c: ^client.Client, _: client.Close_Code) {
    o := (^Input_Obs)(c.user_data)
    o.done = true
}

input_on_error :: proc(c: ^client.Client, _: client.Protocol_Error) {
    o := (^Input_Obs)(c.user_data)
    o.settled = true
    o.done = true
}

input_callbacks :: proc() -> client.Client_Callbacks {
    return client.Client_Callbacks {
        on_ready = input_on_ready,
        on_broadcast = input_on_broadcast,
        on_close = input_on_close,
        on_error = input_on_error,
    }
}

// Open one driver against `port` and run the loop until every input is answered.
input_client_run :: proc(t: ^testing.T, c: ^client.Client, loop: ^nbio.Event_Loop, port: int, o: ^Input_Obs) {
    transport, terr := client.ws_create(loop, {host = "127.0.0.1", port = port, path = "/ws"}, context.temp_allocator)
    testing.expect_value(t, terr, ws.Client_Error.None)

    cerr := client.client_open(c, transport, "yuke-test", "0.1.0", input_callbacks(), o, context.temp_allocator)
    testing.expect_value(t, cerr, client.Protocol_Error.None)
    testing.expect(t, pump_tick_until(&o.settled), "every session.send_input should be answered")
    pump_settle()
}

// Close the driver and tear the daemon down; every exit path runs the same teardown.
input_client_stop :: proc(t: ^testing.T, c: ^client.Client, d: ^Daemon, o: ^Input_Obs) {
    client.client_close(c)
    testing.expect(t, pump_tick_until(&o.done), "the client should close cleanly")
    client.client_destroy(c)
    client.replica_destroy(&o.replica)
    test_teardown(d)
}

// The accepted input is announced live and then committed durably, in that order, and the
// two name the same id. Ids start at 1, increment across sends, and land in the store's
// marks without a write of their own.
@(test)
test_session_send_input_commits_the_user_message :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    path := testsupport.sqlite_db_path(t, "session-send-input")
    defer testsupport.sqlite_db_remove(path)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    session := pump_test_session('a')

    d: Daemon
    testing.expect_value(t, start(&d, loop, {host = "127.0.0.1", port = 0, db_path = path}), Error.None)
    daemon_test_session_create(t, &d, session)

    first := [?]wire.Content_Part{wire.Content_Text{text = "first"}}
    second := [?]wire.Content_Part{wire.Content_Text{text = "second"}}
    inputs := [?]wire.Input{wire.Input_Content{content = first[:]}, wire.Input_Content{content = second[:]}}

    obs: Input_Obs
    input_obs_init(&obs, session, inputs[:])

    c: client.Client
    input_client_run(t, &c, loop, bound_port(&d), &obs)

    // The fixture's model is in no catalog, so no turn starts. The input is durable
    // either way: a refused turn does not undo the message the user already sent.
    testing.expect(t, obs.is_error, "a session whose model resolves to nothing starts no turn")
    testing.expect_value(t, obs.code, wire.Error_Code.Unsupported_Model)
    testing.expect_value(t, len(obs.runs), 0)

    // `input.queued` precedes the commit it explains, and the index is refreshed after
    // the commit that moved it.
    if testing.expect_value(t, len(obs.names), 6) {
        testing.expect_value(t, obs.names[0], wire.Broadcast_Name.Input_Queued)
        testing.expect_value(t, obs.names[1], wire.Broadcast_Name.Message_Committed)
        testing.expect_value(t, obs.names[2], wire.Broadcast_Name.Session_Summary_Changed)
        testing.expect_value(t, obs.names[3], wire.Broadcast_Name.Input_Queued)
        testing.expect_value(t, obs.names[4], wire.Broadcast_Name.Message_Committed)
        testing.expect_value(t, obs.names[5], wire.Broadcast_Name.Session_Summary_Changed)
    }

    if testing.expect_value(t, len(obs.queued), 2) && testing.expect_value(t, len(obs.committed), 2) {
        testing.expect_value(t, obs.queued[0].input_id, obs.committed[0].input_id)
        testing.expect_value(t, obs.queued[1].input_id, obs.committed[1].input_id)
        testing.expect_value(t, obs.committed[0].id, wire.Message_Id(1))
        testing.expect_value(t, obs.committed[1].id, wire.Message_Id(2))
        testing.expect(t, obs.queued[0].queued_at_ms > 0, "a queued input is stamped with the wall clock")

        // The content the request carried reaches the transcript unchanged.
        if testing.expect_value(t, len(obs.committed[0].content), 1) {
            text, is_text := obs.committed[0].content[0].(wire.Content_Text)
            testing.expect(t, is_text, "a text part commits as a text part")
            testing.expect_value(t, text.text, "first")
        }

        // The commit stamps both timestamps from one clock read, so the summary the
        // index carries cannot disagree with the message that moved it.
        testing.expect_value(t, obs.committed[0].time.created_at_ms, obs.queued[0].queued_at_ms)
    }

    // The index the commit moved: `session.list` orders on `updated_at_ms`, which the
    // fixture left at 1.
    if testing.expect_value(t, len(obs.summaries), 2) {
        testing.expect_value(t, obs.summaries[0].message_count, u64(1))
        testing.expect_value(t, obs.summaries[1].message_count, u64(2))
        testing.expect(t, obs.summaries[1].updated_at_ms > 1, "committing a message moves the update mark")
    }

    // Both id families advanced in the append's own transaction.
    hw, herr := store.high_water(d.store, session)
    testing.expect_value(t, herr, nil)
    testing.expect_value(t, hw.seq, wire.Seq(2))
    testing.expect_value(t, hw.message_id, wire.Message_Id(2))
    testing.expect_value(t, hw.input_id, wire.Input_Id(2))

    // The pair converges: the commit dequeues the input it names, so a replica fed both
    // broadcasts holds the messages and nothing else.
    testing.expect_value(t, obs.apply_err, client.Replica_Error.None)
    testing.expect_value(t, len(obs.replica.queued), 0)
    testing.expect_value(t, len(obs.replica.messages), 2)

    input_client_stop(t, &c, &d, &obs)
}

// A send into a session that was never created is refused before anything is announced.
@(test)
test_session_send_input_refuses_an_unknown_session :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    path := testsupport.sqlite_db_path(t, "session-send-input-unknown")
    defer testsupport.sqlite_db_remove(path)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    d: Daemon
    testing.expect_value(t, start(&d, loop, {host = "127.0.0.1", port = 0, db_path = path}), Error.None)
    daemon_test_session_create(t, &d, pump_test_session('a'))

    parts := [?]wire.Content_Part{wire.Content_Text{text = "hello"}}
    inputs := [?]wire.Input{wire.Input_Content{content = parts[:]}}

    // Never created, so the registry has no row for the session the send names. The
    // subscription takes the id as given, so a refusal would still have been observed.
    obs: Input_Obs
    input_obs_init(&obs, pump_test_session('b'), inputs[:])

    c: client.Client
    input_client_run(t, &c, loop, bound_port(&d), &obs)

    testing.expect(t, obs.is_error, "an unknown session is refused")
    testing.expect_value(t, obs.code, wire.Error_Code.Unknown_Session)
    testing.expect_value(t, len(obs.accepted), 0)
    testing.expect_value(t, len(obs.names), 0)

    input_client_stop(t, &c, &d, &obs)
}

// A commit that never lands retracts the input it already announced. `input.queued` is
// live-only, so nothing in the log or a later resync takes it back: a subscriber that is
// not told the input is gone waits for it forever. The append refuses a session with no
// registry row, which is the failure the handler cannot rule out in advance.
@(test)
test_session_send_input_retracts_an_uncommittable_input :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    path := testsupport.sqlite_db_path(t, "session-send-input-retract")
    defer testsupport.sqlite_db_remove(path)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    // The refused append is logged as an error, which the runner would otherwise count as
    // a test failure; the assertions below are the check.
    saved_logger := context.logger
    quiet_logger: testsupport.Assert_Only_Logger
    context.logger = testsupport.assert_only_logger(&quiet_logger, saved_logger)
    defer context.logger = saved_logger

    d: Daemon
    testing.expect_value(t, start(&d, loop, {host = "127.0.0.1", port = 0, db_path = path}), Error.None)

    // Never created, so the append has no row to advance. `subscription.set` takes ids as
    // given, so a connection can still watch it.
    phantom := pump_test_session('c')

    obs: Input_Obs
    input_obs_init(&obs, phantom, {})

    c: client.Client
    input_client_run(t, &c, loop, bound_port(&d), &obs)

    parts := [?]wire.Content_Part{wire.Content_Text{text = "stranded"}}
    queued := wire.Queued_Input {
        input_id     = 1,
        content      = parts[:],
        queued_at_ms = 1,
    }
    committed := wire.User_Message {
        id = 1,
        content = parts[:],
        input_id = 1,
        time = wire.Created_Time{created_at_ms = 1},
    }

    published := send_input_publish(&d, phantom, queued, committed, context.temp_allocator)
    testing.expect(t, !published, "an append into a session with no registry row fails")
    pump_settle()

    if testing.expect_value(t, len(obs.names), 2) {
        testing.expect_value(t, obs.names[0], wire.Broadcast_Name.Input_Queued)
        testing.expect_value(t, obs.names[1], wire.Broadcast_Name.Input_Canceled)
    }

    // The replica took both broadcasts, and its queue drains rather than holding an input
    // no commit will ever name.
    testing.expect_value(t, obs.apply_err, client.Replica_Error.None)
    testing.expect_value(t, len(obs.replica.queued), 0)
    testing.expect_value(t, len(obs.replica.messages), 0)

    // The refused commit logged nothing durable either.
    hw, herr := store.high_water(d.store, phantom)
    testing.expect_value(t, herr, nil)
    testing.expect_value(t, hw.seq, wire.Seq(0))

    input_client_stop(t, &c, &d, &obs)
}

// A skill reaches the transcript as rendered content parts, and nothing renders one yet,
// so it is refused rather than committed empty.
@(test)
test_session_send_input_refuses_a_skill :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    path := testsupport.sqlite_db_path(t, "session-send-input-skill")
    defer testsupport.sqlite_db_remove(path)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    session := pump_test_session('a')

    d: Daemon
    testing.expect_value(t, start(&d, loop, {host = "127.0.0.1", port = 0, db_path = path}), Error.None)
    daemon_test_session_create(t, &d, session)

    inputs := [?]wire.Input{wire.Input_Skill{skill = wire.Skill_Ref{name = "review", arguments = "{}"}}}

    obs: Input_Obs
    input_obs_init(&obs, session, inputs[:])

    c: client.Client
    input_client_run(t, &c, loop, bound_port(&d), &obs)

    testing.expect(t, obs.is_error, "an unrenderable skill is refused")
    testing.expect_value(t, obs.code, wire.Error_Code.Unknown_Skill)
    testing.expect_value(t, len(obs.names), 0)

    input_client_stop(t, &c, &d, &obs)
}
