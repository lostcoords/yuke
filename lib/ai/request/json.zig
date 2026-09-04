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
