package store

import "core:mem"
import "core:strings"

import "libs:sqlite"

// Lock wait for external inspectors; the daemon itself keeps a single writer.
BUSY_TIMEOUT_MS :: 5000

// `PRAGMA synchronous` reports its mode as an integer; NORMAL is 1.
@(private)
SYNCHRONOUS_NORMAL :: 1

// SQLite header identity: ASCII "YUKE". A zero application_id is accepted only
// for an empty database or the exact v1 store that predates this header marker.
APPLICATION_ID :: 0x59554b45

// Store-open and migration failures. SQLite results collapse into these: each
// name is a distinction the caller can act on.
Error :: enum {
    // No error.
    None,

    // The file could not be opened or configured as a WAL database.
    Open_Failed,

    // Not a database, or `quick_check` reported damage.
    Corrupt,

    // Another writer held the lock past `busy_timeout`.
    Busy,

    // Disk I/O failed.
    Io,

    // A migration statement or its transaction failed.
    Migration_Failed,

    // Applied migration_hash rows are missing, extra, malformed, or do not
    // match the immutable embedded step text.
    Migration_Drift,

    // A valid SQLite database belongs to another application.
    Foreign_Database,

    // A write statement or its transaction failed.
    Write_Failed,

    // A read statement failed, or a stored row is not a value this binary knows.
    Read_Failed,

    // A uniqueness or column constraint rejected the write; for an append that
    // means `(session_id, seq)` is already on the log.
    Constraint,

    // The appended seq did not continue the session's high-water, so nothing was
    // written. The pump is the sole seq authority and mints `seq_high + 1`.
    Seq_Conflict,

    // `user_version` names a schema this binary does not know; a newer daemon
    // wrote this database.
    Version_Unsupported,

    // Allocation failed, SQLite's or ours.
    Out_Of_Memory,
}

// The daemon's event store. Owns the writer connection, which the writer
// discipline confines to the reactor thread.
Store :: struct {
    writer:    ^sqlite.Conn,
    stmts:     Statements,
    allocator: mem.Allocator,
}

// Open the store at `path`, creating it if absent, and migrate it to the latest
// embedded schema. On error nothing is left open.
open :: proc(path: string, allocator := context.allocator) -> (s: ^Store, err: Error) {
    assert(len(path) > 0, "open needs a path")

    db, rc := sqlite.open(path, {.Readwrite, .Create, .Nomutex})

    if rc != .Ok {
        // A failed open closes and clears the connection, so there is nothing
        // left to interrogate for a finer code.
        assert(db == nil, "a failed open must not leak a connection")

        return nil, .Out_Of_Memory if rc == .No_Mem else .Open_Failed
    }

    defer if err != .None {
        close_rc := sqlite.close(db)
        assert(close_rc == .Ok, "failed open leaves no SQLite child alive")
    }

    if rc = sqlite.busy_timeout(db, BUSY_TIMEOUT_MS); rc != .Ok {
        return nil, error_from(db, rc, .Open_Failed)
    }

    store_check_integrity(db) or_return
    store_check_identity(db) or_return
    store_configure(db) or_return
    migrations_apply(db, MIGRATIONS[:], APPLICATION_ID) or_return

    stmts: Statements

    defer if err != .None {
        statements_finalize(&stmts)
    }

    statements_prepare(db, &stmts) or_return

    opened, aerr := new(Store, allocator)

    if aerr != nil {
        return nil, .Out_Of_Memory
    }

    opened^ = Store {
        writer    = db,
        stmts     = stmts,
        allocator = allocator,
    }

    return opened, .None
}

// Close the writer and free the handle; it is dead afterwards.
close :: proc(s: ^Store) {
    assert(s != nil, "close needs a store")
    assert(s.writer != nil, "an open store always holds its writer")

    statements_finalize(&s.stmts)

    rc := sqlite.close(s.writer)
    assert(rc == .Ok, "a SQLite child outlived the store it belongs to")

    s.writer = nil
    free(s, s.allocator)
}

