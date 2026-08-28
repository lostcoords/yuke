//! The messages projection. A committed message writes one event (the full body in the payload) and
//! one metadata row, and advances the session summary. Replay rebuilds this from the log.

const std = @import("std");
const wire = @import("wire");
const sql = @import("sql");
const Database = @import("database.zig").Database;
const event = @import("event.zig");

/// The metadata that a committed message adds for its role.
const Meta = struct {
    message_id: u64,
    role: []const u8,
    run_id: ?u64,
    config_rev: ?u64,
    model: ?[]const u8,
    protocol: ?[]const u8,
    finish: ?[]const u8,
    tokens_input: ?u64,
    tokens_output: ?u64,
    tokens_reasoning: ?u64,
    tokens_cache_read: ?u64,
    tokens_cache_write: ?u64,
    cost: ?f64,
    created_at_ms: u64,
    // Add the session usage totals. Use zero when the message carries no tokens.
    add_input: u64,
    add_output: u64,
    add_reasoning: u64,
    add_cache_read: u64,
    add_cache_write: u64,
};

/// Append a committed message, store its body and metadata, and advance the session summary.
/// Run inside a write transaction. The caller mints event_id.
pub fn appendCommittedMessage(
    db: *Database,
    arena: std.mem.Allocator,
    session_id: [16]u8,
    event_id: [16]u8,
    committed_at_ms: u64,
    message: wire.message.Message,
) !u64 {
    std.debug.assert(sql.inTransaction(db.conn)); // The event and projection must commit together.
    const payload = try std.json.Stringify.valueAlloc(arena, message, .{ .emit_null_optional_fields = false });
    const seq = try event.append(db, arena, session_id, event_id, committed_at_ms, "message.committed", payload);

    const m = metaOf(message);
    try db.queries.insert_message.exec(.{
        .session_id = session_id,
        .message_id = m.message_id,
        .seq = seq,
        .role = m.role,
        .run_id = m.run_id,
        .config_rev = m.config_rev,
        .model = m.model,
        .protocol = m.protocol,
        .finish = m.finish,
        .tokens_input = m.tokens_input,
        .tokens_output = m.tokens_output,
        .tokens_reasoning = m.tokens_reasoning,
        .tokens_cache_read = m.tokens_cache_read,
        .tokens_cache_write = m.tokens_cache_write,
        .cost = m.cost,
        .created_at_ms = m.created_at_ms,
    });
    _ = try db.queries.advance_message.one(arena, .{
        .id = session_id,
        .message_id = m.message_id,
        .seq = seq,
        .add_input = m.add_input,
        .add_output = m.add_output,
        .add_reasoning = m.add_reasoning,
        .add_cache_read = m.add_cache_read,
        .add_cache_write = m.add_cache_write,
        .updated_at_ms = committed_at_ms,
    });
    return seq;
}

/// Extract the projection metadata from one message. Only an assistant turn carries tokens.
fn metaOf(message: wire.message.Message) Meta {
    return switch (message) {
        .user => |u| .{
            .message_id = u.id,
            .role = "user",
            .run_id = null,
            .config_rev = null,
            .model = null,
            .protocol = null,
            .finish = null,
            .tokens_input = null,
            .tokens_output = null,
            .tokens_reasoning = null,
            .tokens_cache_read = null,
            .tokens_cache_write = null,
            .cost = null,
            .created_at_ms = u.time.created_at_ms,
            .add_input = 0,
            .add_output = 0,
            .add_reasoning = 0,
            .add_cache_read = 0,
            .add_cache_write = 0,
        },
        .assistant => |a| .{
            .message_id = a.id,
            .role = "assistant",
            .run_id = a.run_id,
            .config_rev = a.config_rev,
            .model = if (a.provenance) |p| p.model else null,
            .protocol = if (a.provenance) |p| @tagName(p.protocol) else null,
            .finish = if (a.finish) |f| @tagName(f) else null,
            .tokens_input = if (a.tokens) |t| t.input else null,
            .tokens_output = if (a.tokens) |t| t.output else null,
            .tokens_reasoning = if (a.tokens) |t| t.reasoning else null,
            .tokens_cache_read = if (a.tokens) |t| t.cache_read else null,
            .tokens_cache_write = if (a.tokens) |t| t.cache_write else null,
            .cost = a.cost,
            .created_at_ms = a.time.created_at_ms,
            .add_input = if (a.tokens) |t| t.input else 0,
            .add_output = if (a.tokens) |t| t.output else 0,
            .add_reasoning = if (a.tokens) |t| t.reasoning else 0,
            .add_cache_read = if (a.tokens) |t| t.cache_read else 0,
            .add_cache_write = if (a.tokens) |t| t.cache_write else 0,
        },
        .compaction => |c| .{
            .message_id = c.id,
            .role = "compaction",
            .run_id = c.run_id,
            .config_rev = null,
            .model = null,
            .protocol = null,
            .finish = null,
            .tokens_input = null,
            .tokens_output = null,
            .tokens_reasoning = null,
            .tokens_cache_read = null,
            .tokens_cache_write = null,
            .cost = null,
            .created_at_ms = c.time.created_at_ms,
            .add_input = 0,
            .add_output = 0,
            .add_reasoning = 0,
            .add_cache_read = 0,
            .add_cache_write = 0,
        },
    };
}

