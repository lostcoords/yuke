//! The messages projection writes one event with the full body, one metadata row, and one session summary update for each committed message; replay rebuilds it from the log.

const std = @import("std");
const proto = @import("proto");
const sql = @import("sql");
const Database = @import("store.zig").Database;
const event = @import("event.zig");
const blob = @import("blob.zig");
const queries_gen = @import("queries_gen.zig");
const token_estimate = @import("../session/tokens.zig");

/// The metadata that a committed message adds for its role.
const Meta = struct {
    message_id: u64,
    role: []const u8,
    run_id: ?u64 = null,
    config_rev: ?u64 = null,
    model: ?[]const u8 = null,
    protocol: ?[]const u8 = null,
    finish: ?[]const u8 = null,
    tokens_input: ?u64 = null,
    tokens_output: ?u64 = null,
    tokens_reasoning: ?u64 = null,
    tokens_cache_read: ?u64 = null,
    tokens_cache_write: ?u64 = null,
    cost: ?f64 = null,
    cost_without_cache: ?f64 = null,
    created_at_ms: u64,
};

/// Append a committed message, store its body and metadata, and advance the session summary inside a write transaction; the caller mints event_id.
pub fn appendCommittedMessage(
    db: *Database,
    arena: std.mem.Allocator,
    session_id: [16]u8,
    event_id: [16]u8,
    committed_at_ms: u64,
    message: proto.message.Message,
) !proto.message.MessageCommittedData {
    std.debug.assert(sql.inTransaction(db.conn)); // The event and projection must commit together.
    const payload = try std.json.Stringify.valueAlloc(arena, message, .{ .emit_null_optional_fields = false });
    const seq = try event.append(db, arena, session_id, event_id, committed_at_ms, "message.committed", payload);
    switch (message) {
        .user => |u| try blob.recordRefs(db, session_id, u.content),
        // A tool part names the blobs its result carries, so a removal elsewhere keeps them.
        .assistant => |a| for (a.content) |part| if (part == .tool) try blob.recordBlobRefs(db, session_id, part.tool.state.media()),
        .compaction => {},
    }

    const m = metaOf(message);
    // The context count reads this estimate, so it reads no body.
    const estimate = token_estimate.ofMessage(message);
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
        .tokens_estimate = estimate.tokens,
        .reasoning_estimate = estimate.reasoning,
        .first_kept_id = if (message == .compaction) message.compaction.first_kept_id else null,
    });
    _ = try db.queries.advance_message.one(arena, .{
        .id = session_id,
        .message_id = m.message_id,
        .seq = seq,
        .tokens_input = m.tokens_input,
        .tokens_output = m.tokens_output,
        .tokens_reasoning = m.tokens_reasoning,
        .tokens_cache_read = m.tokens_cache_read,
        .tokens_cache_write = m.tokens_cache_write,
        .cost = m.cost,
        .cost_without_cache = m.cost_without_cache,
        .updated_at_ms = committed_at_ms,
    });
    // The event borrows the input message.
    return .{ .session_id = .bytes(session_id), .seq = seq, .message = message };
}

/// Extract the projection metadata from one message. Only an assistant turn carries tokens.
fn metaOf(message: proto.message.Message) Meta {
    return switch (message) {
        .user => |u| .{
            .message_id = u.id,
            .role = "user",
            .created_at_ms = u.time.created_at_ms,
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
            .cost = if (a.cost) |c| c.total else null,
            .created_at_ms = a.time.created_at_ms,
            .cost_without_cache = if (a.cost) |c| c.without_cache else null,
        },
        .compaction => |c| .{
            .message_id = c.id,
            .role = "compaction",
            .run_id = c.run_id,
            .created_at_ms = c.time.created_at_ms,
        },
    };
}

/// Return one oldest-first page of committed messages and whether older messages remain.
pub const History = struct { messages: []const proto.message.Message, has_more: bool };

/// The messages one session loads, oldest-first: every message the model reads, and the newest view window. The caller gives `next` the allocator for one row.
pub const Resident = struct {
    rows: queries_gen.MessageResident.Rows,

    /// Parse the next row into `scratch`. It fails with `CorruptLog` when the row id and the body id differ.
    pub fn next(self: *Resident, scratch: std.mem.Allocator) !?proto.message.Message {
        const row = (try self.rows.next(scratch)) orelse return null;
        const msg = try std.json.parseFromSliceLeaky(proto.message.Message, scratch, row.value.payload, .{});
        if (msg.id() != row.value.message_id) return error.CorruptLog; // The row and body disagree.
        return msg;
    }

    /// Finish the statement.
    pub fn deinit(self: *Resident) void {
        self.rows.deinit();
    }
};

