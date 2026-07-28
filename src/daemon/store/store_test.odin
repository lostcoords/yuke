package store

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"

import "libs:sqlite"
import "libs:testsupport"

@(test)
test_open_creates_schema_at_latest_version :: proc(t: ^testing.T) {
    path := testsupport.sqlite_db_path(t, "latest")
    defer testsupport.sqlite_db_remove(path)

    s, err := open(path)
    testing.expect_value(t, err, Error.None)
    testing.expect(t, s != nil, "a successful open returns a store")
    defer close(s)

    version, verr := query_one_i64(s.writer, "PRAGMA user_version")
    testing.expect_value(t, verr, Error.None)
    testing.expect_value(t, version, i64(len(MIGRATIONS)))

    application_id, aerr := query_one_i64(s.writer, "PRAGMA application_id")
    testing.expect_value(t, aerr, Error.None)
    testing.expect_value(t, application_id, i64(APPLICATION_ID))

    testing.expect(t, table_exists(s.writer, "events"), "0001 creates events")
    testing.expect(t, table_exists(s.writer, "session_meta"), "0001 creates session_meta")

    mode, merr := query_one_text(s.writer, "PRAGMA journal_mode")
    testing.expect_value(t, merr, Error.None)
    testing.expect_value(t, mode, "wal")
}

@(test)
test_reopen_applies_nothing :: proc(t: ^testing.T) {
    path := testsupport.sqlite_db_path(t, "reopen")
    defer testsupport.sqlite_db_remove(path)

    first, err := open(path)
    testing.expect_value(t, err, Error.None)
    close(first)

    again, reopen_err := open(path)
    testing.expect_value(t, reopen_err, Error.None)
    defer close(again)

    version, verr := query_one_i64(again.writer, "PRAGMA user_version")
    testing.expect_value(t, verr, Error.None)
    testing.expect_value(t, version, i64(len(MIGRATIONS)))

    // Re-running 0001 would fail on the existing tables; one hash row per step
    // is the second witness that nothing was applied twice.
    rows, rerr := query_one_i64(again.writer, "SELECT count(*) FROM migration_hash")
    testing.expect_value(t, rerr, Error.None)
    testing.expect_value(t, rows, i64(len(MIGRATIONS)))
}

@(test)
test_pending_step_applies_only_the_new_one :: proc(t: ^testing.T) {
    db, rc := sqlite.open_memory()
    testing.expect_value(t, rc, sqlite.Result.Ok)
    defer testing.expect_value(t, sqlite.close(db), sqlite.Result.Ok)

    probes := probe_migrations()
    testing.expect_value(t, migrations_apply(db, probes[:1]), Error.None)
    testing.expect(t, table_exists(db, "probe_one"), "step 1 ran")
    testing.expect(t, !table_exists(db, "probe_two"), "step 2 is not in the set yet")

    // Step 1 re-run would fail on the existing table, so success here is proof
    // the runner skipped it.
    testing.expect_value(t, migrations_apply(db, probes[:]), Error.None)
    testing.expect(t, table_exists(db, "probe_two"), "step 2 ran")

    version, verr := query_one_i64(db, "PRAGMA user_version")
    testing.expect_value(t, verr, Error.None)
    testing.expect_value(t, version, i64(2))
}

@(test)
test_failed_first_migration_claims_nothing :: proc(t: ^testing.T) {
    db, rc := sqlite.open_memory()
    testing.expect_value(t, rc, sqlite.Result.Ok)
    defer testing.expect_value(t, sqlite.close(db), sqlite.Result.Ok)

    broken := [?]Migration{{version = 1, sql = "CREATE TABLE probe(a INTEGER); CREATE TABLE probe(a INTEGER);"}}
    testing.expect_value(t, migrations_apply(db, broken[:], APPLICATION_ID), Error.Migration_Failed)

    version, version_err := query_one_i64(db, "PRAGMA user_version")
    testing.expect_value(t, version_err, Error.None)
    testing.expect_value(t, version, i64(0))

    application_id, app_err := query_one_i64(db, "PRAGMA application_id")
    testing.expect_value(t, app_err, Error.None)
    testing.expect_value(t, application_id, i64(0))
    testing.expect(t, !table_exists(db, "probe"), "failed migration rolled back its schema")
    testing.expect(t, !table_exists(db, "migration_hash"), "failed migration rolled back runner bookkeeping")
}

