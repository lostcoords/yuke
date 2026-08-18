package daemon
import "libs:json"

import "core:log"
import "core:mem"
import "core:mem/virtual"

import ws "libs:websocket"

import "src:daemon/store"
import "src:wire"

// Why a broadcast never reached the fan-out. A durable broadcast that fails here was
// neither logged nor delivered, so the stream stays contiguous.
Pump_Error :: enum {
    None,

    // The store refused the append or the high-water read; nothing was written.
    Store_Failed,

    // The session has consumed every sequence number representable on the wire.
    Sequence_Exhausted,

    // The frame could not be encoded — the emitter's buffer would not grow — so the
    // JSON is truncated. Nothing was logged or sent.
    Encode_Failed,

    // The encoded frame is over the transport's frame cap, which every receiver would
    // refuse. Nothing was logged or sent: a committed one would fail every resync too.
    Frame_Too_Large,
}

// Emit one broadcast. A `Durable_Gated` broadcast is assigned its seq, committed, and only
// then fanned out; every other class fans out directly. Runs on the reactor thread.
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

    // Reset on exit, not freed, so a shed marker the fan-out mints mid-send still shares
    // this arena with the frame already in flight.
    temp := virtual.arena_temp_begin(&d.pump_scratch)
    defer virtual.arena_temp_end(temp)
    scratch := virtual.arena_allocator(&d.pump_scratch)

    // Built before anything is committed: a refusal here must never reach the log.
    frame: json.Emitter
    json.emitter_init(&frame, scratch)
    defer json.emitter_destroy(&frame)

    switch class {
    case .Durable_Gated:
        sid, named := session.?
        assert(named, "a durable broadcast names its session")
        assert(d.store != nil, "a serving daemon always owns an event store")

        seq := pump_next_seq(d, sid) or_return
        stamped := pump_stamp_seq(data, seq)
        assert(wire.broadcast_data_validate(stamped) == .None, "stamping a seq keeps the payload valid")

        // The durable payload the log stores; the frame carries these same bytes.
        payload: json.Emitter
        json.emitter_init(&payload, scratch)
        defer json.emitter_destroy(&payload)

        wire.broadcast_data_emit(&payload, stamped)

        if json.emitter_failed(&payload) {
            log.errorf("daemon: durable broadcast %v could not be encoded", name)

            return .Encode_Failed
        }

        wire.notification_emit_raw(&frame, name, json.to_string(&payload))
        pump_frame_check(&frame, name) or_return
        pump_commit(d, name, stamped, sid, seq, json.to_string(&payload)) or_return
        out = stamped

    case .Live_Gated, .Live_Droppable, .Ungated:
        wire.notification_emit(&frame, wire.notification_build(name, data))
        pump_frame_check(&frame, name) or_return
    }

    // The mark is pure memoization (an absent entry is re-read from the store), so
    // dropping it on removal keeps the map bounded by live sessions, not by history.
    if name == .Session_Removed {
        sid, named := session.?
        assert(named, "session.removed names its session")
        delete_key(&d.seq_high, sid)
    }

    pump_send(d, name, out, session, transmute([]byte)json.to_string(&frame))

    return .None
}

// Refuse a frame no receiver could take. Both faults are the same decision: nothing is
// logged and nothing is sent, so the caller sees the failure rather than the subscribers.
@(private)
pump_frame_check :: proc(e: ^json.Emitter, name: wire.Broadcast_Name) -> Pump_Error {
    assert(e != nil, "a frame check needs the emitter that built it")

    if json.emitter_failed(e) {
        log.errorf("daemon: broadcast %v could not be encoded", name)

        return .Encode_Failed
    }

    size := len(json.to_string(e))
    assert(size > 0, "a healthy emitter wrote the frame")

    // The transport is configured with this same cap at start and enforces it on
    // every send, so an over-cap frame would abort each connection in turn.
    if size > wire.LIMITS.max_frame_bytes {
        log.errorf(
            "daemon: broadcast %v is %d bytes, over the %d byte frame cap",
            name,
            size,
            wire.LIMITS.max_frame_bytes,
        )

        return .Frame_Too_Large
    }

    return .None
}

