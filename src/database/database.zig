//! The daemon database owns one SQLite connection and all prepared queries.
//! A forward-only migration engine brings the schema to the latest version on open.

const std = @import("std");
const sql = @import("sql");
const queries_gen = @import("queries_gen.zig");

pub const catalog = @import("catalog.zig");
pub const workspace = @import("workspace.zig");
pub const session = @import("session.zig");
pub const event = @import("event.zig");

/// A yuke database carries this id in the SQLite application_id header slot.
const APPLICATION_ID: i64 = 0x79756B65; // "yuke"

/// One forward-only schema step. The sql is immutable once shipped; a change is a new step.
const Migration = struct { version: i64, sql: [:0]const u8 };

/// Apply the migrations in order. Entry i sets version i+1.
const migrations = [_]Migration{
    .{ .version = 1, .sql = @embedFile("migrations/0001_initial.sql") },
};

comptime {
    std.debug.assert(migrations.len > 0);
    for (migrations, 0..) |m, i| {
        std.debug.assert(m.version == @as(i64, @intCast(i)) + 1); // versions stay dense and start at 1
        std.debug.assert(m.sql.len > 0);
    }
}

/// Store one checksum row per applied step. Check it on open so a changed shipped migration
/// cannot diverge from the applied database.
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

    /// Take ownership of `conn`, migrate to the latest version, and prepare the queries.
    /// Close the connection if any step fails.
    pub fn open(conn: sql.Connection) !Database {
        errdefer conn.close();
        try migrate(conn);
        return .{ .conn = conn, .queries = try queries_gen.Queries.prepareAll(conn) };
    }

    pub fn deinit(self: *Database) void {
        self.queries.deinit();
        self.conn.close();
        self.* = undefined;
    }
};

/// Bring the database to the latest schema version. Forward-only.
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

    var next: usize = @intCast(applied);
    while (next < migrations.len) : (next += 1) try applyMigration(conn, migrations[next]);

    try checkHashes(conn);
}

/// Set the durability and performance pragmas. A fresh file sets its page size before WAL.
fn configurePragmas(conn: sql.Connection, fresh: bool) !void {
    // The page size is fixed once WAL starts, so a fresh database sets it first.
    if (fresh) try conn.execNoArgs("PRAGMA page_size = 4096");
    try setWal(conn);

    // FULL keeps a committed event durable after a power loss. The event log must not lose a commit.
    try conn.execNoArgs("PRAGMA synchronous = FULL");
    try conn.execNoArgs("PRAGMA wal_autocheckpoint = 1000");
    try conn.execNoArgs("PRAGMA cache_size = -32768"); // 32 MiB, negative means KiB not pages

    // A small timeout guards against an external checkpoint or backup. A large value would freeze the
    // single reactor thread on a busy signal.
    try conn.busyTimeout(250);

    // Foreign keys enforce the projection pointers. The pragma is a no-op inside a transaction, so set
    // it outside one and confirm the build supports it.
    try conn.execNoArgs("PRAGMA foreign_keys = ON");
    if (try scalarInt(conn, "PRAGMA foreign_keys") != 1) return error.ForeignKeysUnavailable;
}

/// Apply one step and record its checksum, atomically.
fn applyMigration(conn: sql.Connection, m: Migration) !void {
    try conn.execNoArgs("BEGIN");
    errdefer conn.execNoArgs("ROLLBACK") catch {};

    try conn.execNoArgs(migration_hash_ddl);
    try conn.execNoArgs(m.sql);

    const hash = migrationHash(m.sql);
    try conn.exec("INSERT INTO migration_hash(version, hash) VALUES (?1, ?2)", .{ m.version, &hash });
    try conn.execNoArgs(std.fmt.comptimePrint("PRAGMA application_id = {d}", .{APPLICATION_ID}));

    var buf: [48]u8 = undefined;
    try conn.execNoArgs(try std.fmt.bufPrintZ(&buf, "PRAGMA user_version = {d}", .{m.version}));

    try conn.execNoArgs("COMMIT");
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
    const r = (try conn.row("PRAGMA journal_mode = WAL", .{})) orelse return error.PragmaReadFailed;
    defer r.deinit();
    const mode = r.text(0);
    if (!std.mem.eql(u8, mode, "wal") and !std.mem.eql(u8, mode, "memory")) return error.WalUnavailable;
}

test {
    std.testing.refAllDecls(@This());
}

const zqlite = @import("zqlite");
const test_flags = zqlite.OpenFlags.Create | zqlite.OpenFlags.NoMutex | zqlite.OpenFlags.EXResCode;

test "migrate applies the baseline and claims the database" {
    const conn = try zqlite.open(":memory:", test_flags);
    var db = try Database.open(conn);
    defer db.deinit();

    try std.testing.expectEqual(@as(i64, 1), try scalarInt(db.conn, "PRAGMA user_version"));
    try std.testing.expectEqual(APPLICATION_ID, try scalarInt(db.conn, "PRAGMA application_id"));
    try std.testing.expectEqual(@as(i64, 1), try scalarInt(db.conn, "SELECT count(*) FROM migration_hash"));
}

test "migrate is idempotent on reopen" {
    const conn = try zqlite.open(":memory:", test_flags);
    defer conn.close();
    try migrate(conn);
    try migrate(conn); // already at latest: apply nothing, re-check hashes
    try std.testing.expectEqual(@as(i64, 1), try scalarInt(conn, "SELECT count(*) FROM migration_hash"));
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
