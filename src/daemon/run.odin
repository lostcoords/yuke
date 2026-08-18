package daemon

import "core:log"
import "core:mem"
import "core:mem/virtual"
import "core:nbio"
import "core:strings"
import "core:time"

import qjs "libs:bindings/quickjs"

import "src:daemon/catalog"
import "src:daemon/store"
import "src:js"
import "src:provider"
import "src:wire"

// The provider inference service: one shared transport client for every session's turns. Ops are
// owned by their caller, which is what lets shutdown reach a turn whose cancel fires no completion.
Run_Service :: struct {
    client:    provider.Client,
    loop:      ^nbio.Event_Loop,
    allocator: mem.Allocator,
    ready:     bool,
    stopping:  bool,

    // Ops started and not yet completed or canceled; only teardown reads it.
    live:      int,
}

// Where a caller receives one turn's output. Event strings borrow the turn arena and are
// valid only until completion; anything retained must be cloned by the sink.
Run_Sink :: struct {
    on_event: proc(user: rawptr, event: provider.Stream_Event),
    on_done:  proc(user: rawptr, result: provider.Turn_Result),
    user:     rawptr,
}

// One in-flight turn. `turn` holds a curl transfer whose address libcurl retains, so a
// live op must never move; the caller heap-owns it until completion or cancellation.
Run_Op :: struct {
    turn:    provider.Turn,
    service: ^Run_Service,
    sink:    Run_Sink,
}

run_service_init :: proc(s: ^Run_Service, loop: ^nbio.Event_Loop, allocator: mem.Allocator) -> Error {
    assert(s != nil && loop != nil, "run service init needs a service and a loop")
    assert(!s.ready, "run service initialized twice")

    if err := provider.client_init(&s.client, loop, allocator); err != .None {
        log.errorf("daemon: provider transport unavailable: %v", err)
        return .Provider_Failed
    }

    s.loop = loop
    s.allocator = allocator
    s.ready = true

    return .None
}

// Stop accepting turns. Live ops belong to their callers, so the daemon cancels those; the
// service only refuses new ones from here on.
run_service_shutdown :: proc(s: ^Run_Service) {
    assert(s != nil, "run service shutdown needs a service")

    s.stopping = true
}

// Cancel one live turn and release it. `turn_cancel` is synchronous and fires no
// completion, so the caller owes whatever terminal the turn had promised.
run_cancel :: proc(s: ^Run_Service, op: ^Run_Op) {
    assert(s != nil && op != nil, "run cancel needs a service and an op")
    assert(s.live > 0, "cancelling a turn the service does not count")

    provider.turn_cancel(&op.turn)
    s.live -= 1
    free(op, s.allocator)
}

run_service_destroy :: proc(s: ^Run_Service) {
    assert(s != nil, "run service teardown needs a service")
    assert(s.live == 0, "run service destroyed with a live turn")

    if s.ready {
        provider.client_destroy(&s.client)
        s.ready = false
    }
}

run_service_busy :: proc(s: ^Run_Service) -> bool {
    assert(s != nil, "run service busy check needs a service")

    return s.live > 0
}

// Start one turn against `connection` with an already-built body. Nil means nothing started; an op
// means exactly one `on_done` follows, and the caller owns it until then.
run_begin :: proc(s: ^Run_Service, connection: provider.Connection, body: string, sink: Run_Sink) -> ^Run_Op {
    assert(s != nil && s.ready, "a run needs an initialized service")
    assert(!s.stopping, "a run cannot start during shutdown")
    assert(sink.on_done != nil, "a run needs a completion sink")
    assert(len(body) > 0, "a run needs a built request body")

    op, alloc_err := new(Run_Op, s.allocator)
    if alloc_err != nil do return nil
    op^ = {
        service = s,
        sink    = sink,
    }
    s.live += 1

    // `turn_start` copies the body, so the caller may release it as soon as this returns.
    err := provider.turn_start(
        &op.turn,
        &s.client,
        {connection = connection, body = body},
        {on_event = run_on_event, on_done = run_on_done},
        op,
    )
    if err != .None {
        log.errorf("daemon: provider turn did not start: %v", err)
        s.live -= 1
        free(op, s.allocator)

        return nil
    }

    assert(op.turn.state == .Running, "a started run owns a running turn")

    return op
}

@(private)
run_on_event :: proc(user: rawptr, event: provider.Stream_Event) {
    op := (^Run_Op)(user)
    assert(op != nil && op.service != nil, "a run event lost its owner")

    if op.sink.on_event != nil do op.sink.on_event(op.sink.user, event)
}

// Terminal for one turn. The op is released before the sink runs, so the sink may start
// the next turn — the queued input behind this one — from inside its own completion.
@(private)
run_on_done :: proc(user: rawptr, result: provider.Turn_Result) {
    op := (^Run_Op)(user)
    assert(op != nil && op.service != nil, "a run completion lost its owner")
    assert(op.turn.state == .Done, "a run completion needs a terminal turn")

    service := op.service
    sink := op.sink

    assert(service.live > 0, "a turn completed that the service does not count")
    service.live -= 1
    free(op, service.allocator)

    sink.on_done(sink.user, result)
}

// Agent a root session's turns are attributed to.
RUN_AGENT :: "main"

@(private = "file")
RUN_DONE_RETRY_MIN :: 100 * time.Millisecond

@(private = "file")
RUN_DONE_RETRY_MAX :: 5 * time.Second

// Why a turn could not be started. Every one of these is decided before `run.started`, so a
// refusal announces nothing and leaves the transcript exactly as it was.
Run_Start_Error :: enum {
    None,

    // The session names no model, so there is nothing to resolve.
    No_Model,

    // The session's model id resolves to no catalog row.
    Unknown_Model,

    // The row resolved but its endpoint or credential would not bind.
    Unbindable,

    // A store read failed; nothing about the turn is known.
    Store_Failed,

    // The request body could not be assembled for the row's protocol.
    Build_Failed,

    // The transport refused the turn, or its announcement could not be encoded.
    Start_Failed,

    // Announced and then failed, so its own terminal already ran — drain included. The send
    // succeeded: the failure belongs to the transcript.
    Terminated,
}

@(private)
Run_Fault :: enum {
    None,
    Transcript_Limit,
    Resource,
}

