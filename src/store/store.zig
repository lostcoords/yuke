//! The engine database owns one SQLite connection and all prepared queries.
//! A forward-only migration engine brings the schema to the latest version on open.

const std = @import("std");
const sql = @import("sql");
const zqlite = @import("zqlite");
const queries_gen = @import("queries_gen.zig");

pub const session = @import("session.zig");
pub const event = @import("event.zig");
pub const message = @import("message.zig");
pub const config = @import("config.zig");
pub const run = @import("run.zig");
pub const input = @import("input.zig");

const test_flags = zqlite.OpenFlags.Create | zqlite.OpenFlags.NoMutex | zqlite.OpenFlags.EXResCode;

/// A yuke database carries this id in the SQLite application_id header slot.
const APPLICATION_ID: i64 = 0x79756B65; // "yuke"

/// Define one forward-only schema step. Keep shipped SQL fixed; make each change a new step.
const Migration = struct { version: i64, sql: [:0]const u8 };

/// Apply the migrations in order. Entry i sets version i+1.
const migrations = [_]Migration{
    .{ .version = 1, .sql = @embedFile("migrations/0001_initial.sql") },
    .{ .version = 2, .sql = @embedFile("migrations/0002_pending_inputs.sql") },
    .{ .version = 3, .sql = @embedFile("migrations/0003_child_admission.sql") },
    .{ .version = 4, .sql = @embedFile("migrations/0004_child_report_name.sql") },
};

comptime {
    std.debug.assert(migrations.len > 0);
    for (migrations, 0..) |m, i| {
        std.debug.assert(m.version == @as(i64, @intCast(i)) + 1); // Versions stay dense and start at 1.
        std.debug.assert(m.sql.len > 0);
    }
}

/// Store one checksum row per applied step. Check it on open to detect changes in shipped SQL.
const migration_hash_ddl =
    \\CREATE TABLE IF NOT EXISTS migration_hash (
    \\    version INTEGER PRIMARY KEY CHECK (version >= 1),
    \\    hash    TEXT NOT NULL CHECK (length(hash) = 16)
    \\) STRICT
;

/// The shared handle stores the connection and owns all prepared queries.
pub const Database = struct {
    conn: sql.Connection,
    queries: queries_gen.Queries,
    /// Private databases still exclude a second engine on the same connection.
    private_owners: std.AutoHashMapUnmanaged([16]u8, void) = .empty,

    /// Take ownership of `conn`, migrate to the latest version, and prepare the queries.
    /// Close the connection if any step fails.
    pub fn open(conn: sql.Connection) !Database {
        errdefer conn.close();
        try migrate(conn);
        return .{ .conn = conn, .queries = try queries_gen.Queries.prepareAll(conn) };
    }

    /// Begin a write transaction. The caller defers `deinit` and then calls `commit`.
    pub fn begin(self: *Database) !Transaction {
        try self.conn.execNoArgs("BEGIN IMMEDIATE");
        return .{ .conn = self.conn };
    }

    /// Open a migrated in-memory database. Tests in every module call this.
    pub fn openTest() !Database {
        return open(try zqlite.open(":memory:", test_flags));
    }

    pub fn deinit(self: *Database) void {
        std.debug.assert(self.private_owners.count() == 0);
        self.queries.deinit();
        self.conn.close();
        self.* = undefined;
    }
};

/// One open write transaction. `commit` ends it; `deinit` rolls back an uncommitted one.
pub const Transaction = struct {
    conn: sql.Connection,
    open: bool = true,

    pub fn commit(self: *Transaction) !void {
        std.debug.assert(self.open);
        try self.conn.execNoArgs("COMMIT");
        self.open = false;
    }

    /// Roll back the transaction. A commit makes this a no-op.
    pub fn deinit(self: *Transaction) void {
        if (self.open) self.conn.execNoArgs("ROLLBACK") catch {};
        self.* = undefined;
    }
};

/// Bring the database to the latest schema version with forward-only migrations.
fn migrate(conn: sql.Connection) !void {
    // Validate identity before any change to the file.
    const app_id = try scalarInt(conn, "PRAGMA application_id");
    if (app_id != 0 and app_id != APPLICATION_ID) return error.ForeignDatabase;

    const applied = try scalarInt(conn, "PRAGMA user_version");
    const user_tables = try scalarInt(conn, "SELECT count(*) FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'");

    const fresh = app_id == 0 and applied == 0 and user_tables == 0;
    const ours = app_id == APPLICATION_ID and applied >= 1 and applied <= migrations.len;
    if (!fresh and !ours) return error.IncompatibleDatabase;

    // The file is ours or empty; now configure the connection.
    try configurePragmas(conn, fresh);

    // One write transaction covers the decision and every step. Several yuke processes may open
    // the same file, so the version is read again under the write lock: the reads above raced.
    try conn.execNoArgs("BEGIN IMMEDIATE");
    errdefer conn.execNoArgs("ROLLBACK") catch {};
    const settled = try scalarInt(conn, "PRAGMA user_version");
    std.debug.assert(settled >= applied); // a migration never moves the version back

    var next: usize = @intCast(settled);
    while (next < migrations.len) : (next += 1) try applyStep(conn, migrations[next]);
    try conn.execNoArgs("COMMIT");

    try checkHashes(conn);
}

