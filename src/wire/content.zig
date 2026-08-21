//! Message content parts and their media sources.

const std = @import("std");
const tagged = @import("tagged.zig");

/// Where media bytes live.
pub const MediaSource = union(enum) {
    url: MediaUrl,
    base64: MediaBase64,
    blob: MediaBlob,

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

/// Remote URL the daemon fetches.
pub const MediaUrl = struct {
    url: []const u8,
};

/// Inline base64 bytes.
pub const MediaBase64 = struct {
    mime: []const u8,
    data: []const u8,
};

/// Content-addressed blob fetched over HTTP.
pub const MediaBlob = struct {
    hash: [64]u8,
    mime: []const u8,
    bytes: u64,
};

/// One part of a message's content.
pub const ContentPart = union(enum) {
    text: ContentText,
    image: ContentImage,
    audio: ContentAudio,
    file: ContentFile,

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

/// Plain text content part.
pub const ContentText = struct {
    text: []const u8,
};

/// Image content part.
pub const ContentImage = struct {
    source: MediaSource,
    detail: ?[]const u8 = null,
};

/// Audio content part.
pub const ContentAudio = struct {
    source: MediaSource,
    format: []const u8,
};

/// File content part.
pub const ContentFile = struct {
    source: MediaSource,
    filename: ?[]const u8 = null,
};

const testing = std.testing;
const opts: std.json.ParseOptions = .{ .ignore_unknown_fields = true };

test "content image with nested media union round-trips" {
    const json =
        \\{"type":"image","source":{"type":"base64","mime":"image/png","data":"aGk="}}
    ;
    const parsed = try std.json.parseFromSlice(ContentPart, testing.allocator, json, opts);
    defer parsed.deinit();
    try testing.expect(parsed.value == .image);
    try testing.expect(parsed.value.image.source == .base64);
    try testing.expectEqualStrings("image/png", parsed.value.image.source.base64.mime);
    try testing.expect(parsed.value.image.detail == null);

    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try std.json.Stringify.value(parsed.value, .{ .emit_null_optional_fields = false }, &buf.writer);
    try testing.expectEqualStrings(json, buf.written());
}

test "blob hash decodes into fixed [64]u8" {
    const hash = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    const parsed = try std.json.parseFromSlice(MediaSource, testing.allocator, std.fmt.comptimePrint(
        \\{{"type":"blob","hash":"{s}","mime":"application/pdf","bytes":1024}}
    , .{hash}), opts);
    defer parsed.deinit();
    try testing.expect(parsed.value == .blob);
    try testing.expectEqualStrings(hash, &parsed.value.blob.hash);
    try testing.expectEqual(@as(u64, 1024), parsed.value.blob.bytes);
}
