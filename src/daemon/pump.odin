package daemon

import "core:log"

import ws "libs:websocket"
import store "src:daemon/store"
import wire "src:wire"

// Why a broadcast never reached the fan-out. A durable broadcast that fails here was
// neither logged nor delivered, so the stream stays contiguous.
Pump_Error :: enum {
    // No error.
    None,

    // A durable broadcast was emitted with no database configured; it has nowhere to
    // be sequenced.
    No_Store,

    // The store refused the append or the high-water read; nothing was written.
    Store_Failed,

    // The session has consumed every sequence number representable on the wire.
    Sequence_Exhausted,
}

// Emit one broadcast. A `Durable_Gated` broadcast is assigned its seq, committed, and
// only then fanned out; every other class fans out directly. Runs on the reactor
// thread, like every other store touch.
broadcast :: proc(d: ^Daemon, data: wire.Broadcast_Data) -> Pump_Error {
    assert(d != nil, "broadcast needs daemon state")
    assert(wire.broadcast_data_validate(data) == .None, "daemon built an invalid broadcast payload")

    // The closed payload union is the sole name authority, so callers cannot pair a
    // valid payload with the wrong registry entry.
    name, typed := wire.broadcast_data_name(data)
    assert(typed, "a broadcast payload names its union arm")

    class := wire.broadcast_name_class(name)
    session := wire.broadcast_data_session_id(data)
    out := data

    switch class {
    case .Durable_Gated:
        sid, named := session.?
        assert(named, "a durable broadcast names its session")

        if d.store == nil {
            return .No_Store
        }

        out = pump_commit(d, name, data, sid) or_return

    case .Live_Gated, .Live_Droppable, .Ungated:
    }

    // A removed session mints nothing further, and the mark is pure memoization: an
    // absent entry is re-read from the store. Dropping it here is what keeps the map
    // bounded by live sessions instead of by everything the daemon ever sequenced.
    if name == .Session_Removed {
        sid, named := session.?
        assert(named, "session.removed names its session")
        delete_key(&d.seq_high, sid)
    }

    pump_send(d, name, out, class, session)

    return .None
}

// Sequence and log one durable broadcast, returning the payload the fan-out sends —
// the seq is minted here, so the caller emits without one.
@(private)
pump_commit :: proc(
    d: ^Daemon,
    name: wire.Broadcast_Name,
    data: wire.Broadcast_Data,
    session: wire.Session_Id,
) -> (
    out: wire.Broadcast_Data,
    err: Pump_Error,
) {
    assert(d != nil, "a durable broadcast needs daemon state")
    assert(d.store != nil, "a durable broadcast needs an open store")
    assert(wire.broadcast_name_class(name) == .Durable_Gated, "only durable broadcasts are logged")

    offered, sequenced := wire.broadcast_data_seq(data).?
    assert(sequenced, "a durable payload carries a sequence field")
    assert(offered == 0, "a durable payload reaches the pump unstamped")

    seq := pump_next_seq(d, session) or_return
    stamped := pump_stamp_seq(data, seq)
    ids := pump_id_marks(stamped)

    e: wire.Emitter
    wire.emitter_init(&e, d.allocator)
    defer wire.emitter_destroy(&e)
    wire.broadcast_data_emit(&e, stamped)

    if aerr := store.event_append(d.store, session, seq, name, wire.to_string(&e), ids); aerr != nil {
        // Seq_Conflict means our tracked high-water diverged from the log: a daemon
        // bug, so it crashes here. Other failures drop the cached mark, since it
        // can't be trusted after a failed append, and degrade.
        assert(aerr != .Seq_Conflict, "the pump minted a seq the log did not continue")
        delete_key(&d.seq_high, session)
        log.errorf("daemon: durable broadcast %v not logged: %v", name, aerr)

        return nil, .Store_Failed
    }

    d.seq_high[session] = seq

    return stamped, .None
}

