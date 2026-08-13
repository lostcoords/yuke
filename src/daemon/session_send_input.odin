package daemon

import "core:log"
import "core:mem"

import store "src:daemon/store"
import wire "src:wire"

// `session.send_input`: mint the input, announce it live, and commit it as a user
// message. No engine runs it yet, so every accepted input answers `queued`.
method_session_send_input :: proc(conn: ^Conn, req: wire.Request, sa: mem.Allocator) {
    assert(conn != nil, "session.send_input needs connection state")
    assert(conn.state == .Ready, "session.send_input ran outside Ready")
    assert(req.method == .Session_Send_Input, "session.send_input received another method")
    assert(conn.daemon != nil, "a connection always names its daemon")

    params := req.params.(wire.Session_Send_Input_Params)
    d := conn.daemon
    assert(d.store != nil, "a serving daemon always owns an event store")

    _, found, serr := store.session_snapshot(d.store, params.session_id, sa)
    if serr != nil {
        log.errorf("daemon: session.send_input could not read the session: %v", serr)
        send_error(conn, req.id, .Internal, "could not read session", sa)

        return
    }

    if !found {
        send_error(conn, req.id, .Unknown_Session, "unknown session", sa)

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

    // Minted and committed with no suspension point in between: the handler runs to
    // completion on the reactor, so no other turn can hand out the same pair. The commit
    // raises both marks in its own transaction.
    input_id := hw.input_id + 1
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

    answer := conn_resolve(d, ticket)
    if answer == nil {
        return
    }

    if !published {
        send_error(answer, req.id, .Internal, "could not accept input", sa)

        return
    }

    send_result(answer, req.id, wire.Session_Send_Input_Result_Queued{input_id = input_id}, sa)
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
@(private = "file")
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
