//! Report tests use durable run markers without a provider or a live model.

const std = @import("std");
const proto = @import("proto");
const database = @import("../store/store.zig");
const Engine = @import("Engine.zig");
const reports = @import("reports.zig");
const run = @import("run.zig");
const commands = @import("commands.zig");
const testing = std.testing;
const Resources = @import("test_resources.zig");
const root: proto.ids.SessionId = .bytes([_]u8{1} ** 16);
const child: proto.ids.SessionId = .bytes([_]u8{2} ** 16);

const Fixture = struct {
    resources: Resources,
    db: database.Database,
    arena: std.heap.ArenaAllocator,
    engine: Engine,

    fn init(self: *Fixture) !void {
        try self.resources.init();
        errdefer self.resources.deinit();
        self.db = try database.Database.openTest();
        errdefer self.db.deinit();
        self.arena = .init(testing.allocator);
        errdefer self.arena.deinit();
        self.engine = self.resources.makeEngine(&self.db);
        errdefer self.engine.close();
        for ([_]proto.ids.SessionId{ root, child }) |id| {
            const is_child = std.mem.eql(u8, &id.raw, &child.raw);
            try database.session.create(&self.db, .{
                .id = id.raw,
                .root = "/work",
                .origin = if (is_child) "child" else "root",
                .parent_id = if (is_child) root.raw else null,
                .parent_message_id = if (is_child) 1 else null,
                .parent_part_id = if (is_child) 0 else null,
                .name = if (is_child) "research" else null,
                .profile = "default",
                .model = "test/model",
                .reasoning = "",
                .config_rev = 0,
                .title = "test",
                .created_at_ms = 1,
                .updated_at_ms = 1,
            });
        }
        try self.engine.own(root);
    }

    fn deinit(self: *Fixture) void {
        self.engine.close();
        self.arena.deinit();
        self.db.deinit();
        self.resources.deinit();
    }

    /// The wake runs on the executor; wait until the parent run committed its terminal.
    fn awaitRootRun(self: *Fixture, run_id: u64) !void {
        const a = self.arena.allocator();
        for (0..1000) |_| {
            const marks = (try database.event.highWater(&self.db, a, root.raw)).?;
            if (marks.run_id_high >= run_id and (try database.session.snapshot(&self.db, a, root.raw)).?.open_run_id == null) return;
            try std.Io.sleep(self.resources.runtime.io(), .fromMilliseconds(1), .awake);
        }
        return error.RootRunDidNotFinish;
    }

    fn start(self: *Fixture) !run.Started {
        return run.beginTurn(&self.db, self.resources.runtime.io(), self.arena.allocator(), child.raw, .{ .content = &.{.{ .text = .{ .text = "task" } }} }, 0);
    }

    /// Each text is one committed round with one tool call; only the first round carries tokens.
    fn terminal(self: *Fixture, started: run.Started, texts: []const []const u8, outcome: proto.run.RunOutcome) !reports.Terminal {
        const a = self.arena.allocator();
        var tx = try self.db.begin();
        defer tx.deinit();
        for (texts, 0..) |value, i| _ = try database.message.appendCommittedMessage(&self.db, a, child.raw, self.engine.newId(), self.engine.nowMillis(), .{ .assistant = .{
            .id = try database.event.allocMessageId(&self.db, a, child.raw),
            .run_id = started.handle.started.run_id,
            .config_rev = 0,
            .agent = "child",
            .content = &.{ .{ .tool = .{ .id = 0, .name = "exec", .arguments = "{}", .state = .{ .completed = .{ .output = "", .duration_ms = 1 } } } }, .{ .text = .{ .id = 1, .text = value } } },
            .finish = .stop,
            .tokens = if (i == 0) .{ .input = 10, .output = 5, .reasoning = 0, .cache_read = 0, .cache_write = 0 } else null,
            .time = .{ .created_at_ms = started.handle.started.started_at_ms },
        } });
        const result = try reports.append(&self.engine, a, .{
            .session_id = child,
            .seq = 0,
            .run_id = started.handle.started.run_id,
            .kind = .turn,
            .timing = .{ .started_at_ms = started.handle.started.started_at_ms, .ended_at_ms = self.engine.nowMillis() },
            .outcome = outcome,
        });
        try tx.commit();
        return result;
    }
};

