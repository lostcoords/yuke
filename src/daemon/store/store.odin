package store

import "core:mem"
import "core:strings"

import "src:daemon/store/queries"

import "libs:bindings/sqlite"

// Lock wait for external inspectors; the daemon itself keeps a single writer.
BUSY_TIMEOUT_MS :: 5000

// SQLite header identity: ASCII "YUKE". A zero application_id is accepted only
// for a freshly created database; every other non-matching header is refused.
APPLICATION_ID :: 0x59554b45

// Outcomes the store decides for itself. Anything SQLite or a row scan decides
// keeps its own code in `Error` instead of being collapsed into a name here.
Store_Error :: enum {
    // The union's nil; never returned as a value.
    None,

    // The file could not be configured with the WAL + NORMAL durability contract
    // the store requires; some filesystems refuse WAL.
    Durability_Unavailable,

    // The connection would not enforce foreign keys, which would leave every
    // ON DELETE CASCADE silently doing nothing rather than failing.
    Constraints_Unavailable,

    // The appended seq did not continue the session's high-water, so nothing was
    // written. The pump is the sole seq authority and mints `seq_high + 1`.
    Seq_Conflict,

    // The append named a session with no registry row, so there is no stream to
    // continue. Distinct from `Seq_Conflict`, which is a divergence of a real mark.
    Unknown_Session,

    // A stored row is well-formed SQLite but not a value this binary accepts:
    // an unknown or live-only broadcast name, an out-of-order seq, an empty payload.
    Invalid_Row,

    // `quick_check` reported damage. A file SQLite refuses outright arrives as its
    // own `.Corrupt` / `.Not_A_Db` instead.
    Integrity_Failed,

    // Applied migration_hash rows are missing, extra, malformed, or do not
    // match the immutable embedded step text.
    Migration_Drift,

    // A valid SQLite database belongs to another application.
    Foreign_Database,

    // `user_version` names a schema this binary does not know; a newer daemon
    // wrote this database.
    Version_Unsupported,

    // One of our own allocations failed; SQLite's arrive as `.No_Mem` and a row
    // scan's as `Scan_Error.Out_Of_Memory`.
    Alloc_Failed,
}

// What a store call can fail with. The two lower layers keep their own vocabulary
// rather than collapsing into a name the caller would have to un-map.
Error :: union #shared_nil {
    Store_Error,
    sqlite.Result,
    sqlite.Scan_Error,
    sqlite.Read_Error,
}

// Unwrap a `Reader` call's error into this package's own union. `sqlite.Error` is
// a distinct union type, so its dynamic variant is re-wrapped rather than assigned.
@(private)
read_err :: proc(err: sqlite.Error) -> Error {
    switch e in err {
    case sqlite.Result:
        return e
    case sqlite.Scan_Error:
        return e
    case sqlite.Read_Error:
        return e
    }

    return nil
}

// The three full-row inserts: their SQL is built by `sqlite.insert_all_sql` from
// their (schema-generated) parameter structs, not from `queries/`, so they are
// bound directly rather than through the generated `Queries` registry.
@(private)
Insert_Binds :: struct {
    create_session: sqlite.Bind_Mapping(queries.Create_Session_Params),
    insert_message: sqlite.Bind_Mapping(queries.Insert_Message_Params),
    insert_config:  sqlite.Bind_Mapping(queries.Insert_Config_Params),
}

// `inserts` is an out-parameter, not a named return: a caller's own `or_return` would
// discard a named return on the error path, dropping whatever was already prepared —
// the same reason `queries.queries_init` takes `^Queries`.
@(private)
inserts_prepare :: proc(db: ^sqlite.Conn, inserts: ^Insert_Binds, allocator: mem.Allocator) -> (err: Error) {
    assert(db != nil, "inserts_prepare needs a connection")
    assert(inserts != nil, "inserts_prepare needs a set to fill")

    inserts.create_session = insert_bind_prepare(db, "sessions", queries.Create_Session_Params, allocator) or_return
    inserts.insert_message = insert_bind_prepare(db, "messages", queries.Insert_Message_Params, allocator) or_return
    inserts.insert_config = insert_bind_prepare(
        db,
        "session_configs",
        queries.Insert_Config_Params,
        allocator,
    ) or_return

    return nil
}

// One full-row insert: its SQL is generated from `P` itself, so a mismatch between the
// two is impossible by construction and asserts rather than propagating.
@(private)
insert_bind_prepare :: proc(
    db: ^sqlite.Conn,
    table: string,
    $P: typeid,
    allocator: mem.Allocator,
) -> (
    bind: sqlite.Bind_Mapping(P),
    err: Error,
) {
    sql := sqlite.insert_all_sql(table, P, allocator)
    defer delete(sql, allocator)

    stmt := sqlite.prepare(db, sql) or_return
    bind_err: sqlite.Bind_Error
    bind, bind_err = sqlite.bind_prepare(stmt, P)
    assert(bind_err == .None, "the generated insert matches its parameter struct")

    return bind, nil
}

@(private)
inserts_destroy :: proc(inserts: ^Insert_Binds) {
    assert(inserts != nil, "inserts_destroy needs a set")

    sqlite.finalize(inserts.create_session.statement)
    sqlite.finalize(inserts.insert_message.statement)
    sqlite.finalize(inserts.insert_config.statement)
}