// Log one durable broadcast at its minted seq. The payload is the encoded bytes the
// frame already carries, so the row and the fan-out can never disagree.
@(private)
pump_commit :: proc(
    d: ^Daemon,
    name: wire.Broadcast_Name,
    data: wire.Broadcast_Data,
    session: wire.Session_Id,
    seq: wire.Seq,
    payload: string,
) -> Pump_Error {
    assert(d != nil, "a durable broadcast needs daemon state")
    assert(d.store != nil, "a durable broadcast needs an open store")
    assert(wire.broadcast_name_class(name) == .Durable_Gated, "only durable broadcasts are logged")
    assert(len(payload) > 0, "a durable broadcast is encoded before it is logged")

    stamped, sequenced := wire.broadcast_data_seq(data).?
    assert(sequenced, "a durable payload carries a sequence field")
    assert(stamped == seq, "the logged payload carries the seq it is logged at")

    ids := pump_id_marks(data)

    if aerr := store.event_append(d.store, session, seq, data, payload, ids); aerr != nil {
        // Seq_Conflict means our high-water mark diverged from the log: a daemon bug,
        // so it crashes here. Other failures drop the now-untrustworthy mark and degrade.
        assert(aerr != .Seq_Conflict, "the pump minted a seq the log did not continue")
        delete_key(&d.seq_high, session)

        if aerr == .Unknown_Session {
            log.errorf("daemon: durable broadcast %v names session %v, which has no registry row", name, session)
        } else {
            log.errorf("daemon: durable broadcast %v not logged: %v", name, aerr)
        }

        return .Store_Failed
    }

    d.seq_high[session] = seq

    return .None
}

// Next durable seq for `session`: `high_water + 1`. Recovered from the store on first
// touch and tracked in memory after; an absent entry is re-read, never assumed zero.
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

// Ids a durable payload proves were handed out, raised in the append's transaction. The store
// keeps the larger mark: naming an existing id is free, missing one lets a restart mint twice.
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

// Hand the already-encoded frame to the fan-out.
@(private)
pump_send :: proc(
    d: ^Daemon,
    name: wire.Broadcast_Name,
    data: wire.Broadcast_Data,
    session: Maybe(wire.Session_Id),
    frame: []byte,
) {
    assert(d != nil, "broadcast send needs daemon state")

    // Commit-before-broadcast: a sequenced payload only reaches a connection once its
    // seq is at or below the session's committed high-water.
    if seq, sequenced := wire.broadcast_data_seq(data).?; sequenced {
        sid, named := session.?
        assert(named, "a sequenced broadcast names its session")
        assert(d.seq_high[sid] >= seq, "a durable broadcast fanned out before its commit")
    }

    pump_fan_out(d, name, session, frame)
}

// Deliver an encoded broadcast to every connection its class admits. A relay conn tears down
// synchronously, so failed sends are aborted after the walk: the table must stay stable.
@(private)
pump_fan_out :: proc(d: ^Daemon, name: wire.Broadcast_Name, session: Maybe(wire.Session_Id), frame: []byte) {
    assert(d != nil, "fan-out needs daemon state")
    assert(len(frame) > 0, "a fanned-out broadcast is already encoded")

    class := wire.broadcast_name_class(name)

    Pending_Abort :: struct {
        conn: ^Conn,
        err:  ws.Server_Error,
    }
    aborts: [dynamic]Pending_Abort
    aborts.allocator = context.temp_allocator

    for _, conn in d.conns {
        if conn.state != .Ready do continue

        if wire.broadcast_class_gated(class) {
            sid, named := session.?
            assert(named, "a gated broadcast names its session")

            if !conn_subscribed(conn, sid) do continue
        }

        send_err := conn_send_text(conn, frame)
        if send_err == .None do continue

        // The transport is already closing; its terminal callback frees the `Conn`.
        if send_err == .Not_Open do continue

        // Shedding is the droppable class's contract: the receiver sees the offset gap and
        // resyncs. No other class may skip a frame, so it dies instead and reconnects.
        if send_err == .Send_Queue_Full && wire.broadcast_class_droppable(class) {
            log.debug("daemon: shed a droppable broadcast under send backpressure")

            // The marker is itself droppable and never marks itself; a shed one leaves
            // the offset gap as the signal and rolls its count into the next attempt.
            if name != .Session_Deltas_Shed {
                sid, named := session.?
                assert(named, "a droppable broadcast names its session")
                pump_shed_mark(d, conn, sid)
            }

            continue
        }

        append(&aborts, Pending_Abort{conn = conn, err = send_err})
    }

    // Aborts run after the walk: a relay conn's teardown frees it and deletes it from `d.conns`.
    for a in aborts {
        conn_abort(a.conn, a.err)
    }
}