// Next durable seq for `session`: `high_water + 1`. The mark is recovered from the
// store the first time the daemon touches the session and tracked in memory after; an
// absent entry is always re-read rather than assumed zero.
@(private)
pump_next_seq :: proc(d: ^Daemon, session: wire.Session_Id) -> (seq: wire.Seq, err: Pump_Error) {
    assert(d != nil, "seq minting needs daemon state")
    assert(d.store != nil, "seq minting needs an open store")

    high, tracked := d.seq_high[session]

    if !tracked {
        hw, herr := store.high_water(d.store, session)
        if herr != nil {
            log.errorf("daemon: high-water read failed: %v", herr)

            return 0, .Store_Failed
        }

        high = hw.seq
    }

    if u64(high) >= wire.MAX_WIRE_INTEGER {
        log.errorf("daemon: session %v exhausted its durable sequence range", session)

        return 0, .Sequence_Exhausted
    }

    return high + 1, .None
}

// Stamp the minted seq into a durable payload. The five durable arms are the only ones
// that carry one, and the caller has already established the class.
@(private)
pump_stamp_seq :: proc(data: wire.Broadcast_Data, seq: wire.Seq) -> wire.Broadcast_Data {
    assert(seq > 0, "seq numbering starts at 1")

    #partial switch v in data {
    case wire.Message_Committed_Data:
        out := v
        out.seq = seq

        return out

    case wire.Run_Started_Data:
        out := v
        out.seq = seq

        return out

    case wire.Run_Done_Data:
        out := v
        out.seq = seq

        return out

    case wire.Config_Changed_Data:
        out := v
        out.seq = seq

        return out

    case wire.Transcript_Truncated_Data:
        out := v
        out.seq = seq

        return out
    }

    unreachable()
}

// Ids a durable payload proves were handed out, raised in the append's own
// transaction. The store keeps the larger of the stored and offered mark, so naming an
// id that already existed costs nothing while missing one lets a restart mint it twice.
@(private)
pump_id_marks :: proc(data: wire.Broadcast_Data) -> store.Id_Marks {
    assert(data != nil, "id marks are derived from a payload")
    _, sequenced := wire.broadcast_data_seq(data).?
    assert(sequenced, "only durable payloads carry the ids an append records")

    marks: store.Id_Marks

    #partial switch v in data {
    case wire.Message_Committed_Data:
        switch m in v.message {
        case wire.User_Message:
            assert(m.id > 0, "a committed user message has a minted id")
            assert(m.input_id > 0, "a committed user message names an accepted input")
            marks.message_id = m.id
            marks.input_id = m.input_id

        case wire.Assistant_Message:
            assert(m.id > 0, "a committed assistant message has a minted id")
            assert(m.run_id > 0, "a committed assistant message names its run")
            marks.message_id = m.id
            marks.run_id = m.run_id
            marks.config_rev = m.config_rev

        case wire.Compaction_Message:
            assert(m.id > 0, "a compaction divider has a minted id")
            assert(m.run_id > 0, "a compaction divider names its run")
            marks.message_id = m.id
            marks.run_id = m.run_id
        }

        return marks

    case wire.Run_Started_Data:
        assert(v.run_id > 0, "a started run has a minted id")
        marks.run_id = v.run_id
        marks.config_rev = v.config_rev

        return marks

    case wire.Run_Done_Data:
        assert(v.run_id > 0, "a finished run has a minted id")
        marks.run_id = v.run_id

        // A compaction terminal names the divider its run committed, so the mark holds
        // whichever of the two events the log carries first.
        if compacted, ok := v.outcome.(wire.Run_Outcome_Compacted); ok {
            assert(compacted.message_id > 0, "a compaction terminal names its divider")
            marks.message_id = compacted.message_id
        }

        return marks

    case wire.Config_Changed_Data:
        marks.config_rev = v.config.config_rev

        return marks

    case wire.Transcript_Truncated_Data:
        // Truncation mints nothing, but the id it removes was minted.
        assert(v.first_removed_id > 0, "a truncation starts at a minted message id")
        marks.message_id = v.first_removed_id

        return marks
    }

    unreachable()
}

