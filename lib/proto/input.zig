//! User input payloads and lifecycle updates.

const std = @import("std");
const content = @import("content.zig");
const ids = @import("ids.zig");
const message = @import("message.zig");
const misc = @import("misc.zig");
const tagged = @import("tagged.zig");
const run = @import("run.zig");
const enums = @import("enums.zig");

/// This type accepts raw content or a skill invocation. Its fields borrow their data.
pub const Input = union(enum) {
    content: InputContent,
    skill: InputSkill,

    /// Decode a tagged wire union from JSON.
    pub const jsonParse = tagged.Codec(@This()).jsonParse;
    pub const jsonParseFromValue = tagged.Codec(@This()).jsonParseFromValue;
    pub const jsonStringify = tagged.Codec(@This()).jsonStringify;
};

/// Native code assigns this source; public input has no source field.
pub const InputSource = union(enum) {
    parent_instruction: ToolSite,
    child_report: ChildReport,
    job_ended: JobEnded,
    engine_interruption: EngineInterruption,

    pub fn protected(self: @This()) bool {
        return self != .parent_instruction;
    }

    pub const jsonParse = tagged.Codec(@This()).jsonParse;
    pub const jsonParseFromValue = tagged.Codec(@This()).jsonParseFromValue;
    pub const jsonStringify = tagged.Codec(@This()).jsonStringify;
};

/// One tool call: the session, the message, and the part that hold it.
pub const ToolSite = struct {
    session_id: ids.SessionId,
    message_id: ids.MessageId,
    part_id: ids.PartId,
};

/// The end of one child run, or of queued child input that a stop dropped before any run took it.
pub const ChildReport = struct {
    session_id: ids.SessionId,
    /// Null when a stop dropped the queued input and no run was active.
    run_id: ?ids.RunId = null,
    name: []const u8,
    outcome: run.RunOutcome,
    usage: ChildReportUsage,
};

/// This type sums the usage of the committed assistant messages in one child run.
pub const ChildReportUsage = struct {
    rounds: u64,
    tool_calls: u64,
    tokens: message.TokenUsage,
    duration_ms: u64,
};

/// The end of one background job. `exit_code` and `signal` stay null when the process wait failed.
pub const JobEnded = struct {
    job_id: ids.JobId,
    command: []const u8,
    exit_code: ?u8 = null,
    signal: ?u8 = null,
};

pub const EngineInterruption = struct {
    run_id: ids.RunId,
    kind: enums.RunKind,
};

/// This payload describes `input.canceled`.
pub const InputCanceledData = struct {
    session_id: ids.SessionId,
    seq: ids.Seq,
    input_id: ids.InputId,
};

/// Raw content parts.
pub const InputContent = struct {
    content: []const content.ContentPart,
};

/// This payload describes `input.queued`.
pub const InputQueuedData = struct {
    session_id: ids.SessionId,
    seq: ids.Seq,
    input: misc.QueuedInput,
};

/// This input names a skill. The engine loads the body and appends one user message.
pub const InputSkill = struct {
    name: []const u8,
    /// The engine appends this text after the body.
    arguments: ?[]const u8 = null,
};

const testing = std.testing;

test "a skill input needs a name and keeps its arguments optional" {
    const a = testing.allocator;
    const parsed = try std.json.parseFromSlice(Input, a, "{\"type\":\"skill\",\"name\":\"pdf\"}", .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("pdf", parsed.value.skill.name);
    try testing.expect(parsed.value.skill.arguments == null);
    const encoded = try std.json.Stringify.valueAlloc(a, parsed.value, .{ .emit_null_optional_fields = false });
    defer a.free(encoded);
    try testing.expectEqualStrings("{\"type\":\"skill\",\"name\":\"pdf\"}", encoded);
    try testing.expectError(error.MissingField, std.json.parseFromSlice(Input, a, "{\"type\":\"skill\",\"arguments\":\"x\"}", .{}));
    try testing.expectError(error.UnexpectedToken, std.json.parseFromSlice(Input, a, "{\"type\":\"skill\",\"name\":\"pdf\",\"arguments\":1}", .{}));
    try testing.expectError(error.InvalidEnumTag, std.json.parseFromSlice(Input, a, "{\"type\":\"template\",\"name\":\"pdf\"}", .{}));
}

test "input sources form a closed union outside public input" {
    const values = [_][]const u8{
        "{\"type\":\"parent_instruction\",\"session_id\":\"01010101010101010101010101010101\",\"message_id\":1,\"part_id\":0}",
        "{\"type\":\"child_report\",\"session_id\":\"01010101010101010101010101010101\",\"run_id\":2,\"name\":\"research\",\"outcome\":{\"type\":\"canceled\"},\"usage\":{\"rounds\":2,\"tool_calls\":1,\"tokens\":{\"input\":10,\"output\":5,\"reasoning\":0,\"cache_read\":0,\"cache_write\":0},\"duration_ms\":1500}}",
        "{\"type\":\"job_ended\",\"job_id\":50000,\"command\":\"npm run dev\",\"exit_code\":1}",
        "{\"type\":\"engine_interruption\",\"run_id\":5,\"kind\":\"turn\"}",
    };
    for (values, 0..) |text, i| {
        const parsed = try std.json.parseFromSlice(InputSource, testing.allocator, text, .{});
        defer parsed.deinit();
        try testing.expectEqual(i != 0, parsed.value.protected());
        const encoded = try std.json.Stringify.valueAlloc(testing.allocator, parsed.value, .{ .emit_null_optional_fields = false });
        defer testing.allocator.free(encoded);
        try testing.expectEqualStrings(text, encoded);
    }
    // A public input has no source field, so a client cannot claim an engine source.
    try testing.expectError(error.UnknownField, std.json.parseFromSlice(Input, testing.allocator, "{\"type\":\"content\",\"content\":[],\"source\":{\"type\":\"engine_interruption\",\"run_id\":1,\"kind\":\"turn\"}}", .{}));
    try testing.expectError(error.InvalidEnumTag, std.json.parseFromSlice(InputSource, testing.allocator, "{\"type\":\"other\"}", .{}));
    try testing.expectError(error.MissingField, std.json.parseFromSlice(InputSource, testing.allocator, "{\"type\":\"engine_interruption\",\"run_id\":1}", .{}));
}
