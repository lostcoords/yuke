//! Tool execution state and updates.

const std = @import("std");
const ids = @import("ids.zig");
const content = @import("content.zig");
const tagged = @import("tagged.zig");

/// This union records a tool part's lifecycle state. Its fields borrow their data.
pub const ToolState = union(enum) {
    pending: ToolStatePending,
    running: ToolStateRunning,
    completed: ToolStateCompleted,
    @"error": ToolStateError,
    canceled: ToolStateCanceled,

    /// Decode a tagged wire union from JSON.
    pub const jsonParse = tagged.Codec(@This()).jsonParse;
    pub const jsonParseFromValue = tagged.Codec(@This()).jsonParseFromValue;
    pub const jsonStringify = tagged.Codec(@This()).jsonStringify;

    /// The images a completed call carries. Every other state carries none.
    pub fn media(self: ToolState) []const content.MediaBlob {
        return switch (self) {
            .completed => |c| c.media,
            else => &.{},
        };
    }
};

/// The user or engine canceled the call.
pub const ToolStateCanceled = struct {
    duration_ms: ?u64 = null,
};

/// This payload describes `tool.state_changed`.
pub const ToolStateChangedData = struct {
    session_id: ids.SessionId,
    message_id: ids.MessageId,
    part_id: ids.PartId,
    state: ToolState,
};

/// The tool call completed successfully.
pub const ToolStateCompleted = struct {
    output: []const u8,
    /// The file changes the UI shows. The model never reads them.
    diff: []const DiffFile = &.{},
    /// Images the model reads beside the output. The engine admitted each blob at the tool boundary.
    media: []const content.MediaBlob = &.{},
    /// The definitions a tool search loaded. The transcript keeps them, so replay never reads the live catalog.
    tools_added: []const ToolDefinition = &.{},
    duration_ms: u64,
};

/// One changed file. Its hunks hold unified diff lines.
pub const DiffFile = struct {
    path: []const u8,
    hunks: []const DiffHunk,
};

/// One hunk of a unified diff.
pub const DiffHunk = struct {
    old_start: u64,
    old_lines: u64,
    new_start: u64,
    new_lines: u64,
    lines: []const []const u8,
};

/// One tool definition as a search loaded it. `input_schema` is the JSON Schema text of the arguments.
pub const ToolDefinition = struct {
    name: []const u8,
    description: []const u8,
    input_schema: []const u8,
};

/// The tool call failed.
pub const ToolStateError = struct {
    @"error": []const u8,
    duration_ms: u64,
};

/// The tool call has not started.
pub const ToolStatePending = struct {};

/// The tool call is active.
pub const ToolStateRunning = struct {
    started_at_ms: u64,
    output: []const u8 = "",
};

const testing = std.testing;

test "tool state completed keeps its media and omits each empty default" {
    // An absent list or output decodes to its empty default, and the empty default encodes as absent.
    for ([_][]const u8{ "{\"type\":\"completed\",\"output\":\"ok\",\"duration_ms\":3}", "{\"type\":\"running\",\"started_at_ms\":1}" }) |bare| {
        const plain = try std.json.parseFromSlice(ToolState, testing.allocator, bare, .{});
        defer plain.deinit();
        var plain_buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer plain_buf.deinit();
        try std.json.Stringify.value(plain.value, .{ .emit_null_optional_fields = false }, &plain_buf.writer);
        try testing.expectEqualStrings(bare, plain_buf.written());
    }

    const json =
        \\{"type":"completed","output":"PNG image, 12 B","media":[{"hash":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","mime":"image/png","bytes":12}],"duration_ms":3}
    ;
    const parsed = try std.json.parseFromSlice(ToolState, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("image/png", parsed.value.completed.media[0].mime);
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try std.json.Stringify.value(parsed.value, .{ .emit_null_optional_fields = false }, &buf.writer);
    try testing.expectEqualStrings(json, buf.written());
}
