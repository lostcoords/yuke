//! Select model history from committed storage without a dependency on the UI cache.

const std = @import("std");
const proto = @import("proto");
const database = @import("../store/store.zig");
const Resources = @import("test_resources.zig");
const ai = @import("ai");
const transcript = @import("../session/transcript.zig");
const zqlite = @import("zqlite");
const allocations = @import("../allocations.zig");
const token_estimate = @import("../session/tokens.zig");

pub const default_context_window: u64 = 128_000;
pub const default_max_output: u32 = 8192;

/// The limits of one request. The history compacts above `compact_at`. The rest of the window holds the answer and the estimate error.
pub const Budget = struct {
    window: u64,
    /// The estimate of the system prompt and the tool declarations. A provider count already holds them.
    fixed: u64,
    compact_at: u64,
    /// The session model. Only its provider count anchors the next count. Another model can use another tokenizer.
    model: []const u8,

    /// Fail when the prompt and tools alone reach the compaction point, because no compaction can make room.
    pub fn forRequest(window_limit: ?u64, model: []const u8, max_output: u32, system: []const u8, tools: []const ai.ir.Tool) !Budget {
        const window = window_limit orelse default_context_window;
        // Reserve a tenth of the window. A small window reserves up to a quarter.
        const reserve = @max(window / 10, @min(16_384, window / 4));
        var tools_json = std.Io.Writer.Discarding.init(&.{});
        try std.json.Stringify.value(tools, .{ .emit_null_optional_fields = false }, &tools_json.writer);
        const fixed = token_estimate.ofBytes(system.len) + token_estimate.ofBytes(tools_json.fullCount());
        // A zero reserve leaves no room for the answer.
        if (max_output == 0 or reserve == 0 or fixed >= window - reserve) return error.ContextTooLarge;
        return .{ .window = window, .fixed = fixed, .compact_at = window - reserve, .model = model };
    }

    /// Clamp the answer ceiling to the room that the count leaves. The input and the answer then fit the window.
    pub fn clampOutput(self: Budget, max_output: u32, tokens: u64) u32 {
        std.debug.assert(tokens <= self.compact_at); // `project` refuses a larger history.
        std.debug.assert(max_output > 0); // `forRequest` refuses a zero answer ceiling.
        return @intCast(@min(max_output, self.window - tokens));
    }
};

pub const Projection = struct {
    messages: []const proto.message.Message,
    /// The count that `project` held under the budget.
    tokens: u64,
};

/// The newest compaction message. It leads the request and stands for every message it covers.
pub const Head = struct {
    message: proto.message.Message,
    /// The first message the checkpoint kept. The request reads no message below it.
    from_id: u64,
};

/// Read the checkpoint into arena with a temporary SQL row from gpa.
pub fn readHead(gpa: std.mem.Allocator, arena: std.mem.Allocator, db: *database.Database, session_id: [16]u8) !?Head {
    var row = (try db.queries.newest_compaction.maybeOne(gpa, .{ .session_id = session_id })) orelse return null;
    defer row.deinit();
    const message = try std.json.parseFromSliceLeaky(proto.message.Message, arena, row.value.payload, .{ .allocate = .alloc_always });
    if (message != .compaction or message.compaction.id != row.value.message_id) return error.CorruptLog;
    return .{ .message = message, .from_id = message.compaction.first_kept_id };
}

/// Count the tokens of the next request to `model`. `prompt_tokens` stands for the prompt and the tools when no provider count anchors the count.
/// A null model or prompt estimate takes the value that the session row stores.
pub fn count(gpa: std.mem.Allocator, db: *database.Database, session_id: [16]u8, model: ?[]const u8, prompt_tokens: ?u64) !u64 {
    var row = try db.queries.context_count.one(gpa, .{ .session_id = session_id, .model = model, .prompt_tokens = prompt_tokens });
    defer row.deinit();
    return row.value.tokens;
}

/// Return the newest checkpoint and every retained message, or refuse a count above the compaction point.
pub fn project(gpa: std.mem.Allocator, arena: std.mem.Allocator, db: *database.Database, session_id: [16]u8, budget: Budget) !Projection {
    const head = try readHead(gpa, arena, db, session_id);
    const tokens = try count(gpa, db, session_id, budget.model, budget.fixed);
    if (tokens > budget.compact_at) return error.ContextHistoryTooLarge;
    return .{ .messages = try collect(gpa, arena, db, session_id, head, null), .tokens = tokens };
}

