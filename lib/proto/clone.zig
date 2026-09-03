//! This module deeply clones wire values. A reflective function keeps every wire type aligned.
//! Copy each field and slice into `a`. The result owns the copies and borrows nothing from the source frame. OOM leaves partial data in `a`. Use an arena and free it as a whole.

const std = @import("std");
const registry = @import("registry.zig");

/// Copy `value` into `a` and infer its type. The result owns all bytes in `a`.
pub fn dupe(a: std.mem.Allocator, value: anytype) std.mem.Allocator.Error!@TypeOf(value) {
    const T = @TypeOf(value);
    if (comptime !hasPointers(T)) return value;
    return switch (@typeInfo(T)) {
        .optional => if (value) |v| try dupe(a, v) else null,
        .@"struct" => |info| blk: {
            var out: T = undefined;
            inline for (info.fields) |f| {
                @field(out, f.name) = try dupe(a, @field(value, f.name));
            }
            break :blk out;
        },
        .@"union" => |info| blk: {
            const Tag = info.tag_type.?;
            inline for (info.fields) |f| {
                if (std.meta.activeTag(value) == @field(Tag, f.name)) {
                    break :blk @unionInit(T, f.name, try dupe(a, @field(value, f.name)));
                }
            }
            unreachable;
        },
        .array => |info| blk: {
            var out: T = undefined;
            inline for (0..info.len) |i| out[i] = try dupe(a, value[i]);
            break :blk out;
        },
        .pointer => |info| blk: {
            if (info.size != .slice) @compileError("proto.dupe: only slices, got " ++ @typeName(T));
            // Copy a pointer-free element as shallow bytes.
            if (comptime !hasPointers(info.child)) break :blk try a.dupe(info.child, value);
            const dst = try a.alloc(info.child, value.len);
            for (value, 0..) |elem, i| dst[i] = try dupe(a, elem);
            break :blk dst;
        },
        else => @compileError("proto.dupe: unsupported type " ++ @typeName(T)),
    };
}

/// Return true when a value of `T` holds a slice or pointer. Copy a pointer-free value directly.
fn hasPointers(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .bool, .int, .float, .@"enum", .void => false,
        .optional => |info| hasPointers(info.child),
        .array => |info| hasPointers(info.child),
        .@"struct" => |info| {
            inline for (info.fields) |f| if (hasPointers(f.type)) return true;
            return false;
        },
        .@"union" => |info| {
            inline for (info.fields) |f| if (hasPointers(f.type)) return true;
            return false;
        },
        .pointer => true,
        else => true,
    };
}

const message = @import("message.zig");
const tool = @import("tool.zig");
const view = @import("view.zig");
const testing = std.testing;

/// Instantiate `dupe` for `T`. The `.run` reference instantiates the whole type graph.
fn Instantiate(comptime T: type) type {
    return struct {
        fn run(a: std.mem.Allocator, v: T) std.mem.Allocator.Error!T {
            return dupe(a, v);
        }
    };
}

test "dupe compiles for every registry type" {
    inline for (registry.structs) |e| _ = &Instantiate(e.ty).run;
}

test "dupe copies a nested string and breaks aliasing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var src = [_]u8{ 'h', 'i' };
    const part: message.TextPart = .{ .id = 1, .text = &src };
    const dst = try dupe(arena.allocator(), part);
    try testing.expectEqualStrings("hi", dst.text);
    try testing.expect(dst.text.ptr != part.text.ptr);
}

test "dupe deep-copies a tool-state view tree" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const hunk: view.DiffHunk = .{ .old_start = 1, .old_lines = 1, .new_start = 1, .new_lines = 2, .lines = &.{ "-a", "+b" } };
    const file: view.DiffFile = .{ .path = "x.zig", .hunks = &.{hunk} };
    const views = [_]view.View{.{ .diff = .{ .files = &.{file} } }};
    const state: tool.ToolState = .{ .completed = .{ .output = "ok", .view = &views, .duration_ms = 3 } };

    const dst = try dupe(arena.allocator(), state);
    try testing.expectEqualStrings("x.zig", dst.completed.view.?[0].diff.files[0].path);
    try testing.expectEqualStrings("+b", dst.completed.view.?[0].diff.files[0].hunks[0].lines[1]);
    try testing.expect(dst.completed.output.ptr != state.completed.output.ptr);
}
