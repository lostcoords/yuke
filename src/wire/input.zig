//! User input payloads and lifecycle updates.

const std = @import("std");
const content = @import("content.zig");
const ids = @import("ids.zig");
const misc = @import("misc.zig");
const tagged = @import("tagged.zig");
const workspace = @import("workspace.zig");

/// A unit of user input: either raw content or a skill invocation. Non-owning.
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

/// Payload for `input.canceled`.
pub const InputCanceledData = struct {
    session_id: ids.SessionId,
    input_id: ids.InputId,
};

/// Raw content parts.
pub const InputContent = struct {
    content: []const content.ContentPart,
};

/// Payload for `input.queued`.
pub const InputQueuedData = struct {
    session_id: ids.SessionId,
    input: misc.QueuedInput,
};

/// Skill invocation.
pub const InputSkill = struct {
    skill: workspace.SkillRef,
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