// Tell one lagging connection how many live deltas were dropped; no other connection shares its
// backpressure. The count is cumulative, so a failed send carries into the next shed.
@(private)
pump_shed_mark :: proc(d: ^Daemon, conn: ^Conn, session: wire.Session_Id) {
    assert(d != nil, "a shed marker needs daemon state")
    assert(conn != nil, "a shed marker needs connection state")
    assert(conn.state == .Ready, "only a Ready connection sheds a gated broadcast")

    index, subscribed := conn_subscription_index(conn, session)
    assert(subscribed, "a gated broadcast reached a subscribed connection")

    conn.shed_counts[index] += 1
    data := wire.Session_Deltas_Shed_Data {
        session_id = session,
        count      = conn.shed_counts[index],
    }
    assert(wire.session_deltas_shed_data_validate(data) == .None, "the pump built an invalid shed marker")

    note := wire.notification_build(.Session_Deltas_Shed, data)
    e, ok := wire.notification_encode(note, virtual.arena_allocator(&d.pump_scratch))
    defer json.emitter_destroy(&e)

    if !ok {
        log.error("daemon: a shed marker could not be encoded")

        return
    }

    if conn_send_text(conn, transmute([]byte)json.to_string(&e)) != .None do return

    conn.shed_counts[index] = 0
}

// `subscription.set` replaces the connection's subscription set wholesale. The params
// are already bounded and id-checked by `request_validate`.
method_subscription_set :: proc(conn: ^Conn, req: wire.Request, sa: mem.Allocator) {
    assert(conn != nil, "subscription.set needs connection state")
    assert(conn.state == .Ready, "subscription.set ran outside Ready")
    assert(req.method == .Subscription_Set, "subscription.set received another method")

    params := req.params.(wire.Subscription_Set_Params)
    assert(len(params.sessions) <= len(conn.subscriptions), "a validated subscription set fits its bound")

    conn.subscription_count = copy(conn.subscriptions[:], params.sessions)
    assert(conn.subscription_count == len(params.sessions), "the replaced set lost a session")

    // Shed counts are positional, so a replaced set starts its accounting over.
    conn.shed_counts = {}

    send_result(conn, req.id, wire.Empty{}, sa)
}

// Whether `conn` subscribed to `session`.
conn_subscribed :: proc(conn: ^Conn, session: wire.Session_Id) -> bool {
    _, subscribed := conn_subscription_index(conn, session)
    return subscribed
}

// Where `session` sits in the connection's subscription set. Bounded by the protocol, so a scan
// is the membership test, and the position is what the parallel shed counts key on.
@(private)
conn_subscription_index :: proc(conn: ^Conn, session: wire.Session_Id) -> (index: int, subscribed: bool) {
    assert(conn != nil, "subscription test needs connection state")
    assert(conn.subscription_count >= 0, "subscription set has a negative length")
    assert(conn.subscription_count <= len(conn.subscriptions), "subscription set over its bound")

    for i in 0 ..< conn.subscription_count {
        if conn.subscriptions[i] == session do return i, true
    }

    return 0, false
}

#assert(wire.LIMITS.max_snapshot_configs >= wire.LIMITS.max_page_size + 1)

// Why a resync cut could not be built. Only `Unknown_Session` names something the
// client did; the rest are faults in our own read model or the cut we derived from it.
Resync_Error :: enum {
    None,

    // The session has no registry row, so it was never created.
    Unknown_Session,

    // The store refused a read; nothing about the session is known right now.
    Store_Failed,

    // The read model referenced a config revision it never announced — a cut that
    // references one is unusable to the replica.
    Corrupt_Log,

    // The finished cut failed the wire validator every outgoing frame is held to.
    Invalid_Cut,

    // Request scratch could not hold the live portion of the cut.
    Resource_Exhausted,
}

// `session.resync`: the full snapshot, read from the session's projections. Result data
// is built in `sa`, the per-frame arena the caller reclaims on return.
method_session_resync :: proc(conn: ^Conn, req: wire.Request, sa: mem.Allocator) {
    assert(conn != nil, "session.resync needs connection state")
    assert(conn.state == .Ready, "session.resync ran outside Ready")
    assert(req.method == .Session_Resync, "session.resync received another method")
    assert(conn.daemon != nil, "a connection always names its daemon")

    params := req.params.(wire.Session_Resync_Params)
    result, err := resync_build(conn.daemon, params, sa)

    switch err {
    case .None:
        send_result(conn, req.id, result, sa)

    case .Unknown_Session:
        send_error(conn, req.id, .Unknown_Session, "unknown session", sa)

    case .Store_Failed, .Corrupt_Log, .Invalid_Cut, .Resource_Exhausted:
        // All three are daemon-side faults: report `Internal`, keep the connection, and
        // never ship a snapshot we do not believe.
        send_error(conn, req.id, .Internal, "resync snapshot unavailable", sa)
    }
}