/// Open every message from the first kept id of the newest checkpoint, or from the first message without one, and the newest `window` messages. The caller must `deinit` the result.
pub fn resident(db: *Database, session_id: [16]u8, window: usize) !Resident {
    std.debug.assert(window > 0);
    return .{ .rows = try db.queries.message_resident.rows(.{ .session_id = session_id, .window = @as(i64, @intCast(window)) }) };
}

/// Read a backward page from the log and return it oldest first; before_message_id is exclusive, 0 means the newest page, and the result borrows `arena`.
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
        const msg = try std.json.parseFromSliceLeaky(proto.message.Message, arena, row.value.payload, .{});
        if (msg.id() != row.value.message_id) return error.CorruptLog; // The row and body disagree.
        try newest_first.append(arena, msg);
    }

    const has_more = newest_first.items.len > limit;
    const kept = newest_first.items[0..@min(newest_first.items.len, limit)];
    std.mem.reverse(proto.message.Message, kept);
    return .{ .messages = kept, .has_more = has_more };
}

const testing = std.testing;
const zqlite = @import("zqlite");
const session = @import("session.zig");
const session_mod = @import("../session/session.zig");

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
        .content = &.{.{ .text = .{ .text = "世界 \"quoted\"\n" } }},
        .input_id = 1,
        .time = .{ .created_at_ms = 150 },
    } };
    const assistant: proto.message.Message = .{ .assistant = .{
        .id = 2,
        .run_id = 1,
        .config_rev = 0,
        .content = &.{},
        .finish = .stop,
        .tokens = .{ .input = 10, .output = 20, .reasoning = 5, .cache_read = 3, .cache_write = 2 },
        .time = .{ .created_at_ms = 160 },
        .provenance = .{ .protocol = .anthropic_messages, .model = "claude-opus-4-8" },
    } };

    try db.conn.execNoArgs("BEGIN IMMEDIATE");
    const user_commit = try appendCommittedMessage(&db, a, sid, [_]u8{1} ** 16, 150, user);
    const assistant_commit = try appendCommittedMessage(&db, a, sid, [_]u8{2} ** 16, 160, assistant);
    try testing.expectEqual(@as(u64, 1), user_commit.seq);
    try testing.expectEqual(@as(u64, 2), assistant_commit.seq);
    try db.conn.execNoArgs("COMMIT");

    try testing.expectEqual(@as(i64, 2), try scalar(&db, "SELECT count(*) FROM messages"));
    try testing.expectEqual(@as(i64, 1), try scalar(&db, "SELECT count(*) FROM messages WHERE role = 'assistant'"));

    var folded = session_mod.Session.init(testing.allocator, .bytes(sid));
    defer folded.deinit();
    for ([_]proto.message.MessageCommittedData{ user_commit, assistant_commit }) |item| _ = try folded.commit(item);
    try testing.expectEqual(@as(usize, 2), folded.history.list.items.len);
    try testing.expectEqual(assistant_commit.message.id(), folded.finalized_message_id);

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
        .content = &.{},
        .finish = .stop,
        .tokens = tokens,
        .time = .{ .created_at_ms = created_at_ms },
        .provenance = .{ .protocol = .anthropic_messages, .model = "claude-opus-4-8" },
    } };
}

test "each committed turn updates the session usage" {
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

    // The last usage reads the newest round alone, never the sum.
    try testing.expectEqual(@as(u64, 300), snap.usage_last_input);
    try testing.expectEqual(@as(u64, 50), snap.usage_last_output);
    try testing.expectEqual(@as(u64, 150), snap.usage_last_cache_read);
}

test "a committed turn adds its known cost, and a turn with tokens and no cost is unpriced" {
    var db = try Database.openTest();
    defer db.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const sid = [_]u8{12} ** 16;
    try session.seedSession(&db, sid);

    const usage: proto.message.TokenUsage = .{ .input = 10, .output = 1, .reasoning = 0, .cache_read = 0, .cache_write = 0 };
    var priced = assistantTurn(1, 400, usage);
    priced.assistant.cost = .{ .total = 0.25, .without_cache = 0.5 };
    try db.conn.execNoArgs("BEGIN IMMEDIATE");
    _ = try appendCommittedMessage(&db, a, sid, [_]u8{1} ** 16, 400, priced);
    _ = try appendCommittedMessage(&db, a, sid, [_]u8{2} ** 16, 410, assistantTurn(2, 410, usage));
    // A round that reported no tokens has no cost to know, so it is not unpriced.
    _ = try appendCommittedMessage(&db, a, sid, [_]u8{3} ** 16, 420, assistantTurn(3, 420, null));
    try db.conn.execNoArgs("COMMIT");

    const snap = (try session.snapshot(&db, a, sid)).?;
    try testing.expectEqual(@as(f64, 0.25), snap.cost_total);
    try testing.expectEqual(@as(f64, 0.5), snap.cost_without_cache_total);
    try testing.expectEqual(@as(u64, 1), snap.unpriced_count);
}

