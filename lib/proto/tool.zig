//! Tool execution state and updates.

const std = @import("std");
const ids = @import("ids.zig");
const tagged = @import("tagged.zig");
const view = @import("view.zig");

/// This union records a tool part's lifecycle state. Its fields borrow their data.
pub const ToolState = union(enum) {
    pending: ToolStatePending,
    running: ToolStateRunning,
    completed: ToolStateCompleted,
    @"error": ToolStateError,
    canceled: ToolStateCanceled,

    /// Decode a tagged wire union from JSON.
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

const no_agent_retry_suffix = " No agent was created, and the delegated task did not start. Do not retry setup or spawn another agent unless the user requests it. Continue without delegation if possible.";

pub const ToolCancellationReason = enum {
    setup_declined,
    setup_dismissed,

    pub fn modelText(self: @This()) []const u8 {
        return switch (self) {
            .setup_declined => "The user declined agent model setup." ++ no_agent_retry_suffix,
            .setup_dismissed => "Agent model setup was dismissed before completion." ++ no_agent_retry_suffix,
        };
    }
};

/// The user or engine canceled the call.
pub const ToolStateCanceled = struct {
    duration_ms: ?u64 = null,
    reason: ?ToolCancellationReason = null,
};

/// This payload describes `tool.state_changed`.
pub const ToolStateChangedData = struct {
    session_id: ids.SessionId,
    message_id: ids.MessageId,
    part_id: ids.PartId,
    state: ToolState,
};

/// The tool call completed successfully.
pub const ToolStateCompleted = struct {
    output: []const u8,
    view: ?[]const view.View = null,
    duration_ms: u64,
};

/// The tool call failed.
pub const ToolStateError = struct {
    @"error": []const u8,
    view: ?[]const view.View = null,
    duration_ms: u64,
};

/// The tool call has not started.
pub const ToolStatePending = struct {};

/// The tool call is active.
pub const ToolStateRunning = struct {
    started_at_ms: u64,
    output: ?[]const u8 = null,
};

const testing = std.testing;
const opts: std.json.ParseOptions = .{ .ignore_unknown_fields = true };

test "tool state running preserves an optional output" {
    const json =
        \\{"type":"running","started_at_ms":100,"output":"partial"}
    ;
    const parsed = try std.json.parseFromSlice(ToolState, testing.allocator, json, opts);
    defer parsed.deinit();
    try testing.expect(parsed.value == .running);
    try testing.expectEqualStrings("partial", parsed.value.running.output.?);

    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try std.json.Stringify.value(parsed.value, .{ .emit_null_optional_fields = false }, &buf.writer);
    try testing.expectEqualStrings(json, buf.written());
}

test "tool cancellation reasons are closed and optional" {
    const parsed = try std.json.parseFromSlice(ToolState, testing.allocator, "{\"type\":\"canceled\",\"reason\":\"setup_declined\"}", .{});
    defer parsed.deinit();
    try testing.expectEqual(ToolCancellationReason.setup_declined, parsed.value.canceled.reason.?);
    const dismissed = try std.json.parseFromSlice(ToolState, testing.allocator, "{\"type\":\"canceled\",\"reason\":\"setup_dismissed\"}", .{});
    defer dismissed.deinit();
    try testing.expectEqual(ToolCancellationReason.setup_dismissed, dismissed.value.canceled.reason.?);
    const legacy = try std.json.parseFromSlice(ToolState, testing.allocator, "{\"type\":\"canceled\"}", .{});
    defer legacy.deinit();
    try testing.expectEqual(null, legacy.value.canceled.reason);
    try testing.expectError(error.InvalidEnumTag, std.json.parseFromSlice(ToolState, testing.allocator, "{\"type\":\"canceled\",\"reason\":\"other\"}", .{}));
}
