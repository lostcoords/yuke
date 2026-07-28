package sqlite

import "core:c"
import "core:testing"

import "libs:testsupport"

@(test)
test_libversion_is_present :: proc(t: ^testing.T) {
    ver := libversion()
    testing.expect(t, len(ver) > 0, "libversion should be non-empty")
    testing.expect(t, libversion_number() >= 3008002, "need SQLite 3.8.2+ for WITHOUT ROWID")
}

@(test)
test_close_reports_live_statement :: proc(t: ^testing.T) {
    db, rc := open_memory()
    testing.expect_value(t, rc, Result.Ok)

    st, prep := prepare(db, "SELECT 1")
    testing.expect_value(t, prep, Result.Ok)
    testing.expect_value(t, close(db), Result.Busy)

    testing.expect_value(t, finalize(st), Result.Ok)
    testing.expect_value(t, close(db), Result.Ok)
}

@(test)
test_cstring_allocation_failure_is_reported :: proc(t: ^testing.T) {
    db, rc := open_memory()
    testing.expect_value(t, rc, Result.Ok)

    failing: testsupport.Failing_Allocator
    testsupport.failing_allocator_init(&failing, context.allocator, 0)

    previous := context.temp_allocator
    context.temp_allocator = testsupport.failing_allocator(&failing)
    st, prep := prepare(db, "SELECT 1")
    exec_rc := exec(db, "SELECT 1")
    opened, open_rc := open_memory()
    context.temp_allocator = previous

    testing.expect_value(t, prep, Result.Ok)
    testing.expect_value(t, exec_rc, Result.No_Mem)
    testing.expect_value(t, open_rc, Result.No_Mem)
    testing.expect(t, opened == nil, "an allocation failure returns no connection")

    testing.expect_value(t, finalize(st), Result.Ok)
    testing.expect_value(t, close(db), Result.Ok)
}

@(test)
test_memory_round_trip :: proc(t: ^testing.T) {
    db, rc := open_memory()
    testing.expect_value(t, rc, Result.Ok)
    testing.expect(t, db != nil, "open_memory returned nil db")
    defer testing.expect_value(t, close(db), Result.Ok)

    testing.expect_value(t, busy_timeout(db, 1000), Result.Ok)

    rc = exec(
        db,
        `
        CREATE TABLE events (
            session_id TEXT NOT NULL,
            seq INTEGER NOT NULL,
            payload TEXT NOT NULL,
            PRIMARY KEY (session_id, seq)
        );
    `,
    )
    testing.expect_value(t, rc, Result.Ok)

    stmt, prep := prepare(db, "INSERT INTO events(session_id, seq, payload) VALUES(?1, ?2, ?3)")
    testing.expect_value(t, prep, Result.Ok)
    defer finalize(stmt)

    testing.expect_value(t, bind_text(stmt, 1, "sess-a"), Result.Ok)
    testing.expect_value(t, bind_i64(stmt, 2, 1), Result.Ok)
    testing.expect_value(t, bind_text(stmt, 3, `{"type":"hello"}`), Result.Ok)
    testing.expect_value(t, step(stmt), Result.Done)
    testing.expect_value(t, changes(db), 1)

    q, qrc := prepare(db, "SELECT session_id, seq, payload FROM events WHERE session_id = ?1")
    testing.expect_value(t, qrc, Result.Ok)
    defer finalize(q)

    testing.expect_value(t, bind_text(q, 1, "sess-a"), Result.Ok)
    testing.expect_value(t, step(q), Result.Row)
    testing.expect_value(t, column_text(q, 0), "sess-a")
    testing.expect_value(t, column_i64(q, 1), i64(1))
    testing.expect_value(t, column_text(q, 2), `{"type":"hello"}`)
    testing.expect_value(t, column_type(q, 2), Type.Text)
    testing.expect_value(t, step(q), Result.Done)
}