const success: proto.run.RunOutcome = .{ .turn = .{ .finish = .stop, .rounds = 1 } };

test "child reuse reports only the current run and preserves source through promotion" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    const first = try f.terminal(try f.start(), &.{"old answer"}, success);
    try testing.expectEqualStrings("research", first.report.?.input.source.?.child_report.name);
    const usage = first.report.?.input.source.?.child_report.usage;
    try testing.expectEqual(@as(u64, 1), usage.rounds);
    try testing.expectEqual(@as(u64, 1), usage.tool_calls);
    try testing.expectEqual(@as(u64, 10), usage.tokens.input);
    try testing.expect(usage.duration_ms != null);
    const first_text = first.report.?.input.content[0].text.text;
    try testing.expect(std.mem.indexOf(u8, first_text, "Usage: rounds=1, tool calls=1, input/output=10/5 tokens, ") != null);
    try testing.expect(std.mem.indexOf(u8, first_text, "not user input") != null);
    try testing.expect(std.mem.endsWith(u8, first_text, "\n\nold answer"));
    const second = try f.terminal(try f.start(), &.{}, .{ .failed = .{ .code = .provider, .message = "provider failed" } });
    const stored_child = try commands.sessionGet(&f.engine, a, .{ .session_id = child });
    try testing.expectEqual(proto.enums.RunErrorCode.provider, stored_child.last_run.?.failed.code);
    const listed = try commands.sessionList(&f.engine, a, .{ .population = .{ .children = .{ .parent_id = root } } });
    try testing.expectEqual(proto.enums.RunErrorCode.provider, listed.items[0].last_run.?.failed.code);
    const second_text = second.report.?.input.content[0].text.text;
    try testing.expect(std.mem.indexOf(u8, second_text, "old answer") == null);
    try testing.expect(second.report.?.input.source.?.child_report.partial);
    const resident = try f.engine.activate(root);
    try testing.expectEqual(@as(usize, 2), resident.queueDepth());
    try testing.expectEqual(@as(u64, 2), resident.queueEntries()[1].source.?.child_report.run_id);
    const promoted = try run.beginQueuedTurn(&f.db, f.resources.runtime.io(), a, root.raw, 0);
    try testing.expectEqual(@as(usize, 2), promoted.user_commits.len);
    const history = try database.message.historyPage(&f.db, a, root.raw, 0, 10);
    try testing.expectEqual(@as(u64, 1), history.messages[0].user.source.?.child_report.run_id);
    try testing.expectEqual(@as(u64, 2), history.messages[1].user.source.?.child_report.run_id);
    const request = try @import("../provider/request_builder.zig").build(a, history.messages, .{});
    try testing.expectEqualStrings(second_text, request.blocks[1].value.text);
}

test "a full user queue cannot block a terminal report or clear protected input" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    {
        var tx = try f.db.begin();
        defer tx.deinit();
        for (0..proto.meta.limits.max_queued_inputs) |_| _ = try database.input.enqueue(&f.db, a, root.raw, f.engine.newId(), 1, .{ .content = &.{.{ .text = .{ .text = "user work" } }} }, 1);
        try tx.commit();
    }
    const result = try f.terminal(try f.start(), &.{"answer"}, success);
    const input_id = result.report.?.input.input_id;
    try testing.expectEqual(@as(u64, 129), try database.input.count(&f.db, a, root.raw));
    try testing.expectError(error.ProtectedInput, commands.sessionCancelInput(&f.engine, a, .{ .session_id = root, .input_id = input_id }));
    const cleared = try commands.sessionCancelRun(&f.engine, a, .{ .session_id = root, .clear_queue = true });
    try testing.expectEqual(@as(usize, 128), cleared.cleared_inputs.len);
    const queue = try database.input.list(&f.db, a, root.raw);
    try testing.expectEqual(@as(usize, 1), queue.len);
    try testing.expectEqual(input_id, queue[0].input.input_id);
}