// One live turn, from `run.started` to `run.done`. Owned by the daemon rather than the
// provider op: a canceled turn fires no completion, so nothing else could free it.
Run :: struct {
    daemon:              ^Daemon,
    session:             wire.Session_Id,

    // Whether the current promise join owns the commit.
    tools_joining:       bool,

    // The provider turn this run is streaming, or nil once it has completed.
    op:                  ^Run_Op,
    run_id:              wire.Run_Id,

    // Request inputs frozen for the run. The catalog row is cloned because a refresh may
    // replace the daemon's snapshot between rounds; credentials bind afresh per request.
    model:               catalog.Model,
    system_prompt:       Maybe(string),
    max_rounds:          Maybe(u64),
    rounds:              u64,
    cancel:              ^js.Run_Scope,
    cancel_signal:       qjs.Value,
    pending_done:        Maybe(wire.Run_Done_Data),
    done_retry:          ^nbio.Operation,
    done_retry_delay:    time.Duration,

    // The revision this run announced, with the model and level it names. Cloned into the
    // run's arena: the snapshot they came from dies with the request that started the turn.
    config:              wire.Run_Config,
    message_id:          wire.Message_Id,
    started_at_ms:       u64,

    // The current draft's lifetime. A run may commit several messages, so round data is
    // bulk-released after each commit instead of accumulating until `run.done`.
    round_started_at_ms: u64,
    round_arena:         virtual.Arena,
    round_allocator:     mem.Allocator,
    blocks:              [dynamic]Run_Block,
    string_bytes:        int,
    fault:               Run_Fault,
    finish:              wire.Stop_Reason,
    finish_seen:         bool,
    usage:               wire.Token_Usage,

    // Owns the request snapshot and run metadata for the run's whole life.
    arena:               virtual.Arena,
    allocator:           mem.Allocator,
    provenance:          wire.Turn_Provenance,
}

// Start one turn for `session`. Resolution and assembly run first: nothing is announced until the
// turn is certain to start, so every error here is invisible to the transcript.
run_turn_start :: proc(d: ^Daemon, session: wire.Session) -> (wire.Run_Id, Run_Start_Error) {
    assert(d != nil, "starting a turn needs daemon state")
    assert(d.store != nil, "a serving daemon always owns an event store")

    // Assembly is transcript-sized and lives only until the body is built, which
    // `turn_start` copies; nothing here outlives this proc.
    temp := virtual.arena_temp_begin(&d.turn_scratch)
    defer virtual.arena_temp_end(temp)
    sa := virtual.arena_allocator(&d.turn_scratch)

    if session.model == "" do return 0, .No_Model

    // The catalog changes only on a refresh, which cannot run while this does; the borrow
    // never outlives this proc.
    model := catalog_model_find(d, session.model)
    if model == nil do return 0, .Unknown_Model

    connection, bind_err := run_connection_build(d, model)
    if bind_err != .None {
        log.errorf("daemon: session %v cannot bind %s: %v", session.id, session.model, bind_err)

        return 0, .Unbindable
    }

    // The whole transcript the daemon can page at once. No compaction exists yet, so a
    // conversation longer than one page silently drops its oldest turns.
    messages, history_err := store.history_page(d.store, session.id, nil, wire.LIMITS.max_page_size, sa)
    if history_err != nil {
        log.errorf("daemon: session %v history read failed: %v", session.id, history_err)

        return 0, .Store_Failed
    }

    prompt, has_prompt, prompt_err := store.session_prompt_get(d.store, session.id, sa)
    if prompt_err != nil {
        log.errorf("daemon: session %v prompt read failed: %v", session.id, prompt_err)

        return 0, .Store_Failed
    }

    // Borrowed from the registry, which outlives the turn. `run_request_build` drops them
    // for a model that cannot call tools.
    session_key := ([16]u8)(session.id)
    request := provider.Request {
        messages  = messages,
        tools     = tools_definitions(d, sa),
        cache_key = string(session_key[:]),
    }

    run_prompt: Maybe(string)
    if has_prompt {
        request.system_prompt = prompt
        run_prompt = prompt
    }

    body, build_err := run_request_build(model, connection.auth, session.reasoning, request, sa, sa)
    if build_err != .None {
        log.errorf("daemon: session %v request assembly failed: %v", session.id, build_err)

        return 0, .Build_Failed
    }

    hw, hw_err := store.high_water(d.store, session.id)
    if hw_err != nil {
        log.errorf("daemon: session %v id marks read failed: %v", session.id, hw_err)

        return 0, .Store_Failed
    }

    run, run_err := run_new(d, session, hw, model, run_prompt)
    if run_err != .None do return 0, run_err

    // `config_rev` 0 means the session has announced none, and a revision no event
    // announced is one a resync cannot resolve.
    if session.config_rev == 0 {
        if perr := broadcast(d, wire.Config_Changed_Data{session_id = session.id, config = run.config});
           perr != .None {
            log.errorf("daemon: session %v could not announce its config: %v", session.id, perr)
            run_free(run)

            return 0, .Start_Failed
        }
    }

    // Allocate the live owner before making the run durable. If this created an empty
    // session slot, a pre-start failure below releases it again.
    live := session_live_ensure(d, session.id)
    if live == nil {
        run_free(run)

        return 0, .Start_Failed
    }
    assert(live.run == nil, "a session starts a turn while one is already live")

    started := wire.Run_Started_Data {
        session_id    = session.id,
        run_id        = run.run_id,
        kind          = .Turn,
        config_rev    = run.config.config_rev,
        started_at_ms = run.started_at_ms,
    }

    if perr := broadcast(d, started); perr != .None {
        log.errorf("daemon: session %v could not announce its run: %v", session.id, perr)
        run_free(run)
        session_live_release(d, session.id)

        return 0, .Start_Failed
    }

    // Durable from here on: every later failure is a terminal `run.done`, never a
    // request error, because the log already says the run began.
    live.run = run

    if !run_round_begin(run, connection, body) {
        // `run_fail` runs the terminal and releases the run, so the id is read first.
        run_id := run.run_id
        run_fail(run, .Provider, "the provider turn did not start")

        return run_id, .Terminated
    }

    return run.run_id, .None
}

