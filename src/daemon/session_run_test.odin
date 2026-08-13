package daemon

import "core:fmt"
import "core:nbio"
import "core:net"
import "core:testing"
import "core:time"

import http_server "libs:http/server"
import "libs:testsupport"
import client "src:client"
import store "src:daemon/store"
import wire "src:wire"

// A turn that committed no message: the draft is announced, retracted, and the terminal
// follows. Failure and cancellation announce the same sequence.
@(private = "file", rodata)
RUN_DISCARDED_NAMES := [?]wire.Broadcast_Name {
    .Input_Queued,
    .Message_Committed,
    .Session_Summary_Changed,
    .Config_Changed,
    .Run_Started,
    .Message_Started,
    .Message_Discarded,
    .Run_Done,
    .Session_Summary_Changed,
}

// Compare the broadcasts a driver recorded against the sequence the turn owes.
@(private = "file")
expect_names :: proc(t: ^testing.T, got: [dynamic]wire.Broadcast_Name, want: []wire.Broadcast_Name) {
    if !testing.expect_value(t, len(got), len(want)) {
        return
    }

    for name, index in want {
        testing.expect_value(t, got[index], name)
    }
}

// One canned Anthropic stream: a text block that arrives in two deltas, then a natural
// stop with usage. Enough to prove folding, ordering, and the terminal metadata.
@(private = "file")
RUN_FAKE_HEAD :: `data: {"type":"message_start","message":{"usage":{"input_tokens":3}}}

data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"he"}}

`

@(private = "file")
RUN_FAKE_MIDDLE :: `data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"llo"}}

`

@(private = "file")
RUN_FAKE_TAIL :: `data: {"type":"content_block_stop","index":0}

data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":2}}

data: {"type":"message_stop"}

`

@(private = "file")
RUN_FAKE_STREAM :: RUN_FAKE_HEAD + RUN_FAKE_MIDDLE + RUN_FAKE_TAIL

// A loopback provider that answers one request with `RUN_FAKE_STREAM`. The daemon binds it
// with no credential: `run_connection_build` exempts a loopback endpoint, which is what
// makes an offline end-to-end turn possible at all.
@(private = "file")
Run_Fake :: struct {
    front:  http_server.Server,

    // Response pieces written in order, `gap` apart, so the daemon decodes a stream that
    // arrives over time. A whole-response fake is the one-piece case.
    pieces: []string,
    single: [1]string,
    gap:    time.Duration,
    next:   int,

    // Accept the request and answer nothing, so the turn stays live until it is canceled.
    hold:   bool,
    gap_op: ^nbio.Operation,

    // One socket per request served. A promoted queue entry starts a second turn, so the
    // fixture answers each request in turn and closes every socket at teardown.
    socket: net.TCP_Socket,
    served: [dynamic]net.TCP_Socket,
    loop:   ^nbio.Event_Loop,
    taken:  bool,
    closed: bool,
}

@(private = "file")
run_fake_on_request :: proc(c: ^http_server.Conn, _: http_server.Request) {
    fake := (^Run_Fake)(c.server.user_data)
    assert(fake != nil, "the run fixture needs its fake")

    fake.socket, fake.loop, _ = http_server.hijack(c)
    fake.taken = true
    fake.next = 0

    // A held request is answered by nothing at all, so the turn stays live until it is
    // canceled. Only these outlive their request, so only these are closed at teardown; a
    // served socket closes itself at EOF, and closing it twice would take out whichever
    // connection the descriptor was recycled for.
    if fake.hold {
        append(&fake.served, fake.socket)

        return
    }

    run_fake_send_next(fake)
}

@(private = "file")
run_fake_send_next :: proc(fake: ^Run_Fake) {
    if fake.next >= len(fake.pieces) {
        run_fake_close(fake)

        return
    }

    piece := fake.pieces[fake.next]
    fake.next += 1
    nbio.send_poly(
        fake.socket,
        [][]byte{transmute([]byte)piece},
        fake,
        run_fake_on_sent,
        {},
        true,
        nbio.NO_TIMEOUT,
        fake.loop,
    )
}

