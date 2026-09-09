//! The session config projection. A config change writes one event and one revision row, and sets the
//! session's current config. session.config reads a revision back directly. Replay rebuilds this.

const std = @import("std");
const proto = @import("proto");
const sql = @import("sql");
const Database = @import("store.zig").Database;
const event = @import("event.zig");

/// Append a config change, store its revision, and set the session's current config.
/// Run inside a write transaction. The caller mints event_id.
pub fn appendConfig(
    db: *Database,
    arena: std.mem.Allocator,
    session_id: [16]u8,
    event_id: [16]u8,
    committed_at_ms: u64,
    config: proto.run.RunConfig,
) !u64 {
    std.debug.assert(sql.inTransaction(db.conn)); // The event and projection must commit together.
    const payload = try std.json.Stringify.valueAlloc(arena, config, .{ .emit_null_optional_fields = false });
    const seq = try event.append(db, arena, session_id, event_id, committed_at_ms, "config.changed", payload);

    try db.queries.insert_config.exec(.{
        .session_id = session_id,
        .config_rev = config.config_rev,
        .model = config.model,
        .reasoning = config.reasoning,
        .max_rounds = config.max_rounds,
    });
    _ = try db.queries.advance_config.one(arena, .{
        .id = session_id,
        .config_rev = config.config_rev,
        .model = config.model,
        .reasoning = config.reasoning,
        .max_rounds = config.max_rounds,
        .seq = seq,
        .updated_at_ms = committed_at_ms,
    });
    return seq;
}

/// Record the birth config as revision 0 so every referenced revision resolves.
/// Create calls this without a log event because the session row already carries the config.
pub fn recordInitial(db: *Database, session_id: [16]u8, config: proto.run.RunConfig) !void {
    std.debug.assert(sql.inTransaction(db.conn)); // Create records this with the session in one commit.
    std.debug.assert(config.config_rev == 0); // The birth config is always revision 0.
    try db.queries.insert_config.exec(.{
        .session_id = session_id,
        .config_rev = 0,
        .model = config.model,
        .reasoning = config.reasoning,
        .max_rounds = config.max_rounds,
    });
}

/// Read one historical config revision into `arena`, or null when the revision does not exist.
pub fn byRevision(db: *Database, arena: std.mem.Allocator, session_id: [16]u8, config_rev: u64) !?proto.run.RunConfig {
    const row = (try db.queries.config_by_revision.maybeOne(arena, .{ .session_id = session_id, .config_rev = config_rev })) orelse return null;
    return .{ .config_rev = config_rev, .model = row.value.model, .reasoning = row.value.reasoning, .max_rounds = row.value.max_rounds };
}

/// Append the config for a revision to `list` once. Fetch it from SQLite. A missing revision is corrupt.
pub fn ensureRevision(db: *Database, arena: std.mem.Allocator, list: *std.ArrayList(proto.run.RunConfig), session_id: [16]u8, rev: u64) !void {
    for (list.items) |c| if (c.config_rev == rev) return;
    const config = (try byRevision(db, arena, session_id, rev)) orelse return error.CorruptLog;
    try list.append(arena, config);
}

/// Return one config for each revision the assistant messages reference. The result borrows `arena`.
pub fn forMessages(db: *Database, arena: std.mem.Allocator, session_id: [16]u8, messages: []const proto.message.Message) ![]const proto.run.RunConfig {
    var list: std.ArrayList(proto.run.RunConfig) = .empty;
    for (messages) |m| switch (m) {
        .assistant => |a| try ensureRevision(db, arena, &list, session_id, a.config_rev),
        else => {},
    };
    return list.items;
}

const testing = std.testing;
const session = @import("session.zig");

fn scalarText(db: *Database, arena: std.mem.Allocator, query: []const u8) ![]const u8 {
    const row = (try db.conn.row(query, .{})) orelse return error.NoRow;
    defer row.deinit();
    return arena.dupe(u8, row.text(0));
}

