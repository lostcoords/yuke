//! The same transcript scenarios drive correctness tests and release benchmarks.

const std = @import("std");
const execution = @import("../../execution.zig");
const quickjs = @import("quickjs");
const term = @import("term");
const Host = @import("../host.zig").Host;
const Allocations = @import("../../allocations.zig");
const native_term = @import("../native/term.zig");
const Tree = @import("agents.zig");
pub const TreeShape = Tree.Shape;
const Commit = @import("commit.zig");
const Projection = @import("projection.zig");
const SocketPeer = @import("../socket_peer.zig").Peer;
const HttpPeer = @import("../http_peer.zig").Peer;
const builtin = @import("builtin");
const metrics = @import("metrics");
pub const metrics_enabled = builtin.is_test or metrics.enabled;

pub const Phase = enum {
    build,
    reflow,
    scroll,
    stream,
    stream_native,
    stream_tool,
    stream_part,
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
    engine_activity,
    engine_activity_changed,
    advice_direct,
    advice_before,
    advice_around,
    advice_mixed,
    advice_churn,
    exec_short,
    exec_bulk,
    exec_stream,
    fs_read,
    fs_range,
    mcp_result_reused,
    mcp_result_fresh,
    utf8_reused,
    utf8_fresh,
    http_reused,
    http_fresh,
    http_close,
    net_echo,
    net_echo_fresh,
    process_echo,
    process_echo_fresh,
    jobs_output,
    timers_batch,
    tool_call,
    hook_request_build,
    hook_tool_before,
    plugin_sync,
    plugin_async,
    interaction_reused,
    interaction_fresh,

    const Group = enum { transcript, colors, advice, agents, process, tools, hooks, plugins, net, http, utf8, interaction, mcp };

    fn group(self: Phase) Group {
        return switch (self) {
            .exec_short, .exec_bulk, .exec_stream, .fs_read, .fs_range, .process_echo, .process_echo_fresh, .jobs_output, .timers_batch => .process,
            .net_echo, .net_echo_fresh => .net,
            .http_reused, .http_fresh, .http_close => .http,
            .mcp_result_reused, .mcp_result_fresh => .mcp,
            .utf8_reused, .utf8_fresh => .utf8,
            .interaction_reused, .interaction_fresh => .interaction,
            .tool_call => .tools,
            .hook_request_build, .hook_tool_before => .hooks,
            .plugin_sync, .plugin_async => .plugins,
            .colors => .colors,
            .agents_open, .agents_activity, .agents_burst, .agents_structure, .engine_activity, .engine_activity_changed => .agents,
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
    socket_peer: ?*SocketPeer = null,
    http_peer: ?*HttpPeer = null,
    tree_shape: TreeShape = .wide,
    phase: ?Phase = null,
    native_step: usize = 0,
    colors: Colors = .ansi_raw,
    advice_batch_size: u32 = 1000,
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
        self.render = try term.Render.init(io, if (metrics_enabled) self.allocations.allocator() else gpa, &self.env);
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
        if (self.phase_group == .net) {
            self.socket_peer = try SocketPeer.create(gpa, io, .echo);
        }
        errdefer if (self.socket_peer) |peer| peer.destroy();
        if (self.socket_peer) |peer| try ctx.setPropertyStr(global, "SOCKET_PATH", ctx.newString(peer.path));
        if (self.phase_group == .http) self.http_peer = try HttpPeer.create(gpa, io, if (phase == .http_close) .close else .reply);
        errdefer if (self.http_peer) |peer| peer.destroy();
        if (self.http_peer) |peer| try ctx.setPropertyStr(global, "HTTP_URL", ctx.newString(peer.url));
        try self.host.evalModule(switch (self.phase_group) {
            .http => @embedFile("http.js"),
            .interaction => @embedFile("interaction.js"),
            .tools => tool_source,
            .hooks => hook_source,
            .plugins => plugin_source,
            .process => @embedFile("process.js"),
            .net => @embedFile("net.js"),
            .mcp => @embedFile("mcp.js"),
            .utf8 => @embedFile("utf8.js"),
            .agents => @embedFile("agents.js"),
            .colors => @embedFile("colors.js"),
            .advice => @embedFile("advice.js"),
            .transcript => @embedFile("transcript.js"),
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
        if (self.socket_peer) |peer| peer.destroy();
        if (self.http_peer) |peer| peer.destroy();
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
        std.debug.assert(self.advice_batch_size > 0);
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
        if (phase == .projection or phase == .stream_native or phase == .stream_tool or phase == .stream_part)
            self.projection = try Projection.create(self.host, self.host.io, scale, switch (phase) {
                .stream_native => .text,
                .stream_tool => .tool,
                .stream_part => .part,
                else => .none,
            });
        const ctx = self.host.ctx;
        const args = [_]quickjs.Value{
            ctx.newString(@tagName(phase)),
            ctx.newUint32(scale),
            ctx.newUint32(if (phase.group() == .advice) self.advice_batch_size else self.host.paint.width),
            ctx.newInt32(self.host.paint.height),
            ctx.newString(@tagName(self.colors)),
        };
        defer for (args) |arg| ctx.freeValue(arg);
        const function = ctx.getPropertyStr(self.api, "start");
        defer ctx.freeValue(function);
        _ = try self.call(function, &args);
        if (phase == .colors or phase.group() == .agents) _ = try self.call(self.step_fn, &.{});
        if (phase.group() == .agents) _ = try self.host.evalInt("agentResetReads()");
        if (phase == .tool_call) try self.toolOnce();
        if (phase.group() == .hooks) try self.hookOnce(phase);
        if (phase.group() == .plugins) _ = try self.call(self.step_fn, &.{});
        if (phase.group() == .net) try self.drainClosedSockets();
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

    const plugin_source =
        \\import { plugins } from "yuke:ext";
        \\let mode, count = 0;
        \\const sync = { name: "probe", apply(ctx) { ctx.effect(() => () => { count++; }); } };
        \\const async = { name: "probe", async apply(ctx) {
        \\  if (ctx.signal.aborted) throw new Error("fresh signal is aborted");
        \\  await Promise.resolve();
        \\  ctx.own(() => { count++; });
        \\} };
        \\globalThis.bench = {
        \\  start(phase) { mode = phase; count = 0; return 1; },
        \\  step() {
        \\    const handle = plugins.use(mode === "plugin_sync" ? sync : async);
        \\    if (mode === "plugin_sync") { plugins.dispose("probe"); return count; }
        \\    return handle.ready.then(() => handle.dispose()).then(() => count);
        \\  },
        \\  verify() { if (plugins.names().length) throw new Error("plugin remains live"); return count; },
        \\};
    ;

    const tool_source =
        \\import { defineTool } from "yuke:tools";
        \\defineTool("probe", { description: "Benchmark a tool call", parameters: { type: "object", properties: {} }, execute: async (_, signal) => signal.aborted ? "aborted" : "ok" });
        \\globalThis.bench = { start: () => 1, step: () => 1, verify: () => 1 };
    ;

    /// One plugin holds both points, as the agents plugin does: a replace on the request and a pass on the tool.
    const hook_source =
        \\import { plugins } from "yuke:ext";
        \\plugins.use({ name: "probe", apply(ctx) {
        \\  ctx.hook("request.build", (request) => ({ replace: { ...request, system: request.system + "\n\nDo not spawn a child unless the user asks." } }));
        \\  ctx.hook("tool.before", () => null);
        \\} });
        \\globalThis.bench = { start: () => 1, step: () => 1, verify: () => 1 };
    ;

    /// A frozen request.build payload: an 8 KB prompt and the six built-in declarations of 2026-09-20.
    const hook_request_payload =
        \\{"model":"gpt-5.6-luna","system":"You are yuke, an assistant for software development.\nYou are yuke, an assistant for software development.\nYou are yuke, an assistant for software development.\nYou are yuke, an assistant for software development.\nYou are yuke, an assistant for software development.\nYou are yuke, an assistant for software development.\nYou are yuke, an assistant for software development.\nYou are yuke, an assistant for software development.\nYou are yuke, an assistant for software development.\nYou are yuke, an assistant for software development.\nYou are yuke, an assistant for software development.\nYou are yuke, an assistant for software development.\nYou are yuke, an assistant for software development.\nYou are yuke, an assistant for software development.\nYou are yuke, an assistant for software development.\nYou are yuke, an assistant for software development.\nYou are yuke, an assistant for software development.\nYou are yuke, an assistant for software development.\nYou are yuke, an assistant for software development.\nYou are yuke, an assistant for software development.\n# AGENTS.md\n- keep the articles; one idea per sentence; short sentences; consistent terms.\n- keep the articles; one idea per sentence; short sentences; consistent terms.\n- keep the articles; one idea per sentence; short sentences; consistent terms.\n- keep the articles; one idea per sentence; short sentences; consistent terms.\n- keep the articles; one idea per sentence; short sentences; consistent terms.\n- keep the articles; one idea per sentence; short sentences; consistent terms.\n- keep the articles; one idea per sentence; short sentences; consistent terms.\n- keep the articles; one idea per sentence; short sentences; consistent terms.\n- keep the articles; one idea per sentence; short sentences; consistent terms.\n- keep the articles; one idea per sentence; short sentences; consistent terms.\n- keep the articles; one idea per sentence; short sentences; consistent terms.\n- keep the articles; one idea per sentence; short sentences; consistent terms.\n- keep the articles; one idea per sentence; short sentences; consistent terms.\n- keep the articles; one idea per sentence; short sentences; consistent terms.\n- keep the articles; one idea per sentence; short sentences; consistent terms.\n- keep the articles; one idea per sentence; short sentences; consistent terms.\n- keep the articles; one idea per sentence; short sentences; consistent terms.\n- keep the articles; one idea per sentence; short sentences; consistent terms.\n- keep the articles; one idea per sentence; short sentences; consistent terms.\n- keep the articles; one idea per sentence; short sentences; consistent terms.\n- keep the articles; one idea per sentence; short sentences; consistent terms.\n- keep the articles; one idea per sentence; short sentences; consistent terms.\n- keep the articles; one idea per sentence; short sentences; consistent terms.\n- keep the articles; one idea per sentence; short sentences; consistent terms.\n- keep the articles; one idea per sentence; short sentences; consistent terms.\n- keep the articles; one idea per sentence; short sentences; consistent terms.\n- keep the articles; one idea per sentence; short sentences; consistent terms.\n- keep the articles; one idea per sentence; short sentences; consistent terms.\n- keep the articles; one idea per sentence; short sentences; consistent terms.\n- keep the articles; one idea per sentence; short sentences; consistent terms.\n- keep the articles; one idea per sentence; short sentences; consistent terms.\n- keep the articles; one idea per sentence; short sentences; consistent terms.\n- keep the articles; one idea per sentence; short sentences; consistent terms.\n- keep the articles; one idea per sentence; short sentences; consistent terms.\n- keep the articles; one idea per sentence; short sentences; consistent terms.\n- keep the articles; one idea per sentence; short sentences; consistent terms.\n- keep the articles; one idea per sentence; short sentences; consistent terms.\n- keep the articles; one idea per sentence; short sentences; consistent terms.\n- keep the articles; one idea per sentence; short sentences; consistent terms.\n- keep the articles; one idea per sentence; short sentences; consistent terms.\n- keep the articles; one idea per sentence; short sentences; consistent terms.\n- keep the articles; one idea per sentence; short sentences; consistent terms.\n- keep the articles; one idea per sentence; short sentences; consistent terms.\n- keep the articles; one idea per sentence; short sentences; consistent terms.\n- keep the articles; one idea per sentence; short sentences; consistent terms.\n- keep the articles; one idea per sentence; short sentences; consistent terms.\n- keep the articles; one idea per sentence; short sentences; consistent terms.\n- keep the articles; one idea per sentence; short sentences; consistent terms.\n- keep the articles; one idea per sentence; short sentences; consistent terms.\n- keep the articles; one idea per sentence; short sentences; consistent terms.\n- keep the articles; one idea per sentence; short sentences; consistent terms.\n- keep the articles; one idea per sentence; short sentences; consistent terms.\n- keep the articles; one idea per sentence; short sentences; consistent terms.\n- keep the articles; one idea per sentence; short sentences; consistent terms.\n- keep the articles; one idea per sentence; short sentences; consistent terms.\n- keep the articles; one idea per sentence; short sentences; consistent terms.\n- keep the articles; one idea per sentence; short sentences; consistent terms.\n- keep the articles; one idea per sentence; short sentences; consistent terms.\n- keep the articles; one idea per sentence; short sentences; consistent terms.\n- keep the articles; one idea per sentence; short sentences; consistent terms.\n","tools":[{"name":"edit","description":"Replace an exact string in a file. old_string must appear exactly once unless replace_all is true.","input_schema":"{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"A relative path resolves against the workspace root.\"},\"old_string\":{\"type\":\"string\"},\"new_string\":{\"type\":\"string\"},\"replace_all\":{\"type\":\"boolean\",\"description\":\"Replace every non-overlapping match.\"}},\"required\":[\"path\",\"old_string\",\"new_string\"],\"additionalProperties\":false}","strict":false},{"name":"exec","description":"Run a shell command in the working directory and return stdout, stderr, and the exit code. Each call starts a fresh shell and ends every process it started. For a server or watcher, set background: true; never use &, nohup, or setsid.","input_schema":"{\"type\":\"object\",\"properties\":{\"command\":{\"type\":\"string\"},\"timeout_ms\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":600000,\"description\":\"The default is 120000.\"},\"background\":{\"type\":\"boolean\",\"description\":\"Run a server or watcher as a job and return at once.\"}},\"required\":[\"command\"],\"additionalProperties\":false}","strict":false},{"name":"jobs","description":"List the background jobs, or stop one. Pass no argument for the list. Pass id alone for one job and its log path. Pass id and stop: true to request the stop of the job and its process group. A requested stop sends no exit message.","input_schema":"{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\",\"description\":\"The job id, for example j1.\"},\"stop\":{\"type\":\"boolean\"}},\"required\":[],\"additionalProperties\":false}","strict":false},{"name":"read","description":"Read a file with 1-indexed line numbers. Pass the start and end values for a line range. A PNG, JPEG, GIF, or WebP file returns the image.","input_schema":"{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"A relative path resolves against the workspace root.\"},\"start\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":4294967295,\"description\":\"The first line.\"},\"end\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":4294967295,\"description\":\"The last line, inclusive.\"}},\"required\":[\"path\"],\"additionalProperties\":false}","strict":false},{"name":"skill","description":"Load the full instructions for a skill listed in the system prompt. Use this tool when the task matches the skill description.","input_schema":"{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\",\"description\":\"Pass the name from an available_skills entry.\"}},\"required\":[\"name\"],\"additionalProperties\":false}","strict":false},{"name":"write","description":"Create a file or replace its content. Pass the complete content.","input_schema":"{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"A relative path resolves against the workspace root.\"},\"content\":{\"type\":\"string\"}},\"required\":[\"path\",\"content\"],\"additionalProperties\":false}","strict":false}],"max_output_tokens":128000,"context":{"session_id":"01010101010101010101010101010101","parent_id":null,"workspace":"/Users/xyaman/Work/yuke","agent_name":"root"}}
    ;

    const hook_tool_payload =
        \\{"name":"exec","arguments":"{\"command\":\"zig build test --seed 0 --summary new\"}","context":{"session_id":"01010101010101010101010101010101","parent_id":null,"agent_name":"root"}}
    ;

    fn hookOnce(self: *Harness, phase: Phase) !void {
        const point: []const u8 = if (phase == .hook_request_build) "request.build" else "tool.before";
        const payload: []const u8 = if (phase == .hook_request_build) hook_request_payload else hook_tool_payload;
        const held = self.host.calls.submitHook(point, payload);
        defer {
            held.finish();
            self.host.calls.sweep(self.host.ctx);
        }
        try self.host.pump();
        if (held.state != .settled or held.is_error) return error.InvalidToolResult;
        const text = held.text orelse return error.InvalidToolResult;
        // A replace echoes the request; a pass is the empty answer.
        if (phase == .hook_request_build and text.len < payload.len) return error.InvalidToolResult;
        if (phase == .hook_tool_before and text.len != 0) return error.InvalidToolResult;
    }

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
        } else if (phase.group() == .hooks) {
            try self.hookOnce(phase);
        } else if (phase == .boot) {
            try self.bootOnce();
        } else {
            if (phase == .engine_activity_changed) {
                const engine = &self.tree.?.app.engine;
                {
                    engine.beginContinuation();
                    defer engine.endContinuation();
                    try self.host.pump();
                }
                try self.host.pump();
            }
            if (phase == .stream_native) {
                try (self.projection orelse unreachable).appendNative(self.native_step);
                self.native_step += 1;
            }
            if (phase == .stream_tool) try (self.projection orelse unreachable).appendTool();
            if (phase == .stream_part) try (self.projection orelse unreachable).appendPart();
            const rows = try self.call(self.step_fn, &.{});
            if (rows <= 0) return error.EmptyBenchmarkOutput;
        }
        if (phase == .net_echo_fresh) try self.drainClosedSockets();
        return self.output.written().len;
    }

    fn drainClosedSockets(self: *Harness) !void {
        self.host.net.reap(self.host.gpa);
        if (socketsDrained(self.host)) return;
        try self.host.pumpUntil(.fromNow(self.host.io, .{ .raw = .fromSeconds(5), .clock = .awake }), self.host, socketsDrained);
    }

    fn socketsDrained(host: *Host) bool {
        for (host.net.live.items) |connection| if (connection.closed) return false;
        return true;
    }

    pub fn verify(self: *Harness, with_checksum: bool) !i32 {
        std.debug.assert(self.phase != null);
        if (self.commit) |commit| return commit.verify(std.meta.stringToEnum(Commit.Mode, @tagName(self.phase.?)).?);
        self.output.clearRetainingCapacity();
        const ctx = self.host.ctx;
        const function = ctx.getPropertyStr(self.api, "verify");
        defer ctx.freeValue(function);
        const checksum = try self.call(function, &.{ctx.newBool(with_checksum)});
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
        try self.host.pumpUntil(.fromNow(self.host.io, .{ .raw = .fromSeconds(30), .clock = .awake }), self.host, struct {
            fn settled(host: *Host) bool {
                return host.ops.live.items.len == 0 and !host.hasPending();
            }
        }.settled);
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
        if (ctx.isObject(result)) {
            const pending: Host.PendingPromise = .{ .ctx = ctx, .promise = result };
            if (!pending.settled()) try self.host.pumpUntil(.fromNow(self.host.io, .{ .raw = .fromSeconds(30), .clock = .awake }), pending, Host.PendingPromise.settled);
        }
        if (self.phase_group == .agents) try self.settleAgents();
        if (ctx.isObject(result)) {
            if (ctx.promiseState(result) == .Rejected) return error.BenchmarkRejected;
            if (ctx.promiseState(result) == .Fulfilled) {
                const value = ctx.promiseResult(result);
                defer ctx.freeValue(value);
                return ctx.toInt32(value);
            }
        }
        return ctx.toInt32(result);
    }
};

const support = @import("../tests/support.zig");
const paging = @import("../native/engine/paging.zig");

test "benchmark scenarios preserve the transcript across updates and cache eviction" {
    var pool: support.Pool = .{ .backing_allocator = std.testing.allocator };
    defer _ = pool.deinit();
    for (phases) |phase| {
        // Process phases use the single-executor benchmark runtime.
        if (phase.group() == .process or phase.group() == .net or phase.group() == .http) continue;
        const harness = try Harness.create(pool.allocator(), std.testing.io, "", 40, 12, phase);
        defer harness.destroy();
        harness.advice_batch_size = 32;
        // Scale 9 holds 18 messages, above the 16-message row cache, so eviction runs.
        try harness.start(phase, if (phase == .stream_native) 1 else 9);
        // The initial native text exceeds one page, so the client must complete it before the first update.
        if (phase == .stream_native) try std.testing.expect(harness.sourceBytes().? > paging.max_page_bytes);
        for (0..6) |_| _ = try harness.step();
        _ = try harness.verify(false);
    }
}

test "transcript verification preserves row checks without a checksum" {
    var pool: support.Pool = .{ .backing_allocator = std.testing.allocator };
    defer _ = pool.deinit();
    const harness = try Harness.create(pool.allocator(), std.testing.io, "", 40, 12, .build);
    defer harness.destroy();
    try harness.start(.build, 1);
    _ = try harness.step();
    try std.testing.expectEqual(@as(i32, 0), try harness.verify(false));
    const checksum = try harness.verify(true);
    try std.testing.expect(checksum != 0);
    try std.testing.expectEqual(checksum, try harness.host.evalInt("bench.verify()"));
    try harness.host.evalModule(
        \\import { Transcript } from "yuke:transcript";
        \\const rows = Transcript.prototype.rows;
        \\let calls = 0;
        \\Transcript.prototype.rows = function(...args) {
        \\  const result = Reflect.apply(rows, this, args);
        \\  if (++calls === 2) result[0] = { ...result[0], text: "corrupt" };
        \\  return result;
        \\};
        \\globalThis.rejectedMismatch = false;
        \\try { bench.verify(false); } catch (error) { globalThis.rejectedMismatch = error.message.startsWith("build differs at row 0:"); };
        \\Transcript.prototype.rows = () => [];
        \\globalThis.rejectedEmptyRows = false;
        \\try { bench.verify(false); } catch (error) { globalThis.rejectedEmptyRows = error.message === "empty benchmark output"; }
    , "verify-empty-rows.js");
    try std.testing.expectEqual(@as(i32, 1), try harness.host.evalInt("Number(rejectedMismatch && rejectedEmptyRows)"));
}

test "advice batches preserve the default workload and reset their counters" {
    var pool: support.Pool = .{ .backing_allocator = std.testing.allocator };
    defer _ = pool.deinit();
    const harness = try Harness.create(pool.allocator(), std.testing.io, "", 40, 12, .advice_direct);
    defer harness.destroy();
    try std.testing.expectEqual(@as(u32, 1000), harness.advice_batch_size);
    for ([_]u32{ 1000, 32, 1, 1000 }) |batch_size| {
        harness.advice_batch_size = batch_size;
        try harness.start(.advice_direct, 9);
        for (1..3) |steps| {
            _ = try harness.step();
            const expected: i32 = @intCast(steps * (batch_size * 12 + batch_size * (batch_size - 1) / 2));
            try std.testing.expectEqual(expected, try harness.verify(true));
        }
    }
}

test "an unchanged transcript frame has stable cells and no terminal output" {
    var pool: support.Pool = .{ .backing_allocator = std.testing.allocator };
    defer _ = pool.deinit();
    const harness = try Harness.create(pool.allocator(), std.testing.io, "", 40, 12, .paint);
    defer harness.destroy();
    try harness.start(.paint, 1);
    try std.testing.expect(try harness.step() > 0);
    const first = try harness.verify(true);
    const before = harness.counters();
    try std.testing.expectEqual(@as(u64, 0), try harness.step());
    if (metrics_enabled) {
        const after = harness.counters();
        try std.testing.expectEqual(@as(u64, 1), after.frames - before.frames);
        try std.testing.expect(after.text_calls > before.text_calls);
        try std.testing.expect(after.measure_calls - before.measure_calls <= after.text_calls - before.text_calls);
    }
    try std.testing.expectEqual(first, try harness.verify(true));
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
        _ = try harness.verify(true);
    }
}

test "native part refresh validates the draft cursor across replacement and removal" {
    var pool: support.Pool = .{ .backing_allocator = std.testing.allocator };
    defer _ = pool.deinit();
    const harness = try Harness.create(pool.allocator(), std.testing.io, "", 40, 12, .stream_native);
    defer harness.destroy();
    try harness.start(.stream_native, 1);
    const session = harness.projection.?.session;
    try session.draft.?.addPart(.{ .session_id = session.id, .message_id = 2, .part = .{ .reasoning = .{ .id = 1, .text = "why 世界", .signature = "" } } });
    try session.draft.?.addPart(.{ .session_id = session.id, .message_id = 2, .part = .{ .tool = .{ .id = 2, .name = "exec", .arguments = "{}", .state = .pending } } });
    try support.eval(harness.host, "app/part-refresh.test.js");
    session.draft.?.deinit();
    session.draft = null;
    try session.apply(.{ .message_started_data = .{
        .session_id = session.id,
        .message_id = 2,
        .run_id = 2,
        .config_rev = 0,
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
