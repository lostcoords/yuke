//! Session activity state updates.

const std = @import("std");
const ids = @import("ids.zig");
const enums = @import("enums.zig");
const tagged = @import("tagged.zig");

/// This state holds the locator fields that place the session in its transcript.
pub const ActivityState = union(enum) {
    idle: ActivityStateIdle,
    building: ActivityStateBuilding,
    running: ActivityStateRunning,
    reasoning: ActivityStateReasoning,
    running_tool: ActivityStateRunningTool,
    retrying: ActivityStateRetrying,
    compacting: ActivityStateCompacting,

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

/// This state marks the first phase of a run.
pub const ActivityStateBuilding = struct {
    run_id: ids.RunId,
    started_at_ms: u64,
};

/// This state marks an active compaction model call.
pub const ActivityStateCompacting = struct {
    run_id: ids.RunId,
    reason: enums.CompactionReason,
    started_at_ms: u64,
};

/// This state marks a session with no active work.
pub const ActivityStateIdle = struct {};

/// The model produces reasoning in this state.
pub const ActivityStateReasoning = struct {
    run_id: ids.RunId,
    message_id: ids.MessageId,
    part_id: ids.PartId,
};

/// This state marks a run that waits for a retry.
pub const ActivityStateRetrying = struct {
    run_id: ids.RunId,
    attempt: u64,
    max_attempts: u64,
    next_at_ms: u64,
    code: enums.RunErrorCode,
    message: []const u8,
};

/// This state marks an active run.
pub const ActivityStateRunning = struct {
    run_id: ids.RunId,
    started_at_ms: u64,
};

/// This state marks an active tool call.
pub const ActivityStateRunningTool = struct {
    run_id: ids.RunId,
    message_id: ids.MessageId,
    part_id: ids.PartId,
    tool_name: []const u8,
    started_at_ms: u64,
};

const testing = std.testing;
const opts: std.json.ParseOptions = .{ .ignore_unknown_fields = true };

test "activity state running_tool round-trips" {
    const json =
        \\{"type":"running_tool","run_id":7,"message_id":8,"part_id":9,"tool_name":"search","started_at_ms":100}
    ;
    const parsed = try std.json.parseFromSlice(ActivityState, testing.allocator, json, opts);
    defer parsed.deinit();
    try testing.expect(parsed.value == .running_tool);
    try testing.expectEqualStrings("search", parsed.value.running_tool.tool_name);

    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try std.json.Stringify.value(parsed.value, .{ .emit_null_optional_fields = false }, &buf.writer);
    try testing.expectEqualStrings(json, buf.written());
}
