//! Allocation totals for one owner; the wrapper neither allocates nor captures stack traces.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
const Allocations = @This();

backing: Allocator,
counts: Counts = .{},
peak_bytes: usize = 0,

pub const Counts = struct {
    allocations: usize = 0,
    frees: usize = 0,
    resize_attempts: usize = 0,
    remap_attempts: usize = 0,
    allocation_failures: usize = 0,
    allocated_bytes: usize = 0,
    freed_bytes: usize = 0,

    pub fn since(self: Counts, before: Counts) Counts {
        var delta: Counts = .{};
        inline for (std.meta.fields(Counts)) |field| {
            assert(@field(self, field.name) >= @field(before, field.name));
            @field(delta, field.name) = @field(self, field.name) - @field(before, field.name);
        }
        return delta;
    }
};

pub fn allocator(self: *Allocations) Allocator {
    return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .free = free, .resize = resize, .remap = remap } };
}

pub fn liveBytes(self: *const Allocations) usize {
    assert(self.counts.allocated_bytes >= self.counts.freed_bytes);
    return self.counts.allocated_bytes - self.counts.freed_bytes;
}

pub fn liveCount(self: *const Allocations) usize {
    assert(self.counts.allocations >= self.counts.frees);
    return self.counts.allocations - self.counts.frees;
}

pub fn resetPeak(self: *Allocations) void {
    self.peak_bytes = self.liveBytes();
}

fn changeSize(self: *Allocations, old: usize, new: usize) void {
    assert(self.liveBytes() >= old);
    if (new >= old) self.counts.allocated_bytes += new - old else self.counts.freed_bytes += old - new;
    self.peak_bytes = @max(self.peak_bytes, self.liveBytes());
}

fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
    const self: *Allocations = @ptrCast(@alignCast(ctx));
    assert(len > 0);
    const ptr = self.backing.rawAlloc(len, alignment, ret_addr) orelse {
        self.counts.allocation_failures += 1;
        return null;
    };
    self.counts.allocations += 1;
    self.changeSize(0, len);
    return ptr;
}

fn free(ctx: *anyopaque, bytes: []u8, alignment: Alignment, ret_addr: usize) void {
    const self: *Allocations = @ptrCast(@alignCast(ctx));
    assert(self.liveCount() > 0);
    self.backing.rawFree(bytes, alignment, ret_addr);
    self.counts.frees += 1;
    self.changeSize(bytes.len, 0);
}

fn resize(ctx: *anyopaque, bytes: []u8, alignment: Alignment, len: usize, ret_addr: usize) bool {
    const self: *Allocations = @ptrCast(@alignCast(ctx));
    assert(self.liveCount() > 0);
    assert(len > 0);
    self.counts.resize_attempts += 1;
    if (!self.backing.rawResize(bytes, alignment, len, ret_addr)) return false;
    self.changeSize(bytes.len, len);
    return true;
}

fn remap(ctx: *anyopaque, bytes: []u8, alignment: Alignment, len: usize, ret_addr: usize) ?[*]u8 {
    const self: *Allocations = @ptrCast(@alignCast(ctx));
    assert(self.liveCount() > 0);
    assert(len > 0);
    self.counts.remap_attempts += 1;
    const ptr = self.backing.rawRemap(bytes, alignment, len, ret_addr) orelse return null;
    self.changeSize(bytes.len, len);
    return ptr;
}

test "allocation totals survive resize, failed growth, and release" {
    var buf: [128]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&buf);
    var tracked: Allocations = .{ .backing = fixed.allocator() };
    const gpa = tracked.allocator();
    var bytes = try gpa.alloc(u8, 32);
    @memset(bytes, 42);
    const before = tracked.counts;
    bytes = try gpa.realloc(bytes, 64);
    try std.testing.expectEqual(@as(u8, 42), bytes[31]);
    try std.testing.expectEqual(@as(usize, 64), tracked.liveBytes());
    try std.testing.expectEqual(@as(usize, 32), tracked.counts.since(before).allocated_bytes);
    try std.testing.expectError(error.OutOfMemory, gpa.realloc(bytes, 256));
    try std.testing.expectEqual(@as(usize, 64), tracked.liveBytes());
    try std.testing.expectEqual(@as(usize, 1), tracked.liveCount());
    try std.testing.expectEqual(@as(usize, 1), tracked.counts.allocation_failures);
    try std.testing.expect(gpa.resize(bytes, 16));
    bytes = bytes[0..16];
    try std.testing.expectEqual(@as(usize, 64), tracked.peak_bytes);
    tracked.resetPeak();
    try std.testing.expectEqual(@as(usize, 16), tracked.peak_bytes);
    gpa.free(bytes);
    try std.testing.expectEqual(@as(usize, 0), tracked.liveBytes());
    try std.testing.expectEqual(@as(usize, 0), tracked.liveCount());
}
