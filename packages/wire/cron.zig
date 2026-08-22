//! Cron scheduling, job, and run wire types.

const std = @import("std");
const ids = @import("ids.zig");
const enums = @import("enums.zig");
const tagged = @import("tagged.zig");
const misc = @import("misc.zig");
const input = @import("input.zig");

/// Params for `cron.create`.
pub const CronCreateParams = struct {
    spec: CronJobSpec,
};

/// Payload for `cron.created`.
pub const CronCreatedData = struct {
    revision: ids.CronRevision,
    job: CronJob,
};

/// A cron job record. Non-owning.
pub const CronJob = struct {
    id: ids.JobId,
    spec: CronJobSpec,
    enabled: bool,
    created_at_ms: u64,
    next_run_ms: ?u64 = null,
    last_run_ms: ?u64 = null,
    last_session_id: ?ids.SessionId = null,
    last_outcome: ?enums.CronRunOutcome = null,
    run_count: u64,
    dispatch_failures: u64,
};

/// Params identifying a cron job.
pub const CronJobRef = struct {
    job_id: ids.JobId,
};

/// Result of `cron.create` and `cron.patch`.
pub const CronJobResult = struct {
    job: CronJob,
};

/// Full spec for a cron job.
pub const CronJobSpec = struct {
    name: ?[]const u8 = null,
    schedule: CronSchedule,
    session: misc.CreateSession,
    retain: enums.CronRetain,
    input: input.Input,
    on_missed: enums.CronMissedPolicy,
    overlap: enums.CronOverlap,
    delete_after_run: bool,
};

/// Params for `cron.list`.
pub const CronListParams = struct {
    limit: ?u64 = null,
    cursor: ?[]const u8 = null,
};

/// Result of `cron.list`.
pub const CronListResult = struct {
    revision: ids.CronRevision,
    jobs: []const CronJob,
    next_cursor: ?[]const u8 = null,
};

/// Optional-field patch applied to an existing cron job.
pub const CronPatch = struct {
    name: ?[]const u8 = null,
    schedule: CronSchedule,
    session: ?misc.CreateSession = null,
    retain: ?enums.CronRetain = null,
    input: input.Input,
    on_missed: ?enums.CronMissedPolicy = null,
    overlap: ?enums.CronOverlap = null,
    delete_after_run: ?bool = null,
    enabled: ?bool = null,
};

/// Params for `cron.patch`.
pub const CronPatchParams = struct {
    job_id: ids.JobId,
    patch: CronPatch,
};

/// Payload for `cron.removed`.
pub const CronRemovedData = struct {
    revision: ids.CronRevision,
    job_id: ids.JobId,
};

/// Result of `cron.run_now`.
pub const CronRunNowResult = struct {
    session_id: ids.SessionId,
    run_id: ids.RunId,
};

/// A cron schedule: recurring or one-shot. Non-owning.
pub const CronSchedule = union(enum) {
    every: CronScheduleEvery,
    cron: CronScheduleCron,
    at: CronScheduleAt,
    after: CronScheduleAfter,

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

/// Delay-based cron schedule arm.
pub const CronScheduleAfter = struct {
    delay_ms: u64,
};

/// One-shot cron schedule arm.
pub const CronScheduleAt = struct {
    at_ms: u64,
};

/// Cron-expression schedule arm.
pub const CronScheduleCron = struct {
    expr: []const u8,
    utc_offset_minutes: i64,
};

/// Recurring-interval schedule arm.
pub const CronScheduleEvery = struct {
    interval_ms: u64,
};

/// Payload for `cron.updated`.
pub const CronUpdatedData = struct {
    revision: ids.CronRevision,
    job: CronJob,
};

const testing = std.testing;
const opts: std.json.ParseOptions = .{ .ignore_unknown_fields = true };

test "cron schedule union round-trips an every arm" {
    const json =
        \\{"type":"every","interval_ms":60000}
    ;
    const parsed = try std.json.parseFromSlice(CronSchedule, testing.allocator, json, opts);
    defer parsed.deinit();
    try testing.expect(parsed.value == .every);
    try testing.expectEqual(@as(u64, 60000), parsed.value.every.interval_ms);

    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try std.json.Stringify.value(parsed.value, .{ .emit_null_optional_fields = false }, &buf.writer);
    try testing.expectEqualStrings(json, buf.written());
}