// Derive the cut from the read model: the transcript tail, announced configs, and
// open-run activity. The reads run to completion on the reactor thread, so the cut is one instant.
@(private)
resync_build :: proc(
    d: ^Daemon,
    params: wire.Session_Resync_Params,
    sa: mem.Allocator,
) -> (
    result: wire.Session_Resync_Result,
    err: Resync_Error,
) {
    assert(d != nil, "a resync cut needs daemon state")
    assert(wire.session_resync_params_validate(params) == .None, "a resync cut needs validated params")

    assert(d.store != nil, "a serving daemon always owns an event store")

    hw, herr := store.high_water(d.store, params.session_id)
    if herr != nil {
        log.errorf("daemon: resync high-water read failed: %v", herr)
        return {}, .Store_Failed
    }

    // The registry row is the existence test, not the high-water: `session.create` writes
    // the row, and a session that has never been written to still resyncs as an empty cut.
    snapshot, found, serr := store.session_snapshot(d.store, params.session_id, sa)
    if serr != nil {
        log.errorf("daemon: resync session read failed: %v", serr)
        return {}, .Store_Failed
    }
    if !found do return {}, .Unknown_Session

    page_size := wire.LIMITS.default_page_size
    if limit, ok := params.limit.?; ok do page_size = int(limit)

    assert(page_size > 0, "the page size is positive")
    assert(page_size <= wire.LIMITS.max_page_size, "the page size stays within the wire bound")

    // The page is the transcript's tail, oldest first; anything older is `has_more`.
    messages, merr := store.history_page(d.store, params.session_id, nil, page_size, sa)
    if merr != nil {
        log.errorf("daemon: resync history read failed: %v", merr)
        return {}, .Store_Failed
    }

    // The boundary is the store's minted mark, not the page's own maximum: truncated ids
    // and compaction dividers are finalized too, even once no message carries them.
    boundary: Maybe(wire.Message_Id)
    if hw.message_id > 0 do boundary = hw.message_id

    // The engine owns every live fact: a run does not outlive the process that started it,
    // so the log can say a run exists but never what it is producing.
    activity := session_activity(d, params.session_id)
    active, queued, draft_ok := session_draft(d, params.session_id, sa)
    if !draft_ok do return {}, .Resource_Exhausted

    configs := make([dynamic]wire.Run_Config, 0, len(messages) + 1, sa)

    // Collected first, and from the run itself rather than the store: the draft names this
    // revision, so a cut that could not resolve it would be unusable to the replica.
    if running, has_run := activity.config.?; has_run do append(&configs, running)

    for message in messages {
        assistant, is_assistant := message.(wire.Assistant_Message)
        if !is_assistant do continue

        resync_config_add(&configs, d.store, params.session_id, assistant.config_rev, sa) or_return
    }

    item := wire.Session_List_Item {
        session  = snapshot.session,
        activity = activity,
    }

    result = wire.Session_Resync_Result {
        item                         = item,
        base_seq                     = hw.seq,
        highest_finalized_message_id = boundary,
        messages                     = messages,
        has_more                     = snapshot.session.message_count > u64(len(messages)),
        configs                      = configs[:],
        active                       = active,
        queued                       = queued,
    }

    // The finalized mark and the transcript advance in one transaction, so a page above
    // the mark — or no mark under a non-empty page — means the two diverged on disk.
    if len(messages) > 0 {
        highest, finalized := boundary.?

        if !finalized || wire.message_id(messages[len(messages) - 1]) > highest {
            log.errorf("daemon: resync page tail rises above finalized mark %v", boundary)
            return {}, .Corrupt_Log
        }
    }

    if verr := wire.session_resync_result_validate(result); verr != .None {
        log.errorf("daemon: built an invalid resync cut: %v", verr)
        return {}, .Invalid_Cut
    }

    return result, .None
}

// The config `rev` names, once. A revision no `config.changed` announced cannot be
// resolved, and a cut that references one is unusable to the replica.
@(private)
resync_config_add :: proc(
    out: ^[dynamic]wire.Run_Config,
    s: ^store.Store,
    session: wire.Session_Id,
    rev: wire.Config_Rev,
    allocator: mem.Allocator,
) -> Resync_Error {
    assert(out != nil, "collecting configs needs its accumulator")
    assert(s != nil, "collecting configs needs a store")

    if resync_config_collected(out[:], rev) do return .None

    cfg, found, read_err := store.session_config(s, session, rev, allocator)
    if read_err != nil {
        log.errorf("daemon: resync config read failed: %v", read_err)
        return .Store_Failed
    }
    if !found {
        log.errorf("daemon: resync found no config.changed for revision %v", rev)
        return .Corrupt_Log
    }

    append(out, cfg)
    return .None
}

// Whether this cut already collected `rev`.
@(private)
resync_config_collected :: proc(configs: []wire.Run_Config, rev: wire.Config_Rev) -> bool {
    for candidate in configs {
        if candidate.config_rev == rev do return true
    }

    return false
}
