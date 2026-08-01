package store

import "core:fmt"
import "core:testing"

import "libs:bindings/sqlite"
import "libs:testsupport"
import "src:wire"

@(private = "file")
config_model :: proc(s: ^Store, session: wire.Session_Id, rev: wire.Config_Rev) -> string {
    text, err := sqlite.query_one_text(
        s.writer,
        fmt.tprintf(
            "SELECT model FROM session_configs WHERE session_id = x'%s' AND config_rev = %d",
            hex_session(session),
            rev,
        ),
        context.temp_allocator,
    )
    if err != .Ok {
        return ""
    }

    return text
}

@(private = "file")
prompt_rows :: proc(s: ^Store, session: wire.Session_Id) -> i64 {
    count, err := sqlite.query_one_i64(
        s.writer,
        fmt.tprintf("SELECT count(*) FROM session_prompts WHERE session_id = x'%s'", hex_session(session)),
    )
    if err != .Ok {
        return -1
    }

    return count
}

// Every announced revision is projected, so session.config can answer for a past
// one without folding the log from seq 1.
@(test)
test_config_changed_projects_every_revision :: proc(t: ^testing.T) {
    path := testsupport.sqlite_db_path(t, "config-project")
    defer testsupport.sqlite_db_remove(path)

    session := test_session(0xa8)
    s, err := open(path)
    testing.expect_value(t, err, nil)
    defer close(s)
    test_session_create(t, s, session)

    for rev in wire.Config_Rev(1) ..= 3 {
        changed := wire.Config_Changed_Data {
            session_id = session,
            seq = wire.Seq(rev),
            config = {config_rev = rev, model = fmt.tprintf("model-%d", rev), reasoning = "low"},
        }
        testing.expect_value(
            t,
            event_append(
                s,
                session,
                wire.Seq(rev),
                changed,
                test_encode(changed, context.temp_allocator),
                {config_rev = rev},
            ),
            nil,
        )
    }

    // A superseded revision is still answerable; that is the point of the table.
    testing.expect_value(t, config_model(s, session, 1), "model-1")
    testing.expect_value(t, config_model(s, session, 3), "model-3")
}

// A truncation drops messages, never the revisions announced before it.
@(test)
test_truncation_leaves_configs_alone :: proc(t: ^testing.T) {
    path := testsupport.sqlite_db_path(t, "config-truncate")
    defer testsupport.sqlite_db_remove(path)

    session := test_session(0xa9)
    s, err := open(path)
    testing.expect_value(t, err, nil)
    defer close(s)
    test_session_create(t, s, session)

    changed := wire.Config_Changed_Data {
        session_id = session,
        seq = 1,
        config = {config_rev = 1, model = "kept", reasoning = "low"},
    }
    testing.expect_value(
        t,
        event_append(s, session, 1, changed, test_encode(changed, context.temp_allocator), {config_rev = 1}),
        nil,
    )

    committed := wire.Message_Committed_Data {
        session_id = session,
        seq = 2,
        message = wire.User_Message{id = 1, input_id = 1, time = {created_at_ms = 1}},
    }
    testing.expect_value(
        t,
        event_append(s, session, 2, committed, test_encode(committed, context.temp_allocator), {message_id = 1}),
        nil,
    )

    truncate := wire.Transcript_Truncated_Data {
        session_id       = session,
        seq              = 3,
        first_removed_id = 1,
    }
    testing.expect_value(
        t,
        event_append(s, session, 3, truncate, test_encode(truncate, context.temp_allocator), {message_id = 1}),
        nil,
    )

    testing.expect_value(t, config_model(s, session, 1), "kept")
    testing.expect_value(t, session_message_count(s, session), i64(0))
}

// The config projection replays like the transcript one.
@(test)
test_replay_reproduces_the_configs :: proc(t: ^testing.T) {
    path := testsupport.sqlite_db_path(t, "config-replay")
    defer testsupport.sqlite_db_remove(path)

    session := test_session(0xaa)
    s, err := open(path)
    testing.expect_value(t, err, nil)
    defer close(s)
    test_session_create(t, s, session)

    for rev in wire.Config_Rev(1) ..= 2 {
        changed := wire.Config_Changed_Data {
            session_id = session,
            seq = wire.Seq(rev),
            config = {config_rev = rev, model = fmt.tprintf("m%d", rev), reasoning = "high"},
        }
        testing.expect_value(
            t,
            event_append(
                s,
                session,
                wire.Seq(rev),
                changed,
                test_encode(changed, context.temp_allocator),
                {config_rev = rev},
            ),
            nil,
        )
    }

    testing.expect_value(t, projection_rebuild(s, session), nil)
    testing.expect_value(t, config_model(s, session, 1), "m1")
    testing.expect_value(t, config_model(s, session, 2), "m2")
}

// A prompt is stored only when one is sent; absence is the null the protocol
// reports, not an empty row.
@(test)
test_session_prompt_is_stored_only_when_present :: proc(t: ^testing.T) {
    path := testsupport.sqlite_db_path(t, "prompt")
    defer testsupport.sqlite_db_remove(path)

    with_prompt := test_session(0xab)
    without := test_session(0xac)

    s, err := open(path)
    testing.expect_value(t, err, nil)
    defer close(s)

    testing.expect_value(t, session_create(s, test_session_summary(with_prompt), "be helpful"), nil)
    testing.expect_value(t, session_create(s, test_session_summary(without), nil), nil)

    testing.expect_value(t, prompt_rows(s, with_prompt), i64(1))
    testing.expect_value(t, prompt_rows(s, without), i64(0))

    stored, stored_err := sqlite.query_one_text(
        s.writer,
        fmt.tprintf("SELECT prompt FROM session_prompts WHERE session_id = x'%s'", hex_session(with_prompt)),
        context.temp_allocator,
    )
    testing.expect_value(t, stored_err, sqlite.Result.Ok)
    testing.expect_value(t, stored, "be helpful")

    // Removing the session takes its prompt and configs with it.
    testing.expect_value(
        t,
        sqlite.exec(s.writer, fmt.tprintf("DELETE FROM sessions WHERE id = x'%s'", hex_session(with_prompt))),
        sqlite.Result.Ok,
    )
    testing.expect_value(t, prompt_rows(s, with_prompt), i64(0))
}
