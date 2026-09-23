//! Session activity state updates.

const std = @import("std");
const ids = @import("ids.zig");
const enums = @import("enums.zig");
const tagged = @import("tagged.zig");

/// This state holds the locator fields that place the session in its transcript.
pub const ActivityState = union(enum) {
    idle: ActivityStateIdle,
    building: ActivityStateBuilding,
    waiting: ActivityStateWaiting,
    streaming: ActivityStateStreaming,
    reasoning: ActivityStateReasoning,
    running_tool: ActivityStateRunningTool,
    retrying: ActivityStateRetrying,
    compacting: ActivityStateCompacting,

    /// Decode a tagged wire union from JSON.
    pub const jsonParse = tagged.Codec(@This()).jsonParse;
    pub const jsonParseFromValue = tagged.Codec(@This()).jsonParseFromValue;
    pub const jsonStringify = tagged.Codec(@This()).jsonStringify;
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

/// This state marks an active tool call.
pub const ActivityStateRunningTool = struct {
    run_id: ids.RunId,
    message_id: ids.MessageId,
    part_id: ids.PartId,
    tool_name: []const u8,
    started_at_ms: u64,
};

/// The provider accepted the request in this state.
pub const ActivityStateStreaming = struct {
    run_id: ids.RunId,
    started_at_ms: u64,
};

/// The request is out and the provider has not answered in this state.
pub const ActivityStateWaiting = struct {
    run_id: ids.RunId,
    started_at_ms: u64,
};

const testing = std.testing;
const opts: std.json.ParseOptions = .{ .ignore_unknown_fields = true };
