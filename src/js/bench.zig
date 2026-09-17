//! The same transcript scenarios drive correctness tests and release benchmarks.

const std = @import("std");
const execution = @import("../execution.zig");
const quickjs = @import("quickjs");
const term = @import("term");
const Host = @import("host.zig").Host;
const Allocations = @import("../allocations.zig");
const native_term = @import("native/term.zig");
const Tree = @import("bench_agents.zig");
pub const TreeShape = Tree.Shape;
const Commit = @import("bench_commit.zig");
const Projection = @import("bench_projection.zig");
pub const metrics_enabled = @import("builtin").is_test or @import("metrics").enabled;

pub const Phase = enum {
    build,
    reflow,
    scroll,
    stream,
    stream_native,
    paint,
    colors,
    selection,
    key_routing,
    preview,
    projection,
    gc,
    boot,
    commit,
    commit_serialize,
    commit_size,
    agents_open,
    agents_activity,
    agents_burst,
    agents_structure,
    advice_direct,
    advice_before,
    advice_around,
    advice_mixed,
    advice_churn,
    exec_short,
    exec_bulk,
    fs_read,
    process_echo,
    process_echo_fresh,
    jobs_output,
    timers_batch,
    tool_call,

    const Group = enum { transcript, colors, advice, agents, process, tools };

    fn group(self: Phase) Group {
        return switch (self) {
            .exec_short, .exec_bulk, .fs_read, .process_echo, .process_echo_fresh, .jobs_output, .timers_batch => .process,
            .tool_call => .tools,
            .colors => .colors,
            .agents_open, .agents_activity, .agents_burst, .agents_structure => .agents,
            .advice_direct, .advice_before, .advice_around, .advice_mixed, .advice_churn => .advice,
            else => .transcript,
        };
    }
};
pub const Colors = enum { ansi_raw, rgb_raw, ansi_group, rgb_group, rgb_fresh };
pub const phases = std.enums.values(Phase);

