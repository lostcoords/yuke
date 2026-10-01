//! These JSON writers support the request serializers.

const std = @import("std");

/// Write `key: value`. It fails only when the writer fails.
pub fn field(jw: *std.json.Stringify, key: []const u8, value: anytype) std.Io.Writer.Error!void {
    try jw.objectField(key);
    try jw.write(value);
}

/// Write `key: {inner_key: value}`, the one-member object many request members use.
pub fn nested(jw: *std.json.Stringify, key: []const u8, inner_key: []const u8, value: anytype) std.Io.Writer.Error!void {
    try jw.objectField(key);
    try jw.beginObject();
    try field(jw, inner_key, value);
    try jw.endObject();
}

/// Write `raw` as JSON without a check; an empty `raw` writes `{}`. It fails only when the writer fails.
pub fn writeRawJson(jw: *std.json.Stringify, raw: []const u8) std.Io.Writer.Error!void {
    try jw.beginWriteRaw();
    try jw.writer.writeAll(if (raw.len == 0) "{}" else raw);
    jw.endWriteRaw();
}

/// Write the name, schema, and strict members that both OpenAI response-schema shapes carry.
pub fn schemaMembers(jw: *std.json.Stringify, name: []const u8, schema: []const u8, strict: bool) std.Io.Writer.Error!void {
    try field(jw, "name", name);
    try jw.objectField("schema");
    try writeRawJson(jw, schema);
    try field(jw, "strict", strict);
}

/// Write bytes as a base64 JSON string, in chunks, so no encoded copy of the media is ever held. A `mime` makes the string a data URL.
/// It fails only when the writer fails.
pub fn writeBase64(jw: *std.json.Stringify, mime: ?[]const u8, data: []const u8) std.Io.Writer.Error!void {
    const encoder = std.base64.standard.Encoder;
    // Each chunk is a multiple of three, so only the last one carries padding.
    const chunk = 3 * 1024;
    var encoded: [4 * 1024]u8 = undefined;

    try jw.beginWriteRaw();
    try jw.writer.writeByte('"');
    if (mime) |value| {
        try jw.writer.writeAll("data:");
        try std.json.Stringify.encodeJsonStringChars(value, .{}, jw.writer);
        try jw.writer.writeAll(";base64,");
    }
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

/// Name the audio container this endpoint accepts, which is only wav and mp3.
pub fn audioFormat(mime: []const u8) error{UnsupportedContent}![]const u8 {
    if (std.mem.eql(u8, mime, "audio/wav") or std.mem.eql(u8, mime, "audio/x-wav")) return "wav";
    if (std.mem.eql(u8, mime, "audio/mpeg") or std.mem.eql(u8, mime, "audio/mp3")) return "mp3";
    return error.UnsupportedContent;
}

const testing = std.testing;

test "a base64 data URL survives the chunk boundary and a long mime" {
    // The writer encodes 3 * 1024 bytes at a time, so only the last chunk can pad.
    var data: [3 * 1024 + 7]u8 = undefined;
    for (&data, 0..) |*byte, i| byte.* = @truncate(i);
    // Validation admits a mime far past any fixed prefix buffer.
    const mime = "x/" ++ "y" ** 300;

    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    var jw: std.json.Stringify = .{ .writer = &buf.writer };
    try jw.beginObject();
    try jw.objectField("d");
    try writeBase64(&jw, mime, &data);
    try jw.endObject();

    const parsed = try std.json.parseFromSlice(struct { d: []const u8 }, testing.allocator, buf.written(), .{});
    defer parsed.deinit();
    const encoded = parsed.value.d[("data:" ++ mime ++ ";base64,").len..];

    const decoder = std.base64.standard.Decoder;
    const out = try testing.allocator.alloc(u8, try decoder.calcSizeForSlice(encoded));
    defer testing.allocator.free(out);
    try decoder.decode(out, encoded);
    try testing.expectEqualSlices(u8, &data, out);
}

/// Write the sampling members a request states. An absent member leaves the endpoint default.
pub fn sampling(jw: *std.json.Stringify, temperature: ?f64, top_p: ?f64) std.Io.Writer.Error!void {
    if (temperature) |value| {
        try field(jw, "temperature", value);
    }
    if (top_p) |value| {
        try field(jw, "top_p", value);
    }
}
