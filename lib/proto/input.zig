//! User input payloads and lifecycle updates.

const std = @import("std");
const content = @import("content.zig");
const ids = @import("ids.zig");
const misc = @import("misc.zig");
const tagged = @import("tagged.zig");
const skill_mod = @import("skill.zig");

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

/// This type describes a skill invocation.
pub const InputSkill = struct {
    skill: skill_mod.SkillRef,
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

test "input queued data round-trips the durable seq" {
    const value: InputQueuedData = .{
        .session_id = .bytes(@splat(0)),
        .seq = 7,
        .input = .{ .input_id = 3, .content = &.{.{ .text = .{ .text = "hi" } }}, .queued_at_ms = 100 },
    };
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try std.json.Stringify.value(value, .{ .emit_null_optional_fields = false }, &buf.writer);
    const parsed = try std.json.parseFromSlice(InputQueuedData, testing.allocator, buf.written(), opts);
    defer parsed.deinit();
    try testing.expectEqual(@as(ids.Seq, 7), parsed.value.seq);
    try testing.expectEqual(@as(ids.InputId, 3), parsed.value.input.input_id);
}
