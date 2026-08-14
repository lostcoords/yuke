package daemon

import "core:log"
import "core:mem"
import "core:mem/virtual"
import "core:strings"

import qjs "libs:bindings/quickjs"
import catalog "src:daemon/catalog"
import store "src:daemon/store"
import provider "src:provider"
import wire "src:wire"

// Agent a root session's turns are attributed to.
RUN_AGENT :: "main"

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

// A session's live engine state: the turn in flight and the inputs waiting behind it.
// One turn at a time per session, because two turns writing one transcript would
// interleave its sequence; different sessions run concurrently on the shared transport.
Session_Live :: struct {
    run:   ^Run,

    // Accepted inputs not yet promoted to a user message, oldest first. Their content is
    // cloned out of the frame arena, which does not survive the request that queued them.
    queue: [dynamic]wire.Queued_Input,
    arena: virtual.Arena,
}

// One live turn, from `run.started` to `run.done`. Owned by the daemon rather than the
// provider op: a canceled turn fires no completion, so nothing else could free it.
Run :: struct {
    daemon:              ^Daemon,
    session:             wire.Session_Id,

    // Tool calls still awaiting a handler, and whether their join owns the commit. The turn
    // commits when the count reaches zero.
    tools_open:          int,
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

    // The revision this run announced, with the model and level it names. Cloned into the
    // run's arena: the snapshot they came from dies with the request that started the turn.
    config:              wire.Run_Config,
    message_id:          wire.Message_Id,
    started_at_ms:       u64,

    // The current draft's lifetime. A run may commit several messages, so round data is
    // bulk-released after each commit instead of accumulating until `run.done`.
    round_started_at_ms: u64,
    draft_open:          bool,
    round_arena:         virtual.Arena,
    round_allocator:     mem.Allocator,
    blocks:              [dynamic]Run_Block,
    finish:              wire.Stop_Reason,
    usage:               wire.Token_Usage,

    // Owns the request snapshot and run metadata for the run's whole life.
    arena:               virtual.Arena,
    allocator:           mem.Allocator,
    provenance:          wire.Turn_Provenance,
}

