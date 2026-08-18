package store
import "libs:json"

import "core:strings"
import "core:testing"

import "libs:bindings/sqlite"
import "libs:testsupport"
import "src:wire"

@(private = "file")
message_row_count :: proc(s: ^Store, session: wire.Session_Id) -> i64 {
    st, prep := sqlite.prepare(s.writer, "SELECT count(*) FROM messages WHERE session_id = ?1")
    if prep != .Ok do return -1
    defer sqlite.finalize(st)

    sid := ([16]u8)(session)
    if sqlite.bind_blob(st, 1, sid[:]) != .Ok || sqlite.step(st) != .Row do return -1

    return sqlite.column_i64(st, 0)
}

@(private)
session_message_count :: proc(s: ^Store, session: wire.Session_Id) -> i64 {
    st, prep := sqlite.prepare(s.writer, "SELECT message_count FROM sessions WHERE id = ?1")
    if prep != .Ok do return -1
    defer sqlite.finalize(st)

    sid := ([16]u8)(session)
    if sqlite.bind_blob(st, 1, sid[:]) != .Ok || sqlite.step(st) != .Row do return -1

    return sqlite.column_i64(st, 0)
}

// An assistant turn projects its scalars, and `model` comes from provenance —
// what answered — rather than from the `config_rev` it was requested under.
@(test)
test_committed_assistant_projects_provenance_not_config :: proc(t: ^testing.T) {
    path := testsupport.sqlite_db_path(t, "project-assistant")
    defer testsupport.sqlite_db_remove(path)

    session := test_session(0x91)
    s, err := open(path)
    testing.expect_value(t, err, nil)
    defer close(s)
    test_session_create(t, s, session)

    committed := wire.Message_Committed_Data {
        session_id = session,
        seq = 1,
        message = wire.Assistant_Message {
            id = 1,
            run_id = 3,
            config_rev = 7,
            agent = "main",
            finish = wire.Stop_Reason.Stop,
            tokens = wire.Token_Usage{input = 11, output = 22, reasoning = 33, cache_read = 44, cache_write = 55},
            cost = 0.5,
            time = {created_at_ms = 1000, completed_at_ms = u64(2000)},
            provenance = wire.Turn_Provenance{protocol = .Anthropic_Messages, model = "claude-opus-5"},
        },
    }
    testing.expect_value(t, event_append(s, session, 1, committed, `{"seq":1}`, {message_id = 1, run_id = 3}), nil)

    st, prep := sqlite.prepare(
        s.writer,
        `SELECT role, run_id, config_rev, model, protocol, finish,
                tokens_input, tokens_output, tokens_reasoning, tokens_cache_read, tokens_cache_write,
                cost, created_at_ms, seq
         FROM messages WHERE session_id = ?1 AND message_id = 1`,
    )
    testing.expect_value(t, prep, sqlite.Result.Ok)
    defer sqlite.finalize(st)

    sid := ([16]u8)(session)
    testing.expect_value(t, sqlite.bind_blob(st, 1, sid[:]), sqlite.Result.Ok)
    testing.expect_value(t, sqlite.step(st), sqlite.Result.Row)

    role, role_rc := sqlite.column_text(st, 0)
    testing.expect_value(t, role_rc, sqlite.Result.Ok)
    testing.expect_value(t, role, "assistant")
    testing.expect_value(t, sqlite.column_i64(st, 1), i64(3))
    testing.expect_value(t, sqlite.column_i64(st, 2), i64(7))

    model, model_rc := sqlite.column_text(st, 3)
    testing.expect_value(t, model_rc, sqlite.Result.Ok)
    testing.expect_value(t, model, "claude-opus-5")

    protocol, protocol_rc := sqlite.column_text(st, 4)
    testing.expect_value(t, protocol_rc, sqlite.Result.Ok)
    testing.expect_value(t, protocol, "anthropic-messages")

    finish, finish_rc := sqlite.column_text(st, 5)
    testing.expect_value(t, finish_rc, sqlite.Result.Ok)
    testing.expect_value(t, finish, "stop")

    testing.expect_value(t, sqlite.column_i64(st, 6), i64(11))
    testing.expect_value(t, sqlite.column_i64(st, 7), i64(22))
    testing.expect_value(t, sqlite.column_i64(st, 8), i64(33))
    testing.expect_value(t, sqlite.column_i64(st, 9), i64(44))
    testing.expect_value(t, sqlite.column_i64(st, 10), i64(55))
    testing.expect_value(t, sqlite.column_i64(st, 12), i64(1000))

    // `seq` is the pointer back to the body, which the projection never copies.
    testing.expect_value(t, sqlite.column_i64(st, 13), i64(1))
    testing.expect_value(t, session_message_count(s, session), i64(1))
}