/// Set the durability and performance pragmas. A fresh file sets its page size before WAL.
fn configurePragmas(conn: sql.Connection, fresh: bool) !void {
    // Set the wait first, so every statement below it waits. `journal_mode = WAL` takes an
    // exclusive lock, and a second yuke process opening the same file holds one.
    // The wait blocks the one reactor thread, so it bounds a turn-start transaction, which is
    // microseconds, against a first-open migration, which is not.
    try conn.busyTimeout(5000);

    // Set the page size before WAL starts because WAL fixes the page size.
    if (fresh) try conn.execNoArgs("PRAGMA page_size = 4096");
    try setWal(conn);

    // FULL keeps a committed event durable after a power loss. The event log must not lose a commit.
    try conn.execNoArgs("PRAGMA synchronous = FULL");
    try conn.execNoArgs("PRAGMA wal_autocheckpoint = 1000");
    try conn.execNoArgs("PRAGMA cache_size = -32768"); // A negative value sets KiB rather than pages.

    // Foreign keys enforce the projection pointers. Set the pragma outside a transaction because
    // SQLite ignores it inside one, then confirm that the build supports it.
    try conn.execNoArgs("PRAGMA foreign_keys = ON");
    if (try scalarInt(conn, "PRAGMA foreign_keys") != 1) return error.ForeignKeysUnavailable;
}

/// Apply one step and record its checksum. The caller holds the write transaction.
fn applyStep(conn: sql.Connection, m: Migration) !void {
    try conn.execNoArgs(migration_hash_ddl);
    try conn.execNoArgs(m.sql);

    const hash = migrationHash(m.sql);
    try conn.exec("INSERT INTO migration_hash(version, hash) VALUES (?1, ?2)", .{ m.version, &hash });
    try conn.execNoArgs(std.fmt.comptimePrint("PRAGMA application_id = {d}", .{APPLICATION_ID}));

    var buf: [48]u8 = undefined;
    try conn.execNoArgs(try std.fmt.bufPrintZ(&buf, "PRAGMA user_version = {d}", .{m.version}));
}

/// Verify one checksum row for each applied step. Compare each row with the embedded text.
fn checkHashes(conn: sql.Connection) !void {
    var rows = try conn.rows("SELECT version, hash FROM migration_hash ORDER BY version", .{});
    defer rows.deinit();

    var expected: usize = 0;
    while (rows.next()) |row| {
        if (expected >= migrations.len) return error.MigrationDrift;
        const want = migrationHash(migrations[expected].sql);
        if (row.int(0) != migrations[expected].version) return error.MigrationDrift;
        if (!std.mem.eql(u8, row.text(1), &want)) return error.MigrationDrift;
        expected += 1;
    }
    if (rows.err) |err| return err;
    if (expected != migrations.len) return error.MigrationDrift;
}

/// The 16-hex-character checksum of one migration. Big-endian, so it is host-portable.
fn migrationHash(source: [:0]const u8) [16]u8 {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, std.hash.Wyhash.hash(0, source), .big);
    return std.fmt.bytesToHex(bytes, .lower);
}

/// Read a single-integer scalar query.
fn scalarInt(conn: sql.Connection, query: []const u8) !i64 {
    const r = (try conn.row(query, .{})) orelse return error.QueryFailed;
    defer r.deinit();
    return r.int(0);
}

/// Set WAL journal mode. A file database must reach WAL; an in-memory database reports "memory".
fn setWal(conn: sql.Connection) !void {
    if (try readsWal(conn)) return; // another connection already switched the file

    // The switch to WAL takes an exclusive lock and does NOT honour `busy_timeout`: SQLite
    // answers BUSY at once. A second yuke process opening the same file holds that lock for a
    // moment, so this retries instead of failing the open.
    var attempt: u8 = 0;
    while (attempt < wal_switch_attempts) : (attempt += 1) {
        if (conn.row("PRAGMA journal_mode = WAL", .{})) |maybe| {
            const r = maybe orelse return error.PragmaReadFailed;
            defer r.deinit();
            const mode = r.text(0);
            if (std.mem.eql(u8, mode, "wal") or std.mem.eql(u8, mode, "memory")) return;
            return error.WalUnavailable;
        } else |err| switch (err) {
            // The holder finishes its switch in microseconds, so a bounded retry needs no sleep.
            error.Busy => if (try readsWal(conn)) return,
            else => return err,
        }
    }
    return error.Busy;
}

/// How many times one open retries the WAL switch before it gives up.
const wal_switch_attempts: u8 = 200;

/// Report whether the file already reads as WAL. This takes no write lock.
fn readsWal(conn: sql.Connection) !bool {
    const r = (try conn.row("PRAGMA journal_mode", .{})) orelse return error.PragmaReadFailed;
    defer r.deinit();
    const mode = r.text(0);
    return std.mem.eql(u8, mode, "wal") or std.mem.eql(u8, mode, "memory");
}

