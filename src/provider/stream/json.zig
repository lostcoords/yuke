//! Shared JSON accessors for stream reducers.

const std = @import("std");

pub fn fieldGet(v: std.json.Value, key: []const u8) ?std.json.Value {
    const o = switch (v) {
        .object => |o| o,
        else => return null,
    };
    return o.get(key);
}

pub fn fieldStr(v: std.json.Value, key: []const u8) ?[]const u8 {
    return switch (fieldGet(v, key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

pub fn fieldInt(v: std.json.Value, key: []const u8) ?i64 {
    return switch (fieldGet(v, key) orelse return null) {
        .integer => |n| n,
        else => null,
    };
}

pub fn fieldIndex(v: std.json.Value, key: []const u8) ?usize {
    const n = fieldInt(v, key) orelse return null;
    if (n < 0) return null;
    return std.math.cast(usize, n);
}

pub fn fieldObj(v: std.json.Value, key: []const u8) ?std.json.ObjectMap {
    return switch (fieldGet(v, key) orelse return null) {
        .object => |o| o,
        else => null,
    };
}

pub fn childObj(o: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    return switch (o.get(key) orelse return null) {
        .object => |c| c,
        else => null,
    };
}

pub fn childStr(o: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return switch (o.get(key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

/// Read a token count. An absent key is zero. A non-integer or negative value is malformed.
/// A value above i64 max arrives as a number string, so parse the full u64 range.
pub fn countOf(o: std.json.ObjectMap, key: []const u8) error{Protocol}!u64 {
    const value = o.get(key) orelse return 0;
    return switch (value) {
        .integer => |n| std.math.cast(u64, n) orelse error.Protocol,
        .number_string => |s| std.fmt.parseInt(u64, s, 10) catch error.Protocol,
        else => error.Protocol,
    };
}