// A turn with no provenance leaves `model` null rather than substituting the
// config the turn was requested under.
@(test)
test_committed_assistant_without_provenance_has_no_model :: proc(t: ^testing.T) {
    path := testsupport.sqlite_db_path(t, "project-no-provenance")
    defer testsupport.sqlite_db_remove(path)

    session := test_session(0x92)
    s, err := open(path)
    testing.expect_value(t, err, nil)
    defer close(s)
    test_session_create(t, s, session)

    committed := wire.Message_Committed_Data {
        session_id = session,
        seq = 1,
        message = wire.Assistant_Message {
            id = 1,
            run_id = 1,
            config_rev = 4,
            agent = "main",
            finish = wire.Stop_Reason.Stop,
            time = {created_at_ms = 1, completed_at_ms = u64(2)},
        },
    }
    testing.expect_value(t, event_append(s, session, 1, committed, `{"seq":1}`, {message_id = 1, run_id = 1}), nil)

    st, prep := sqlite.prepare(
        s.writer,
        "SELECT model, protocol, tokens_input, cost, config_rev FROM messages WHERE session_id = ?1",
    )
    testing.expect_value(t, prep, sqlite.Result.Ok)
    defer sqlite.finalize(st)

    sid := ([16]u8)(session)
    testing.expect_value(t, sqlite.bind_blob(st, 1, sid[:]), sqlite.Result.Ok)
    testing.expect_value(t, sqlite.step(st), sqlite.Result.Row)
    testing.expect_value(t, sqlite.column_type(st, 0), sqlite.Type.Null)
    testing.expect_value(t, sqlite.column_type(st, 1), sqlite.Type.Null)
    testing.expect_value(t, sqlite.column_type(st, 2), sqlite.Type.Null)
    testing.expect_value(t, sqlite.column_type(st, 3), sqlite.Type.Null)

    // The requested revision is still recorded; only the answer is unknown.
    testing.expect_value(t, sqlite.column_i64(st, 4), i64(4))
}

// Truncation arrives after the messages it removes, so the projection folds it
// instead of mirroring the log row for row. The id marks deliberately stay put.
@(test)
test_truncation_removes_the_projected_tail :: proc(t: ^testing.T) {
    path := testsupport.sqlite_db_path(t, "project-truncate")
    defer testsupport.sqlite_db_remove(path)

    session := test_session(0x93)
    s, err := open(path)
    testing.expect_value(t, err, nil)
    defer close(s)
    test_session_create(t, s, session)

    for id in wire.Message_Id(1) ..= 4 {
        data := wire.Message_Committed_Data {
            session_id = session,
            seq = wire.Seq(id),
            message = wire.User_Message{id = id, input_id = wire.Input_Id(id), time = {created_at_ms = u64(id)}},
        }
        testing.expect_value(
            t,
            event_append(s, session, wire.Seq(id), data, `{"n":0}`, {message_id = id, input_id = wire.Input_Id(id)}),
            nil,
        )
    }

    testing.expect_value(t, message_row_count(s, session), i64(4))
    testing.expect_value(t, session_message_count(s, session), i64(4))

    truncate := wire.Transcript_Truncated_Data {
        session_id       = session,
        seq              = 5,
        first_removed_id = 3,
    }
    testing.expect_value(t, event_append(s, session, 5, truncate, `{"seq":5}`, {message_id = 3}), nil)

    testing.expect_value(t, message_row_count(s, session), i64(2))
    testing.expect_value(t, session_message_count(s, session), i64(2))

    // A discarded id stays spent: the mark never rewinds with the projection.
    hw, hw_err := high_water(s, session)
    testing.expect_value(t, hw_err, nil)
    testing.expect_value(t, hw.message_id, wire.Message_Id(4))

    // The log itself keeps every row; only the projection shrank.
    events, events_err := events_after(s, session, 0, 16)
    testing.expect_value(t, events_err, nil)
    defer events_destroy(events)
    testing.expect_value(t, len(events), 5)
}