// Allocate the run and mint the ids it announces. `config_rev` reuses the session's
// announced revision and only mints a new one when the session has none.
@(private = "file")
run_new :: proc(
    d: ^Daemon,
    session: wire.Session,
    hw: store.High_Water,
    model: ^catalog.Model,
    prompt: Maybe(string),
) -> (
    ^Run,
    Run_Start_Error,
) {
    run, alloc_err := new(Run, d.allocator)
    if alloc_err != nil do return nil, .Start_Failed

    run^ = {}

    if virtual.arena_init_growing(&run.arena) != nil {
        free(run, d.allocator)

        return nil, .Start_Failed
    }

    if !run_round_init(run) {
        virtual.arena_destroy(&run.arena)
        free(run, d.allocator)

        return nil, .Start_Failed
    }

    run.daemon = d
    run.session = session.id
    run.run_id = hw.run_id + 1
    run.message_id = hw.message_id + 1
    run.started_at_ms = now_ms()
    run.round_started_at_ms = run.started_at_ms
    run.allocator = virtual.arena_allocator(&run.arena)
    run.finish = .Unknown
    run.max_rounds = session.max_rounds

    // A tool's `yuke:exec` defaults to the session's workspace root. A read failure or a
    // missing row degrades to no default (the daemon's cwd) rather than failing the run.
    ws_root, ws_found, ws_err := store.workspace_root(d.store, session.workspace_id, run.allocator)
    if ws_err != nil {
        log.errorf("daemon: session %v cannot resolve workspace root: %v", session.id, ws_err)
    } else {
        assert(ws_found, "a live session's workspace row exists (enforced FK)")
    }

    signal, cancel, cancel_ok := js.cancel_signal_new(&d.js, ws_root)
    if !cancel_ok {
        virtual.arena_destroy(&run.round_arena)
        virtual.arena_destroy(&run.arena)
        free(run, d.allocator)

        return nil, .Start_Failed
    }
    run.cancel = cancel
    run.cancel_signal = signal

    provider_id, provider_err := strings.clone(model.info.provider, run.allocator)
    if provider_err != nil {
        run_free(run)

        return nil, .Start_Failed
    }

    run.model = catalog.model_clone(model^, wire.Provider_Id(provider_id), run.allocator)

    if value, has_prompt := prompt.?; has_prompt {
        owned_prompt, prompt_err := strings.clone(value, run.allocator)
        if prompt_err != nil {
            run_free(run)

            return nil, .Start_Failed
        }

        run.system_prompt = owned_prompt
    }

    // A session with no announced revision mints one; every other run reuses what
    // `config.changed` already published for the model and level the session names.
    run.config = wire.Run_Config {
        config_rev = session.config_rev if session.config_rev != 0 else hw.config_rev + 1,
        model      = strings.clone(session.model, run.allocator),
        reasoning  = strings.clone(session.reasoning, run.allocator),
    }

    // Provenance records what actually answered, which is the only correct source for
    // "which model produced this"; the config revision only records what was requested.
    run.provenance = wire.Turn_Provenance {
        protocol = model.endpoint.protocol,
        model    = strings.clone(string(model.info.id), run.allocator),
    }

    assert(run.run_id > 0, "a started run has a minted id")
    assert(run.message_id > 0, "a drafted message has a minted id")
    assert(run.config.config_rev > 0, "a run names an announced config revision")

    return run, .None
}

// Terminal for one turn: commit what the provider produced, then close the run. Runs on
// the loop thread, after the service has already released its slot.
@(private = "file")
run_on_result :: proc(user: rawptr, result: provider.Turn_Result) {
    run := (^Run)(user)
    assert(run != nil, "a turn completion lost its run")
    assert(session_live_run(run.daemon, run.session) == run, "a turn completed for a run the daemon does not own")

    // The service releases the op before calling this, so the run no longer owns one.
    run.op = nil

    if result.err != .None {
        log.errorf("daemon: session %v turn failed: %v", run.session, result.err)
        code, message := run_fault(result.err)
        run_fail(run, code, message)

        return
    }

    if run.fault != .None {
        run_fail_fault(run)

        return
    }

    if !run.finish_seen {
        run_fail(run, .Protocol, "the provider response had no terminal event")

        return
    }

    assert(run.rounds < wire.MAX_WIRE_INTEGER, "a live run stays inside the wire round range")
    run.rounds += 1

    // Tools run before the commit: a transcript carrying a pending tool part is refused by
    // every request builder, so the message that holds one must never reach the log.
    if run_tools_begin(run) do return

    if run.fault != .None {
        run_fail_fault(run)

        return
    }

    run_commit(run)
}

// Commit the current draft. A tool-call round may open the next provider request under the
// same run; every other stop, and a reached positive cap, ends it here.
@(private)
run_commit :: proc(run: ^Run) {
    assert(run != nil && run.daemon != nil, "committing a round needs its run")
    assert(run.op == nil, "a round commits after its provider operation completes")
    assert(run.round_allocator.procedure != nil, "only an announced draft can commit")
    assert(run.rounds > 0, "a committed round completed a provider request")
    assert(run_tools_open(run) == 0, "a round commits after every tool settles")

    content, alloc_err := make([]wire.Assistant_Part, len(run.blocks), run.round_allocator)
    if alloc_err != nil {
        run_fail(run, .Internal, "the turn exhausted local resources")

        return
    }
    for &block, index in run.blocks {
        content[index] = run_part_build(&block, index)
    }

    now := now_ms()
    message := wire.Assistant_Message {
        id = run.message_id,
        run_id = run.run_id,
        config_rev = run.config.config_rev,
        agent = RUN_AGENT,
        content = content,
        finish = run.finish,
        tokens = run.usage,
        time = wire.Message_Time{created_at_ms = run.round_started_at_ms, completed_at_ms = now},
        provenance = run.provenance,
    }

    committed := wire.Message_Committed_Data {
        session_id = run.session,
        message    = message,
    }

    if perr := broadcast(run.daemon, committed); perr != .None {
        log.errorf("daemon: session %v could not commit its turn: %v", run.session, perr)
        run_fail(run, .Internal, "the turn could not be committed")

        return
    }

    finish := run.finish
    continues := run_round_continues(run)
    run_round_release(run)

    if continues {
        run_round_start_next(run)

        return
    }

    run_finish(run, wire.Run_Outcome_Turn{finish = finish, rounds = run.rounds}, now)
}

// Whether this committed round owes another provider request. A provider stop alone is not
// enough: an empty tool-call stop has no result to replay and would otherwise spin forever.
@(private = "file")
run_round_continues :: proc(run: ^Run) -> bool {
    assert(run != nil, "checking a round continuation needs its run")
    assert(run.rounds > 0, "a continuation follows a completed round")

    if run.finish != .Tool_Calls do return false

    has_tool := false
    for &block in run.blocks {
        if block.kind == .Tool {
            has_tool = true

            break
        }
    }

    if !has_tool do return false

    if cap, capped := run.max_rounds.?; capped && cap > 0 && run.rounds >= cap do return false

    return true
}

