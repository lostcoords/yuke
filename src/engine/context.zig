//! The per-round model context. Project the resident transcript, oldest first, inside a budget.
//! The projection borrows the transcript and copies no message. SQLite stays the source of truth.
//! A later append can evict an entry, so a projection is valid until the next commit.

const std = @import("std");
const proto = @import("proto");
const transcript_mod = @import("../session/transcript.zig");

const ids = proto.ids;
const Transcript = transcript_mod.Transcript;
const Sized = transcript_mod.Sized;
const Message = proto.message.Message;

/// The turn does not fit the model. The pinned turn cannot trim, so no budget can rescue it.
pub const Error = error{ OutOfMemory, TurnTooLarge };

/// The window to assume when the catalog publishes none. It suits the smallest model we expect.
pub const default_context_window: u64 = 128_000;
/// The output tokens to reserve when the catalog publishes no output limit.
pub const default_max_output: u64 = 8192;
/// The history takes this share of the input ceiling. The rest is headroom for the live turn.
/// A turn holds its own tool results, they can be large, and the pin refuses to trim them. So the
/// headroom must already be there when the turn starts.
pub const history_divisor: u64 = 4;
/// The recent work a trim always keeps. The working set follows the work, not the model window.
pub const keep_recent_tokens: u64 = 20_000;

/// The token budget of the history that one request carries.
pub const Budget = struct {
    /// The tokens the history may take.
    max_tokens: u64,
    /// The tokens the whole request may take. The live turn must fit inside this.
    input_ceiling: u64,

    /// Derive the history budget from the model window. The reply and the live turn both need room.
    pub fn forModel(context_window: ?u64, max_output: ?u64) Budget {
        const window = context_window orelse default_context_window;
        const output = max_output orelse default_max_output;
        const ceiling = window -| output;
        return .{ .max_tokens = @max(1, ceiling / history_divisor), .input_ceiling = @max(1, ceiling) };
    }

    /// The mark a trim falls back to. A trim is then rare, so the cached prefix survives many turns.
    /// A small budget takes half instead, because a trim that frees nothing slides on every turn.
    fn lowWater(self: Budget) u64 {
        return @max(1, @min(keep_recent_tokens, self.max_tokens / 2));
    }
};

/// The model context of one round. It borrows the transcript entries.
pub const TurnContext = struct {
    messages: []const Message = &.{},
    estimated_tokens: u64 = 0,
};

/// Project the messages the model reads. Hold the floor while the history fits the budget, so the
/// request keeps a byte-identical prefix and the provider cache stays warm. Over the budget, drop
/// to the low-water mark in one step. The current turn never trims.
///
/// A new budget re-reads the floor from the oldest resident message, so a larger model recovers the
/// history a smaller one dropped. The provider cache is model-scoped, so that switch costs nothing.
pub fn project(scratch: std.mem.Allocator, transcript: *Transcript, budget: Budget) Error!TurnContext {
    const all = try transcript.sized(scratch);
    if (all.len == 0) return .{};

    const pin = turnStart(all);
    // The pin never trims, so a turn over the whole ceiling can never fit. Refuse before the request.
    if (tokensFrom(all, pin) > budget.input_ceiling) return error.TurnTooLarge;

    const rebase = budget.max_tokens != transcript.context_floor_budget;
    const floor = if (rebase) 0 else floorIndex(all, transcript.context_floor_id);
    transcript.context_floor_budget = budget.max_tokens;

    const held = tokensFrom(all, floor);
    if (held <= budget.max_tokens) {
        transcript.context_floor_id = all[floor].message.id();
        return .{ .messages = try messagesFrom(scratch, all, floor), .estimated_tokens = held };
    }

    // The history passed the budget, so trim in one large step and record the new floor.
    const next = lowWaterIndex(all, budget.lowWater(), pin);
    transcript.context_floor_id = all[next].message.id();
    return .{ .messages = try messagesFrom(scratch, all, next), .estimated_tokens = tokensFrom(all, next) };
}

/// Copy the kept messages out of the sized view. Only the spine is new; the content still borrows.
fn messagesFrom(scratch: std.mem.Allocator, all: []const Sized, from: usize) Error![]const Message {
    const out = try scratch.alloc(Message, all.len - from);
    for (all[from..], 0..) |item, i| out[i] = item.message;
    return out;
}

/// Return the index of the message that opened the current turn. One queued drain commits every
/// waiting input as its own user message, so the pin covers the whole batch and not only the last.
fn turnStart(all: []const Sized) usize {
    var newest: usize = all.len;
    var i = all.len;
    while (i > 0) {
        i -= 1;
        if (all[i].message == .user) {
            newest = i;
            break;
        }
    }
    if (newest == all.len) return all.len - 1; // no user message, so pin the newest
    while (newest > 0 and all[newest - 1].message == .user) newest -= 1;
    return newest;
}