// A refused append leaves no projected row: the projection is written inside the
// append's transaction, so it cannot survive an event that rolled back.
@(test)
test_refused_append_projects_nothing :: proc(t: ^testing.T) {
    path := testsupport.sqlite_db_path(t, "project-rollback")
    defer testsupport.sqlite_db_remove(path)

    session := test_session(0x94)
    s, err := open(path)
    testing.expect_value(t, err, nil)
    defer close(s)
    test_session_create(t, s, session)

    first := wire.Message_Committed_Data {
        session_id = session,
        seq = 1,
        message = wire.User_Message{id = 1, input_id = 1, time = {created_at_ms = 1}},
    }
    testing.expect_value(t, event_append(s, session, 1, first, `{"seq":1}`, {message_id = 1, input_id = 1}), nil)

    // Same seq: the contiguity guard refuses before the row or its projection lands.
    replay := wire.Message_Committed_Data {
        session_id = session,
        seq = 1,
        message = wire.User_Message{id = 2, input_id = 2, time = {created_at_ms = 2}},
    }
    testing.expect_value(
        t,
        event_append(s, session, 1, replay, `{"seq":1}`, {message_id = 2, input_id = 2}),
        Store_Error.Seq_Conflict,
    )

    testing.expect_value(t, message_row_count(s, session), i64(1))
    testing.expect_value(t, session_message_count(s, session), i64(1))
}

// Events that say nothing about the transcript project nothing.
@(test)
test_non_transcript_events_project_nothing :: proc(t: ^testing.T) {
    path := testsupport.sqlite_db_path(t, "project-ignored")
    defer testsupport.sqlite_db_remove(path)

    session := test_session(0x95)
    s, err := open(path)
    testing.expect_value(t, err, nil)
    defer close(s)
    test_session_create(t, s, session)

    started := wire.Run_Started_Data {
        session_id    = session,
        seq           = 1,
        run_id        = 1,
        kind          = .Turn,
        config_rev    = 1,
        started_at_ms = 1,
    }
    testing.expect_value(t, event_append(s, session, 1, started, `{"seq":1}`, {run_id = 1}), nil)

    changed := wire.Config_Changed_Data {
        session_id = session,
        seq = 2,
        config = {config_rev = 1, model = "test/model", reasoning = "low"},
    }
    testing.expect_value(t, event_append(s, session, 2, changed, `{"seq":2}`, {config_rev = 1}), nil)

    testing.expect_value(t, message_row_count(s, session), i64(0))
    testing.expect_value(t, session_message_count(s, session), i64(0))
}

@(private = "file")
usage_total :: proc(s: ^Store, session: wire.Session_Id) -> wire.Token_Usage {
    st, prep := sqlite.prepare(
        s.writer,
        `SELECT usage_input_total, usage_output_total, usage_reasoning_total,
                usage_cache_read_total, usage_cache_write_total
         FROM sessions WHERE id = ?1`,
    )
    if prep != .Ok do return {}
    defer sqlite.finalize(st)

    sid := ([16]u8)(session)
    if sqlite.bind_blob(st, 1, sid[:]) != .Ok || sqlite.step(st) != .Row do return {}

    return wire.Token_Usage {
        input = u64(sqlite.column_i64(st, 0)),
        output = u64(sqlite.column_i64(st, 1)),
        reasoning = u64(sqlite.column_i64(st, 2)),
        cache_read = u64(sqlite.column_i64(st, 3)),
        cache_write = u64(sqlite.column_i64(st, 4)),
    }
}

