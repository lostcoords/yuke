//! The daemon database owns one SQLite connection and all store queries.
//! The catalog is the first store. Sessions, events, and credentials follow.

const std = @import("std");
const sql = @import("sql");
const queries_gen = @import("queries_gen.zig");

pub const catalog = @import("catalog.zig");

/// Each entry is a sentinel-terminated SQL script.
const migrations = [_][:0]const u8{
    @embedFile("migrations/0001_catalog.sql"),
};

/// The shared handle stores the connection and owns all prepared queries.
pub const Database = struct {
    conn: sql.Connection,
    queries: queries_gen.Queries,

    /// Take ownership of `conn`, apply the migrations atomically, and prepare the
    /// queries. On any failure the connection is closed.
    pub fn open(conn: sql.Connection) !Database {
        errdefer conn.close();
        {
            try conn.execNoArgs("BEGIN");
            errdefer conn.execNoArgs("ROLLBACK") catch {};
            for (migrations) |m| try conn.execNoArgs(m);
            try conn.execNoArgs("COMMIT");
        }
        return .{ .conn = conn, .queries = try queries_gen.Queries.prepareAll(conn) };
    }

    pub fn deinit(self: *Database) void {
        self.queries.deinit();
        self.conn.close();
        self.* = undefined;
    }
};

test {
    std.testing.refAllDecls(@This());
}
