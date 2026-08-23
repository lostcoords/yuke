//! The session config projection. A config change writes one event and one revision row, and sets the
//! session's current config. session.config reads a revision back directly. Replay rebuilds this.

const std = @import("std");
const wire = @import("wire");
const sql = @import("sql");
const Database = @import("database.zig").Database;
const event = @import("event.zig");

/// Append a config change: log the revision, store it, and set the session's current config. Run
/// inside a write transaction. The caller mints event_id.
pub fn appendConfig(
    db: *Database,
    arena: std.mem.Allocator,
    session_id: [16]u8,
    event_id: [16]u8,
    committed_at_ms: u64,
    config: wire.run.RunConfig,
) !u64 {
    std.debug.assert(sql.inTransaction(db.conn)); // else the event and projection can half-apply
    const payload = try std.json.Stringify.valueAlloc(arena, config, .{ .emit_null_optional_fields = false });
    const seq = try event.append(db, arena, session_id, event_id, committed_at_ms, "config.changed", payload);

    try db.queries.insert_config.exec(.{
        .session_id = session_id,
        .config_rev = config.config_rev,
        .model = config.model,
        .reasoning = config.reasoning,
    });
    _ = try db.queries.advance_config.one(arena, .{
        .id = session_id,
        .config_rev = config.config_rev,
        .model = config.model,
        .reasoning = config.reasoning,
        .seq = seq,
        .updated_at_ms = committed_at_ms,
    });
    return seq;
}

/// Record the birth config as revision 0. Create calls this so every referenced revision, the initial
/// one included, resolves. It logs no event; the session row already carries the config.
pub fn recordInitial(db: *Database, session_id: [16]u8, model: []const u8, reasoning: []const u8) !void {
    std.debug.assert(sql.inTransaction(db.conn)); // create records this with the session in one commit
    try db.queries.insert_config.exec(.{ .session_id = session_id, .config_rev = 0, .model = model, .reasoning = reasoning });
}

/// Read one historical config revision into `arena`, or null when the revision does not exist.
pub fn byRevision(db: *Database, arena: std.mem.Allocator, session_id: [16]u8, config_rev: u64) !?wire.run.RunConfig {
    const row = (try db.queries.config_by_revision.maybeOne(arena, .{ .session_id = session_id, .config_rev = config_rev })) orelse return null;
    return .{ .config_rev = config_rev, .model = row.value.model, .reasoning = row.value.reasoning };
}

const testing = std.testing;
const zqlite = @import("zqlite");
const workspace = @import("workspace.zig");
const session = @import("session.zig");

fn testDb() !Database {
    const conn = try zqlite.open(":memory:", zqlite.OpenFlags.Create | zqlite.OpenFlags.NoMutex | zqlite.OpenFlags.EXResCode);
    return Database.open(conn);
}

fn scalarText(db: *Database, arena: std.mem.Allocator, query: []const u8) ![]const u8 {
    const row = (try db.conn.row(query, .{})) orelse return error.NoRow;
    defer row.deinit();
    return arena.dupe(u8, row.text(0));
}

test "a config change stores a revision and sets the current config" {
    var db = try testDb();
    defer db.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const ws = try workspace.resolve(&db, a, [_]u8{7} ** 16, "/w", "w", "/w");
    const sid = [_]u8{3} ** 16;
    try session.create(&db, .{
        .id = sid,
        .workspace_id = ws.id,
        .origin = "root",
        .profile = "default",
        .model = "opus",
        .reasoning = "high",
        .config_rev = 0,
        .permission = "normal",
        .title = "t",
        .created_at_ms = 100,
        .updated_at_ms = 100,
    });

    try db.conn.execNoArgs("BEGIN IMMEDIATE");
    const seq = try appendConfig(&db, a, sid, [_]u8{1} ** 16, 200, .{ .config_rev = 1, .model = "sonnet", .reasoning = "low" });
    try db.conn.execNoArgs("COMMIT");
    try testing.expectEqual(@as(u64, 1), seq);

    // The revision row is stored.
    try testing.expectEqualStrings("sonnet", try scalarText(&db, a, "SELECT model FROM session_configs WHERE config_rev = 1"));

    // The session's current config now points at the new revision.
    const snap = (try session.snapshot(&db, a, sid)).?;
    try testing.expectEqualStrings("sonnet", snap.model);
    try testing.expectEqualStrings("low", snap.reasoning);
    try testing.expectEqual(@as(u64, 1), snap.config_rev);
}

test "byRevision reads a stored revision and misses an absent one" {
    var db = try testDb();
    defer db.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const ws = try workspace.resolve(&db, a, [_]u8{7} ** 16, "/w", "w", "/w");
    const sid = [_]u8{3} ** 16;
    try session.create(&db, .{
        .id = sid,
        .workspace_id = ws.id,
        .origin = "root",
        .profile = "default",
        .model = "opus",
        .reasoning = "high",
        .config_rev = 0,
        .permission = "normal",
        .title = "t",
        .created_at_ms = 100,
        .updated_at_ms = 100,
    });
    try db.conn.execNoArgs("BEGIN IMMEDIATE");
    _ = try appendConfig(&db, a, sid, [_]u8{1} ** 16, 200, .{ .config_rev = 1, .model = "sonnet", .reasoning = "low" });
    try db.conn.execNoArgs("COMMIT");

    const got = (try byRevision(&db, a, sid, 1)).?;
    try testing.expectEqual(@as(u64, 1), got.config_rev);
    try testing.expectEqualStrings("sonnet", got.model);
    try testing.expectEqualStrings("low", got.reasoning);
    try testing.expect((try byRevision(&db, a, sid, 99)) == null);
}

test "appendConfig rejects a missing session" {
    var db = try testDb();
    defer db.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try db.conn.execNoArgs("BEGIN IMMEDIATE");
    defer db.conn.execNoArgs("ROLLBACK") catch {};
    try testing.expectError(error.NoRow, appendConfig(&db, a, [_]u8{9} ** 16, [_]u8{1} ** 16, 1, .{ .config_rev = 1, .model = "m", .reasoning = "r" }));
}
