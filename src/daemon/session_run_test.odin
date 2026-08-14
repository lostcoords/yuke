package daemon

import "core:fmt"
import "core:mem/virtual"
import "core:nbio"
import "core:net"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"

import sqlite "libs:bindings/sqlite"
import http_server "libs:http/server"
import "libs:testsupport"
import client "src:client"
import catalog "src:daemon/catalog"
import store "src:daemon/store"
import provider "src:provider"
import wire "src:wire"

// A turn that committed no message: the draft is announced, retracted, and the terminal
// follows. Failure and cancellation announce the same sequence. No block ever opened, so
// the only activity frames are the run going live and the run being released.
@(private = "file", rodata)
RUN_DISCARDED_NAMES := [?]wire.Broadcast_Name {
    .Input_Queued,
    .Message_Committed,
    .Session_Summary_Changed,
    .Config_Changed,
    .Run_Started,
    .Message_Started,
    .Session_Activity_Changed,
    .Message_Discarded,
    .Run_Done,
    .Session_Summary_Changed,
    .Session_Activity_Changed,
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

@(private = "file")
RUN_FAKE_UNKNOWN_STOP_STREAM ::
    RUN_FAKE_HEAD +
    RUN_FAKE_MIDDLE +
    `data: {"type":"content_block_stop","index":0}

data: {"type":"message_delta","delta":{"stop_reason":"future_reason"},"usage":{"output_tokens":2}}

data: {"type":"message_stop"}

`

// A reasoning block that opens, streams, and closes before a text block answers. Enough to
// prove the phase moves into `reasoning` and back out again.
@(private = "file")
RUN_FAKE_REASONING_STREAM :: `data: {"type":"message_start","message":{"usage":{"input_tokens":3}}}

data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}

data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"consider"}}

data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig"}}

data: {"type":"content_block_stop","index":0}

data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}

data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"hi"}}

data: {"type":"content_block_stop","index":1}

data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":2}}

data: {"type":"message_stop"}

`

// One tool call and nothing else. The block start names the tool, the arguments arrive as
// JSON fragments, and the terminal completes the call.
@(private = "file")
RUN_FAKE_TOOL_STREAM :: `data: {"type":"message_start","message":{"usage":{"input_tokens":3}}}

data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"get_weather","input":{}}}

data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"city\":"}}

data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"\"Tokyo\"}"}}

data: {"type":"content_block_stop","index":0}

data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":2}}

data: {"type":"message_stop"}

`

@(private = "file")
RUN_FAKE_TOOL_ENTRY :: `
    import { defineTool } from "yuke:daemon"

    defineTool("get_weather", {
        description: "Report the weather",
        params: { city: "string" },
        handler: async ({ city }) => ({ weather: "sunny", city }),
    })
`

// Two calls in one round. Their handlers use a barrier in the join test, so neither can
// settle unless both start before the daemon drains their promises.
@(private = "file")
RUN_FAKE_TOOL_JOIN_STREAM :: `data: {"type":"message_start","message":{"usage":{"input_tokens":3}}}

data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"first","input":{}}}

data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{}"}}

data: {"type":"content_block_stop","index":0}

data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_2","name":"second","input":{}}}

data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{}"}}

data: {"type":"content_block_stop","index":1}

data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":2}}

data: {"type":"message_stop"}

`

// A loopback provider that answers one request with `RUN_FAKE_STREAM`. The daemon binds it
// with no credential: `run_connection_build` exempts a loopback endpoint, which is what
// makes an offline end-to-end turn possible at all.
@(private = "file")
Run_Fake :: struct {
    front:          http_server.Server,

    // Response pieces written in order, `gap` apart, so the daemon decodes a stream that
    // arrives over time. A whole-response fake is the one-piece case.
    pieces:         []string,
    single:         [1]string,
    gap:            time.Duration,
    next:           int,

    // Optional whole bodies selected per request. The ordinary fixture leaves this empty
    // and serves `pieces`; a multi-round turn consumes one body for each provider request.
    responses:      []string,
    response_next:  int,
    status:         string,
    content_type:   string,
    requests:       int,
    request_bodies: [dynamic]string,

    // Accept the request and answer nothing, so the turn stays live until it is canceled.
    hold:           bool,
    hold_after:     int,
    held:           bool,
    gap_op:         ^nbio.Operation,

    // One socket per request served. A promoted queue entry starts a second turn, so the
    // fixture answers each request in turn and closes every socket at teardown.
    socket:         net.TCP_Socket,
    served:         [dynamic]net.TCP_Socket,
    loop:           ^nbio.Event_Loop,
    taken:          bool,
    closed:         bool,
}

// Body capture is only needed by the sequenced multi-round fixture. Its requests are
// serial, so the ordinary fake's single send state remains sufficient after each body ends.
@(private = "file")
Run_Fake_Body :: struct {
    fake:  ^Run_Fake,
    bytes: []byte,
    got:   int,
}

@(private = "file")
run_fake_on_request :: proc(c: ^http_server.Conn, request: http_server.Request) {
    fake := (^Run_Fake)(c.server.user_data)
    assert(fake != nil, "the run fixture needs its fake")

    if len(fake.responses) > 0 {
        assert(request.content_length > 0, "a provider request carries its JSON body")

        capture := new(Run_Fake_Body, context.temp_allocator)
        capture.fake = fake
        capture.bytes = make([]byte, int(request.content_length), context.temp_allocator)
        http_server.receive_body(c, capture, run_fake_on_body, run_fake_on_body_end)

        return
    }

    run_fake_answer(c, fake)
}

@(private = "file")
run_fake_on_body :: proc(_: ^http_server.Conn, user: rawptr, chunk: []byte) -> bool {
    capture := (^Run_Fake_Body)(user)
    assert(capture != nil && capture.fake != nil, "a fake request body needs its owner")
    assert(capture.got + len(chunk) <= len(capture.bytes), "a fake request stays inside its declared body")

    capture.got += copy(capture.bytes[capture.got:], chunk)

    return true
}

@(private = "file")
run_fake_on_body_end :: proc(c: ^http_server.Conn, user: rawptr, ok: bool) {
    capture := (^Run_Fake_Body)(user)
    assert(capture != nil && capture.fake != nil, "a fake request body completion needs its owner")
    assert(ok && capture.got == len(capture.bytes), "the fake receives the complete provider request")

    append(&capture.fake.request_bodies, string(capture.bytes))
    run_fake_answer(c, capture.fake)
}

@(private = "file")
run_fake_answer :: proc(c: ^http_server.Conn, fake: ^Run_Fake) {
    assert(fake != nil, "answering a run request needs its fake")

    if len(fake.responses) > 0 {
        assert(fake.response_next < len(fake.responses), "the fake has a response for every provider round")
        body := fake.responses[fake.response_next]
        fake.response_next += 1
        fake.single[0] = fmt.tprintf(
            "HTTP/1.1 %s\r\ncontent-length: %d\r\ncontent-type: %s\r\n\r\n%s",
            fake.status,
            len(body),
            fake.content_type,
            body,
        )
        fake.pieces = fake.single[:]
    }

    fake.requests += 1

    fake.socket, fake.loop, _ = http_server.hijack(c)
    fake.taken = true
    fake.next = 0

    // A held request is answered by nothing at all, so the turn stays live until it is
    // canceled. Only these outlive their request, so only these are closed at teardown; a
    // served socket closes itself at EOF, and closing it twice would take out whichever
    // connection the descriptor was recycled for.
    if fake.hold || fake.hold_after > 0 && fake.requests >= fake.hold_after {
        fake.held = true
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
    fake.request_bodies = make([dynamic]string, context.temp_allocator)
    fake.status = status
    fake.content_type = content_type
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
// same path a models.dev refresh writes, so the run path sees an ordinary row. The daemon
// reloads its held snapshot afterwards, since the write alone does not move it.
@(private = "file")
run_fake_catalog :: proc(t: ^testing.T, d: ^Daemon, base_url: string) {
    item := catalog.Provider {
        id = wire.Provider_Id("fake"),
        source_id = "fake",
        name = "Fake",
        endpoint = {base_url = base_url, protocol = .Anthropic_Messages},
    }
    item.models.allocator = context.temp_allocator

    _, append_err := append(
        &item.models,
        catalog.Model {
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
            thinking_format = .None,
            max_tokens_field = .Max_Tokens,
        },
    )
    testing.expect_value(t, append_err, nil)

    testing.expect_value(t, store.catalog_imported_replace(d.store, item, `"e"`), nil)
    testing.expect_value(t, catalog_state_load(d), nil)
}

// Register a session that names the fake's model, since the shared fixture names one no
// catalog resolves.
@(private = "file")
run_fake_session :: proc(t: ^testing.T, d: ^Daemon, id: wire.Session_Id, max_rounds: Maybe(u64) = nil) {
    session := daemon_test_session(id)
    session.model = "fake/model"
    session.reasoning = ""
    session.max_rounds = max_rounds

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
    js_root: string,
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
    entry := "",
    max_rounds: Maybe(u64) = nil,
    responses: []string = nil,
    hold_after := 0,
) {
    env.path = testsupport.sqlite_db_path(t, name)
    env.session = pump_test_session('a')

    loop := nbio.current_thread_event_loop()
    env.fake.hold = hold
    env.fake.hold_after = hold_after
    base_url := run_fake_start(t, &env.fake, loop, status, content_type, body)
    env.fake.responses = responses

    js_root := ""
    if entry != "" {
        js_root = test_make_dir(name)
        env.js_root = js_root

        script, join_err := filepath.join({js_root, JS_ENTRY_FILE}, context.temp_allocator)
        testing.expect(t, join_err == nil, "the entry path joins")
        testing.expect_value(t, os.write_entire_file(script, transmute([]byte)entry), nil)
    }

    testing.expect_value(
        t,
        start(&env.d, loop, {host = "127.0.0.1", port = 0, db_path = env.path, js_root = js_root}),
        Error.None,
    )
    run_fake_catalog(t, &env.d, base_url)
    run_fake_session(t, &env.d, env.session, max_rounds)

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

    if env.js_root != "" {
        os.remove_all(env.js_root)
    }
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
    // the run's own config, start, draft, content, commit, and terminal. Activity is
    // announced when the run goes live, when a block opens, when a reasoning block closes,
    // and when the queue settles — never per delta.
    committed := [?]wire.Broadcast_Name {
        .Input_Queued,
        .Message_Committed,
        .Session_Summary_Changed,
        .Config_Changed,
        .Run_Started,
        .Message_Started,
        .Session_Activity_Changed,
        .Message_Part_Added,
        .Session_Activity_Changed,
        .Message_Part_Delta,
        .Message_Part_Delta,
        .Message_Committed,
        .Run_Done,
        .Session_Summary_Changed,
        .Session_Activity_Changed,
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

// A new provider stop reason is normalized to the wire's explicit unknown value. The
// terminal event's presence, not that value, proves the stream completed.
@(test)
test_session_run_commits_an_unknown_provider_stop_reason :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()

    env: Run_Env
    parts: [1]wire.Content_Part
    inputs: [1]wire.Input
    run_env_start(
        t,
        &env,
        "session-run-unknown-stop",
        run_env_input("hi", &parts, &inputs),
        body = RUN_FAKE_UNKNOWN_STOP_STREAM,
    )
    defer run_env_stop(t, &env)

    run_env_drive(t, &env)

    if testing.expect_value(t, len(env.obs.assistants), 1) {
        finish, present := env.obs.assistants[0].finish.?
        testing.expect(t, present, "the committed turn carries its stop reason")
        testing.expect_value(t, finish, wire.Stop_Reason.Unknown)
    }
}

// A host operation can return more than one wire message may retain even when the provider
// response itself was small. The daemon discards the round before `broadcast` can assert.
@(test)
test_session_run_rejects_tool_output_beyond_wire_limits :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()

    entry := `
        import { defineTool } from "yuke:daemon"

        defineTool("get_weather", {
            description: "Return an oversized result",
            params: { city: "string" },
            handler: () => "x".repeat(1024 * 1024),
        })
    `

    env: Run_Env
    parts: [1]wire.Content_Part
    inputs: [1]wire.Input
    run_env_start(
        t,
        &env,
        "session-run-output-limit",
        run_env_input("hi", &parts, &inputs),
        body = RUN_FAKE_TOOL_STREAM,
        entry = entry,
        max_rounds = 1,
    )
    defer run_env_stop(t, &env)

    run_env_drive(t, &env)

    testing.expect_value(t, len(env.obs.assistants), 0)
    testing.expect(t, session_live_run(&env.d, env.session) == nil, "the faulted run releases its live slot")
}

// The neutral provider representation has no part-count bound. The accumulator stops at
// the wire bound before assigning an invalid ordinal; tool blocks avoid unrelated fan-out.
@(test)
test_run_block_open_enforces_wire_part_limit :: proc(t: ^testing.T) {
    run: Run
    testing.expect_value(t, virtual.arena_init_growing(&run.round_arena), nil)
    defer virtual.arena_destroy(&run.round_arena)

    run.round_allocator = virtual.arena_allocator(&run.round_arena)
    run.blocks = make([dynamic]Run_Block, run.round_allocator)

    for index in 0 ..< wire.LIMITS.max_message_parts + 1 {
        run_block_open(&run, provider.Stream_Block_Started{block_id = provider.Stream_Block_Id(index), kind = .Tool})
    }

    testing.expect_value(t, len(run.blocks), wire.LIMITS.max_message_parts)
    testing.expect_value(t, run.fault, Run_Fault.Transcript_Limit)
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

// A transient store refusal cannot make memory claim a run ended while the durable log
// still says it is open. The run retains its terminal and closes only after that append.
@(test)
test_session_run_retries_a_refused_terminal_append :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()

    saved_logger := context.logger
    quiet_logger: testsupport.Assert_Only_Logger
    context.logger = testsupport.assert_only_logger(&quiet_logger, saved_logger)
    defer context.logger = saved_logger

    env: Run_Env
    parts: [1]wire.Content_Part
    inputs: [1]wire.Input
    run_env_start(t, &env, "session-terminal-retry", run_env_input("hi", &parts, &inputs), hold = true)
    defer run_env_stop(t, &env)
    run_env_drive(t, &env)

    run := session_live_run(&env.d, env.session)
    if !testing.expect(t, run != nil, "the held provider keeps its run live") {
        return
    }

    // The store begins its own transaction for every durable event. Holding one open on
    // the same connection makes that begin fail without damaging the schema or fixtures.
    testing.expect_value(t, sqlite.txn_begin(env.d.store.writer, .Deferred), sqlite.Result.Ok)

    run_id, canceled := run_turn_cancel(&env.d, env.session)
    testing.expect(t, canceled, "the live run accepts cancellation")
    testing.expect_value(t, run_id, wire.Run_Id(1))
    _, retained := run.pending_done.?
    testing.expect(t, retained, "a refused terminal remains owned by the run")
    testing.expect(t, session_live_run(&env.d, env.session) == run, "the run cannot appear idle before its terminal")

    testing.expect_value(t, sqlite.txn_rollback(env.d.store.writer), sqlite.Result.Ok)
    testing.expect(t, testsupport.nbio_run_until(t, &env, proc(env: ^Run_Env) -> bool {
                return session_live_run(&env.d, env.session) == nil
            }, "the retained terminal retries"), "the retained terminal should commit after the store recovers")
    pump_settle()

    testing.expect(t, session_live_run(&env.d, env.session) == nil, "the committed terminal releases the run")
    testing.expect(t, env.obs.turn_done, "the retried terminal reaches subscribers")
    testing.expect_value(t, env.obs.canceled_runs, 1)
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

// Nothing but the next start can write the terminal a dead run owed: shutdown announces
// nothing. Without the sweep the log keeps an unfinished run for good.
@(test)
test_runs_recover_closes_a_run_the_previous_start_left_open :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    path := testsupport.sqlite_db_path(t, "session-run-recover")
    defer testsupport.sqlite_db_remove(path)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    session := pump_test_session('e')

    first: Daemon
    testing.expect_value(t, start(&first, loop, {host = "127.0.0.1", port = 0, db_path = path}), Error.None)
    daemon_test_session_create(t, &first, session)
    testing.expect_value(t, broadcast(&first, pump_run_started(session)), Pump_Error.None)

    // Shutdown cancels the turn and announces nothing, which is exactly how the log is
    // left mid-sentence.
    test_teardown(&first)

    second: Daemon
    testing.expect_value(t, start(&second, loop, {host = "127.0.0.1", port = 0, db_path = path}), Error.None)
    defer test_teardown(&second)

    rows := pump_events(t, second.store, session)

    if testing.expect_value(t, len(rows), 2) {
        testing.expect_value(t, rows[1].name, wire.Broadcast_Name.Run_Done)

        dec := wire.decoder_init(rows[1].payload, context.temp_allocator)
        done, derr := wire.broadcast_data_from_reader(.Run_Done, &dec)
        testing.expect_value(t, derr, wire.Validation_Error.None)

        terminal, is_done := done.(wire.Run_Done_Data)
        if testing.expect(t, is_done, "the recovery event is a run terminal") {
            testing.expect_value(t, terminal.run_id, wire.Run_Id(1))
            testing.expect_value(t, terminal.kind, wire.Run_Kind.Turn)

            failed, is_failed := terminal.outcome.(wire.Run_Outcome_Failed)
            if testing.expect(t, is_failed, "a run nothing finished ended in failure") {
                testing.expect_value(t, failed.code, wire.Run_Error_Code.Internal)
            }
        }
    }

    // The marker is cleared, so a second restart writes no second terminal.
    snapshot, _, serr := store.session_snapshot(second.store, session, context.temp_allocator)
    testing.expect_value(t, serr, nil)
    testing.expect(t, snapshot.open_run == nil, "the sweep clears what it closed")

    // Nothing is live, so the session reads back idle rather than carrying the dead run.
    _, idle := session_activity(&second, session).state.(wire.Activity_State_Idle)
    testing.expect(t, idle, "a recovered run leaves the session idle")
}

// The phases one turn moves through: only a reasoning block names a phase, so the run
// reports it while that block streams and `running` on either side.
@(test)
test_session_activity_follows_the_reasoning_block :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()

    env: Run_Env
    parts: [1]wire.Content_Part
    inputs: [1]wire.Input
    run_env_start(
        t,
        &env,
        "session-activity-phases",
        run_env_input("hi", &parts, &inputs),
        body = RUN_FAKE_REASONING_STREAM,
    )
    defer run_env_stop(t, &env)

    obs := &env.obs
    run_env_drive(t, &env)

    // Live, reasoning opens, reasoning closes, text opens, and the queue settles.
    if !testing.expect_value(t, len(obs.activities), 5) {
        return
    }

    running_ids := [?]int{0, 2, 3}
    for index in running_ids {
        state, is_running := obs.activities[index].state.(wire.Activity_State_Running)
        testing.expectf(t, is_running, "activity %d should be running", index)
        testing.expect_value(t, state.run_id, wire.Run_Id(1))
    }

    reasoning, is_reasoning := obs.activities[1].state.(wire.Activity_State_Reasoning)
    if testing.expect(t, is_reasoning, "an open reasoning block reports reasoning") {
        testing.expect_value(t, reasoning.run_id, wire.Run_Id(1))
        testing.expect_value(t, reasoning.message_id, wire.Message_Id(2))
        testing.expect_value(t, reasoning.part_id, wire.Part_Id(0))
    }

    _, is_idle := obs.activities[4].state.(wire.Activity_State_Idle)
    testing.expect(t, is_idle, "the terminal settles the session back to idle")
    testing.expect_value(t, obs.activities[4].queued, u64(0))

    // Every state that names a run carries the config that run announced.
    for activity, index in obs.activities[:4] {
        config, has_config := activity.config.?
        testing.expectf(t, has_config, "activity %d names a run, so it carries its config", index)
        testing.expect_value(t, config.model, "fake/model")
    }
}

// A client that opens a session mid-turn has only the cut: `message.started` and
// `input.queued` are live. Omitting either made the replica resync once per delta.
@(test)
test_session_resync_mid_turn_carries_the_draft_and_the_queue :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()

    first := [?]wire.Content_Part{wire.Content_Text{text = "one"}}
    second := [?]wire.Content_Part{wire.Content_Text{text = "two"}}
    inputs := [?]wire.Input{wire.Input_Content{content = first[:]}, wire.Input_Content{content = second[:]}}

    env: Run_Env
    run_env_start(t, &env, "session-resync-mid-turn", inputs[:], hold = true)
    defer run_env_stop(t, &env)

    d := &env.d
    session := env.session

    run_env_drive(t, &env)

    // The provider is holding its request, so the turn is still live at the cut.
    testing.expect(t, session_live_run(d, session) != nil, "the held turn is still live")

    cut, err := resync_build(d, {session_id = session}, context.temp_allocator)
    testing.expect_value(t, err, Resync_Error.None)
    testing.expect_value(t, wire.session_resync_result_validate(cut), wire.Validation_Error.None)

    state, running := cut.item.activity.state.(wire.Activity_State_Running)
    testing.expect(t, running, "a live turn reports running")
    testing.expect_value(t, state.run_id, wire.Run_Id(1))
    testing.expect_value(t, cut.item.activity.queued, u64(1))

    // The draft names the message the run is producing, and its parts carry the offsets
    // the next `message.part_delta` names.
    active, drafted := cut.active.?
    if testing.expect(t, drafted, "the open draft is in the cut") {
        testing.expect_value(t, active.message.id, wire.Message_Id(2))
        testing.expect_value(t, active.message.run_id, wire.Run_Id(1))
        testing.expect_value(t, active.message.config_rev, wire.Config_Rev(1))
        testing.expect_value(t, active.message.agent, RUN_AGENT)
    }

    // The waiting input is in the cut too, so a re-entered session shows a full queue.
    if testing.expect_value(t, len(cut.queued), 1) {
        testing.expect_value(t, cut.queued[0].input_id, wire.Input_Id(2))
    }

    // The draft's revision resolves against the page the same cut carries.
    if testing.expect_value(t, len(cut.configs), 1) {
        testing.expect_value(t, cut.configs[0].config_rev, wire.Config_Rev(1))
        testing.expect_value(t, cut.configs[0].model, "fake/model")
    }
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

// A call naming a tool nothing registered fails rather than committing pending: every
// request builder refuses a transcript carrying a pending tool part.
@(test)
test_session_run_fails_a_call_to_an_unregistered_tool :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()

    env: Run_Env
    parts: [1]wire.Content_Part
    inputs: [1]wire.Input
    run_env_start(
        t,
        &env,
        "session-run-tool",
        run_env_input("weather in Tokyo?", &parts, &inputs),
        body = RUN_FAKE_TOOL_STREAM,
        max_rounds = 1,
    )
    defer run_env_stop(t, &env)

    obs := &env.obs
    run_env_drive(t, &env)

    if !testing.expect_value(t, len(obs.assistants), 1) {
        return
    }

    message := obs.assistants[0]
    testing.expect_value(t, message.finish, wire.Stop_Reason.Tool_Calls)

    if !testing.expect_value(t, len(message.content), 1) {
        return
    }

    tool, is_tool := message.content[0].(wire.Tool_Part)
    if !testing.expect(t, is_tool, "the tool block commits as a tool part") {
        return
    }

    testing.expect_value(t, tool.name, "get_weather")
    testing.expect_value(t, tool.arguments, `{"city":"Tokyo"}`)

    call_id, has_call_id := tool.call_id.?
    testing.expect(t, has_call_id, "the part carries the provider's call id")
    testing.expect_value(t, call_id, "toolu_1")

    failed, is_error := tool.state.(wire.Tool_State_Error)
    testing.expect(t, is_error, "an unregistered tool cannot run")
    testing.expect_value(t, failed.message, "unknown tool")
    testing.expect_value(t, failed.duration_ms, u64(0))

    // Announced once, at the terminal that names the tool, rather than at the block start
    // where there is nothing to render.
    added := 0
    for name in obs.names {
        if name == .Message_Part_Added {
            added += 1
        }
    }

    testing.expect_value(t, added, 1)
}

// The whole round trip: yuked.js registers the tool, the model calls it, the handler awaits a
// host op, and the turn commits only once the handler's promise settles.
@(test)
test_session_run_executes_a_tool_and_commits_its_output :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()

    // `exec` proves the join runs through the drain hook: the handler cannot settle until a
    // command finishes on a worker thread, long after the provider turn completed.
    entry := `
        import { defineTool } from "yuke:daemon"
        import { exec } from "yuke:exec"

        defineTool("get_weather", {
            description: "Report the weather",
            params: { city: "string" },
            handler: async ({ city }, signal) => {
                const r = await exec("printf sunny", { signal })

                return { weather: r.stdout, city }
            },
        })
    `

    env: Run_Env
    parts: [1]wire.Content_Part
    inputs: [1]wire.Input
    run_env_start(
        t,
        &env,
        "session-run-tool-exec",
        run_env_input("weather in Tokyo?", &parts, &inputs),
        body = RUN_FAKE_TOOL_STREAM,
        entry = entry,
        max_rounds = 1,
    )
    defer run_env_stop(t, &env)

    obs := &env.obs
    run_env_drive(t, &env)

    if !testing.expect_value(t, len(obs.assistants), 1) {
        return
    }

    content := obs.assistants[0].content
    if !testing.expect_value(t, len(content), 1) {
        return
    }

    tool, is_tool := content[0].(wire.Tool_Part)
    if !testing.expect(t, is_tool, "the call commits as a tool part") {
        return
    }

    completed, is_completed := tool.state.(wire.Tool_State_Completed)
    if !testing.expect(t, is_completed, "the handler completed the call") {
        return
    }

    testing.expect_value(t, completed.output, `{"weather":"sunny","city":"Tokyo"}`)

    // Running, then completed: a client watches the call rather than only its result.
    states := 0
    for name in obs.names {
        if name == .Tool_State_Changed {
            states += 1
        }
    }

    testing.expect_value(t, states, 2)

    // The turn reported the tool it was waiting on.
    saw_running_tool := false
    for activity in obs.activities {
        if running, is_running := activity.state.(wire.Activity_State_Running_Tool); is_running {
            saw_running_tool = true
            testing.expect_value(t, running.tool_name, "get_weather")
        }
    }

    testing.expect(t, saw_running_tool, "the session reported running_tool while the handler ran")

    testing.expect_value(t, env.fake.requests, 1)
    if testing.expect_value(t, len(obs.turns), 1) {
        testing.expect_value(t, obs.turns[0].rounds, u64(1))
        testing.expect_value(t, obs.turns[0].finish, wire.Stop_Reason.Tool_Calls)
    }
}

