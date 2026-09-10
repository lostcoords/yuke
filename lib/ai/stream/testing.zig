//! The three protocol reducers share these assertions, so each suite states only its own protocol differences.

const std = @import("std");
const event = @import("event.zig");
const types = @import("../types.zig");

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
