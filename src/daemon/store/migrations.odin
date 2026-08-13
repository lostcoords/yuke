package store

import "core:fmt"
import "core:hash"

import "libs:bindings/sqlite"

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
    {version = 2, sql = #load("migrations/0002_model_transport.sql", string)},
}

// Runner bookkeeping rather than schema: one row per applied step, checked on
// every open so embedded text cannot drift from an applied database.
@(private)
MIGRATION_HASH_DDL :: `CREATE TABLE IF NOT EXISTS migration_hash (
    version INTEGER PRIMARY KEY CHECK (typeof(version) = 'integer' AND version >= 1),
    hash    TEXT NOT NULL CHECK (typeof(hash) = 'text' AND length(hash) = 16)
)`

// Bring `db` up to the last step in `set`. Forward-only; `current` is the applied
// version the caller validated, so nothing here re-derives identity or version.
@(private)
migrations_apply :: proc(db: ^sqlite.Conn, set: []Migration, application_id: i64, current: int) -> Error {
    assert(db != nil, "migrations_apply needs a connection")
    assert(len(set) > 0, "the migration set is never empty")
    assert(application_id >= 0, "application_id is non-negative")
    assert(application_id <= 0x7fffffff, "application_id fits SQLite's signed header slot")
    assert(current >= 0, "the caller validated the applied version")
    assert(current <= len(set), "the caller refused a database past the last known step")
    for m, i in set {
        assert(m.version == i + 1, "migration versions are dense and 1-based")
        assert(len(m.sql) > 0, "a migration carries statements")
    }

    // Only an unclaimed database takes the header, and only a never-migrated one is
    // unclaimed; the first step to run writes it.
    claim := application_id if current == 0 else 0
    for i in current ..< len(set) {
        migration_apply(db, set[i], claim) or_return
        claim = 0
    }

    return migration_hash_check(db, set, len(set))
}

// Require one dense, correctly typed checksum row for every applied version.
// Missing, extra, reordered, or edited rows are on-disk drift, never assertions.
@(private)
migration_hash_check :: proc(db: ^sqlite.Conn, set: []Migration, applied: int) -> Error {
    assert(db != nil, "migration_hash_check needs a connection")
    assert(len(set) > 0, "the migration set is never empty")
    assert(applied >= 1, "at least one migration was applied")
    assert(applied <= len(set), "applied migration count is in the embedded set")

    st, rc := sqlite.prepare(db, "SELECT version, hash FROM migration_hash ORDER BY version")

    if rc != .Ok {
        return .Migration_Drift if rc == .Error else Error(rc)
    }
    defer sqlite.finalize(st)
    assert(sqlite.column_count(st) == 2, "the checksum query returns version and hash")

    for expected in 1 ..= applied {
        rc = sqlite.step(st)
        if rc != .Row {
            return Error(rc) if sqlite.is_error(rc) else .Migration_Drift
        }

        hash_buf: [16]byte
        stored_hash := ""

        if sqlite.column_type(st, 1) == .Text {
            stored_hash = sqlite.column_text(st, 1) or_return
        }

        if sqlite.column_type(st, 0) != .Integer ||
           sqlite.column_type(st, 1) != .Text ||
           sqlite.column_i64(st, 0) != i64(expected) ||
           stored_hash != migration_hash(set[expected - 1].sql, &hash_buf) {
            return .Migration_Drift
        }
    }

    rc = sqlite.step(st)
    if rc != .Done {
        return Error(rc) if sqlite.is_error(rc) else .Migration_Drift
    }

    return nil
}

// One step, one transaction: the schema change, its hash row, and the
// `user_version` bump commit together or not at all.
@(private)
migration_apply :: proc(db: ^sqlite.Conn, m: Migration, application_id: i64) -> (err: Error) {
    assert(db != nil, "migration_apply needs a connection")
    assert(m.version >= 1, "migration versions are 1-based")
    assert(len(m.sql) > 0, "a migration carries statements")

    sqlite.txn_begin(db, .Immediate) or_return

    // A failed ROLLBACK leaves the transaction open, which outlives this call, so it
    // replaces the original error rather than being dropped.
    defer if err != nil {
        if rollback := sqlite.txn_rollback(db); rollback != .Ok {
            err = rollback
        }
    }

    migration_body(db, m, application_id) or_return
    sqlite.txn_commit(db) or_return

    return nil
}

// The transactional part of one step; the caller owns the transaction.
@(private)
migration_body :: proc(db: ^sqlite.Conn, m: Migration, application_id: i64) -> Error {
    assert(db != nil, "migration_body needs a connection")
    assert(application_id >= 0, "application_id is non-negative")
    assert(application_id <= 0x7fffffff, "application_id fits SQLite's signed header slot")

    sqlite.exec(db, MIGRATION_HASH_DDL) or_return
    sqlite.exec(db, m.sql) or_return

    st := sqlite.prepare(db, "INSERT INTO migration_hash(version, hash) VALUES (?1, ?2)") or_return
    defer sqlite.finalize(st)

    hash_buf: [16]byte
    sqlite.bind_i64(st, 1, i64(m.version)) or_return
    sqlite.bind_text(st, 2, migration_hash(m.sql, &hash_buf)) or_return
    sqlite.execute(st) or_return

    pragma_buf: [64]byte

    if application_id != 0 {
        sqlite.exec(db, fmt.bprintf(pragma_buf[:], "PRAGMA application_id = %d", application_id)) or_return
    }

    // PRAGMA rejects bound parameters; both values are embedded integers.
    return sqlite.exec(db, fmt.bprintf(pragma_buf[:], "PRAGMA user_version = %d", m.version))
}

// FNV-1a over the exact embedded bytes, as fixed-width hex in caller memory.
@(private)
migration_hash :: proc(sql: string, buf: ^[16]byte) -> string {
    assert(len(sql) > 0, "a migration carries statements")
    assert(buf != nil, "migration_hash needs output storage")

    return fmt.bprintf(buf[:], "%016x", hash.fnv64a(transmute([]byte)sql))
}
