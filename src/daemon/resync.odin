package daemon

import "core:log"
import "core:mem"

import store "src:daemon/store"
import wire "src:wire"

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

    case .Store_Failed, .Corrupt_Log, .Invalid_Cut:
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
    if !found {
        return {}, .Unknown_Session
    }

    page_size := wire.LIMITS.default_page_size
    if limit, ok := params.limit.?; ok {
        page_size = int(limit)
    }

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
    if hw.message_id > 0 {
        boundary = hw.message_id
    }

    // The engine owns every live fact: a run does not outlive the process that started it,
    // so the log can say a run exists but never what it is producing.
    activity := session_activity(d, params.session_id)
    active, queued := session_draft(d, params.session_id, sa)

    configs := make([dynamic]wire.Run_Config, 0, len(messages) + 1, sa)

    // Collected first, and from the run itself rather than the store: the draft names this
    // revision, so a cut that could not resolve it would be unusable to the replica.
    if running, has_run := activity.config.?; has_run {
        append(&configs, running)
    }

    for message in messages {
        assistant, is_assistant := message.(wire.Assistant_Message)
        if !is_assistant {
            continue
        }

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

    if _, collected := resync_config_find(out[:], rev); collected {
        return .None
    }

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

// Find a revision already collected for this cut.
@(private)
resync_config_find :: proc(configs: []wire.Run_Config, rev: wire.Config_Rev) -> (cfg: wire.Run_Config, ok: bool) {
    for candidate in configs {
        if candidate.config_rev == rev {
            return candidate, true
        }
    }

    return {}, false
}
