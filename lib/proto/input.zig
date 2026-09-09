//! User input payloads and lifecycle updates.

const std = @import("std");
const content = @import("content.zig");
const ids = @import("ids.zig");
const message = @import("message.zig");
const misc = @import("misc.zig");
const tagged = @import("tagged.zig");

/// This type accepts raw content or a skill invocation. Its fields borrow their data.
pub const Input = union(enum) {
    content: InputContent,
    skill: InputSkill,

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

/// Native code assigns this source; public input has no source field.
pub const InputSource = union(enum) {
    parent_instruction: ToolSite,
    child_report: ChildReport,
    child_input_canceled: ChildInputCanceled,
    engine_interruption: EngineInterruption,

    pub fn protected(self: @This()) bool {
        return self != .parent_instruction;
    }

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

/// One tool call: the session, the message, and the part that hold it.
pub const ToolSite = struct {
    session_id: ids.SessionId,
    message_id: ids.MessageId,
    part_id: ids.PartId,
};

pub const ChildReport = struct {
    session_id: ids.SessionId,
    run_id: ids.RunId,
    name: []const u8,
    outcome: @import("run.zig").RunOutcome,
    partial: bool,
    truncated: bool,
    usage: ChildReportUsage,
};

/// This type sums the usage of the committed assistant messages in one child run.
pub const ChildReportUsage = struct {
    rounds: u64,
    tool_calls: u64,
    tokens: message.TokenUsage,
    duration_ms: ?u64 = null,
};

pub const ChildInputCanceled = struct {
    session_id: ids.SessionId,
    name: []const u8,
    input_ids: []const ids.InputId,
};

pub const EngineInterruption = struct {
    run_id: ids.RunId,
    kind: @import("enums.zig").RunKind,
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
const opts: std.json.ParseOptions = .{ .ignore_unknown_fields = true };

test "input content union round-trips" {
    const json =
        \\{"type":"content","content":[{"type":"text","text":"hello"}]}
    ;
    const parsed = try std.json.parseFromSlice(Input, testing.allocator, json, opts);
    defer parsed.deinit();
    try testing.expect(parsed.value == .content);
    try testing.expect(parsed.value.content.content[0] == .text);
    try testing.expectEqualStrings("hello", parsed.value.content.content[0].text.text);

    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try std.json.Stringify.value(parsed.value, .{ .emit_null_optional_fields = false }, &buf.writer);
    try testing.expectEqualStrings(json, buf.written());
}

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
        "{\"type\":\"child_report\",\"session_id\":\"01010101010101010101010101010101\",\"run_id\":2,\"name\":\"research\",\"outcome\":{\"type\":\"canceled\"},\"partial\":true,\"truncated\":false,\"usage\":{\"rounds\":2,\"tool_calls\":1,\"tokens\":{\"input\":10,\"output\":5,\"reasoning\":0,\"cache_read\":0,\"cache_write\":0},\"duration_ms\":null}}",
        "{\"type\":\"child_input_canceled\",\"session_id\":\"01010101010101010101010101010101\",\"name\":\"research\",\"input_ids\":[3,4]}",
        "{\"type\":\"engine_interruption\",\"run_id\":5,\"kind\":\"turn\"}",
    };
    for (values, 0..) |text, i| {
        const parsed = try std.json.parseFromSlice(InputSource, testing.allocator, text, .{});
        defer parsed.deinit();
        try testing.expectEqual(i != 0, parsed.value.protected());
        const encoded = try std.json.Stringify.valueAlloc(testing.allocator, parsed.value, .{});
        defer testing.allocator.free(encoded);
        try testing.expectEqualStrings(text, encoded);
    }
    const public = try std.json.parseFromSlice(Input, testing.allocator, "{\"type\":\"content\",\"content\":[],\"source\":{\"type\":\"engine_interruption\",\"run_id\":1,\"kind\":\"turn\"}}", .{});
    defer public.deinit();
    const encoded = try std.json.Stringify.valueAlloc(testing.allocator, public.value, .{});
    defer testing.allocator.free(encoded);
    try testing.expectEqualStrings("{\"type\":\"content\",\"content\":[]}", encoded);
    try testing.expectError(error.InvalidEnumTag, std.json.parseFromSlice(InputSource, testing.allocator, "{\"type\":\"other\"}", .{}));
    try testing.expectError(error.MissingField, std.json.parseFromSlice(InputSource, testing.allocator, "{\"type\":\"engine_interruption\",\"run_id\":1}", .{}));
}
