//! The QuickJS allocator bridge preserves alignment and reports every payload size.

const std = @import("std");
const quickjs = @import("quickjs");
const c = @import("quickjs_c");
const assert = std.debug.assert;

const alignment: std.mem.Alignment = .of(std.c.max_align_t);
const header_size = std.mem.alignForward(usize, @sizeOf(usize), alignment.toByteUnits());

// QuickJS releases empty arenas at once; retain at most eight page-sized blocks per runtime.
pub const Allocator = struct {
    backing: std.mem.Allocator,
    blocks: [8][]align(alignment.toByteUnits()) u8 = undefined,
    len: usize = 0,

    pub fn deinit(self: *Allocator) void {
        assert(self.len <= self.blocks.len);
        for (self.blocks[0..self.len]) |block| self.backing.free(block);
        self.* = undefined;
    }
};

const page_size = 4096;

fn cacheable(size: usize) bool {
    return size >= 3 * 1024 and size <= page_size;
}

/// Keep the allocator at one address until the runtime is destroyed.
pub fn createRuntime(memory: *Allocator) !*quickjs.Runtime {
    const gpa = memory.backing;
    const runtime = try gpa.create(quickjs.Runtime);
    errdefer gpa.destroy(runtime);
    runtime.allocator = gpa;
    runtime.ptr = c.JS_NewRuntime2(&functions, memory) orelse return error.OutOfMemory;
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

fn allocator(opaque_ptr: ?*anyopaque) *Allocator {
    return @ptrCast(@alignCast(opaque_ptr.?));
}

fn malloc(opaque_ptr: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque {
    if (size == 0) return null;
    const total = std.math.add(usize, header_size, size) catch return null;
    const memory = allocator(opaque_ptr);
    assert(memory.len <= memory.blocks.len);
    const bytes = blk: {
        if (cacheable(size)) {
            var i = memory.len;
            while (i > 0) {
                i -= 1;
                const block = memory.blocks[i];
                if (block.len != total) continue;
                memory.len -= 1;
                memory.blocks[i] = memory.blocks[memory.len]; // The cache has no order, so the last block fills the gap.
                break :blk block;
            }
        }
        break :blk memory.backing.alignedAlloc(u8, alignment, total) catch return null;
    };
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
    const memory = allocator(opaque_ptr);
    const bytes = allocation(p);
    assert(memory.len <= memory.blocks.len);
    if (cacheable(bytes.len - header_size)) {
        if (memory.len == memory.blocks.len) {
            memory.backing.free(memory.blocks[0]);
            memory.len -= 1;
            memory.blocks[0] = memory.blocks[memory.len];
        }
        memory.blocks[memory.len] = bytes;
        memory.len += 1;
    } else memory.backing.free(bytes);
}

fn realloc(opaque_ptr: ?*anyopaque, ptr: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque {
    const p = ptr orelse return malloc(opaque_ptr, size);
    if (size == 0) {
        free(opaque_ptr, p);
        return null;
    }
    const total = std.math.add(usize, header_size, size) catch return null;
    const bytes = allocator(opaque_ptr).backing.realloc(allocation(p), total) catch return null;
    std.mem.writeInt(usize, bytes[0..@sizeOf(usize)], size, .little);
    assert(bytes.len == total);
    return bytes[header_size..].ptr;
}

fn usableSize(ptr: ?*const anyopaque) callconv(.c) usize {
    const p = ptr orelse return 0;
    return allocation(p).len - header_size;
}

test "QuickJS counts large allocations and rejects their combined size over the limit" {
    var memory: Allocator = .{ .backing = std.testing.allocator };
    defer memory.deinit();
    const runtime = try createRuntime(&memory);
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

test "QuickJS page reuse stays bounded and preserves realloc and calloc semantics" {
    var memory: Allocator = .{ .backing = std.testing.allocator };
    defer memory.deinit();
    var pages: [10]*anyopaque = undefined;
    for (&pages) |*page| {
        page.* = malloc(&memory, page_size) orelse return error.OutOfMemory;
        @memset(@as([*]u8, @ptrCast(page.*))[0..page_size], 0xa5);
    }
    for (pages) |page| free(&memory, page);
    try std.testing.expectEqual(memory.blocks.len, memory.len);
    const reused = calloc(&memory, 1, page_size) orelse return error.OutOfMemory;
    var owned: ?*anyopaque = reused;
    defer free(&memory, owned);
    try std.testing.expectEqual(memory.blocks.len - 1, memory.len); // calloc took a cached page
    try std.testing.expectEqual(page_size, usableSize(reused));
    const bytes: [*]u8 = @ptrCast(reused);
    try std.testing.expect(std.mem.allEqual(u8, bytes[0..page_size], 0));
    @memset(bytes[0..3072], 0xa5);
    owned = realloc(&memory, owned, page_size * 2) orelse return error.OutOfMemory;
    try std.testing.expect(std.mem.allEqual(u8, @as([*]u8, @ptrCast(owned.?))[0..3072], 0xa5));
    owned = realloc(&memory, owned, 3072) orelse return error.OutOfMemory;
    owned = realloc(&memory, owned, 128) orelse return error.OutOfMemory;
    try std.testing.expect(std.mem.allEqual(u8, @as([*]u8, @ptrCast(owned.?))[0..128], 0xa5));
    try std.testing.expectEqual(@as(usize, 128), usableSize(owned));
    owned = realloc(&memory, owned, 0);
    try std.testing.expectEqual(null, owned);
}