test "report credits bound accepted work and preserve capacity after a lower limit" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    for (0..136) |_| _ = try f.terminal(try f.start(), &.{}, success);
    try testing.expectError(error.ReportCapacityFull, reports.reserve(&f.engine, a, root));
    var launch: ?@import("turn.zig").Launch = null;
    const before = (try database.event.highWater(&f.db, a, child.raw)).?.input_id_high;
    try testing.expectError(error.ReportCapacityFull, commands.sessionSendInputForRpc(&f.engine, a, .{ .session_id = child, .input = .{ .content = .{ .content = &.{} } } }, &launch, null));
    try testing.expectEqual(before, (try database.event.highWater(&f.db, a, child.raw)).?.input_id_high);
    try f.engine.setAgentLimits(1, 1);
    try testing.expectError(error.ReportCapacityFull, reports.reserve(&f.engine, a, root));
    _ = try run.beginQueuedTurn(&f.db, f.resources.runtime.io(), a, root.raw, 0);
    try reports.reserve(&f.engine, a, root);
}

test "one report reservation survives each hop from a grandchild to the root" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    const grandchild = [_]u8{3} ** 16;
    try database.session.create(&f.db, .{
        .id = grandchild,
        .root = "/work",
        .origin = "child",
        .parent_id = child.raw,
        .parent_message_id = 1,
        .parent_part_id = 0,
        .name = "scan",
        .profile = "default",
        .model = "test/model",
        .reasoning = "",
        .config_rev = 0,
        .title = "scan",
        .created_at_ms = 1,
        .updated_at_ms = 1,
    });
    try reports.reserve(&f.engine, a, root);
    {
        var tx = try f.db.begin();
        defer tx.deinit();
        _ = try database.input.enqueue(&f.db, a, grandchild, f.engine.newId(), 1, .{ .content = &.{.{ .text = .{ .text = "task" } }} }, 1);
        try tx.commit();
    }
    try testing.expectEqual(@as(i64, 1), (try f.db.queries.child_report_credits.one(a, .{ .parent_id = root.raw })).value.used);
    const started = try run.beginQueuedTurn(&f.db, f.resources.runtime.io(), a, grandchild, 0);
    try testing.expectEqual(@as(i64, 1), (try f.db.queries.child_report_credits.one(a, .{ .parent_id = root.raw })).value.used);
    {
        var tx = try f.db.begin();
        defer tx.deinit();
        const terminal = try reports.append(&f.engine, a, .{
            .session_id = .bytes(grandchild),
            .seq = 0,
            .run_id = started.handle.started.run_id,
            .kind = .turn,
            .timing = .{ .started_at_ms = started.handle.started.started_at_ms, .ended_at_ms = f.engine.nowMillis() },
            .outcome = success,
        });
        try testing.expectEqual(child, terminal.report.?.session_id);
        try testing.expectEqualStrings("scan", terminal.report.?.input.source.?.child_report.name);
        try tx.commit();
    }
    try testing.expectEqual(@as(i64, 1), (try f.db.queries.child_report_credits.one(a, .{ .parent_id = root.raw })).value.used);
    const parent_run = try run.beginQueuedTurn(&f.db, f.resources.runtime.io(), a, child.raw, 0);
    try testing.expectEqual(@as(i64, 1), (try f.db.queries.child_report_credits.one(a, .{ .parent_id = root.raw })).value.used);
    _ = try f.terminal(parent_run, &.{}, success);
    try testing.expectEqual(@as(i64, 1), (try f.db.queries.child_report_credits.one(a, .{ .parent_id = root.raw })).value.used);
    _ = try run.beginQueuedTurn(&f.db, f.resources.runtime.io(), a, root.raw, 0);
    try testing.expectEqual(@as(i64, 0), (try f.db.queries.child_report_credits.one(a, .{ .parent_id = root.raw })).value.used);
}

