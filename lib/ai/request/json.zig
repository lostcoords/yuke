//! These JSON writers support the request serializers.

const std = @import("std");

pub fn field(jw: *std.json.Stringify, key: []const u8, value: []const u8) !void {
    try jw.objectField(key);
    try jw.write(value);
}

/// Write `key: {inner_key: value}`, the one-member object many request members use.
pub fn nested(jw: *std.json.Stringify, key: []const u8, inner_key: []const u8, value: anytype) !void {
    try jw.objectField(key);
    try jw.beginObject();
    try jw.objectField(inner_key);
    try jw.write(value);
    try jw.endObject();
}

pub fn writeRawJson(jw: *std.json.Stringify, raw: []const u8) !void {
    try jw.beginWriteRaw();
    try jw.writer.writeAll(if (raw.len == 0) "{}" else raw);
    jw.endWriteRaw();
}

/// Write the name, schema, and strict members that both OpenAI response-schema shapes carry.
pub fn schemaMembers(jw: *std.json.Stringify, name: []const u8, schema: []const u8, strict: bool) !void {
    try field(jw, "name", name);
    try jw.objectField("schema");
    try writeRawJson(jw, schema);
    try jw.objectField("strict");
    try jw.write(strict);
}

/// Write bytes as a base64 JSON string, in chunks, so no encoded copy of the media is ever held.
pub fn writeBase64(jw: *std.json.Stringify, prefix: []const u8, data: []const u8) !void {
    const encoder = std.base64.standard.Encoder;
    // Each chunk is a multiple of three, so only the last one carries padding.
    const chunk = 3 * 1024;
    var encoded: [4 * 1024]u8 = undefined;

    try jw.beginWriteRaw();
    try jw.writer.writeByte('"');
    try std.json.Stringify.encodeJsonStringChars(prefix, .{}, jw.writer);
    var offset: usize = 0;
    while (offset < data.len) {
        const take = @min(chunk, data.len - offset);
        const slice = encoder.encode(encoded[0..encoder.calcSize(take)], data[offset..][0..take]);
        try jw.writer.writeAll(slice);
        offset += take;
    }
    try jw.writer.writeByte('"');
    jw.endWriteRaw();
}

/// Write bytes as the base64 data URL an OpenAI part reads in place of a fetchable URL.
pub fn writeDataUrl(jw: *std.json.Stringify, mime: []const u8, data: []const u8) !void {
    var buffer: [256]u8 = undefined;
    const prefix = std.fmt.bufPrint(&buffer, "data:{s};base64,", .{mime}) catch return error.UnsupportedContent;
    return writeBase64(jw, prefix, data);
}

/// Name the audio container this endpoint accepts, which is only wav and mp3.
pub fn audioFormat(mime: []const u8) ![]const u8 {
    if (std.mem.eql(u8, mime, "audio/wav") or std.mem.eql(u8, mime, "audio/x-wav")) return "wav";
    if (std.mem.eql(u8, mime, "audio/mpeg") or std.mem.eql(u8, mime, "audio/mp3")) return "mp3";
    return error.UnsupportedContent;
}

const testing = std.testing;

test "base64 survives the chunk boundary it encodes across" {
    // The writer encodes 3 * 1024 bytes at a time, so only the last chunk can pad.
    var data: [3 * 1024 + 7]u8 = undefined;
    for (&data, 0..) |*byte, i| byte.* = @truncate(i);

    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    var jw: std.json.Stringify = .{ .writer = &buf.writer };
    try jw.beginObject();
    try jw.objectField("d");
    try writeBase64(&jw, "data:x;base64,", &data);
    try jw.endObject();

    const parsed = try std.json.parseFromSlice(struct { d: []const u8 }, testing.allocator, buf.written(), .{});
    defer parsed.deinit();
    const encoded = parsed.value.d["data:x;base64,".len..];

    const decoder = std.base64.standard.Decoder;
    const out = try testing.allocator.alloc(u8, try decoder.calcSizeForSlice(encoded));
    defer testing.allocator.free(out);
    try decoder.decode(out, encoded);
    try testing.expectEqualSlices(u8, &data, out);
}
