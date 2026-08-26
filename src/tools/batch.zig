//! Execute one batch of tool calls concurrently. A single failure is local to its result. The caller
//! must provide a single-executor reactor when the allocator or host is not thread-safe.

const std = @import("std");
const wire = @import("wire");
const t = @import("tool.zig");
const registry = @import("registry.zig");

/// One decoded tool call from a provider response.
pub const Call = struct {
    name: []const u8,
    args: std.json.Value,
};

/// One tool result. The loop maps `is_error` to a completed or an error tool state.
pub const Result = struct {
    output: []const u8,
    view: ?[]const wire.view.View = null,
    is_error: bool,
};

/// Run every call concurrently and return one result per call, in call order. The caller owns the slice.
/// A caller cancel returns `error.Canceled`. The run loop adds the per-part tool event lifecycle
/// (running/output_delta/terminal + per-leg cancel) when it integrates this batch (turn-engine slice 7).
pub fn execute(io: std.Io, arena: std.mem.Allocator, host: t.ToolHost, calls: []const Call) ![]const Result {
    const results = try arena.alloc(Result, calls.len);
    // A call that never starts (a cancel) keeps this default.
    @memset(results, .{ .output = "canceled", .is_error = true });

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    for (calls, 0..) |call, i| {
        try group.concurrent(io, runOne, .{ arena, host, call, &results[i] });
    }
    try group.await(io); // Propagate a caller cancel; a leg failure is local, not a group error.
    return results;
}

/// Run one call and write its result. An unknown tool or a handler error becomes a local error result.
fn runOne(arena: std.mem.Allocator, host: t.ToolHost, call: Call, out: *Result) void {
    const tool = registry.find(call.name) orelse {
        out.* = .{ .output = "unknown tool", .is_error = true };
        return;
    };
    const res = tool.execute(arena, host, call.args) catch |err| {
        out.* = .{ .output = @errorName(err), .is_error = true };
        return;
    };
    out.* = .{ .output = res.text, .view = res.view, .is_error = false };
}

const testing = std.testing;
const zio = @import("zio");

/// This host returns fixed bytes for batch tests without a file system.
const FakeHost = struct {
    text: []const u8,

    const vtable: t.ToolHost.VTable = .{ .readFile = readFile };

    fn host(self: *FakeHost) t.ToolHost {
        return .{ .ctx = self, .vtable = &vtable };
    }

    fn readFile(ctx: *anyopaque, arena: std.mem.Allocator, path: []const u8, start: ?usize, end: ?usize) anyerror![]const u8 {
        _ = path;
        _ = start;
        _ = end;
        const self: *FakeHost = @ptrCast(@alignCast(ctx));
        return arena.dupe(u8, self.text);
    }
};

fn parseArgs(arena: std.mem.Allocator, json: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{});
}

fn batchBody(arena: std.mem.Allocator, io: std.Io) ![]const Result {
    var fake: FakeHost = .{ .text = "hello\n" };
    const calls = [_]Call{
        .{ .name = "read", .args = try parseArgs(arena, "{\"path\":\"a\"}") },
        .{ .name = "read", .args = try parseArgs(arena, "{}") }, // The second call has no path and must fail.
        .{ .name = "nope", .args = .null }, // The third call names an unknown tool and must fail.
    };
    return execute(io, arena, fake.host(), &calls);
}

test "batch runs calls and keeps order with local failures" {
    const rt = try zio.Runtime.init(testing.allocator, .{ .executors = .exact(1) });
    defer rt.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var task = try rt.spawn(batchBody, .{ arena.allocator(), rt.io() });
    const results = try task.join();

    try testing.expectEqual(@as(usize, 3), results.len);
    try testing.expect(!results[0].is_error);
    try testing.expectEqualStrings("1: hello", results[0].output);
    try testing.expect(results[1].is_error);
    try testing.expect(results[2].is_error);
    try testing.expectEqualStrings("unknown tool", results[2].output);
}
