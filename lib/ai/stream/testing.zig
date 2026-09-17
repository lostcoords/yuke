//! The three protocol reducers share these assertions, so each suite states only its own protocol differences.

const std = @import("std");
const event = @import("event.zig");
const types = @import("../types.zig");

pub fn Harness(comptime Reducer: type) type {
    return struct {
        arena: std.heap.ArenaAllocator,
        reducer: Reducer,
        out: std.ArrayList(event.StreamEvent) = .empty,

        pub fn init() @This() {
            return .{ .arena = std.heap.ArenaAllocator.init(std.testing.allocator), .reducer = Reducer.init(std.testing.allocator) };
        }

        pub fn deinit(self: *@This()) void {
            self.out.deinit(std.testing.allocator);
            self.reducer.deinit();
            self.arena.deinit();
        }

        pub fn feed(self: *@This(), events: []const []const u8) !void {
            for (events) |e| try self.reducer.decode(e, self.arena.allocator(), &self.out);
        }
    };
}

pub fn decodeAll(comptime Reducer: type) fn (std.mem.Allocator, []const []const u8) anyerror!void {
    const Impl = struct {
        fn run(gpa: std.mem.Allocator, events: []const []const u8) !void {
            var arena = std.heap.ArenaAllocator.init(gpa);
            defer arena.deinit();
            var reducer = Reducer.init(gpa);
            defer reducer.deinit();
            var out: std.ArrayList(event.StreamEvent) = .empty;
            defer out.deinit(gpa);
            for (events) |e| try reducer.decode(e, arena.allocator(), &out);
        }
    };
    return Impl.run;
}

/// Assert the neutral sequence that every protocol produces for one two-chunk text response, and return its protocol-specific `done` payload.
pub fn expectTextResponse(out: []const event.StreamEvent) !event.Done {
    try std.testing.expectEqual(@as(usize, 5), out.len);
    try std.testing.expect(out[0] == .block_started);
    try std.testing.expectEqual(event.BlockKind.text, out[0].block_started.kind);
    try std.testing.expectEqualStrings("Hel", out[1].text_delta.text);
    try std.testing.expectEqualStrings("lo", out[2].text_delta.text);
    try std.testing.expect(out[3].block_stopped.result == .text);
    try std.testing.expectEqual(types.FinishReason.stop, out[4].done.stop_reason);
    return out[4].done;
}
