//! Session requests, results, and lifecycle state.

const std = @import("std");
const activity = @import("activity.zig");
const enums = @import("enums.zig");
const ids = @import("ids.zig");
const input = @import("input.zig");
const message = @import("message.zig");
const misc = @import("misc.zig");
const run = @import("run.zig");
const tagged = @import("tagged.zig");

/// Coarse live session state.
pub const SessionActivity = struct {
    state: activity.ActivityState,
    config: ?run.RunConfig = null,
    queued: u64,
    context_usage: message.TokenUsage,
    pending_compaction: ?ids.RunId = null,
};

/// This payload describes `session.activity_changed`.
pub const SessionActivityChangedData = struct {
    session_id: ids.SessionId,
    activity: SessionActivity,
};

/// These are the parameters for `session.cancel_input`.
pub const SessionCancelInputParams = struct {
    session_id: ids.SessionId,
    input_id: ids.InputId,
};

/// This result identifies the canceled input.
pub const SessionCancelInputResult = struct {
    canceled_input: ids.InputId,
};

/// These are the parameters for `session.cancel_run`.
pub const SessionCancelRunParams = struct {
    session_id: ids.SessionId,
    run_id: ?ids.RunId = null,
    clear_queue: ?bool = null,
};

/// This result identifies the canceled run and cleared inputs.
pub const SessionCancelRunResult = struct {
    canceled_run: ?ids.RunId = null,
    cleared_inputs: []const ids.InputId,
    cleared_compaction: ?ids.RunId = null,
};

/// These are the parameters for `session.compact`.
pub const SessionCompactParams = struct {
    session_id: ids.SessionId,
};

/// This result describes `session.compact`.
pub const SessionCompactResult = struct {
    status: enums.CompactStatus,
    run_id: ids.RunId,
};

/// These are the parameters for `session.config.get`.
pub const SessionConfigParams = struct {
    session_id: ids.SessionId,
    config_rev: ?ids.ConfigRev = null,
};

/// This result describes `session.config.get`.
pub const SessionConfigResult = struct {
    config: run.RunConfig,
    system_prompt: ?[]const u8 = null,
};

/// These are the parameters for `session.fork`.
pub const SessionForkParams = struct {
    session_id: ids.SessionId,
    before_message_id: ?ids.MessageId = null,
};

/// These are the parameters for `session.history`.
pub const SessionHistoryParams = struct {
    session_id: ids.SessionId,
    before_message_id: ids.MessageId,
    limit: ?u64 = null,
};

/// This result describes `session.history`.
pub const SessionHistoryResult = struct {
    session_id: ids.SessionId,
    messages: []const message.Message,
    configs: []const run.RunConfig,
    has_more: bool,
};

/// These are the parameters for `session.get`.
pub const SessionGetParams = struct {
    session_id: ids.SessionId,
    /// Select a direct child of session_id by name.
    child_name: ?[]const u8 = null,
};

/// This row summarizes a session for `session.list`, `session.get`, and session broadcasts. Its fields borrow their data.
pub const SessionListItem = struct {
    session: misc.Session,
    activity: SessionActivity,
    /// The outcome of the latest terminal turn; the engine reports it for a child.
    last_run: ?run.RunOutcome = null,
};

/// These are the `session.list` input fields. They borrow their data.
pub const SessionListParams = struct {
    population: SessionPopulation = .top_level,
    view: enums.SessionView = .active_recent,
    limit: ?u64 = null,
    cursor: ?[]const u8 = null,
};

/// This result contains one bounded `session.list` page. Its fields borrow their data.
pub const SessionListResult = struct {
    revision: ids.SessionRevision,
    items: []const SessionListItem,
    next_cursor: ?[]const u8 = null,
    total: u64,
};