// Start one turn for `session`, whose summary the caller already read. Resolution and
// assembly run to completion first: nothing is announced until the turn is certain to
// start, so every error here is invisible to the transcript.
run_turn_start :: proc(d: ^Daemon, session: wire.Session) -> (wire.Run_Id, Run_Start_Error) {
    assert(d != nil, "starting a turn needs daemon state")
    assert(d.store != nil, "a serving daemon always owns an event store")

    // Assembly is transcript-sized and lives only until the body is built, which
    // `turn_start` copies; nothing here outlives this proc.
    temp := virtual.arena_temp_begin(&d.turn_scratch)
    defer virtual.arena_temp_end(temp)
    sa := virtual.arena_allocator(&d.turn_scratch)

    if session.model == "" {
        return 0, .No_Model
    }

    // The catalog changes only on a refresh, which cannot run while this does; the borrow
    // never outlives this proc.
    model := catalog_model_find(d, session.model)
    if model == nil {
        return 0, .Unknown_Model
    }

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
    request := provider.Request {
        messages = messages,
        tools    = tools_definitions(d, sa),
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
    if run_err != .None {
        return 0, run_err
    }

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

        return 0, .Start_Failed
    }

    // Durable from here on: every later failure is a terminal `run.done`, never a
    // request error, because the log already says the run began.
    live := session_live_ensure(d, session.id)
    if live == nil {
        run_free(run)

        return 0, .Start_Failed
    }

    assert(live.run == nil, "a session starts a turn while one is already live")
    live.run = run

    // Live-only: a client that connects mid-turn rebuilds the draft from resync instead.
    started_draft := wire.Message_Started_Data {
        session_id    = run.session,
        message_id    = run.message_id,
        run_id        = run.run_id,
        config_rev    = run.config.config_rev,
        agent         = RUN_AGENT,
        created_at_ms = run.round_started_at_ms,
    }
    run.draft_open = true
    _ = broadcast(d, started_draft)

    // `run.started` says a run exists, not what it is doing.
    session_activity_announce(d, session.id)

    sink := Run_Sink {
        on_event = run_on_stream,
        on_done  = run_on_result,
        user     = run,
    }

    run.op = run_begin(&d.runs, connection, body, sink)
    if run.op == nil {
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
    if alloc_err != nil {
        return nil, .Start_Failed
    }

    run^ = {}

    if virtual.arena_init_growing(&run.arena) != nil {
        free(run, d.allocator)

        return nil, .Start_Failed
    }

    if virtual.arena_init_growing(&run.round_arena) != nil {
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
    run.round_allocator = virtual.arena_allocator(&run.round_arena)
    run.blocks = make([dynamic]Run_Block, run.round_allocator)
    run.finish = .Unknown
    run.max_rounds = session.max_rounds

    provider_id, provider_err := strings.clone(model.info.provider, run.allocator)
    if provider_err != nil {
        virtual.arena_destroy(&run.round_arena)
        virtual.arena_destroy(&run.arena)
        free(run, d.allocator)

        return nil, .Start_Failed
    }

    owned_model, model_err := catalog.model_clone(model^, wire.Provider_Id(provider_id), run.allocator)
    if model_err != nil {
        virtual.arena_destroy(&run.round_arena)
        virtual.arena_destroy(&run.arena)
        free(run, d.allocator)

        return nil, .Start_Failed
    }
    run.model = owned_model

    if value, has_prompt := prompt.?; has_prompt {
        owned_prompt, prompt_err := strings.clone(value, run.allocator)
        if prompt_err != nil {
            virtual.arena_destroy(&run.round_arena)
            virtual.arena_destroy(&run.arena)
            free(run, d.allocator)

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

// Fold one provider event into the draft and mirror it live. Runs on the loop thread; the
// event's strings borrow the turn arena and are copied into the run's own.
@(private = "file")
run_on_stream :: proc(user: rawptr, event: provider.Stream_Event) {
    run := (^Run)(user)
    assert(run != nil, "a stream event lost its run")
    assert(run.daemon != nil, "a run lost its daemon")

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
@(private = "file")
run_block_open :: proc(run: ^Run, started: provider.Stream_Block_Started) {
    append(
        &run.blocks,
        Run_Block{block_id = started.block_id, kind = started.kind, text = strings.builder_make(run.round_allocator)},
    )

    index := len(run.blocks) - 1

    // A tool block announces at its terminal instead: the provider names the tool there, so
    // until then there is no part a client could render.
    if started.kind == .Tool {
        return
    }

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
    if block == nil {
        return
    }

    offset := u64(len(strings.to_string(block.text)))
    strings.write_string(&block.text, text)

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
    if block == nil {
        return
    }

    was_open := !block.closed
    block.closed = true

    // Only the newest reasoning block names a phase, so closing anything else is invisible.
    if was_open && block.kind == .Reasoning && block == &run.blocks[len(run.blocks) - 1] {
        session_activity_announce(run.daemon, run.session)
    }

    #partial switch result in stopped.result {
    case provider.Stream_Reasoning_Block:
        block.signature = strings.clone(result.signature, run.round_allocator)

    case provider.Stream_Redacted_Reasoning_Block:
        block.signature = strings.clone(result.data, run.round_allocator)

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

    block.name = strings.clone(name, run.round_allocator)
    block.call_id = strings.clone(call.id, run.round_allocator)
    strings.write_string(&block.text, call.arguments)

    added := wire.Message_Part_Added_Data {
        session_id = run.session,
        message_id = run.message_id,
        part       = run_part_build(block, index),
    }
    _ = broadcast(run.daemon, added)
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

// The open block `block_id` names and its part ordinal, or nil. Blocks are few and
// ordered, so a scan is the lookup; a provider naming a block we never opened is peer
// data, not an invariant.
@(private = "file")
run_block_find :: proc(run: ^Run, block_id: provider.Stream_Block_Id) -> (^Run_Block, int) {
    for &block, index in run.blocks {
        if block.block_id == block_id {
            return &block, index
        }
    }

    return nil, 0
}

// The wire part one block currently represents, borrowing the block's own buffer.
@(private)
run_part_build :: proc(block: ^Run_Block, index: int) -> wire.Assistant_Part {
    text := strings.to_string(block.text)
    id := wire.Part_Id(index)

    #partial switch block.kind {
    case .Reasoning:
        return wire.Reasoning_Part{id = id, text = text, signature = block.signature}

    case .Redacted_Reasoning:
        return wire.Redacted_Reasoning_Part{id = id, data = block.signature}

    case .Tool:
        call_id: Maybe(string)

        if block.call_id != "" {
            call_id = block.call_id
        }

        state := block.tool_state
        if state == nil {
            state = wire.Tool_State_Pending{}
        }

        return wire.Tool_Part{id = id, call_id = call_id, name = block.name, arguments = text, state = state}
    }

    return wire.Text_Part{id = id, text = text}
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

    assert(run.finish != .Unknown, "a successful provider round carries its stop reason")
    assert(run.rounds < wire.MAX_WIRE_INTEGER, "a live run stays inside the wire round range")
    run.rounds += 1

    // Tools run before the commit: a transcript carrying a pending tool part is refused by
    // every request builder, so the message that holds one must never reach the log.
    if run_tools_begin(run) {
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
    assert(run.draft_open, "only an announced draft can commit")
    assert(run.rounds > 0, "a committed round completed a provider request")
    assert(run.tools_open == 0, "a round commits after every tool settles")

    content := make([]wire.Assistant_Part, len(run.blocks), run.round_allocator)
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

    run.draft_open = false

    if run_round_continues(run) {
        run_round_start_next(run)

        return
    }

    run_finish(run, wire.Run_Outcome_Turn{finish = run.finish, rounds = run.rounds}, now)
}

// Whether this committed round owes another provider request. A provider stop alone is not
// enough: an empty tool-call stop has no result to replay and would otherwise spin forever.
@(private = "file")
run_round_continues :: proc(run: ^Run) -> bool {
    assert(run != nil, "checking a round continuation needs its run")
    assert(run.rounds > 0, "a continuation follows a completed round")

    if run.finish != .Tool_Calls {
        return false
    }

    has_tool := false
    for &block in run.blocks {
        if block.kind == .Tool {
            has_tool = true

            break
        }
    }

    if !has_tool {
        return false
    }

    if cap, capped := run.max_rounds.?; capped && cap > 0 && run.rounds >= cap {
        return false
    }

    return true
}

// Release the committed round, rebuild canonical history, and open the next draft. The
// request body is copied by `run_begin`; all assembly storage dies on return.
@(private = "file")
run_round_start_next :: proc(run: ^Run) {
    assert(run != nil && run.daemon != nil, "continuing a round needs its run")
    assert(session_live_run(run.daemon, run.session) == run, "a continuation needs its owned live run")
    assert(run.op == nil && !run.draft_open, "a continuation starts between drafts")
    assert(run.tools_open == 0 && !run.tools_joining, "a continuation starts after the tool join")

    d := run.daemon
    run_round_release(run)

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

    request := provider.Request {
        messages = messages,
        tools    = tools_definitions(d, sa),
    }
    if prompt, has_prompt := run.system_prompt.?; has_prompt {
        request.system_prompt = prompt
    }

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
    run.usage = {}
    run.draft_open = true

    started := wire.Message_Started_Data {
        session_id    = run.session,
        message_id    = run.message_id,
        run_id        = run.run_id,
        config_rev    = run.config.config_rev,
        agent         = RUN_AGENT,
        created_at_ms = run.round_started_at_ms,
    }
    _ = broadcast(d, started)
    session_activity_announce(d, run.session)

    sink := Run_Sink {
        on_event = run_on_stream,
        on_done  = run_on_result,
        user     = run,
    }
    run.op = run_begin(&d.runs, connection, body, sink)
    if run.op == nil {
        run_fail(run, .Provider, "the next provider round did not start")
    }
}

// Initialize storage for one draft. The run's stable arena is deliberately separate.
@(private = "file")
run_round_init :: proc(run: ^Run) -> bool {
    assert(run != nil, "initializing a round needs its run")
    assert(run.round_allocator.procedure == nil, "a round is initialized once")
    assert(run.blocks == nil, "a new round starts without blocks")

    if virtual.arena_init_growing(&run.round_arena) != nil {
        return false
    }

    run.round_allocator = virtual.arena_allocator(&run.round_arena)
    run.blocks = make([dynamic]Run_Block, run.round_allocator)

    return true
}

// Drop the current round after every owned promise is gone. A committed broadcast has
// already encoded and persisted these bytes synchronously, so no borrower survives it.
@(private = "file")
run_round_release :: proc(run: ^Run) {
    assert(run != nil, "releasing a round needs its run")

    run_tools_release(run)

    if run.round_allocator.procedure != nil {
        virtual.arena_destroy(&run.round_arena)
    }

    run.round_arena = {}
    run.round_allocator = {}
    run.blocks = nil
    run.finish = .Unknown
    run.usage = {}
}

// End a started run without a message: drop the draft every subscriber is holding, then
// record the failure durably. `run.started` is already in the log, so a terminal is owed.
@(private = "file")
run_fail :: proc(run: ^Run, code: wire.Run_Error_Code, message: string) {
    run_end(run, wire.Run_Outcome_Failed{code = code, message = message})
}

// Cancel the live turn. `turn_cancel` is synchronous and fires no completion, so the
// terminal that `run.started` already owes the log is emitted here or never.
run_turn_cancel :: proc(d: ^Daemon, session: wire.Session_Id) -> (wire.Run_Id, bool) {
    assert(d != nil, "canceling a turn needs daemon state")

    run := session_live_run(d, session)
    if run == nil {
        return 0, false
    }

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
    if run.draft_open {
        discarded := wire.Message_Discarded_Data {
            session_id = run.session,
            message_id = run.message_id,
        }
        _ = broadcast(run.daemon, discarded)
        run.draft_open = false
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
        outcome = outcome,
    }
    _ = broadcast(run.daemon, done)

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

    allocator := run.daemon.allocator
    virtual.arena_destroy(&run.arena)
    free(run, allocator)
}

// Close every run the log left unterminated, once at start. Shutdown announces nothing, so
// a clean stop leaves the same trace a kill does, and only this start can write what it owed.
runs_recover :: proc(d: ^Daemon) {
    assert(d != nil, "run recovery needs daemon state")
    assert(d.store != nil, "run recovery needs an open store")
    assert(len(d.sessions) == 0, "run recovery runs before the engine tracks anything")

    scratch: virtual.Arena
    if virtual.arena_init_growing(&scratch) != nil {
        log.error("daemon: could not read the runs left open by the previous start")

        return
    }

    defer virtual.arena_destroy(&scratch)

    open, read_err := store.open_runs(d.store, virtual.arena_allocator(&scratch))
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

// Cancel every live turn and release the engine state the daemon owns. `turn_cancel` fires
// no completion, so this is the only path that reclaims a run at shutdown, and it announces
// nothing: the transport is already closing.
runs_stop :: proc(d: ^Daemon) {
    assert(d != nil, "stopping runs needs daemon state")

    run_service_shutdown(&d.runs)

    for _, live in d.sessions {
        if live.run != nil {
            if live.run.op != nil {
                run_cancel(&d.runs, live.run.op)
            }

            run_free(live.run)
            live.run = nil
        }

        session_live_free(d, live)
    }

    clear(&d.sessions)
}

// Provider stop reasons and wire stop reasons are separate closed sets; a matched stop
// sequence is a natural stop on the wire, which has no arm of its own for it. Indexed by
// the enum, so a new provider reason fails the build rather than defaulting silently.
@(private = "file", rodata)
RUN_STOP_REASON := [provider.Stop_Reason]wire.Stop_Reason {
    .End_Turn       = .Stop,
    .Stop_Sequence  = .Stop,
    .Tool_Calls     = .Tool_Calls,
    .Max_Tokens     = .Length,
    .Content_Filter = .Content_Filter,
    .Unknown        = .Unknown,
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

// --- per-session engine state ---

// The session's live state, or nil when it has neither a turn nor a queue.
session_live :: proc(d: ^Daemon, session: wire.Session_Id) -> ^Session_Live {
    assert(d != nil, "session state needs daemon state")

    return d.sessions[session] or_else nil
}

// The session's live turn, or nil.
session_live_run :: proc(d: ^Daemon, session: wire.Session_Id) -> ^Run {
    live := session_live(d, session)
    if live == nil {
        return nil
    }

    return live.run
}

// The session's live state, created empty if it has none. Nil only under allocation
// failure, which the caller reports rather than announcing a turn it cannot track.
@(private)
session_live_ensure :: proc(d: ^Daemon, session: wire.Session_Id) -> ^Session_Live {
    if existing := session_live(d, session); existing != nil {
        return existing
    }

    live, alloc_err := new(Session_Live, d.allocator)
    if alloc_err != nil {
        return nil
    }

    if virtual.arena_init_growing(&live.arena) != nil {
        free(live, d.allocator)

        return nil
    }

    live.queue = make([dynamic]wire.Queued_Input, virtual.arena_allocator(&live.arena))

    if map_insert(&d.sessions, session, live) == nil {
        session_live_free(d, live)

        return nil
    }

    return live
}

// Release one session's state. Its queue and every cloned input die with the arena.
@(private = "file")
session_live_free :: proc(d: ^Daemon, live: ^Session_Live) {
    assert(live != nil, "freeing session state needs state")
    assert(live.run == nil, "session state freed with a live turn")

    virtual.arena_destroy(&live.arena)
    free(live, d.allocator)
}

// Drop the session's state once it holds neither a turn nor a queue, so an idle daemon
// tracks nothing.
@(private = "file")
session_live_release :: proc(d: ^Daemon, session: wire.Session_Id) {
    live := session_live(d, session)
    if live == nil || live.run != nil || len(live.queue) > 0 {
        return
    }

    delete_key(&d.sessions, session)
    session_live_free(d, live)
}

// Accept an input behind the session's live turn. The content is cloned into the session's
// own arena: it was decoded into the frame arena, which is reset when the request returns.
session_queue_push :: proc(
    d: ^Daemon,
    session: wire.Session_Id,
    input_id: wire.Input_Id,
    content: []wire.Content_Part,
) -> bool {
    live := session_live(d, session)
    assert(live != nil && live.run != nil, "an input queues only behind a live turn")
    assert(len(live.queue) < wire.LIMITS.max_queued_inputs, "the queue accepted an input past its bound")

    queued := wire.Queued_Input {
        input_id     = input_id,
        content      = content,
        queued_at_ms = now_ms(),
    }
    owned := wire.queued_input_clone(queued, virtual.arena_allocator(&live.arena))

    if _, err := append(&live.queue, owned); err != nil {
        return false
    }

    session_activity_announce(d, session)

    return true
}

// How many inputs are waiting behind the session's turn.
session_queue_depth :: proc(d: ^Daemon, session: wire.Session_Id) -> int {
    live := session_live(d, session)
    if live == nil {
        return 0
    }

    return len(live.queue)
}

// The highest input id this session has handed out: the store's mark covers committed
// inputs, and the queue tail covers the ones accepted but not yet promoted.
session_input_high :: proc(d: ^Daemon, session: wire.Session_Id, mark: wire.Input_Id) -> wire.Input_Id {
    live := session_live(d, session)
    if live == nil || len(live.queue) == 0 {
        return mark
    }

    tail := live.queue[len(live.queue) - 1].input_id
    assert(tail >= mark, "a queued input predates the store's own mark")

    return tail
}

// Remove one queued input by id, for `session.cancel_input`. Its content dies with the
// session's arena, which is reclaimed when the session goes idle.
session_queue_remove :: proc(d: ^Daemon, session: wire.Session_Id, input_id: wire.Input_Id) -> bool {
    live := session_live(d, session)
    if live == nil {
        return false
    }

    for queued, index in live.queue {
        if queued.input_id == input_id {
            ordered_remove(&live.queue, index)
            session_activity_announce(d, session)

            return true
        }
    }

    return false
}

// Drop every queued input, for `cancel_run`'s `clear_queue`. Returns the ids dropped, in
// queue order, allocated in `sa` for the answer that reports them.
session_queue_clear :: proc(d: ^Daemon, session: wire.Session_Id, sa: mem.Allocator) -> []wire.Input_Id {
    live := session_live(d, session)
    if live == nil || len(live.queue) == 0 {
        return nil
    }

    cleared := make([]wire.Input_Id, len(live.queue), sa)
    for queued, index in live.queue {
        cleared[index] = queued.input_id
    }

    clear(&live.queue)
    session_activity_announce(d, session)

    return cleared
}

// Start the input at the head of the queue. Every failing path removes its entry and drains
// on, so the recursion is bounded and nothing is stranded behind a session with no turn.
@(private = "file")
session_promote_next :: proc(d: ^Daemon, session: wire.Session_Id) {
    live := session_live(d, session)
    assert(live == nil || live.run == nil, "a session promotes an input only between turns")

    // Settled: the engine holds nothing more, and this is the one place that says so.
    if live == nil || len(live.queue) == 0 {
        session_live_release(d, session)
        session_activity_announce(d, session)

        return
    }

    next := live.queue[0]
    ordered_remove(&live.queue, 0)

    scratch: virtual.Arena
    if virtual.arena_init_growing(&scratch) != nil {
        log.errorf("daemon: session %v could not promote its queued input", session)
        session_input_drop(d, session, next.input_id)
        session_promote_next(d, session)

        return
    }

    defer virtual.arena_destroy(&scratch)
    sa := virtual.arena_allocator(&scratch)

    snapshot, found, serr := store.session_snapshot(d.store, session, sa)
    if serr != nil || !found {
        log.errorf("daemon: session %v could not read the session behind its queue: %v", session, serr)
        session_input_drop(d, session, next.input_id)
        session_promote_next(d, session)

        return
    }

    hw, hw_err := store.high_water(d.store, session)
    if hw_err != nil {
        log.errorf("daemon: session %v could not read its marks to promote an input: %v", session, hw_err)
        session_input_drop(d, session, next.input_id)
        session_promote_next(d, session)

        return
    }

    // The queued input's user message commits now, not when it was accepted: the client
    // dequeues it on this commit, so committing earlier would empty the queue while the
    // input still waited.
    committed := wire.User_Message {
        id = hw.message_id + 1,
        content = next.content,
        input_id = next.input_id,
        time = wire.Created_Time{created_at_ms = now_ms()},
    }

    if perr := broadcast(d, wire.Message_Committed_Data{session_id = session, message = committed}); perr != .None {
        log.errorf("daemon: session %v could not commit its queued input: %v", session, perr)
        session_input_drop(d, session, next.input_id)
        session_promote_next(d, session)

        return
    }

    session_summary_announce(d, session, sa)

    // A refused turn keeps its committed message and drains on. `Terminated` already
    // drained, and draining again would promote behind a live turn.
    _, start_err := run_turn_start(d, snapshot.session)

    if start_err != .None && start_err != .Terminated {
        log.errorf("daemon: session %v could not run its queued input: %v", session, start_err)
        session_promote_next(d, session)
    }
}

// Retract an input promoted out of the queue but never committed, so no subscriber holds
// one that will never arrive. The caller drains on.
@(private = "file")
session_input_drop :: proc(d: ^Daemon, session: wire.Session_Id, input_id: wire.Input_Id) {
    _ = broadcast(d, wire.Input_Canceled_Data{session_id = session, input_id = input_id})
}