// A zero cap is unlimited. The completed tool message lands in canonical history, the next
// request starts under the same run, and its natural stop closes the two-round turn.
@(test)
test_session_run_continues_with_tool_results :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()

    responses := [?]string{RUN_FAKE_TOOL_STREAM, RUN_FAKE_STREAM}

    env: Run_Env
    parts: [1]wire.Content_Part
    inputs: [1]wire.Input
    run_env_start(
        t,
        &env,
        "session-run-tool-results",
        run_env_input("weather in Tokyo?", &parts, &inputs),
        entry = RUN_FAKE_TOOL_ENTRY,
        max_rounds = 0,
        responses = responses[:],
    )
    defer run_env_stop(t, &env)

    obs := &env.obs
    run_env_drive(t, &env)

    testing.expect_value(t, env.fake.requests, 2)
    if testing.expect_value(t, len(env.fake.request_bodies), 2) {
        second := env.fake.request_bodies[1]
        testing.expect(
            t,
            strings.contains(second, `"type":"tool_result","tool_use_id":"toolu_1"`),
            "the next request carries the completed tool result",
        )
        testing.expect(
            t,
            strings.contains(second, `"content":"{\"weather\":\"sunny\",\"city\":\"Tokyo\"}"`),
            "the next request carries the handler output",
        )
        testing.expect(t, !strings.contains(second, `"system":`), "an absent prompt remains absent between rounds")
    }

    if !testing.expect_value(t, len(obs.assistants), 2) {
        return
    }

    tool_message := obs.assistants[0]
    testing.expect_value(t, tool_message.id, wire.Message_Id(2))
    testing.expect_value(t, tool_message.run_id, wire.Run_Id(1))
    testing.expect_value(t, tool_message.finish, wire.Stop_Reason.Tool_Calls)

    if testing.expect_value(t, len(tool_message.content), 1) {
        tool, is_tool := tool_message.content[0].(wire.Tool_Part)
        if testing.expect(t, is_tool, "the first round commits its tool call") {
            completed, is_completed := tool.state.(wire.Tool_State_Completed)
            if testing.expect(t, is_completed, "the next round receives a completed result") {
                testing.expect_value(t, completed.output, `{"weather":"sunny","city":"Tokyo"}`)
            }
        }
    }

    answer := obs.assistants[1]
    testing.expect_value(t, answer.id, wire.Message_Id(3))
    testing.expect_value(t, answer.run_id, tool_message.run_id)
    testing.expect_value(t, answer.finish, wire.Stop_Reason.Stop)

    if testing.expect_value(t, len(answer.content), 1) {
        text, is_text := answer.content[0].(wire.Text_Part)
        if testing.expect(t, is_text, "the second round commits its natural answer") {
            testing.expect_value(t, text.text, "hello")
        }
    }

    if testing.expect_value(t, len(obs.turns), 1) {
        testing.expect_value(t, obs.turns[0].rounds, u64(2))
        testing.expect_value(t, obs.turns[0].finish, wire.Stop_Reason.Stop)
    }

    starts := 0
    run_starts := 0
    run_ends := 0
    for name in obs.names {
        #partial switch name {
        case .Message_Started:
            starts += 1

        case .Run_Started:
            run_starts += 1

        case .Run_Done:
            run_ends += 1

        }
    }

    testing.expect_value(t, starts, 2)
    testing.expect_value(t, run_starts, 1)
    testing.expect_value(t, run_ends, 1)

    hw, hw_err := store.high_water(env.d.store, env.session)
    testing.expect_value(t, hw_err, nil)
    testing.expect_value(t, hw.message_id, wire.Message_Id(3))
    testing.expect_value(t, hw.run_id, wire.Run_Id(1))

    testing.expect_value(t, obs.apply_err, client.Replica_Error.None)
    testing.expect_value(t, len(obs.replica.messages), 3)
    testing.expect(t, obs.replica.active == nil, "the final round leaves no draft open")
}