@(test)
test_open_upgrades_the_real_previous_schema :: proc(t: ^testing.T) {
    path := testsupport.sqlite_db_path(t, "upgrade")
    defer testsupport.sqlite_db_remove(path)

    db, rc := sqlite.open(path)
    testing.expect_value(t, rc, sqlite.Result.Ok)
    testing.expect_value(t, migrations_apply(db, MIGRATIONS[:1]), Error.None)
    testing.expect_value(t, sqlite.close(db), sqlite.Result.Ok)

    s, err := open(path)
    testing.expect_value(t, err, Error.None)
    defer close(s)

    version, version_err := query_one_i64(s.writer, "PRAGMA user_version")
    testing.expect_value(t, version_err, Error.None)
    testing.expect_value(t, version, i64(len(MIGRATIONS)))

    application_id, app_err := query_one_i64(s.writer, "PRAGMA application_id")
    testing.expect_value(t, app_err, Error.None)
    testing.expect_value(t, application_id, i64(APPLICATION_ID))

    ddl, ddl_err := query_one_text(s.writer, "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'events'")
    testing.expect_value(t, ddl_err, Error.None)
    testing.expect(t, strings.contains(ddl, "typeof(seq)"), "migration 2 installed the numeric storage check")
}

@(test)
test_future_user_version_is_refused :: proc(t: ^testing.T) {
    path := testsupport.sqlite_db_path(t, "future")
    defer testsupport.sqlite_db_remove(path)

    s, err := open(path)
    testing.expect_value(t, err, Error.None)
    close(s)

    raw, rc := sqlite.open(path)
    testing.expect_value(t, rc, sqlite.Result.Ok)
    testing.expect_value(t, sqlite.exec(raw, "PRAGMA user_version = 99"), sqlite.Result.Ok)
    testing.expect_value(t, sqlite.close(raw), sqlite.Result.Ok)

    before, before_err := os.read_entire_file(path, context.temp_allocator)
    testing.expect(t, before_err == nil, "could not snapshot the future database")

    ahead, ahead_err := open(path)
    testing.expect_value(t, ahead_err, Error.Version_Unsupported)
    testing.expect(t, ahead == nil, "a refused open returns no store")

    after, after_err := os.read_entire_file(path, context.temp_allocator)
    testing.expect(t, after_err == nil, "could not read the refused database")
    testing.expect(t, slice.equal(before, after), "refusing a future version does not mutate it")
}

@(test)
test_negative_user_version_is_refused :: proc(t: ^testing.T) {
    path := testsupport.sqlite_db_path(t, "negative")
    defer testsupport.sqlite_db_remove(path)

    s, err := open(path)
    testing.expect_value(t, err, Error.None)
    close(s)

    // `user_version` is a signed 32-bit slot; a negative value names no step, so
    // it is as unrunnable as one past the end.
    raw, rc := sqlite.open(path)
    testing.expect_value(t, rc, sqlite.Result.Ok)
    testing.expect_value(t, sqlite.exec(raw, "PRAGMA user_version = -1"), sqlite.Result.Ok)
    testing.expect_value(t, sqlite.close(raw), sqlite.Result.Ok)

    behind, behind_err := open(path)
    testing.expect_value(t, behind_err, Error.Version_Unsupported)
    testing.expect(t, behind == nil, "a refused open returns no store")
}

@(test)
test_reopen_after_missing_migration_hash_is_refused :: proc(t: ^testing.T) {
    path := testsupport.sqlite_db_path(t, "drift")
    defer testsupport.sqlite_db_remove(path)

    s, err := open(path)
    testing.expect_value(t, err, Error.None)
    close(s)

    raw, rc := sqlite.open(path)
    testing.expect_value(t, rc, sqlite.Result.Ok)
    testing.expect_value(t, sqlite.exec(raw, "DELETE FROM migration_hash WHERE version = 2"), sqlite.Result.Ok)
    testing.expect_value(t, sqlite.close(raw), sqlite.Result.Ok)

    before, before_err := os.read_entire_file(path, context.temp_allocator)
    testing.expect(t, before_err == nil, "could not snapshot the drifted database")

    drifted, drift_err := open(path)
    testing.expect_value(t, drift_err, Error.Migration_Drift)
    testing.expect(t, drifted == nil, "a refused open returns no store")

    after, after_err := os.read_entire_file(path, context.temp_allocator)
    testing.expect(t, after_err == nil, "could not read the refused drifted database")
    testing.expect(t, slice.equal(before, after), "checksum refusal does not mutate the database")
}