pub const Harness = struct {
    gpa: std.mem.Allocator,
    allocations: Allocations,
    host: *Host,
    env: std.process.Environ.Map,
    render: term.Render,
    output: std.Io.Writer.Allocating,
    api: quickjs.Value,
    step_fn: quickjs.Value,
    projection: ?*Projection = null,
    commit: ?*Commit = null,
    tree: ?*Tree = null,
    tree_shape: TreeShape = .wide,
    phase: ?Phase = null,
    native_step: usize = 0,
    colors: Colors = .ansi_raw,
    phase_group: Phase.Group,

    /// The benchmark borrows its own environment and runs no command of its own.
    fn context(self: *Harness) execution.Context {
        return .{ .env = &self.env, .shell = .{ .path = execution.fallback_shell } };
    }

    pub fn create(gpa: std.mem.Allocator, io: std.Io, fixture: []const u8, width: u16, height: u16, phase: Phase) !*Harness {
        std.debug.assert(width > 1 and height > 0);
        const self = try gpa.create(Harness);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .allocations = .{ .backing = gpa },
            .host = undefined,
            .env = .init(gpa),
            .render = undefined,
            .output = .init(gpa),
            .api = quickjs.UNDEFINED,
            .step_fn = quickjs.UNDEFINED,
            .phase_group = phase.group(),
        };
        errdefer self.env.deinit();
        errdefer self.output.deinit();
        self.render = try term.Render.init(io, if (metrics_enabled) self.allocations.allocator() else gpa, &self.env, .{});
        errdefer self.render.deinit(&self.output.writer);
        try self.render.resize(&self.output.writer, .{ .cols = width, .rows = height, .x_pixel = 0, .y_pixel = 0 });
        self.host = Host.createWith(if (metrics_enabled) self.allocations.allocator() else gpa, io, .{ .cwd = "", .execution = self.context() });
        errdefer self.host.destroy();
        self.host.runtime.setMemoryLimit(1024 * 1024 * 1024);
        self.host.interrupt_budget = std.math.maxInt(u32);
        self.host.paint.bindRender(self.host.ctx, &self.render, &self.output.writer);
        const ctx = self.host.ctx;
        const global = ctx.getGlobalObject();
        defer ctx.freeValue(global);
        try ctx.setPropertyStr(global, "FIXTURE", ctx.newString(fixture));
        try self.host.evalModule(switch (self.phase_group) {
            .tools => tool_source,
            .process => @embedFile("bench_process.js"),
            .agents => @embedFile("bench_agents.js"),
            .colors => @embedFile("bench_colors.js"),
            .advice => @embedFile("bench_advice.js"),
            .transcript => @embedFile("bench.js"),
        }, "bench.js");
        self.api = ctx.getPropertyStr(global, "bench");
        self.step_fn = ctx.getPropertyStr(self.api, "step");
        std.debug.assert(ctx.isObject(self.api));
        std.debug.assert(ctx.isFunction(self.step_fn));
        return self;
    }

    pub fn destroy(self: *Harness) void {
        const gpa = self.gpa;
        self.host.engine.detach();
        if (self.tree) |tree| tree.destroy();
        if (self.commit) |commit| commit.destroy();
        if (self.projection) |projection| projection.destroy();
        self.host.ctx.freeValue(self.step_fn);
        self.host.ctx.freeValue(self.api);
        self.host.destroy();
        self.render.deinit(&self.output.writer);
        std.debug.assert(self.allocations.liveBytes() == 0);
        std.debug.assert(self.allocations.liveCount() == 0);
        self.output.deinit();
        self.env.deinit();
        gpa.destroy(self);
    }

    pub fn start(self: *Harness, phase: Phase, scale: u32) !void {
        std.debug.assert(scale > 0);
        std.debug.assert(self.phase_group == phase.group());
        self.phase = null;
        self.native_step = 0;
        self.host.engine.detach();
        if (self.tree) |tree| tree.destroy();
        if (self.commit) |commit| commit.destroy();
        if (self.projection) |projection| projection.destroy();
        self.projection = null;
        self.commit = null;
        self.tree = null;
        if (phase.group() == .agents) self.tree = try Tree.create(self.host, scale, self.tree_shape);
        if (std.meta.stringToEnum(Commit.Mode, @tagName(phase))) |mode| {
            self.commit = try Commit.create(self.host.gpa, scale);
            try self.commit.?.step(mode);
            self.allocations.resetPeak();
            if (metrics_enabled) self.host.paint.counters = .{};
            self.phase = phase;
            return;
        }
        if (phase == .projection or phase == .stream_native)
            self.projection = try Projection.create(self.host, self.host.io, scale, phase == .stream_native);
        const ctx = self.host.ctx;
        const args = [_]quickjs.Value{
            ctx.newString(@tagName(phase)),       ctx.newUint32(scale),
            ctx.newInt32(self.host.paint.width),  ctx.newInt32(self.host.paint.height),
            ctx.newString(@tagName(self.colors)),
        };
        defer for (args) |arg| ctx.freeValue(arg);
        const function = ctx.getPropertyStr(self.api, "start");
        defer ctx.freeValue(function);
        _ = try self.call(function, &args);
        if (phase == .colors or phase.group() == .agents) _ = try self.call(self.step_fn, &.{});
        if (phase.group() == .agents) _ = try self.host.evalInt("agentResetReads()");
        if (phase == .tool_call) try self.toolOnce();
        self.host.runtime.runGC();
        self.output.clearRetainingCapacity();
        self.allocations.resetPeak();
        if (metrics_enabled) self.host.paint.counters = .{};
        self.phase = phase;
    }

    /// The frontend boots this way, so the phase pays for the runtime, the modules, and the plugins.
    const boot_source =
        \\import { plugins } from "yuke:ext";
        \\import { tuiPlugin } from "yuke:tui";
        \\import "yuke:core";
        \\import "yuke:defaults";
        \\plugins.use(tuiPlugin);
    ;

    /// Boot one throwaway host. A fresh runtime parses every module again, which one host would cache.
    fn bootOnce(self: *Harness) !void {
        const host = Host.createWith(self.host.gpa, self.host.io, .{ .cwd = "", .execution = self.context() });
        defer host.destroy();
        host.interrupt_budget = std.math.maxInt(u32);
        try host.evalModule(boot_source, "boot.js");
    }

    const tool_source =
        \\import { defineTool } from "yuke:tools";
        \\defineTool("probe", { description: "Benchmark a tool call", parameters: { type: "object", properties: {} }, execute: async (_, signal) => signal.aborted ? "aborted" : "ok" });
        \\globalThis.bench = { start: () => 1, step: () => 1, verify: () => 1 };
    ;

    fn toolOnce(self: *Harness) !void {
        const invocation = self.host.calls.submit("probe", "{}", "");
        defer {
            invocation.finish();
            self.host.calls.sweep(self.host.ctx);
        }
        try self.host.pump();
        if (invocation.state != .settled or invocation.is_error) return error.InvalidToolResult;
        if (!std.mem.eql(u8, invocation.text orelse return error.InvalidToolResult, "ok")) return error.InvalidToolResult;
    }

    pub fn step(self: *Harness) !u64 {
        const phase = self.phase orelse unreachable;
        self.output.clearRetainingCapacity();
        if (self.commit) |commit| {
            try commit.step(std.meta.stringToEnum(Commit.Mode, @tagName(phase)).?);
        } else if (phase == .gc) {
            self.host.runtime.runGC();
        } else if (phase == .tool_call) {
            try self.toolOnce();
        } else if (phase == .boot) {
            try self.bootOnce();
        } else {
            if (phase == .stream_native) {
                try (self.projection orelse unreachable).appendNative(self.native_step);
                self.native_step += 1;
            }
            const rows = try self.call(self.step_fn, &.{});
            if (rows <= 0) return error.EmptyBenchmarkOutput;
        }
        return self.output.written().len;
    }

    pub fn verify(self: *Harness) !i32 {
        std.debug.assert(self.phase != null);
        if (self.commit) |commit| return commit.verify(std.meta.stringToEnum(Commit.Mode, @tagName(self.phase.?)).?);
        self.output.clearRetainingCapacity();
        const ctx = self.host.ctx;
        const function = ctx.getPropertyStr(self.api, "verify");
        defer ctx.freeValue(function);
        const checksum = try self.call(function, &.{});
        if (self.output.written().len != 0) return error.FrameMismatch;
        return checksum;
    }

    pub fn counters(self: *const Harness) native_term.Counters {
        return if (metrics_enabled) self.host.paint.counters else .{};
    }

    pub fn sourceBytes(self: *const Harness) ?u64 {
        if (self.commit) |commit| return commit.source_bytes;
        return if (self.projection) |projection| projection.sourceBytes() else null;
    }

    pub fn requests(self: *Harness) !?struct { gets: i32, lists: i32, updates: i32 } {
        if (self.phase_group != .agents) return null;
        return .{
            .gets = try self.host.evalInt("agentReads().gets"),
            .lists = try self.host.evalInt("agentReads().lists"),
            .updates = try self.host.evalInt("agentReads().updates"),
        };
    }

    fn settleAgents(self: *Harness) !void {
        const deadline = std.Io.Clock.Timestamp.fromNow(self.host.io, .{ .raw = .fromSeconds(30), .clock = .awake });
        while (true) {
            try self.host.pump();
            if (self.host.ops.live.items.len == 0 and !self.host.hasPending()) return;
            if (deadline.durationFromNow(self.host.io).raw.nanoseconds <= 0) return error.AgentBenchmarkTimeout;
            self.host.wake.reset();
            if (self.host.hasPending()) continue;
            self.host.wake.waitTimeout(self.host.io, .{ .deadline = deadline }) catch |err| switch (err) {
                error.Timeout => continue,
                else => return err,
            };
        }
    }

    fn call(self: *Harness, function: quickjs.Value, args: []const quickjs.Value) !i32 {
        const ctx = self.host.ctx;
        std.debug.assert(ctx.isFunction(function));
        self.host.enterSlice();
        const result = ctx.call(function, self.api, args);
        defer ctx.freeValue(result);
        if (ctx.isException(result)) {
            self.host.noteFault();
            std.log.err("benchmark: {s}", .{self.host.faultText()});
            return error.JavaScriptFault;
        }
        if (self.phase_group == .process and ctx.isObject(result)) {
            const deadline = std.Io.Clock.Timestamp.fromNow(self.host.io, .{ .raw = .fromSeconds(30), .clock = .awake });
            while (ctx.promiseState(result) == .Pending) {
                self.host.wake.reset();
                try self.host.pump();
                if (ctx.promiseState(result) != .Pending) break;
                if (deadline.durationFromNow(self.host.io).raw.nanoseconds <= 0) return error.ProcessBenchmarkTimeout;
                self.host.wake.waitTimeout(self.host.io, .{ .duration = .{ .raw = .fromMilliseconds(1), .clock = .awake } }) catch |err| switch (err) {
                    error.Timeout => {},
                    else => return err,
                };
            }
        }
        if (self.phase_group == .agents or self.phase_group == .process) {
            if (self.phase_group == .agents) try self.settleAgents();
            if (ctx.isObject(result) and ctx.promiseState(result) == .Rejected) return error.AgentBenchmarkRejected;
            if (ctx.isObject(result) and ctx.promiseState(result) == .Fulfilled) {
                const value = ctx.promiseResult(result);
                defer ctx.freeValue(value);
                return ctx.toInt32(value);
            }
        }
        return ctx.toInt32(result);
    }
};