@(private = "file")
commit_message :: proc(t: ^testing.T, s: ^Store, session: wire.Session_Id, seq: wire.Seq, m: wire.Message) {
    data := wire.Message_Committed_Data {
        session_id = session,
        seq        = seq,
        message    = m,
    }
    testing.expect_value(
        t,
        event_append(
            s,
            session,
            seq,
            data,
            test_encode(data, context.temp_allocator),
            {message_id = wire.message_id(m)},
        ),
        nil,
    )
}

// The live gauge reads the usage of the newest assistant turn that reported it, past a
// trailing user message and past an assistant that reported none. The session's lifetime
// totals accumulate every reporting turn.
@(test)
test_last_usage_and_totals_track_assistant_turns :: proc(t: ^testing.T) {
    path := testsupport.sqlite_db_path(t, "last-usage")
    defer testsupport.sqlite_db_remove(path)

    session := test_session(0x98)
    s, err := open(path)
    testing.expect_value(t, err, nil)
    defer close(s)
    test_session_create(t, s, session)

    // No turn has reported usage yet.
    _, found0, err0 := messages_last_usage(s, session)
    testing.expect_value(t, err0, nil)
    testing.expect_value(t, found0, false)
    testing.expect_value(t, usage_total(s, session), wire.Token_Usage{})

    commit_message(
        t,
        s,
        session,
        1,
        wire.Assistant_Message {
            id = 1,
            run_id = 1,
            config_rev = 1,
            agent = "main",
            finish = wire.Stop_Reason.Stop,
            tokens = wire.Token_Usage{input = 100, output = 20, reasoning = 5, cache_read = 40, cache_write = 10},
            time = {created_at_ms = 10, completed_at_ms = u64(11)},
        },
    )

    usage, found, err1 := messages_last_usage(s, session)
    testing.expect_value(t, err1, nil)
    testing.expect_value(t, found, true)
    testing.expect_value(
        t,
        usage,
        wire.Token_Usage{input = 100, output = 20, reasoning = 5, cache_read = 40, cache_write = 10},
    )
    testing.expect_value(
        t,
        usage_total(s, session),
        wire.Token_Usage{input = 100, output = 20, reasoning = 5, cache_read = 40, cache_write = 10},
    )

    // A trailing user message carries no usage: it shadows neither the gauge nor the totals.
    commit_message(t, s, session, 2, wire.User_Message{id = 2, input_id = 2, time = {created_at_ms = 20}})

    usage2, found2, _ := messages_last_usage(s, session)
    testing.expect_value(t, found2, true)
    testing.expect_value(t, usage2.input, u64(100))
    testing.expect_value(t, usage_total(s, session).input, u64(100))

    // A newer assistant that reported usage becomes the gauge and folds into the totals.
    commit_message(
        t,
        s,
        session,
        3,
        wire.Assistant_Message {
            id = 3,
            run_id = 2,
            config_rev = 1,
            agent = "main",
            finish = wire.Stop_Reason.Stop,
            tokens = wire.Token_Usage{input = 250, output = 60, reasoning = 0, cache_read = 200, cache_write = 0},
            time = {created_at_ms = 30, completed_at_ms = u64(31)},
        },
    )

    usage3, found3, err3 := messages_last_usage(s, session)
    testing.expect_value(t, err3, nil)
    testing.expect_value(t, found3, true)
    testing.expect_value(
        t,
        usage3,
        wire.Token_Usage{input = 250, output = 60, reasoning = 0, cache_read = 200, cache_write = 0},
    )
    testing.expect_value(
        t,
        usage_total(s, session),
        wire.Token_Usage{input = 350, output = 80, reasoning = 5, cache_read = 240, cache_write = 10},
    )
}

