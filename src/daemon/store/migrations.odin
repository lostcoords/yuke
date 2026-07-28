package store

import "core:fmt"
import "core:hash"

import "libs:sqlite"

// One forward-only schema step. `version` is what `user_version` becomes when it
// commits; `sql` is immutable once the step has shipped.
@(private)
Migration :: struct {
    version: int,
    sql:     string,
}

// Applied in order; entry i brings the database to version i+1.
@(private, rodata)
MIGRATIONS := [?]Migration {
    {version = 1, sql = #load("migrations/0001_initial.sql", string)},
    {version = 2, sql = #load("migrations/0002_persisted_ranges.sql", string)},
}

// Runner bookkeeping rather than schema: one row per applied step, checked on
// every open so embedded text cannot drift from an applied database.
@(private)
MIGRATION_HASH_DDL :: `CREATE TABLE IF NOT EXISTS migration_hash (
    version INTEGER PRIMARY KEY CHECK (typeof(version) = 'integer' AND version >= 1),
    hash    TEXT NOT NULL CHECK (typeof(hash) = 'text' AND length(hash) = 16)
)`

// Bring `db` up to the last step in `set`. Forward-only: already-applied steps
// are never re-run, and a database past the last known version is refused.
@(private)
migrations_apply :: proc(db: ^sqlite.Conn, set: []Migration, application_id: i64 = 0) -> Error {
    assert(db != nil, "migrations_apply needs a connection")
    assert(len(set) > 0, "the migration set is never empty")
    assert(application_id >= 0 && application_id <= 0x7fffffff, "application_id fits SQLite's signed header slot")
    for m, i in set {
        assert(m.version == i + 1, "migration versions are dense and 1-based")
        assert(len(m.sql) > 0, "a migration carries statements")
    }

    current := query_one_i64(db, "PRAGMA user_version", .Migration_Failed) or_return

    if current < 0 || current > i64(len(set)) {
        return .Version_Unsupported
    }

    if current > 0 {
        migration_hash_check(db, set, int(current)) or_return
    }

    stored_application_id := query_one_i64(db, "PRAGMA application_id", .Migration_Failed) or_return

    if application_id != 0 && stored_application_id != 0 && stored_application_id != application_id {
        return .Migration_Failed
    }

    claim := application_id if stored_application_id == 0 else 0
    for i in int(current) ..< len(set) {
        migration_apply(db, set[i], claim) or_return
        claim = 0
    }

    if claim != 0 {
        return .Migration_Failed
    }

    return migration_hash_check(db, set, len(set))
}

// Require one dense, correctly typed checksum row for every applied version.
// Missing, extra, reordered, or edited rows are on-disk drift, never assertions.
@(private)
migration_hash_check :: proc(db: ^sqlite.Conn, set: []Migration, applied: int) -> Error {
    assert(db != nil, "migration_hash_check needs a connection")
    assert(len(set) > 0, "the migration set is never empty")
    assert(applied >= 1 && applied <= len(set), "applied migration count is in the embedded set")

    st, rc := sqlite.prepare(db, "SELECT version, hash FROM migration_hash ORDER BY version")

    if rc != .Ok {
        return .Migration_Drift if rc == .Error else error_from(db, rc, .Migration_Failed)
    }
    defer sqlite.finalize(st)
    assert(sqlite.column_count(st) == 2, "the checksum query returns version and hash")

    for expected in 1 ..= applied {
        rc = sqlite.step(st)

        if rc != .Row {
            return error_from(db, rc, .Migration_Failed) if sqlite.is_error(rc) else .Migration_Drift
        }

        if sqlite.column_type(st, 0) != .Integer || sqlite.column_type(st, 1) != .Text {
            return .Migration_Drift
        }

        recorded := sqlite.column_i64(st, 0)

        if recorded != i64(expected) {
            return .Migration_Drift
        }

        hash_buf: [16]byte

        if sqlite.column_text(st, 1) != migration_hash(set[expected - 1].sql, &hash_buf) {
            return .Migration_Drift
        }
    }

    rc = sqlite.step(st)

    if rc != .Done {
        return error_from(db, rc, .Migration_Failed) if sqlite.is_error(rc) else .Migration_Drift
    }

    return .None
}

// One step, one transaction: the schema change, its hash row, and the
// `user_version` bump commit together or not at all.
@(private)
migration_apply :: proc(db: ^sqlite.Conn, m: Migration, application_id: i64) -> (err: Error) {
    assert(db != nil, "migration_apply needs a connection")
    assert(m.version >= 1, "migration versions are 1-based")
    assert(len(m.sql) > 0, "a migration carries statements")

    txn_begin(db, .Migration_Failed) or_return

    defer if err != .None {
        rollback := sqlite.exec(db, "ROLLBACK")

        if rollback == .Ok {
            assert(sqlite.autocommit(db), "a successful ROLLBACK ends the migration transaction")
        }
    }

    migration_body(db, m, application_id) or_return
    txn_commit(db, .Migration_Failed) or_return

    return .None
}

// The transactional part of one step; the caller owns the transaction.
@(private)
migration_body :: proc(db: ^sqlite.Conn, m: Migration, application_id: i64) -> Error {
    assert(db != nil, "migration_body needs a connection")
    assert(application_id >= 0 && application_id <= 0x7fffffff, "application_id fits SQLite's signed header slot")

    rc := sqlite.exec(db, MIGRATION_HASH_DDL)

    if rc != .Ok {
        return error_from(db, rc, .Migration_Failed)
    }

    rc = sqlite.exec(db, m.sql)

    if rc != .Ok {
        return error_from(db, rc, .Migration_Failed)
    }

    st, prc := sqlite.prepare(db, "INSERT INTO migration_hash(version, hash) VALUES (?1, ?2)")

    if prc != .Ok {
        return error_from(db, prc, .Migration_Failed)
    }
    defer sqlite.finalize(st)

    if rc = sqlite.bind_i64(st, 1, i64(m.version)); rc != .Ok {
        return error_from(db, rc, .Migration_Failed)
    }

    hash_buf: [16]byte

    if rc = sqlite.bind_text(st, 2, migration_hash(m.sql, &hash_buf)); rc != .Ok {
        return error_from(db, rc, .Migration_Failed)
    }

    if rc = sqlite.step(st); rc != .Done {
        return error_from(db, rc, .Migration_Failed) if sqlite.is_error(rc) else .Migration_Failed
    }

    pragma_buf: [64]byte

    if application_id != 0 {
        pragma := fmt.bprintf(pragma_buf[:], "PRAGMA application_id = %d", application_id)

        if rc = sqlite.exec(db, pragma); rc != .Ok {
            return error_from(db, rc, .Migration_Failed)
        }
    }

    // PRAGMA rejects bound parameters; both values are embedded integers.
    pragma := fmt.bprintf(pragma_buf[:], "PRAGMA user_version = %d", m.version)

    if rc = sqlite.exec(db, pragma); rc != .Ok {
        return error_from(db, rc, .Migration_Failed)
    }

    return .None
}

// FNV-1a over the exact embedded bytes, as fixed-width hex in caller memory.
@(private)
migration_hash :: proc(sql: string, buf: ^[16]byte) -> string {
    assert(len(sql) > 0, "a migration carries statements")
    assert(buf != nil, "migration_hash needs output storage")

    return fmt.bprintf(buf[:], "%016x", hash.fnv64a(transmute([]byte)sql))
}
