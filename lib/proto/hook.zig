//! Hook points a plugin answers, and the decision one handler returns.

const std = @import("std");
const misc = @import("misc.zig");
const tagged = @import("tagged.zig");

/// Every point a handler can answer. Each name states a call site, so the set stays closed.
/// A fact reads as `x.verbed` and needs no answer; a point reads as `x.verb` and waits for one.
pub const Point = enum {
    /// Once per run, before the first round opens.
    @"run.before",
    /// Once per round, over the neutral request the serializer has not read yet.
    @"request.build",
    /// Once per round, over the serialized body and its headers.
    @"request.send",
    /// Before the process runs one tool the model chose.
    @"tool.before",
    /// After that tool answers, over the output the model will read.
    @"tool.after",
    /// Before one user input reaches the queue.
    @"input.before",

    /// Report the wire name, which is the point itself.
    pub fn wireName(self: Point) []const u8 {
        return @tagName(self);
    }

    /// Read one point from its wire name, or null when the set holds no such point.
    pub fn parse(name: []const u8) ?Point {
        return std.meta.stringToEnum(Point, name);
    }
};

/// What one handler answers. A chain folds `replace` and stops at the first `block`.
pub const Decision = union(enum) {
    /// The handler changes nothing, so the next handler reads the same value.
    proceed: misc.Empty,
    /// The payload the next handler reads instead. Its shape matches the point.
    replace: std.json.Value,
    /// The action never runs, and the reason reaches the model in place of a result.
    block: Blocked,

    pub fn jsonParse(a: std.mem.Allocator, s: anytype, o: std.json.ParseOptions) !@This() {
        return tagged.jsonParse(@This(), a, s, o);
    }
    pub fn jsonParseFromValue(a: std.mem.Allocator, v: std.json.Value, o: std.json.ParseOptions) !@This() {
        return tagged.fromValue(@This(), a, v, o);
    }
    pub fn jsonStringify(self: @This(), jw: *std.json.Stringify) !void {
        return tagged.stringify(@This(), self, jw);
    }
};

pub const Blocked = struct {
    reason: []const u8,
};

const testing = std.testing;

test "a point reads back from the name it writes" {
    for (std.meta.tags(Point)) |point| {
        try testing.expectEqual(point, Point.parse(point.wireName()).?);
        // A point must never read as a fact, because the two registries carry different promises.
        try testing.expect(!std.mem.endsWith(u8, point.wireName(), "ed"));
    }
    try testing.expectEqual(@as(?Point, null), Point.parse("tool.started"));
}

test "a decision uses the tagged wire shape" {
    const blocked = try std.json.parseFromSlice(Decision, testing.allocator,
        \\{"type":"block","reason":"denied"}
    , .{});
    defer blocked.deinit();
    try testing.expectEqualStrings("denied", blocked.value.block.reason);

    const proceed = try std.json.parseFromSlice(Decision, testing.allocator,
        \\{"type":"proceed"}
    , .{});
    defer proceed.deinit();
    try testing.expect(proceed.value == .proceed);
}

test "a decision rejects an unknown arm" {
    try testing.expectError(error.InvalidEnumTag, std.json.parseFromSlice(Decision, testing.allocator,
        \\{"type":"retry"}
    , .{}));
}
