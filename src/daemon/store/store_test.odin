package store

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"

import "libs:bindings/sqlite"
import "libs:testsupport"

@(test)
test_open_creates_schema_at_latest_version :: proc(t: ^testing.T) {
    path := testsupport.sqlite_db_path(t, "latest")
    defer testsupport.sqlite_db_remove(path)

    s, err := open(path)
    testing.expect_value(t, err, nil)
    testing.expect(t, s != nil, "a successful open returns a store")
    defer close(s)

    version, verr := sqlite.query_one_i64(s.writer, "PRAGMA user_version")
    testing.expect_value(t, verr, sqlite.Result.Ok)
    testing.expect_value(t, version, i64(len(MIGRATIONS)))

    application_id, aerr := sqlite.query_one_i64(s.writer, "PRAGMA application_id")
    testing.expect_value(t, aerr, sqlite.Result.Ok)
    testing.expect_value(t, application_id, i64(APPLICATION_ID))

    testing.expect(t, table_exists(s.writer, "sessions"), "0001 creates sessions")
    testing.expect(t, table_exists(s.writer, "events"), "0001 creates events")
    testing.expect(t, table_exists(s.writer, "messages"), "0001 creates messages")
    testing.expect(t, table_exists(s.writer, "provider_credentials"), "0001 creates provider credentials")
    testing.expect(t, table_exists(s.writer, "catalog_providers"), "0001 creates catalog providers")
    testing.expect(t, table_exists(s.writer, "catalog_models"), "0001 creates catalog models")

    // Both must be settled before WAL and before any transaction; a silent
    // default here would disable every cascade and halve the page budget.
    page, page_err := sqlite.query_one_i64(s.writer, "PRAGMA page_size")
    testing.expect_value(t, page_err, sqlite.Result.Ok)
    testing.expect_value(t, page, i64(8192))

    keys, keys_err := sqlite.query_one_i64(s.writer, "PRAGMA foreign_keys")
    testing.expect_value(t, keys_err, sqlite.Result.Ok)
    testing.expect_value(t, keys, i64(1))

    mode, merr := sqlite.query_one_text(s.writer, "PRAGMA journal_mode")
    defer delete(mode)
    testing.expect_value(t, merr, sqlite.Result.Ok)
    testing.expect_value(t, mode, "wal")

    level, level_rc := sqlite.synchronous(s.writer)
    testing.expect_value(t, level_rc, sqlite.Result.Ok)
    testing.expect_value(t, level, sqlite.Synchronous.Normal)
}

@(test)
test_open_memory_creates_constrained_ephemeral_store :: proc(t: ^testing.T) {
    s, err := open_memory()
    testing.expect_value(t, err, nil)
    testing.expect(t, s != nil, "a successful memory open returns a store")
    defer close(s)

    version, verr := sqlite.query_one_i64(s.writer, "PRAGMA user_version")
    testing.expect_value(t, verr, sqlite.Result.Ok)
    testing.expect_value(t, version, i64(len(MIGRATIONS)))

    mode, merr := sqlite.query_one_text(s.writer, "PRAGMA journal_mode")
    defer delete(mode)
    testing.expect_value(t, merr, sqlite.Result.Ok)
    testing.expect_value(t, mode, "memory")

    keys, keys_err := sqlite.query_one_i64(s.writer, "PRAGMA foreign_keys")
    testing.expect_value(t, keys_err, sqlite.Result.Ok)
    testing.expect_value(t, keys, i64(1))
}

@(test)
test_reopen_applies_nothing :: proc(t: ^testing.T) {
    path := testsupport.sqlite_db_path(t, "reopen")
    defer testsupport.sqlite_db_remove(path)

    first, err := open(path)
    testing.expect_value(t, err, nil)
    close(first)

    again, reopen_err := open(path)
    testing.expect_value(t, reopen_err, nil)
    defer close(again)

    version, verr := sqlite.query_one_i64(again.writer, "PRAGMA user_version")
    testing.expect_value(t, verr, sqlite.Result.Ok)
    testing.expect_value(t, version, i64(len(MIGRATIONS)))

    // Re-running 0001 would fail on the existing tables; one hash row per step
    // is the second witness that nothing was applied twice.
    rows, rerr := sqlite.query_one_i64(again.writer, "SELECT count(*) FROM migration_hash")
    testing.expect_value(t, rerr, sqlite.Result.Ok)
    testing.expect_value(t, rows, i64(len(MIGRATIONS)))
}