/// Read the selected history into arena with a temporary row buffer from gpa.
pub fn collect(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    db: *database.Database,
    session_id: [16]u8,
    head: ?Head,
    stop_id: ?u64,
) ![]const proto.message.Message {
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    var messages: std.ArrayList(proto.message.Message) = .empty;
    // The checkpoint leads the range and stands for every message it replaced.
    if (head) |h| try messages.append(arena, h.message);
    var rows = try db.queries.context_messages.rows(.{
        .session_id = session_id,
        .first_message_id = if (head) |h| h.from_id else 0,
        .stop_message_id = stop_id,
    });
    defer rows.deinit();
    while (try rows.next(scratch.allocator())) |row| {
        defer _ = scratch.reset(.retain_capacity);
        const msg = try std.json.parseFromSliceLeaky(proto.message.Message, arena, row.value.payload, .{ .allocate = .alloc_always });
        if (msg.id() != row.value.message_id) return error.CorruptLog;
        if (msg == .compaction) continue; // The head already states every checkpoint below it.
        try messages.append(arena, msg);
    }
    return messages.items;
}

test "the budget reserves room and clamps the answer" {
    const t = std.testing;
    try t.expectEqual(@as(u64, 945_000), (try Budget.forRequest(1_050_000, "m", 128_000, "", &.{})).compact_at);
    // A small window keeps a quarter of itself, up to 16,384 tokens.
    try t.expectEqual(@as(u64, 15_000), (try Budget.forRequest(20_000, "m", 1000, "", &.{})).compact_at);
    const tool = try Budget.forRequest(20_000, "m", 1000, "x" ** 3000, &.{.{ .name = "read", .description = "x" ** 3000, .input_schema = "{}" }});
    try t.expect(tool.fixed > token_estimate.ofBytes(6000));
    try t.expectEqual(@as(u32, 6000), tool.clampOutput(8192, 14_000));
    try t.expectEqual(@as(u32, 1000), tool.clampOutput(1000, 14_000));
    try t.expectError(error.ContextTooLarge, Budget.forRequest(3, "m", 1, "", &.{}));
    try t.expectError(error.ContextTooLarge, Budget.forRequest(20_000, "m", 1000, "x" ** 60_000, &.{}));
    try t.expectError(error.ContextTooLarge, Budget.forRequest(null, "m", 0, "", &.{}));
}

test "only a provider count of the session model anchors the count" {
    const t = std.testing;
    var db = try database.Database.openTest();
    defer db.deinit();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sid = [_]u8{43} ** 16;
    try Resources.seedSession(&db, sid, .{ .model = "p/m", .title = "", .created_at_ms = 0, .updated_at_ms = 0 });
    const signature = "A" ** 40_000;
    const messages = [_]proto.message.Message{
        .{ .user = .{ .id = 1, .input_id = 1, .content = &.{.{ .text = .{ .text = "u" ** 4000 } }}, .time = .{ .created_at_ms = 1 } } },
        .{ .assistant = .{ .id = 2, .run_id = 1, .config_rev = 0, .time = .{ .created_at_ms = 2 }, .provenance = .{ .protocol = .openai_responses, .model = "p/m" }, .tokens = .{ .input = 5000, .output = 50, .reasoning = 0, .cache_read = 0, .cache_write = 0 }, .content = &.{
            .{ .reasoning = .{ .id = 0, .text = "", .signature = signature, .title = "" } },
            .{ .text = .{ .id = 1, .text = "a" ** 400 } },
        } } },
        .{ .user = .{ .id = 3, .input_id = 2, .content = &.{.{ .text = .{ .text = "v" ** 800 } }}, .time = .{ .created_at_ms = 3 } } },
    };
    {
        var tx = try db.begin();
        defer tx.deinit();
        for (messages, 1..) |m, n| _ = try database.message.appendCommittedMessage(&db, a, sid, @splat(@intCast(n)), n, m);
        try tx.commit();
    }
    const budget: Budget = .{ .window = 100_000, .fixed = 700, .compact_at = 90_000, .model = "p/m" };
    // The provider input holds message 1 and the prompt, so only message 2 and the later message add to it.
    const answer = token_estimate.ofMessage(messages[1]);
    const later = token_estimate.ofMessage(messages[2]).tokens;
    try t.expectEqual(5000 + answer.tokens + later, try count(t.allocator, &db, sid, budget.model, budget.fixed));
    // Another model has no anchor and gets no replayed reasoning, so the prompt and the rest of each message are estimated.
    var switched = budget;
    switched.model = "p/other";
    try t.expect(answer.reasoning > 0);
    const rest = token_estimate.ofMessage(messages[0]).tokens + answer.tokens - answer.reasoning + later;
    try t.expectEqual(700 + rest, try count(t.allocator, &db, sid, switched.model, switched.fixed));
}