// Release the committed round, rebuild canonical history, and open the next draft. The
// request body is copied by `run_begin`; all assembly storage dies on return.
@(private = "file")
run_round_start_next :: proc(run: ^Run) {
    assert(run != nil && run.daemon != nil, "continuing a round needs its run")
    assert(session_live_run(run.daemon, run.session) == run, "a continuation needs its owned live run")
    assert(run.op == nil && run.round_allocator.procedure == nil, "a continuation starts between drafts")
    assert(run_tools_open(run) == 0 && !run.tools_joining, "a continuation starts after the tool join")

    d := run.daemon
    temp := virtual.arena_temp_begin(&d.turn_scratch)
    defer virtual.arena_temp_end(temp)
    sa := virtual.arena_allocator(&d.turn_scratch)

    // The intermediate commit moved the session's message count and update mark. Announce
    // that durable state before the next provider may spend an arbitrary amount of time.
    session_summary_announce(d, run.session, sa)

    connection, bind_err := run_connection_build(d, &run.model)
    if bind_err != .None {
        log.errorf("daemon: session %v cannot bind its next provider round: %v", run.session, bind_err)
        code := wire.Run_Error_Code.Provider
        message := "the next provider round could not bind its endpoint"

        if bind_err == .Missing_Credential {
            code = .Auth
            message = "the next provider round has no usable credential"
        }

        run_fail(run, code, message)

        return
    }

    messages, history_err := store.history_page(d.store, run.session, nil, wire.LIMITS.max_page_size, sa)
    if history_err != nil {
        log.errorf("daemon: session %v next-round history read failed: %v", run.session, history_err)
        run_fail(run, .Internal, "the next provider round could not read the transcript")

        return
    }

    run_key := ([16]u8)(run.session)
    request := provider.Request {
        messages  = messages,
        tools     = tools_definitions(d, sa),
        cache_key = string(run_key[:]),
    }
    if prompt, has_prompt := run.system_prompt.?; has_prompt do request.system_prompt = prompt

    body, build_err := run_request_build(&run.model, connection.auth, run.config.reasoning, request, sa, sa)
    if build_err != .None {
        log.errorf("daemon: session %v next-round request assembly failed: %v", run.session, build_err)
        run_fail(run, .Internal, "the next provider round could not be assembled")

        return
    }

    if u64(run.message_id) >= wire.MAX_WIRE_INTEGER {
        log.errorf("daemon: session %v exhausted its message id range between rounds", run.session)
        run_fail(run, .Internal, "the turn exhausted its message id range")

        return
    }

    if !run_round_init(run) {
        run_fail(run, .Internal, "the next provider round could not allocate its draft")

        return
    }

    run.message_id += 1
    run.round_started_at_ms = now_ms()
    run.finish = .Unknown
    run.finish_seen = false
    run.fault = .None
    run.usage = {}
    if !run_round_begin(run, connection, body) do run_fail(run, .Provider, "the next provider round did not start")
}

// Announce one initialized draft, then hand its response sink to the provider transport.
// The draft comes first so every stream callback has a client-visible owner.
@(private = "file")
run_round_begin :: proc(run: ^Run, connection: provider.Connection, body: string) -> bool {
    assert(run != nil && run.daemon != nil, "starting a round needs its run")
    assert(run.op == nil, "a provider round starts once")
    assert(run.round_allocator.procedure != nil, "a provider round needs an initialized draft")

    started := wire.Message_Started_Data {
        session_id    = run.session,
        message_id    = run.message_id,
        run_id        = run.run_id,
        config_rev    = run.config.config_rev,
        agent         = RUN_AGENT,
        created_at_ms = run.round_started_at_ms,
    }
    _ = broadcast(run.daemon, started)

    // `run.started` says a run exists, not what it is doing.
    session_activity_announce(run.daemon, run.session)

    sink := Run_Sink {
        on_event = run_on_stream,
        on_done  = run_on_result,
        user     = run,
    }
    run.op = run_begin(&run.daemon.runs, connection, body, sink)

    return run.op != nil
}

// Initialize storage for one draft. The run's stable arena is deliberately separate.
@(private = "file")
run_round_init :: proc(run: ^Run) -> bool {
    assert(run != nil, "initializing a round needs its run")
    assert(run.round_allocator.procedure == nil, "a round is initialized once")
    assert(run.blocks == nil, "a new round starts without blocks")

    if virtual.arena_init_growing(&run.round_arena) != nil do return false

    run.round_allocator = virtual.arena_allocator(&run.round_arena)
    run.blocks = make([dynamic]Run_Block, run.round_allocator)
    run.string_bytes = len(RUN_AGENT)

    return true
}

// Drop the current round after every owned promise is gone. A committed broadcast has
// already encoded and persisted these bytes synchronously, so no borrower survives it.
@(private = "file")
run_round_release :: proc(run: ^Run) {
    assert(run != nil, "releasing a round needs its run")

    run_tools_release(run)

    if run.round_allocator.procedure != nil do virtual.arena_destroy(&run.round_arena)

    run.round_arena = {}
    run.round_allocator = {}
    run.blocks = nil
    run.string_bytes = 0
    run.fault = .None
    run.finish = .Unknown
    run.finish_seen = false
    run.usage = {}
}

// End a started run without a message: drop the draft every subscriber is holding, then
// record the failure durably. `run.started` is already in the log, so a terminal is owed.
@(private = "file")
run_fail :: proc(run: ^Run, code: wire.Run_Error_Code, message: string) {
    run_end(run, wire.Run_Outcome_Failed{code = code, message = message})
}

@(private)
run_fail_fault :: proc(run: ^Run) {
    assert(run != nil, "failing a faulted run needs its run")
    assert(run.fault != .None, "a run-local fault is latched before it is reported")

    if run.fault == .Transcript_Limit {
        run_fail(run, .Protocol, "the provider output exceeded transcript limits")
    } else {
        run_fail(run, .Internal, "the turn exhausted local resources")
    }
}

// Cancel the live turn. `turn_cancel` is synchronous and fires no completion, so the
// terminal that `run.started` already owes the log is emitted here or never.
run_turn_cancel :: proc(d: ^Daemon, session: wire.Session_Id) -> (wire.Run_Id, bool) {
    assert(d != nil, "canceling a turn needs daemon state")

    run := session_live_run(d, session)
    if run == nil do return 0, false

    if _, pending := run.pending_done.?; pending {
        run_id := run.run_id
        run_done_retry(run)

        return run_id, true
    }

    js.cancel_trigger(&d.js, run.cancel, run.cancel_signal)

    // A run executing tools has already released its provider op, and is still cancelable:
    // the handlers are what the turn is waiting on.
    if run.op != nil {
        run_cancel(&d.runs, run.op)
        run.op = nil
    }

    run_id := run.run_id
    run_end(run, wire.Run_Outcome_Canceled{})

    return run_id, true
}

// Close a run that committed nothing: retract the draft, log the terminal, refresh the
// index. Cancellation and failure differ only in the outcome they carry.
@(private = "file")
run_end :: proc(run: ^Run, outcome: wire.Run_Outcome) {
    if run.round_allocator.procedure != nil {
        discarded := wire.Message_Discarded_Data {
            session_id = run.session,
            message_id = run.message_id,
        }
        _ = broadcast(run.daemon, discarded)
        run_round_release(run)
    }

    run_finish(run, outcome, now_ms())
}

