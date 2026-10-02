//! Deep-clone any wire value into `a` with one reflective function, so the copy borrows nothing from the source.

const std = @import("std");
const registry = @import("registry.zig");

/// Copy `value` into `a`, which must be an arena, because an OOM leaves partial data in it.
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

/// Return the bytes that `dupe` takes from a fresh `std.heap.FixedBufferAllocator` whose buffer starts at `max_alignment`. One exact block then holds the whole copy.
pub fn size(value: anytype) usize {
    var total: usize = 0;
    addSize(&total, value);
    return total;
}

/// The largest alignment of a wire type. `size` assumes a buffer that starts at it.
pub const max_alignment = @alignOf(u64);

// Follow the allocation order of `dupe`, because each slice pads to its alignment from the end of the previous one.
fn addSize(total: *usize, value: anytype) void {
    const T = @TypeOf(value);
    if (comptime !hasPointers(T)) return;
    switch (@typeInfo(T)) {
        .optional => if (value) |v| addSize(total, v),
        .@"struct" => |info| inline for (info.fields) |f| addSize(total, @field(value, f.name)),
        .@"union" => switch (value) {
            inline else => |v| addSize(total, v),
        },
        .array => for (value) |elem| addSize(total, elem),
        .pointer => |info| {
            if (info.size != .slice) @compileError("proto.size: only slices, got " ++ @typeName(T));
            // An empty slice takes no allocation.
            if (value.len == 0) return;
            comptime std.debug.assert(@alignOf(info.child) <= max_alignment);
            total.* = std.mem.alignForward(usize, total.*, @alignOf(info.child)) + value.len * @sizeOf(info.child);
            if (comptime hasPointers(info.child)) for (value) |elem| addSize(total, elem);
        },
        else => @compileError("proto.size: unsupported type " ++ @typeName(T)),
    }
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

const tool = @import("tool.zig");
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
    inline for (registry.tagged_unions) |e| _ = &Instantiate(e.ty).run;
    inline for (registry.envelope_unions) |e| _ = &Instantiate(e.ty).run;
    inline for (registry.string_enums) |e| _ = &Instantiate(e.ty).run;
    inline for (registry.numeric_enums) |e| _ = &Instantiate(e.ty).run;
}

test "size measures every byte that dupe takes" {
    var src = [_]u8{ 'h', 'i' };
    const hunk: tool.DiffHunk = .{ .old_start = 1, .old_lines = 1, .new_start = 1, .new_lines = 2, .lines = &.{ "-a", "+b", "" } };
    const files = [_]tool.DiffFile{ .{ .path = "x.zig", .hunks = &.{hunk} }, .{ .path = "", .hunks = &.{} } };
    const state: tool.ToolState = .{ .completed = .{ .output = &src, .diff = &files, .duration_ms = 3 } };
    var buffer: [512]u8 align(max_alignment) = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&buffer);
    _ = try dupe(fixed.allocator(), state);
    try testing.expectEqual(size(state), fixed.end_index);
}

test "dupe deep-copies a tool-state diff tree" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var src = [_]u8{ 'h', 'i' };
    const hunk: tool.DiffHunk = .{ .old_start = 1, .old_lines = 1, .new_start = 1, .new_lines = 2, .lines = &.{ "-a", "+b" } };
    const files = [_]tool.DiffFile{.{ .path = "x.zig", .hunks = &.{hunk} }};
    const file = files[0];
    const state: tool.ToolState = .{ .completed = .{ .output = &src, .diff = &files, .duration_ms = 3 } };

    const dst = try dupe(arena.allocator(), state);
    const cloned_files = dst.completed.diff;
    const cloned_hunks = cloned_files[0].hunks;
    try testing.expectEqualStrings("x.zig", cloned_files[0].path);
    try testing.expectEqualStrings("+b", cloned_hunks[0].lines[1]);
    try testing.expect(cloned_files.ptr != state.completed.diff.ptr);
    try testing.expect(cloned_files[0].path.ptr != file.path.ptr);
    try testing.expect(cloned_hunks.ptr != file.hunks.ptr);
    try testing.expect(cloned_hunks[0].lines.ptr != hunk.lines.ptr);
    try testing.expect(cloned_hunks[0].lines[1].ptr != hunk.lines[1].ptr);
    try testing.expect(dst.completed.output.ptr != state.completed.output.ptr);
    src[0] = 'x';
    try testing.expectEqualStrings("hi", dst.completed.output);
}