/// Return one oldest-first page of committed messages and whether older messages remain.
pub const History = struct { messages: []const wire.message.Message, has_more: bool };

/// Return the message id shared by every message arm.
fn messageId(message: wire.message.Message) u64 {
    return switch (message) {
        inline else => |m| m.id,
    };
}

/// Read a backward page from the log and return it oldest first. before_message_id is exclusive;
/// 0 means the newest page. The result borrows `arena`.
pub fn historyPage(db: *Database, arena: std.mem.Allocator, session_id: [16]u8, before_message_id: u64, limit: usize) !History {
    std.debug.assert(limit > 0); // The caller clamps the peer limit to at least 1.
    // A cursor of 0 means "no cursor". The sentinel exceeds every message id.
    const cursor: u64 = if (before_message_id == 0) std.math.maxInt(i64) else before_message_id;
    var it = try db.queries.message_page.rows(.{
        .session_id = session_id,
        .cursor_message_id = cursor,
        .limit = @as(i64, @intCast(limit + 1)), // The extra row detects a further page.
    });
    defer it.deinit();

    // The query returns newest first. Collect the rows, then reverse them to oldest first.
    var newest_first: std.ArrayList(wire.message.Message) = .empty;
    while (try it.next(arena)) |row| {
        const msg = try std.json.parseFromSliceLeaky(wire.message.Message, arena, row.value.payload, .{ .ignore_unknown_fields = true });
        if (messageId(msg) != row.value.message_id) return error.CorruptLog; // The row and body disagree.
        try newest_first.append(arena, msg);
    }

    const has_more = newest_first.items.len > limit;
    const kept = newest_first.items[0..@min(newest_first.items.len, limit)];
    const out = try arena.alloc(wire.message.Message, kept.len);
    for (kept, 0..) |msg, i| out[out.len - 1 - i] = msg;
    return .{ .messages = out, .has_more = has_more };
}

const testing = std.testing;
const workspace = @import("workspace.zig");
const session = @import("session.zig");