test "a report transaction failure leaves the run open for repair" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    const started = try f.start();
    try f.db.conn.execNoArgs("CREATE TEMP TRIGGER refuse_report BEFORE INSERT ON pending_inputs BEGIN SELECT RAISE(FAIL, 'test refusal'); END");
    try testing.expectError(error.ConstraintTrigger, f.terminal(started, &.{"answer"}, success));
    try testing.expectEqual(@as(?u64, 1), (try database.session.snapshot(&f.db, a, child.raw)).?.open_run_id);
    try testing.expectEqual(@as(u64, 0), try database.input.count(&f.db, a, root.raw));
    const history = try database.message.historyPage(&f.db, a, child.raw, 0, 10);
    try testing.expectEqual(@as(usize, 1), history.messages.len);
}

test "cancel before admission reports input IDs without a run ID" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    var ids: [2]u64 = undefined;
    {
        var tx = try f.db.begin();
        defer tx.deinit();
        for (&ids) |*id| id.* = (try database.input.enqueue(&f.db, a, child.raw, f.engine.newId(), 1, .{ .content = &.{.{ .text = .{ .text = "task" } }} }, 1)).input.input_id;
        try tx.commit();
    }
    _ = try commands.sessionCancelInput(&f.engine, a, .{ .session_id = child, .input_id = ids[0] });
    _ = try commands.sessionCancelRun(&f.engine, a, .{ .session_id = child, .clear_queue = true });
    try testing.expectEqual(@as(u64, 0), (try database.event.highWater(&f.db, a, child.raw)).?.run_id_high);
    const queue = try database.input.list(&f.db, a, root.raw);
    try testing.expectEqual(@as(usize, 2), queue.len);
    for (queue, ids) |entry, id| {
        try testing.expectEqual(id, entry.input.source.?.child_input_canceled.input_ids[0]);
    }
}

test "a crash notice and parent report commit once without a child retry" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    _ = try f.start();
    f.engine.close();
    f.engine = f.resources.makeEngine(&f.db);
    try f.engine.own(child);
    try f.awaitRootRun(1);
    const parent = try database.message.historyPage(&f.db, a, root.raw, 0, 10);
    try testing.expectEqual(proto.enums.RunErrorCode.interrupted, parent.messages[0].user.source.?.child_report.outcome.failed.code);
    try testing.expectEqual(@as(u64, 0), try database.input.count(&f.db, a, root.raw));
    const history = try database.message.historyPage(&f.db, a, child.raw, 0, 10);
    try testing.expectEqual(@as(usize, 2), history.messages.len);
    try testing.expectEqual(@as(u64, 1), history.messages[1].user.source.?.engine_interruption.run_id);
    try testing.expectEqual(@as(u64, 0), try database.input.count(&f.db, a, child.raw));
    const seq = (try database.event.highWater(&f.db, a, child.raw)).?.seq_high;
    try f.engine.own(child);
    try testing.expectEqual(seq, (try database.event.highWater(&f.db, a, child.raw)).?.seq_high);
}

test "report output has a UTF-8 byte bound and cancellation preserves partial output" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    const text = try std.mem.concat(a, u8, &.{ "x" ** (reports.max_output_bytes - 1), "日本語" });
    const result = try f.terminal(try f.start(), &.{text}, .{ .canceled = .{} });
    const source = result.report.?.input.source.?.child_report;
    try testing.expect(source.partial and source.truncated);
    const body = result.report.?.input.content[0].text.text;
    try testing.expect(std.unicode.utf8ValidateSlice(body));
    try testing.expect(body.len < reports.max_output_bytes + 512);
}

test "compaction does not produce a child turn report" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    var tx = try f.db.begin();
    defer tx.deinit();
    const id = try database.event.allocRunId(&f.db, a, child.raw);
    _ = try database.run.appendStarted(&f.db, a, f.engine.newId(), 1, .{ .session_id = child, .seq = 0, .run_id = id, .kind = .compaction, .config_rev = 0, .started_at_ms = 1 });
    const result = try reports.append(&f.engine, a, .{ .session_id = child, .seq = 0, .run_id = id, .kind = .compaction, .timing = .{ .started_at_ms = 1, .ended_at_ms = 2 }, .outcome = .{ .canceled = .{} } });
    try tx.commit();
    try testing.expect(result.report == null);
    try testing.expectEqual(@as(u64, 0), try database.input.count(&f.db, a, root.raw));
}

