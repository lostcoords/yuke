//! Shared JSON writers for request serializers.

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
