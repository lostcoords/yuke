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
        \\{"sessions":["0123456789abcdef","fedcba9876543210"]}
    , .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 2), parsed.value.sessions.len);
    try testing.expectEqualStrings("fedcba9876543210", &parsed.value.sessions[1]);
}

test "round-trip re-encodes ids as strings" {
    const p: SubscriptionSetParams = .{ .sessions = &.{"0123456789abcdef".*} };

    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try std.json.Stringify.value(p, .{}, &buf.writer);
    try testing.expectEqualStrings(
        \\{"sessions":["0123456789abcdef"]}
    , buf.written());
}
