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

pub fn countOf(o: std.json.ObjectMap, key: []const u8) u64 {
    const n = switch (o.get(key) orelse return 0) {
        .integer => |n| n,
        else => return 0,
    };
    return std.math.cast(u64, n) orelse 0;
}
