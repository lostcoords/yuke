//! Select model history from committed storage without a dependency on the UI cache.

const std = @import("std");
const proto = @import("proto");
const database = @import("../store/store.zig");

pub const default_context_window: u64 = 128_000;
pub const default_max_output: u32 = 8192;

pub const Budget = struct {
    max_tokens: u64,
    input_ceiling: u64,

    /// Reserve the final build-hook prompt, tools, output, and a framing margin.
    pub fn forRequest(window_limit: ?u64, output: u32, system: []const u8, tools: []const @import("ai").ir.Tool) !Budget {
        const window = window_limit orelse default_context_window;
        const fixed = tokensFor(system.len) + tokensFor(try jsonBytes(tools)) + 1024;
        if (output == 0 or output >= window or fixed >= window - output) return error.ContextTooLarge;
        const ceiling = window - output - fixed;
        return .{ .max_tokens = @max(1, ceiling / 4), .input_ceiling = ceiling };
    }

    fn lowWater(self: Budget) u64 {
        std.debug.assert(self.max_tokens > 0 and self.input_ceiling >= self.max_tokens);
        return @max(1, @min(20_000, self.max_tokens / 2));
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

/// Scan newest first with constant memory and preserve the complete input batch.
const Scan = struct {
    budget: Budget,
    total: u64 = 0,
    first: u64 = 0,
    recent: u64 = 0,
    recent_tokens: u64 = 0,
    pin: u64 = 0,
    pin_tokens: u64 = 0,
    seen_user: bool = false,
    past_pin: bool = false,

    fn add(self: *Scan, id: u64, user: bool, bytes: u64) !bool {
        std.debug.assert(id > 0);
        std.debug.assert(self.first == 0 or id < self.first);
        if (self.seen_user and !user) self.past_pin = true;
        self.seen_user = self.seen_user or user;
        const before = self.total;
        self.total += tokensFor(bytes);
        self.first = id;
        if (!self.past_pin) {
            if (self.total > self.budget.input_ceiling) return error.TurnTooLarge;
            self.pin = id;
            self.pin_tokens = self.total;
        }
        // Take the message that crosses the low water, so one large message never empties the tail.
        if (self.recent == 0 or (before <= self.budget.lowWater() and self.total <= self.budget.max_tokens)) {
            self.recent = id;
            self.recent_tokens = self.total;
        }
        return !(self.past_pin and self.total > self.budget.max_tokens);
    }

    fn selected(self: Scan) struct { id: u64, tokens: u64 } {
        std.debug.assert(self.first == 0 or (self.pin > 0 and self.recent > 0));
        if (self.total <= self.budget.max_tokens) return .{ .id = self.first, .tokens = self.total };
        if (self.pin < self.recent) return .{ .id = self.pin, .tokens = self.pin_tokens };
        return .{ .id = self.recent, .tokens = self.recent_tokens };
    }
};

/// Build the model history: the newest checkpoint, then the committed suffix that fits the budget.
pub fn project(arena: std.mem.Allocator, db: *database.Database, session_id: [16]u8, budget: Budget) !Projection {
    std.debug.assert(budget.max_tokens > 0 and budget.max_tokens <= budget.input_ceiling);
    const head = try readHead(arena, db, session_id);
    // The checkpoint is charged once here, so no trim can drop the message that stands for the rest.
    var scan: Scan = .{ .budget = budget, .total = if (head) |h| tokensFor(h.message.compaction.summary.len) else 0 };
    {
        var rows = try db.queries.context_sizes.rows(.{ .session_id = session_id, .first_message_id = if (head) |h| h.from_id else 0 });
        defer rows.deinit();
        while (try rows.next(arena)) |owned| {
            var row = owned;
            defer row.deinit();
            if (head) |h| if (row.value.message_id == h.id) continue;
            if (!try scan.add(row.value.message_id, std.mem.eql(u8, row.value.role, "user"), row.value.bytes)) break;
        }
    }
    const selected = scan.selected().id;
    var messages: std.ArrayList(proto.message.Message) = .empty;
    // The checkpoint leads whatever id it holds, because it stands for the messages before the tail.
    if (head) |h| try messages.append(arena, h.message);
    if (selected > 0) {
        var rows = try db.queries.context_messages.rows(.{ .session_id = session_id, .first_message_id = selected });
        defer rows.deinit();
        while (try rows.next(arena)) |owned| {
            var row = owned;
            defer row.deinit();
            const msg = try std.json.parseFromSliceLeaky(proto.message.Message, arena, row.value.payload, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
            if (msg.id() != row.value.message_id) return error.CorruptLog;
            // An older checkpoint is redundant, because the head was written with its text.
            if (msg == .compaction) continue;
            try messages.append(arena, msg);
        }
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

test "a trim preserves the complete input batch and refuses an oversized live turn" {
    var scan: Scan = .{ .budget = .{ .max_tokens = 10, .input_ceiling = 100 } };
    try std.testing.expect(try scan.add(5, false, 30));
    try std.testing.expect(try scan.add(4, true, 30));
    try std.testing.expect(try scan.add(3, true, 30));
    try std.testing.expect(!try scan.add(2, false, 3000));
    try std.testing.expectEqual(@as(u64, 3), scan.selected().id);
    try std.testing.expectEqual(@as(u64, 30), scan.selected().tokens);
    var large: Scan = .{ .budget = .{ .max_tokens = 10, .input_ceiling = 20 } };
    _ = try large.add(2, false, 30);
    try std.testing.expectError(error.TurnTooLarge, large.add(1, true, 33));
}

test "a trim keeps the message that crosses the low water" {
    const t = std.testing;
    // These are the measured budgets of a 1M-token model, so low water is the flat 20000.
    var scan: Scan = .{ .budget = .{ .max_tokens = 230_500, .input_ceiling = 922_000 } };
    try t.expectEqual(@as(u64, 20_000), scan.budget.lowWater());
    try t.expect(try scan.add(4, true, 2_400)); // the new user turn, 800 tokens
    try t.expect(try scan.add(3, false, 135_000)); // a 45000-token tool result straddles the mark
    try t.expect(try scan.add(2, false, 3_000));
    try t.expect(try scan.add(1, false, 3_000));
    // A tail that stops before message 3 would hold 800 tokens of a 230500-token budget.
    try t.expectEqual(@as(u64, 3), scan.recent);
    try t.expectEqual(@as(u64, 45_800), scan.recent_tokens);

    // A message wider than the whole budget stays out, because a trim may not exceed what it trims to.
    var huge: Scan = .{ .budget = .{ .max_tokens = 20_000, .input_ceiling = 100_000 } };
    try t.expect(try huge.add(3, true, 3_000));
    try t.expect(!try huge.add(2, false, 90_000));
    try t.expectEqual(@as(u64, 3), huge.recent);
    try t.expectEqual(@as(u64, 1_000), huge.recent_tokens);
}

test "an empty history and a history within budget need no trim" {
    var scan: Scan = .{ .budget = .{ .max_tokens = 100, .input_ceiling = 400 } };
    try std.testing.expectEqual(@as(u64, 0), scan.selected().id);
    _ = try scan.add(3, true, 30);
    _ = try scan.add(2, false, 30);
    _ = try scan.add(1, true, 30);
    try std.testing.expectEqual(@as(u64, 1), scan.selected().id);
    try std.testing.expectEqual(@as(u64, 30), scan.selected().tokens);
}

test "model history survives cache eviction and a larger budget restores stored history" {
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
    const narrow: Budget = .{ .max_tokens = 100, .input_ceiling = 5000 };
    const first = try project(a, &db, sid, narrow);
    try t.expectEqual(@as(u64, 7), first.messages[0].id());
    try t.expectEqual(@as(usize, 3), first.messages.len);
    // The boundary follows the budget alone, so the same budget selects the same suffix.
    const held = try project(a, &db, sid, narrow);
    try t.expectEqual(first.messages[0].id(), held.messages[0].id());
    const wide = try project(a, &db, sid, .{ .max_tokens = 10_000, .input_ceiling = 40_000 });
    try t.expectEqual(@as(usize, 9), wide.messages.len);
    try t.expectEqual(@as(u64, 1), wide.messages[0].id());
    try t.expectEqual(@as(usize, 2), cache.list.items.len);
    try t.expectError(error.TurnTooLarge, project(a, &db, sid, .{ .max_tokens = 1, .input_ceiling = 1 }));
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

    const projected = try project(a, &db, sid, .{ .max_tokens = 10_000, .input_ceiling = 40_000 });
    try t.expectEqual(@as(usize, 2), projected.messages.len);
    try t.expectEqualStrings("second summary", projected.messages[0].compaction.summary);
    try t.expectEqual(@as(u64, 4), projected.messages[1].id());
}