/// This union records how the engine created the session.
pub const SessionOrigin = union(enum) {
    root: SessionOriginRoot,
    child: SessionOriginChild,
    fork: SessionOriginFork,

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

/// This origin links a session to its parent session and message part.
pub const SessionOriginChild = struct {
    site: input.ToolSite,
};

/// This origin links a session to its source session.
pub const SessionOriginFork = struct {
    source_id: ids.SessionId,
};

/// This origin marks a user-created root session.
pub const SessionOriginRoot = struct {};

/// An absent field leaves the current value unchanged. The engine stores the system prompt at creation.
/// The system prompt remains fixed, and the fields borrow their data.
pub const SessionPatch = struct {
    model: ?[]const u8 = null,
    reasoning: ?[]const u8 = null,
    max_rounds: ?u64 = null,
};

/// These are the parameters for `session.patch`.
pub const SessionPatchParams = struct {
    session_id: ids.SessionId,
    patch: SessionPatch,
};

/// This union selects the session relationships that `session.list` returns.
pub const SessionPopulation = union(enum) {
    top_level: SessionPopulationTopLevel,
    children: SessionPopulationChildren,
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

/// This option selects every session regardless of origin.
pub const SessionPopulationAll = struct {};

/// This option selects the immediate persistent children of one session.
pub const SessionPopulationChildren = struct {
    parent_id: ids.SessionId,
};

/// This option selects root sessions and forks for user-facing conversations.
pub const SessionPopulationTopLevel = struct {};

/// These are the parameters for `session.queue`.
pub const SessionQueueParams = struct {
    session_id: ids.SessionId,
};

/// This result lists the queued inputs of one session, oldest first.
pub const SessionQueueResult = struct {
    items: []const misc.QueuedInput,
};

/// These are the parameters for `session.remove`.
pub const SessionRemoveParams = struct {
    session_id: ids.SessionId,
    cascade_children: bool = false,
};

/// This payload describes `session.removed`.
pub const SessionRemovedData = struct {
    revision: ids.SessionRevision,
    session_id: ids.SessionId,
};

/// This result contains the session after creation, a fork, or a patch.
pub const SessionResult = struct {
    session: misc.Session,
    input: ?SessionSendInputResult = null,
};

/// The live parent tool site and the stable name of a new child.
pub const ChildSession = struct {
    slot: @import("agents.zig").AgentModelSlot,
    site: input.ToolSite,
    name: []const u8,
};

pub const ChildCapacity = struct {
    active: u64,
    limit: u64,
};

pub const InputQueueReason = enum { session_busy, concurrency_limit };

/// These are the parameters for `session.rewind`.
pub const SessionRewindParams = struct {
    session_id: ids.SessionId,
    before_message_id: ids.MessageId,
};

/// These are the parameters for `session.send_input`.
pub const SessionSendInputParams = struct {
    parent_tool: ?input.ToolSite = null,
    session_id: ids.SessionId,
    input: input.Input,
};

/// This result says whether the engine started or queued the input.
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

/// The engine queued the input behind an active turn.
pub const SessionSendInputResultQueued = struct {
    input_id: ids.InputId,
    reason: InputQueueReason,
    capacity: ?ChildCapacity = null,
};

/// The engine started the input immediately.
pub const SessionSendInputResultStarted = struct {
    input_id: ids.InputId,
    run_id: ids.RunId,
    capacity: ?ChildCapacity = null,
};

/// This payload describes `session.summary_changed`.
pub const SessionSummaryChangedData = struct {
    revision: ids.SessionRevision,
    session: misc.Session,
};

const testing = std.testing;
const opts: std.json.ParseOptions = .{ .ignore_unknown_fields = true };

test "session population round-trips" {
    const json =
        \\{"type":"children","parent_id":"abababababababababababababababab"}
    ;
    const parsed = try std.json.parseFromSlice(SessionPopulation, testing.allocator, json, opts);
    defer parsed.deinit();
    try testing.expect(parsed.value == .children);
    try testing.expectEqual([_]u8{0xab} ** 16, parsed.value.children.parent_id.raw);

    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try std.json.Stringify.value(parsed.value, .{ .emit_null_optional_fields = false }, &buf.writer);
    try testing.expectEqualStrings(json, buf.written());
}

test "queued admission requires a closed reason and preserves capacity" {
    const json = "{\"type\":\"queued\",\"input_id\":1,\"reason\":\"concurrency_limit\",\"capacity\":{\"active\":2,\"limit\":2}}";
    const parsed = try std.json.parseFromSlice(SessionSendInputResult, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(InputQueueReason.concurrency_limit, parsed.value.queued.reason);
    const written = try std.json.Stringify.valueAlloc(std.testing.allocator, parsed.value, .{});
    defer std.testing.allocator.free(written);
    try std.testing.expectEqualStrings(json, written);
    try std.testing.expectError(error.MissingField, std.json.parseFromSlice(SessionSendInputResult, std.testing.allocator, "{\"type\":\"queued\",\"input_id\":1}", .{}));
    try std.testing.expectError(error.InvalidEnumTag, std.json.parseFromSlice(SessionSendInputResult, std.testing.allocator, "{\"type\":\"queued\",\"input_id\":1,\"reason\":\"unknown\"}", .{}));
}

test "a child requires a closed explicit slot on the wire" {
    const a = std.testing.allocator;
    for ([_][]const u8{ "", ",\"slot\":null", ",\"slot\":\"large\"", ",\"slot\":\"provider/model\"" }) |suffix| {
        const json = try std.fmt.allocPrint(a, "{{\"parent_id\":\"01010101010101010101010101010101\",\"parent_message_id\":2,\"parent_part_id\":0,\"name\":\"one\"{s}}}", .{suffix});
        defer a.free(json);
        if (std.json.parseFromSlice(ChildSession, a, json, .{})) |parsed| {
            parsed.deinit();
            return error.AcceptedInvalidChildSlot;
        } else |_| {}
    }
}
