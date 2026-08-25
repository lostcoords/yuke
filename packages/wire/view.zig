//! Renderable views for tool output.

const std = @import("std");
const content = @import("content.zig");
const tagged = @import("tagged.zig");

/// This type describes one file in a diff view.
pub const DiffFile = struct {
    path: []const u8,
    old_path: ?[]const u8 = null,
    hunks: []const DiffHunk,
};

/// This type describes one hunk of a unified diff.
pub const DiffHunk = struct {
    old_start: u64,
    old_lines: u64,
    new_start: u64,
    new_lines: u64,
    lines: []const []const u8,
};

/// A frontend can render this hint natively or ignore it. Its fields borrow their data.
pub const View = union(enum) {
    text: ViewText,
    markdown: ViewMarkdown,
    json: ViewJson,
    diff: ViewDiff,
    image: ViewImage,

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

/// This view displays a unified diff.
pub const ViewDiff = struct {
    files: []const DiffFile,
};

/// This view displays an image.
pub const ViewImage = struct {
    source: content.MediaSource,
    alt: ?[]const u8 = null,
};

/// This view displays JSON text.
pub const ViewJson = struct {
    text: []const u8,
};

/// This view displays Markdown text.
pub const ViewMarkdown = struct {
    text: []const u8,
};

/// This view displays plain text.
pub const ViewText = struct {
    text: []const u8,
    language: ?[]const u8 = null,
};

const testing = std.testing;
const opts: std.json.ParseOptions = .{ .ignore_unknown_fields = true };

test "text view omits absent optional language on encode" {
    const json =
        \\{"type":"text","text":"hello"}
    ;
    const parsed = try std.json.parseFromSlice(View, testing.allocator, json, opts);
    defer parsed.deinit();
    try testing.expect(parsed.value == .text);
    try testing.expect(parsed.value.text.language == null);

    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try std.json.Stringify.value(parsed.value, .{ .emit_null_optional_fields = false }, &buf.writer);
    try testing.expectEqualStrings(json, buf.written());
}
