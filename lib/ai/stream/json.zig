//! Shared JSON readers and the tool-argument rules of the three stream reducers.

const std = @import("std");
const answer = @import("../answer.zig");
const event = @import("event.zig");

/// The errors a reducer decode returns: a malformed stream, an allocation failure, or a provider answer.
pub const Error = error{ Protocol, OutOfMemory } || answer.Error;

pub inline fn parse(data: []const u8, scratch: std.mem.Allocator) error{ Protocol, OutOfMemory }!std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, scratch, data, .{}) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Protocol,
    };
}

pub fn replaceOwned(gpa: std.mem.Allocator, target: *[]const u8, bytes: []const u8) error{OutOfMemory}!void {
    const owned = try gpa.dupe(u8, bytes);
    gpa.free(target.*);
    target.* = owned;
}

/// Join one argument fragment. The joined text reaches the wire as one string, so the string cap bounds it.
pub fn appendArgs(gpa: std.mem.Allocator, args: *std.ArrayList(u8), fragment: []const u8) Error!void {
    std.debug.assert(args.items.len <= event.max_tool_arg_bytes);
    if (fragment.len > event.max_tool_arg_bytes - args.items.len) return error.Protocol;
    try args.appendSlice(gpa, fragment);
}

/// The arguments of a finished call. A call with no fragment takes the empty object.
pub fn arguments(args: []const u8) []const u8 {
    return if (args.len == 0) "{}" else args;
}

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

/// Read an index that must be present, non-negative, and representable as `usize`.
pub fn fieldIndex(v: std.json.Value, key: []const u8) error{Protocol}!usize {
    const n = fieldInt(v, key) orelse return error.Protocol;
    if (n < 0) return error.Protocol;
    return std.math.cast(usize, n) orelse error.Protocol;
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

/// Read a token count. An absent key or a null is zero, and a count above i64 max is a number string.
pub fn countOf(o: std.json.ObjectMap, key: []const u8) error{Protocol}!u64 {
    const value = o.get(key) orelse return 0;
    return switch (value) {
        .integer => |n| std.math.cast(u64, n) orelse error.Protocol,
        .number_string => |s| std.fmt.parseInt(u64, s, 10) catch error.Protocol,
        // Anthropic declares every usage count nullable, so a null is an absent count.
        .null => 0,
        else => error.Protocol,
    };
}
