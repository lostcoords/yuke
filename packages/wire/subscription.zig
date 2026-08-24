//! Params for selecting sessions whose updates a connection receives.

const std = @import("std");
const ids = @import("ids.zig");

/// The sessions this connection wants live updates for.
pub const SubscriptionSetParams = struct {
    sessions: []const ids.SessionId,
};

const testing = std.testing;

test "decode array of fixed-hex ids" {
    const parsed = try std.json.parseFromSlice(SubscriptionSetParams, testing.allocator,
        \\{"sessions":["abababababababababababababababab","cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd"]}
    , .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 2), parsed.value.sessions.len);
    try testing.expectEqual([_]u8{0xcd} ** 16, parsed.value.sessions[1].bytes);
}

test "round-trip re-encodes ids as hex strings" {
    const p: SubscriptionSetParams = .{ .sessions = &.{.from(@splat(0xab))} };

    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try std.json.Stringify.value(p, .{}, &buf.writer);
    try testing.expectEqualStrings(
        \\{"sessions":["abababababababababababababababab"]}
    , buf.written());
}
