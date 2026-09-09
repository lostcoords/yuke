//! Select model history from committed storage without a dependency on the UI cache.

const std = @import("std");
const proto = @import("proto");
const database = @import("../store/store.zig");

pub const default_context_window: u64 = 128_000;
pub const default_max_output: u32 = 8192;

pub const Budget = struct {
    input_ceiling: u64,

    /// Reserve the final build-hook prompt, tools, output, and a framing margin.
    pub fn forRequest(window_limit: ?u64, output: u32, system: []const u8, tools: []const @import("ai").ir.Tool) !Budget {
        const window = window_limit orelse default_context_window;
        const fixed = tokensFor(system.len) + tokensFor(try jsonBytes(tools)) + 1024;
        if (output == 0 or output >= window or fixed >= window - output) return error.ContextTooLarge;
        const ceiling = window - output - fixed;
        return .{ .input_ceiling = ceiling };
    }
};

pub const Projection = struct {
    messages: []const proto.message.Message,
};

/// The newest compaction message. It leads the request and stands for every message it covers.
pub const Head = struct {
    message: proto.message.Message,
    id: u64,
    /// The first message the checkpoint kept. The request reads no message below it.
    from_id: u64,
};

pub fn readHead(arena: std.mem.Allocator, db: *database.Database, session_id: [16]u8) !?Head {
    const row = (try db.queries.newest_compaction.maybeOne(arena, .{ .session_id = session_id })) orelse return null;
    const message = try std.json.parseFromSliceLeaky(proto.message.Message, arena, row.value.payload, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    if (message != .compaction or message.compaction.id != row.value.message_id) return error.CorruptLog;
    return .{ .message = message, .id = row.value.message_id, .from_id = message.compaction.first_kept_id orelse 0 };
}

/// Charge the summary text and its provider wrapper once.
pub fn summaryTokens(summary: []const u8) u64 {
    return tokensFor(summary.len) + 128;
}

/// Estimate the complete checkpoint and tail without a body copy.
pub fn estimate(arena: std.mem.Allocator, db: *database.Database, session_id: [16]u8) !u64 {
    const head = try readHead(arena, db, session_id);
    var total: u64 = if (head) |h| summaryTokens(h.message.compaction.summary) else 0;
    var rows = try db.queries.context_sizes.rows(.{ .session_id = session_id, .first_message_id = if (head) |h| h.from_id else 0 });
    defer rows.deinit();
    while (try rows.next(arena)) |owned| {
        var row = owned;
        defer row.deinit();
        if (std.mem.eql(u8, row.value.role, "compaction")) continue;
        total += tokensFor(row.value.bytes);
    }
    return total;
}

/// Return the newest checkpoint and every retained message, or refuse the request.
pub fn project(arena: std.mem.Allocator, db: *database.Database, session_id: [16]u8, budget: Budget) !Projection {
    std.debug.assert(budget.input_ceiling > 0);
    if (try estimate(arena, db, session_id) > budget.input_ceiling) return error.ContextHistoryTooLarge;
    const head = try readHead(arena, db, session_id);
    var messages: std.ArrayList(proto.message.Message) = .empty;
    if (head) |h| try messages.append(arena, h.message);
    var rows = try db.queries.context_messages.rows(.{ .session_id = session_id, .first_message_id = if (head) |h| h.from_id else 0 });
    defer rows.deinit();
    while (try rows.next(arena)) |owned| {
        var row = owned;
        defer row.deinit();
        const msg = try std.json.parseFromSliceLeaky(proto.message.Message, arena, row.value.payload, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
        if (msg.id() != row.value.message_id) return error.CorruptLog;
        if (msg == .compaction) continue;
        try messages.append(arena, msg);
    }
    return .{ .messages = messages.items };
}

/// JSON byte counts are an estimate and do not replace a provider tokenizer.
pub fn tokensFor(bytes: u64) u64 {
    return bytes / 3 + @intFromBool(bytes % 3 != 0);
}

fn jsonBytes(value: anytype) !u64 {
    var buffer: [0]u8 = .{};
    var out = std.Io.Writer.Discarding.init(&buffer);
    try std.json.Stringify.value(value, .{ .emit_null_optional_fields = false }, &out.writer);
    return out.fullCount();
}

test "the budget charges the final prompt tools and output reserve" {
    const t = std.testing;
    const plain = try Budget.forRequest(20_000, 1000, "", &.{});
    const prompt = try Budget.forRequest(20_000, 1000, "x" ** 3000, &.{});
    try t.expectEqual(plain.input_ceiling - 1000, prompt.input_ceiling);
    const tool = try Budget.forRequest(20_000, 1000, "", &.{.{ .name = "read", .description = "x" ** 3000, .input_schema = "{}" }});
    try t.expect(tool.input_ceiling < prompt.input_ceiling);
    const output = try Budget.forRequest(20_000, 2000, "", &.{});
    try t.expectEqual(plain.input_ceiling - 1000, output.input_ceiling);
    try t.expectError(error.ContextTooLarge, Budget.forRequest(1000, 2000, "", &.{}));
    try t.expectError(error.ContextTooLarge, Budget.forRequest(2000, 1000, "", &.{}));
    try t.expectError(error.ContextTooLarge, Budget.forRequest(null, 0, "", &.{}));
}

test "model history survives cache eviction and an insufficient budget drops nothing" {
    const t = std.testing;
    var db = try database.Database.openTest();
    defer db.deinit();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sid = [_]u8{42} ** 16;
    try database.session.create(&db, .{ .id = sid, .root = "/w", .origin = "root", .profile = "default", .model = "test/model", .reasoning = "", .config_rev = 0, .title = "", .created_at_ms = 0, .updated_at_ms = 0 });
    var cache = @import("../session/transcript.zig").Transcript.init(t.allocator);
    defer cache.deinit();
    cache.max_messages = 2;
    {
        var tx = try db.begin();
        defer tx.deinit();
        for (1..10) |n| {
            const id: u64 = @intCast(n);
            const user = n % 2 == 1 and n != 9 or n == 8;
            const msg: proto.message.Message = if (user) .{ .user = .{ .id = id, .content = &.{.{ .text = .{ .text = "task" } }}, .input_id = id, .time = .{ .created_at_ms = id } } } else .{ .assistant = .{ .id = id, .run_id = 1, .config_rev = 0, .agent = "root", .content = &.{}, .time = .{ .created_at_ms = id } } };
            var event_id = sid;
            event_id[0] = @intCast(n);
            _ = try database.message.appendCommittedMessage(&db, a, sid, event_id, id, msg);
            try cache.append(msg);
        }
        try tx.commit();
    }
    try t.expectEqual(@as(u64, 8), cache.list.items[0].message.id());
    const wide = try project(a, &db, sid, .{ .input_ceiling = 40_000 });
    try t.expectEqual(@as(usize, 9), wide.messages.len);
    try t.expectEqual(@as(u64, 1), wide.messages[0].id());
    try t.expectEqual(@as(usize, 2), cache.list.items.len);
    try t.expectError(error.ContextHistoryTooLarge, project(a, &db, sid, .{ .input_ceiling = 100 }));
    const again = try project(a, &db, sid, .{ .input_ceiling = 40_000 });
    try t.expectEqual(@as(usize, 9), again.messages.len);
}

test "the newest checkpoint leads the request and an older one drops out" {
    const t = std.testing;
    var db = try database.Database.openTest();
    defer db.deinit();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sid = [_]u8{51} ** 16;
    try database.session.create(&db, .{ .id = sid, .root = "/w", .origin = "root", .profile = "default", .model = "test/model", .reasoning = "", .config_rev = 0, .title = "", .created_at_ms = 0, .updated_at_ms = 0 });

    // 1 and 2 are covered history, 3 is an old checkpoint, 4 is the tail, 5 is the newest checkpoint.
    const messages = [_]proto.message.Message{
        .{ .user = .{ .id = 1, .input_id = 1, .content = &.{.{ .text = .{ .text = "old" } }}, .time = .{ .created_at_ms = 1 } } },
        .{ .assistant = .{ .id = 2, .run_id = 1, .config_rev = 0, .agent = "root", .content = &.{}, .time = .{ .created_at_ms = 2 } } },
        .{ .compaction = .{ .id = 3, .run_id = 1, .reason = .manual, .summary = "first summary", .first_kept_id = 1, .tokens_before = 9, .tokens_after = 2, .time = .{ .created_at_ms = 3 } } },
        .{ .user = .{ .id = 4, .input_id = 2, .content = &.{.{ .text = .{ .text = "kept" } }}, .time = .{ .created_at_ms = 4 } } },
        .{ .compaction = .{ .id = 5, .run_id = 2, .reason = .auto, .summary = "second summary", .first_kept_id = 4, .tokens_before = 9, .tokens_after = 2, .time = .{ .created_at_ms = 5 } } },
    };
    for (messages, 0..) |m, i| {
        var event_id = sid;
        event_id[0] = @intCast(i);
        var tx = try db.begin();
        defer tx.deinit();
        _ = try database.message.appendCommittedMessage(&db, a, sid, event_id, i + 1, m);
        try tx.commit();
    }

    const projected = try project(a, &db, sid, .{ .input_ceiling = 40_000 });
    try t.expectEqual(@as(usize, 2), projected.messages.len);
    try t.expectEqualStrings("second summary", projected.messages[0].compaction.summary);
    try t.expectEqual(@as(u64, 4), projected.messages[1].id());
}
