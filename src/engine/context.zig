//! Select the model history of one round from the session history, and count it from the stored estimates.

const std = @import("std");
const proto = @import("proto");
const database = @import("../store/store.zig");
const Resources = @import("test_resources.zig");
const ai = @import("ai");
const Session = @import("../session/session.zig").Session;
const token_estimate = @import("../session/tokens.zig");

pub const default_context_window: u64 = 128_000;
pub const default_max_output: u32 = 8192;
/// The JSON around one tool declaration. The widest wire, Responses with deferred loading, writes 97 bytes, and the rest covers escaped characters.
const tool_frame_bytes = 128;

/// The limits of one request. The history compacts above `compact_at`. The rest of the window holds the answer and the estimate error.
pub const Budget = struct {
    window: u64,
    /// The estimate of the system prompt and the tool declarations. A provider count already holds them.
    fixed: u64,
    compact_at: u64,
    /// The session model. Only its provider count anchors the next count. Another model can use another tokenizer.
    model: []const u8,

    /// Fail when the prompt and tools alone reach the compaction point, because no compaction can make room.
    pub fn forRequest(window_limit: ?u64, model: []const u8, max_output: u32, system: []const u8, tools: []const ai.ir.Tool) error{ContextTooLarge}!Budget {
        const window = window_limit orelse default_context_window;
        // Reserve a tenth of the window. A small window reserves up to a quarter.
        const reserve = @max(window / 10, @min(16_384, window / 4));
        // The request writes each schema as raw JSON, and the frame covers the keys and escapes of each tool.
        var tool_bytes: u64 = 0;
        for (tools) |tool| tool_bytes += tool.name.len + tool.description.len + tool.input_schema.len + tool_frame_bytes;
        const fixed = token_estimate.ofBytes(system.len) + token_estimate.ofBytes(tool_bytes);
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

/// Count the tokens of the next request to `model`. `prompt_tokens` stands for the prompt and the tools when no provider count anchors the count.
/// A null model or prompt estimate takes the value that the session row stores.
pub fn count(gpa: std.mem.Allocator, db: *database.Database, session_id: [16]u8, model: ?[]const u8, prompt_tokens: ?u64) !u64 {
    var row = try db.queries.context_count.one(gpa, .{ .session_id = session_id, .model = model, .prompt_tokens = prompt_tokens });
    defer row.deinit();
    return row.value.tokens;
}

/// Return the newest checkpoint and every message the model reads, or refuse a count above the compaction point. The slice belongs to `arena`; the messages borrow the session history.
pub fn project(gpa: std.mem.Allocator, arena: std.mem.Allocator, db: *database.Database, session: *const Session, budget: Budget) !Projection {
    const tokens = try count(gpa, db, session.id.raw, budget.model, budget.fixed);
    if (tokens > budget.compact_at) return error.ContextHistoryTooLarge;
    return .{ .messages = try session.history.model(arena, null), .tokens = tokens };
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
    var resident = Session.init(t.allocator, .bytes(sid));
    defer resident.deinit();
    for (messages, 0..) |m, i| {
        var event_id = sid;
        event_id[0] = @intCast(i);
        var tx = try db.begin();
        defer tx.deinit();
        _ = try resident.commit(try database.message.appendCommittedMessage(&db, a, sid, event_id, i + 1, m));
        try tx.commit();
    }

    const projected = try project(t.allocator, a, &db, &resident, .{ .window = 40_000, .fixed = 0, .compact_at = 40_000, .model = "test/model" });
    try t.expectEqual(@as(usize, 2), projected.messages.len);
    try t.expectEqualStrings("second summary", projected.messages[0].compaction.summary);
    try t.expectEqual(@as(u64, 4), projected.messages[1].id());
}