// Announce the run's terminal, refresh the index, and release the run. `ended_at_ms` is
// passed in so a committed turn stamps its message and its terminal from one clock read.
@(private = "file")
run_finish :: proc(run: ^Run, outcome: wire.Run_Outcome, ended_at_ms: u64) {
    done := wire.Run_Done_Data {
        session_id = run.session,
        run_id = run.run_id,
        kind = .Turn,
        timing = wire.Run_Canceled_Timing{started_at_ms = run.started_at_ms, ended_at_ms = ended_at_ms},
        outcome = wire.run_outcome_clone(outcome, run.allocator),
    }

    if perr := broadcast(run.daemon, done); perr != .None {
        log.errorf("daemon: session %v could not finish run %d: %v", run.session, run.run_id, perr)
        run.pending_done = done

        if perr == .Store_Failed do run_done_retry_schedule(run)

        return
    }

    session_summary_announce(run.daemon, run.session, run.allocator)
    run_close(run)
}

@(private = "file")
run_done_retry_schedule :: proc(run: ^Run) {
    assert(run != nil && run.daemon != nil, "scheduling a run terminal needs its run")
    assert(run.done_retry == nil, "a run terminal retry is scheduled once")
    assert(run.pending_done != nil, "a terminal retry has a retained terminal")

    if run.done_retry_delay == 0 do run.done_retry_delay = RUN_DONE_RETRY_MIN

    delay := run.done_retry_delay
    run.done_retry_delay = min(delay * 2, RUN_DONE_RETRY_MAX)
    run.done_retry = nbio.timeout_poly(delay, run, run_done_retry_on_timer, run.daemon.loop)
}

@(private = "file")
run_done_retry_on_timer :: proc(op: ^nbio.Operation, run: ^Run) {
    assert(run != nil, "a run terminal retry lost its run")
    assert(run.done_retry == op, "a run terminal retry crossed ownership")

    run.done_retry = nil
    run_done_retry(run)
}

@(private = "file")
run_done_retry :: proc(run: ^Run) {
    done, pending := run.pending_done.?
    assert(pending, "retrying a run terminal needs a retained terminal")

    if perr := broadcast(run.daemon, done); perr != .None {
        log.errorf("daemon: session %v still could not finish run %d: %v", run.session, run.run_id, perr)
        if perr == .Store_Failed && run.done_retry == nil do run_done_retry_schedule(run)

        return
    }

    run.pending_done = nil
    session_summary_announce(run.daemon, run.session, run.allocator)
    run_close(run)
}

// Release a run the daemon owns after its terminal was announced, then start whatever
// queued behind it. The session's state is dropped once it holds neither.
@(private = "file")
run_close :: proc(run: ^Run) {
    d := run.daemon
    session := run.session
    live := session_live(d, session)
    assert(live != nil && live.run == run, "a run closed for a session that does not own it")

    live.run = nil
    run_free(run)

    // The queue settles before anything is announced, so no subscriber sees an idle state
    // that a promotion replaces in the same tick.
    session_promote_next(d, session)
}

// Free the run's arena and the run itself. Announces nothing: used both after a terminal
// and on the shutdown path, where a canceled turn fires no completion of its own.
run_free :: proc(run: ^Run) {
    assert(run != nil, "freeing a run needs a run")

    run_round_release(run)

    if run.done_retry != nil {
        nbio.remove(run.done_retry)
        run.done_retry = nil
    }

    allocator := run.daemon.allocator
    js.cancel_trigger(&run.daemon.js, run.cancel, run.cancel_signal)
    qjs.free_value(run.daemon.js.ctx, run.cancel_signal)
    run.cancel_signal = {}
    run.cancel = nil
    virtual.arena_destroy(&run.arena)
    free(run, allocator)
}

// Close every run the log left unterminated, once at start. Shutdown announces nothing, so
// a clean stop leaves the same trace a kill does, and only this start can write what it owed.
runs_recover :: proc(d: ^Daemon) {
    assert(d != nil, "run recovery needs daemon state")
    assert(d.store != nil, "run recovery needs an open store")
    assert(len(d.sessions) == 0, "run recovery runs before the engine tracks anything")

    // `start` runs this after `turn_scratch` exists and before the front door accepts
    // anyone, so no turn assembly can be holding a region in it.
    temp := virtual.arena_temp_begin(&d.turn_scratch)
    defer virtual.arena_temp_end(temp)

    open, read_err := store.open_runs(d.store, virtual.arena_allocator(&d.turn_scratch))
    if read_err != nil {
        log.errorf("daemon: could not read the runs left open by the previous start: %v", read_err)

        return
    }

    now := now_ms()

    for row in open {
        done := wire.Run_Done_Data {
            session_id = row.session,
            run_id = row.run.run_id,
            kind = row.run.kind,
            timing = wire.Run_Canceled_Timing{started_at_ms = row.run.started_at_ms, ended_at_ms = now},
            outcome = wire.Run_Outcome_Failed{code = .Internal, message = "the daemon stopped during this run"},
        }

        // The append clears the marker, so a failure leaves the row for the next start.
        if perr := broadcast(d, done); perr != .None {
            log.errorf(
                "daemon: session %v could not close run %d after a restart: %v",
                row.session,
                row.run.run_id,
                perr,
            )

            continue
        }

        log.infof("daemon: session %v closed run %d left open by the previous start", row.session, row.run.run_id)
    }
}

// Cancel every live turn and release the engine state. `turn_cancel` fires no completion, so this
// is the only path that reclaims a run at shutdown, and it announces nothing.
runs_stop :: proc(d: ^Daemon) {
    assert(d != nil, "stopping runs needs daemon state")

    run_service_shutdown(&d.runs)

    for _, live in d.sessions {
        if live.run != nil {
            if live.run.op != nil do run_cancel(&d.runs, live.run.op)

            run_free(live.run)
            live.run = nil
        }

        session_live_free(d, live)
    }

    clear(&d.sessions)
}

// How a failed turn is recorded and reported. Category-shaped: the provider's own text is
// never carried here, so nothing peer-controlled reaches a bounded wire field.
@(private = "file")
run_fault :: proc(err: provider.Transport_Error) -> (wire.Run_Error_Code, string) {
    #partial switch err {
    case .Authentication_Failed:
        return .Auth, "the provider rejected this daemon's credential"

    case .Rate_Limited:
        return .Rate_Limited, "the provider rate-limited this request"

    case .Quota_Exhausted:
        return .Quota_Exhausted, "the provider account is out of quota"

    case .Network_Error:
        return .Network, "the provider could not be reached"

    case .Parse_Error:
        return .Protocol, "the provider's response could not be decoded"

    case .Invalid_Request:
        return .Provider, "the provider rejected the request as malformed"
    }

    return .Provider, "the provider failed this turn"
}

