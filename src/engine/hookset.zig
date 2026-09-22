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

    /// Fold the chain and read a replacement as `T`, or null when none; a block or an unreadable answer stops the run.
    pub fn decide(
        self: HookSet,
        comptime T: type,
        arena: std.mem.Allocator,
        run_id: proto.ids.RunId,
        point: proto.hook.Point,
        payload: anytype,
    ) error{ HookAnswerInvalid, HookBlocked, Canceled }!?T {
        switch (self.askIfHeld(arena, point, payload)) {
            .proceed => return null,
            .replace => |value| return std.json.parseFromValueLeaky(T, arena, value, .{ .ignore_unknown_fields = true }) catch return error.HookAnswerInvalid,
            .block => |reason| {
                std.log.warn("run {d} stopped at {s}: {s}", .{ run_id, @tagName(point), reason });
                return error.HookBlocked;
            },
            .canceled => return error.Canceled,
        }
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

test "the default set holds nothing and askIfHeld skips the round trip" {
    const defaults: HookSet = .{};
    try testing.expect(!defaults.holds(defaults.ctx, .@"tool.before"));
    try testing.expectEqual(Decision.proceed, defaults.ask(defaults.ctx, testing.allocator, .@"tool.before", "{}"));

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

test "decide reads a replacement and stops the run on a block or an unreadable answer" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Stub = struct {
        answer: Decision,
        fn holds(_: *anyopaque, _: proto.hook.Point) bool {
            return true;
        }
        fn ask(ctx: *anyopaque, _: std.mem.Allocator, _: proto.hook.Point, _: []const u8) Decision {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return self.answer;
        }
    };
    const Answer = struct { count: u32 };
    var stub: Stub = .{ .answer = .proceed };
    const set: HookSet = .{ .ctx = &stub, .holds = Stub.holds, .ask = Stub.ask };
    try testing.expectEqual(null, try set.decide(Answer, arena, 1, .@"request.send", .{}));

    stub.answer = .{ .replace = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"count\":3,\"extra\":true}", .{}) };
    try testing.expectEqual(3, (try set.decide(Answer, arena, 1, .@"request.send", .{})).?.count);

    stub.answer = .{ .replace = .{ .string = "unreadable" } };
    try testing.expectError(error.HookAnswerInvalid, set.decide(Answer, arena, 1, .@"request.send", .{}));

    stub.answer = .{ .block = "denied" };
    try testing.expectError(error.HookBlocked, set.decide(Answer, arena, 1, .@"request.send", .{}));

    stub.answer = .canceled;
    try testing.expectError(error.Canceled, set.decide(Answer, arena, 1, .@"request.send", .{}));
}
