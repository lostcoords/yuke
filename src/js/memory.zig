//! The QuickJS allocator bridge preserves alignment and reports every payload size.

const std = @import("std");
const quickjs = @import("quickjs");
const c = @import("quickjs_c");
const assert = std.debug.assert;

const alignment: std.mem.Alignment = .of(std.c.max_align_t);
const header_size = std.mem.alignForward(usize, @sizeOf(usize), alignment.toByteUnits());

pub fn createRuntime(gpa: std.mem.Allocator) !*quickjs.Runtime {
    const runtime = try gpa.create(quickjs.Runtime);
    errdefer gpa.destroy(runtime);
    runtime.allocator = gpa;
    runtime.ptr = c.JS_NewRuntime2(&functions, runtime) orelse return error.OutOfMemory;
    assert(runtime.ptr != null);
    return runtime;
}

const functions: c.JSMallocFunctions = .{
    .js_calloc = calloc,
    .js_malloc = malloc,
    .js_free = free,
    .js_realloc = realloc,
    .js_malloc_usable_size = usableSize,
};

fn allocator(opaque_ptr: ?*anyopaque) std.mem.Allocator {
    const runtime: *const quickjs.Runtime = @ptrCast(@alignCast(opaque_ptr.?));
    return runtime.allocator;
}

fn malloc(opaque_ptr: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque {
    if (size == 0) return null;
    const total = std.math.add(usize, header_size, size) catch return null;
    const bytes = allocator(opaque_ptr).alignedAlloc(u8, alignment, total) catch return null;
    std.mem.writeInt(usize, bytes[0..@sizeOf(usize)], size, .little);
    assert(bytes.len > header_size);
    return bytes[header_size..].ptr;
}

fn calloc(opaque_ptr: ?*anyopaque, count: usize, size: usize) callconv(.c) ?*anyopaque {
    const len = std.math.mul(usize, count, size) catch return null;
    const ptr = malloc(opaque_ptr, len) orelse return null;
    const bytes: [*]u8 = @ptrCast(ptr);
    @memset(bytes[0..len], 0);
    return ptr;
}

fn allocation(ptr: *const anyopaque) []align(alignment.toByteUnits()) u8 {
    const bytes: [*]align(alignment.toByteUnits()) u8 = @ptrFromInt(@intFromPtr(ptr) - header_size);
    const size = std.mem.readInt(usize, bytes[0..@sizeOf(usize)], .little);
    assert(size > 0);
    assert(size <= std.math.maxInt(usize) - header_size);
    return bytes[0 .. header_size + size];
}

fn free(opaque_ptr: ?*anyopaque, ptr: ?*anyopaque) callconv(.c) void {
    const p = ptr orelse return;
    allocator(opaque_ptr).free(allocation(p));
}

fn realloc(opaque_ptr: ?*anyopaque, ptr: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque {
    const p = ptr orelse return malloc(opaque_ptr, size);
    if (size == 0) {
        free(opaque_ptr, p);
        return null;
    }
    const total = std.math.add(usize, header_size, size) catch return null;
    const bytes = allocator(opaque_ptr).realloc(allocation(p), total) catch return null;
    std.mem.writeInt(usize, bytes[0..@sizeOf(usize)], size, .little);
    assert(bytes.len == total);
    return bytes[header_size..].ptr;
}

fn usableSize(ptr: ?*const anyopaque) callconv(.c) usize {
    const p = ptr orelse return 0;
    return allocation(p).len - header_size;
}

test "QuickJS counts large allocations and rejects their combined size over the limit" {
    const runtime = try createRuntime(std.testing.allocator);
    defer runtime.deinit();
    const before = runtime.computeMemoryUsage();
    const size = 128 * 1024;
    runtime.setMemoryLimit(@as(usize, @intCast(before.malloc_size)) + size * 3);
    const ptr = c.js_malloc_rt(runtime.ptr, size) orelse return error.OutOfMemory;
    var owned: ?*anyopaque = ptr;
    defer c.js_free_rt(runtime.ptr, owned);
    try std.testing.expect(runtime.computeMemoryUsage().malloc_size >= before.malloc_size + size);
    owned = c.js_realloc_rt(runtime.ptr, ptr, size * 2) orelse return error.OutOfMemory;
    try std.testing.expect(runtime.computeMemoryUsage().malloc_size >= before.malloc_size + size * 2);
    const refused = c.js_malloc_rt(runtime.ptr, size * 2);
    defer c.js_free_rt(runtime.ptr, refused);
    try std.testing.expect(refused == null);
    owned = c.js_realloc_rt(runtime.ptr, owned, size) orelse return error.OutOfMemory;
    c.js_free_rt(runtime.ptr, owned);
    owned = null;
    try std.testing.expectEqual(before.malloc_size, runtime.computeMemoryUsage().malloc_size);
    try std.testing.expectEqual(before.malloc_count, runtime.computeMemoryUsage().malloc_count);
}

test "QuickJS runtime initialization releases partial allocations on failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(gpa: std.mem.Allocator) !void {
            const runtime = try createRuntime(gpa);
            runtime.deinit();
        }
    }.run, .{});
}