// WAL plus `synchronous=NORMAL` is the durability contract: commits survive a
// process crash, power loss can only lose the newest commits.
@(private)
store_configure :: proc(db: ^sqlite.Conn) -> Error {
    assert(db != nil, "store_configure needs a connection")

    rc := sqlite.exec(db, "PRAGMA journal_mode=WAL")

    if rc != .Ok {
        return error_from(db, rc, .Open_Failed)
    }

    // WAL is refused on some filesystems, and the pragma reports the mode it
    // settled on rather than failing.
    mode := query_one_text(db, "PRAGMA journal_mode") or_return

    if mode != "wal" {
        return .Open_Failed
    }

    rc = sqlite.exec(db, "PRAGMA synchronous=NORMAL")

    if rc != .Ok {
        return error_from(db, rc, .Open_Failed)
    }

    // Read back like journal_mode: half the durability contract is worthless if
    // the other half silently settled somewhere else.
    sync := query_one_i64(db, "PRAGMA synchronous") or_return

    if sync != SYNCHRONOUS_NORMAL {
        return .Open_Failed
    }

    return .None
}

// Cheap startup sanity. Damage is a store-open error, never a crash.
@(private)
store_check_integrity :: proc(db: ^sqlite.Conn) -> Error {
    assert(db != nil, "store_check_integrity needs a connection")

    // The argument caps reporting at the first fault; we only branch on "ok".
    report := query_one_text(db, "PRAGMA quick_check(1)") or_return

    if report != "ok" {
        return .Corrupt
    }

    return .None
}

// Refuse to adopt a valid but unrelated SQLite database. Identity and version
// checks happen before journal configuration or migration can write anything.
@(private)
store_check_identity :: proc(db: ^sqlite.Conn) -> Error {
    assert(db != nil, "store_check_identity needs a connection")

    application_id := query_one_i64(db, "PRAGMA application_id") or_return
    version := query_one_i64(db, "PRAGMA user_version") or_return

    if application_id == APPLICATION_ID {
        if version < 1 || version > i64(len(MIGRATIONS)) {
            return .Version_Unsupported
        }

        return migration_hash_check(db, MIGRATIONS[:], int(version))
    }

    if application_id != 0 {
        return .Foreign_Database
    }

    objects := query_one_i64(db, "SELECT count(*) FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'") or_return

    if version == 0 {
        return .None if objects == 0 else .Foreign_Database
    }

    // Commit 1501c4a1 shipped schema v1 before application_id was assigned. Its
    // three exact tables plus immutable migration hash are sufficient identity;
    // migration 2 claims the header in the same transaction as its upgrade.
    if version == 1 && objects == 3 {
        expected := query_one_i64(
            db,
            `SELECT count(*) FROM sqlite_master
                WHERE type = 'table' AND name IN ('events', 'session_meta', 'migration_hash')`,
        ) or_return

        if expected == 3 {
            hash_err := migration_hash_check(db, MIGRATIONS[:1], 1)

            if hash_err == .None {
                return .None
            }

            if hash_err != .Migration_Drift {
                return hash_err
            }
        }
    }

    return .Foreign_Database
}

// Read exactly one row and one integer column from internal SQL.
@(private)
query_one_i64 :: proc(db: ^sqlite.Conn, sql: string, fallback := Error.Open_Failed) -> (value: i64, err: Error) {
    assert(db != nil, "query_one_i64 needs a connection")
    assert(len(sql) > 0, "query_one_i64 needs a statement")

    st, rc := sqlite.prepare(db, sql)

    if rc != .Ok {
        return 0, error_from(db, rc, fallback)
    }
    defer sqlite.finalize(st)
    assert(sqlite.column_count(st) == 1, "query_one_i64 SQL returns one column")

    rc = sqlite.step(st)

    if rc != .Row {
        return 0, error_from(db, rc, fallback) if sqlite.is_error(rc) else fallback
    }

    if sqlite.column_type(st, 0) != .Integer {
        return 0, fallback
    }

    value = sqlite.column_i64(st, 0)

    rc = sqlite.step(st)

    if rc != .Done {
        return 0, error_from(db, rc, fallback) if sqlite.is_error(rc) else fallback
    }

    return value, .None
}