// The stream ends at EOF, so the socket closes once the last piece is out. Pieces are
// spaced by `gap` so each one is decoded and fanned out before the next arrives. A failed
// write closes rather than stalling the test until its tick budget runs out.
@(private = "file")
run_fake_on_sent :: proc(op: ^nbio.Operation, fake: ^Run_Fake) {
    if op.send.err != nil || fake.next >= len(fake.pieces) {
        // EOF ends the stream; the socket stays open for teardown so a promoted input's
        // turn can be served on a fresh one.
        nbio.close(fake.socket, run_fake_on_closed, fake.loop)

        return
    }

    fake.gap_op = nbio.timeout_poly(fake.gap, fake, run_fake_on_gap, fake.loop)
}

@(private = "file")
run_fake_on_gap :: proc(_: ^nbio.Operation, fake: ^Run_Fake) {
    fake.gap_op = nil
    run_fake_send_next(fake)
}

@(private = "file")
run_fake_close :: proc(fake: ^Run_Fake) {
    if fake.closed || !fake.taken {
        return
    }

    fake.closed = true

    if fake.gap_op != nil {
        nbio.remove(fake.gap_op)
        fake.gap_op = nil
    }

    for socket in fake.served {
        nbio.close(socket, run_fake_on_closed, fake.loop)
    }

    clear(&fake.served)
}

@(private = "file")
run_fake_on_closed :: proc(_: ^nbio.Operation) {}

// Listen on an ephemeral loopback port and return the base URL a catalog row points at.
// `status` and `body` are the whole response, so one fixture serves both a good turn and a
// provider that refuses one.
@(private = "file")
run_fake_start :: proc(
    t: ^testing.T,
    fake: ^Run_Fake,
    loop: ^nbio.Event_Loop,
    status := "200 OK",
    content_type := "text/event-stream",
    body := RUN_FAKE_STREAM,
) -> string {
    fake.served = make([dynamic]net.TCP_Socket, context.temp_allocator)
    fake.single[0] = fmt.tprintf(
        "HTTP/1.1 %s\r\ncontent-length: %d\r\ncontent-type: %s\r\n\r\n%s",
        status,
        len(body),
        content_type,
        body,
    )
    fake.pieces = fake.single[:]

    options := http_server.Options {
        host = "127.0.0.1",
        port = 0,
    }
    testing.expect_value(
        t,
        http_server.listen(&fake.front, loop, options, run_fake_on_request, fake),
        http_server.Error.None,
    )

    return fmt.tprintf("http://127.0.0.1:%d/v1", http_server.bound_port(&fake.front))
}

@(private = "file")
run_fake_stop :: proc(t: ^testing.T, fake: ^Run_Fake) {
    run_fake_close(fake)
    http_server.shutdown(&fake.front)
    testing.expect(t, pump_tick_until(&fake.front.shutdown_complete), "the fake provider should close cleanly")
    http_server.destroy(&fake.front)
}

// A single-model catalog whose endpoint is the fake. Written as an import, which is the
// same path a models.dev refresh writes, so resolution sees an ordinary row.
@(private = "file")
run_fake_catalog :: proc(t: ^testing.T, d: ^Daemon, base_url: string) {
    item := store.Catalog_Provider {
        id = wire.Provider_Id("fake"),
        source = .Models_Dev,
        models_dev_id = "fake",
        name = "Fake",
        endpoint = {base_url = base_url, protocol = .Anthropic_Messages},
        has_endpoint = true,
        etag = `"e"`,
    }
    model := store.Catalog_Complete_Model {
        source = .Models_Dev,
        model = {
            info = {
                id = wire.Model_Id("fake/model"),
                provider = "fake",
                name = "Model",
                context_window = 1000,
                max_output_tokens = 100,
                supports_tools = true,
            },
            upstream_id = "model",
            endpoint = {base_url = base_url, protocol = .Anthropic_Messages},
            supports_temperature = true,
            reasoning_replay = .None,
            reasoning_format = .Native,
            max_tokens_field = .Max_Tokens,
        },
    }

    testing.expect_value(t, store.catalog_imported_replace(d.store, item, []store.Catalog_Model{model}), nil)
}

// Register a session that names the fake's model, since the shared fixture names one no
// catalog resolves.
@(private = "file")
run_fake_session :: proc(t: ^testing.T, d: ^Daemon, id: wire.Session_Id) {
    session := daemon_test_session(id)
    session.model = "fake/model"
    session.reasoning = ""

    _, err := store.session_create(d.store, daemon_test_workspace(), session, nil)
    testing.expect_value(t, err, nil)
}