// The daemon's event store. Owns the writer connection, which the writer
// discipline confines to the reactor thread.
Store :: struct {
    writer:       ^sqlite.Conn,
    queries:      queries.Queries,
    inserts:      Insert_Binds,
    events_after: Events_After_Reader,
    allocator:    mem.Allocator,
}

// Open the store at `path`, creating it if absent, and migrate it to the latest
// embedded schema. On error nothing is left open.
open :: proc(path: string, allocator := context.allocator) -> (s: ^Store, err: Error) {
    assert(len(path) > 0, "open needs a path")

    cpath, clone_err := strings.clone_to_cstring(path, allocator)
    if clone_err != nil {
        return nil, Store_Error.Alloc_Failed
    }
    defer delete(cpath, allocator)

    db := sqlite.open(cpath, {.Readwrite, .Create, .Nomutex}) or_return
    defer if err != nil {
        close_rc := sqlite.close(db)
        assert(close_rc == .Ok, "failed open leaves no SQLite child alive")
    }

    sqlite.busy_timeout(db, BUSY_TIMEOUT_MS) or_return

    // Ignored once the file has pages, and unchangeable under WAL: this is the
    // only slot where it still takes.
    sqlite.exec(db, "PRAGMA page_size = 8192") or_return

    check_integrity(db) or_return
    version := check_identity(db) or_return
    configure(db) or_return
    migrations_apply(db, MIGRATIONS[:], APPLICATION_ID, version) or_return

    q: queries.Queries
    inserts: Insert_Binds
    events_after: Events_After_Reader
    defer if err != nil {
        queries.queries_destroy(&q, allocator)
        inserts_destroy(&inserts)
        events_after_destroy(&events_after, allocator)
    }

    if init_err := queries.queries_init(db, &q, allocator); init_err != nil {
        return nil, read_err(init_err)
    }
    inserts_prepare(db, &inserts, allocator) or_return
    events_after = events_after_prepare(db, allocator) or_return

    opened, aerr := new(Store, allocator)
    if aerr != nil {
        return nil, Store_Error.Alloc_Failed
    }

    opened^ = Store {
        writer       = db,
        queries      = q,
        inserts      = inserts,
        events_after = events_after,
        allocator    = allocator,
    }

    return opened, nil
}

// Close the writer and free the handle; it is dead afterwards.
close :: proc(s: ^Store) {
    assert(s != nil, "close needs a store")
    assert(s.writer != nil, "an open store always holds its writer")

    queries.queries_destroy(&s.queries, s.allocator)
    inserts_destroy(&s.inserts)
    events_after_destroy(&s.events_after, s.allocator)

    rc := sqlite.close(s.writer)
    assert(rc == .Ok, "a SQLite child outlived the store it belongs to")

    s.writer = nil
    free(s, s.allocator)
}

// WAL plus `synchronous=NORMAL`: commits survive a crash, power loss only the newest.
// Foreign keys default off, are per-connection, and are a no-op mid-transaction —
// forgetting one silently disables every ON DELETE CASCADE, so all three are read back.
@(private)
configure :: proc(db: ^sqlite.Conn) -> Error {
    assert(db != nil, "configure needs a connection")

    // WAL is refused on some filesystems, and the pragma reports the mode it
    // settled on rather than failing.
    journaled := sqlite.journal_mode_set(db, .Wal) or_return

    if !journaled {
        return .Durability_Unavailable
    }

    sqlite.synchronous_set(db, .Normal) or_return

    // Read back like journal_mode: half the durability contract is worthless if
    // the other half silently settled somewhere else.
    level := sqlite.synchronous(db) or_return

    if level != .Normal {
        return .Durability_Unavailable
    }

    sqlite.exec(db, "PRAGMA foreign_keys = ON") or_return
    enforced := sqlite.query_one_i64(db, "PRAGMA foreign_keys") or_return

    if enforced != 1 {
        return .Constraints_Unavailable
    }

    return nil
}

// Cheap startup sanity. Damage is a store-open error, never a crash.
@(private)
check_integrity :: proc(db: ^sqlite.Conn) -> Error {
    assert(db != nil, "check_integrity needs a connection")

    // The argument caps reporting at the first fault; we only branch on "ok".
    healthy := sqlite.query_one_text_equal(db, "PRAGMA quick_check(1)", "ok") or_return
    if !healthy {
        return .Integrity_Failed
    }

    return nil
}

// Refuse to adopt a valid but unrelated SQLite database, and report the applied
// version so the migration runner does not re-derive it. Runs before any write.
@(private)
check_identity :: proc(db: ^sqlite.Conn) -> (version: int, err: Error) {
    assert(db != nil, "check_identity needs a connection")

    application_id := sqlite.query_one_i64(db, "PRAGMA application_id") or_return
    stored := sqlite.query_one_i64(db, "PRAGMA user_version") or_return

    if application_id == APPLICATION_ID {
        if stored < 1 || stored > i64(len(MIGRATIONS)) {
            return 0, .Version_Unsupported
        }

        migration_hash_check(db, MIGRATIONS[:], int(stored)) or_return

        return int(stored), nil
    }

    if application_id != 0 || stored != 0 {
        return 0, .Foreign_Database
    }

    objects := sqlite.query_one_i64(db, "SELECT count(*) FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'") or_return

    if objects != 0 {
        return 0, .Foreign_Database
    }

    return 0, nil
}
