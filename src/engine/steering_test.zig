//! Round boundary tests use real commands, storage, requests, and event folds.

const std = @import("std");
const testing = std.testing;
const proto = @import("proto");
const ai = @import("ai");
const Engine = @import("Engine.zig");
const database = @import("../store/store.zig");
const commands = @import("commands.zig");
const turn = @import("turn.zig");
const hookset = @import("hookset.zig");
const Resources = @import("test_resources.zig");
const registry = @import("../provider/registry.zig");

const Fixture = struct {
    resources: Resources,
    db: database.Database,
    engine: Engine,
    arena: std.heap.ArenaAllocator,
    models: [1]registry.ModelSpec,
    rows: [1]registry.Provider,
    requests: std.ArrayList([]const u8) = .empty,
    stage: Stage = .stream,
    entered: std.Io.Event = .unset,
    release: std.Io.Event = .unset,
    paused: bool = false,
    gate: ?turn.Launch = null,
    run_starts: usize = 0,
    run_done: std.ArrayList(proto.run.RunDoneData) = .empty,
    activity: ?proto.session.SessionActivity = null,
    build_activity: ?proto.session.SessionActivity = null,

    const Stage = enum { stream, build, send, tool, retry };
    const id: proto.ids.SessionId = .bytes([_]u8{73} ** 16);

    fn init(self: *Fixture) !void {
        self.* = .{ .resources = undefined, .db = undefined, .engine = undefined, .arena = .init(testing.allocator), .models = undefined, .rows = undefined };
        try self.resources.init();
        self.db = try database.Database.openTest();
        self.engine = self.resources.makeEngine(&self.db);
        self.models = .{.{ .id = "m", .upstream_id = "m", .name = "M", .caps = .{ .tools = true } }};
        self.rows = .{.{ .id = "mock", .name = "Mock", .models = &self.models, .availability = .{ .ready = .{
            .route = .{ .base_url = "https://example.test", .protocol = .anthropic_messages, .auth = .none },
            .credential = .none,
        } } }};
        self.resources.providers.merged.rows = &self.rows;
        self.engine.deps.route_transport = .{ .ctx = self, .vtable = &.{ .open = open } };
        self.engine.deps.retry_policy = .{ .base_ms = 0, .cap_ms = 0 };
        self.engine.installHooks(.{ .ctx = self, .holds = holds, .ask = ask });
        self.engine.sinks.add(.{ .ctx = self, .on_event = onEvent });
        try database.session.create(&self.db, .{ .id = id.raw, .root = "/work", .origin = "root", .profile = "default", .model = "mock/m", .reasoning = "", .config_rev = 0, .title = "test", .created_at_ms = 1, .updated_at_ms = 1 });
        _ = try database.session.setPrompt(&self.db, self.arena.allocator(), id.raw, .{ .base = "", .child_policy = null, .environment = "" });
    }

    fn deinit(self: *Fixture) void {
        self.release.set(self.engine.deps.io);
        self.engine.close();
        self.resources.providers.merged.rows = &.{};
        self.db.deinit();
        self.resources.deinit();
        self.arena.deinit();
    }

    fn send(self: *Fixture, text: []const u8) !proto.session.SessionSendInputResult {
        return commands.sessionSendInputForRpc(&self.engine, self.arena.allocator(), .{ .session_id = id, .input = .{ .content = .{ .content = &.{.{ .text = .{ .text = text } }} } } }, &self.gate, null);
    }

    fn start(self: *Fixture) !void {
        _ = try self.send("initial task");
        turn.Launch.release(&self.gate, &self.engine);
        try self.entered.waitTimeout(self.engine.deps.io, .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } });
    }

    fn finish(self: *Fixture) !void {
        self.release.set(self.engine.deps.io);
        for (0..1000) |_| {
            const resident = self.engine.sessions.get(id);
            if (resident == null or (resident.?.active_run == null and resident.?.queueDepth() == 0)) return;
            try std.Io.sleep(self.engine.deps.io, .fromMilliseconds(1), .awake);
        }
        return error.RunDidNotFinish;
    }

    fn pause(self: *Fixture) !void {
        if (self.paused) return;
        self.paused = true;
        self.entered.set(self.engine.deps.io);
        try self.release.waitTimeout(self.engine.deps.io, .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } });
    }

    fn onEvent(ctx: *anyopaque, note: proto.rpc.Notification) void {
        const self: *Fixture = @ptrCast(@alignCast(ctx));
        const a = self.arena.allocator();
        switch (note.method) {
            .@"run.started" => self.run_starts += 1,
            .@"run.done" => self.run_done.append(a, proto.dupe(a, note.params.run_done_data) catch @panic("out of memory")) catch @panic("out of memory"),
            .@"session.activity_changed" => self.activity = proto.dupe(a, note.params.session_activity_changed_data.activity) catch @panic("out of memory"),
            else => {},
        }
    }

    fn holds(ctx: *anyopaque, point: proto.hook.Point) bool {
        const self: *Fixture = @ptrCast(@alignCast(ctx));
        return switch (self.stage) {
            .build => point == .@"request.build",
            .send => point == .@"request.send",
            .tool => point == .@"tool.before",
            else => false,
        };
    }

    fn ask(ctx: *anyopaque, _: std.mem.Allocator, _: proto.hook.Point, _: []const u8) hookset.Decision {
        const self: *Fixture = @ptrCast(@alignCast(ctx));
        if (self.stage == .build) self.build_activity = self.activity;
        self.pause() catch return .canceled;
        return if (self.stage == .tool) .{ .block = "settled tool result" } else .proceed;
    }

    fn open(ctx: *anyopaque, arena: std.mem.Allocator, request: ai.transport.Request, _: *ai.transport.AttemptInfo) !ai.transport.ResponseBody {
        const self: *Fixture = @ptrCast(@alignCast(ctx));
        const index = self.requests.items.len;
        try self.requests.append(self.arena.allocator(), try self.arena.allocator().dupe(u8, request.body));
        if (index > 5) return error.UnexpectedRequest;
        if (self.stage == .retry and index == 0) {
            try self.pause();
            return error.ConnectionRefused;
        }
        const body = try arena.create(Body);
        body.* = .{ .fixture = self, .bytes = if (self.stage == .tool and index == 0) tool_reply else ai.transport.canned_reply, .gated = self.stage == .stream and index == 0 };
        return .{ .ctx = body, .vtable = &.{ .peek = Body.peek, .toss = Body.toss, .deinit = Body.close } };
    }

    const Body = struct {
        fixture: *Fixture,
        bytes: []const u8,
        pos: usize = 0,
        gated: bool,

        /// Deliver the whole gate prefix, then pause one time before the rest of the reply.
        fn peek(ctx: *anyopaque) anyerror![]const u8 {
            const self: *Body = @ptrCast(@alignCast(ctx));
            const gate = if (self.gated)
                std.mem.indexOf(u8, self.bytes, "data: {\"type\":\"message_delta\"") orelse self.bytes.len / 2
            else
                self.bytes.len;
            if (self.pos < gate) return self.bytes[self.pos..gate];
            if (self.gated) try self.fixture.pause();
            return self.bytes[self.pos..];
        }

        fn toss(ctx: *anyopaque, count: usize) void {
            const self: *Body = @ptrCast(@alignCast(ctx));
            self.pos += count;
        }

        fn close(_: *anyopaque) void {}
    };

    fn history(self: *Fixture) ![]const proto.message.Message {
        return (try database.message.historyPage(&self.db, self.arena.allocator(), id.raw, 0, 100)).messages;
    }
};

