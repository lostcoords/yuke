package sqlite

import "core:c"
import "core:strings"
import "core:testing"

import "libs:testsupport"

@(test)
test_libversion_is_present :: proc(t: ^testing.T) {
    ver := libversion()
    testing.expect(t, len(ver) > 0, "libversion should be non-empty")
    testing.expect(t, libversion_number() >= 3008002, "need SQLite 3.8.2+ for WITHOUT ROWID")
}

@(test)
test_finalize_nil_is_a_no_op :: proc(t: ^testing.T) {
    testing.expect_value(t, finalize(nil), Result.Ok)
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
    session, session_rc := column_text(q, 0)
    testing.expect_value(t, session_rc, Result.Ok)
    testing.expect_value(t, session, "sess-a")
    testing.expect_value(t, column_i64(q, 1), i64(1))
    payload, payload_rc := column_text(q, 2)
    testing.expect_value(t, payload_rc, Result.Ok)
    testing.expect_value(t, payload, `{"type":"hello"}`)
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
test_empty_blob_stays_a_blob :: proc(t: ^testing.T) {
    db, rc := open_memory()
    testing.expect_value(t, rc, Result.Ok)
    defer testing.expect_value(t, close(db), Result.Ok)

    testing.expect_value(t, exec(db, "CREATE TABLE t(value BLOB NOT NULL)"), Result.Ok)

    insert, prep := prepare(db, "INSERT INTO t(value) VALUES (?1)")
    testing.expect_value(t, prep, Result.Ok)
    defer testing.expect_value(t, finalize(insert), Result.Ok)

    empty: []byte
    testing.expect_value(t, bind_blob(insert, 1, empty), Result.Ok)
    testing.expect_value(t, step(insert), Result.Done)

    query, query_rc := prepare(db, "SELECT value, typeof(value), length(value) FROM t")
    testing.expect_value(t, query_rc, Result.Ok)
    defer testing.expect_value(t, finalize(query), Result.Ok)

    testing.expect_value(t, step(query), Result.Row)
    testing.expect_value(t, column_type(query, 0), Type.Blob)
    testing.expect_value(t, len(column_blob(query, 0)), 0)
    storage, storage_rc := column_text(query, 1)
    testing.expect_value(t, storage_rc, Result.Ok)
    testing.expect_value(t, storage, "blob")
    testing.expect_value(t, column_i64(query, 2), i64(0))
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

    db, rc := open(strings.clone_to_cstring(path, context.temp_allocator), DEFAULT_WRITER | {.Nomutex})
    testing.expect_value(t, rc, Result.Ok)
    defer testing.expect_value(t, close(db), Result.Ok)

    journaled, jrc := journal_mode_set(db, .Wal)
    testing.expect_value(t, jrc, Result.Ok)
    testing.expect(t, journaled, "a file database accepts WAL")
    testing.expect_value(t, synchronous_set(db, .Normal), Result.Ok)

    stmt, prep := prepare(db, "PRAGMA journal_mode")
    testing.expect_value(t, prep, Result.Ok)
    defer finalize(stmt)

    testing.expect_value(t, step(stmt), Result.Row)
    mode, mode_rc := column_text(stmt, 0)
    testing.expect_value(t, mode_rc, Result.Ok)
    testing.expect_value(t, mode, "wal")

    nlog, nckpt: int
    ck := wal_checkpoint(db, .Passive, &nlog, &nckpt)
    testing.expect_value(t, ck, Result.Ok)
}

@(test)
test_journal_mode_reports_a_refused_change :: proc(t: ^testing.T) {
    db, rc := open_memory()
    testing.expect_value(t, rc, Result.Ok)
    defer testing.expect_value(t, close(db), Result.Ok)

    // A memory database cannot leave memory journalling, and says so by reporting
    // the mode it kept instead of failing the pragma.
    journaled, jrc := journal_mode_set(db, .Wal)
    testing.expect_value(t, jrc, Result.Ok)
    testing.expect(t, !journaled, "a memory database refuses WAL")

    kept, krc := journal_mode_set(db, .Memory)
    testing.expect_value(t, krc, Result.Ok)
    testing.expect(t, kept, "a memory database settles on its own mode")
}

@(test)
test_synchronous_round_trips_every_level :: proc(t: ^testing.T) {
    db, rc := open_memory()
    testing.expect_value(t, rc, Result.Ok)
    defer testing.expect_value(t, close(db), Result.Ok)

    // FULL is SQLite's default, so start elsewhere to prove the setter moved it.
    for level in Synchronous {
        testing.expect_value(t, synchronous_set(db, level), Result.Ok)

        got, got_rc := synchronous(db)
        testing.expect_value(t, got_rc, Result.Ok)
        testing.expect_value(t, got, level)
    }
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

@(test)
test_exec_runs_a_statement_batch :: proc(t: ^testing.T) {
    db, rc := open_memory()
    testing.expect_value(t, rc, Result.Ok)
    defer testing.expect_value(t, close(db), Result.Ok)

    // Comments between and after the statements compile to nothing, and the rows the
    // middle `SELECT` produces are stepped through rather than ending the batch.
    batch := `
        CREATE TABLE t(id INTEGER PRIMARY KEY, u TEXT UNIQUE);
        INSERT INTO t(id, u) VALUES (1, 'a');
        -- a comment between statements
        SELECT id, u FROM t;
        INSERT INTO t(id, u) VALUES (2, 'b');
        -- and a trailing one
    `
    testing.expect_value(t, exec(db, batch), Result.Ok)

    count, crc := prepare(db, "SELECT count(*) FROM t")
    testing.expect_value(t, crc, Result.Ok)
    defer finalize(count)

    testing.expect_value(t, step(count), Result.Row)
    testing.expect_value(t, column_i64(count, 0), i64(2))

    // A failure stops the batch where it happened: the insert before it stands and
    // the one after it never ran.
    failing := `
        INSERT INTO t(id, u) VALUES (3, 'c');
        INSERT INTO t(id, u) VALUES (4, 'c');
        INSERT INTO t(id, u) VALUES (5, 'd');
    `
    testing.expect_value(t, exec(db, failing), Result.Constraint)

    after, arc := prepare(db, "SELECT count(*) FROM t")
    testing.expect_value(t, arc, Result.Ok)
    defer finalize(after)

    testing.expect_value(t, step(after), Result.Row)
    testing.expect_value(t, column_i64(after, 0), i64(3))
}

@(test)
test_txn_commit_keeps_work_and_rollback_discards_it :: proc(t: ^testing.T) {
    db, rc := open_memory()
    testing.expect_value(t, rc, Result.Ok)
    defer testing.expect_value(t, close(db), Result.Ok)

    testing.expect_value(t, exec(db, "CREATE TABLE t(id INTEGER PRIMARY KEY)"), Result.Ok)

    testing.expect_value(t, txn_begin(db, .Immediate), Result.Ok)
    testing.expect(t, !autocommit(db), "BEGIN IMMEDIATE opens a transaction")
    testing.expect_value(t, exec(db, "INSERT INTO t(id) VALUES (1)"), Result.Ok)
    testing.expect_value(t, txn_commit(db), Result.Ok)

    testing.expect_value(t, txn_begin(db, .Deferred), Result.Ok)
    testing.expect_value(t, exec(db, "INSERT INTO t(id) VALUES (2)"), Result.Ok)
    testing.expect_value(t, txn_rollback(db), Result.Ok)
    testing.expect(t, autocommit(db), "ROLLBACK ends the transaction")

    kept, krc := query_one_i64(db, "SELECT count(*) FROM t")
    testing.expect_value(t, krc, Result.Ok)
    testing.expect_value(t, kept, i64(1))
}

@(test)
test_txn_rollback_is_idempotent :: proc(t: ^testing.T) {
    db, rc := open_memory()
    testing.expect_value(t, rc, Result.Ok)
    defer testing.expect_value(t, close(db), Result.Ok)

    // Nothing to end is the state a failed COMMIT can leave behind, so it reports
    // success; that keeps a real rollback failure distinguishable from it.
    testing.expect(t, autocommit(db), "a fresh connection has no transaction")
    testing.expect_value(t, txn_rollback(db), Result.Ok)

    testing.expect_value(t, txn_begin(db, .Immediate), Result.Ok)
    testing.expect_value(t, txn_rollback(db), Result.Ok)
    testing.expect_value(t, txn_rollback(db), Result.Ok)
    testing.expect(t, autocommit(db), "the transaction is gone either way")
}

@(test)
test_execute_steps_and_leaves_the_statement_reusable :: proc(t: ^testing.T) {
    db, rc := open_memory()
    testing.expect_value(t, rc, Result.Ok)
    defer testing.expect_value(t, close(db), Result.Ok)

    testing.expect_value(t, exec(db, "CREATE TABLE t(id INTEGER PRIMARY KEY, u TEXT UNIQUE)"), Result.Ok)

    st, prc := prepare(db, "INSERT INTO t(id, u) VALUES (?1, ?2)")
    testing.expect_value(t, prc, Result.Ok)
    defer finalize(st)

    testing.expect_value(t, bind_i64(st, 1, 1), Result.Ok)
    testing.expect_value(t, bind_text(st, 2, "a"), Result.Ok)
    testing.expect_value(t, execute(st), Result.Ok)

    // Rebinding both parameters proves the first run reset and cleared them.
    testing.expect_value(t, bind_i64(st, 1, 2), Result.Ok)
    testing.expect_value(t, bind_text(st, 2, "b"), Result.Ok)
    testing.expect_value(t, execute(st), Result.Ok)

    // A failing step is still reset, so the statement survives its own error.
    testing.expect_value(t, bind_i64(st, 1, 3), Result.Ok)
    testing.expect_value(t, bind_text(st, 2, "b"), Result.Ok)
    testing.expect_value(t, execute(st), Result.Constraint)

    testing.expect_value(t, bind_i64(st, 1, 4), Result.Ok)
    testing.expect_value(t, bind_text(st, 2, "d"), Result.Ok)
    testing.expect_value(t, execute(st), Result.Ok)

    rows, qrc := query_one_i64(db, "SELECT count(*) FROM t")
    testing.expect_value(t, qrc, Result.Ok)
    testing.expect_value(t, rows, i64(3))

    // A statement that yields rows is reported, not asserted on, and is left
    // reusable like any other failure.
    sel, src := prepare(db, "SELECT id FROM t")
    testing.expect_value(t, src, Result.Ok)
    defer finalize(sel)

    testing.expect_value(t, execute(sel), Result.Row)
    testing.expect_value(t, step(sel), Result.Row)
    testing.expect_value(t, column_i64(sel, 0), i64(1))
}

@(test)
test_query_one_reports_arity_and_storage_class :: proc(t: ^testing.T) {
    db, rc := open_memory()
    testing.expect_value(t, rc, Result.Ok)
    defer testing.expect_value(t, close(db), Result.Ok)

    testing.expect_value(t, exec(db, "CREATE TABLE t(id INTEGER PRIMARY KEY, u TEXT)"), Result.Ok)
    testing.expect_value(t, exec(db, "INSERT INTO t(id, u) VALUES (1, 'a'), (2, 'b')"), Result.Ok)

    got, grc := query_one_i64(db, "SELECT id FROM t WHERE id = 1")
    testing.expect_value(t, grc, Result.Ok)
    testing.expect_value(t, got, i64(1))

    text, trc := query_one_text(db, "SELECT u FROM t WHERE id = 2")
    defer delete(text)
    testing.expect_value(t, trc, Result.Ok)
    testing.expect_value(t, text, "b")

    equal, equal_rc := query_one_text_equal(db, "SELECT u FROM t WHERE id = 2", "b")
    testing.expect_value(t, equal_rc, Result.Ok)
    testing.expect(t, equal, "the text predicate matches its only row")

    different, different_rc := query_one_text_equal(db, "SELECT u FROM t WHERE id = 2", "a")
    testing.expect_value(t, different_rc, Result.Ok)
    testing.expect(t, !different, "the text predicate reports a mismatch")

    _, missing := query_one_i64(db, "SELECT id FROM t WHERE id = 99")
    testing.expect_value(t, missing, Result.Done)

    _, extra := query_one_i64(db, "SELECT id FROM t UNION ALL SELECT id FROM t")
    testing.expect_value(t, extra, Result.Row)

    _, wrong := query_one_i64(db, "SELECT u FROM t WHERE id = 1")
    testing.expect_value(t, wrong, Result.Mismatch)

    _, wrong_text := query_one_text(db, "SELECT id FROM t WHERE id = 1")
    testing.expect_value(t, wrong_text, Result.Mismatch)
}

@(test)
test_column_decltype_reports_the_schema_type_and_blanks_for_expressions :: proc(t: ^testing.T) {
    db, rc := open_memory()
    testing.expect_value(t, rc, Result.Ok)
    defer testing.expect_value(t, close(db), Result.Ok)

    testing.expect_value(t, exec(db, "CREATE TABLE t (a INTEGER)"), Result.Ok)
    testing.expect_value(t, exec(db, "INSERT INTO t VALUES (1)"), Result.Ok)

    st, prep := prepare(db, "SELECT a, a + 1 FROM t")
    testing.expect_value(t, prep, Result.Ok)
    defer testing.expect_value(t, finalize(st), Result.Ok)

    testing.expect_value(t, column_decltype(st, 0), "INTEGER")
    // An expression column has no declared type.
    testing.expect_value(t, column_decltype(st, 1), "")
}