test "benchmark scenarios preserve the transcript across updates and cache eviction" {
    var pool: support.Pool = .{ .backing_allocator = std.testing.allocator };
    defer _ = pool.deinit();
    for (phases) |phase| {
        // Process phases use the single-executor benchmark runtime.
        if (phase.group() == .process) continue;
        const harness = try Harness.create(pool.allocator(), std.testing.io, "", 40, 12, phase);
        defer harness.destroy();
        // Scale 9 holds 18 messages, above the 16-message row cache, so eviction runs.
        try harness.start(phase, if (phase == .stream_native) 1 else 9);
        // The initial native text exceeds one page, so the client must complete it before the first update.
        if (phase == .stream_native) try std.testing.expect(harness.sourceBytes().? > paging.max_page_bytes);
        for (0..6) |_| _ = try harness.step();
        _ = try harness.verify();
    }
}

test "an unchanged transcript frame has stable cells and no terminal output" {
    var pool: support.Pool = .{ .backing_allocator = std.testing.allocator };
    defer _ = pool.deinit();
    const harness = try Harness.create(pool.allocator(), std.testing.io, "", 40, 12, .paint);
    defer harness.destroy();
    try harness.start(.paint, 1);
    try std.testing.expect(try harness.step() > 0);
    const first = try harness.verify();
    const before = harness.counters();
    try std.testing.expectEqual(@as(u64, 0), try harness.step());
    if (metrics_enabled) {
        const after = harness.counters();
        try std.testing.expectEqual(@as(u64, 1), after.frames - before.frames);
        try std.testing.expect(after.text_calls > before.text_calls);
        try std.testing.expect(after.measure_calls - before.measure_calls <= after.text_calls - before.text_calls);
    }
    try std.testing.expectEqual(first, try harness.verify());
}