// Failure in a later provider request retracts only that request's draft. The tool message
// is already durable and remains available for retry or inspection after the run terminal.
@(test)
test_session_run_failure_preserves_committed_tool_results :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()

    saved_logger := context.logger
    quiet_logger: testsupport.Assert_Only_Logger
    context.logger = testsupport.assert_only_logger(&quiet_logger, saved_logger)
    defer context.logger = saved_logger

    responses := [?]string{RUN_FAKE_TOOL_STREAM, "data: {\n\n"}

    env: Run_Env
    parts: [1]wire.Content_Part
    inputs: [1]wire.Input
    run_env_start(
        t,
        &env,
        "session-run-tool-next-fails",
        run_env_input("weather in Tokyo?", &parts, &inputs),
        entry = RUN_FAKE_TOOL_ENTRY,
        max_rounds = 0,
        responses = responses[:],
    )
    defer run_env_stop(t, &env)

    obs := &env.obs
    run_env_drive(t, &env)
    testing.expect(t, pump_tick_until(&obs.turn_done), "the failed second round should reach run.done")
    pump_settle()

    testing.expect_value(t, env.fake.requests, 2)
    testing.expect_value(t, len(obs.turns), 0)
    if testing.expect_value(t, len(obs.failures), 1) {
        testing.expect_value(t, obs.failures[0], wire.Run_Error_Code.Protocol)
    }

    if testing.expect_value(t, len(obs.assistants), 1) {
        testing.expect_value(t, obs.assistants[0].id, wire.Message_Id(2))
        testing.expect_value(t, obs.assistants[0].finish, wire.Stop_Reason.Tool_Calls)
    }

    discarded := 0
    for name in obs.names {
        if name == .Message_Discarded {
            discarded += 1
        }
    }
    testing.expect_value(t, discarded, 1)

    hw, hw_err := store.high_water(env.d.store, env.session)
    testing.expect_value(t, hw_err, nil)
    testing.expect_value(t, hw.message_id, wire.Message_Id(2))
    testing.expect_value(t, hw.run_id, wire.Run_Id(1))

    testing.expect_value(t, obs.apply_err, client.Replica_Error.None)
    testing.expect_value(t, len(obs.replica.messages), 2)
    testing.expect(t, obs.replica.active == nil, "the failed second-round draft is gone")
}