/// Resolve the floor id to an index. An evicted or unset floor starts at the oldest resident message.
fn floorIndex(all: []const Sized, floor_id: ids.MessageId) usize {
    for (all, 0..) |item, i| if (item.message.id() >= floor_id) return i;
    return all.len - 1; // every resident message is older than the floor, so keep the newest
}

/// Sum the estimated tokens of `all[from..]` from the sizes the transcript already measured.
fn tokensFrom(all: []const Sized, from: usize) u64 {
    var total: u64 = 0;
    for (all[from..]) |item| total += tokensFor(item.bytes);
    return total;
}

/// Walk newest -> oldest and stop at the low-water mark. Never trim into the current turn.
fn lowWaterIndex(all: []const Sized, low_water: u64, pin: usize) usize {
    var total: u64 = 0;
    var i = all.len;
    while (i > 0) {
        i -= 1;
        total += tokensFor(all[i].bytes);
        if (total > low_water and i < pin) return i + 1;
    }
    return 0;
}

/// Estimate a message's token cost from its JSON byte size. Round up, because code and CJK pack
/// fewer bytes for each token than prose. An overestimate trims early; an underestimate overflows.
fn tokensFor(bytes: u64) u64 {
    return @max(1, (bytes + 2) / 3);
}

const testing = std.testing;

fn userMessage(id: u64) Message {
    return .{ .user = .{ .id = id, .content = &.{}, .input_id = id, .time = .{ .created_at_ms = 0 } } };
}

fn assistantMessage(id: u64) Message {
    return .{ .assistant = .{ .id = id, .run_id = 1, .config_rev = 0, .agent = "a", .content = &.{}, .time = .{ .created_at_ms = 0 } } };
}

test "the budget reserves the output and leaves the live turn its headroom" {
    // A 200k window with an 8k output reservation leaves 192k, and the history takes a quarter.
    try testing.expectEqual(@as(u64, 48_000), Budget.forModel(200_000, 8_000).max_tokens);

    // The other three quarters stay free, so a turn that reads large files still fits the window.
    const ceiling: u64 = 200_000 - 8_000;
    try testing.expectEqual(ceiling - 48_000, ceiling - Budget.forModel(200_000, 8_000).max_tokens);

    // An unpublished window falls back to the conservative default, never to an unbounded budget.
    const fallback = Budget.forModel(null, null);
    try testing.expectEqual(Budget.forModel(default_context_window, default_max_output).max_tokens, fallback.max_tokens);
    try testing.expect(fallback.max_tokens < default_context_window);

    // An output reservation over the window still yields a usable budget instead of an underflow.
    try testing.expectEqual(@as(u64, 1), Budget.forModel(1000, 9000).max_tokens);

    // The ceiling is what the whole request may take, so it is always above the history budget.
    const wide = Budget.forModel(200_000, 8_000);
    try testing.expectEqual(@as(u64, 192_000), wide.input_ceiling);
    try testing.expect(wide.input_ceiling > wide.max_tokens);
}

test "the token estimate rounds up so a trim happens early" {
    try testing.expectEqual(@as(u64, 1), tokensFor(0)); // never zero
    try testing.expectEqual(@as(u64, 1), tokensFor(3));
    try testing.expectEqual(@as(u64, 2), tokensFor(4)); // 4 bytes is more than one token
    try testing.expectEqual(@as(u64, 34), tokensFor(100));
}

fn sizedOf(m: Message) Sized {
    return .{ .message = m, .bytes = transcript_mod.messageBytes(m) catch 0 };
}

test "the turn starts at the user message that opened it" {
    const msgs = [_]Sized{ sizedOf(userMessage(1)), sizedOf(assistantMessage(2)), sizedOf(userMessage(3)), sizedOf(assistantMessage(4)) };
    try testing.expectEqual(@as(usize, 2), turnStart(&msgs));

    const none = [_]Sized{ sizedOf(assistantMessage(1)), sizedOf(assistantMessage(2)) };
    try testing.expectEqual(@as(usize, 1), turnStart(&none));
}

test "one queued drain commits several inputs, and the pin covers them all" {
    // beginQueuedTurn commits one user message for every waiting input, then the run answers them.
    const batch = [_]Sized{
        sizedOf(assistantMessage(1)), // an earlier turn
        sizedOf(userMessage(2)), // the drain starts here
        sizedOf(userMessage(3)),
        sizedOf(userMessage(4)),
        sizedOf(assistantMessage(5)), // the round that answers the batch
    };
    try testing.expectEqual(@as(usize, 1), turnStart(&batch));
}

