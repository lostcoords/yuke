//! Run configuration, outcomes, and lifecycle updates.

const std = @import("std");
const ids = @import("ids.zig");
const enums = @import("enums.zig");
const tagged = @import("tagged.zig");

/// Cancellation timing; an accepted queued run may never start.
pub const RunCanceledTiming = struct {
    started_at_ms: ?u64 = null,
    ended_at_ms: u64,
};

/// Run settings captured at start.
pub const RunConfig = struct {
    config_rev: ids.ConfigRev,
    model: []const u8,
    reasoning: []const u8,
};

/// Payload for `run.done`.
pub const RunDoneData = struct {
    session_id: ids.SessionId,
    seq: ids.Seq,
    run_id: ids.RunId,
    kind: enums.RunKind,
    timing: RunCanceledTiming,
    outcome: RunOutcome,
};

/// Terminal outcome of a run, discriminated by `type`.
pub const RunOutcome = union(enum) {
    turn: RunOutcomeTurn,
    compacted: RunOutcomeCompacted,
    skipped: RunOutcomeSkipped,
    canceled: RunOutcomeCanceled,
    failed: RunOutcomeFailed,

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

/// A run canceled by the user or daemon. Its timing rides the terminal envelope.
pub const RunOutcomeCanceled = struct {};

/// A manual compaction that produced a summary.
pub const RunOutcomeCompacted = struct {
    message_id: ids.MessageId,
};

/// A run that failed after daemon retry policy was exhausted.
pub const RunOutcomeFailed = struct {
    code: enums.RunErrorCode,
    message: []const u8,
};

/// A manual compaction that did nothing.
pub const RunOutcomeSkipped = struct {
    reason: enums.CompactSkipReason,
};

/// A completed turn: it stopped for a stop reason after some round trips.
pub const RunOutcomeTurn = struct {
    finish: enums.StopReason,
    rounds: u64,
};

/// Payload for `run.started`.
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

test "run outcome failed round-trips" {
    const json =
        \\{"type":"failed","code":"timeout","message":"provider timed out"}
    ;
    const parsed = try std.json.parseFromSlice(RunOutcome, testing.allocator, json, opts);
    defer parsed.deinit();
    try testing.expect(parsed.value == .failed);
    try testing.expectEqual(enums.RunErrorCode.timeout, parsed.value.failed.code);

    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try std.json.Stringify.value(parsed.value, .{ .emit_null_optional_fields = false }, &buf.writer);
    try testing.expectEqualStrings(json, buf.written());
}