// Cancellation has the same ownership boundary as failure: the in-flight second draft is
// discarded, while the completed tool-call message from the first round remains durable.
@(test)
test_session_cancel_run_preserves_committed_tool_results :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()

    responses := [?]string{RUN_FAKE_TOOL_STREAM, RUN_FAKE_STREAM}

    env: Run_Env
    parts: [1]wire.Content_Part
    inputs: [1]wire.Input
    run_env_start(
        t,
        &env,
        "session-cancel-tool-next-round",
        run_env_input("weather in Tokyo?", &parts, &inputs),
        entry = RUN_FAKE_TOOL_ENTRY,
        max_rounds = 0,
        responses = responses[:],
        hold_after = 2,
    )
    defer run_env_stop(t, &env)

    obs := &env.obs
    run_env_drive(t, &env)

    held := testsupport.nbio_run_until(t, &env, proc(env: ^Run_Env) -> bool {
            return env.fake.held
        }, "the second provider request starts")
    if !testing.expect(t, held, "the second provider request should be held open") {
        return
    }

    run := session_live_run(&env.d, env.session)
    if testing.expect(t, run != nil, "the second round should still own the run") {
        testing.expect_value(t, run.message_id, wire.Message_Id(3))
        testing.expect(t, run.round_allocator.procedure != nil, "the second round announced its draft")
    }

    run_id, canceled := run_turn_cancel(&env.d, env.session)
    testing.expect(t, canceled, "the second provider round is cancelable")
    testing.expect_value(t, run_id, wire.Run_Id(1))
    pump_settle()

    testing.expect_value(t, env.fake.requests, 2)
    testing.expect_value(t, obs.canceled_runs, 1)
    testing.expect_value(t, len(obs.turns), 0)

    if testing.expect_value(t, len(obs.assistants), 1) {
        testing.expect_value(t, obs.assistants[0].id, wire.Message_Id(2))
        testing.expect_value(t, obs.assistants[0].finish, wire.Stop_Reason.Tool_Calls)
    }

    discarded := 0
    for name in obs.names {
        if name == .Message_Discarded {
            discarded += 1
        }
    }
    testing.expect_value(t, discarded, 1)

    hw, hw_err := store.high_water(env.d.store, env.session)
    testing.expect_value(t, hw_err, nil)
    testing.expect_value(t, hw.message_id, wire.Message_Id(2))
    testing.expect_value(t, hw.run_id, wire.Run_Id(1))

    testing.expect_value(t, obs.apply_err, client.Replica_Error.None)
    testing.expect_value(t, len(obs.replica.messages), 2)
    testing.expect(t, obs.replica.active == nil, "the canceled second-round draft is gone")
    testing.expect(t, session_live_run(&env.d, env.session) == nil, "the canceled run releases session ownership")
}