// A daemon on a real database, a fake provider it resolves, and a driver subscribed to one
// session. The caller drives the loop; `run_env_stop` unwinds the whole stack.
@(private = "file")
Run_Env :: struct {
    d:       Daemon,
    c:       client.Client,
    obs:     Input_Obs,
    fake:    Run_Fake,
    path:    string,
    session: wire.Session_Id,
}

// `hold` leaves every request unanswered, so a started turn stays live until it is
// canceled; otherwise the fake serves `RUN_FAKE_STREAM`.
@(private = "file")
run_env_start :: proc(
    t: ^testing.T,
    env: ^Run_Env,
    name: string,
    inputs: []wire.Input,
    hold := false,
    status := "200 OK",
    content_type := "text/event-stream",
    body := RUN_FAKE_STREAM,
) {
    env.path = testsupport.sqlite_db_path(t, name)
    env.session = pump_test_session('a')

    loop := nbio.current_thread_event_loop()
    env.fake.hold = hold
    base_url := run_fake_start(t, &env.fake, loop, status, content_type, body)

    testing.expect_value(t, start(&env.d, loop, {host = "127.0.0.1", port = 0, db_path = env.path}), Error.None)
    run_fake_catalog(t, &env.d, base_url)
    run_fake_session(t, &env.d, env.session)

    input_obs_init(&env.obs, env.session, inputs)
}

// Open the driver and run until every request it owes has been answered.
@(private = "file")
run_env_drive :: proc(t: ^testing.T, env: ^Run_Env) {
    input_client_run(t, &env.c, nbio.current_thread_event_loop(), bound_port(&env.d), &env.obs)
}

@(private = "file")
run_env_stop :: proc(t: ^testing.T, env: ^Run_Env) {
    input_client_stop(t, &env.c, &env.d, &env.obs)
    run_fake_stop(t, &env.fake)
    testsupport.sqlite_db_remove(env.path)
}

// One text part, the shape every one of these tests sends.
@(private = "file")
run_env_input :: proc(text: string, parts: ^[1]wire.Content_Part, inputs: ^[1]wire.Input) -> []wire.Input {
    parts[0] = wire.Content_Text {
        text = text,
    }
    inputs[0] = wire.Input_Content {
        content = parts[:],
    }

    return inputs[:]
}

// One input drives one whole turn: the user message commits, the run is announced, the
// provider's text folds into a draft, and the draft commits as an assistant message.
@(test)
test_session_send_input_runs_a_turn :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()

    env: Run_Env
    parts: [1]wire.Content_Part
    inputs: [1]wire.Input
    run_env_start(t, &env, "session-run-turn", run_env_input("hi", &parts, &inputs))
    defer run_env_stop(t, &env)

    obs := &env.obs
    d := &env.d
    session := env.session

    run_env_drive(t, &env)

    // The send answered `started`, which it can only do once the run is announced.
    if testing.expect_value(t, len(obs.accepted), 1) && testing.expect_value(t, len(obs.runs), 1) {
        testing.expect_value(t, obs.accepted[0], wire.Input_Id(1))
        testing.expect_value(t, obs.runs[0], wire.Run_Id(1))
    }

    // The whole announced turn, in order: the input, its durable commit, the index, then
    // the run's own config, start, draft, content, commit, and terminal.
    committed := [?]wire.Broadcast_Name {
        .Input_Queued,
        .Message_Committed,
        .Session_Summary_Changed,
        .Config_Changed,
        .Run_Started,
        .Message_Started,
        .Message_Part_Added,
        .Message_Part_Delta,
        .Message_Part_Delta,
        .Message_Committed,
        .Run_Done,
        .Session_Summary_Changed,
    }
    expect_names(t, obs.names, committed[:])

    // The draft folded the provider's two deltas into one committed text part.
    if testing.expect_value(t, len(obs.assistants), 1) {
        answer := obs.assistants[0]
        testing.expect_value(t, answer.id, wire.Message_Id(2))
        testing.expect_value(t, answer.run_id, wire.Run_Id(1))
        testing.expect_value(t, answer.config_rev, wire.Config_Rev(1))
        testing.expect_value(t, answer.agent, RUN_AGENT)

        finish, finished := answer.finish.?
        testing.expect(t, finished, "a committed turn carries its stop reason")
        testing.expect_value(t, finish, wire.Stop_Reason.Stop)

        if testing.expect_value(t, len(answer.content), 1) {
            text, is_text := answer.content[0].(wire.Text_Part)
            testing.expect(t, is_text, "a text block commits as a text part")
            testing.expect_value(t, text.id, wire.Part_Id(0))
            testing.expect_value(t, text.text, "hello")
        }

        // Usage rides the terminal event, and provenance records what actually answered.
        usage, has_usage := answer.tokens.?
        testing.expect(t, has_usage, "a committed turn carries its token accounting")
        testing.expect_value(t, usage.input, u64(3))
        testing.expect_value(t, usage.output, u64(2))

        provenance, has_provenance := answer.provenance.?
        testing.expect(t, has_provenance, "a committed turn records the model that produced it")
        testing.expect_value(t, provenance.model, "fake/model")
        testing.expect_value(t, provenance.protocol, wire.Provider_Protocol.Anthropic_Messages)
    }

    // Five durable events, and every id family the turn minted advanced with them.
    hw, hw_err := store.high_water(d.store, session)
    testing.expect_value(t, hw_err, nil)
    testing.expect_value(t, hw.seq, wire.Seq(5))
    testing.expect_value(t, hw.message_id, wire.Message_Id(2))
    testing.expect_value(t, hw.run_id, wire.Run_Id(1))
    testing.expect_value(t, hw.config_rev, wire.Config_Rev(1))

    // The replica a real client folds this into ends on the same transcript: both
    // messages committed, no queued input, and no draft left open.
    testing.expect_value(t, obs.apply_err, client.Replica_Error.None)
    testing.expect_value(t, len(obs.replica.messages), 2)
    testing.expect_value(t, len(obs.replica.queued), 0)
    testing.expect(t, obs.replica.active == nil, "the committed draft is no longer active")
}

