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

/// The longest owner sleep. A test that reaches it found work that no task announced.
const wake_timeout: std.Io.Clock.Duration = .{ .raw = .fromSeconds(10), .clock = .awake };
/// The most passes for one helper. A test that reaches it found an owner that never settles.
const max_pumps = 1024;

/// Drive the owner until no primitive is in flight.
pub fn pumpUntilIdle(host: *Host) !void {
    for (0..max_pumps) |_| {
        try host.pump();
        if (host.ops.live.items.len == 0) return;
        try awaitWork(host);
    }
    return error.PrimitiveNeverSettled;
}

/// Drive the owner until the call settles.
pub fn pumpUntilSettled(host: *Host, call: *tools_table.Call) !void {
    for (0..max_pumps) |_| {
        try host.pump();
        if (call.state == .settled) return;
        try awaitWork(host);
    }
    return error.CallNeverSettled;
}

/// Drive the owner until a task sets the event. The task must set `host.wake` after the event.
pub fn pumpUntilSet(host: *Host, event: *const std.Io.Event) !void {
    for (0..max_pumps) |_| {
        try host.pump();
        if (event.isSet()) return;
        try awaitWork(host);
    }
    return error.TaskNeverFinished;
}

/// Drive the owner until the JavaScript expression answers a nonzero integer.
pub fn pumpUntilTrue(host: *Host, expression: [:0]const u8) !void {
    for (0..max_pumps) |_| {
        try host.pump();
        if (try host.evalInt(expression) != 0) return;
        try awaitWork(host);
    }
    return error.ConditionNeverTrue;
}

/// Sleep as the owner loops do: clear the wake, and sleep only when no work waits.
fn awaitWork(host: *Host) !void {
    std.debug.assert(host.phase == .open);
    host.wake.reset();
    if (host.hasPending()) return;
    const deadline = std.Io.Clock.Timestamp.fromNow(host.io, wake_timeout);
    while (true) {
        host.wake.waitTimeout(host.io, .{ .deadline = deadline }) catch |err| switch (err) {
            error.Canceled => return err,
            // A spurious wakeup also returns Timeout, so only the deadline proves a missed wake.
            error.Timeout => {
                if (deadline.durationFromNow(host.io).raw.nanoseconds > 0) continue;
                return error.OwnerNeverWoken;
            },
        };
        return;
    }
}

pub fn dropCall(host: *Host, call: *tools_table.Call) !void {
    call.finish();
    try host.pump();
}
