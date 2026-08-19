package daemon

import "core:crypto"
import "core:log"
import "core:mem"
import "core:mem/virtual"
import "core:slice"
import "core:strconv"
import "core:strings"

import "src:daemon/store"
import "src:wire"

@(private = "file")
Queued_Input_Owned :: struct {
    arena: mem.Dynamic_Arena,
    input: wire.Queued_Input,
}

// A session's live engine state. One turn at a time, because two turns writing one transcript
// would interleave its sequence; different sessions run concurrently.
Session_Live :: struct {
    run:   ^Run,

    // Accepted inputs not yet promoted to a user message, oldest first. Their content is
    // cloned out of the frame arena, which does not survive the request that queued them.
    queue: [dynamic]Queued_Input_Owned,
}

// The session's live state, or nil when it has neither a turn nor a queue.
session_live :: proc(d: ^Daemon, session: wire.Session_Id) -> ^Session_Live {
    assert(d != nil, "session state needs daemon state")

    return d.sessions[session] or_else nil
}

// The session's live turn, or nil.
session_live_run :: proc(d: ^Daemon, session: wire.Session_Id) -> ^Run {
    live := session_live(d, session)
    if live == nil do return nil

    return live.run
}

// The session's live state, created empty if it has none. Nil only under allocation
// failure, which the caller reports rather than announcing a turn it cannot track.
@(private)
session_live_ensure :: proc(d: ^Daemon, session: wire.Session_Id) -> ^Session_Live {
    if existing := session_live(d, session); existing != nil do return existing

    live, alloc_err := new(Session_Live, d.allocator)
    if alloc_err != nil do return nil

    live.queue = make([dynamic]Queued_Input_Owned, d.allocator)

    if map_insert(&d.sessions, session, live) == nil {
        session_live_free(d, live)

        return nil
    }

    return live
}

// Release one session's state and every independently owned queued input.
@(private)
session_live_free :: proc(d: ^Daemon, live: ^Session_Live) {
    assert(live != nil, "freeing session state needs state")
    assert(live.run == nil, "session state freed with a live turn")

    for &queued in live.queue {
        queued_input_owned_destroy(&queued)
    }
    delete(live.queue)
    free(live, d.allocator)
}

// Drop the session's state once it holds neither a turn nor a queue, so an idle daemon
// tracks nothing.
@(private)
session_live_release :: proc(d: ^Daemon, session: wire.Session_Id) {
    live := session_live(d, session)
    if live == nil || live.run != nil || len(live.queue) > 0 do return

    delete_key(&d.sessions, session)
    session_live_free(d, live)
}

// Accept an input behind the session's live turn. The content is cloned into the session's
// own arena: it was decoded into the frame arena, which is reset when the request returns.
session_queue_push :: proc(d: ^Daemon, session: wire.Session_Id, queued: wire.Queued_Input) -> bool {
    live := session_live(d, session)
    assert(live != nil && live.run != nil, "an input queues only behind a live turn")
    assert(len(live.queue) < wire.LIMITS.max_queued_inputs, "the queue accepted an input past its bound")

    owned := queued_input_owned_clone(queued, d.allocator)

    if _, err := append(&live.queue, owned); err != nil {
        queued_input_owned_destroy(&owned)

        return false
    }

    session_activity_announce(d, session)

    return true
}

// How many inputs are waiting behind the session's turn.
session_queue_depth :: proc(d: ^Daemon, session: wire.Session_Id) -> int {
    live := session_live(d, session)
    if live == nil do return 0

    return len(live.queue)
}

// The highest input id this session has handed out: the store's mark covers committed
// inputs, and the queue tail covers the ones accepted but not yet promoted.
session_input_high :: proc(d: ^Daemon, session: wire.Session_Id, mark: wire.Input_Id) -> wire.Input_Id {
    live := session_live(d, session)
    if live == nil || len(live.queue) == 0 do return mark

    tail := live.queue[len(live.queue) - 1].input.input_id
    assert(tail >= mark, "a queued input predates the store's own mark")

    return tail
}