test "the last usage skips a turn that reported no usage" {
    var db = try Database.openTest();
    defer db.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const sid = [_]u8{11} ** 16;
    try session.seedSession(&db, sid);

    // A session with no assistant turn reports zero.
    try testing.expectEqual(@as(u64, 0), (try session.snapshot(&db, a, sid)).?.usage_last_input);

    const with_usage: proto.message.TokenUsage = .{ .input = 70, .output = 8, .reasoning = 0, .cache_read = 25, .cache_write = 5 };
    try db.conn.execNoArgs("BEGIN IMMEDIATE");
    _ = try appendCommittedMessage(&db, a, sid, [_]u8{1} ** 16, 300, assistantTurn(1, 300, with_usage));
    // A canceled round commits with no tokens. It must not blank the last usage.
    _ = try appendCommittedMessage(&db, a, sid, [_]u8{2} ** 16, 310, assistantTurn(2, 310, null));
    // A later user turn must not blank it either.
    _ = try appendCommittedMessage(&db, a, sid, [_]u8{3} ** 16, 320, .{ .user = .{ .id = 3, .content = &.{}, .input_id = 1, .time = .{ .created_at_ms = 320 } } });
    try db.conn.execNoArgs("COMMIT");

    const snap = (try session.snapshot(&db, a, sid)).?;
    try testing.expectEqual(@as(u64, 70), snap.usage_last_input);
    try testing.expectEqual(@as(u64, 8), snap.usage_last_output);
    try testing.expectEqual(@as(u64, 25), snap.usage_last_cache_read);
    try testing.expectEqual(@as(u64, 5), snap.usage_last_cache_write);

    // The usage-free turn still counts as a message and adds nothing to the totals.
    try testing.expectEqual(@as(u64, 3), snap.message_count);
    try testing.expectEqual(@as(u64, 70), snap.usage_input_total);
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

test "a load reads the model range and the newest window" {
    var db = try Database.openTest();
    defer db.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const sid = [_]u8{4} ** 16;
    try session.seedSession(&db, sid);
    try db.conn.execNoArgs("BEGIN IMMEDIATE");
    for (1..5) |i| {
        const n: u8 = @intCast(i);
        const m: proto.message.Message = .{ .user = .{ .id = i, .content = &.{}, .input_id = i, .time = .{ .created_at_ms = 100 + i } } };
        _ = try appendCommittedMessage(&db, a, sid, [_]u8{n} ** 16, 100 + i, m);
    }
    try db.conn.execNoArgs("COMMIT");

    const Load = struct {
        fn ids(store: *Database, arena_: std.mem.Allocator, id: [16]u8, window: usize) ![]const u64 {
            var it = try resident(store, id, window);
            defer it.deinit();
            var seen: std.ArrayList(u64) = .empty;
            while (try it.next(arena_)) |m| try seen.append(arena_, m.id());
            return seen.items;
        }
    };
    // Without a checkpoint the model reads every message, so the window adds nothing.
    try testing.expectEqualSlices(u64, &.{ 1, 2, 3, 4 }, try Load.ids(&db, a, sid, 2));
    try db.conn.execNoArgs("BEGIN IMMEDIATE");
    _ = try appendCommittedMessage(&db, a, sid, [_]u8{5} ** 16, 105, .{ .compaction = .{ .id = 5, .run_id = 1, .reason = .manual, .summary = "s", .first_kept_id = 3, .tokens_before = 2, .tokens_after = 1, .time = .{ .created_at_ms = 105 } } });
    try db.conn.execNoArgs("COMMIT");
    // The model range reaches below the window in the first load, and the window reaches below it in the second.
    try testing.expectEqualSlices(u64, &.{ 3, 4, 5 }, try Load.ids(&db, a, sid, 1));
    try testing.expectEqualSlices(u64, &.{ 2, 3, 4, 5 }, try Load.ids(&db, a, sid, 4));
    // The row id is valid, but its payload names another message.
    try db.conn.exec("UPDATE events SET payload = json_set(payload, '$.id', 99) WHERE session_id = ? AND seq = 3", .{zqlite.blob(&sid)});
    var corrupt = try resident(&db, sid, 1);
    defer corrupt.deinit();
    while (corrupt.next(a)) |m| {
        if (m == null) return error.TestExpectedError;
    } else |err| try testing.expectEqual(error.CorruptLog, err);
}