@(test)
test_pending_step_applies_only_the_new_one :: proc(t: ^testing.T) {
    db, rc := sqlite.open_memory()
    testing.expect_value(t, rc, sqlite.Result.Ok)
    defer testing.expect_value(t, sqlite.close(db), sqlite.Result.Ok)

    probes := probe_migrations()
    testing.expect_value(t, migrations_apply(db, probes[:1], 0, 0), nil)
    testing.expect(t, table_exists(db, "probe_one"), "step 1 ran")
    testing.expect(t, !table_exists(db, "probe_two"), "step 2 is not in the set yet")

    // Step 1 re-run would fail on the existing table, so success here is proof
    // the runner skipped it.
    testing.expect_value(t, migrations_apply(db, probes[:], 0, 1), nil)
    testing.expect(t, table_exists(db, "probe_two"), "step 2 ran")

    version, verr := sqlite.query_one_i64(db, "PRAGMA user_version")
    testing.expect_value(t, verr, sqlite.Result.Ok)
    testing.expect_value(t, version, i64(2))
}

@(test)
test_failed_first_migration_claims_nothing :: proc(t: ^testing.T) {
    db, rc := sqlite.open_memory()
    testing.expect_value(t, rc, sqlite.Result.Ok)
    defer testing.expect_value(t, sqlite.close(db), sqlite.Result.Ok)

    broken := [?]Migration{{version = 1, sql = "CREATE TABLE probe(a INTEGER); CREATE TABLE probe(a INTEGER);"}}
    testing.expect_value(t, migrations_apply(db, broken[:], APPLICATION_ID, 0), sqlite.Result.Error)

    version, version_err := sqlite.query_one_i64(db, "PRAGMA user_version")
    testing.expect_value(t, version_err, sqlite.Result.Ok)
    testing.expect_value(t, version, i64(0))

    application_id, app_err := sqlite.query_one_i64(db, "PRAGMA application_id")
    testing.expect_value(t, app_err, sqlite.Result.Ok)
    testing.expect_value(t, application_id, i64(0))
    testing.expect(t, !table_exists(db, "probe"), "failed migration rolled back its schema")
    testing.expect(t, !table_exists(db, "migration_hash"), "failed migration rolled back runner bookkeeping")
}

@(test)
test_future_user_version_is_refused :: proc(t: ^testing.T) {
    path := testsupport.sqlite_db_path(t, "future")
    defer testsupport.sqlite_db_remove(path)

    s, err := open(path)
    testing.expect_value(t, err, nil)
    close(s)

    raw, rc := sqlite.open(strings.clone_to_cstring(path, context.temp_allocator))
    testing.expect_value(t, rc, sqlite.Result.Ok)
    testing.expect_value(t, sqlite.exec(raw, "PRAGMA user_version = 99"), sqlite.Result.Ok)
    testing.expect_value(t, sqlite.close(raw), sqlite.Result.Ok)

    before, before_err := os.read_entire_file(path, context.temp_allocator)
    testing.expect(t, before_err == nil, "could not snapshot the future database")

    ahead, ahead_err := open(path)
    testing.expect_value(t, ahead_err, Store_Error.Version_Unsupported)
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
    testing.expect_value(t, err, nil)
    close(s)

    // `user_version` is a signed 32-bit slot; a negative value names no step, so
    // it is as unrunnable as one past the end.
    raw, rc := sqlite.open(strings.clone_to_cstring(path, context.temp_allocator))
    testing.expect_value(t, rc, sqlite.Result.Ok)
    testing.expect_value(t, sqlite.exec(raw, "PRAGMA user_version = -1"), sqlite.Result.Ok)
    testing.expect_value(t, sqlite.close(raw), sqlite.Result.Ok)

    behind, behind_err := open(path)
    testing.expect_value(t, behind_err, Store_Error.Version_Unsupported)
    testing.expect(t, behind == nil, "a refused open returns no store")
}