test "model history survives cache eviction and an insufficient budget drops nothing" {
    const t = std.testing;
    var db = try database.Database.openTest();
    defer db.deinit();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sid = [_]u8{42} ** 16;
    try Resources.seedSession(&db, sid, .{ .model = "test/model", .title = "", .created_at_ms = 0, .updated_at_ms = 0 });
    var cache = transcript.Transcript.init(t.allocator);
    defer cache.deinit();
    cache.max_messages = 2;
    {
        var tx = try db.begin();
        defer tx.deinit();
        for (1..10) |n| {
            const id: u64 = @intCast(n);
            const user = n % 2 == 1 and n != 9 or n == 8;
            const msg: proto.message.Message = if (user) .{ .user = .{ .id = id, .content = &.{.{ .text = .{ .text = "task" } }}, .input_id = id, .time = .{ .created_at_ms = id } } } else .{ .assistant = .{ .id = id, .run_id = 1, .config_rev = 0, .content = &.{}, .time = .{ .created_at_ms = id } } };
            var event_id = sid;
            event_id[0] = @intCast(n);
            _ = try database.message.appendCommittedMessage(&db, a, sid, event_id, id, msg);
            try cache.append(msg);
        }
        try tx.commit();
    }
    try t.expectEqual(@as(u64, 8), cache.list.items[0].message.id());
    const wide = try project(t.allocator, a, &db, sid, .{ .window = 40_000, .fixed = 0, .compact_at = 40_000, .model = "test/model" });
    try t.expectEqual(@as(usize, 9), wide.messages.len);
    try t.expectEqual(@as(u64, 1), wide.messages[0].id());
    try t.expectEqual(@as(usize, 2), cache.list.items.len);
    try t.expectError(error.ContextHistoryTooLarge, project(t.allocator, a, &db, sid, .{ .window = 40_000, .fixed = 0, .compact_at = 1, .model = "test/model" }));
    const again = try project(t.allocator, a, &db, sid, .{ .window = 40_000, .fixed = 0, .compact_at = 40_000, .model = "test/model" });
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
    try Resources.seedSession(&db, sid, .{ .model = "test/model", .title = "", .created_at_ms = 0, .updated_at_ms = 0 });

    // 1 and 2 are covered history, 3 is an old checkpoint, 4 is the tail, 5 is the newest checkpoint.
    const messages = [_]proto.message.Message{
        .{ .user = .{ .id = 1, .input_id = 1, .content = &.{.{ .text = .{ .text = "old" } }}, .time = .{ .created_at_ms = 1 } } },
        .{ .assistant = .{ .id = 2, .run_id = 1, .config_rev = 0, .content = &.{}, .time = .{ .created_at_ms = 2 } } },
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

    const projected = try project(t.allocator, a, &db, sid, .{ .window = 40_000, .fixed = 0, .compact_at = 40_000, .model = "test/model" });
    try t.expectEqual(@as(usize, 2), projected.messages.len);
    try t.expectEqualStrings("second summary", projected.messages[0].compaction.summary);
    try t.expectEqual(@as(u64, 4), projected.messages[1].id());
}

test "a context cutoff excludes the boundary payload and preserves validation inside the range" {
    const t = std.testing;
    var db = try database.Database.openTest();
    defer db.deinit();
    var setup: std.heap.ArenaAllocator = .init(t.allocator);
    defer setup.deinit();
    const a = setup.allocator();
    const sid = [_]u8{61} ** 16;
    try database.session.seedSession(&db, sid);
    const large = try a.alloc(u8, 1024 * 1024);
    @memset(large, 'x');
    {
        var tx = try db.begin();
        defer tx.deinit();
        for (1..4) |id| {
            _ = try database.message.appendCommittedMessage(&db, a, sid, @splat(@intCast(id)), id, .{ .user = .{
                .id = id,
                .input_id = id,
                .content = &.{.{ .text = .{ .text = if (id == 2) large else "small" } }},
                .time = .{ .created_at_ms = id },
            } });
        }
        try tx.commit();
    }
    const covered = try collect(t.allocator, a, &db, sid, null, 2);
    try t.expectEqual(@as(usize, 1), covered.len);
    try t.expectEqual(@as(u64, 1), covered[0].id());
    const all = try collect(t.allocator, a, &db, sid, null, null);
    try t.expectEqual(@as(usize, 3), all.len);
    try t.expectEqual(@as(u64, 3), all[2].id());
    try t.expectEqual(@as(usize, 0), (try collect(t.allocator, a, &db, sid, null, 0)).len);
    try t.expectEqual(@as(usize, 0), (try collect(t.allocator, a, &db, sid, null, 1)).len);
    // The row id is valid, but its payload names another message.
    try db.conn.exec("UPDATE events SET payload = json_set(payload, '$.id', 99) WHERE session_id = ? AND seq = 2", .{zqlite.blob(&sid)});
    try t.expectEqual(@as(usize, 1), (try collect(t.allocator, a, &db, sid, null, 2)).len);
    try t.expectError(error.CorruptLog, collect(t.allocator, a, &db, sid, null, 3));
    try t.expectError(error.CorruptLog, collect(t.allocator, a, &db, sid, null, null));
}

test "projected text outlives temporary SQL rows" {
    const t = std.testing;
    var db = try database.Database.openTest();
    defer db.deinit();
    var setup: std.heap.ArenaAllocator = .init(t.allocator);
    defer setup.deinit();
    const a = setup.allocator();
    const sid = [_]u8{62} ** 16;
    try database.session.seedSession(&db, sid);
    const text = try a.alloc(u8, 256 * 1024);
    @memset(text, 'x');
    text[0] = '\n';
    text[text.len - 1] = '"';
    {
        var tx = try db.begin();
        defer tx.deinit();
        _ = try database.message.appendCommittedMessage(&db, a, sid, @splat(1), 1, .{ .compaction = .{
            .id = 1,
            .run_id = 1,
            .reason = .manual,
            .summary = text,
            .first_kept_id = 2,
            .tokens_before = 1_000_000,
            .tokens_after = 100_000,
            .time = .{ .created_at_ms = 1 },
        } });
        for (2..6) |id| {
            _ = try database.message.appendCommittedMessage(&db, a, sid, @splat(@intCast(id)), id, .{ .user = .{
                .id = id,
                .input_id = id,
                .content = &.{.{ .text = .{ .text = text } }},
                .time = .{ .created_at_ms = id },
            } });
        }
        try tx.commit();
    }
    const Check = struct {
        fn run(gpa: std.mem.Allocator, store: *database.Database, session_id: [16]u8, expected: []const u8) !void {
            var result: std.heap.ArenaAllocator = .init(gpa);
            defer result.deinit();
            var temporary: allocations = .{ .backing = gpa };
            const projected = try project(temporary.allocator(), result.allocator(), store, session_id, .{ .window = 4_000_000, .fixed = 0, .compact_at = 4_000_000, .model = "" });
            try t.expectEqual(@as(usize, 0), temporary.liveBytes());
            try t.expectEqual(@as(usize, 0), temporary.liveCount());
            try t.expectEqual(@as(usize, 5), projected.messages.len);
            try t.expectEqualStrings(expected, projected.messages[0].compaction.summary);
            for (projected.messages[1..]) |msg| try t.expectEqualStrings(expected, msg.user.content[0].text.text);
        }
    };
    try Check.run(t.allocator, &db, sid, text);
}
