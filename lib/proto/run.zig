//! Run configuration, outcomes, and lifecycle updates.

const std = @import("std");
const ids = @import("ids.zig");
const enums = @import("enums.zig");
const tagged = @import("tagged.zig");

/// This type records run start and end times. The engine records no start time when a queued run never starts.
pub const RunCanceledTiming = struct {
    started_at_ms: ?u64 = null,
    ended_at_ms: u64,
};

/// The engine saves these run settings at run start.
pub const RunConfig = struct {
    config_rev: ids.ConfigRev,
    model: []const u8,
    reasoning: []const u8,
    /// A null value means the run has no round limit.
    max_rounds: ?u64 = null,
};

/// This payload describes `run.done`.
pub const RunDoneData = struct {
    session_id: ids.SessionId,
    seq: ids.Seq,
    run_id: ids.RunId,
    kind: enums.RunKind,
    timing: RunCanceledTiming,
    outcome: RunOutcome,
};

/// This union describes the terminal run outcome. The `type` field selects the outcome.
pub const RunOutcome = union(enum) {
    turn: RunOutcomeTurn,
    compacted: RunOutcomeCompacted,
    skipped: RunOutcomeSkipped,
    canceled: RunOutcomeCanceled,
    failed: RunOutcomeFailed,

    /// Decode a tagged wire union from JSON.
    pub const jsonParse = tagged.Codec(@This()).jsonParse;
    pub const jsonParseFromValue = tagged.Codec(@This()).jsonParseFromValue;
    pub const jsonStringify = tagged.Codec(@This()).jsonStringify;
};

/// The user or engine canceled the run. The terminal envelope carries its timing.
pub const RunOutcomeCanceled = struct {};

/// The engine completed a manual compaction and produced a summary.
pub const RunOutcomeCompacted = struct {
    message_id: ids.MessageId,
};

/// The engine reports failure after it exhausts its retry policy.
pub const RunOutcomeFailed = struct {
    code: enums.RunErrorCode,
    message: []const u8,
    /// The HTTP status of the provider answer, when the failure came from one.
    status: ?u16 = null,
    /// The provider request id, when the answer named one.
    request_id: ?[]const u8 = null,
    /// A bounded, control-free excerpt of the provider error, at most 512 bytes.
    detail: ?[]const u8 = null,
};

/// The engine skipped a manual compaction without producing a summary.
pub const RunOutcomeSkipped = struct {
    reason: enums.CompactSkipReason,
};

/// The engine completed a turn after some round trips and recorded its stop reason.
pub const RunOutcomeTurn = struct {
    finish: enums.StopReason,
    rounds: u64,
};

/// This payload describes `run.started`.
pub const RunStartedData = struct {
    session_id: ids.SessionId,
    seq: ids.Seq,
    run_id: ids.RunId,
    kind: enums.RunKind,
    reason: ?enums.CompactionReason = null,
    config_rev: ids.ConfigRev,
    started_at_ms: u64,
};

const testing = std.testing;
const opts: std.json.ParseOptions = .{ .ignore_unknown_fields = true };

test "interrupted is a closed run failure category" {
    const json = "{\"type\":\"failed\",\"code\":\"interrupted\",\"message\":\"the engine stopped\"}";
    const parsed = try std.json.parseFromSlice(RunOutcome, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expectEqual(enums.RunErrorCode.interrupted, parsed.value.failed.code);
    const encoded = try std.json.Stringify.valueAlloc(testing.allocator, parsed.value, .{ .emit_null_optional_fields = false });
    defer testing.allocator.free(encoded);
    try testing.expectEqualStrings(json, encoded);
    try testing.expectError(error.InvalidEnumTag, std.json.parseFromSlice(RunOutcome, testing.allocator, "{\"type\":\"failed\",\"code\":\"unknown_failure\",\"message\":\"x\"}", .{}));
}
