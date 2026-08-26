//! Message content parts and their media sources.

const std = @import("std");
const tagged = @import("tagged.zig");

/// This type identifies where media bytes live.
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

/// The daemon fetches media from this remote URL.
pub const MediaUrl = struct {
    url: []const u8,
};

/// This source stores inline bytes in base64.
pub const MediaBase64 = struct {
    mime: []const u8,
    data: []const u8,
};

/// The daemon fetches this content-addressed blob over HTTP.
pub const MediaBlob = struct {
    hash: [64]u8,
    mime: []const u8,
    bytes: u64,
};

/// This type describes one part of a message's content.
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

/// This part holds plain text.
pub const ContentText = struct {
    text: []const u8,
};

/// This part holds an image source and an optional detail hint.
pub const ContentImage = struct {
    source: MediaSource,
    detail: ?[]const u8 = null,
};

/// This part holds an audio source and its format.
pub const ContentAudio = struct {
    source: MediaSource,
    format: []const u8,
};

/// This part holds a file source and an optional file name.
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