// One open assistant block and the part it folds into. Text arrives as deltas — a closed
// block carries only its terminal metadata — so the run accumulates it here.
@(private)
Run_Block :: struct {
    block_id:      provider.Stream_Block_Id,
    kind:          provider.Stream_Block_Kind,

    // The block's accumulated content: assistant text, reasoning, or a tool call's argument
    // JSON. A tool block fills this once at its terminal rather than from deltas.
    text:          strings.Builder,
    signature:     string,

    // Tool blocks only. The provider names the tool in the terminal, never at the start.
    call_id:       string,
    name:          string,

    // Nil until the call starts, which `run_part_build` reads as pending.
    tool_state:    wire.Tool_State,
    tool_started:  u64,

    // A handler's promise, owned while `tool_awaiting`. Polled rather than continued into,
    // so cancelling a run never leaves JS holding a pointer to it.
    tool_promise:  qjs.Value,
    tool_awaiting: bool,

    // Set by this block's terminal. A closed reasoning block is no longer the live phase.
    closed:        bool,
}

// What `Tool_Part.name` admits. A provider that exceeds it is not trusted to have named a
// tool we offered, but the part still has to be valid: `pump` asserts that.
@(private = "file")
TOOL_NAME_WIRE_MAX :: 128

// Fold one provider event into the draft and mirror it live. Runs on the loop thread; the
// event's strings borrow the turn arena and are copied into the run's own.
@(private)
run_on_stream :: proc(user: rawptr, event: provider.Stream_Event) {
    run := (^Run)(user)
    assert(run != nil, "a stream event lost its run")
    assert(run.daemon != nil, "a run lost its daemon")

    if run.fault != .None do return

    switch v in event {
    case provider.Stream_Block_Started:
        run_block_open(run, v)

    case provider.Stream_Text_Delta:
        run_block_fold(run, v.block_id, v.text)

    case provider.Stream_Reasoning_Delta:
        run_block_fold(run, v.block_id, v.text)

    case provider.Stream_Block_Stopped:
        run_block_close(run, v)

    case provider.Stream_Done:
        run.finish = RUN_STOP_REASON[v.reason]
        run.finish_seen = true
        run.usage = wire.Token_Usage {
            input       = v.usage.input,
            output      = v.usage.output,
            reasoning   = v.usage.reasoning,
            cache_read  = v.usage.cache_read,
            cache_write = v.usage.cache_write,
        }
    }
}

// Open one block as the next part ordinal.
@(private)
run_block_open :: proc(run: ^Run, started: provider.Stream_Block_Started) {
    if len(run.blocks) >= wire.LIMITS.max_message_parts {
        run.fault = .Transcript_Limit

        return
    }

    if _, err := append(
        &run.blocks,
        Run_Block{block_id = started.block_id, kind = started.kind, text = strings.builder_make(run.round_allocator)},
    ); err != nil {
        run.fault = .Resource

        return
    }

    index := len(run.blocks) - 1

    // A tool block announces at its terminal instead: the provider names the tool there, so
    // until then there is no part a client could render.
    if started.kind == .Tool do return

    added := wire.Message_Part_Added_Data {
        session_id = run.session,
        message_id = run.message_id,
        part       = run_part_build(&run.blocks[index], index),
    }
    _ = broadcast(run.daemon, added)

    // A block boundary is the only point inside a turn where the phase moves; deltas never
    // change it and never announce.
    session_activity_announce(run.daemon, run.session)
}

// Append `text` to its block and mirror the same bytes as a delta. `offset` is what the
// receiver already holds, so a dropped delta shows as a gap rather than corruption.
@(private = "file")
run_block_fold :: proc(run: ^Run, block_id: provider.Stream_Block_Id, text: string) {
    block, index := run_block_find(run, block_id)
    if block == nil do return

    if !run_string_add(run, len(text)) do return

    offset := u64(len(strings.to_string(block.text)))
    if strings.write_string(&block.text, text) != len(text) {
        run.fault = .Resource

        return
    }

    delta := wire.Part_Delta {
        session_id = run.session,
        message_id = run.message_id,
        part_id    = wire.Part_Id(index),
        delta      = text,
        offset     = offset,
    }
    _ = broadcast(run.daemon, wire.Message_Part_Delta_Data(delta))
}

// Close one block, keeping the terminal metadata only the reasoning arms carry.
@(private = "file")
run_block_close :: proc(run: ^Run, stopped: provider.Stream_Block_Stopped) {
    block, index := run_block_find(run, stopped.block_id)
    if block == nil do return

    was_open := !block.closed
    block.closed = true

    // Only the newest reasoning block names a phase, so closing anything else is invisible.
    if was_open && block.kind == .Reasoning && block == &run.blocks[len(run.blocks) - 1] do session_activity_announce(run.daemon, run.session)

    #partial switch result in stopped.result {
    case provider.Stream_Reasoning_Block:
        run_block_signature_set(run, block, result.signature)

    case provider.Stream_Redacted_Reasoning_Block:
        run_block_signature_set(run, block, result.data)

    case provider.Stream_Tool_Block:
        run_tool_adopt(run, block, index, result.call)
    }
}

// Adopt the completed call and announce its part. Nothing executes it yet: the part enters
// the transcript pending, which is what a client renders while a decision is outstanding.
@(private = "file")
run_tool_adopt :: proc(run: ^Run, block: ^Run_Block, index: int, call: provider.Tool_Call) {
    name := call.name

    if len(name) > TOOL_NAME_WIRE_MAX {
        log.warnf("daemon: session %v truncated a %d byte tool name", run.session, len(name))
        name = name[:utf8_floor(name, TOOL_NAME_WIRE_MAX)]
    }

    if !run_string_add(run, len(name) + len(call.id) + len(call.arguments)) {
        run_block_drop_unannounced(run, index)

        return
    }

    owned_name, name_err := strings.clone(name, run.round_allocator)
    owned_id, id_err := strings.clone(call.id, run.round_allocator)
    if name_err != nil || id_err != nil {
        run.fault = .Resource
        run_block_drop_unannounced(run, index)

        return
    }
    if strings.write_string(&block.text, call.arguments) != len(call.arguments) {
        run.fault = .Resource
        run_block_drop_unannounced(run, index)

        return
    }
    block.name = owned_name
    block.call_id = owned_id

    added := wire.Message_Part_Added_Data {
        session_id = run.session,
        message_id = run.message_id,
        part       = run_part_build(block, index),
    }
    _ = broadcast(run.daemon, added)
}

// Drop a tool block whose part was never announced: keeping an incomplete part would make a
// concurrent draft resync invalid. Neutral streams serialize blocks, so it is normally the tail.
@(private = "file")
run_block_drop_unannounced :: proc(run: ^Run, index: int) {
    assert(run != nil, "dropping an unannounced block needs its run")
    assert(index >= 0 && index < len(run.blocks), "an unannounced block has a part ordinal")

    if index == len(run.blocks) - 1 do ordered_remove(&run.blocks, index)
}