@(test)
test_reopen_after_missing_migration_hash_is_refused :: proc(t: ^testing.T) {
    path := testsupport.sqlite_db_path(t, "drift")
    defer testsupport.sqlite_db_remove(path)

    s, err := open(path)
    testing.expect_value(t, err, nil)
    close(s)

    raw, rc := sqlite.open(strings.clone_to_cstring(path, context.temp_allocator))
    testing.expect_value(t, rc, sqlite.Result.Ok)
    testing.expect_value(t, sqlite.exec(raw, "DELETE FROM migration_hash WHERE version = 1"), sqlite.Result.Ok)
    testing.expect_value(t, sqlite.close(raw), sqlite.Result.Ok)

    before, before_err := os.read_entire_file(path, context.temp_allocator)
    testing.expect(t, before_err == nil, "could not snapshot the drifted database")

    drifted, drift_err := open(path)
    testing.expect_value(t, drift_err, Store_Error.Migration_Drift)
    testing.expect(t, drifted == nil, "a refused open returns no store")

    after, after_err := os.read_entire_file(path, context.temp_allocator)
    testing.expect(t, after_err == nil, "could not read the refused drifted database")
    testing.expect(t, slice.equal(before, after), "checksum refusal does not mutate the database")
}

@(test)
test_valid_foreign_database_is_refused_unchanged :: proc(t: ^testing.T) {
    path := testsupport.sqlite_db_path(t, "foreign")
    defer testsupport.sqlite_db_remove(path)

    db, rc := sqlite.open(strings.clone_to_cstring(path, context.temp_allocator))
    testing.expect_value(t, rc, sqlite.Result.Ok)
    testing.expect_value(t, sqlite.exec(db, "PRAGMA application_id = 42"), sqlite.Result.Ok)
    testing.expect_value(t, sqlite.exec(db, "CREATE TABLE foreign_data(value TEXT NOT NULL)"), sqlite.Result.Ok)
    testing.expect_value(t, sqlite.exec(db, "INSERT INTO foreign_data VALUES ('keep me')"), sqlite.Result.Ok)
    testing.expect_value(t, sqlite.close(db), sqlite.Result.Ok)

    before, before_err := os.read_entire_file(path, context.temp_allocator)
    testing.expect(t, before_err == nil, "could not snapshot the foreign database")

    s, err := open(path)
    testing.expect_value(t, err, Store_Error.Foreign_Database)
    testing.expect(t, s == nil, "a refused open returns no store")

    after, after_err := os.read_entire_file(path, context.temp_allocator)
    testing.expect(t, after_err == nil, "could not read the refused foreign database")
    testing.expect(t, slice.equal(before, after), "identity refusal does not mutate a foreign database")
}

@(test)
test_non_database_file_is_refused :: proc(t: ^testing.T) {
    path := testsupport.sqlite_db_path(t, "garbage")
    defer testsupport.sqlite_db_remove(path)

    junk := make([]byte, 4096, context.temp_allocator)
    for &b, i in junk {
        b = byte(i)
    }
    testing.expect(t, os.write_entire_file(path, junk) == nil, "could not seed the garbage file")

    // SQLite refuses the header itself, so its own code travels up rather than being
    // collapsed; `Integrity_Failed` is reserved for a quick_check that reports damage.
    s, err := open(path)
    testing.expect_value(t, err, sqlite.Result.Not_A_Db)
    testing.expect(t, s == nil, "a refused open returns no store")
}