// An intermediate tool commit does not make the session idle. Queued input remains behind
// the same run until its active next round reaches a terminal, then promotion may reuse the
// discarded draft id as the queued input's durable message id.
@(test)
test_session_run_keeps_queued_input_between_rounds :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()

    first := [?]wire.Content_Part{wire.Content_Text{text = "weather in Tokyo?"}}
    second := [?]wire.Content_Part{wire.Content_Text{text = "and tomorrow?"}}
    inputs := [?]wire.Input{wire.Input_Content{content = first[:]}, wire.Input_Content{content = second[:]}}
    responses := [?]string{RUN_FAKE_TOOL_STREAM, RUN_FAKE_STREAM, RUN_FAKE_STREAM}

    env: Run_Env
    run_env_start(
        t,
        &env,
        "session-run-tool-keeps-queue",
        inputs[:],
        entry = RUN_FAKE_TOOL_ENTRY,
        max_rounds = 0,
        responses = responses[:],
        hold_after = 2,
    )
    defer run_env_stop(t, &env)

    obs := &env.obs
    run_env_drive(t, &env)

    continued := testsupport.nbio_run_until(t, &env, proc(env: ^Run_Env) -> bool {
            return env.fake.requests >= 2
        }, "the first run starts its second round")
    if !testing.expect(t, continued, "the first run should reach its held second round") {
        return
    }

    testing.expect_value(t, session_queue_depth(&env.d, env.session), 1)
    testing.expect_value(t, len(obs.committed), 1)
    testing.expect_value(t, len(obs.assistants), 1)
    testing.expect_value(t, obs.canceled_runs, 0)

    first_run := session_live_run(&env.d, env.session)
    if testing.expect(t, first_run != nil, "the intermediate commit keeps its run live") {
        testing.expect_value(t, first_run.run_id, wire.Run_Id(1))
        testing.expect_value(t, first_run.message_id, wire.Message_Id(3))
    }

    run_id, canceled := run_turn_cancel(&env.d, env.session)
    testing.expect(t, canceled, "the held continuation is cancelable")
    testing.expect_value(t, run_id, wire.Run_Id(1))

    promoted := testsupport.nbio_run_until(t, &env, proc(env: ^Run_Env) -> bool {
            return env.fake.requests >= 3
        }, "the queued input is promoted after the terminal")
    if !testing.expect(t, promoted, "the queued input should start after cancellation") {
        return
    }

    testing.expect_value(t, session_queue_depth(&env.d, env.session), 0)
    testing.expect_value(t, obs.canceled_runs, 1)
    if testing.expect_value(t, len(obs.committed), 2) {
        testing.expect_value(t, obs.committed[1].input_id, wire.Input_Id(2))
        testing.expect_value(t, obs.committed[1].id, wire.Message_Id(3))
    }

    next_run := session_live_run(&env.d, env.session)
    if testing.expect(t, next_run != nil, "the promoted input owns the session") {
        testing.expect_value(t, next_run.run_id, wire.Run_Id(2))
        testing.expect_value(t, next_run.message_id, wire.Message_Id(4))
    }

    testing.expect_value(t, obs.apply_err, client.Replica_Error.None)
    testing.expect_value(t, len(obs.replica.queued), 0)
}