const tool_reply =
    "data: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":0}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"unknown\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

test "input during a response or hook joins the next round in FIFO order" {
    for ([_]Fixture.Stage{ .stream, .build, .send, .tool }) |stage| {
        var f: Fixture = undefined;
        try f.init();
        defer f.deinit();
        f.stage = stage;
        try f.start();
        const one = try f.send("steer one");
        const two = try f.send("steer two");
        try testing.expect(one == .queued and two == .queued);
        try testing.expectEqual(@as(u64, 2), try database.input.count(&f.db, f.arena.allocator(), Fixture.id.raw));
        try testing.expectEqual(@as(usize, 1), (try f.history()).len);
        try f.finish();
        try testing.expectEqual(@as(usize, 2), f.requests.items.len);
        try testing.expect(std.mem.indexOf(u8, f.requests.items[0], "steer one") == null);
        try testing.expect(std.mem.indexOf(u8, f.requests.items[1], "steer one").? < std.mem.indexOf(u8, f.requests.items[1], "steer two").?);
        if (stage == .tool) try testing.expect(std.mem.indexOf(u8, f.requests.items[1], "settled tool result") != null);
        if (stage == .build) {
            try testing.expectEqual(@as(u64, 0), f.build_activity.?.queued);
            try testing.expect(f.build_activity.?.state == .building);
        }
        const messages = try f.history();
        try testing.expectEqual(@as(usize, 5), messages.len);
        for (messages, 1..) |message, id| try testing.expectEqual(id, message.id());
        try testing.expectEqual(one.queued.input_id, messages[2].user.input_id);
        try testing.expectEqual(two.queued.input_id, messages[3].user.input_id);
        try testing.expectEqual(messages[1].assistant.run_id, messages[4].assistant.run_id);
        try testing.expectEqual(@as(usize, 1), f.run_starts);
        try testing.expectEqual(@as(usize, 1), f.run_done.items.len);
        try testing.expectEqual(@as(u64, 2), (try database.run.latestOutcome(&f.db, f.arena.allocator(), Fixture.id.raw)).?.turn.rounds);
        try testing.expectEqual(@as(u64, 0), try database.input.count(&f.db, f.arena.allocator(), Fixture.id.raw));
    }
}