test "reused RGB and ANSI colors need no backing allocations after warmup" {
    var pool: support.Pool = .{ .backing_allocator = std.testing.allocator };
    defer _ = pool.deinit();
    const harness = try Harness.create(pool.allocator(), std.testing.io, "", 40, 12, .colors);
    defer harness.destroy();
    for ([_]Colors{ .ansi_raw, .rgb_raw, .ansi_group, .rgb_group }) |colors| {
        harness.colors = colors;
        try harness.start(.colors, 1);
        const before = harness.allocations.counts;
        for (0..8) |_| try std.testing.expectEqual(@as(u64, 0), try harness.step());
        const counts = harness.allocations.counts.since(before);
        try std.testing.expectEqualDeep(Allocations.Counts{}, counts);
        _ = try harness.verify();
    }
}

const support = @import("test_support.zig");
const paging = @import("native/engine/paging.zig");

test "native part refresh validates the draft cursor across replacement and removal" {
    var pool: support.Pool = .{ .backing_allocator = std.testing.allocator };
    defer _ = pool.deinit();
    const harness = try Harness.create(pool.allocator(), std.testing.io, "", 40, 12, .stream_native);
    defer harness.destroy();
    try harness.start(.stream_native, 1);
    const session = harness.projection.?.session;
    try session.draft.?.addPart(.{ .session_id = session.id, .message_id = 2, .part = .{ .reasoning = .{ .id = 1, .text = "why 世界", .signature = "" } } });
    try session.draft.?.addPart(.{ .session_id = session.id, .message_id = 2, .part = .{ .tool = .{ .id = 2, .name = "exec", .arguments = "{}", .state = .pending } } });
    try support.eval(harness.host, "tests/app/part-refresh.test.js");
    session.draft.?.deinit();
    session.draft = null;
    try session.apply(.{ .message_started_data = .{
        .session_id = session.id,
        .message_id = 2,
        .run_id = 2,
        .config_rev = 0,
        .agent = "bench",
        .created_at_ms = 2,
    } });
    const replacement = try harness.host.gpa.alloc(u8, harness.projection.?.source_bytes + 1);
    defer harness.host.gpa.free(replacement);
    @memset(replacement, 'x');
    try session.draft.?.addPart(.{ .session_id = session.id, .message_id = 2, .part = .{ .text = .{ .id = 0, .text = replacement } } });
    try harness.host.evalModule(
        \\import { client } from "yuke:client";
        \\import { equal } from "yuke:test";
        \\const fresh = client.sessionPart(globalThis.PROJECTION_SESSION, 2, 0, globalThis.previousPart);
        \\equal(fresh.text, "x".repeat(globalThis.STREAM_NATIVE_INITIAL_BYTES + 1));
        \\equal(globalThis.previousPart.text, globalThis.PROJECTION_TEXT);
    , "replacement.js");
    session.draft.?.deinit();
    session.draft = null;
    try harness.host.evalModule(
        \\import { client } from "yuke:client";
        \\import { equal } from "yuke:test";
        \\equal(client.sessionPart(globalThis.PROJECTION_SESSION, 2, 0, globalThis.previousPart), null);
    , "removal.js");
}