// Read exactly one row and one text column. The result is temp-allocated because
// the SQLite column borrow dies with the statement.
@(private)
query_one_text :: proc(db: ^sqlite.Conn, sql: string, fallback := Error.Open_Failed) -> (value: string, err: Error) {
    assert(db != nil, "query_one_text needs a connection")
    assert(len(sql) > 0, "query_one_text needs a statement")

    st, rc := sqlite.prepare(db, sql)

    if rc != .Ok {
        return "", error_from(db, rc, fallback)
    }
    defer sqlite.finalize(st)
    assert(sqlite.column_count(st) == 1, "query_one_text SQL returns one column")

    rc = sqlite.step(st)

    if rc != .Row {
        return "", error_from(db, rc, fallback) if sqlite.is_error(rc) else fallback
    }

    if sqlite.column_type(st, 0) != .Text {
        return "", fallback
    }

    cloned, clone_err := strings.clone(sqlite.column_text(st, 0), context.temp_allocator)

    if clone_err != nil {
        return "", .Out_Of_Memory
    }

    value = cloned

    rc = sqlite.step(st)

    if rc != .Done {
        return "", error_from(db, rc, fallback) if sqlite.is_error(rc) else fallback
    }

    return value, .None
}

// Classify a failing SQLite result. `rc` is the failure at hand; the connection's
// extended code only refines it, and is consulted only when it describes that same
// failure — a bind never sets it, so a stale code must not classify this call.
@(private)
error_from :: proc(db: ^sqlite.Conn, rc: sqlite.Result, fallback: Error) -> Error {
    assert(db != nil, "error_from needs a connection")
    assert(sqlite.is_error(rc), "error_from classifies failures only")
    assert(fallback != .None, "a failure never classifies as None")

    ext := sqlite.extended_result_base(sqlite.extended_errcode(db))
    base := ext if ext == rc else rc

    #partial switch base {
    case .Corrupt, .Not_A_Db:
        return .Corrupt

    case .Busy, .Locked:
        return .Busy

    case .Constraint:
        return .Constraint

    case .Io_Err, .Full:
        return .Io

    case .No_Mem:
        return .Out_Of_Memory

    case .Cant_Open:
        return .Open_Failed

    case .Perm, .Read_Only:
        return .Open_Failed if fallback == .Open_Failed else fallback
    }

    return fallback
}

// BEGIN IMMEDIATE, never DEFERRED: a deferred lock upgrade returns BUSY without
// consulting busy_timeout.
@(private)
txn_begin :: proc(db: ^sqlite.Conn, fallback: Error) -> Error {
    assert(db != nil, "txn_begin needs a connection")
    assert(fallback != .None, "a failure never classifies as None")
    assert(sqlite.autocommit(db), "the store never nests transactions")

    rc := sqlite.exec(db, "BEGIN IMMEDIATE")

    if rc != .Ok {
        return error_from(db, rc, fallback)
    }

    assert(!sqlite.autocommit(db), "BEGIN IMMEDIATE starts a transaction")

    return .None
}

// COMMIT only. The transaction owner has a single deferred rollback path for
// both body and commit failures.
@(private)
txn_commit :: proc(db: ^sqlite.Conn, fallback: Error) -> Error {
    assert(db != nil, "txn_commit needs a connection")
    assert(fallback != .None, "a failure never classifies as None")
    assert(!sqlite.autocommit(db), "COMMIT requires an active transaction")

    rc := sqlite.exec(db, "COMMIT")

    if rc != .Ok {
        return error_from(db, rc, fallback)
    }

    assert(sqlite.autocommit(db), "a successful COMMIT ends the transaction")

    return .None
}