test "a retry keeps its request bytes and delivers steering on the next round" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.stage = .retry;
    try f.start();
    _ = try f.send("steer after retry");
    try f.finish();
    try testing.expectEqual(@as(usize, 3), f.requests.items.len);
    try testing.expectEqualStrings(f.requests.items[0], f.requests.items[1]);
    try testing.expect(std.mem.indexOf(u8, f.requests.items[2], "steer after retry") != null);
    try testing.expectEqual(@as(usize, 1), f.run_starts);
}

test "input before launch joins the first request without an early assistant id" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    _ = try f.send("initial task");
    const launch = f.gate;
    f.gate = null;
    _ = try f.send("before launch");
    f.gate = launch;
    f.release.set(f.engine.deps.io);
    turn.Launch.release(&f.gate, &f.engine);
    try f.finish();
    try testing.expectEqual(@as(usize, 1), f.requests.items.len);
    try testing.expect(std.mem.indexOf(u8, f.requests.items[0], "before launch") != null);
    const messages = try f.history();
    try testing.expectEqual(@as(usize, 3), messages.len);
    try testing.expectEqual(@as(u64, 2), messages[1].user.id);
    try testing.expectEqual(@as(u64, 3), messages[2].assistant.id);
}

test "cancel preserves pending input unless clear_queue is set" {
    for ([_]Fixture.Stage{ .stream, .build }) |stage| {
        for ([_]bool{ false, true }) |clear| {
            var f: Fixture = undefined;
            try f.init();
            defer f.deinit();
            f.stage = stage;
            try f.start();
            const queued = try f.send("after cancel");
            const canceled = try commands.sessionCancelRun(&f.engine, f.arena.allocator(), .{ .session_id = Fixture.id, .clear_queue = clear });
            try testing.expectEqual(@as(usize, if (clear) 1 else 0), canceled.cleared_inputs.len);
            try f.finish();
            try testing.expectEqual(@as(usize, if (clear) 1 else 2), f.run_starts);
            var found = false;
            for (try f.history()) |message| {
                if (message == .user and message.user.input_id == queued.queued.input_id) found = true;
                if (message == .assistant and message.assistant.run_id == 1) {
                    try testing.expect(stage == .stream);
                    try testing.expectEqual(proto.enums.StopReason.canceled, message.assistant.finish.?);
                }
            }
            try testing.expectEqual(!clear, found);
            try testing.expect(f.run_done.items[0].outcome == .canceled);
        }
    }
}

test "steering respects the pinned round limit and leaves excess input for a new run" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    _ = try commands.sessionPatch(&f.engine, a, .{ .session_id = Fixture.id, .patch = .{ .max_rounds = 1 } });
    try f.start();
    _ = try commands.sessionPatch(&f.engine, a, .{ .session_id = Fixture.id, .patch = .{ .max_rounds = 4 } });
    _ = try f.send("next run after cap");
    try f.finish();
    const messages = try f.history();
    try testing.expectEqual(@as(usize, 4), messages.len);
    try testing.expectEqualStrings("max_rounds", messages[1].assistant.@"error".?.type);
    try testing.expectEqual(@as(u64, 1), messages[1].assistant.run_id);
    try testing.expectEqual(@as(u64, 1), messages[1].assistant.config_rev);
    try testing.expectEqual(@as(u64, 2), messages[3].assistant.run_id);
    try testing.expectEqual(@as(u64, 2), messages[3].assistant.config_rev);
    try testing.expectEqual(@as(usize, 2), f.run_done.items.len);
}

test "input accepted after run completion starts a new run" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.start();
    try f.finish();
    const next = try f.send("next task");
    try testing.expectEqual(@as(u64, 2), next.started.run_id);
    turn.Launch.release(&f.gate, &f.engine);
    try f.finish();
    try testing.expectEqual(@as(usize, 2), f.run_starts);
    try testing.expectEqual(@as(usize, 2), f.run_done.items.len);
}

