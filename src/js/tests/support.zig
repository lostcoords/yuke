//! Execute JavaScript cases with test-only modules and report their faults.

const std = @import("std");
const host_mod = @import("../host.zig");
const Host = host_mod.Host;
const tools_table = @import("../tools.zig");
const BakedModule = @import("../loader.zig").BakedModule;
const Paint = @import("paint.zig").Paint;
const execution = @import("../../execution.zig");

const modules = host_mod.default_baked ++ [_]BakedModule{
    .{ .name = "yuke:test-markdown", .code = .{ .source = @embedFile("markdown.js") } },
    .{ .name = "yuke:test", .code = .{ .source = @embedFile("assert.js") } },
};

const environment: std.process.Environ.Map = .init(std.testing.allocator);

pub fn hostOptions(cwd: []const u8) host_mod.Options {
    return .{ .cwd = cwd, .execution = execution.testContext(&environment) };
}

/// A test allocator that records no stack traces, because QuickJS allocates on every JavaScript step.
pub const Pool = std.heap.DebugAllocator(.{ .stack_trace_frames = 0 });

pub fn createHost() *Host {
    return createHostWith(std.testing.io, "");
}

/// The testing allocator backs the pool, so a page that a leak pins fails the test.
pub fn createHostWith(io: std.Io, cwd: []const u8) *Host {
    return createHostWithOptions(io, hostOptions(cwd));
}

pub fn createHostWithOptions(io: std.Io, options: host_mod.Options) *Host {
    const pool = std.testing.allocator.create(Pool) catch unreachable;
    pool.* = .{ .backing_allocator = std.testing.allocator };
    return Host.createWith(pool.allocator(), io, options);
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

/// A test that waits this long found work that no task announced.
const wake_timeout: std.Io.Clock.Duration = .{ .raw = .fromSeconds(10), .clock = .awake };

/// Pump until `done(context)` holds; a missed wake fails the test at the timeout.
pub fn pumpUntil(host: *Host, context: anytype, comptime done: fn (@TypeOf(context)) bool) !void {
    try host.pumpUntil(.fromNow(host.io, wake_timeout), context, done);
}

/// Pump and poll a condition that no task announces, such as the end of a process.
pub fn pumpPolling(host: *Host, context: anytype, comptime done: fn (@TypeOf(context)) bool) !void {
    const deadline: std.Io.Clock.Timestamp = .fromNow(host.io, wake_timeout);
    while (true) {
        host.pumpUntil(.fromNow(host.io, .{ .raw = .fromMilliseconds(10), .clock = .awake }), context, done) catch |err| {
            if (err == error.Timeout and deadline.durationFromNow(host.io).raw.nanoseconds > 0) continue;
            return err;
        };
        return;
    }
}

pub fn pumpUntilIdle(host: *Host) !void {
    try pumpUntil(host, host, struct {
        fn idle(h: *Host) bool {
            return h.ops.live.items.len == 0;
        }
    }.idle);
}

pub fn pumpUntilSettled(host: *Host, call: *tools_table.Call) !void {
    try pumpUntil(host, call, struct {
        fn settled(c: *tools_table.Call) bool {
            return c.state == .settled;
        }
    }.settled);
}

/// The task must set `host.wake` after it sets the event.
pub fn pumpUntilSet(host: *Host, event: *const std.Io.Event) !void {
    try pumpUntil(host, event, std.Io.Event.isSet);
}

pub fn pumpUntilTrue(host: *Host, expression: [:0]const u8) !void {
    const Check = struct {
        host: *Host,
        expression: [:0]const u8,
        // A failed read ends the wait, and the read below reports it.
        fn holds(self: @This()) bool {
            return (self.host.evalInt(self.expression) catch return true) != 0;
        }
    };
    try pumpUntil(host, Check{ .host = host, .expression = expression }, Check.holds);
    if (try host.evalInt(expression) == 0) return error.ConditionNeverTrue;
}

/// What one tool call must answer. A null root runs the call in the host workspace.
pub const Answer = struct {
    root: ?[]const u8 = null,
    is_error: bool = false,
    text: union(enum) { contains: []const u8, ends: []const u8, equals: []const u8 },
};

/// Submit one tool call from session 01…01, wait for it, check its answer, and drop it.
pub fn expectTool(host: *Host, name: []const u8, args: []const u8, want: Answer) !void {
    const call = host.calls.submit(name, args, want.root orelse host.cwd);
    call.site = .{ .session_id = .bytes([_]u8{1} ** 16), .message_id = 2, .part_id = 0 };
    try pumpUntilSettled(host, call);
    errdefer std.debug.print("{s} {s} -> {s}\n", .{ name, args, call.text orelse "" });
    try std.testing.expectEqual(want.is_error, call.is_error);
    const text = call.text orelse "";
    switch (want.text) {
        .contains => |part| try std.testing.expect(std.mem.indexOf(u8, text, part) != null),
        .ends => |part| try std.testing.expect(std.mem.endsWith(u8, text, part)),
        .equals => |whole| try std.testing.expectEqualStrings(whole, text),
    }
    try dropCall(host, call);
}

pub fn hasTool(host: *Host, name: []const u8) bool {
    for (host.tools.entries.items) |entry| if (std.mem.eql(u8, entry.decl.name, name)) return true;
    return false;
}

pub fn dropCall(host: *Host, call: *tools_table.Call) !void {
    call.finish();
    try host.pump();
}
