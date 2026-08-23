//! Protocol enumerations and capability sets.

const std = @import("std");

/// Authentication flow kind.
pub const AuthFlow = enum { browser, device_code };

/// Authentication credential kind.
pub const AuthCredentialKind = enum { api_key, oauth };

/// Broadcast event name.
pub const BroadcastName = enum {
    @"session.summary_changed",
    @"session.activity_changed",
    @"session.removed",
    @"workspace.created",
    @"workspace.removed",
    @"permission.rules_changed",
    @"catalog.changed",
    @"auth.login_finished",
    @"auth.changed",
    @"cron.created",
    @"cron.updated",
    @"cron.removed",
    notice,
    @"message.committed",
    @"run.started",
    @"run.done",
    @"config.changed",
    @"transcript.truncated",
    @"message.started",
    @"message.discarded",
    @"message.part_added",
    @"message.part_delta",
    @"tool.state_changed",
    @"tool.output_delta",
    @"input.queued",
    @"input.canceled",
    @"session.deltas_shed",
};

/// Run failure category.
pub const RunErrorCode = enum {
    provider,
    protocol,
    network,
    timeout,
    rate_limited,
    quota_exhausted,
    auth,
    unknown_model,
    unsupported_reasoning,
    max_rounds,
    context_overflow,
    runtime,
    internal,
};

/// Cron job retention policy.
pub const CronRetain = enum { always, on_failure, never };

/// Cron schedule overlap policy.
pub const CronOverlap = enum { skip, parallel };

/// Policy for a missed cron schedule.
pub const CronMissedPolicy = enum { skip, run_once };

/// Cron run outcome.
pub const CronRunOutcome = enum { completed, canceled, failed, dispatch_failed };

/// RPC method name.
pub const MethodName = enum {
    initialize,
    @"session.list",
    @"session.create",
    @"session.patch",
    @"session.remove",
    @"session.fork",
    @"session.compact",
    @"session.rewind",
    @"session.send_input",
    @"session.cancel_input",
    @"session.cancel_run",
    @"session.resync",
    @"session.history",
    @"permission.decide",
    @"session.config",
    @"subscription.set",
    @"catalog.list",
    @"catalog.refresh",
    @"auth.list",
    @"auth.set_api_key",
    @"auth.login",
    @"auth.cancel_login",
    @"auth.logout",
    @"workspace.describe",
    @"workspace.browse",
    @"workspace.remove",
    @"workspace.skills",
    @"permission.rules",
    @"permission.forget",
    @"cron.create",
    @"cron.patch",
    @"cron.remove",
    @"cron.list",
    @"cron.run_now",
};

/// Notice severity level.
pub const NoticeLevel = enum { info, warn, @"error" };

/// Permission option kind.
pub const PermissionOptionKind = enum {
    allow_once,
    allow_session,
    allow_always,
    reject_once,
    reject_always,
};

/// Authority that decided a permission request.
pub const DeniedBy = enum { user, policy };

/// Permission rule action.
pub const RuleAction = enum { allow, deny };

/// Run kind.
pub const RunKind = enum { turn, compaction };

/// Reason compaction was skipped.
pub const CompactSkipReason = enum { nothing_to_summarize, too_few_messages };

/// Assistant stop reason.
pub const StopReason = enum { stop, length, content_filter, tool_calls, canceled, @"error", unknown };

/// Compaction status.
pub const CompactStatus = enum { started, queued };

/// Permission enforcement mode.
pub const PermissionMode = enum { strict, normal, yolo };

/// Session list view.
pub const SessionView = enum { active, recent, active_recent };

/// Reason for compaction.
pub const CompactionReason = enum { auto, manual };

/// Provider protocol kind.
pub const ProviderProtocol = enum { @"anthropic-messages", @"openai-completions", @"openai-responses" };

/// Skill scope.
pub const SkillScope = enum { project, personal };

/// Workspace execution environment.
pub const WorkspaceKind = enum { local, container, cloud };

/// Advertised daemon capability.
pub const Capability = enum { blob_upload };

