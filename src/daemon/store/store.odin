package store

import "core:mem"
import "core:strings"

import "libs:sqlite"

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

    // The appended seq did not continue the session's high-water, so nothing was
    // written. The pump is the sole seq authority and mints `seq_high + 1`.
    Seq_Conflict,

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
}

// The daemon's event store. Owns the writer connection, which the writer
// discipline confines to the reactor thread.
Store :: struct {
    writer:    ^sqlite.Conn,
    stmts:     Statements,
    mappings:  Mappings,
    binds:     Binds,
    allocator: mem.Allocator,
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

    store_check_integrity(db) or_return
    version := store_check_identity(db) or_return
    store_configure(db) or_return
    migrations_apply(db, MIGRATIONS[:], APPLICATION_ID, version) or_return

    stmts: Statements
    mappings: Mappings
    binds: Binds
    defer if err != nil {
        // Mappings resolve columns of these statements, so they die first.
        mappings_destroy(&mappings, allocator)

        // Unprepared slots are still nil, which `finalize` accepts.
        for st in stmts {
            sqlite.finalize(st)
        }
    }

    for sql, id in STATEMENT_SQL {
        stmts[id] = sqlite.prepare(db, sql) or_return
    }

    mappings_prepare(stmts, &mappings, allocator) or_return
    binds_prepare(stmts, &binds)
    opened, aerr := new(Store, allocator)
    if aerr != nil {
        return nil, Store_Error.Alloc_Failed
    }

    opened^ = Store {
        writer    = db,
        stmts     = stmts,
        mappings  = mappings,
        binds     = binds,
        allocator = allocator,
    }

    return opened, nil
}

// Close the writer and free the handle; it is dead afterwards.
close :: proc(s: ^Store) {
    assert(s != nil, "close needs a store")
    assert(s.writer != nil, "an open store always holds its writer")

    // Mappings resolve columns of these statements, so they die first.
    mappings_destroy(&s.mappings, s.allocator)

    for st in s.stmts {
        sqlite.finalize(st)
    }

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

    return nil
}

// Cheap startup sanity. Damage is a store-open error, never a crash.
@(private)
store_check_integrity :: proc(db: ^sqlite.Conn) -> Error {
    assert(db != nil, "store_check_integrity needs a connection")

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
store_check_identity :: proc(db: ^sqlite.Conn) -> (version: int, err: Error) {
    assert(db != nil, "store_check_identity needs a connection")

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
