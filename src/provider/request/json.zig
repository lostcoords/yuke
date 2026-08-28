//! Shared JSON writers for request serializers.

const std = @import("std");

pub fn field(jw: *std.json.Stringify, key: []const u8, value: []const u8) !void {
    try jw.objectField(key);
    try jw.write(value);
}

pub fn writeRawJson(jw: *std.json.Stringify, raw: []const u8) !void {
    try jw.beginWriteRaw();
    try jw.writer.writeAll(if (raw.len == 0) "{}" else raw);
    jw.endWriteRaw();
}