@(private = "file")
run_block_signature_set :: proc(run: ^Run, block: ^Run_Block, signature: string) {
    if !run_string_add(run, len(signature)) do return

    owned, err := strings.clone(signature, run.round_allocator)
    if err != nil {
        run.fault = .Resource

        return
    }
    block.signature = owned
}

// Reserve payload bytes before retaining provider or tool output. A fault latches for the
// round; later stream events are ignored and the valid draft prefix is discarded.
@(private)
run_string_add :: proc(run: ^Run, bytes: int) -> bool {
    assert(run != nil, "reserving draft bytes needs a run")
    assert(run.string_bytes >= len(RUN_AGENT), "draft bytes include its agent")
    assert(bytes >= 0, "draft byte growth is non-negative")

    if run.fault != .None do return false

    if bytes > wire.LIMITS.max_message_string_bytes - run.string_bytes {
        run.fault = .Transcript_Limit

        return false
    }

    run.string_bytes += bytes

    return true
}

// The largest length at or below `limit` that does not split a UTF-8 sequence.
@(private = "file")
utf8_floor :: proc(text: string, limit: int) -> int {
    end := min(limit, len(text))

    for end > 0 && end < len(text) && text[end] & 0xC0 == 0x80 {
        end -= 1
    }

    return end
}

// The open block `block_id` names and its part ordinal, or nil. Blocks are few and ordered, so a
// scan is the lookup; a provider naming an unopened block is peer data, not an invariant.
@(private = "file")
run_block_find :: proc(run: ^Run, block_id: provider.Stream_Block_Id) -> (^Run_Block, int) {
    for &block, index in run.blocks {
        if block.block_id == block_id do return &block, index
    }

    return nil, 0
}

// The wire part one block currently represents, borrowing the block's own buffer.
@(private)
run_part_build :: proc(block: ^Run_Block, index: int) -> wire.Assistant_Part {
    text := strings.to_string(block.text)
    id := wire.Part_Id(index)

    switch block.kind {
    case .Text:
        return wire.Text_Part{id = id, text = text}

    case .Reasoning:
        return wire.Reasoning_Part{id = id, text = text, signature = block.signature}

    case .Redacted_Reasoning:
        return wire.Redacted_Reasoning_Part{id = id, data = block.signature}

    case .Tool:
        call_id: Maybe(string)

        if block.call_id != "" do call_id = block.call_id

        state := block.tool_state
        if state == nil do state = wire.Tool_State_Pending{}

        return wire.Tool_Part{id = id, call_id = call_id, name = block.name, arguments = text, state = state}
    }

    unreachable()
}

// Provider and wire stop reasons are separate closed sets. Indexed by the enum, so a new provider
// reason fails the build rather than defaulting silently.
@(private = "file", rodata)
RUN_STOP_REASON := [provider.Stop_Reason]wire.Stop_Reason {
    .End_Turn       = .Stop,
    .Stop_Sequence  = .Stop,
    .Tool_Calls     = .Tool_Calls,
    .Max_Tokens     = .Length,
    .Content_Filter = .Content_Filter,
    .Unknown        = .Unknown,
}

// Start every call the draft is still waiting on; true when one is outstanding, in which case
// the join commits. Handlers are polled, never continued into, so cancelling can free the run.
run_tools_begin :: proc(run: ^Run) -> bool {
    assert(run != nil, "starting tools needs a run")
    assert(run.daemon != nil, "starting tools needs daemon state")
    assert(run.op == nil, "tools start after the provider turn releases its op")
    assert(run_tools_open(run) == 0, "a round starts with no tool outstanding")
    assert(!run.tools_joining, "a round starts before its tool join")

    d := run.daemon
    now := now_ms()

    for &block, index in run.blocks {
        if run.fault != .None do break

        if block.kind != .Tool || block.tool_state != nil do continue

        tool := tools_find(d, block.name)

        if tool == nil {
            run_tool_settle(run, &block, index, wire.Tool_State_Error{error = "unknown tool"}, 0)

            continue
        }

        block.tool_started = now
        run_tool_state_set(run, &block, index, wire.Tool_State_Running{started_at_ms = now})

        run_tool_call(run, &block, index, tool^)
    }

    // A promise can already be settled without queuing a microtask.
    run_tools_poll(run)
    if run_tools_open(run) == 0 do return false

    // Mark the join before the drain. Its hook can settle the last promise and free `run`,
    // so nothing after the drain can read through that pointer.
    run.tools_joining = true
    js.drain(&d.js)

    return true
}

// Call one handler and retain its promise until the join observes a terminal state.
@(private = "file")
run_tool_call :: proc(run: ^Run, block: ^Run_Block, index: int, tool: Daemon_Tool) {
    ctx := run.daemon.js.ctx
    assert(ctx != nil, "calling a tool needs a live context")
    assert(block.kind == .Tool, "only a tool block calls a handler")
    assert(!block.tool_awaiting, "a tool handler starts once")
    assert(index >= 0 && index < len(run.blocks), "a tool call needs its part ordinal")
    assert(qjs.is_function(ctx, tool.handler), "a registered tool retains its handler")

    arguments := strings.to_string(block.text)

    if arguments == "" do arguments = "{}"

    args := qjs.parse_json(ctx, arguments, run.round_allocator)

    if qjs.is_exception(args) {
        qjs.free_value(ctx, args)
        exception := qjs.get_exception(ctx)
        qjs.free_value(ctx, exception)
        run_tool_raise(run, block, index, "arguments were not valid JSON")

        return
    }

    argv := [2]qjs.Value{args, run.cancel_signal}
    result := js.call_value(&run.daemon.js, tool.handler, qjs.undefined(), argv[:])
    qjs.free_value(ctx, args)

    if qjs.is_exception(result) {
        qjs.free_value(ctx, result)
        run_tool_raise(run, block, index, run_tool_exception(run))

        return
    }

    if qjs.promise_state(ctx, result) == .Not_A_Promise {
        output, ok := run_tool_output(run, result)

        if ok {
            run_tool_settle(run, block, index, wire.Tool_State_Completed{output = output})
        } else {
            run_tool_raise(run, block, index, "tool output was not JSON-serializable")
        }

        qjs.free_value(ctx, result)

        return
    }

    block.tool_promise = result
    block.tool_awaiting = true
}

