package daemon

import "core:log"
import "core:mem"

import store "src:daemon/store"
import wire "src:wire"

// `session.cancel_run`: stop the session's live turn, and drop what waits behind it when
// asked. Cancelling nothing is a success with a null run, not an error — a client that
// races the turn's own ending must not have to tell the two apart.
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
        if _, ok := session_require(conn, req, params.session_id, sa); !ok {
            return
        }
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
    if clear, asked := params.clear_queue.?; asked && clear {
        result.cleared_inputs = session_queue_clear(d, params.session_id, sa)
    }

    for input in result.cleared_inputs {
        _ = broadcast(d, wire.Input_Canceled_Data{session_id = params.session_id, input_id = input})
    }

    if run != nil {
        canceled, stopped := run_turn_cancel(d, params.session_id)
        assert(stopped, "an active run cancels")
        result.canceled_run = canceled
    }

    answer := conn_resolve(d, ticket)
    if answer == nil {
        return
    }

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
        if _, ok := session_require(conn, req, params.session_id, sa); !ok {
            return
        }
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
    if answer == nil {
        return
    }

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
