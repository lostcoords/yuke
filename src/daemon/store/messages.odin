package store

import "core:mem"

import "src:daemon/store/queries"
import "src:wire"

import "libs:bindings/sqlite"

// Fold one durable event into the transcript projection, inside the append transaction
// so the projection cannot survive a rollback. Events that say nothing project nothing.
@(private)
messages_apply :: proc(s: ^Store, session: wire.Session_Id, seq: wire.Seq, data: wire.Broadcast_Data) -> Error {
    assert(s != nil, "messages_apply needs a store")
    assert(s.writer != nil, "messages_apply needs an open writer")
    assert(seq > 0, "messages_apply receives a positive seq")

    #partial switch v in data {
    case wire.Message_Committed_Data:
        return messages_insert(s, session, seq, v.message)

    case wire.Transcript_Truncated_Data:
        return messages_truncate(s, session, v.first_removed_id)
    }

    return nil
}

// Project one committed message and raise the session's count and update mark.
@(private)
messages_insert :: proc(s: ^Store, session: wire.Session_Id, seq: wire.Seq, message: wire.Message) -> Error {
    assert(s != nil, "messages_insert needs a store")
    assert(message != nil, "a committed event carries its message")

    params := queries.Insert_Message_Params {
        session_id = session,
        message_id = wire.message_id(message),
        seq        = seq,
        role       = wire.message_type_to_wire(message),
    }

    switch m in message {
    case wire.User_Message:
        params.created_at_ms = m.time.created_at_ms

    case wire.Assistant_Message:
        params.run_id = m.run_id
        params.config_rev = m.config_rev
        params.created_at_ms = m.time.created_at_ms
        params.cost = m.cost

        if finish, ok := m.finish.?; ok {
            params.finish = wire.stop_reason_to_wire(finish)
        }

        // `config_rev` records what the turn was *requested* under; provenance records what
        // answered, the only correct source for "which model produced this".
        if prov, ok := m.provenance.?; ok {
            params.model = prov.model
            params.protocol = wire.provider_protocol_to_wire(prov.protocol)
        }

        if usage, ok := m.tokens.?; ok {
            params.tokens_input = usage.input
            params.tokens_output = usage.output
            params.tokens_reasoning = usage.reasoning
            params.tokens_cache_read = usage.cache_read
            params.tokens_cache_write = usage.cache_write
        }

    case wire.Compaction_Message:
        params.run_id = m.run_id
        params.created_at_ms = m.time.created_at_ms
    }

    assert(params.message_id > 0, "a committed message carries a minted id")
    sqlite.execute(&s.inserts.insert_message, &params) or_return

    // The lifetime totals are monotonic, so only a committed assistant turn folds in; a
    // truncation removing this row later never subtracts it.
    if assistant, is_assistant := message.(wire.Assistant_Message); is_assistant {
        if usage, ok := assistant.tokens.?; ok {
            queries.add_session_usage(
                &s.queries,
                {
                    session_id = session,
                    input = usage.input,
                    output = usage.output,
                    reasoning = usage.reasoning,
                    cache_read = usage.cache_read,
                    cache_write = usage.cache_write,
                },
            ) or_return
        }
    }

    return messages_count_add(s, session, 1, params.created_at_ms)
}

// Apply a truncation marker: appended *after* the messages it removes, so the projection
// deletes the tail rather than mirroring row for row. Id marks stay put — a discarded id stays spent.
@(private)
messages_truncate :: proc(s: ^Store, session: wire.Session_Id, first_removed_id: wire.Message_Id) -> Error {
    assert(s != nil, "messages_truncate needs a store")
    assert(first_removed_id > 0, "a truncation starts at a minted message id")

    queries.truncate_messages(&s.queries, {session_id = session, first_removed_id = first_removed_id}) or_return

    removed := sqlite.changes(s.writer)
    assert(removed >= 0, "a delete never reports a negative row count")

    if removed == 0 {
        return nil
    }

    // The marker carries no timestamp, so the update mark is left where it is
    // rather than invented.
    return messages_count_add(s, session, -i64(removed), nil)
}