@(test)
test_blob_and_null_bind :: proc(t: ^testing.T) {
    db, rc := open_memory()
    testing.expect_value(t, rc, Result.Ok)
    defer testing.expect_value(t, close(db), Result.Ok)

    testing.expect_value(t, exec(db, "CREATE TABLE t(id INTEGER PRIMARY KEY, b BLOB, n TEXT)"), Result.Ok)

    stmt, prep := prepare(db, "INSERT INTO t(id, b, n) VALUES(1, ?1, ?2)")
    testing.expect_value(t, prep, Result.Ok)
    defer finalize(stmt)

    blob := []byte{0x00, 0x01, 0xfe, 0xff}
    testing.expect_value(t, bind_blob(stmt, 1, blob), Result.Ok)
    testing.expect_value(t, bind_null(stmt, 2), Result.Ok)
    testing.expect_value(t, step(stmt), Result.Done)

    q, qrc := prepare(db, "SELECT b, n FROM t WHERE id = 1")
    testing.expect_value(t, qrc, Result.Ok)
    defer finalize(q)

    testing.expect_value(t, step(q), Result.Row)
    got := column_blob(q, 0)
    testing.expect_value(t, len(got), len(blob))
    for i in 0 ..< len(blob) {
        testing.expect_value(t, got[i], blob[i])
    }
    testing.expect_value(t, column_type(q, 1), Type.Null)
}

@(test)
test_prepare_error_message :: proc(t: ^testing.T) {
    db, rc := open_memory()
    testing.expect_value(t, rc, Result.Ok)
    defer testing.expect_value(t, close(db), Result.Ok)

    stmt, prep := prepare(db, "SELECT * FROM definitely_missing")
    testing.expect(t, is_error(prep), "bad SQL should error")
    testing.expect(t, stmt == nil, "failed prepare must not return a stmt")
    testing.expect(t, len(errmsg(db)) > 0, "errmsg should explain the fault")
}

@(test)
test_file_wal_pragma :: proc(t: ^testing.T) {
    path := testsupport.sqlite_db_path(t, "sqlite-wal-test")
    defer testsupport.sqlite_db_remove(path)

    db, rc := open(path, DEFAULT_WRITER | {.Nomutex})
    testing.expect_value(t, rc, Result.Ok)
    defer testing.expect_value(t, close(db), Result.Ok)

    testing.expect_value(t, exec(db, "PRAGMA journal_mode=WAL"), Result.Ok)
    testing.expect_value(t, exec(db, "PRAGMA synchronous=NORMAL"), Result.Ok)

    stmt, prep := prepare(db, "PRAGMA journal_mode")
    testing.expect_value(t, prep, Result.Ok)
    defer finalize(stmt)

    testing.expect_value(t, step(stmt), Result.Row)
    testing.expect_value(t, column_text(stmt, 0), "wal")

    nlog, nckpt: int
    ck := wal_checkpoint(db, .Passive, &nlog, &nckpt)
    testing.expect_value(t, ck, Result.Ok)
}

@(test)
test_extended_errcode_recovers_base_family :: proc(t: ^testing.T) {
    db, rc := open_memory()
    testing.expect_value(t, rc, Result.Ok)
    defer testing.expect_value(t, close(db), Result.Ok)

    testing.expect_value(t, exec(db, "CREATE TABLE t(id INTEGER PRIMARY KEY, u TEXT UNIQUE)"), Result.Ok)
    testing.expect_value(t, exec(db, "INSERT INTO t(id, u) VALUES (1, 'a')"), Result.Ok)

    // SQLITE_CONSTRAINT_UNIQUE and SQLITE_CONSTRAINT_PRIMARYKEY are distinct
    // extended codes (Constraint | (subcode << 8)) that share the Constraint base.
    unique := exec(db, "INSERT INTO t(id, u) VALUES (2, 'a')")
    testing.expect_value(t, unique, Result.Constraint)
    testing.expect_value(t, extended_errcode(db), c.int(Result.Constraint) | (8 << 8))
    testing.expect_value(t, extended_result_base(extended_errcode(db)), Result.Constraint)

    primarykey := exec(db, "INSERT INTO t(id, u) VALUES (1, 'b')")
    testing.expect_value(t, primarykey, Result.Constraint)
    testing.expect_value(t, extended_errcode(db), c.int(Result.Constraint) | (6 << 8))
    testing.expect_value(t, extended_result_base(extended_errcode(db)), Result.Constraint)
}
