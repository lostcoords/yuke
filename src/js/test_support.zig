//! Execute JavaScript cases with test-only modules and report their faults.

const std = @import("std");
const host_mod = @import("host.zig");
const Host = host_mod.Host;
const tools_table = @import("tools.zig");
const BakedModule = @import("loader.zig").BakedModule;

const modules = host_mod.default_baked ++ [_]BakedModule{
    .{ .name = "yuke:test", .source = @embedFile("tests/assert.js") },
};

/// Each pure JS case owns a fresh host and its teardown.
pub fn run(comptime path: [:0]const u8) !void {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    try eval(host, path);
}

pub fn eval(host: *Host, comptime path: [:0]const u8) !void {
    std.debug.assert(host.phase == .open);
    const previous = host.loader.baked;
    host.loader.baked = &modules;
    defer host.loader.baked = previous;
    host.evalModule(@embedFile(path), path) catch |err| {
        std.debug.print("\n{s}: {s}\n", .{ path, host.faultText() });
        return err;
    };
}

pub fn evalScript(host: *Host, comptime path: [:0]const u8) !void {
    std.debug.assert(host.phase == .open);
    host.eval(@embedFile(path), path) catch |err| {
        std.debug.print("\n{s}: {s}\n", .{ path, host.faultText() });
        return err;
    };
}

pub fn expectString(host: *Host, comptime property: []const u8, want: []const u8) !void {
    std.debug.assert(host.phase == .open or host.phase == .drained);
    const value = try host.ctx.eval("globalThis." ++ property, "test-result.js", .{});
    defer host.ctx.freeValue(value);
    const text = try host.ctx.toCStringLen(value);
    defer host.ctx.freeCString(text.ptr);
    try std.testing.expectEqualStrings(want, text);
}

pub fn pumpUntilIdle(host: *Host) !void {
    var rounds: u32 = 0;
    while (host.ops.live.items.len != 0) : (rounds += 1) {
        if (rounds == 64) return error.PrimitiveNeverSettled;
        host.wake.waitTimeout(host.io, .{ .duration = .{ .raw = .fromMilliseconds(1000), .clock = .awake } }) catch {};
        host.wake.reset();
        try host.pump();
    }
    try host.pump();
}

pub fn pumpUntilSettled(host: *Host, call: *tools_table.Call, wake: ?*std.Io.Event) !void {
    var rounds: u32 = 0;
    while (call.state != .settled) : (rounds += 1) {
        if (rounds == 64) return error.CallNeverSettled;
        if (wake) |w| {
            w.waitTimeout(host.io, .{ .duration = .{ .raw = .fromMilliseconds(1000), .clock = .awake } }) catch {};
            w.reset();
        }
        try host.pump();
    }
}

pub fn dropCall(host: *Host, call: *tools_table.Call) !void {
    call.finish();
    try host.pump();
}
