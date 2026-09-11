//! Message content parts and their media blobs.

const std = @import("std");
const ids = @import("ids.zig");
const tagged = @import("tagged.zig");

/// A content-addressed blob in the engine store. The `bytes` field is the size, not the payload.
pub const MediaBlob = struct {
    hash: ids.BlobHash,
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

/// This part holds an image blob.
pub const ContentImage = struct {
    source: MediaBlob,
};

/// This part holds an audio blob and its format.
pub const ContentAudio = struct {
    source: MediaBlob,
    format: []const u8,
};

/// This part holds a file blob and an optional file name.
pub const ContentFile = struct {
    source: MediaBlob,
    filename: ?[]const u8 = null,
};

const testing = std.testing;
const opts: std.json.ParseOptions = .{ .ignore_unknown_fields = true };
const hex = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

test "content image with a blob round-trips" {
    const json =
        \\{"type":"image","source":{"hash":"
    ++ hex ++
        \\","mime":"image/png","bytes":1024}}
    ;
    const parsed = try std.json.parseFromSlice(ContentPart, testing.allocator, json, opts);
    defer parsed.deinit();
    try testing.expect(parsed.value == .image);
    try testing.expectEqualStrings("image/png", parsed.value.image.source.mime);
    try testing.expectEqual(@as(u64, 1024), parsed.value.image.source.bytes);

    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try std.json.Stringify.value(parsed.value, .{ .emit_null_optional_fields = false }, &buf.writer);
    try testing.expectEqualStrings(json, buf.written());
}

test "blob hash decodes 64 lowercase hexadecimal characters into 32 raw bytes" {
    const parsed = try std.json.parseFromSlice(MediaBlob, testing.allocator, "{\"hash\":\"" ++ hex ++ "\",\"mime\":\"application/pdf\",\"bytes\":1024}", opts);
    defer parsed.deinit();
    try testing.expectEqual(@as(u8, 0x01), parsed.value.hash.raw[0]);
    try testing.expectEqual(@as(u8, 0xef), parsed.value.hash.raw[31]);
}

test "blob hash rejects every text that is not 64 lowercase hexadecimal characters" {
    const a = testing.allocator;
    const upper = "0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF";
    const path = "../" ** 21 ++ "x"; // 64 bytes, so only the character check can reject it.
    try testing.expectError(error.InvalidCharacter, std.json.parseFromSlice(MediaBlob, a, "{\"hash\":\"" ++ upper ++ "\",\"mime\":\"image/png\",\"bytes\":1}", opts));
    try testing.expectError(error.InvalidCharacter, std.json.parseFromSlice(MediaBlob, a, "{\"hash\":\"" ++ path ++ "\",\"mime\":\"image/png\",\"bytes\":1}", opts));
    try testing.expectError(error.LengthMismatch, std.json.parseFromSlice(MediaBlob, a, "{\"hash\":\"" ++ hex[0..62] ++ "\",\"mime\":\"image/png\",\"bytes\":1}", opts));
    try testing.expectError(error.UnexpectedToken, std.json.parseFromSlice(MediaBlob, a, "{\"hash\":7,\"mime\":\"image/png\",\"bytes\":1}", opts));
    try testing.expectError(error.MissingField, std.json.parseFromSlice(MediaBlob, a, "{\"mime\":\"image/png\",\"bytes\":1}", opts));
}