// A provider that refuses the turn still owes the transcript a terminal. The draft every
// subscriber is holding is discarded, the run ends as failed, and the user message that
// started it stays committed.
@(test)
test_session_send_input_fails_a_refused_turn :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    path := testsupport.sqlite_db_path(t, "session-run-refused")
    defer testsupport.sqlite_db_remove(path)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    // The refused turn is logged as an error, which the runner would otherwise count as a
    // test failure; the assertions below are the check.
    saved_logger := context.logger
    quiet_logger: testsupport.Assert_Only_Logger
    context.logger = testsupport.assert_only_logger(&quiet_logger, saved_logger)
    defer context.logger = saved_logger

    fake: Run_Fake
    base_url := run_fake_start(t, &fake, loop, "500 Internal Server Error", "application/json", `{"error":"nope"}`)

    session := pump_test_session('a')

    d: Daemon
    testing.expect_value(t, start(&d, loop, {host = "127.0.0.1", port = 0, db_path = path}), Error.None)
    run_fake_catalog(t, &d, base_url)
    run_fake_session(t, &d, session)

    parts := [?]wire.Content_Part{wire.Content_Text{text = "hi"}}
    inputs := [?]wire.Input{wire.Input_Content{content = parts[:]}}

    obs: Input_Obs
    input_obs_init(&obs, session, inputs[:])

    c: client.Client
    input_client_run(t, &c, loop, bound_port(&d), &obs)
    testing.expect(t, pump_tick_until(&obs.turn_done), "a refused turn still reaches run.done")
    pump_settle()

    // The run started, so the send succeeded: the failure belongs to the transcript.
    testing.expect(t, !obs.is_error, "a turn that starts and then fails answers the send successfully")
    testing.expect_value(t, len(obs.runs), 1)

    expect_names(t, obs.names, RUN_DISCARDED_NAMES[:])

    // Nothing was committed for the run, so the assistant id it drafted stays unspent.
    testing.expect_value(t, len(obs.assistants), 0)

    hw, hw_err := store.high_water(d.store, session)
    testing.expect_value(t, hw_err, nil)
    testing.expect_value(t, hw.message_id, wire.Message_Id(1))
    testing.expect_value(t, hw.run_id, wire.Run_Id(1))

    // The replica drops the draft rather than holding a message that never lands.
    testing.expect_value(t, obs.apply_err, client.Replica_Error.None)
    testing.expect_value(t, len(obs.replica.messages), 1)
    testing.expect(t, obs.replica.active == nil, "a discarded draft is no longer active")

    input_client_stop(t, &c, &d, &obs)
    run_fake_stop(t, &fake)
}

