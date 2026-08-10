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

    // The session has no durable stream, so nothing ever wrote it.
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

    // Nothing durable exists without a store, so no session does either.
    if d.store == nil {
        return {}, .Unknown_Session
    }

    hw, herr := store.high_water(d.store, params.session_id)
    if herr != nil {
        log.errorf("daemon: resync high-water read failed: %v", herr)
        return {}, .Store_Failed
    }

    // The high-water is the session's existence test: the pump advances it in the same
    // transaction as the first row. `d.seq_high` lags the log it recovers from, so it is not consulted.
    if hw.seq == 0 {
        return {}, .Unknown_Session
    }

    // Message count and open-run activity, from the session row the projections maintain.
    activity_row, aerr := store.session_activity(d.store, params.session_id, sa)
    if aerr != nil {
        log.errorf("daemon: resync activity read failed: %v", aerr)
        return {}, .Store_Failed
    }

    // Every announced config revision, so a message's `config_rev` resolves without a fold.
    known, cerr := store.session_configs(d.store, params.session_id, sa)
    if cerr != nil {
        log.errorf("daemon: resync config read failed: %v", cerr)
        return {}, .Store_Failed
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

    total := int(activity_row.message_count)

    // The boundary is the store's minted mark, not the page's own maximum: truncated ids
    // and compaction dividers are finalized too, even once no message carries them.
    boundary: Maybe(wire.Message_Id)
    if hw.message_id > 0 {
        boundary = hw.message_id
    }

    activity := wire.Session_Activity {
        state = wire.Activity_State_Idle{},
    }

    configs := make([dynamic]wire.Run_Config, 0, len(messages) + 1, sa)

    // Until the session engine supplies its live state, the open run is the only activity
    // the log reconstructs. Drafts and queued inputs are not rebuilt here.
    if open, running := activity_row.open_run.?; running {
        switch open.kind {
        case .Turn:
            // The turn's config is collected like every other, so an unannounced
            // revision is diagnosed in one place.
            resync_config_add(&configs, known, open.config_rev) or_return
            assert(len(configs) == 1, "the running config is the first one collected")

            activity.state = wire.Activity_State_Running {
                run_id        = open.run_id,
                started_at_ms = open.started_at_ms,
            }
            activity.config = configs[0]

        case .Compaction:
            reason, has_reason := open.reason.?
            assert(has_reason, "a compaction run carries its reason")

            // `Activity_State_Compacting` carries no config; the run's revision is not
            // hoisted or added to the configs page, which is why the wire type omits it.
            activity.state = wire.Activity_State_Compacting {
                run_id        = open.run_id,
                reason        = reason,
                started_at_ms = open.started_at_ms,
            }
        }
    }

    for message in messages {
        assistant, is_assistant := message.(wire.Assistant_Message)
        if !is_assistant {
            continue
        }

        resync_config_add(&configs, known, assistant.config_rev) or_return
    }

    // This summary is a placeholder until the session engine exists; it will be replaced
    // with the same derived row used by session.list and summary_changed.
    current := resync_current_config(known)
    item := wire.Session_List_Item {
        session = wire.Session {
            id = params.session_id,
            workspace_id = wire.Workspace_Id(resync_unset_id()),
            model = current.model,
            reasoning = current.reasoning,
            config_rev = current.config_rev,
            permission = .Strict,
            message_count = u64(total),
            created_by = wire.Client{},
            origin = wire.Session_Origin_Root{},
        },
        activity = activity,
    }

    result = wire.Session_Resync_Result {
        item                         = item,
        base_seq                     = hw.seq,
        highest_finalized_message_id = boundary,
        messages                     = messages,
        has_more                     = total > len(messages),
        configs                      = configs[:],
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
    known: []wire.Run_Config,
    rev: wire.Config_Rev,
) -> Resync_Error {
    assert(out != nil, "collecting configs needs its accumulator")

    if _, collected := resync_config_find(out[:], rev); collected {
        return .None
    }

    cfg, found := resync_config_find(known, rev)
    if !found {
        log.errorf("daemon: resync found no config.changed for revision %v", rev)
        return .Corrupt_Log
    }

    append(out, cfg)
    return .None
}

// The last announcement of `rev`; `ok` is false when the log never announced it.
@(private)
resync_config_find :: proc(known: []wire.Run_Config, rev: wire.Config_Rev) -> (cfg: wire.Run_Config, ok: bool) {
    #reverse for candidate in known {
        if candidate.config_rev == rev {
            return candidate, true
        }
    }

    return {}, false
}

// The session's live config: the newest `config.changed`, or nothing when the log has
// none yet. `known` is ordered oldest first, so the last row is newest.
@(private)
resync_current_config :: proc(known: []wire.Run_Config) -> wire.Run_Config {
    if len(known) == 0 {
        return {}
    }

    return known[len(known) - 1]
}

// The temporary workspace id used until the session engine owns the summary.
@(private)
resync_unset_id :: proc() -> [16]u8 {
    out: [16]u8
    for i in 0 ..< 16 {
        out[i] = '0'
    }

    return out
}
