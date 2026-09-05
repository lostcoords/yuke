//! The engine asks the process to fold a hook chain without access to JavaScript.

const std = @import("std");
const proto = @import("proto");

/// What one folded chain answers. The caller's allocator owns `replace` and `block`.
pub const Decision = union(enum) {
    /// No handler changed the value, so the call site uses what it already holds.
    proceed,
    /// The payload the call site uses instead, as the parsed JSON the point defines.
    replace: std.json.Value,
    /// The action never runs. The reason reaches the model in place of a result.
    block: []const u8,
    /// Cancellation stopped the call before the chain answered.
    canceled,
};

pub const HookSet = struct {
    ctx: *anyopaque = undefined,
    /// Report whether any handler holds `point`. A call site skips `ask` when none does.
    holds: *const fn (ctx: *anyopaque, point: proto.hook.Point) bool = holdsNone,
    /// Fold the chain for one point. `payload` is the JSON that point defines.
    ask: *const fn (
        ctx: *anyopaque,
        out: std.mem.Allocator,
        point: proto.hook.Point,
        payload: []const u8,
    ) Decision = proceed,

    /// Ask only when a handler waits, so an unhooked process pays no round trip.
    pub fn askIfHeld(
        self: HookSet,
        out: std.mem.Allocator,
        point: proto.hook.Point,
        payload: anytype,
    ) Decision {
        if (!self.holds(self.ctx, point)) return .proceed;
        const json = std.json.Stringify.valueAlloc(out, payload, .{}) catch return .proceed;
        defer out.free(json);
        return self.ask(self.ctx, out, point, json);
    }
};

/// A process without extensions holds no handler.
fn holdsNone(_: *anyopaque, _: proto.hook.Point) bool {
    return false;
}

/// A process without extensions changes nothing.
fn proceed(_: *anyopaque, _: std.mem.Allocator, _: proto.hook.Point, _: []const u8) Decision {
    return .proceed;
}

const testing = std.testing;

test "the default set holds nothing and proceeds" {
    const set: HookSet = .{};
    try testing.expect(!set.holds(set.ctx, .@"tool.before"));
    try testing.expectEqual(Decision.proceed, set.ask(set.ctx, testing.allocator, .@"tool.before", "{}"));
}

test "askIfHeld skips the round trip when no handler waits" {
    const Counter = struct {
        asked: usize = 0,
        fn holds(_: *anyopaque, _: proto.hook.Point) bool {
            return false;
        }
        fn ask(ctx: *anyopaque, _: std.mem.Allocator, _: proto.hook.Point, _: []const u8) Decision {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.asked += 1;
            return .proceed;
        }
    };
    var counter: Counter = .{};
    const set: HookSet = .{ .ctx = &counter, .holds = Counter.holds, .ask = Counter.ask };
    try testing.expectEqual(Decision.proceed, set.askIfHeld(testing.allocator, .@"tool.before", .{ .name = "bash" }));
    try testing.expectEqual(@as(usize, 0), counter.asked);
}