fn seedSession(db: *Database, a: std.mem.Allocator, id: [16]u8) !void {
    const ws = try workspace.resolve(db, a, [_]u8{7} ** 16, "/w", "w", "/w");
    try session.create(db, .{
        .id = id,
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
}

fn scalar(db: *Database, query: []const u8) !i64 {
    const row = (try db.conn.row(query, .{})) orelse return error.NoRow;
    defer row.deinit();
    return row.int(0);
}

test "a committed user then assistant message advances the summary" {
    var db = try Database.openTest();
    defer db.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const sid = [_]u8{3} ** 16;
    try seedSession(&db, a, sid);

    const user: wire.message.Message = .{ .user = .{
        .id = 1,
        .content = &.{},
        .input_id = 1,
        .time = .{ .created_at_ms = 150 },
    } };
    const assistant: wire.message.Message = .{ .assistant = .{
        .id = 2,
        .run_id = 1,
        .config_rev = 0,
        .agent = "claude",
        .content = &.{},
        .finish = .stop,
        .tokens = .{ .input = 10, .output = 20, .reasoning = 5, .cache_read = 3, .cache_write = 2 },
        .time = .{ .created_at_ms = 160 },
        .provenance = .{ .protocol = .@"anthropic-messages", .model = "claude-opus-4-8" },
    } };

    try db.conn.execNoArgs("BEGIN IMMEDIATE");
    try testing.expectEqual(@as(u64, 1), try appendCommittedMessage(&db, a, sid, [_]u8{1} ** 16, 150, user));
    try testing.expectEqual(@as(u64, 2), try appendCommittedMessage(&db, a, sid, [_]u8{2} ** 16, 160, assistant));
    try db.conn.execNoArgs("COMMIT");

    try testing.expectEqual(@as(i64, 2), try scalar(&db, "SELECT count(*) FROM messages"));
    try testing.expectEqual(@as(i64, 1), try scalar(&db, "SELECT count(*) FROM messages WHERE role = 'assistant'"));

    const snap = (try session.snapshot(&db, a, sid)).?;
    try testing.expectEqual(@as(u64, 2), snap.message_count);
    try testing.expectEqual(@as(u64, 10), snap.usage_input_total);
    try testing.expectEqual(@as(u64, 20), snap.usage_output_total);
    try testing.expectEqual(@as(u64, 5), snap.usage_reasoning_total);

    // The id mark and projection seq track the last committed message.
    try testing.expectEqual(@as(i64, 2), try scalar(&db, "SELECT message_id_high FROM sessions"));
    try testing.expectEqual(@as(i64, 2), try scalar(&db, "SELECT projection_seq FROM sessions"));
}

test "a later commit with an earlier timestamp does not regress recency" {
    var db = try Database.openTest();
    defer db.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const sid = [_]u8{3} ** 16;
    try seedSession(&db, a, sid);

    const first: wire.message.Message = .{ .user = .{ .id = 1, .content = &.{}, .input_id = 1, .time = .{ .created_at_ms = 200 } } };
    const second: wire.message.Message = .{ .user = .{ .id = 2, .content = &.{}, .input_id = 2, .time = .{ .created_at_ms = 150 } } };

    try db.conn.execNoArgs("BEGIN IMMEDIATE");
    _ = try appendCommittedMessage(&db, a, sid, [_]u8{1} ** 16, 200, first);
    _ = try appendCommittedMessage(&db, a, sid, [_]u8{2} ** 16, 150, second);
    try db.conn.execNoArgs("COMMIT");

    // MAX keeps the newest timestamp, so the session never moves backward in session.list.
    try testing.expectEqual(@as(i64, 200), try scalar(&db, "SELECT updated_at_ms FROM sessions"));
}

test "a rolled-back commit leaves no event, row, or seq advance" {
    var db = try Database.openTest();
    defer db.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const sid = [_]u8{3} ** 16;
    try seedSession(&db, a, sid);
    const msg: wire.message.Message = .{ .user = .{ .id = 1, .content = &.{}, .input_id = 1, .time = .{ .created_at_ms = 100 } } };

    try db.conn.execNoArgs("BEGIN IMMEDIATE");
    _ = try appendCommittedMessage(&db, a, sid, [_]u8{1} ** 16, 100, msg);
    // InsertMessage rejects a duplicate message_id after event.append raises the seq.
    try testing.expectError(error.ConstraintUnique, appendCommittedMessage(&db, a, sid, [_]u8{2} ** 16, 100, msg));
    try db.conn.execNoArgs("ROLLBACK");

    try testing.expectEqual(@as(i64, 0), try scalar(&db, "SELECT count(*) FROM events"));
    try testing.expectEqual(@as(i64, 0), try scalar(&db, "SELECT count(*) FROM messages"));
    try testing.expectEqual(@as(i64, 0), try scalar(&db, "SELECT seq_high FROM sessions"));
}

test "historyPage returns a page oldest-first with has_more" {
    var db = try Database.openTest();
    defer db.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const sid = [_]u8{3} ** 16;
    try seedSession(&db, a, sid);

    try db.conn.execNoArgs("BEGIN IMMEDIATE");
    for (1..4) |i| {
        const n: u8 = @intCast(i);
        const m: wire.message.Message = .{ .user = .{ .id = i, .content = &.{}, .input_id = i, .time = .{ .created_at_ms = 100 + i } } };
        _ = try appendCommittedMessage(&db, a, sid, [_]u8{n} ** 16, 100 + i, m);
    }
    try db.conn.execNoArgs("COMMIT");

    // The newest page of 2 returns ids 2 and 3 oldest first; id 1 remains.
    const page = try historyPage(&db, a, sid, 0, 2);
    try testing.expectEqual(@as(usize, 2), page.messages.len);
    try testing.expectEqual(@as(u64, 2), page.messages[0].user.id);
    try testing.expectEqual(@as(u64, 3), page.messages[1].user.id);
    try testing.expect(page.has_more);

    // Before id 2 returns only id 1, with no older row.
    const older = try historyPage(&db, a, sid, 2, 2);
    try testing.expectEqual(@as(usize, 1), older.messages.len);
    try testing.expectEqual(@as(u64, 1), older.messages[0].user.id);
    try testing.expect(!older.has_more);
}

test "appendCommittedMessage rejects a missing session" {
    var db = try Database.openTest();
    defer db.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const user: wire.message.Message = .{ .user = .{ .id = 1, .content = &.{}, .input_id = 1, .time = .{ .created_at_ms = 1 } } };
    try db.conn.execNoArgs("BEGIN IMMEDIATE");
    defer db.conn.execNoArgs("ROLLBACK") catch {};
    // An absent session fails the seq allocation before any row is written.
    try testing.expectError(error.NoRow, appendCommittedMessage(&db, a, [_]u8{9} ** 16, [_]u8{1} ** 16, 1, user));
}
