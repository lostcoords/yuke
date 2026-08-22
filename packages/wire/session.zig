//! Session requests, results, and lifecycle state.

const std = @import("std");
const activity = @import("activity.zig");
const enums = @import("enums.zig");
const ids = @import("ids.zig");
const input = @import("input.zig");
const message = @import("message.zig");
const misc = @import("misc.zig");
const run = @import("run.zig");
const scope = @import("scope.zig");
const tagged = @import("tagged.zig");

/// Coarse live session state.
pub const SessionActivity = struct {
    state: activity.ActivityState,
    config: ?run.RunConfig = null,
    queued: u64,
    context_usage: message.TokenUsage,
    pending_compaction: ?ids.RunId = null,
};

/// Payload for `session.activity_changed`.
pub const SessionActivityChangedData = struct {
    session_id: ids.SessionId,
    activity: SessionActivity,
};

/// Params for `session.cancel_input`.
pub const SessionCancelInputParams = struct {
    session_id: ids.SessionId,
    input_id: ids.InputId,
};

/// Result of `session.cancel_input`.
pub const SessionCancelInputResult = struct {
    canceled_input: ids.InputId,
};

/// Params for `session.cancel_run`.
pub const SessionCancelRunParams = struct {
    session_id: ids.SessionId,
    run_id: ?ids.RunId = null,
    clear_queue: ?bool = null,
};

/// Result of `session.cancel_run`.
pub const SessionCancelRunResult = struct {
    canceled_run: ?ids.RunId = null,
    cleared_inputs: []const ids.InputId,
    cleared_compaction: ?ids.RunId = null,
};

/// session.compact input.
pub const SessionCompactParams = struct {
    session_id: ids.SessionId,
};

/// session.compact result.
pub const SessionCompactResult = struct {
    status: enums.CompactStatus,
    run_id: ids.RunId,
};

/// session.config.get input.
pub const SessionConfigParams = struct {
    session_id: ids.SessionId,
    config_rev: ?ids.ConfigRev = null,
};

/// session.config.get result.
pub const SessionConfigResult = struct {
    config: run.RunConfig,
    system_prompt: ?[]const u8 = null,
};

/// Advisory notice that this connection's live deltas were shed.
pub const SessionDeltasShedData = struct {
    session_id: ids.SessionId,
    count: u64,
};

/// session.fork input.
pub const SessionForkParams = struct {
    session_id: ids.SessionId,
    before_message_id: ?ids.MessageId = null,
};

/// session.history input.
pub const SessionHistoryParams = struct {
    session_id: ids.SessionId,
    before_message_id: ids.MessageId,
    limit: ?u64 = null,
};

/// session.history result.
pub const SessionHistoryResult = struct {
    session_id: ids.SessionId,
    messages: []const message.Message,
    configs: []const run.RunConfig,
    has_more: bool,
};

/// Compact session row for `session.list` and session broadcasts. Non-owning.
pub const SessionListItem = struct {
    session: misc.Session,
    activity: SessionActivity,
};

/// session.list input. Non-owning.
pub const SessionListParams = struct {
    scope: scope.SessionScope = .all,
    population: SessionPopulation = .top_level,
    view: enums.SessionView = .active_recent,
    limit: ?u64 = null,
    cursor: ?[]const u8 = null,
};

/// One bounded session.list page. Non-owning.
pub const SessionListResult = struct {
    revision: ids.SessionRevision,
    items: []const SessionListItem,
    next_cursor: ?[]const u8 = null,
    total: u64,
};