test "a generous budget holds the floor at the oldest message" {
    var t = Transcript.init(testing.allocator);
    defer t.deinit();
    try t.append(userMessage(1));
    try t.append(assistantMessage(2));

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = try project(arena.allocator(), &t, .{ .max_tokens = 1 << 30, .input_ceiling = 1 << 40 });
    try testing.expectEqual(@as(usize, 2), ctx.messages.len);
    try testing.expectEqual(@as(ids.MessageId, 1), t.context_floor_id); // the floor sits at the oldest
    try testing.expect(ctx.estimated_tokens > 0);
}

test "the low-water mark is the recent work, and always frees room" {
    // A wide model keeps the fixed recent set, not a share of its window.
    try testing.expectEqual(keep_recent_tokens, (Budget{ .max_tokens = 1_000_000, .input_ceiling = 1 << 40 }).lowWater());

    // A budget under the recent set takes half, so the trim still frees room and does not slide.
    try testing.expectEqual(@as(u64, 250), (Budget{ .max_tokens = 500, .input_ceiling = 1 << 40 }).lowWater());

    // Whatever the budget, a trim must leave room, or the floor moves on every turn.
    for ([_]u64{ 2, 500, 29_952, 250_000 }) |b| {
        try testing.expect((Budget{ .max_tokens = b, .input_ceiling = 1 << 40 }).lowWater() < b or b < 2);
    }
}

test "the floor holds steady across turns until the budget breaks" {
    var t = Transcript.init(testing.allocator);
    defer t.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A real transcript alternates: past rounds, then the user message that opened this turn.
    for (1..8) |n| try t.append(assistantMessage(n));
    try t.append(userMessage(8));
    const per = tokensFor(try transcript_mod.messageBytes(assistantMessage(1)));

    // A budget for about four messages trims, and the floor lands at the low-water mark.
    const budget: Budget = .{ .max_tokens = per * 4, .input_ceiling = 1 << 40 };
    try testing.expect(budget.lowWater() < budget.max_tokens); // the trim must move the floor
    _ = try project(a, &t, budget);
    const trimmed_floor = t.context_floor_id;
    try testing.expect(trimmed_floor > 0); // the trim moved the floor

    // The next projection is under the budget again, so the floor does not move. The prefix is stable.
    _ = try project(a, &t, budget);
    try testing.expectEqual(trimmed_floor, t.context_floor_id);
}

test "a trim never cuts into the current turn" {
    var t = Transcript.init(testing.allocator);
    defer t.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    for (1..6) |n| try t.append(assistantMessage(n)); // pre-turn history
    try t.append(userMessage(6)); // the turn opens here
    try t.append(assistantMessage(7)); // a round message of the same turn

    // A budget of one token forces the hardest possible trim.
    const ctx = try project(arena.allocator(), &t, .{ .max_tokens = 1, .input_ceiling = 1 << 40 });
    try testing.expectEqual(@as(usize, 2), ctx.messages.len);
    try testing.expectEqual(@as(u64, 6), ctx.messages[0].user.id);
    try testing.expectEqual(@as(u64, 7), ctx.messages[1].assistant.id);
}

test "a larger budget recovers the history a smaller one dropped" {
    var t = Transcript.init(testing.allocator);
    defer t.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    for (1..8) |n| try t.append(assistantMessage(n));
    try t.append(userMessage(8));
    const per = tokensFor(try transcript_mod.messageBytes(assistantMessage(1)));

    // A small model trims the history and leaves the floor above the oldest message.
    _ = try project(a, &t, .{ .max_tokens = per * 4, .input_ceiling = 1 << 40 });
    try testing.expect(t.context_floor_id > 1);

    // A larger model re-reads the floor, so the dropped history returns instead of staying lost.
    const wide = try project(a, &t, .{ .max_tokens = per * 100, .input_ceiling = 1 << 40 });
    try testing.expectEqual(@as(usize, 8), wide.messages.len);
    try testing.expectEqual(@as(ids.MessageId, 1), t.context_floor_id);
}

test "a turn larger than the whole window is refused, not sent" {
    var t = Transcript.init(testing.allocator);
    defer t.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    try t.append(assistantMessage(1)); // history the trim could drop
    try t.append(userMessage(2)); // the pin starts here and never trims

    const pinned = tokensFor(try transcript_mod.messageBytes(userMessage(2)));
    // A ceiling under the pinned turn cannot be met by any trim, so the projection refuses.
    try testing.expectError(error.TurnTooLarge, project(arena.allocator(), &t, .{
        .max_tokens = 1,
        .input_ceiling = pinned - 1,
    }));

    // A ceiling that fits the pin still projects.
    const ok = try project(arena.allocator(), &t, .{ .max_tokens = 1, .input_ceiling = pinned });
    try testing.expectEqual(@as(usize, 1), ok.messages.len);
}

test "an empty transcript projects no message" {
    var t = Transcript.init(testing.allocator);
    defer t.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = try project(arena.allocator(), &t, .{ .max_tokens = 1 << 30, .input_ceiling = 1 << 40 });
    try testing.expectEqual(@as(usize, 0), ctx.messages.len);
}
