//! The messages projection. A committed message writes one event (the full body in the payload) and
//! one metadata row, and advances the session summary. Replay rebuilds this from the log.

const std = @import("std");
const proto = @import("proto");
const sql = @import("sql");
const Database = @import("store.zig").Database;
const event = @import("event.zig");
const blob = @import("blob.zig");
const queries_gen = @import("queries_gen.zig");
const transcript = @import("../session/transcript.zig");

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
    message: proto.message.Message,
) !u64 {
    std.debug.assert(sql.inTransaction(db.conn)); // The event and projection must commit together.
    const payload = try std.json.Stringify.valueAlloc(arena, message, .{ .emit_null_optional_fields = false });
    const seq = try event.append(db, arena, session_id, event_id, committed_at_ms, "message.committed", payload);
    if (message == .user) try blob.recordRefs(db, session_id, message.user.content);

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
fn metaOf(message: proto.message.Message) Meta {
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
pub const History = struct { messages: []const proto.message.Message, has_more: bool };

/// Return the message id shared by every message arm.
fn messageId(message: proto.message.Message) u64 {
    return switch (message) {
        inline else => |m| m.id,
    };
}

/// The newest messages of one session, oldest-first. The caller gives `next` the allocator for one row.
pub const Tail = struct {
    rows: queries_gen.MessageTail.Rows,

    /// One message beside its stored size, which is the same serialization the transcript measures.
    pub fn next(self: *Tail, scratch: std.mem.Allocator) !?transcript.Sized {
        const row = (try self.rows.next(scratch)) orelse return null;
        const msg = try std.json.parseFromSliceLeaky(proto.message.Message, scratch, row.value.payload, .{ .ignore_unknown_fields = true });
        if (messageId(msg) != row.value.message_id) return error.CorruptLog; // The row and body disagree.
        return .{ .message = msg, .bytes = row.value.payload.len };
    }

    pub fn deinit(self: *Tail) void {
        self.rows.deinit();
    }
};

/// Open the newest `limit` committed messages oldest-first. The caller must `deinit` the tail.
pub fn tail(db: *Database, session_id: [16]u8, limit: usize) !Tail {
    std.debug.assert(limit > 0);
    return .{ .rows = try db.queries.message_tail.rows(.{ .session_id = session_id, .limit = @as(i64, @intCast(limit)) }) };
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
    var newest_first: std.ArrayList(proto.message.Message) = .empty;
    while (try it.next(arena)) |row| {
        const msg = try std.json.parseFromSliceLeaky(proto.message.Message, arena, row.value.payload, .{ .ignore_unknown_fields = true });
        if (messageId(msg) != row.value.message_id) return error.CorruptLog; // The row and body disagree.
        try newest_first.append(arena, msg);
    }

    const has_more = newest_first.items.len > limit;
    const kept = newest_first.items[0..@min(newest_first.items.len, limit)];
    const out = try arena.alloc(proto.message.Message, kept.len);
    for (kept, 0..) |msg, i| out[out.len - 1 - i] = msg;
    return .{ .messages = out, .has_more = has_more };
}

/// The token usage of the newest committed assistant turn. This is the live context gauge, not a
/// lifetime total. A session with no such turn reports zero.
pub fn contextUsage(db: *Database, arena: std.mem.Allocator, session_id: [16]u8) !proto.message.TokenUsage {
    const row = (try db.queries.last_assistant_usage.maybeOne(arena, .{ .session_id = session_id })) orelse return .{
        .input = 0,
        .output = 0,
        .reasoning = 0,
        .cache_read = 0,
        .cache_write = 0,
    };
    std.debug.assert(row.value.tokens_input != null); // The query keeps a null-usage turn out.
    return .{
        .input = row.value.tokens_input orelse 0,
        .output = row.value.tokens_output orelse 0,
        .reasoning = row.value.tokens_reasoning orelse 0,
        .cache_read = row.value.tokens_cache_read orelse 0,
        .cache_write = row.value.tokens_cache_write orelse 0,
    };
}

const testing = std.testing;
const session = @import("session.zig");

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
    try session.seedSession(&db, sid);

    const user: proto.message.Message = .{ .user = .{
        .id = 1,
        .content = &.{},
        .input_id = 1,
        .time = .{ .created_at_ms = 150 },
    } };
    const assistant: proto.message.Message = .{ .assistant = .{
        .id = 2,
        .run_id = 1,
        .config_rev = 0,
        .agent = "claude",
        .content = &.{},
        .finish = .stop,
        .tokens = .{ .input = 10, .output = 20, .reasoning = 5, .cache_read = 3, .cache_write = 2 },
        .time = .{ .created_at_ms = 160 },
        .provenance = .{ .protocol = .anthropic_messages, .model = "claude-opus-4-8" },
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

    // All five counters fold, and the cache subsets ride inside the input total.
    try testing.expectEqual(@as(u64, 3), snap.usage_cache_read_total);
    try testing.expectEqual(@as(u64, 2), snap.usage_cache_write_total);

    // The id mark and projection seq track the last committed message.
    try testing.expectEqual(@as(i64, 2), try scalar(&db, "SELECT message_id_high FROM sessions"));
    try testing.expectEqual(@as(i64, 2), try scalar(&db, "SELECT projection_seq FROM sessions"));
}

/// Build one committed assistant turn for a usage test.
fn assistantTurn(id: u64, created_at_ms: u64, tokens: ?proto.message.TokenUsage) proto.message.Message {
    return .{ .assistant = .{
        .id = id,
        .run_id = 1,
        .config_rev = 0,
        .agent = "claude",
        .content = &.{},
        .finish = .stop,
        .tokens = tokens,
        .time = .{ .created_at_ms = created_at_ms },
        .provenance = .{ .protocol = .anthropic_messages, .model = "claude-opus-4-8" },
    } };
}

test "each committed turn adds its usage one time and the gauge names the newest" {
    var db = try Database.openTest();
    defer db.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const sid = [_]u8{9} ** 16;
    try session.seedSession(&db, sid);

    // Three rounds of one turn. Each round commits its own assistant message.
    const rounds = [_]proto.message.TokenUsage{
        .{ .input = 100, .output = 10, .reasoning = 0, .cache_read = 40, .cache_write = 20 },
        .{ .input = 220, .output = 30, .reasoning = 7, .cache_read = 90, .cache_write = 0 },
        .{ .input = 300, .output = 50, .reasoning = 0, .cache_read = 150, .cache_write = 0 },
    };
    try db.conn.execNoArgs("BEGIN IMMEDIATE");
    for (rounds, 0..) |usage, i| {
        const n: u64 = @intCast(i + 1);
        _ = try appendCommittedMessage(&db, a, sid, @splat(@intCast(n)), 200 + n, assistantTurn(n, 200 + n, usage));
    }
    try db.conn.execNoArgs("COMMIT");

    const snap = (try session.snapshot(&db, a, sid)).?;
    try testing.expectEqual(@as(u64, 620), snap.usage_input_total);
    try testing.expectEqual(@as(u64, 90), snap.usage_output_total);
    try testing.expectEqual(@as(u64, 7), snap.usage_reasoning_total);
    try testing.expectEqual(@as(u64, 280), snap.usage_cache_read_total);
    try testing.expectEqual(@as(u64, 20), snap.usage_cache_write_total);
    try testing.expectEqual(@as(u64, 3), snap.message_count);

    // The context gauge reads the newest round alone, never the sum.
    const context = try contextUsage(&db, a, sid);
    try testing.expectEqual(@as(u64, 300), context.input);
    try testing.expectEqual(@as(u64, 50), context.output);
    try testing.expectEqual(@as(u64, 150), context.cache_read);
}

test "the context gauge skips a turn that reported no usage" {
    var db = try Database.openTest();
    defer db.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const sid = [_]u8{11} ** 16;
    try session.seedSession(&db, sid);

    // A session with no assistant turn reports zero rather than an error.
    const empty = try contextUsage(&db, a, sid);
    try testing.expectEqual(@as(u64, 0), empty.input);

    const with_usage: proto.message.TokenUsage = .{ .input = 70, .output = 8, .reasoning = 0, .cache_read = 25, .cache_write = 5 };
    try db.conn.execNoArgs("BEGIN IMMEDIATE");
    _ = try appendCommittedMessage(&db, a, sid, [_]u8{1} ** 16, 300, assistantTurn(1, 300, with_usage));
    // A canceled round commits with no tokens. It must not blank the gauge.
    _ = try appendCommittedMessage(&db, a, sid, [_]u8{2} ** 16, 310, assistantTurn(2, 310, null));
    // A later user turn must not blank it either.
    _ = try appendCommittedMessage(&db, a, sid, [_]u8{3} ** 16, 320, .{ .user = .{ .id = 3, .content = &.{}, .input_id = 1, .time = .{ .created_at_ms = 320 } } });
    try db.conn.execNoArgs("COMMIT");

    const context = try contextUsage(&db, a, sid);
    try testing.expectEqual(@as(u64, 70), context.input);
    try testing.expectEqual(@as(u64, 8), context.output);
    try testing.expectEqual(@as(u64, 25), context.cache_read);
    try testing.expectEqual(@as(u64, 5), context.cache_write);

    // The usage-free turn still counts as a message and adds nothing to the totals.
    const snap = (try session.snapshot(&db, a, sid)).?;
    try testing.expectEqual(@as(u64, 3), snap.message_count);
    try testing.expectEqual(@as(u64, 70), snap.usage_input_total);
    try testing.expectEqual(@as(u64, 70), snap.ctx_tokens_input.?); // The view agrees with the query.
}

test "a later commit with an earlier timestamp does not regress recency" {
    var db = try Database.openTest();
    defer db.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const sid = [_]u8{3} ** 16;
    try session.seedSession(&db, sid);

    const first: proto.message.Message = .{ .user = .{ .id = 1, .content = &.{}, .input_id = 1, .time = .{ .created_at_ms = 200 } } };
    const second: proto.message.Message = .{ .user = .{ .id = 2, .content = &.{}, .input_id = 2, .time = .{ .created_at_ms = 150 } } };

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
    try session.seedSession(&db, sid);
    const msg: proto.message.Message = .{ .user = .{ .id = 1, .content = &.{}, .input_id = 1, .time = .{ .created_at_ms = 100 } } };

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
    try session.seedSession(&db, sid);

    try db.conn.execNoArgs("BEGIN IMMEDIATE");
    for (1..4) |i| {
        const n: u8 = @intCast(i);
        const m: proto.message.Message = .{ .user = .{ .id = i, .content = &.{}, .input_id = i, .time = .{ .created_at_ms = 100 + i } } };
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

test "tail streams the newest messages oldest-first" {
    var db = try Database.openTest();
    defer db.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const sid = [_]u8{4} ** 16;
    try session.seedSession(&db, sid);
    try db.conn.execNoArgs("BEGIN IMMEDIATE");
    for (1..4) |i| {
        const n: u8 = @intCast(i);
        const m: proto.message.Message = .{ .user = .{ .id = i, .content = &.{}, .input_id = i, .time = .{ .created_at_ms = 100 + i } } };
        _ = try appendCommittedMessage(&db, a, sid, [_]u8{n} ** 16, 100 + i, m);
    }
    try db.conn.execNoArgs("COMMIT");

    // The newest two arrive as 2 then 3, each parsed into a scratch the caller resets between rows.
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    var it = try tail(&db, sid, 2);
    defer it.deinit();
    var seen: [4]u64 = undefined;
    var n: usize = 0;
    while (try it.next(scratch.allocator())) |m| : (n += 1) {
        seen[n] = messageId(m.message);
        _ = scratch.reset(.retain_capacity);
    }
    try testing.expectEqual(2, n);
    try testing.expectEqualSlices(u64, &.{ 2, 3 }, seen[0..n]);
}

test "appendCommittedMessage rejects a missing session" {
    var db = try Database.openTest();
    defer db.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const user: proto.message.Message = .{ .user = .{ .id = 1, .content = &.{}, .input_id = 1, .time = .{ .created_at_ms = 1 } } };
    try db.conn.execNoArgs("BEGIN IMMEDIATE");
    defer db.conn.execNoArgs("ROLLBACK") catch {};
    // An absent session fails the seq allocation before any row is written.
    try testing.expectError(error.NoRow, appendCommittedMessage(&db, a, [_]u8{9} ** 16, [_]u8{1} ** 16, 1, user));
}
