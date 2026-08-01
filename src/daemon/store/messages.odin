package store

import "core:mem"

import "libs:bindings/sqlite"
import "src:wire"

// One projected transcript row. Scalars and a pointer only: `seq` locates the
// body in `events`, which stays the single copy of the message itself.
@(private)
Insert_Message_Params :: struct {
    session_id:         wire.Session_Id,
    message_id:         wire.Message_Id,
    seq:                wire.Seq,
    role:               string,
    run_id:             Maybe(wire.Run_Id),
    config_rev:         Maybe(wire.Config_Rev),
    model:              Maybe(string),
    protocol:           Maybe(string),
    finish:             Maybe(string),
    tokens_input:       Maybe(u64),
    tokens_output:      Maybe(u64),
    tokens_reasoning:   Maybe(u64),
    tokens_cache_read:  Maybe(u64),
    tokens_cache_write: Maybe(u64),
    cost:               Maybe(f64),
    created_at_ms:      u64,
}

@(private)
Truncate_Messages_Params :: struct {
    session_id:       wire.Session_Id,
    first_removed_id: wire.Message_Id,
}

@(private)
Count_Messages_Params :: struct {
    session_id:    wire.Session_Id,
    delta:         i64,
    updated_at_ms: Maybe(u64),
}

// Fold one durable event into the transcript projection. Runs inside the append
// transaction, so the projection cannot survive an event that rolled back.
// Events that say nothing about the transcript project nothing.
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

    params := Insert_Message_Params {
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

        // `config_rev` records what the turn was *requested* under; provenance
        // records what answered, which is the only correct source for "which
        // model produced this".
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
    sqlite.execute(&s.binds.insert_message, &params) or_return

    return messages_count_add(s, session, 1, params.created_at_ms)
}

// Apply a truncation marker: it is appended *after* the messages it removes, so
// the projection deletes the tail rather than mirroring the log row for row.
// The id marks deliberately do not move — a discarded id stays spent.
@(private)
messages_truncate :: proc(s: ^Store, session: wire.Session_Id, first_removed_id: wire.Message_Id) -> Error {
    assert(s != nil, "messages_truncate needs a store")
    assert(first_removed_id > 0, "a truncation starts at a minted message id")

    sqlite.execute(
        &s.binds.truncate_messages,
        &Truncate_Messages_Params{session_id = session, first_removed_id = first_removed_id},
    ) or_return

    removed := sqlite.changes(s.writer)
    assert(removed >= 0, "a delete never reports a negative row count")

    if removed == 0 {
        return nil
    }

    // The marker carries no timestamp, so the update mark is left where it is
    // rather than invented.
    return messages_count_add(s, session, -i64(removed), nil)
}

// Move `sessions.message_count` by `delta` and raise the update mark. The
// schema's `message_count >= 0` check is the drift alarm: the projection and the
// count are written in one transaction, so they cannot disagree.
@(private)
messages_count_add :: proc(s: ^Store, session: wire.Session_Id, delta: i64, updated_at_ms: Maybe(u64)) -> Error {
    assert(s != nil, "messages_count_add needs a store")
    assert(delta != 0, "a count update moves the count")

    sqlite.execute(
        &s.binds.count_messages,
        &Count_Messages_Params{session_id = session, delta = delta, updated_at_ms = updated_at_ms},
    ) or_return
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

// Drop and rebuild one session's projection by replaying its log. The projection holds no
// fact the log doesn't, which is why it can reshape without a migration and why
// `events.payload` must stay verbatim JSON. Runs in one transaction; `sa` is caller-owned scratch.
messages_rebuild :: proc(s: ^Store, session: wire.Session_Id, sa := context.temp_allocator) -> (err: Error) {
    assert(s != nil, "messages_rebuild needs a store")
    assert(s.writer != nil, "an open store always holds its writer")

    sqlite.txn_begin(s.writer, .Immediate) or_return

    defer if err != nil {
        if rollback := sqlite.txn_rollback(s.writer); rollback != .Ok {
            err = rollback
        }
    }

    // Ids start at 1, so truncating from there clears the session and carries the
    // count back to zero through the same path a real truncation takes.
    messages_truncate(s, session, 1) or_return

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
            messages_rebuild_visit,
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

@(private)
messages_rebuild_visit :: proc(user: rawptr, event: Event) -> Event_Visit {
    rebuild := (^Messages_Rebuild)(user)
    assert(rebuild != nil, "a replay needs its state")
    assert(rebuild.err == nil, "a replay stops after its first error")
    defer delete(event.payload, rebuild.scratch)

    rebuild.last = event.seq

    // Only two of the five durable names say anything about the transcript, so the
    // rest never pay a decode.
    #partial switch event.name {
    case .Message_Committed, .Transcript_Truncated:
    case:
        return .Continue
    }

    d := wire.decoder_init(event.payload, rebuild.scratch)
    data, derr := wire.broadcast_data_from_reader(event.name, &d)

    // A row the codec refuses is damage, not a programmer error: the rebuild reports it
    // rather than asserting on file contents. Validation runs here too, since a replay must
    // arrive with the same guarantee the live path gets from the pump's validated payload.
    if derr != .None || wire.broadcast_data_validate(data) != .None {
        rebuild.err = Store_Error.Invalid_Row

        return .Stop
    }

    if aerr := messages_apply(rebuild.store, rebuild.session, event.seq, data); aerr != nil {
        rebuild.err = aerr

        return .Stop
    }

    return .Continue
}