// Calls in one provider round start together and commit in provider block order only after
// the last promise settles.
@(test)
test_session_run_joins_concurrent_tool_calls :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()

    entry := `
        import { defineTool } from "yuke:daemon"

        let started = 0
        let release
        const barrier = new Promise(resolve => { release = resolve })

        const join = (output, fails = false) => {
            started += 1
            if (started === 2) release()

            return barrier.then(() => {
                if (fails) throw new Error(output)

                return output
            })
        }

        defineTool("first", {
            description: "First call",
            handler: () => join("one"),
        })
        defineTool("second", {
            description: "Second call",
            handler: () => join("two failed", true),
        })
    `

    env: Run_Env
    parts: [1]wire.Content_Part
    inputs: [1]wire.Input
    run_env_start(
        t,
        &env,
        "session-run-tool-join",
        run_env_input("run both", &parts, &inputs),
        body = RUN_FAKE_TOOL_JOIN_STREAM,
        entry = entry,
        max_rounds = 1,
    )
    defer run_env_stop(t, &env)

    obs := &env.obs
    run_env_drive(t, &env)

    if !testing.expect_value(t, len(obs.assistants), 1) {
        return
    }

    content := obs.assistants[0].content
    if !testing.expect_value(t, len(content), 2) {
        return
    }

    first, first_is_tool := content[0].(wire.Tool_Part)
    if testing.expect(t, first_is_tool, "the first joined part is a tool") {
        completed, is_completed := first.state.(wire.Tool_State_Completed)
        if testing.expect(t, is_completed, "the first joined call completed") {
            testing.expect_value(t, completed.output, "one")
        }
    }

    second, second_is_tool := content[1].(wire.Tool_Part)
    if testing.expect(t, second_is_tool, "the second joined part is a tool") {
        failed, is_error := second.state.(wire.Tool_State_Error)
        if testing.expect(t, is_error, "the second joined call failed") {
            testing.expect_value(t, failed.message, "Error: two failed")
        }
    }
}

