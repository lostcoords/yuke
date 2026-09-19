//! Execute JavaScript cases with test-only modules and report their faults.

const std = @import("std");
const host_mod = @import("../host.zig");
const Host = host_mod.Host;
const tools_table = @import("../tools.zig");
const BakedModule = @import("../loader.zig").BakedModule;
const Paint = @import("paint.zig").Paint;

const modules = host_mod.default_baked ++ [_]BakedModule{
    .{ .name = "yuke:test-herdr", .code = .{ .source = @embedFile("../plugins/herdr.js") } },
    .{ .name = "yuke:test-markdown", .code = .{ .source = @embedFile("markdown.js") } },
    .{ .name = "yuke:test", .code = .{ .source = @embedFile("assert.js") } },
};

const environment: std.process.Environ.Map = .init(std.testing.allocator);

pub fn hostOptions(cwd: []const u8) host_mod.Options {
    return .{ .cwd = cwd, .execution = @import("../../execution.zig").testContext(&environment) };
}

/// A test allocator that records no stack traces, because QuickJS allocates on every JavaScript step.
pub const Pool = std.heap.DebugAllocator(.{ .stack_trace_frames = 0 });

pub fn createHost() *Host {
    return createHostWith(std.testing.io, "");
}

/// The testing allocator backs the pool, so a page that a leak pins fails the test.
pub fn createHostWith(io: std.Io, cwd: []const u8) *Host {
    const pool = std.testing.allocator.create(Pool) catch unreachable;
    pool.* = .{ .backing_allocator = std.testing.allocator };
    return Host.createWith(pool.allocator(), io, hostOptions(cwd));
}

/// Destroy a host from `createHostWith` and then its pool.
pub fn destroyHost(host: *Host) void {
    var probe: Pool = .init;
    std.debug.assert(host.gpa.vtable == probe.allocator().vtable);
    const pool: *Pool = @ptrCast(@alignCast(host.gpa.ptr));
    host.destroy();
    std.debug.assert(pool.deinit() == .ok);
    std.testing.allocator.destroy(pool);
}

/// Each pure JS case owns a fresh host and its teardown.
pub fn run(comptime path: [:0]const u8) !void {
    const host = createHost();
    defer destroyHost(host);
    try eval(host, path);
}

pub const PaintedHost = struct {
    paint: *Paint,
    host: *Host,

    pub fn init(rows: u16, cols: u16) !@This() {
        const paint = try std.testing.allocator.create(Paint);
        errdefer std.testing.allocator.destroy(paint);
        try paint.setup(std.testing.allocator, rows, cols);
        errdefer paint.deinit();
        const host = createHost();
        paint.bind(host);
        return .{ .paint = paint, .host = host };
    }

    pub fn deinit(self: *@This()) void {
        destroyHost(self.host);
        self.paint.deinit();
        std.testing.allocator.destroy(self.paint);
    }
};

pub fn runPainted(rows: u16, cols: u16, comptime path: [:0]const u8) !void {
    var fixture = try PaintedHost.init(rows, cols);
    defer fixture.deinit();
    try eval(fixture.host, path);
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

/// A test that sleeps this long found work that no task announced.
const wake_timeout: std.Io.Clock.Duration = .{ .raw = .fromSeconds(10), .clock = .awake };
const max_pumps = 1024;

pub fn pumpUntilIdle(host: *Host) !void {
    for (0..max_pumps) |_| {
        try host.pump();
        if (host.ops.live.items.len == 0) return;
        try awaitWork(host);
    }
    return error.PrimitiveNeverSettled;
}

pub fn pumpUntilSettled(host: *Host, call: *tools_table.Call) !void {
    for (0..max_pumps) |_| {
        try host.pump();
        if (call.state == .settled) return;
        try awaitWork(host);
    }
    return error.CallNeverSettled;
}

/// The task must set `host.wake` after it sets the event.
pub fn pumpUntilSet(host: *Host, event: *const std.Io.Event) !void {
    for (0..max_pumps) |_| {
        try host.pump();
        if (event.isSet()) return;
        try awaitWork(host);
    }
    return error.TaskNeverFinished;
}

pub fn pumpUntilTrue(host: *Host, expression: [:0]const u8) !void {
    for (0..max_pumps) |_| {
        try host.pump();
        if (try host.evalInt(expression) != 0) return;
        try awaitWork(host);
    }
    return error.ConditionNeverTrue;
}

/// Clear the wake and sleep only when no work waits, as the owner loops do.
fn awaitWork(host: *Host) !void {
    std.debug.assert(host.phase == .open);
    host.wake.reset();
    if (host.hasPending()) return;
    const deadline = std.Io.Clock.Timestamp.fromNow(host.io, wake_timeout);
    // A timer due before the missed-wake deadline ends the sleep with no wake, as `Host.waitForWork` does.
    const timer = host.timers.nextDeadline();
    const until: std.Io.Clock.Timestamp = if (timer) |due| (if (due.nanoseconds < deadline.raw.nanoseconds) .{ .raw = due, .clock = .awake } else deadline) else deadline;
    while (true) {
        host.wake.waitTimeout(host.io, .{ .deadline = until }) catch |err| switch (err) {
            error.Canceled => return err,
            // A spurious wakeup also returns Timeout, so only a passed deadline proves a missed wake.
            error.Timeout => {
                if (until.durationFromNow(host.io).raw.nanoseconds > 0) continue;
                if (timer != null and until.raw.nanoseconds != deadline.raw.nanoseconds) return;
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