/// Numeric JSON-RPC and yuke error code.
pub const ErrorCode = enum(i32) {
    bad_request = -32602,
    bad_protocol = -32600,
    unknown_method = -32601,
    unknown_session = -31000,
    unknown_workspace = -31001,
    stale_cursor = -31002,
    unknown_message = -31003,
    unknown_part = -31004,
    unknown_input = -31005,
    unknown_config_rev = -31006,
    unknown_job = -31007,
    job_busy = -31008,
    unknown_skill = -31009,
    input_already_started = -31010,
    queue_full = -31011,
    run_mismatch = -31012,
    permission_unknown = -31013,
    permission_already_decided = -31014,
    session_busy = -31015,
    session_has_children = -31016,
    runtime_failed = -31017,
    invalid_patch = -31018,
    unsupported_model = -31019,
    unsupported_reasoning = -31020,
    internal = -32603,
    overloaded = -31021,

    /// Decode an error code from JSON.
    pub fn jsonParse(a: std.mem.Allocator, s: anytype, o: std.json.ParseOptions) !@This() {
        const v = try std.json.Value.jsonParse(a, s, o);
        return jsonParseFromValue(a, v, o);
    }

    pub fn jsonParseFromValue(a: std.mem.Allocator, v: std.json.Value, o: std.json.ParseOptions) !@This() {
        _ = a;
        _ = o;
        const n = switch (v) {
            .integer => |n| n,
            else => return error.UnexpectedToken,
        };
        return std.enums.fromInt(@This(), n) orelse error.InvalidEnumTag;
    }

    pub fn jsonStringify(self: @This(), jw: *std.json.Stringify) !void {
        try jw.write(@intFromEnum(self));
    }
};

/// A set of advertised capabilities; unknown tokens are ignored on decode.
pub const CapabilitySet = struct {
    set: std.EnumSet(Capability) = std.EnumSet(Capability).empty,

    /// Decode advertised capabilities from JSON.
    pub fn jsonParse(a: std.mem.Allocator, s: anytype, o: std.json.ParseOptions) !@This() {
        const v = try std.json.Value.jsonParse(a, s, o);
        return jsonParseFromValue(a, v, o);
    }

    pub fn jsonParseFromValue(a: std.mem.Allocator, v: std.json.Value, o: std.json.ParseOptions) !@This() {
        _ = a;
        _ = o;
        const arr = switch (v) {
            .array => |arr| arr,
            else => return error.UnexpectedToken,
        };
        var out: @This() = .{};
        for (arr.items) |item| {
            const token = switch (item) {
                .string => |token| token,
                else => return error.UnexpectedToken,
            };
            if (std.meta.stringToEnum(Capability, token)) |cap| out.set.insert(cap);
        }
        return out;
    }

    pub fn jsonStringify(self: @This(), jw: *std.json.Stringify) !void {
        try jw.beginArray();
        var it = self.set.iterator();
        while (it.next()) |cap| try jw.write(@tagName(cap));
        try jw.endArray();
    }
};

const testing = std.testing;

test "strict enum decodes wire string" {
    const parsed = try std.json.parseFromSlice(NoticeLevel, testing.allocator,
        \\"warn"
    , .{});
    defer parsed.deinit();
    try testing.expectEqual(NoticeLevel.warn, parsed.value);
}

test "strict enum rejects unknown value" {
    try testing.expectError(error.InvalidEnumTag, std.json.parseFromSlice(NoticeLevel, testing.allocator,
        \\"catastrophe"
    , .{}));
}

test "dotted wire string round-trips" {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try std.json.Stringify.value(MethodName.@"session.send_input", .{}, &buf.writer);
    try testing.expectEqualStrings(
        \\"session.send_input"
    , buf.written());
}

test "numeric enum round-trips as an integer" {
    const parsed = try std.json.parseFromSlice(ErrorCode, testing.allocator,
        \\-31000
    , .{});
    defer parsed.deinit();
    try testing.expectEqual(ErrorCode.unknown_session, parsed.value);

    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try std.json.Stringify.value(ErrorCode.unknown_session, .{}, &buf.writer);
    try testing.expectEqualStrings("-31000", buf.written());
}

test "numeric enum rejects unknown code" {
    try testing.expectError(error.InvalidEnumTag, std.json.parseFromSlice(ErrorCode, testing.allocator,
        \\-99999
    , .{}));
}

test "tolerant set keeps known, skips unknown" {
    const parsed = try std.json.parseFromSlice(CapabilitySet, testing.allocator,
        \\["blob_upload","future_capability"]
    , .{});
    defer parsed.deinit();
    try testing.expect(parsed.value.set.contains(.blob_upload));
    try testing.expectEqual(@as(usize, 1), parsed.value.set.count());
}