// Move `sessions.message_count` by `delta` and raise the update mark. The schema's
// `message_count >= 0` check is the drift alarm: the projection and count are written in one transaction.
@(private)
messages_count_add :: proc(s: ^Store, session: wire.Session_Id, delta: i64, updated_at_ms: Maybe(u64)) -> Error {
    assert(s != nil, "messages_count_add needs a store")
    assert(delta != 0, "a count update moves the count")

    queries.count_messages(&s.queries, {session_id = session, delta = delta, updated_at_ms = updated_at_ms}) or_return
    assert(sqlite.changes(s.writer) == 1, "the count update lands on the append's session row")

    return nil
}

// Rebuild state threaded through a replay.
@(private)
Messages_Rebuild :: struct {
    store:   ^Store,
    session: wire.Session_Id,
    scratch: mem.Allocator,
    last:    wire.Seq,
    err:     Error,
}

// Drop and rebuild one session's projection by replaying its log; it holds no fact the log
// doesn't, so `events.payload` must stay verbatim JSON. Runs in one transaction; `sa` is scratch.
projection_rebuild :: proc(s: ^Store, session: wire.Session_Id, sa := context.temp_allocator) -> (err: Error) {
    assert(s != nil, "projection_rebuild needs a store")
    assert(s.writer != nil, "an open store always holds its writer")

    sqlite.txn_begin(s.writer, .Immediate) or_return

    defer if err != nil {
        if rollback := sqlite.txn_rollback(s.writer); rollback != .Ok {
            err = rollback
        }
    }

    // Reset all three projections to empty, then replay. Ids start at 1, so truncating from there
    // clears the transcript and carries the count back to zero through the same path a real truncation takes.
    messages_truncate(s, session, 1) or_return
    queries.clear_configs(&s.queries, {session_id = session}) or_return
    queries.reset_open_run(&s.queries, {session_id = session}) or_return
    queries.reset_session_usage(&s.queries, {session_id = session}) or_return

    rebuild := Messages_Rebuild {
        store   = s,
        session = session,
        scratch = sa,
    }

    // The tail read is bounded, so the replay pages until the log is exhausted.
    for {
        visited, _, verr := events_visit_after(
            s,
            session,
            rebuild.last,
            REBUILD_PAGE,
            projection_rebuild_visit,
            &rebuild,
            sa,
        )

        if verr != nil {
            return verr
        }

        if rebuild.err != nil {
            return rebuild.err
        }

        // A short page is the end of the log; a full one may have more behind it.
        if visited < REBUILD_PAGE {
            break
        }
    }

    return sqlite.txn_commit(s.writer)
}

// Rows per replay page. The log is read in bounded pages so a long transcript
// never materializes at once.
@(private)
REBUILD_PAGE :: 256

// Decode and validate one stored durable event body. A row the codec or validator rejects is
// on-disk damage — `Invalid_Row`, reported not asserted, matching the guarantee the pump gives the live path.
@(private)
durable_decode :: proc(
    name: wire.Broadcast_Name,
    payload: string,
    allocator: mem.Allocator,
) -> (
    wire.Broadcast_Data,
    Error,
) {
    dec := wire.decoder_init(payload, allocator)

    data, derr := wire.broadcast_data_from_reader(name, &dec)
    if derr != .None || wire.broadcast_data_validate(data) != .None {
        return {}, Store_Error.Invalid_Row
    }

    return data, nil
}

