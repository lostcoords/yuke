package daemon

import "core:log"
import "core:mem"

import store "src:daemon/store"
import wire "src:wire"

// Rows one fold read pulls off the log. The whole log is folded either way; this only
// bounds how much of it a single statement materializes.
RESYNC_CHUNK :: 512

#assert(wire.LIMITS.max_snapshot_configs >= wire.LIMITS.max_page_size + 1)

// Why a resync cut could not be built. Only `Unknown_Session` names something the
// client did; the rest are faults in our own log or in the cut we derived from it.
Resync_Error :: enum {
    // No error.
    None,

    // The session has no durable stream, so nothing ever wrote it.
    Unknown_Session,

    // The store refused a read; nothing about the session is known right now.
    Store_Failed,

    // The log did not fold into a cut: an invalid row, non-rising transcript ids,
    // overlapping runs, or inconsistent or missing config revision evidence.
    Corrupt_Log,

    // The finished cut failed the wire validator every outgoing frame is held to.
    Invalid_Cut,
}

// A run the fold left open: a `run.started` no `run.done` closed.
Resync_Open_Run :: struct {
    // Run the session is executing.
    run_id:        wire.Run_Id,

    // What kind of run is open.
    kind:          wire.Run_Kind,

    // Why compaction is running; present exactly when `kind` is compaction.
    reason:        Maybe(wire.Compaction_Reason),

    // Config revision it runs under; resolved against the folded configs.
    config_rev:    wire.Config_Rev,

    // Run start epoch ms, as `run.started` recorded it.
    started_at_ms: u64,
}

// A session's durable log folded into the pieces the cut is assembled from. Every
// slice lives in the frame arena the handler was given.
Resync_Fold :: struct {
    // Committed transcript, oldest first, with truncated tails already removed.
    messages: [dynamic]wire.Message,

    // Every config revision the log announced, in announcement order.
    configs:  [dynamic]wire.Run_Config,

    // Highest message id the log committed; zero until one is, since id 0 is never
    // minted. Truncation never lowers it, so every later commit must rise past every
    // id ever committed.
    highest:  wire.Message_Id,

    // Run still open at the cut, if any.
    run:      Maybe(Resync_Open_Run),
}

// `session.resync`: the full snapshot, folded from the session's durable log. Result
// data is built in `sa`, the per-frame arena the caller reclaims on return.
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
        // A cut our own validator rejects, a log row the codec rejects, and a refused
        // read are all daemon-side faults: report `Internal` and keep the connection,
        // never ship a snapshot we do not believe.
        send_error(conn, req.id, .Internal, "resync snapshot unavailable", sa)
    }
}