test "a config change stores a revision and sets the current config" {
    var db = try Database.openTest();
    defer db.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const sid = [_]u8{3} ** 16;
    try session.create(&db, .{
        .id = sid,
        .root = "/w",
        .origin = "root",
        .profile = "default",
        .model = "opus",
        .reasoning = "high",
        .config_rev = 0,
        .title = "t",
        .created_at_ms = 100,
        .updated_at_ms = 100,
    });

    try db.conn.execNoArgs("BEGIN IMMEDIATE");
    const seq = try appendConfig(&db, a, sid, [_]u8{1} ** 16, 200, .{ .config_rev = 1, .model = "sonnet", .reasoning = "low", .max_rounds = 7 });
    try db.conn.execNoArgs("COMMIT");
    try testing.expectEqual(@as(u64, 1), seq);

    // Store the revision row.
    try testing.expectEqualStrings("sonnet", try scalarText(&db, a, "SELECT model FROM session_configs WHERE config_rev = 1"));

    // Point the session's current config at the new revision.
    const snap = (try session.snapshot(&db, a, sid)).?;
    try testing.expectEqualStrings("sonnet", snap.model);
    try testing.expectEqualStrings("low", snap.reasoning);
    try testing.expectEqual(@as(u64, 1), snap.config_rev);
    try testing.expectEqual(@as(?u64, 7), snap.max_rounds);
}

test "byRevision reads a stored revision and misses an absent one" {
    var db = try Database.openTest();
    defer db.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const sid = [_]u8{3} ** 16;
    try session.create(&db, .{
        .id = sid,
        .root = "/w",
        .origin = "root",
        .profile = "default",
        .model = "opus",
        .reasoning = "high",
        .config_rev = 0,
        .title = "t",
        .created_at_ms = 100,
        .updated_at_ms = 100,
    });
    try db.conn.execNoArgs("BEGIN IMMEDIATE");
    _ = try appendConfig(&db, a, sid, [_]u8{1} ** 16, 200, .{ .config_rev = 1, .model = "sonnet", .reasoning = "low", .max_rounds = 5 });
    try db.conn.execNoArgs("COMMIT");

    const got = (try byRevision(&db, a, sid, 1)).?;
    try testing.expectEqual(@as(u64, 1), got.config_rev);
    try testing.expectEqual(@as(?u64, 5), got.max_rounds);
    try testing.expectEqualStrings("sonnet", got.model);
    try testing.expectEqualStrings("low", got.reasoning);
    try testing.expect((try byRevision(&db, a, sid, 99)) == null);
}

test "appendConfig rejects a missing session" {
    var db = try Database.openTest();
    defer db.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try db.conn.execNoArgs("BEGIN IMMEDIATE");
    defer db.conn.execNoArgs("ROLLBACK") catch {};
    try testing.expectError(error.NoRow, appendConfig(&db, a, [_]u8{9} ** 16, [_]u8{1} ** 16, 1, .{ .config_rev = 1, .model = "m", .reasoning = "r" }));
}

test "appendConfig keeps the current config monotonic" {
    var db = try Database.openTest();
    defer db.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const sid = [_]u8{3} ** 16;
    try session.create(&db, .{
        .id = sid,
        .root = "/w",
        .origin = "root",
        .profile = "default",
        .model = "opus",
        .reasoning = "high",
        .config_rev = 0,
        .title = "t",
        .created_at_ms = 100,
        .updated_at_ms = 100,
    });

    try db.conn.execNoArgs("BEGIN IMMEDIATE");
    _ = try appendConfig(&db, a, sid, [_]u8{1} ** 16, 200, .{ .config_rev = 2, .model = "sonnet", .reasoning = "low" });
    try db.conn.execNoArgs("COMMIT");

    // A revision below the mark cannot become current, so return NoRow.
    try db.conn.execNoArgs("BEGIN IMMEDIATE");
    try testing.expectError(error.NoRow, appendConfig(&db, a, sid, [_]u8{2} ** 16, 300, .{ .config_rev = 1, .model = "haiku", .reasoning = "off" }));
    try db.conn.execNoArgs("ROLLBACK");

    // Keep the current config on the newer revision.
    const snap = (try session.snapshot(&db, a, sid)).?;
    try testing.expectEqualStrings("sonnet", snap.model);
    try testing.expectEqual(@as(u64, 2), snap.config_rev);
}
