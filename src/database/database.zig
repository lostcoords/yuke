//! The daemon database owns one SQLite connection and all store queries.
//! The daemon uses one rebased baseline schema and can discard the database before release.

const std = @import("std");
const sql = @import("sql");
const queries_gen = @import("queries_gen.zig");

pub const catalog = @import("catalog.zig");

/// The baseline schema version. The daemon rejects any other version and does not migrate it.
const SCHEMA_VERSION: i64 = 1;

/// Each entry is a sentinel-terminated DDL script. The daemon applies entries in array order.
const schema = [_][:0]const u8{
    @embedFile("schema/catalog.sql"),
    @embedFile("schema/session.sql"),
};

/// The shared handle stores the connection and owns all prepared queries.
pub const Database = struct {
    conn: sql.Connection,
    queries: queries_gen.Queries,

    /// Take ownership of `conn`, apply the baseline schema once, and prepare the queries.
    /// Close the connection if any step fails.
    pub fn open(conn: sql.Connection) !Database {
        errdefer conn.close();

        // Run these per-connection pragmas outside a transaction.
        try conn.execNoArgs("PRAGMA foreign_keys = ON");
        try setWal(conn);

        const version = try userVersion(conn);
        if (version == 0) {
            try conn.execNoArgs("BEGIN");
            errdefer conn.execNoArgs("ROLLBACK") catch {};
            for (schema) |s| try conn.execNoArgs(s);
            try conn.execNoArgs(std.fmt.comptimePrint("PRAGMA user_version = {d}", .{SCHEMA_VERSION}));
            try conn.execNoArgs("COMMIT");
        } else if (version != SCHEMA_VERSION) {
            return error.IncompatibleDatabase;
        }

        return .{ .conn = conn, .queries = try queries_gen.Queries.prepareAll(conn) };
    }

    pub fn deinit(self: *Database) void {
        self.queries.deinit();
        self.conn.close();
        self.* = undefined;
    }
};

/// Read the database format version from the header.
fn userVersion(conn: sql.Connection) !i64 {
    const r = (try conn.row("PRAGMA user_version", .{})) orelse return error.PragmaReadFailed;
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

test "open applies the baseline on a fresh database" {
    const conn = try zqlite.open(":memory:", test_flags);
    var db = try Database.open(conn);
    defer db.deinit();

    const r = (try db.conn.row("PRAGMA user_version", .{})).?;
    defer r.deinit();
    try std.testing.expectEqual(SCHEMA_VERSION, r.int(0));
}

test "open rejects an incompatible database version" {
    const conn = try zqlite.open(":memory:", test_flags);
    try conn.execNoArgs("PRAGMA user_version = 99");
    try std.testing.expectError(error.IncompatibleDatabase, Database.open(conn));
}

// The skip path becomes strict once session.sql adds plain CREATE TABLE; catalog.sql uses
// IF NOT EXISTS, so a reapply here would not fail.
test "open skips the baseline when the version matches" {
    const conn = try zqlite.open(":memory:", test_flags);
    for (schema) |s| try conn.execNoArgs(s);
    try conn.execNoArgs("PRAGMA user_version = 1");
    var db = try Database.open(conn);
    defer db.deinit();
}