// A synchronous throw answers the model with the failure instead of stalling the turn. The
// call goes through the host entry so its deadline applies and its exception is cleared.
@(test)
test_session_run_reports_a_throwing_tool_as_an_error :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()

    entry := `
        import { defineTool } from "yuke:daemon"

        defineTool("get_weather", {
            description: "Report the weather",
            params: { city: "string" },
            handler: () => { throw new Error("no station") },
        })
    `

    env: Run_Env
    parts: [1]wire.Content_Part
    inputs: [1]wire.Input
    run_env_start(
        t,
        &env,
        "session-run-tool-throw",
        run_env_input("weather in Tokyo?", &parts, &inputs),
        body = RUN_FAKE_TOOL_STREAM,
        entry = entry,
        max_rounds = 1,
    )
    defer run_env_stop(t, &env)

    obs := &env.obs
    run_env_drive(t, &env)

    if !testing.expect_value(t, len(obs.assistants), 1) {
        return
    }

    content := obs.assistants[0].content
    if !testing.expect_value(t, len(content), 1) {
        return
    }

    tool, is_tool := content[0].(wire.Tool_Part)
    if !testing.expect(t, is_tool, "the call commits as a tool part") {
        return
    }

    failed, is_error := tool.state.(wire.Tool_State_Error)
    testing.expect(t, is_error, "a throwing handler fails its call")
    testing.expect_value(t, failed.message, "Error: no station")
}