// Encode the notification frame once and hand it to the fan-out.
@(private)
pump_send :: proc(
    d: ^Daemon,
    name: wire.Broadcast_Name,
    data: wire.Broadcast_Data,
    class: wire.Broadcast_Class,
    session: Maybe(wire.Session_Id),
) {
    assert(d != nil, "broadcast send needs daemon state")

    // Commit-before-broadcast: a sequenced payload only reaches a connection once its
    // seq is at or below the session's committed high-water.
    if seq, sequenced := wire.broadcast_data_seq(data).?; sequenced {
        sid, named := session.?
        assert(named, "a sequenced broadcast names its session")
        assert(d.seq_high[sid] >= seq, "a durable broadcast fanned out before its commit")
    }

    frame := wire.notification_build(name, data)
    assert(wire.notification_validate(frame) == .None, "daemon built an invalid broadcast frame")

    e: wire.Emitter
    wire.emitter_init(&e, d.allocator)
    defer wire.emitter_destroy(&e)
    wire.notification_emit(&e, frame)

    pump_fan_out(d, class, session, transmute([]byte)wire.to_string(&e))
}

// Deliver an encoded broadcast to every connection its class admits. Closing a
// connection defers its release to the loop, so the connection table is stable across
// this walk.
@(private)
pump_fan_out :: proc(d: ^Daemon, class: wire.Broadcast_Class, session: Maybe(wire.Session_Id), frame: []byte) {
    assert(d != nil, "fan-out needs daemon state")
    assert(len(frame) > 0, "a fanned-out broadcast is already encoded")

    for wsc in d.ws_server.conns {
        conn := (^Conn)(wsc.user_data)
        if conn == nil || conn.state != .Ready {
            continue
        }

        if wire.broadcast_class_gated(class) {
            sid, named := session.?
            assert(named, "a gated broadcast names its session")

            if !conn_subscribed(conn, sid) {
                continue
            }
        }

        send_err := ws.server_send_text(wsc, frame)
        if send_err == .None {
            continue
        }

        // The transport is already closing; its terminal callback frees the `Conn`.
        if send_err == .Not_Open {
            continue
        }

        // Shedding is the droppable class's contract: the receiver sees the offset gap
        // and resyncs. No other class may skip a frame, so the connection dies instead
        // and the client reconnects.
        if send_err == .Send_Queue_Full && wire.broadcast_class_droppable(class) {
            log.debug("daemon: shed a droppable broadcast under send backpressure")

            continue
        }

        conn_abort(conn, send_err)
    }
}

// `subscription.set` replaces the connection's subscription set wholesale. The params
// are already bounded and id-checked by `request_validate`.
method_subscription_set :: proc(conn: ^Conn, req: wire.Request) {
    assert(conn != nil, "subscription.set needs connection state")
    assert(conn.state == .Ready, "subscription.set ran outside Ready")
    assert(req.method == .Subscription_Set, "subscription.set received another method")

    params := req.params.(wire.Subscription_Set_Params)
    assert(len(params.sessions) <= len(conn.subscriptions), "a validated subscription set fits its bound")

    conn.subscription_count = copy(conn.subscriptions[:], params.sessions)
    assert(conn.subscription_count == len(params.sessions), "the replaced set lost a session")

    send_result(conn, req.id, wire.Empty{})
}

// Whether `conn` subscribed to `session`. The set is a replace-semantics list bounded
// by `LIMITS.max_subscriptions`, so a linear scan is the membership test.
conn_subscribed :: proc(conn: ^Conn, session: wire.Session_Id) -> bool {
    assert(conn != nil, "subscription test needs connection state")
    assert(conn.subscription_count >= 0, "subscription set has a negative length")
    assert(conn.subscription_count <= len(conn.subscriptions), "subscription set over its bound")

    for i in 0 ..< conn.subscription_count {
        if conn.subscriptions[i] == session {
            return true
        }
    }

    return false
}