// Lifetime totals are monotonic: a truncation removes the projected rows and the message
// count, but never subtracts the usage already billed. A rebuild replays to the same totals.
@(test)
test_usage_totals_survive_truncation_and_rebuild :: proc(t: ^testing.T) {
    path := testsupport.sqlite_db_path(t, "usage-monotonic")
    defer testsupport.sqlite_db_remove(path)

    session := test_session(0x99)
    s, err := open(path)
    testing.expect_value(t, err, nil)
    defer close(s)
    test_session_create(t, s, session)

    commit_message(
        t,
        s,
        session,
        1,
        wire.Assistant_Message {
            id = 1,
            run_id = 1,
            config_rev = 1,
            agent = "main",
            finish = wire.Stop_Reason.Stop,
            tokens = wire.Token_Usage{input = 100, output = 20, reasoning = 0, cache_read = 40, cache_write = 10},
            time = {created_at_ms = 10, completed_at_ms = u64(11)},
        },
    )
    commit_message(
        t,
        s,
        session,
        2,
        wire.Assistant_Message {
            id = 2,
            run_id = 2,
            config_rev = 1,
            agent = "main",
            finish = wire.Stop_Reason.Stop,
            tokens = wire.Token_Usage{input = 250, output = 60, reasoning = 0, cache_read = 200, cache_write = 0},
            time = {created_at_ms = 20, completed_at_ms = u64(21)},
        },
    )

    full := wire.Token_Usage {
        input       = 350,
        output      = 80,
        reasoning   = 0,
        cache_read  = 240,
        cache_write = 10,
    }
    testing.expect_value(t, usage_total(s, session), full)

    // Truncate the second turn away. The gauge falls back to the first turn, the totals do not.
    truncate := wire.Transcript_Truncated_Data {
        session_id       = session,
        seq              = 3,
        first_removed_id = 2,
    }
    testing.expect_value(
        t,
        event_append(s, session, 3, truncate, test_encode(truncate, context.temp_allocator), {message_id = 2}),
        nil,
    )

    testing.expect_value(t, message_row_count(s, session), i64(1))
    testing.expect_value(t, usage_total(s, session), full)

    gauge, found, _ := messages_last_usage(s, session)
    testing.expect_value(t, found, true)
    testing.expect_value(t, gauge.input, u64(100))

    // A rebuild replays every committed turn, including the truncated one, to the same totals.
    testing.expect_value(t, projection_rebuild(s, session), nil)
    testing.expect_value(t, usage_total(s, session), full)
}

// The real encoding of a payload. Replay decodes the stored bytes, so a fixture
// that wants to be replayable has to store what the pump would have stored.
@(private)
test_encode :: proc(data: wire.Broadcast_Data, allocator := context.allocator) -> string {
    e: json.Emitter
    json.emitter_init(&e, allocator)
    defer json.emitter_destroy(&e)
    wire.broadcast_data_emit(&e, data)

    return strings.clone(json.to_string(&e), allocator)
}

// Snapshot every projected row for one session as comparable text.
@(private = "file")
project_snapshot :: proc(s: ^Store, session: wire.Session_Id, allocator := context.allocator) -> string {
    st, prep := sqlite.prepare(
        s.writer,
        `SELECT message_id || '|' || seq || '|' || role || '|' ||
                COALESCE(run_id, -1) || '|' || COALESCE(config_rev, -1) || '|' ||
                COALESCE(model, '-') || '|' || COALESCE(protocol, '-') || '|' ||
                COALESCE(finish, '-') || '|' || COALESCE(tokens_input, -1) || '|' ||
                COALESCE(cost, -1) || '|' || created_at_ms
         FROM messages WHERE session_id = ?1 ORDER BY message_id`,
    )
    if prep != .Ok do return ""
    defer sqlite.finalize(st)

    sid := ([16]u8)(session)
    if sqlite.bind_blob(st, 1, sid[:]) != .Ok do return ""

    b := strings.builder_make(allocator)
    for sqlite.step(st) == .Row {
        row, rc := sqlite.column_text(st, 0)
        if rc != .Ok do return ""

        strings.write_string(&b, row)
        strings.write_byte(&b, '\n')
    }

    return strings.to_string(b)
}