@(private)
projection_rebuild_visit :: proc(user: rawptr, event: Event) -> Event_Visit {
    rebuild := (^Messages_Rebuild)(user)
    assert(rebuild != nil, "a replay needs its state")
    assert(rebuild.err == nil, "a replay stops after its first error")
    defer delete(event.payload, rebuild.scratch)

    rebuild.last = event.seq

    // Every durable name projects something — transcript, config, or open run — and the walk
    // already refused every row that is not durable, so all five decode.
    assert(wire.broadcast_name_class(event.name) == .Durable_Gated, "a replay visits only durable events")

    data, decode_err := durable_decode(event.name, event.payload, rebuild.scratch)
    if decode_err != nil {
        rebuild.err = decode_err

        return .Stop
    }

    if aerr := messages_apply(rebuild.store, rebuild.session, event.seq, data); aerr != nil {
        rebuild.err = aerr

        return .Stop
    }

    if aerr := configs_apply(rebuild.store, rebuild.session, data); aerr != nil {
        rebuild.err = aerr

        return .Stop
    }

    if aerr := runs_apply(rebuild.store, rebuild.session, data); aerr != nil {
        rebuild.err = aerr

        return .Stop
    }

    return .Continue
}

// The transcript tail as `session.history` pages it: the newest `limit` messages, decoded from
// `events` and returned oldest first. A null cursor starts at the newest; a rejected payload is `Invalid_Row`.
history_page :: proc(
    s: ^Store,
    session: wire.Session_Id,
    cursor: Maybe(wire.Message_Id),
    limit: int,
    allocator: mem.Allocator,
) -> (
    messages: []wire.Message,
    err: Error,
) {
    assert(s != nil, "history_page needs a store")
    assert(s.writer != nil, "an open store always holds its writer")
    assert(limit > 0, "a history page is bounded")
    assert(allocator.procedure != nil, "a history page needs an allocator")

    read, sqlite_err := queries.session_history_page(
        &s.queries,
        {session_id = session, cursor_message_id = cursor, limit = limit},
        allocator,
        cap_hint = limit,
    )
    if sqlite_err != nil {
        return nil, read_err(sqlite_err)
    }

    out, alloc_err := make([]wire.Message, len(read), allocator)
    if alloc_err != nil {
        return nil, Store_Error.Alloc_Failed
    }

    // The rows arrive newest first off the keyset; the page ships oldest first.
    n := len(read)
    for row, i in read {
        data, decode_err := durable_decode(.Message_Committed, row.payload, allocator)
        if decode_err != nil {
            return nil, decode_err
        }

        committed, is_committed := data.(wire.Message_Committed_Data)
        if !is_committed {
            return nil, Store_Error.Invalid_Row
        }

        // The projection's id indexes this row; a payload whose id disagrees is damaged,
        // since the two were written from one event in one transaction.
        if wire.message_id(committed.message) != row.message_id {
            return nil, Store_Error.Invalid_Row
        }

        out[n - 1 - i] = committed.message
    }

    return out, nil
}

// Token usage of the newest committed assistant turn that reported it; `found` is false when
// none has yet. `input` already folds the cache read/write subsets.
messages_last_usage :: proc(
    s: ^Store,
    session: wire.Session_Id,
) -> (
    usage: wire.Token_Usage,
    found: bool,
    err: Error,
) {
    assert(s != nil, "messages_last_usage needs a store")
    assert(s.writer != nil, "an open store always holds its writer")

    row, sqlite_err := queries.last_assistant_usage(&s.queries, {session_id = session})
    if sqlite_err != nil {
        if count_err, is_count := sqlite_err.(sqlite.Read_Error); is_count && count_err == .Row_Count {
            return {}, false, nil
        }

        return {}, false, read_err(sqlite_err)
    }

    usage = wire.Token_Usage {
        input       = row.tokens_input.? or_else 0,
        output      = row.tokens_output.? or_else 0,
        reasoning   = row.tokens_reasoning.? or_else 0,
        cache_read  = row.tokens_cache_read.? or_else 0,
        cache_write = row.tokens_cache_write.? or_else 0,
    }

    return usage, true, nil
}