@(test)
test_valid_foreign_database_is_refused_unchanged :: proc(t: ^testing.T) {
    path := testsupport.sqlite_db_path(t, "foreign")
    defer testsupport.sqlite_db_remove(path)

    db, rc := sqlite.open(path)
    testing.expect_value(t, rc, sqlite.Result.Ok)
    testing.expect_value(t, sqlite.exec(db, "PRAGMA application_id = 42"), sqlite.Result.Ok)
    testing.expect_value(t, sqlite.exec(db, "CREATE TABLE foreign_data(value TEXT NOT NULL)"), sqlite.Result.Ok)
    testing.expect_value(t, sqlite.exec(db, "INSERT INTO foreign_data VALUES ('keep me')"), sqlite.Result.Ok)
    testing.expect_value(t, sqlite.close(db), sqlite.Result.Ok)

    before, before_err := os.read_entire_file(path, context.temp_allocator)
    testing.expect(t, before_err == nil, "could not snapshot the foreign database")

    s, err := open(path)
    testing.expect_value(t, err, Error.Foreign_Database)
    testing.expect(t, s == nil, "a refused open returns no store")

    after, after_err := os.read_entire_file(path, context.temp_allocator)
    testing.expect(t, after_err == nil, "could not read the refused foreign database")
    testing.expect(t, slice.equal(before, after), "identity refusal does not mutate a foreign database")
}

@(test)
test_non_database_file_is_corrupt :: proc(t: ^testing.T) {
    path := testsupport.sqlite_db_path(t, "garbage")
    defer testsupport.sqlite_db_remove(path)

    junk := make([]byte, 4096, context.temp_allocator)
    for &b, i in junk {
        b = byte(i)
    }
    testing.expect(t, os.write_entire_file(path, junk) == nil, "could not seed the garbage file")

    s, err := open(path)
    testing.expect_value(t, err, Error.Corrupt)
    testing.expect(t, s == nil, "a refused open returns no store")
}

@(test)
test_migration_hash_rows_are_dense_and_immutable :: proc(t: ^testing.T) {
    db, rc := sqlite.open_memory()
    testing.expect_value(t, rc, sqlite.Result.Ok)
    defer testing.expect_value(t, sqlite.close(db), sqlite.Result.Ok)

    applied := probe_migrations()
    testing.expect_value(t, migrations_apply(db, applied[:]), Error.None)
    testing.expect_value(t, migration_hash_check(db, applied[:], len(applied)), Error.None)

    edited := probe_migrations()
    edited[1].sql = "CREATE TABLE probe_two(b INTEGER);"
    testing.expect_value(t, migration_hash_check(db, edited[:], len(edited)), Error.Migration_Drift)
}

@(test)
test_partial_statement_prepare_finalizes_itself :: proc(t: ^testing.T) {
    db, rc := sqlite.open_memory()
    testing.expect_value(t, rc, sqlite.Result.Ok)

    // session_meta exists but events does not, so the set fails part-way and has
    // to unwind the statements it already prepared.
    ddl := `CREATE TABLE session_meta (
        session_id      BLOB PRIMARY KEY,
        seq_high        INTEGER NOT NULL DEFAULT 0,
        message_id_high INTEGER NOT NULL DEFAULT 0,
        run_id_high     INTEGER NOT NULL DEFAULT 0,
        input_id_high   INTEGER NOT NULL DEFAULT 0,
        config_rev_high INTEGER NOT NULL DEFAULT 0
    )`
    testing.expect_value(t, sqlite.exec(db, ddl), sqlite.Result.Ok)

    set: Statements
    testing.expect(t, statements_prepare(db, &set) != .None, "the set cannot be prepared without events")
    testing.expect(t, set == (Statements{}), "a failed prepare leaves no statement behind")
    testing.expect_value(t, sqlite.close(db), sqlite.Result.Ok)
}

@(private = "file")
probe_migrations :: proc() -> [2]Migration {
    return [2]Migration {
        {version = 1, sql = "CREATE TABLE probe_one(a INTEGER);"},
        {version = 2, sql = "CREATE TABLE probe_two(a INTEGER);"},
    }
}

@(private = "file")
table_exists :: proc(db: ^sqlite.Conn, name: string) -> bool {
    count, err := query_one_i64(
        db,
        fmt.tprintf("SELECT count(*) FROM sqlite_master WHERE type='table' AND name='%s'", name),
    )

    return err == .None && count == 1
}