@(test)
test_migration_hash_rows_are_dense_and_immutable :: proc(t: ^testing.T) {
    db, rc := sqlite.open_memory()
    testing.expect_value(t, rc, sqlite.Result.Ok)
    defer testing.expect_value(t, sqlite.close(db), sqlite.Result.Ok)

    applied := probe_migrations()
    testing.expect_value(t, migrations_apply(db, applied[:], 0, 0), nil)
    testing.expect_value(t, migration_hash_check(db, applied[:], len(applied)), nil)

    edited := probe_migrations()
    edited[1].sql = "CREATE TABLE probe_two(b INTEGER);"
    testing.expect_value(t, migration_hash_check(db, edited[:], len(edited)), Store_Error.Migration_Drift)
}

@(test)
test_open_releases_a_partial_statement_set :: proc(t: ^testing.T) {
    path := testsupport.sqlite_db_path(t, "partial-prepare")
    defer testsupport.sqlite_db_remove(path)

    s, err := open(path)
    testing.expect_value(t, err, nil)
    testing.expect(t, s != nil, "a successful open returns a store")

    // Identity, version, and hash rows survive the drop, so the reopen below
    // skips migrations and stops part-way through preparing the set.
    testing.expect_value(t, sqlite.exec(s.writer, "DROP TABLE events"), sqlite.Result.Ok)
    close(s)

    // A statement left alive would hold the connection open and trip the
    // "failed open leaves no SQLite child alive" assertion inside `open`.
    again, reopen_err := open(path)
    testing.expect_value(t, reopen_err, sqlite.Result.Error)
    testing.expect(t, again == nil, "a refused open returns no store")
}

// `queries.queries_init`'s first `Reader`-based query is `Read_High`: its statement is
// prepared, then `reader_prepare` resolves the scan side, and only stores the
// pointer in `queries` once that succeeds. Its lone heap allocation (after the
// one `open` makes cloning `path`) is `scan_prepare`'s column table, so a
// `Failing_Allocator` with `fail_at = 1` fails exactly there and nowhere earlier.
// The statement itself must still be finalized on that path, or it is unreachable
// from every cleanup path in `queries` — this would silently pass if it weren't,
// since `open`'s own internal assert ("failed open leaves no SQLite child alive")
// is what actually catches a statement left open on the doomed connection.
@(test)
test_open_finalizes_the_statement_a_reader_oom_orphans :: proc(t: ^testing.T) {
    path := testsupport.sqlite_db_path(t, "reader-oom")
    defer testsupport.sqlite_db_remove(path)

    failing: testsupport.Failing_Allocator
    testsupport.failing_allocator_init(&failing, context.allocator, 1)

    s, err := open(path, testsupport.failing_allocator(&failing))
    testing.expect_value(t, err, sqlite.Scan_Error.Out_Of_Memory)
    testing.expect(t, s == nil, "a refused open returns no store")

    // A statement orphaned by the failed open would still hold the file's only
    // connection busy; a normal reopen only succeeds if that connection was
    // actually closed, which only happens if every one of its statements was.
    again, reopen_err := open(path)
    testing.expect_value(t, reopen_err, nil)
    testing.expect(t, again != nil, "a clean reopen succeeds after a failed one")

    if again != nil {
        close(again)
    }
}

// The registry row and the system prompt are one creation. A failure on the second
// must leave no session behind, or the retry would collide with a row that never
// carried its prompt.
@(test)
test_session_create_is_all_or_nothing :: proc(t: ^testing.T) {
    path := testsupport.sqlite_db_path(t, "session-create-atomic")
    defer testsupport.sqlite_db_remove(path)

    s, err := open(path)
    testing.expect_value(t, err, nil)
    defer close(s)

    testing.expect_value(t, sqlite.exec(s.writer, "DROP TABLE session_prompts"), sqlite.Result.Ok)

    session := test_session(0x8d)
    testing.expect(t, session_create(s, test_session_summary(session), "be brief") != nil, "the prompt insert fails")

    count, count_err := sqlite.query_one_i64(s.writer, "SELECT count(*) FROM sessions")
    testing.expect_value(t, count_err, sqlite.Result.Ok)
    testing.expect_value(t, count, i64(0))
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
    count, err := sqlite.query_one_i64(
        db,
        fmt.tprintf("SELECT count(*) FROM sqlite_master WHERE type='table' AND name='%s'", name),
    )

    return err == .Ok && count == 1
}