// A turn waiting on a handler is still cancelable. It owns no provider op by then, so the
// cancel path must not assume one, and the handler's promise must be released with the run.
@(test)
test_session_cancel_run_during_a_tool_call :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()

    entry := `
        import { defineTool } from "yuke:daemon"

        defineTool("get_weather", {
            description: "Report the weather",
            params: { city: "string" },
            handler: () => new Promise(() => {}),
        })
    `

    env: Run_Env
    parts: [1]wire.Content_Part
    inputs: [1]wire.Input
    run_env_start(
        t,
        &env,
        "session-cancel-tool",
        run_env_input("weather in Tokyo?", &parts, &inputs),
        body = RUN_FAKE_TOOL_STREAM,
        entry = entry,
    )
    defer run_env_stop(t, &env)

    obs := &env.obs
    run_env_drive(t, &env)

    // Cancel only once the handler is outstanding: that is the state with no provider op.
    started := testsupport.nbio_run_until(t, &env, proc(env: ^Run_Env) -> bool {
            run := session_live_run(&env.d, env.session)

            return run != nil && run_tools_open(run) > 0
        }, "the handler starts")

    if !testing.expect(t, started, "the tool call should be outstanding") {
        return
    }

    run_id, canceled := run_turn_cancel(&env.d, env.session)
    testing.expect(t, canceled, "a turn waiting on a handler is cancelable")
    testing.expect_value(t, run_id, wire.Run_Id(1))
    pump_settle()

    // The handler never settles, so nothing may have been committed.
    testing.expect_value(t, len(obs.assistants), 0)
}

// Cancellation reaches the host job, not only the handler promise. The rejected await may
// resume script code, but omitting the signal cannot escape the daemon's cancellation latch.
@(test)
test_session_cancel_run_stops_tool_host_operations :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()

    target := "/tmp/yuke-canceled-tool-write"
    os.remove(target)
    defer os.remove(target)

    entry := `
        import { defineTool } from "yuke:daemon";
        import * as fs from "yuke:fs";
        import { exec } from "yuke:exec";

        defineTool("get_weather", {
            description: "Report the weather",
            params: { city: "string" },
            handler: async (_, signal) => {
                try { await exec("sleep 30", { signal }) } catch {}
                await fs.writeFile("/tmp/yuke-canceled-tool-write", "too late")
                return "impossible"
            },
        })
        `

    env: Run_Env
    parts: [1]wire.Content_Part
    inputs: [1]wire.Input
    run_env_start(
        t,
        &env,
        "session-cancel-tool-host-op",
        run_env_input("weather in Tokyo?", &parts, &inputs),
        body = RUN_FAKE_TOOL_STREAM,
        entry = entry,
    )
    defer run_env_stop(t, &env)

    run_env_drive(t, &env)

    started := testsupport.nbio_run_until(t, &env, proc(env: ^Run_Env) -> bool {
            run := session_live_run(&env.d, env.session)

            return run != nil && run_tools_open(run) > 0 && env.d.js.pending > 0
        }, "the command starts")
    if !testing.expect(t, started, "the host operation should be outstanding") {
        return
    }

    _, canceled := run_turn_cancel(&env.d, env.session)
    testing.expect(t, canceled, "the tool run is cancelable")

    drained := testsupport.nbio_run_until(t, &env, proc(env: ^Run_Env) -> bool {
            return env.d.js.pending == 0
        }, "the canceled command drains")
    testing.expect(t, drained, "the canceled host operation should settle")
    testing.expect(t, !os.exists(target), "post-cancel script code must not mutate files")
    testing.expect_value(t, len(env.obs.assistants), 0)
}

// The cancellation scope is the run's lifetime, not only the explicit cancel path. A tool
// cannot return synchronously and leave a signaled fire-and-forget host mutation behind it.
@(test)
test_session_completed_run_stops_unawaited_tool_host_operations :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()

    target := "/tmp/yuke-completed-tool-write"
    os.remove(target)
    defer os.remove(target)

    entry := `
        import { defineTool } from "yuke:daemon";
        import { exec } from "yuke:exec";

        defineTool("get_weather", {
            description: "Report the weather",
            params: { city: "string" },
            handler: (_, signal) => {
                exec("sleep 1; touch /tmp/yuke-completed-tool-write", { signal })
                return "sunny"
            },
        })
    `

    env: Run_Env
    parts: [1]wire.Content_Part
    inputs: [1]wire.Input
    run_env_start(
        t,
        &env,
        "session-complete-tool-host-op",
        run_env_input("weather in Tokyo?", &parts, &inputs),
        body = RUN_FAKE_TOOL_STREAM,
        entry = entry,
        max_rounds = 1,
    )
    defer run_env_stop(t, &env)

    run_env_drive(t, &env)

    testing.expect_value(t, len(env.obs.assistants), 1)
    drained := testsupport.nbio_run_until(t, &env, proc(env: ^Run_Env) -> bool {
            return env.d.js.pending == 0
        }, "the run-scoped command drains")
    testing.expect(t, drained, "the unawaited host operation should settle")
    testing.expect(t, !os.exists(target), "a completed run cannot leave a host mutation behind")
}