test "a failed parent wake preserves the report and an explicit retry starts it" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    _ = try f.terminal(try f.start(), &.{"answer"}, success);
    try f.db.conn.execNoArgs("CREATE TEMP TRIGGER refuse_wake BEFORE INSERT ON messages BEGIN SELECT RAISE(FAIL, 'test refusal'); END");
    try testing.expectError(error.ConstraintTrigger, reports.wake(&f.engine, root));
    try testing.expectEqual(@as(u64, 1), try database.input.count(&f.db, a, root.raw));
    try testing.expect((try database.session.snapshot(&f.db, a, root.raw)).?.open_run_id == null);
    try f.db.conn.execNoArgs("DROP TRIGGER refuse_wake");
    try reports.wake(&f.engine, root);
    try testing.expectEqual(@as(u64, 0), try database.input.count(&f.db, a, root.raw));
    try testing.expectEqual(@as(u64, 1), (try database.event.highWater(&f.db, a, root.raw)).?.run_id_high);
}

test "an owned tree wakes an existing durable report without another terminal event" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    const result = try f.terminal(try f.start(), &.{"saved before the engine stopped"}, success);
    // A closing engine leaves the report durable and starts no run.
    f.engine.stopTurns();
    reports.publishReport(&f.engine, result.report.?, true);
    try testing.expectEqual(@as(u64, 1), try database.input.count(&f.db, a, root.raw));
    f.engine.close();
    f.engine = f.resources.makeEngine(&f.db);
    try f.engine.own(child);
    try f.awaitRootRun(1);
    try testing.expectEqual(@as(u64, 1), (try database.event.highWater(&f.db, a, root.raw)).?.run_id_high);
    try testing.expectEqual(@as(u64, 0), try database.input.count(&f.db, a, root.raw));
    const history = try database.message.historyPage(&f.db, a, root.raw, 0, 10);
    try testing.expectEqual(@as(u64, 1), history.messages[0].user.source.?.child_report.run_id);
    try testing.expectEqual(@as(u64, 1), (try database.event.highWater(&f.db, a, child.raw)).?.run_id_high);
}

test "automatic report wake respects a faulted parent and resumes after repair" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    const parent = try f.engine.activate(root);
    parent.pin();
    defer if (f.engine.sessions.get(root)) |resident| resident.unpin();
    parent.faulted = true;
    const result = try f.terminal(try f.start(), &.{"answer"}, success);
    reports.publishReport(&f.engine, result.report.?, true);
    try std.Io.sleep(f.resources.runtime.io(), .fromMilliseconds(1), .awake);
    try testing.expectEqual(@as(u64, 0), (try database.event.highWater(&f.db, a, root.raw)).?.run_id_high);
    try testing.expectEqual(@as(usize, 1), parent.queueDepth());
    parent.faulted = false;
    reports.requestWake(&f.engine, root);
    for (0..1000) |_| {
        if ((try database.event.highWater(&f.db, a, root.raw)).?.run_id_high > 0) break;
        try std.Io.sleep(f.resources.runtime.io(), .fromMilliseconds(1), .awake);
    }
    try testing.expectEqual(@as(u64, 1), (try database.event.highWater(&f.db, a, root.raw)).?.run_id_high);
    try testing.expectEqual(@as(usize, 0), parent.queueDepth());
}

test "a report sums every round and takes the newest text as its body" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const multi = try f.terminal(try f.start(), &.{ "first round", "newest answer" }, success);
    const usage = multi.report.?.input.source.?.child_report.usage;
    try testing.expectEqual(@as(u64, 2), usage.rounds);
    try testing.expectEqual(@as(u64, 2), usage.tool_calls);
    try testing.expectEqual(@as(u64, 10), usage.tokens.input);
    try testing.expect(std.mem.endsWith(u8, multi.report.?.input.content[0].text.text, "\n\nnewest answer"));
}
