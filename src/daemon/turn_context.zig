//! The per-turn model context. Load the committed history once, then append each round. A byte and token
//! budget bounds it, so the context never grows without limit. SQLite stays the source of truth.

const std = @import("std");
const wire = @import("wire");
const database = @import("../database/database.zig");

const Database = database.Database;
const message_store = database.message;
const Message = wire.message.Message;

pub const Budget = struct { max_bytes: u64, max_tokens: u64 };

pub const TurnContext = struct {
    arena: std.mem.Allocator,
    budget: Budget,
    messages: std.ArrayList(Message) = .empty, // oldest -> newest
    turn_start: usize = 0, // index of the current turn; trimming never crosses it
    bytes: u64 = 0,
    estimated_tokens: u64 = 0,

    /// Load the committed history once. Keep the newest messages that fit the budget and trim the oldest.
    /// The last message is the current user input; it and each later round message stay. `max_messages`
    /// caps the transient load. The result borrows `arena`.
    pub fn load(arena: std.mem.Allocator, db: *Database, session_id: [16]u8, budget: Budget, max_messages: usize) !TurnContext {
        var ctx: TurnContext = .{ .arena = arena, .budget = budget };
        const all = (try message_store.historyPage(db, arena, session_id, 0, max_messages)).messages;
        const pin = all.len -| 1; // the user input is the newest committed message
        const kept = keptRange(all, budget, pin);
        try ctx.messages.appendSlice(arena, all[kept.first..]);
        ctx.turn_start = pin - kept.first;
        ctx.bytes = kept.bytes;
        ctx.estimated_tokens = kept.tokens;
        return ctx;
    }

    /// Append a committed round message, then trim pre-turn history to re-fit the budget. The current
    /// turn never trims. The message is duplicated into the arena.
    pub fn appendCommitted(self: *TurnContext, msg: Message) !void {
        const owned = try wire.dupe(self.arena, msg);
        try self.messages.append(self.arena, owned);
        const kept = keptRange(self.messages.items, self.budget, self.turn_start);
        if (kept.first > 0) {
            const keep = self.messages.items[kept.first..];
            std.mem.copyForwards(Message, self.messages.items[0..keep.len], keep);
            self.messages.shrinkRetainingCapacity(keep.len);
            self.turn_start -= kept.first;
        }
        self.bytes = kept.bytes;
        self.estimated_tokens = kept.tokens;
    }

    /// The model context, oldest first. It borrows the arena.
    pub fn slice(self: *const TurnContext) []const Message {
        return self.messages.items;
    }
};

const Kept = struct { first: usize, bytes: u64, tokens: u64 };

/// Walk newest -> oldest and keep messages while they fit the budget. Always keep `all[pin..]`, the
/// current turn. Return the oldest kept index and the kept totals.
fn keptRange(all: []const Message, budget: Budget, pin: usize) Kept {
    var kept: Kept = .{ .first = all.len, .bytes = 0, .tokens = 0 };
    var i: usize = all.len;
    while (i > 0) {
        i -= 1;
        const b = messageBytes(all[i]);
        const t = tokensFor(b);
        const must_keep = i >= pin;
        if (!must_keep and (kept.bytes + b > budget.max_bytes or kept.tokens + t > budget.max_tokens)) break;
        kept.bytes += b;
        kept.tokens += t;
        kept.first = i;
    }
    return kept;
}

/// Estimate a message's token cost from its JSON byte size. A real tokenizer can replace this later.
fn tokensFor(bytes: u64) u64 {
    return @max(1, (bytes + 3) / 4);
}

/// The JSON byte size of one message. This bounds the context by the wire representation.
fn messageBytes(msg: Message) u64 {
    var buf: [256]u8 = undefined;
    var discarding: std.Io.Writer.Discarding = .init(&buf);
    std.json.Stringify.value(msg, .{ .emit_null_optional_fields = false }, &discarding.writer) catch return 0;
    return discarding.fullCount();
}

const testing = std.testing;

fn userMessage(id: u64) Message {
    return .{ .user = .{ .id = id, .content = &.{}, .input_id = id, .time = .{ .created_at_ms = 0 } } };
}

test "keptRange trims the oldest to fit the byte budget and always keeps the newest" {
    const msgs = [_]Message{ userMessage(1), userMessage(2), userMessage(3) };
    const per = messageBytes(msgs[0]);
    const pin = msgs.len - 1; // pin the newest only

    // A budget for about two messages keeps the two newest and trims the oldest.
    const two = keptRange(&msgs, .{ .max_bytes = per * 2, .max_tokens = 1 << 30 }, pin);
    try testing.expectEqual(@as(usize, 1), two.first);

    // A generous budget keeps every message.
    const all = keptRange(&msgs, .{ .max_bytes = 1 << 30, .max_tokens = 1 << 30 }, pin);
    try testing.expectEqual(@as(usize, 0), all.first);

    // A tiny budget still keeps the newest message.
    const tiny = keptRange(&msgs, .{ .max_bytes = 1, .max_tokens = 1 }, pin);
    try testing.expectEqual(@as(usize, 2), tiny.first);
}

test "appendCommitted accumulates bytes and tokens" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var ctx: TurnContext = .{ .arena = arena.allocator(), .budget = .{ .max_bytes = 1 << 20, .max_tokens = 1 << 20 } };
    try ctx.appendCommitted(userMessage(1));
    try ctx.appendCommitted(userMessage(2));
    try testing.expectEqual(@as(usize, 2), ctx.slice().len);
    try testing.expect(ctx.bytes > 0);
    try testing.expect(ctx.estimated_tokens > 0);
}

test "appendCommitted trims pre-turn history but keeps the current turn" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const per = messageBytes(userMessage(1));
    // One pre-turn message, then the user input at turn_start = 1.
    var ctx: TurnContext = .{ .arena = a, .budget = .{ .max_bytes = per * 2, .max_tokens = 1 << 30 }, .turn_start = 1 };
    try ctx.messages.append(a, userMessage(10)); // pre-turn history
    try ctx.messages.append(a, userMessage(20)); // the current user input
    try ctx.appendCommitted(userMessage(30)); // a round message; the budget trims the pre-turn message
    try testing.expectEqual(@as(usize, 2), ctx.slice().len);
    try testing.expectEqual(@as(u64, 20), ctx.slice()[0].user.id); // id 10 was trimmed
    try testing.expectEqual(@as(u64, 30), ctx.slice()[1].user.id);
    try testing.expectEqual(@as(usize, 0), ctx.turn_start); // shifted down after the trim
}

test "appendCommitted keeps the current turn even over budget" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const per = messageBytes(userMessage(1));
    // A budget for one message. The turn (user input plus round message) still stays whole.
    var ctx: TurnContext = .{ .arena = a, .budget = .{ .max_bytes = per, .max_tokens = 1 << 30 }, .turn_start = 1 };
    try ctx.messages.append(a, userMessage(10)); // pre-turn history
    try ctx.messages.append(a, userMessage(20)); // the current user input
    try ctx.appendCommitted(userMessage(30)); // a round message; the user input must not trim
    try testing.expectEqual(@as(usize, 2), ctx.slice().len);
    try testing.expectEqual(@as(u64, 20), ctx.slice()[0].user.id); // the user input stays
    try testing.expectEqual(@as(u64, 30), ctx.slice()[1].user.id);
}