// A canceled turn owes the same terminal a failed one does: the draft is retracted and the
// run ends canceled. The provider is never given the chance to answer, so this is the
// path where nothing but the daemon can produce a terminal.
@(test)
test_session_cancel_run_ends_the_live_turn :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()

    env: Run_Env
    parts: [1]wire.Content_Part
    inputs: [1]wire.Input
    run_env_start(t, &env, "session-cancel-run", run_env_input("hi", &parts, &inputs), hold = true)
    defer run_env_stop(t, &env)
    env.obs.cancel = true

    obs := &env.obs
    d := &env.d
    session := env.session

    run_env_drive(t, &env)

    // The provider never answered, so the draft carries no content: the run goes straight
    // from its draft to a canceled terminal.
    expect_names(t, obs.names, RUN_DISCARDED_NAMES[:])

    testing.expect_value(t, len(obs.assistants), 0)

    // The user message stands and the drafted assistant id was never spent.
    hw, hw_err := store.high_water(d.store, session)
    testing.expect_value(t, hw_err, nil)
    testing.expect_value(t, hw.message_id, wire.Message_Id(1))
    testing.expect_value(t, hw.run_id, wire.Run_Id(1))

    testing.expect_value(t, obs.apply_err, client.Replica_Error.None)
    testing.expect_value(t, len(obs.replica.messages), 1)
    testing.expect(t, obs.replica.active == nil, "a canceled draft is no longer active")

    // The slot is free again: cancelling stops the turn without stopping the service.
    testing.expect(t, !run_service_busy(&d.runs), "a canceled turn releases the run slot")
}

// Cancelling when nothing runs is a success with a null run, and naming a run that is not
// the active one is the mismatch the protocol has a code for.
@(test)
test_session_cancel_run_without_an_active_run :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    path := testsupport.sqlite_db_path(t, "session-cancel-idle")
    defer testsupport.sqlite_db_remove(path)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    session := pump_test_session('a')

    d: Daemon
    testing.expect_value(t, start(&d, loop, {host = "127.0.0.1", port = 0, db_path = path}), Error.None)
    daemon_test_session_create(t, &d, session)

    // No inputs: the driver subscribes and goes straight to the cancel.
    idle: Input_Obs
    input_obs_init(&idle, session, {})
    idle.cancel = true

    c: client.Client
    input_client_run(t, &c, loop, bound_port(&d), &idle)

    testing.expect(t, !idle.is_error, "cancelling nothing is not an error")
    _, canceled := idle.canceled.canceled_run.?
    testing.expect(t, !canceled, "there was no run to cancel")
    testing.expect_value(t, len(idle.names), 0)

    input_client_stop(t, &c, &d, &idle)

    // A named run that is not current is refused rather than silently ignored.
    second: Daemon
    testing.expect_value(t, start(&second, loop, {host = "127.0.0.1", port = 0, db_path = path}), Error.None)
    named: Input_Obs
    input_obs_init(&named, session, {})
    named.cancel = true
    named.cancel_run = wire.Run_Id(7)

    other: client.Client
    input_client_run(t, &other, loop, bound_port(&second), &named)

    testing.expect(t, named.is_error, "a run that is not active cannot be canceled")
    testing.expect_value(t, named.code, wire.Error_Code.Run_Mismatch)

    input_client_stop(t, &other, &second, &named)
}

// Deltas reach the client as the provider produces them, not in one flush when the turn
// ends. The fixture writes the stream in three pieces spaced `RUN_STREAM_GAP` apart, so a
// daemon that buffered the whole response would deliver every delta at the same instant.
@(private = "file")
RUN_STREAM_GAP :: 60 * time.Millisecond