// Derive the cut. The high-water read, the fold, and the send all run to completion on
// the reactor thread, so no commit can interleave and the whole cut is one instant.
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

    session := params.session_id

    hw, herr := store.high_water(d.store, session)
    if herr != nil {
        log.errorf("daemon: resync high-water read failed: %v", herr)

        return {}, .Store_Failed
    }

    // The high-water is the session's existence test: the log is the only place a
    // session is ever written, and the pump advances this mark in the same
    // transaction as the first row. `d.seq_high` is deliberately not consulted — it
    // is the pump's minting cache and may lag the log it recovers from.
    if hw.seq == 0 {
        return {}, .Unknown_Session
    }

    fold := resync_fold(d, session, hw.seq, sa) or_return

    // The mark and the log advance in one transaction, so a mark below an id the log
    // committed means the two diverged on disk.
    if hw.message_id < fold.highest {
        log.errorf("daemon: resync found message mark %v below committed id %v", hw.message_id, fold.highest)

        return {}, .Corrupt_Log
    }

    // The finalized boundary is the store's minted mark rather than the fold's own
    // maximum: truncated ids and compaction dividers are finalized too, and the mark
    // still covers them once no message in the transcript carries them.
    boundary: Maybe(wire.Message_Id)

    if hw.message_id > 0 {
        boundary = hw.message_id
    }

    page_size := wire.LIMITS.default_page_size

    if limit, ok := params.limit.?; ok {
        page_size = int(limit)
    }

    assert(page_size > 0, "the page size is positive")
    assert(page_size <= wire.LIMITS.max_page_size, "the page size stays within the wire bound")

    // The page is the transcript's tail; anything older is what `has_more` announces.
    total := len(fold.messages)
    first := max(0, total - page_size)
    messages := fold.messages[first:]

    activity := wire.Session_Activity {
        state = wire.Activity_State_Idle{},
    }

    configs := make([dynamic]wire.Run_Config, 0, len(messages) + 1, sa)

    // Until the session engine supplies its live state, the log can report only the
    // durable run activity. Drafts and queued inputs are not reconstructed here.
    if open, running := fold.run.?; running {
        switch open.kind {
        case .Turn:
            // The turn's config is collected like every other, so an unannounced
            // revision is diagnosed in one place.
            resync_config_add(&configs, fold.configs[:], open.config_rev) or_return
            assert(len(configs) == 1, "the running config is the first one collected")

            activity.state = wire.Activity_State_Running {
                run_id        = open.run_id,
                started_at_ms = open.started_at_ms,
            }
            activity.config = configs[0]

        case .Compaction:
            reason, has_reason := open.reason.?
            assert(has_reason, "a compaction run's reason is validated present at decode")

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

        resync_config_add(&configs, fold.configs[:], assistant.config_rev) or_return
    }

    // This summary is a placeholder until the session engine exists; it will be replaced
    // with the same derived row used by session.list and summary_changed.
    current := resync_current_config(fold.configs[:])
    item := wire.Session_List_Item {
        session = wire.Session {
            id = session,
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
        has_more                     = first > 0,
        configs                      = configs[:],
    }

    // The replica rejects a page that is not under a present boundary, and our own
    // validator does not cross-check the two.
    if total > 0 {
        highest, finalized := boundary.?
        assert(finalized, "a page implies a finalized boundary")
        assert(wire.message_id(messages[len(messages) - 1]) <= highest, "the page stays under the finalized boundary")
    }

    if verr := wire.session_resync_result_validate(result); verr != .None {
        log.errorf("daemon: built an invalid resync cut: %v", verr)

        return {}, .Invalid_Cut
    }

    return result, .None
}

// Fold the whole log, oldest row first. Payloads are read into the frame arena and
// retained because the decoded cut borrows from them for the rest of the frame.
@(private)
resync_fold :: proc(
    d: ^Daemon,
    session: wire.Session_Id,
    base_seq: wire.Seq,
    sa: mem.Allocator,
) -> (
    fold: Resync_Fold,
    err: Resync_Error,
) {
    assert(d != nil, "a fold needs daemon state")
    assert(d.store != nil, "a fold needs an open store")
    assert(base_seq > 0, "a folded session has a committed stream")

    // The frame arena cannot reclaim a superseded backing array, so growth by doubling
    // strands roughly the final size again. Every row contributes at most one message
    // and at most one config, so the high-water bounds both; the read chunk caps what a
    // long log reserves up front.
    hint := min(int(base_seq), RESYNC_CHUNK)
    fold.messages = make([dynamic]wire.Message, 0, hint, sa)
    fold.configs = make([dynamic]wire.Run_Config, 0, hint, sa)

    visit := Resync_Fold_Visit {
        fold      = &fold,
        session   = session,
        base_seq  = base_seq,
        allocator = sa,
    }
    for {
        visited, stopped, rerr := store.events_visit_after(
            d.store,
            session,
            visit.after,
            RESYNC_CHUNK,
            resync_fold_visit,
            &visit,
            sa,
        )
        if rerr != nil {
            log.errorf("daemon: resync log read failed: %v", rerr)

            return {}, .Store_Failed
        }

        if stopped {
            assert(visit.err != .None, "the resync visitor stops only on a fold error")

            return {}, visit.err
        }

        if visited < RESYNC_CHUNK {
            break
        }
    }

    if visit.after != base_seq {
        log.errorf("daemon: resync log ended at seq %v below high-water %v", visit.after, base_seq)

        return {}, .Corrupt_Log
    }

    return fold, .None
}

@(private)
Resync_Fold_Visit :: struct {
    fold:      ^Resync_Fold,
    session:   wire.Session_Id,
    base_seq:  wire.Seq,
    after:     wire.Seq,
    allocator: mem.Allocator,
    err:       Resync_Error,
}

@(private)
resync_fold_visit :: proc(user: rawptr, event: store.Event) -> store.Event_Visit {
    visit := (^Resync_Fold_Visit)(user)
    assert(visit != nil, "a resync visit needs fold state")
    assert(visit.fold != nil, "a resync visit needs its accumulator")
    assert(visit.err == .None, "a failed fold accepts no more rows")

    if event.seq != visit.after + 1 {
        log.errorf("daemon: resync found a gap between seq %v and %v", visit.after, event.seq)
        visit.err = .Corrupt_Log

        return .Stop
    }

    if event.seq > visit.base_seq {
        log.errorf("daemon: resync found row seq %v above high-water %v", event.seq, visit.base_seq)
        visit.err = .Corrupt_Log

        return .Stop
    }

    visit.after = event.seq
    visit.err = resync_fold_event(visit.fold, visit.session, event, visit.allocator)

    return .Continue if visit.err == .None else .Stop
}

// Apply one durable row. These five durable broadcasts are the fold's whole input
// today; the session engine will supply the remaining live state.
@(private)
resync_fold_event :: proc(
    fold: ^Resync_Fold,
    session: wire.Session_Id,
    ev: store.Event,
    sa: mem.Allocator,
) -> Resync_Error {
    assert(fold != nil, "folding needs its accumulator")
    assert(wire.broadcast_name_class(ev.name) == .Durable_Gated, "the store returns durable rows only")

    dec := wire.decoder_init(ev.payload, sa)

    // A stored row the codec rejects is persisted corruption, never peer input.
    data, derr := wire.broadcast_data_from_reader(ev.name, &dec)
    if derr != .None {
        log.errorf("daemon: resync could not decode seq %v (%v): %v", ev.seq, ev.name, derr)

        return .Corrupt_Log
    }

    if ferr := wire.dec_finish(&dec); ferr != .None {
        log.errorf("daemon: resync found trailing data at seq %v (%v)", ev.seq, ev.name)

        return .Corrupt_Log
    }

    if verr := wire.broadcast_data_validate(data); verr != .None {
        log.errorf("daemon: resync found invalid data at seq %v (%v): %v", ev.seq, ev.name, verr)

        return .Corrupt_Log
    }

    arm, typed := wire.broadcast_data_name(data)
    assert(typed, "the codec returns a typed broadcast payload")
    assert(arm == ev.name, "the codec decodes a row into the arm its name selects")

    payload_session, named := wire.broadcast_data_session_id(data).?
    assert(named, "a durable payload names its session")

    if payload_session != session {
        log.errorf("daemon: resync found another session in seq %v (%v)", ev.seq, ev.name)

        return .Corrupt_Log
    }

    payload_seq, sequenced := wire.broadcast_data_seq(data).?
    assert(sequenced, "a durable payload carries its seq")

    if payload_seq != ev.seq {
        log.errorf("daemon: resync row seq %v carries payload seq %v", ev.seq, payload_seq)

        return .Corrupt_Log
    }

    // The class check above admits only the five durable arms.
    #partial switch v in data {
    case wire.Message_Committed_Data:
        id := wire.message_id(v.message)

        // Message ids are minted as `high_water + 1` from a mark that starts at zero,
        // so zero is never one the daemon handed out.
        if id == 0 {
            log.error("daemon: resync found a committed message with id 0, which is never minted")

            return .Corrupt_Log
        }

        // The minted high-water survives truncation, so a later commit must rise past
        // every id ever committed, not merely the visible transcript tail.
        if id <= fold.highest {
            log.errorf("daemon: resync found message id %v at or below high-water %v", id, fold.highest)

            return .Corrupt_Log
        }

        switch m in v.message {
        case wire.User_Message:
            if m.input_id == 0 {
                log.errorf("daemon: resync found user message %v with input id 0", id)

                return .Corrupt_Log
            }

        case wire.Assistant_Message:
            if m.run_id == 0 {
                log.errorf("daemon: resync found assistant message %v with run id 0", id)

                return .Corrupt_Log
            }

        case wire.Compaction_Message:
            if m.run_id == 0 {
                log.errorf("daemon: resync found compaction message %v with run id 0", id)

                return .Corrupt_Log
            }

            if first, kept := m.first_kept_id.?; kept && first == 0 {
                log.errorf("daemon: resync found compaction message %v keeping id 0", id)

                return .Corrupt_Log
            }
        }

        append(&fold.messages, v.message)
        fold.highest = id

        return .None

    case wire.Transcript_Truncated_Data:
        if v.first_removed_id == 0 {
            log.error("daemon: resync found a truncation beginning at message id 0")

            return .Corrupt_Log
        }

        // Truncation removes the newest messages; `highest` deliberately stays put,
        // because a discarded id is finalized too.
        for len(fold.messages) > 0 && wire.message_id(fold.messages[len(fold.messages) - 1]) >= v.first_removed_id {
            pop(&fold.messages)
        }

        return .None

    case wire.Config_Changed_Data:
        if prior, announced := resync_config_find(fold.configs[:], v.config.config_rev); announced {
            if prior.model != v.config.model || prior.reasoning != v.config.reasoning {
                log.errorf("daemon: resync found conflicting config revision %v", v.config.config_rev)

                return .Corrupt_Log
            }

            return .None
        }

        append(&fold.configs, v.config)

        return .None

    case wire.Run_Started_Data:
        if v.run_id == 0 {
            log.error("daemon: resync found a started run with id 0")

            return .Corrupt_Log
        }

        if _, running := fold.run.?; running {
            log.errorf("daemon: resync found run %v starting while another run was open", v.run_id)

            return .Corrupt_Log
        }

        fold.run = Resync_Open_Run {
            run_id        = v.run_id,
            kind          = v.kind,
            reason        = v.reason,
            config_rev    = v.config_rev,
            started_at_ms = v.started_at_ms,
        }

        return .None

    case wire.Run_Done_Data:
        if v.run_id == 0 {
            log.error("daemon: resync found a finished run with id 0")

            return .Corrupt_Log
        }

        if compacted, ok := v.outcome.(wire.Run_Outcome_Compacted); ok && compacted.message_id == 0 {
            log.errorf("daemon: resync found run %v compacting to message id 0", v.run_id)

            return .Corrupt_Log
        }

        // A run canceled while queued terminates without ever having started, so only
        // the matching id closes the open run.
        if open, running := fold.run.?; running && open.run_id == v.run_id {
            fold.run = nil
        }

        return .None
    }

    unreachable()
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
// none yet.
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