test "a protected child report joins its active parent at the next boundary" {
    const reports = @import("reports.zig");
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.start();
    const a = f.arena.allocator();
    const child: proto.ids.SessionId = .bytes([_]u8{75} ** 16);
    try database.session.create(&f.db, .{ .id = child.raw, .root = "/work", .origin = "child", .parent_id = Fixture.id.raw, .parent_message_id = 2, .parent_part_id = 0, .name = "worker", .profile = "default", .model = "mock/m", .reasoning = "", .config_rev = 0, .title = "child", .created_at_ms = 1, .updated_at_ms = 1 });
    const started = try @import("run.zig").beginTurn(&f.db, f.engine.deps.io, a, child.raw, .{ .content = &.{.{ .text = .{ .text = "child task" } }} }, 0);
    const report = blk: {
        var tx = try f.db.begin();
        defer tx.deinit();
        const terminal = try reports.append(&f.engine, a, .{ .session_id = child, .seq = 0, .run_id = started.handle.started.run_id, .kind = .turn, .timing = .{ .started_at_ms = started.handle.started.started_at_ms, .ended_at_ms = f.engine.nowMillis() }, .outcome = .{ .turn = .{ .finish = .stop, .rounds = 0 } } });
        try tx.commit();
        break :blk terminal.report.?;
    };
    reports.publishReport(&f.engine, report, true);
    try testing.expectEqual(@as(i64, 1), (try f.db.queries.child_report_credits.one(a, .{ .parent_id = Fixture.id.raw })).value.used);
    try testing.expectError(error.ProtectedInput, commands.sessionCancelInput(&f.engine, a, .{ .session_id = Fixture.id, .input_id = report.input.input_id }));
    try f.finish();
    const messages = try f.history();
    try testing.expectEqual(@as(usize, 4), messages.len);
    try testing.expectEqual(report.input.input_id, messages[2].user.input_id);
    try testing.expectEqualStrings("worker", messages[2].user.source.?.child_report.name);
    try testing.expectEqual(messages[1].assistant.run_id, messages[3].assistant.run_id);
    try testing.expect(std.mem.indexOf(u8, f.requests.items[1], "Report from worker") != null);
    try testing.expectEqual(@as(i64, 0), (try f.db.queries.child_report_credits.one(a, .{ .parent_id = Fixture.id.raw })).value.used);
}

test "input during automatic compaction waits for the next round and keeps message ids ordered" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.models[0].limits.context_window = 20_000;
    const a = f.arena.allocator();
    {
        var tx = try f.db.begin();
        defer tx.deinit();
        for ([_]usize{ 300, 30_000, 300, 7000 }, 0..) |len, i| {
            const id = try database.event.allocMessageId(&f.db, a, Fixture.id.raw);
            const text = try a.alloc(u8, len);
            @memset(text, 'x');
            const message: proto.message.Message = if (i % 2 == 0) .{ .user = .{
                .id = id,
                .input_id = try database.event.allocInputId(&f.db, a, Fixture.id.raw),
                .content = &.{.{ .text = .{ .text = text } }},
                .time = .{ .created_at_ms = 1 },
            } } else .{ .assistant = .{
                .id = id,
                .run_id = 1,
                .config_rev = 0,
                .agent = "test",
                .content = &.{.{ .text = .{ .id = 0, .text = text } }},
                .finish = .stop,
                .time = .{ .created_at_ms = 1 },
            } };
            _ = try database.message.appendCommittedMessage(&f.db, a, Fixture.id.raw, f.engine.newId(), 1, message);
        }
        try tx.commit();
    }
    try f.start();
    const resident = f.engine.sessions.get(Fixture.id).?;
    try testing.expect(resident.active_run.?.compacting);
    try testing.expect(resident.draft == null and resident.active_run.?.progress.current == null);
    _ = try f.send("steer during summary");
    try f.finish();
    try testing.expectEqual(@as(usize, 3), f.requests.items.len);
    try testing.expect(std.mem.indexOf(u8, f.requests.items[1], "steer during summary") == null);
    try testing.expect(std.mem.indexOf(u8, f.requests.items[2], "steer during summary") != null);
    const messages = try f.history();
    try testing.expectEqual(@as(usize, 9), messages.len);
    for (messages, 1..) |message, id| try testing.expectEqual(id, message.id());
    try testing.expect(messages[5] == .compaction);
    try testing.expect(messages[6] == .assistant);
    try testing.expect(messages[7] == .user);
    try testing.expectEqual(messages[5].compaction.run_id, messages[8].assistant.run_id);
    try testing.expectEqual(@as(usize, 1), f.run_done.items.len);
}