// Settle whatever finished since the last drain.
run_tools_poll :: proc(run: ^Run) {
    assert(run != nil, "polling tools needs a run")
    assert(run.daemon != nil, "polling tools needs daemon state")
    ctx := run.daemon.js.ctx
    assert(ctx != nil, "polling tools needs a live context")

    for &block, index in run.blocks {
        if !block.tool_awaiting do continue

        state := qjs.promise_state(ctx, block.tool_promise)

        if state == .Pending do continue

        assert(state == .Fulfilled || state == .Rejected, "an owned tool promise has a promise state")

        value := qjs.promise_result(ctx, block.tool_promise)

        if state == .Fulfilled {
            output, ok := run_tool_output(run, value)

            if ok {
                run_tool_settle(run, &block, index, wire.Tool_State_Completed{output = output})
            } else {
                run_tool_raise(run, &block, index, "tool output was not JSON-serializable")
            }
        } else {
            // `String(e)` rather than JSON: an Error serializes to an empty object, and its
            // message is the whole point.
            run_tool_settle(run, &block, index, wire.Tool_State_Error{error = run_tool_clone(run, value)})
        }

        qjs.free_value(ctx, value)
        qjs.free_value(ctx, block.tool_promise)
        block.tool_promise = {}
        block.tool_awaiting = false
    }
}

// Release any promise a canceled or failed run still owns.
run_tools_release :: proc(run: ^Run) {
    assert(run != nil, "releasing tools needs a run")
    assert(run.daemon != nil, "releasing tools needs daemon state")
    ctx := run.daemon.js.ctx
    assert(ctx != nil, "releasing tools needs a live context")

    for &block in run.blocks {
        if !block.tool_awaiting do continue

        qjs.free_value(ctx, block.tool_promise)
        block.tool_promise = {}
        block.tool_awaiting = false
    }

    run.tools_joining = false
}

run_tools_open :: proc(run: ^Run) -> int {
    assert(run != nil, "counting open tools needs a run")

    count := 0
    for &block in run.blocks {
        if block.tool_awaiting do count += 1
    }

    return count
}

// Record a terminal state and announce it. The duration is filled here so every terminal
// reports one, whichever path produced it.
@(private = "file")
run_tool_settle :: proc(
    run: ^Run,
    block: ^Run_Block,
    index: int,
    state: wire.Tool_State,
    duration_ms: Maybe(u64) = nil,
) {
    if run.fault != .None do return

    elapsed: u64

    if duration, supplied := duration_ms.?; supplied {
        elapsed = duration
    } else {
        assert(block.tool_started > 0, "a settled tool has a start time")
        elapsed = now_ms() - block.tool_started
    }

    final := state
    bytes := 0

    switch &value in final {
    case wire.Tool_State_Completed:
        bytes = len(value.output)
        value.duration_ms = elapsed

    case wire.Tool_State_Error:
        bytes = len(value.error)
        value.duration_ms = elapsed

    case wire.Tool_State_Pending,
         wire.Tool_State_Waiting_Permission,
         wire.Tool_State_Running,
         wire.Tool_State_Denied,
         wire.Tool_State_Canceled:
        assert(false, "settling a tool needs a terminal execution state")
    }

    if !run_string_add(run, bytes) do return

    run_tool_state_set(run, block, index, final)
}

@(private = "file")
run_tool_state_set :: proc(run: ^Run, block: ^Run_Block, index: int, state: wire.Tool_State) {
    assert(run != nil && run.daemon != nil, "changing a tool needs its run")
    assert(block != nil && block.kind == .Tool, "only a tool block has tool state")
    assert(index >= 0 && index < len(run.blocks), "a tool state needs its part ordinal")

    block.tool_state = state

    changed := wire.Tool_State_Changed_Data {
        session_id = run.session,
        message_id = run.message_id,
        part_id    = wire.Part_Id(index),
        state      = state,
    }
    _ = broadcast(run.daemon, changed)

    session_activity_announce(run.daemon, run.session)
}

@(private = "file")
run_tool_raise :: proc(run: ^Run, block: ^Run_Block, index: int, message: string) {
    run_tool_settle(run, block, index, wire.Tool_State_Error{error = message})
}

// The pending exception as model-facing text. Clears it, so a later entry does not inherit it.
@(private = "file")
run_tool_exception :: proc(run: ^Run) -> string {
    assert(run != nil && run.daemon != nil, "reading a tool exception needs its run")

    ctx := run.daemon.js.ctx
    assert(ctx != nil, "reading a tool exception needs a live context")

    thrown := qjs.get_exception(ctx)

    defer qjs.free_value(ctx, thrown)

    return run_tool_clone(run, thrown)
}

// A handler's value as the text the model reads: a string is its own output, anything else is JSON.
// False means conversion threw or the value has no JSON representation.
@(private = "file")
run_tool_output :: proc(run: ^Run, value: qjs.Value) -> (string, bool) {
    assert(run != nil && run.daemon != nil, "reading tool output needs its run")

    ctx := run.daemon.js.ctx
    assert(ctx != nil, "reading tool output needs a live context")

    if qjs.is_undefined(value) || qjs.is_null(value) do return "", true

    if qjs.is_string(value) do return run_tool_clone(run, value), true

    encoded := qjs.json_stringify(ctx, value)

    if qjs.is_exception(encoded) {
        qjs.free_value(ctx, encoded)
        exception := qjs.get_exception(ctx)
        qjs.free_value(ctx, exception)

        return "", false
    }

    if qjs.is_undefined(encoded) {
        qjs.free_value(ctx, encoded)

        return "", false
    }

    defer qjs.free_value(ctx, encoded)

    return run_tool_clone(run, encoded), true
}

@(private = "file")
run_tool_clone :: proc(run: ^Run, value: qjs.Value) -> string {
    assert(run != nil && run.daemon != nil, "cloning a tool value needs its run")

    ctx := run.daemon.js.ctx
    assert(ctx != nil, "cloning a tool value needs a live context")

    text, readable := qjs.to_string(ctx, value)

    if !readable {
        exception := qjs.get_exception(ctx)
        qjs.free_value(ctx, exception)

        return ""
    }

    defer qjs.free_string(ctx, text)

    cloned, err := strings.clone(text, run.round_allocator)
    if err != nil {
        run.fault = .Resource

        return ""
    }

    return cloned
}

// Loop thread, after every drain: settle what finished and commit a round that is done. The
// map is re-scanned per join because committing a turn can remove the session from it.
js_on_drain :: proc(user: rawptr) {
    d := (^Daemon)(user)
    assert(d != nil, "the daemon drain hook needs daemon state")

    for _, live in d.sessions {
        run := live.run
        if run != nil && run_tools_open(run) > 0 do run_tools_poll(run)
    }

    for {
        joined: ^Run

        for _, live in d.sessions {
            run := live.run
            if run != nil && run.tools_joining && run_tools_open(run) == 0 {
                joined = run

                break
            }
        }

        if joined == nil do return

        joined.tools_joining = false
        if joined.fault != .None {
            run_fail_fault(joined)
        } else {
            run_commit(joined)
        }
    }
}