/// How a session was created.
pub const SessionOrigin = union(enum) {
    root: SessionOriginRoot,
    child: SessionOriginChild,
    fork: SessionOriginFork,
    cron: SessionOriginCron,

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

/// Child of another session.
pub const SessionOriginChild = struct {
    parent_id: ids.SessionId,
    parent_message_id: ids.MessageId,
    parent_part_id: ids.PartId,
};

/// Created by a cron job.
pub const SessionOriginCron = struct {
    job_id: ids.JobId,
};

/// Fork of another session.
pub const SessionOriginFork = struct {
    source_id: ids.SessionId,
};

/// User-created root session.
pub const SessionOriginRoot = struct {};

/// Missing field means no change. The system prompt is snapshotted at creation and is not patchable. Non-owning.
pub const SessionPatch = struct {
    model: ?[]const u8 = null,
    reasoning: ?[]const u8 = null,
    permission: ?enums.PermissionMode = null,
    max_rounds: ?u64 = null,
};

/// Params for `session.patch`.
pub const SessionPatchParams = struct {
    session_id: ids.SessionId,
    patch: SessionPatch,
};

/// Session relationship population searched by session.list.
pub const SessionPopulation = union(enum) {
    top_level: SessionPopulationTopLevel,
    children: SessionPopulationChildren,
    job_runs: SessionPopulationJobRuns,
    all: SessionPopulationAll,

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

/// Every session regardless of origin.
pub const SessionPopulationAll = struct {};

/// Immediate persistent children of one session.
pub const SessionPopulationChildren = struct {
    parent_id: ids.SessionId,
};

/// Sessions created by one cron job.
pub const SessionPopulationJobRuns = struct {
    job_id: ids.JobId,
};

/// User-facing conversations: root sessions and forks.
pub const SessionPopulationTopLevel = struct {};

/// Params for `session.remove`.
pub const SessionRemoveParams = struct {
    session_id: ids.SessionId,
    cascade_children: bool = false,
};

/// Payload for `session.removed`.
pub const SessionRemovedData = struct {
    revision: ids.SessionRevision,
    session_id: ids.SessionId,
};

/// Result of session creation, forking, or patching.
pub const SessionResult = struct {
    session: misc.Session,
};

/// session.resync input.
pub const SessionResyncParams = struct {
    session_id: ids.SessionId,
    limit: ?u64 = null,
};

/// Full session snapshot for reconnection. Non-owning.
pub const SessionResyncResult = struct {
    item: SessionListItem,
    base_seq: ids.Seq,
    highest_finalized_message_id: ?ids.MessageId = null,
    messages: []const message.Message,
    has_more: bool,
    configs: []const run.RunConfig,
    active: ?message.ActiveDraft = null,
    queued: []const misc.QueuedInput,
};

/// session.rewind input.
pub const SessionRewindParams = struct {
    session_id: ids.SessionId,
    before_message_id: ids.MessageId,
};

/// Params for `session.send_input`.
pub const SessionSendInputParams = struct {
    session_id: ids.SessionId,
    input: input.Input,
};

/// Result of `session.send_input`: started immediately or queued behind an active turn.
pub const SessionSendInputResult = union(enum) {
    started: SessionSendInputResultStarted,
    queued: SessionSendInputResultQueued,

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

/// Queued behind an active turn.
pub const SessionSendInputResultQueued = struct {
    input_id: ids.InputId,
};

/// Started immediately.
pub const SessionSendInputResultStarted = struct {
    input_id: ids.InputId,
    run_id: ids.RunId,
};

/// Payload for `session.summary_changed`.
pub const SessionSummaryChangedData = struct {
    revision: ids.SessionRevision,
    session: misc.Session,
};

const testing = std.testing;
const opts: std.json.ParseOptions = .{ .ignore_unknown_fields = true };

test "session population round-trips" {
    const json =
        \\{"type":"children","parent_id":"0123456789abcdef"}
    ;
    const parsed = try std.json.parseFromSlice(SessionPopulation, testing.allocator, json, opts);
    defer parsed.deinit();
    try testing.expect(parsed.value == .children);
    try testing.expectEqualStrings("0123456789abcdef", &parsed.value.children.parent_id);

    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try std.json.Stringify.value(parsed.value, .{ .emit_null_optional_fields = false }, &buf.writer);
    try testing.expectEqualStrings(json, buf.written());
}