// The projection holds no fact the log does not: dropping it and replaying the
// events reproduces it exactly, including the truncation fold and the derived
// message_count. This is what lets the table be reshaped without a migration.
@(test)
test_replay_reproduces_the_projection :: proc(t: ^testing.T) {
    path := testsupport.sqlite_db_path(t, "project-replay")
    defer testsupport.sqlite_db_remove(path)

    session := test_session(0x96)
    s, err := open(path)
    testing.expect_value(t, err, nil)
    defer close(s)
    test_session_create(t, s, session)

    seq := wire.Seq(0)
    append_committed :: proc(t: ^testing.T, s: ^Store, session: wire.Session_Id, seq: ^wire.Seq, m: wire.Message) {
        seq^ += 1
        data := wire.Message_Committed_Data {
            session_id = session,
            seq        = seq^,
            message    = m,
        }
        testing.expect_value(
            t,
            event_append(
                s,
                session,
                seq^,
                data,
                test_encode(data, context.temp_allocator),
                {message_id = wire.message_id(m)},
            ),
            nil,
        )
    }

    append_committed(t, s, session, &seq, wire.User_Message{id = 1, input_id = 1, time = {created_at_ms = 10}})
    append_committed(
        t,
        s,
        session,
        &seq,
        wire.Assistant_Message {
            id = 2,
            run_id = 1,
            config_rev = 1,
            agent = "main",
            finish = wire.Stop_Reason.Stop,
            tokens = wire.Token_Usage{input = 5, output = 6, reasoning = 7, cache_read = 8, cache_write = 9},
            cost = 1.25,
            time = {created_at_ms = 20, completed_at_ms = u64(21)},
            provenance = wire.Turn_Provenance{protocol = .Anthropic_Messages, model = "claude-opus-5"},
        },
    )
    append_committed(t, s, session, &seq, wire.User_Message{id = 3, input_id = 3, time = {created_at_ms = 30}})
    append_committed(
        t,
        s,
        session,
        &seq,
        wire.Compaction_Message {
            id = 4,
            run_id = 2,
            reason = .Manual,
            summary = "s",
            tokens_before = 10,
            tokens_after = 5,
            time = {created_at_ms = 40},
        },
    )

    // A truncation the replay has to fold, not mirror.
    seq += 1
    truncate := wire.Transcript_Truncated_Data {
        session_id       = session,
        seq              = seq,
        first_removed_id = 4,
    }
    testing.expect_value(
        t,
        event_append(s, session, seq, truncate, test_encode(truncate, context.temp_allocator), {message_id = 4}),
        nil,
    )

    live := project_snapshot(s, session, context.temp_allocator)
    live_count := session_message_count(s, session)
    testing.expect_value(t, live_count, i64(3))
    testing.expect(t, len(live) > 0, "the live projection is not empty")

    testing.expect_value(t, projection_rebuild(s, session), nil)

    rebuilt := project_snapshot(s, session, context.temp_allocator)
    testing.expect_value(t, rebuilt, live)
    testing.expect_value(t, session_message_count(s, session), live_count)
}

// A rebuild is idempotent: running it twice lands on the same rows and count.
@(test)
test_replay_is_idempotent :: proc(t: ^testing.T) {
    path := testsupport.sqlite_db_path(t, "project-replay-twice")
    defer testsupport.sqlite_db_remove(path)

    session := test_session(0x97)
    s, err := open(path)
    testing.expect_value(t, err, nil)
    defer close(s)
    test_session_create(t, s, session)

    for id in wire.Message_Id(1) ..= 3 {
        data := wire.Message_Committed_Data {
            session_id = session,
            seq = wire.Seq(id),
            message = wire.User_Message{id = id, input_id = wire.Input_Id(id), time = {created_at_ms = u64(id)}},
        }
        testing.expect_value(
            t,
            event_append(s, session, wire.Seq(id), data, test_encode(data, context.temp_allocator), {message_id = id}),
            nil,
        )
    }

    first := project_snapshot(s, session, context.temp_allocator)
    testing.expect_value(t, projection_rebuild(s, session), nil)
    testing.expect_value(t, projection_rebuild(s, session), nil)

    testing.expect_value(t, project_snapshot(s, session, context.temp_allocator), first)
    testing.expect_value(t, session_message_count(s, session), i64(3))
}