@(test)
test_session_run_streams_deltas_as_they_arrive :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    path := testsupport.sqlite_db_path(t, "session-run-stream")
    defer testsupport.sqlite_db_remove(path)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    fake: Run_Fake
    base_url := run_fake_start(t, &fake, loop)

    // The framed head carries the whole body's length; the pieces concatenate back to it.
    framed := fake.single[0]
    head := len(framed) - len(RUN_FAKE_MIDDLE) - len(RUN_FAKE_TAIL)
    pieces := [?]string{framed[:head], RUN_FAKE_MIDDLE, RUN_FAKE_TAIL}
    fake.pieces = pieces[:]
    fake.gap = RUN_STREAM_GAP

    session := pump_test_session('a')

    d: Daemon
    testing.expect_value(t, start(&d, loop, {host = "127.0.0.1", port = 0, db_path = path}), Error.None)
    run_fake_catalog(t, &d, base_url)
    run_fake_session(t, &d, session)

    parts := [?]wire.Content_Part{wire.Content_Text{text = "hi"}}
    inputs := [?]wire.Input{wire.Input_Content{content = parts[:]}}

    obs: Input_Obs
    input_obs_init(&obs, session, inputs[:])

    c: client.Client
    input_client_run(t, &c, loop, bound_port(&d), &obs)
    testing.expect(t, pump_tick_until(&obs.turn_done), "the streamed turn should reach run.done")
    pump_settle()

    first_delta := -1
    commit := -1
    for name, index in obs.names {
        if name == .Message_Part_Delta && first_delta < 0 {
            first_delta = index
        }

        // The assistant commit is the second one; the first committed the user message.
        if name == .Message_Committed {
            commit = index
        }
    }

    if !testing.expect(t, first_delta >= 0 && commit > first_delta, "a delta preceded the commit") {
        input_client_stop(t, &c, &d, &obs)
        run_fake_stop(t, &fake)

        return
    }

    // Two pieces still had to arrive after the first delta, so a buffered daemon could not
    // have produced this spread. The bound is one gap rather than two, to stay clear of
    // scheduler noise while still failing a single end-of-response flush.
    spread := obs.times[commit] - obs.times[first_delta]
    testing.expectf(
        t,
        spread >= u64(RUN_STREAM_GAP / time.Millisecond),
        "the first delta should arrive at least one gap before the commit, spread was %dms",
        spread,
    )

    // The pieces still fold into one part with the whole answer.
    if testing.expect_value(t, len(obs.assistants), 1) {
        if testing.expect_value(t, len(obs.assistants[0].content), 1) {
            text, is_text := obs.assistants[0].content[0].(wire.Text_Part)
            testing.expect(t, is_text, "the streamed block commits as a text part")
            testing.expect_value(t, text.text, "hello")
        }
    }

    input_client_stop(t, &c, &d, &obs)
    run_fake_stop(t, &fake)
}

// An input sent while a turn is running waits behind it: announced as queued, but not
// committed, because the client dequeues on the commit and the input has not run yet.
// Cancelling the turn ahead of it promotes it — it commits then, and runs.
@(test)
test_session_send_input_queues_behind_a_live_turn :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()

    first := [?]wire.Content_Part{wire.Content_Text{text = "one"}}
    second := [?]wire.Content_Part{wire.Content_Text{text = "two"}}
    inputs := [?]wire.Input{wire.Input_Content{content = first[:]}, wire.Input_Content{content = second[:]}}

    env: Run_Env
    run_env_start(t, &env, "session-queue", inputs[:], hold = true)
    defer run_env_stop(t, &env)

    obs := &env.obs
    d := &env.d
    session := env.session

    run_env_drive(t, &env)

    // The first send started a turn; the second was accepted behind it without a run.
    if testing.expect_value(t, len(obs.accepted), 2) {
        testing.expect_value(t, obs.accepted[0], wire.Input_Id(1))
        testing.expect_value(t, obs.accepted[1], wire.Input_Id(2))
    }

    testing.expect_value(t, len(obs.runs), 1)
    testing.expect_value(t, session_queue_depth(d, session), 1)

    // Only the first input has a committed user message so far.
    testing.expect_value(t, len(obs.committed), 1)
    testing.expect_value(t, obs.committed[0].input_id, wire.Input_Id(1))
    testing.expect_value(t, len(obs.queued), 2)
    testing.expect_value(t, obs.queued[1].input_id, wire.Input_Id(2))

    // Cancelling the live turn promotes the queued input: it commits and starts its own.
    canceled, stopped := run_turn_cancel(d, session)
    testing.expect(t, stopped, "the live turn cancels")
    testing.expect_value(t, canceled, wire.Run_Id(1))
    pump_settle()

    if testing.expect_value(t, len(obs.committed), 2) {
        testing.expect_value(t, obs.committed[1].input_id, wire.Input_Id(2))
        testing.expect_value(t, obs.committed[1].id, wire.Message_Id(2))
    }

    testing.expect_value(t, session_queue_depth(d, session), 0)

    // The promoted input is running, so the session still holds live state.
    promoted := session_live_run(d, session)
    if testing.expect(t, promoted != nil, "the promoted input started its own turn") {
        testing.expect_value(t, promoted.run_id, wire.Run_Id(2))
    }

    testing.expect_value(t, obs.apply_err, client.Replica_Error.None)
    testing.expect_value(t, len(obs.replica.queued), 0)
}