// Remove one queued input by id, for `session.cancel_input`. Its content dies with the
// session's arena, which is reclaimed when the session goes idle.
session_queue_remove :: proc(d: ^Daemon, session: wire.Session_Id, input_id: wire.Input_Id) -> bool {
    live := session_live(d, session)
    if live == nil do return false

    for &queued, index in live.queue {
        if queued.input.input_id == input_id {
            queued_input_owned_destroy(&queued)
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
    if live == nil || len(live.queue) == 0 do return nil

    cleared := make([]wire.Input_Id, len(live.queue), sa)
    for &queued, index in live.queue {
        cleared[index] = queued.input.input_id
        queued_input_owned_destroy(&queued)
    }

    clear(&live.queue)
    session_activity_announce(d, session)

    return cleared
}

// What promoting one queued input decided.
@(private = "file")
Promote_Outcome :: enum {
    // A turn is live, or a terminal already drained the queue: this drain is finished.
    Settled,

    // The input committed but its turn was refused. The message stands; drain on.
    Refused,

    // Nothing committed. The caller retracts the input and drains on.
    Failed,
}

// Drain the queue, one input at a time. A loop rather than a recursion, so a run of failing
// inputs releases each arena before taking the next.
@(private)
session_promote_next :: proc(d: ^Daemon, session: wire.Session_Id) {
    for {
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
        input_id := next.input.input_id
        outcome := session_promote_one(d, session, next.input)
        queued_input_owned_destroy(&next)

        switch outcome {
        case .Settled:
            return

        case .Failed:
            session_input_drop(d, session, input_id)

        case .Refused:
        }
    }
}

// Commit one promoted input as a user message and start its turn. Its storage is released
// before returning, so a failing drain holds one input's memory at a time.
@(private = "file")
session_promote_one :: proc(d: ^Daemon, session: wire.Session_Id, input: wire.Queued_Input) -> Promote_Outcome {
    scratch: virtual.Arena
    if virtual.arena_init_growing(&scratch) != nil {
        log.errorf("daemon: session %v could not promote its queued input", session)

        return .Failed
    }

    defer virtual.arena_destroy(&scratch)
    sa := virtual.arena_allocator(&scratch)

    snapshot, found, serr := store.session_snapshot(d.store, session, sa)
    if serr != nil || !found {
        log.errorf("daemon: session %v could not read the session behind its queue: %v", session, serr)

        return .Failed
    }

    hw, hw_err := store.high_water(d.store, session)
    if hw_err != nil {
        log.errorf("daemon: session %v could not read its marks to promote an input: %v", session, hw_err)

        return .Failed
    }

    // The user message commits on promotion, not on acceptance: the client dequeues on this commit,
    // so committing earlier would empty the queue while the input still waited.
    committed := wire.User_Message {
        id = hw.message_id + 1,
        content = input.content,
        input_id = input.input_id,
        time = wire.Created_Time{created_at_ms = now_ms()},
    }

    if perr := broadcast(d, wire.Message_Committed_Data{session_id = session, message = committed}); perr != .None {
        log.errorf("daemon: session %v could not commit its queued input: %v", session, perr)

        return .Failed
    }

    session_summary_announce(d, session, sa)

    // A refused turn keeps its committed message and drains on. `Terminated` already
    // drained, and draining again would promote behind a live turn.
    _, start_err := run_turn_start(d, snapshot.session)

    if start_err == .None || start_err == .Terminated do return .Settled

    log.errorf("daemon: session %v could not run its queued input: %v", session, start_err)

    return .Refused
}

@(private = "file")
queued_input_owned_clone :: proc(src: wire.Queued_Input, backing: mem.Allocator) -> Queued_Input_Owned {
    owned: Queued_Input_Owned
    mem.dynamic_arena_init(&owned.arena, backing, backing)
    owned.input = wire.queued_input_clone(src, mem.dynamic_arena_allocator(&owned.arena))

    return owned
}

@(private = "file")
queued_input_owned_destroy :: proc(owned: ^Queued_Input_Owned) {
    assert(owned != nil, "destroying a queued input needs its owner")

    mem.dynamic_arena_destroy(&owned.arena)
    owned^ = {}
}

// Retract an input promoted out of the queue but never committed, so no subscriber holds
// one that will never arrive. The caller drains on.
@(private = "file")
session_input_drop :: proc(d: ^Daemon, session: wire.Session_Id, input_id: wire.Input_Id) {
    _ = broadcast(d, wire.Input_Canceled_Data{session_id = session, input_id = input_id})
}

// What a session is doing now. A run never outlives its daemon, so the engine state is the
// whole truth and every activity surface reads it here rather than the log.
session_activity :: proc(d: ^Daemon, session: wire.Session_Id) -> wire.Session_Activity {
    assert(d != nil, "reading session activity needs daemon state")

    activity := wire.Session_Activity {
        state = wire.Activity_State_Idle{},
    }

    // Durable, so it holds through an idle session, a resync, and a restart, unlike the run.
    activity.context_usage = session_context_usage(d, session)

    live := session_live(d, session)
    if live == nil do return activity

    assert(len(live.queue) <= wire.LIMITS.max_queued_inputs, "the queue holds no more than its bound")
    activity.queued = u64(len(live.queue))

    run := live.run
    if run == nil do return activity

    activity.config = run.config
    activity.state = wire.Activity_State_Running {
        run_id        = run.run_id,
        started_at_ms = run.started_at_ms,
    }

    // A running tool outranks the stream: the turn is waiting on it, not on the provider.
    // The first one still running names the phase when several run at once.
    for &block, index in run.blocks {
        if block.kind != .Tool do continue

        running, is_running := block.tool_state.(wire.Tool_State_Running)
        if !is_running do continue

        activity.state = wire.Activity_State_Running_Tool {
            run_id        = run.run_id,
            message_id    = run.message_id,
            part_id       = wire.Part_Id(index),
            tool_name     = block.name,
            started_at_ms = running.started_at_ms,
        }

        return activity
    }

    // Only a reasoning block names a phase of its own, and only while it is the one
    // receiving deltas. A permission phase arrives with permissions.
    if len(run.blocks) > 0 {
        index := len(run.blocks) - 1
        block := &run.blocks[index]

        if block.kind == .Reasoning && !block.closed {
            activity.state = wire.Activity_State_Reasoning {
                run_id     = run.run_id,
                message_id = run.message_id,
                part_id    = wire.Part_Id(index),
            }
        }
    }

    return activity
}

// Usage of the last committed assistant turn for the live context gauge. A failed read
// degrades to zero rather than failing the activity every surface depends on.
@(private)
session_context_usage :: proc(d: ^Daemon, session: wire.Session_Id) -> wire.Token_Usage {
    assert(d != nil, "reading context usage needs daemon state")
    assert(d.store != nil, "a serving daemon owns an event store")

    usage, found, err := store.messages_last_usage(d.store, session)
    if err != nil {
        log.errorf("daemon: context-usage read failed for session %v: %v", session, err)

        return {}
    }

    if !found do return {}

    return usage
}

// The open draft and the inputs behind it, for a resync cut: `message.started` and
// `input.queued` are live-only, so a mid-turn subscriber has no other source. Borrowed.
session_draft :: proc(
    d: ^Daemon,
    session: wire.Session_Id,
    allocator: mem.Allocator,
) -> (
    draft: Maybe(wire.Active_Draft),
    queued: []wire.Queued_Input,
    ok: bool,
) {
    assert(d != nil, "reading a session draft needs daemon state")
    assert(allocator.procedure != nil, "building a draft needs an allocator")

    live := session_live(d, session)
    if live == nil do return nil, nil, true

    queue_copy, queue_err := make([]wire.Queued_Input, len(live.queue), allocator)
    if queue_err != nil do return nil, nil, false
    queued = queue_copy
    for owned, index in live.queue {
        queued[index] = owned.input
    }

    run := live.run
    if run == nil do return nil, queued, true

    // Each part carries what its block has accumulated, which is the offset the next
    // `message.part_delta` names, so folding that delta onto this cut leaves no gap.
    content, alloc_err := make([]wire.Assistant_Part, len(run.blocks), allocator)
    if alloc_err != nil do return nil, nil, false

    for &block, index in run.blocks {
        content[index] = run_part_build(&block, index)
    }

    open := wire.Active_Draft {
        message = wire.Assistant_Message {
            id = run.message_id,
            run_id = run.run_id,
            config_rev = run.config.config_rev,
            agent = RUN_AGENT,
            content = content,
            time = wire.Message_Time{created_at_ms = run.round_started_at_ms},
        },
    }

    assert(wire.active_draft_validate(open) == .None, "the engine built an invalid draft")

    return open, queued, true
}

// Publish the session's activity. Called from the engine transitions rather than the
// handlers, so nothing can move the queue or the phase without announcing it.
session_activity_announce :: proc(d: ^Daemon, session: wire.Session_Id) {
    activity := session_activity(d, session)
    _ = broadcast(d, wire.Session_Activity_Changed_Data{session_id = session, activity = activity})
}

// `session.send_input`: mint the input and announce it live, then either start the turn it
// feeds or leave it queued behind the one already running.
method_session_send_input :: proc(conn: ^Conn, req: wire.Request, sa: mem.Allocator) {
    assert(conn != nil, "session.send_input needs connection state")
    assert(conn.state == .Ready, "session.send_input ran outside Ready")
    assert(req.method == .Session_Send_Input, "session.send_input received another method")
    assert(conn.daemon != nil, "a connection always names its daemon")

    params := req.params.(wire.Session_Send_Input_Params)
    d := conn.daemon
    assert(d.store != nil, "a serving daemon always owns an event store")

    snapshot, ok := session_require(conn, req, params.session_id, sa)
    if !ok do return

    // A skill reaches the transcript as rendered content parts, and nothing resolves a
    // name to a body yet, so there is nothing to queue or commit.
    raw, is_content := params.input.(wire.Input_Content)
    if !is_content {
        send_error(conn, req.id, .Unknown_Skill, "skills are not implemented", sa)

        return
    }

    hw, herr := store.high_water(d.store, params.session_id)
    if herr != nil {
        log.errorf("daemon: session.send_input could not read the id marks: %v", herr)
        send_error(conn, req.id, .Internal, "could not mint an input id", sa)

        return
    }

    // The store's mark only covers inputs whose user message committed, so an input queued
    // behind the live turn is not in it yet; the session's own tail carries those.
    input_id := session_input_high(d, params.session_id, hw.input_id) + 1

    // Queued behind the live turn: announced now, committed on promotion. The client dequeues on that
    // commit, so committing here would empty its queue while the input still waited.
    if session_live_run(d, params.session_id) != nil {
        send_input_queue(conn, req, input_id, raw.content, sa)

        return
    }

    // Minted and committed with no suspension point between: the handler runs to completion on the
    // reactor, so no other turn can hand out the same pair.
    message_id := hw.message_id + 1
    now := now_ms()

    // The parts are borrowed from the frame arena, which outlives the handler; both
    // broadcasts encode into their own buffers and nothing here is retained.
    queued := wire.Queued_Input {
        input_id     = input_id,
        content      = raw.content,
        queued_at_ms = now,
    }
    committed := wire.User_Message {
        id = message_id,
        content = raw.content,
        input_id = input_id,
        time = wire.Created_Time{created_at_ms = now},
    }

    // A failed fan-out aborts the connection it failed on, and a relay connection is freed
    // synchronously by that abort — including the one that asked.
    ticket := conn.ticket
    published := send_input_publish(d, params.session_id, queued, committed, sa)

    // The input is durable whether or not a turn follows it, so a refused turn answers an
    // error over a committed message rather than pretending the input was never accepted.
    run_id: wire.Run_Id
    start_err := Run_Start_Error.None
    if published do run_id, start_err = run_turn_start(d, snapshot.session)

    answer := conn_resolve(d, ticket)
    if answer == nil do return

    if !published {
        send_error(answer, req.id, .Internal, "could not accept input", sa)

        return
    }

    // `Terminated` means the run was announced and then failed, so the send succeeded and
    // the failure is already in the transcript as this run's `run.done`.
    if start_err != .None && start_err != .Terminated {
        code, message := send_input_start_error(start_err)
        send_error(answer, req.id, code, message, sa)

        return
    }

    send_result(answer, req.id, wire.Session_Send_Input_Result_Started{input_id = input_id, run_id = run_id}, sa)
}

// Accept an input behind the session's live turn. Nothing durable happens here: the input
// is announced and retained, and its user message commits when the turn ahead of it ends.
@(private = "file")
send_input_queue :: proc(
    conn: ^Conn,
    req: wire.Request,
    input_id: wire.Input_Id,
    content: []wire.Content_Part,
    sa: mem.Allocator,
) {
    d := conn.daemon
    params := req.params.(wire.Session_Send_Input_Params)

    if session_queue_depth(d, params.session_id) >= wire.LIMITS.max_queued_inputs {
        send_error(conn, req.id, .Queue_Full, "the session's input queue is full", sa)

        return
    }

    // Taken before the push: accepting an input announces the new queue depth, and a
    // failed fan-out frees the connection that asked. A refused push announces nothing.
    ticket := conn.ticket

    queued := wire.Queued_Input {
        input_id     = input_id,
        content      = content,
        queued_at_ms = now_ms(),
    }

    if !session_queue_push(d, params.session_id, queued) {
        send_error(conn, req.id, .Internal, "could not queue the input", sa)

        return
    }

    if perr := broadcast(d, wire.Input_Queued_Data{session_id = params.session_id, input = queued}); perr != .None {
        log.errorf("daemon: session.send_input could not announce input %d: %v", input_id, perr)
        _ = session_queue_remove(d, params.session_id, input_id)

        if answer := conn_resolve(d, ticket); answer != nil do send_error(answer, req.id, .Internal, "could not accept input", sa)

        return
    }

    answer := conn_resolve(d, ticket)
    if answer == nil do return

    send_result(answer, req.id, wire.Session_Send_Input_Result_Queued{input_id = input_id}, sa)
}

// How a refused turn is reported. The input itself was accepted, so these describe the
// run that did not start, not the send that did.
@(private = "file")
send_input_start_error :: proc(err: Run_Start_Error) -> (wire.Error_Code, string) {
    #partial switch err {
    case .No_Model:
        return .Bad_Request, "the session names no model"

    case .Unknown_Model:
        return .Unsupported_Model, "the session's model is not in the catalog"

    case .Unbindable:
        return .Unsupported_Model, "the session's model has no usable endpoint or credential"
    }

    return .Internal, "the turn could not be started"
}

// Announce the input, commit it as a user message, and refresh the index. An input
// announced live is either committed or canceled, never left queued.
@(private)
send_input_publish :: proc(
    d: ^Daemon,
    session: wire.Session_Id,
    queued: wire.Queued_Input,
    committed: wire.User_Message,
    sa: mem.Allocator,
) -> bool {
    assert(d != nil, "publishing an input needs daemon state")
    assert(queued.input_id > 0, "an announced input carries a minted id")
    assert(committed.id > 0, "a committed message carries a minted id")
    assert(committed.input_id == queued.input_id, "the committed message names the announced input")

    if perr := broadcast(d, wire.Input_Queued_Data{session_id = session, input = queued}); perr != .None {
        log.errorf("daemon: session.send_input could not announce input %d: %v", queued.input_id, perr)

        return false
    }

    if perr := broadcast(d, wire.Message_Committed_Data{session_id = session, message = committed}); perr != .None {
        log.errorf("daemon: session.send_input could not commit input %d: %v", queued.input_id, perr)

        // `input.queued` never reaches the log, so no resync retracts it: every
        // subscriber holds this id until it is told the input is gone.
        _ = broadcast(d, wire.Input_Canceled_Data{session_id = session, input_id = queued.input_id})

        return false
    }

    session_summary_announce(d, session, sa)

    return true
}

// Re-announce the session summary the commit moved: `session.list` orders on
// `updated_at_ms`. Read back rather than patched: the store owns that fold.
@(private)
session_summary_announce :: proc(d: ^Daemon, session: wire.Session_Id, sa: mem.Allocator) {
    assert(d != nil, "announcing a summary needs daemon state")
    assert(d.store != nil, "a serving daemon always owns an event store")

    snapshot, found, serr := store.session_snapshot(d.store, session, sa)
    if serr != nil {
        log.errorf("daemon: session.send_input could not re-read the session summary: %v", serr)

        return
    }

    assert(found, "the session a commit landed in still has its registry row")
    _ = broadcast(
        d,
        wire.Session_Summary_Changed_Data{revision = session_revision_next(d), session = snapshot.session},
    )
}

// `session.cancel_run`: stop the live turn, and drop what waits behind it when asked. Cancelling
// nothing is a success with a null run, so a client racing the turn's end need not tell them apart.
method_session_cancel_run :: proc(conn: ^Conn, req: wire.Request, sa: mem.Allocator) {
    assert(conn != nil, "session.cancel_run needs connection state")
    assert(conn.state == .Ready, "session.cancel_run ran outside Ready")
    assert(req.method == .Session_Cancel_Run, "session.cancel_run received another method")
    assert(conn.daemon != nil, "a connection always names its daemon")

    params := req.params.(wire.Session_Cancel_Run_Params)
    d := conn.daemon

    run := session_live_run(d, params.session_id)

    // A live run proves the session exists; only the idle case has to ask the store.
    if run == nil {
        if _, ok := session_require(conn, req, params.session_id, sa); !ok do return
    }

    // An explicit id names the run the client believes is current. When it is not — it
    // ended, or it belongs to another session — the mismatch is the answer.
    if target, named := params.run_id.?; named && (run == nil || target != run.run_id) {
        send_error(conn, req.id, .Run_Mismatch, "that run is not the session's active run", sa)

        return
    }

    result := wire.Session_Cancel_Run_Result{}

    // Taken before anything fans out: clearing the queue announces the new activity, and a
    // failed fan-out frees the connection that asked — including this one.
    ticket := conn.ticket

    // Cleared before the cancel, so the terminal does not promote an input the client
    // just asked to drop.
    if clear, asked := params.clear_queue.?; asked && clear do result.cleared_inputs = session_queue_clear(d, params.session_id, sa)

    for input in result.cleared_inputs {
        _ = broadcast(d, wire.Input_Canceled_Data{session_id = params.session_id, input_id = input})
    }

    if run != nil {
        canceled, stopped := run_turn_cancel(d, params.session_id)
        assert(stopped, "an active run cancels")
        result.canceled_run = canceled
    }

    answer := conn_resolve(d, ticket)
    if answer == nil do return

    send_result(answer, req.id, result, sa)
}

// `session.cancel_input`: drop one input that has not started yet. An input that already
// ran, or never existed, is `Unknown_Input` — the client's view is simply stale.
method_session_cancel_input :: proc(conn: ^Conn, req: wire.Request, sa: mem.Allocator) {
    assert(conn != nil, "session.cancel_input needs connection state")
    assert(conn.state == .Ready, "session.cancel_input ran outside Ready")
    assert(req.method == .Session_Cancel_Input, "session.cancel_input received another method")
    assert(conn.daemon != nil, "a connection always names its daemon")

    params := req.params.(wire.Session_Cancel_Input_Params)
    d := conn.daemon

    if session_live(d, params.session_id) == nil {
        if _, ok := session_require(conn, req, params.session_id, sa); !ok do return
    }

    // A successful removal announces the new activity, so the connection may be gone by
    // the time this returns. The refusal below fans nothing out and still holds `conn`.
    ticket := conn.ticket

    if !session_queue_remove(d, params.session_id, params.input_id) {
        send_error(conn, req.id, .Unknown_Input, "no queued input has that id", sa)

        return
    }

    _ = broadcast(d, wire.Input_Canceled_Data{session_id = params.session_id, input_id = params.input_id})

    answer := conn_resolve(d, ticket)
    if answer == nil do return

    send_result(answer, req.id, wire.Session_Cancel_Input_Result{canceled_input = params.input_id}, sa)
}

// The session a request names, or the two answers it owes when there is none. Every
// session-scoped method starts here, so they cannot drift on the code or the message.
@(private)
session_require :: proc(
    conn: ^Conn,
    req: wire.Request,
    session: wire.Session_Id,
    sa: mem.Allocator,
) -> (
    store.Session_Snapshot,
    bool,
) {
    snapshot, found, serr := store.session_snapshot(conn.daemon.store, session, sa)
    if serr != nil {
        log.errorf("daemon: %v could not read the session: %v", req.method, serr)
        send_error(conn, req.id, .Internal, "could not read session", sa)

        return {}, false
    }

    if !found {
        send_error(conn, req.id, .Unknown_Session, "unknown session", sa)

        return {}, false
    }

    return snapshot, true
}

// `session.create`: resolve the requested root off the reactor, then register the
// workspace and the session together.
method_session_create :: proc(conn: ^Conn, req: wire.Request, sa: mem.Allocator) {
    assert(conn != nil, "session.create needs connection state")
    assert(conn.state == .Ready, "session.create ran outside Ready")
    assert(req.method == .Session_Create, "session.create received another method")

    // `request_validate` already held every override to the bound of the `Session` field
    // it lands in, so the summary this builds cannot overflow.
    params := req.params.(wire.Create_Session)

    fs_job_submit(conn, req.id, .Create_Session, fs_target_path(params.workspace_path, sa), create = params)
}

// Persist the session into its resolved workspace and answer. `workspace.created` is announced
// first, so a client never hears of a session in a workspace it does not know.
session_send_create :: proc(conn: ^Conn, job: ^Fs_Job) {
    assert(job.kind == .Create_Session, "a session was built from another job")
    assert(len(job.canonical) > 0, "a completed create has a canonical root")
    assert(conn.daemon != nil, "session.create needs daemon state")
    assert(conn.daemon.store != nil, "a serving daemon always owns an event store")

    d := conn.daemon
    workspace := wire.Workspace {
        id    = workspace_id(job.canonical),
        root  = job.canonical,
        title = workspace_title(job.canonical),
    }

    session := session_from_create(job, workspace.id, conn)

    // Omitted means no system prompt; only a supplied value is stored.
    prompt := job.create.system_prompt

    workspace_created, err := store.session_create(d.store, workspace, session, prompt)
    if err != nil {
        log.errorf("daemon: session.create could not persist the session: %v", err)
        send_error(conn, job.id, .Internal, "could not create session", job.allocator)

        return
    }

    if workspace_created do _ = broadcast(d, wire.Workspace_Created_Data{workspace = workspace})

    _ = broadcast(d, wire.Session_Summary_Changed_Data{revision = session_revision_next(d), session = session})

    // A failed fan-out aborts the connection it failed on, and a relay one is freed synchronously by
    // that abort — including the asker. The session is durable either way; only the answer is lost.
    answer := conn_resolve(d, job.ticket)
    if answer == nil do return

    send_result(answer, job.id, wire.Session_Result{session = session}, job.allocator)
}

// Build the summary a create persists and announces; every omitted override takes its default,
// and nothing resolves against the catalog. The client identity is cloned into the job.
@(private = "file")
session_from_create :: proc(job: ^Fs_Job, workspace: wire.Workspace_Id, conn: ^Conn) -> wire.Session {
    now := now_ms()
    session := wire.Session {
        id = session_id_create(),
        workspace_id = workspace,
        profile = "default",
        permission = .Normal,
        created_at_ms = now,
        updated_at_ms = now,
        created_by = wire.Client {
            name = strings.clone(conn.client_name, job.allocator),
            version = strings.clone(conn.client_version, job.allocator),
        },
        origin = wire.Session_Origin_Root{},
    }

    if profile, ok := job.create.profile.?; ok do session.profile = profile

    if model, ok := job.create.model.?; ok do session.model = model

    if reasoning, ok := job.create.reasoning.?; ok do session.reasoning = reasoning

    if permission, ok := job.create.permission.?; ok do session.permission = permission

    // Omitted means no cap; only a supplied value carries one.
    session.max_rounds = job.create.max_rounds

    return session
}

// A fresh session id: 8 random bytes rendered as the 16 lowercase hex chars the wire
// fixes, which the store also uses as the session's name.
@(private = "file")
session_id_create :: proc() -> wire.Session_Id {
    random: [8]byte
    crypto.rand_bytes(random[:])

    lower := "0123456789abcdef"
    out: [16]byte
    for value, index in random {
        out[index * 2] = lower[value >> 4]
        out[index * 2 + 1] = lower[value & 0x0f]
    }

    id := wire.Session_Id(out)
    assert(wire.enforce_id(([16]u8)(id)) == .None, "a minted session id is a valid wire id")

    return id
}

// A `session.list` cursor is `<filter key>.<updated_at_ms>.<session id>`. The key ties a
// cursor to one selection, so replaying it against a different scope is `Bad_Request`.
@(private = "file")
CURSOR_SEPARATOR :: '.'

// `strconv.parse_u64` wraps silently and still reports success, so a longer run of digits
// is rejected before it is parsed rather than after.
@(private = "file")
MAX_CURSOR_TIMESTAMP_DIGITS :: 20

// A filter key is a scope arm and a population arm, each a tag byte plus at most one
// 16-character id.
@(private = "file")
MAX_FILTER_KEY_BYTES :: 2 * (1 + size_of(wire.Session_Id))

// The key, two separators, the timestamp, and the position's id.
@(private = "file")
MAX_CURSOR_BYTES :: MAX_FILTER_KEY_BYTES + 2 + MAX_CURSOR_TIMESTAMP_DIGITS + size_of(wire.Session_Id)

// The index revision every announcement carries. Daemon-lifetime, so a reconnecting client sees
// it restart and refetches; minted from 1, since the wire reserves 0 for "nothing yet".
session_revision_next :: proc(d: ^Daemon) -> wire.Session_Revision {
    assert(d != nil, "a session index revision needs daemon state")
    assert(u64(d.session_revision) < wire.MAX_SESSION_REVISION, "the session index revision is exhausted")

    d.session_revision += 1

    return d.session_revision
}

// `session.list` over the registry: page, continuation and total read from SQLite. Each row's
// activity comes from the engine, so a listed session and its resync agree.
method_session_list :: proc(conn: ^Conn, req: wire.Request, sa: mem.Allocator) {
    assert(conn != nil, "session.list needs connection state")
    assert(conn.state == .Ready, "session.list ran outside Ready")
    assert(req.method == .Session_List, "session.list received another method")
    assert(conn.daemon != nil, "a connection always names its daemon")

    params := req.params.(wire.Session_List_Params)
    d := conn.daemon

    filter := store.Session_Filter {
        scope      = params.scope,
        population = params.population,
    }

    assert(d.store != nil, "a serving daemon always owns an event store")

    // `active` selects what the engine tracks, which lives in memory rather than the
    // registry. `active_recent` still orders like `recent`.
    if params.view == .Active {
        session_list_active(conn, req, filter, sa)
        return
    }

    cursor, limit, window_ok := session_list_window(conn, req, filter, sa)
    if !window_ok do return

    // One row past the page, so a continuation is minted only when a further row exists
    // rather than on every full page. The extra row is dropped before the result is built.
    sessions, page_err := store.session_page(d.store, filter, cursor, limit + 1, sa)
    if page_err != nil {
        log.errorf("daemon: session.list page read failed: %v", page_err)
        send_error(conn, req.id, .Internal, "session index unavailable", sa)

        return
    }

    more := len(sessions) > limit
    if more do sessions = sessions[:limit]

    // A first page that wasn't truncated already holds the whole selection, so its length is
    // the total; only a paged or truncated view pays for the count, which is unbounded work.
    total := u64(len(sessions))
    if more || cursor != nil {
        counted, count_err := store.session_count(d.store, filter)

        if count_err != nil {
            log.errorf("daemon: session.list count failed: %v", count_err)
            send_error(conn, req.id, .Internal, "session index unavailable", sa)

            return
        }

        total = counted
    }

    items, items_err := make([]wire.Session_List_Item, len(sessions), sa)
    if items_err != nil {
        send_error(conn, req.id, .Internal, "session index unavailable", sa)
        return
    }

    for session, i in sessions {
        items[i] = wire.Session_List_Item {
            session  = session,
            activity = session_activity(d, session.id),
        }
    }

    result := wire.Session_List_Result {
        revision = d.session_revision,
        items    = items,
        total    = total,
    }

    if more {
        last := sessions[len(sessions) - 1]
        result.next_cursor = session_cursor_encode(filter, {updated_at_ms = last.updated_at_ms, id = last.id}, sa)
    }

    // Every remaining field is daemon-built and the store already refused any row the protocol
    // would reject, so `send_result`'s validation assertion covers the rest.
    send_result(conn, req.id, result, sa)
}

// The page both views open on: the cursor's resume position and the page size. Answers
// `Bad_Request` itself; `false` means the request is already answered.
@(private = "file")
session_list_window :: proc(
    conn: ^Conn,
    req: wire.Request,
    filter: store.Session_Filter,
    sa: mem.Allocator,
) -> (
    cursor: Maybe(store.Session_Cursor),
    limit: int,
    ok: bool,
) {
    params := req.params.(wire.Session_List_Params)

    if token, paging := params.cursor.?; paging {
        position, valid := session_cursor_decode(token, filter)

        if !valid {
            send_error(conn, req.id, .Bad_Request, "malformed session.list cursor", sa)

            return nil, 0, false
        }

        cursor = position
    }

    // Already validated to be within bounds; default when omitted.
    limit = wire.LIMITS.default_session_list_page_size
    if requested, requested_ok := params.limit.?; requested_ok do limit = int(requested)

    assert(limit > 0, "a validated page size is positive")

    return cursor, limit, true
}

// `session.list` at `view = active`: paged over the engine's map instead of SQL, on the
// same keyset and cursor grammar, so a client pages both views identically.
@(private = "file")
session_list_active :: proc(conn: ^Conn, req: wire.Request, filter: store.Session_Filter, sa: mem.Allocator) {
    d := conn.daemon

    resume, limit, window_ok := session_list_window(conn, req, filter, sa)
    if !window_ok do return

    items, items_err := make([dynamic]wire.Session_List_Item, 0, len(d.sessions), sa)
    if items_err != nil {
        send_error(conn, req.id, .Internal, "session index unavailable", sa)

        return
    }

    for id in d.sessions {
        snapshot, found, serr := store.session_snapshot(d.store, id, sa)

        if serr != nil {
            log.errorf("daemon: session.list could not read active session %v: %v", id, serr)
            send_error(conn, req.id, .Internal, "session index unavailable", sa)

            return
        }

        // A tracked id with no row lost a race with `session.removed`, not an invariant.
        if !found || !session_filter_matches(filter, snapshot.session) do continue

        if _, err := append(
            &items,
            wire.Session_List_Item{session = snapshot.session, activity = session_activity(d, id)},
        ); err != nil {
            send_error(conn, req.id, .Internal, "session index unavailable", sa)

            return
        }
    }

    // Map iteration is unordered, so this is what makes the answer reproducible at all.
    slice.sort_by(items[:], proc(a, b: wire.Session_List_Item) -> bool {
        if a.session.updated_at_ms != b.session.updated_at_ms do return a.session.updated_at_ms > b.session.updated_at_ms

        return session_id_greater(a.session.id, b.session.id)
    })

    // `total` describes the whole selection on every page, as it does for the registry.
    page := items[:]
    total := u64(len(page))

    // Resume strictly below the cursor. The position is exclusive on both terms, so no row
    // repeats across pages and none between them is skipped.
    if position, paging := resume.?; paging {
        for item, index in page {
            below :=
                item.session.updated_at_ms < position.updated_at_ms ||
                (item.session.updated_at_ms == position.updated_at_ms &&
                        session_id_greater(position.id, item.session.id))

            if below {
                page = page[index:]
                break
            }

            if index == len(page) - 1 do page = nil
        }
    }

    result := wire.Session_List_Result {
        revision = d.session_revision,
        items    = page,
        total    = total,
    }

    // Minted only when a row remains, so a null continuation really does end the view.
    if len(page) > limit {
        result.items = page[:limit]
        last := result.items[limit - 1].session
        result.next_cursor = session_cursor_encode(filter, {updated_at_ms = last.updated_at_ms, id = last.id}, sa)
    }

    send_result(conn, req.id, result, sa)
}

// Whether a session belongs to the selection a filter names. `Session_Page` applies this
// same predicate in SQL; this is its in-memory twin, and the two must agree.
@(private = "file")
session_filter_matches :: proc(filter: store.Session_Filter, session: wire.Session) -> bool {
    assert(filter.scope != nil, "a session filter carries its scope")
    assert(filter.population != nil, "a session filter carries its population")

    switch scope in filter.scope {
    case wire.Session_Scope_All:

    case wire.Session_Scope_Workspace:
        if session.workspace_id != scope.workspace_id do return false
    }

    switch population in filter.population {
    case wire.Session_Population_All:

    case wire.Session_Population_Top_Level:
        // `origin IN ('root', 'fork')`, the same pair the statement admits.
        switch _ in session.origin {
        case wire.Session_Origin_Root, wire.Session_Origin_Fork:

        case wire.Session_Origin_Child, wire.Session_Origin_Cron:
            return false
        }

    case wire.Session_Population_Children:
        child, is_child := session.origin.(wire.Session_Origin_Child)

        if !is_child || child.parent_id != population.parent_id do return false

    case wire.Session_Population_Job_Runs:
        cron, is_cron := session.origin.(wire.Session_Origin_Cron)

        if !is_cron || cron.job_id != population.job_id do return false
    }

    return true
}

// The registry's `id DESC` tiebreak. Ids are opaque blobs, so the compare is bytewise.
@(private = "file")
session_id_greater :: proc(a, b: wire.Session_Id) -> bool {
    left := ([16]u8)(a)
    right := ([16]u8)(b)

    for byte, index in left {
        if byte != right[index] do return byte > right[index]
    }

    return false
}

// Write the selection a cursor belongs to. Every arm contributes a distinct leading byte, and
// ids are already 16 lowercase hex characters, so no arm's encoding can prefix another's.
@(private = "file")
session_filter_key_write :: proc(b: ^strings.Builder, filter: store.Session_Filter) {
    assert(filter.scope != nil, "a session filter carries its scope")
    assert(filter.population != nil, "a session filter carries its population")

    switch scope in filter.scope {
    case wire.Session_Scope_All:
        strings.write_byte(b, 'a')

    case wire.Session_Scope_Workspace:
        strings.write_byte(b, 'w')
        id := ([16]u8)(scope.workspace_id)
        strings.write_bytes(b, id[:])
    }

    switch population in filter.population {
    case wire.Session_Population_Top_Level:
        strings.write_byte(b, 't')

    case wire.Session_Population_All:
        strings.write_byte(b, 'e')

    case wire.Session_Population_Children:
        strings.write_byte(b, 'c')
        id := ([16]u8)(population.parent_id)
        strings.write_bytes(b, id[:])

    case wire.Session_Population_Job_Runs:
        strings.write_byte(b, 'j')
        id := ([16]u8)(population.job_id)
        strings.write_bytes(b, id[:])
    }
}

// Mint the continuation for `position` under `filter`, sized exactly for a filter key plus
// a timestamp and id — well inside the protocol's cursor bound.
@(private = "file")
session_cursor_encode :: proc(
    filter: store.Session_Filter,
    position: store.Session_Cursor,
    allocator: mem.Allocator,
) -> string {
    b := strings.builder_make(0, MAX_CURSOR_BYTES, allocator) or_else strings.Builder{}

    session_filter_key_write(&b, filter)
    strings.write_byte(&b, CURSOR_SEPARATOR)
    strings.write_u64(&b, position.updated_at_ms)
    strings.write_byte(&b, CURSOR_SEPARATOR)

    id := ([16]u8)(position.id)
    strings.write_bytes(&b, id[:])

    token := strings.to_string(b)
    assert(len(token) <= wire.LIMITS.max_session_list_cursor_bytes, "a minted cursor fits the protocol bound")

    return token
}

// Read a continuation back, refusing one minted for any other selection. The whole token
// is peer input: nothing here asserts on its contents.
@(private = "file")
session_cursor_decode :: proc(
    token: string,
    filter: store.Session_Filter,
) -> (
    position: store.Session_Cursor,
    ok: bool,
) {
    key_buf: [MAX_FILTER_KEY_BYTES]u8
    b := strings.builder_from_bytes(key_buf[:])
    session_filter_key_write(&b, filter)
    key := strings.to_string(b)

    // The cursor names the selection it is a position in; anything else is a token this
    // request has no meaning for.
    if len(token) <= len(key) || token[:len(key)] != key || token[len(key)] != CURSOR_SEPARATOR do return {}, false

    rest := token[len(key) + 1:]
    split := strings.index_byte(rest, CURSOR_SEPARATOR)

    if split < 0 do return {}, false

    digits := rest[:split]
    id := rest[split + 1:]

    if len(digits) == 0 || len(digits) > MAX_CURSOR_TIMESTAMP_DIGITS do return {}, false

    updated_at_ms, parsed := strconv.parse_u64(digits, 10)
    if !parsed do return {}, false

    if len(id) != size_of(wire.Session_Id) do return {}, false

    session: [size_of(wire.Session_Id)]u8
    copy(session[:], id)

    // A cursor id is compared against stored ids as an opaque blob, so a token outside the
    // id grammar could only ever match nothing. Rejecting it names the fault instead.
    if wire.enforce_id(session) != .None do return {}, false

    return {updated_at_ms = updated_at_ms, id = wire.Session_Id(session)}, true
}
