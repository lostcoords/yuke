package daemon

import "core:log"
import "core:mem"

import store "src:daemon/store"
import wire "src:wire"

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
    if !ok {
        return
    }

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

    // Queued behind the live turn: announced now, committed only when it is promoted. The
    // client dequeues on that commit, so committing here would empty its queue while the
    // input still waited.
    if session_live_run(d, params.session_id) != nil {
        send_input_queue(conn, req, input_id, raw.content, sa)

        return
    }

    // Minted and committed with no suspension point in between: the handler runs to
    // completion on the reactor, so no other turn can hand out the same pair. The commit
    // raises both marks in its own transaction.
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
    if published {
        run_id, start_err = run_turn_start(d, snapshot.session)
    }

    answer := conn_resolve(d, ticket)
    if answer == nil {
        return
    }

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

    if !session_queue_push(d, params.session_id, input_id, content) {
        send_error(conn, req.id, .Internal, "could not queue the input", sa)

        return
    }

    queued := wire.Queued_Input {
        input_id     = input_id,
        content      = content,
        queued_at_ms = now_ms(),
    }

    if perr := broadcast(d, wire.Input_Queued_Data{session_id = params.session_id, input = queued}); perr != .None {
        log.errorf("daemon: session.send_input could not announce input %d: %v", input_id, perr)
        _ = session_queue_remove(d, params.session_id, input_id)

        if answer := conn_resolve(d, ticket); answer != nil {
            send_error(answer, req.id, .Internal, "could not accept input", sa)
        }

        return
    }

    answer := conn_resolve(d, ticket)
    if answer == nil {
        return
    }

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