// A queued input can be dropped before it runs, and the turn ahead of it is untouched.
@(test)
test_session_cancel_input_drops_a_queued_input :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()

    first := [?]wire.Content_Part{wire.Content_Text{text = "one"}}
    second := [?]wire.Content_Part{wire.Content_Text{text = "two"}}
    inputs := [?]wire.Input{wire.Input_Content{content = first[:]}, wire.Input_Content{content = second[:]}}

    env: Run_Env
    run_env_start(t, &env, "session-cancel-input", inputs[:], hold = true)
    defer run_env_stop(t, &env)
    env.obs.cancel_input = wire.Input_Id(2)

    obs := &env.obs
    d := &env.d
    session := env.session

    run_env_drive(t, &env)

    // The dropped input never commits, and the running turn is left alone.
    testing.expect_value(t, len(obs.committed), 1)
    testing.expect_value(t, obs.names[len(obs.names) - 1], wire.Broadcast_Name.Input_Canceled)
    testing.expect(t, session_live_run(d, session) != nil, "the live turn survives the cancel")

    // The replica drops it too, so no client is left holding an input that never runs.
    testing.expect_value(t, obs.apply_err, client.Replica_Error.None)
    testing.expect_value(t, len(obs.replica.queued), 0)
}

// Two sessions run at once. The per-session invariant is one live turn, not one per
// daemon, so a turn in one session must not refuse or delay another's.
@(test)
test_session_run_is_concurrent_across_sessions :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    path := testsupport.sqlite_db_path(t, "session-concurrent")
    defer testsupport.sqlite_db_remove(path)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    fake: Run_Fake
    fake.hold = true
    base_url := run_fake_start(t, &fake, loop)

    alpha := pump_test_session('a')
    beta := pump_test_session('b')

    d: Daemon
    testing.expect_value(t, start(&d, loop, {host = "127.0.0.1", port = 0, db_path = path}), Error.None)
    run_fake_catalog(t, &d, base_url)
    run_fake_session(t, &d, alpha)
    run_fake_session(t, &d, beta)

    text := [?]wire.Content_Part{wire.Content_Text{text = "hi"}}
    inputs := [?]wire.Input{wire.Input_Content{content = text[:]}}

    first: Input_Obs
    input_obs_init(&first, alpha, inputs[:])
    alpha_client: client.Client
    input_client_run(t, &alpha_client, loop, bound_port(&d), &first)

    second: Input_Obs
    input_obs_init(&second, beta, inputs[:])
    beta_client: client.Client
    input_client_run(t, &beta_client, loop, bound_port(&d), &second)

    // Neither send was refused, and both sessions hold their own live turn.
    testing.expect(t, !first.is_error, "the first session started a turn")
    testing.expect(t, !second.is_error, "the second session started one too")
    testing.expect_value(t, len(first.runs), 1)
    testing.expect_value(t, len(second.runs), 1)

    alpha_run := session_live_run(&d, alpha)
    beta_run := session_live_run(&d, beta)
    testing.expect(t, alpha_run != nil && beta_run != nil, "both turns are live at once")
    testing.expect(t, alpha_run.run_id != 0 && beta_run.run_id != 0, "each turn minted its own run id")
    testing.expect_value(t, d.runs.live, 2)

    input_client_stop(t, &alpha_client, &d, &first)
    client.client_close(&beta_client)
    testing.expect(t, pump_tick_until(&second.done), "the second client should close cleanly")
    client.client_destroy(&beta_client)
    client.replica_destroy(&second.replica)
    run_fake_stop(t, &fake)
}