test {
    std.testing.refAllDecls(@This());
}

test "migrate applies the baseline and claims the database" {
    const conn = try zqlite.open(":memory:", test_flags);
    var db = try Database.open(conn);
    defer db.deinit();

    try std.testing.expectEqual(@as(i64, 4), try scalarInt(db.conn, "PRAGMA user_version"));
    try std.testing.expectEqual(APPLICATION_ID, try scalarInt(db.conn, "PRAGMA application_id"));
    try std.testing.expectEqual(@as(i64, 4), try scalarInt(db.conn, "SELECT count(*) FROM migration_hash"));
}

test "migrate is idempotent on reopen" {
    const conn = try zqlite.open(":memory:", test_flags);
    defer conn.close();
    try migrate(conn);
    try migrate(conn); // The database is current, so apply no step and recheck hashes.
    try std.testing.expectEqual(@as(i64, 4), try scalarInt(conn, "SELECT count(*) FROM migration_hash"));
}

test "migrate renames persisted child report paths" {
    const conn = try zqlite.open(":memory:", test_flags);
    defer conn.close();
    try conn.execNoArgs(@embedFile("migrations/0001_initial.sql"));
    try conn.execNoArgs(@embedFile("migrations/0002_pending_inputs.sql"));
    try conn.execNoArgs(@embedFile("migrations/0003_child_admission.sql"));
    try conn.execNoArgs("INSERT INTO sessions(id, root, origin, profile, model, reasoning, config_rev, title, created_at_ms, updated_at_ms) VALUES (x'01010101010101010101010101010101', '/work', 'root', 'default', 'mock', '', 0, 'root', 1, 1)");
    try conn.execNoArgs("INSERT INTO events(session_id, seq, event_id, committed_at_ms, name, payload) VALUES (x'01010101010101010101010101010101', 1, x'02020202020202020202020202020202', 1, 'message.committed', '{\"type\":\"user\",\"source\":{\"type\":\"child_report\",\"path\":\"/root/a/b\"}}')");
    try conn.execNoArgs("INSERT INTO events(session_id, seq, event_id, committed_at_ms, name, payload) VALUES (x'01010101010101010101010101010101', 2, x'03030303030303030303030303030303', 1, 'input.queued', '{\"session_id\":\"01010101010101010101010101010101\",\"seq\":2,\"input\":{\"content\":[],\"source\":{\"type\":\"child_report\",\"path\":\"/root/a/b\"}}}')");
    try conn.execNoArgs("INSERT INTO pending_inputs(session_id, input_id, seq, queued_at_ms, payload) VALUES (x'01010101010101010101010101010101', 1, 2, 1, '{\"content\":[],\"source\":{\"type\":\"child_report\",\"path\":\"/root/a/b\"}}')");
    try conn.execNoArgs("PRAGMA application_id = 0x79756B65");
    try conn.execNoArgs("PRAGMA user_version = 3");
    try conn.execNoArgs(migration_hash_ddl);
    for (migrations[0..3]) |migration| {
        const hash = migrationHash(migration.sql);
        try conn.exec("INSERT INTO migration_hash(version, hash) VALUES (?1, ?2)", .{ migration.version, &hash });
    }
    try migrate(conn);
    try std.testing.expectEqual(@as(i64, 4), try scalarInt(conn, "PRAGMA user_version"));
    for ([_][]const u8{
        "SELECT json_extract(payload, '$.source.name'), json_type(payload, '$.source.path') IS NULL FROM events WHERE seq = 1",
        "SELECT json_extract(payload, '$.input.source.name'), json_type(payload, '$.input.source.path') IS NULL FROM events WHERE seq = 2",
        "SELECT json_extract(payload, '$.source.name'), json_type(payload, '$.source.path') IS NULL FROM pending_inputs",
    }) |query| {
        const row = (try conn.row(query, .{})).?;
        defer row.deinit();
        try std.testing.expectEqualStrings("b", row.text(0));
        try std.testing.expectEqual(@as(i64, 1), row.int(1));
    }
}

test "migrate rejects a version from the future" {
    const conn = try zqlite.open(":memory:", test_flags);
    defer conn.close();
    try conn.execNoArgs("PRAGMA user_version = 99");
    try std.testing.expectError(error.IncompatibleDatabase, migrate(conn));
}

test "migrate rejects a foreign application id" {
    const conn = try zqlite.open(":memory:", test_flags);
    defer conn.close();
    try conn.execNoArgs("PRAGMA application_id = 12345");
    try std.testing.expectError(error.ForeignDatabase, migrate(conn));
}

test "migrate detects an edited migration" {
    const conn = try zqlite.open(":memory:", test_flags);
    defer conn.close();
    try migrate(conn);
    try conn.execNoArgs("UPDATE migration_hash SET hash = '0000000000000000'");
    try std.testing.expectError(error.MigrationDrift, migrate(conn));
}
