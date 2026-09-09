//! Admission tests hold response gates to make capacity and queue order deterministic.

const std = @import("std");
const proto = @import("proto");
const database = @import("../store/store.zig");
const Engine = @import("Engine.zig");
const commands = @import("commands.zig");
const admission = @import("admission.zig");
const config = @import("agent_config.zig");
const turn = @import("turn.zig");
const Draft = @import("../session/draft.zig").Draft;
const testing = std.testing;
const Resources = @import("test_resources.zig");

const Fixture = struct {
    tmp: testing.TmpDir,
    resources: Resources,
    db: database.Database,
    arena: std.heap.ArenaAllocator,
    engine: Engine,
    parent: proto.ids.SessionId,

    fn init(self: *Fixture) !void {
        return self.initWithPrompt(null);
    }

    fn initWithPrompt(self: *Fixture, base_prompt: ?[]const u8) !void {
        self.tmp = testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        try self.resources.init();
        errdefer self.resources.deinit();
        self.db = try database.Database.openTest();
        errdefer self.db.deinit();
        var path: [std.fs.max_path_bytes]u8 = undefined;
        try self.resources.env.put("XDG_CONFIG_HOME", path[0..try self.tmp.dir.realPath(testing.io, &path)]);
        try self.resources.env.put("YUKE_APPNAME", "agents-test");
        var local = try @import("../provider/provider.zig").config.loadBytes(testing.allocator,
            \\{"version":1,"providers":[{"id":"test","base_url":"http://localhost:1/v1","protocol":"openai_chat","models":[{"id":"model","upstream_id":"model","flags":{"supports_tools":true}}]}]}
        );
        _ = self.resources.providers.installLocal(&local) catch |err| {
            local.deinit();
            return err;
        };
        self.arena = .init(testing.allocator);
        errdefer self.arena.deinit();
        self.engine = self.resources.makeEngine(&self.db);
        errdefer self.engine.close();
        const empty = try config.get(&self.engine, self.arena.allocator());
        _ = try config.update(&self.engine, self.arena.allocator(), .{ .revision = empty.revision, .config = .{ .models = .{ .small = .{ .model = "test/model" } } } });
        const root = try commands.sessionCreate(&self.engine, self.arena.allocator(), .{ .workspace_path = "/work", .model = "test/model", .system_prompt = base_prompt });
        self.parent = root.session.id;
        var launch: ?turn.Launch = null;
        _ = try commands.sessionSendInputForRpc(&self.engine, self.arena.allocator(), .{ .session_id = self.parent, .input = input() }, &launch, null);
        const slot = launch.?.slot;
        slot.phase = .running;
        const resident = self.engine.sessions.get(self.parent).?;
        resident.draft = try Draft.init(testing.allocator, .{ .session_id = self.parent, .message_id = slot.progress.current.?.message_id, .run_id = slot.runId(), .config_rev = 0, .agent = "parent", .created_at_ms = 1 });
        try resident.draft.?.addPart(.{ .session_id = self.parent, .message_id = slot.progress.current.?.message_id, .part = .{ .tool = .{ .id = 0, .name = "delegate", .arguments = "{}", .state = .{ .running = .{ .started_at_ms = 1 } } } } });
    }

    fn deinit(self: *Fixture) void {
        self.engine.close();
        self.arena.deinit();
        self.db.deinit();
        self.resources.deinit();
        self.tmp.cleanup();
    }

    fn params(self: *Fixture, name: []const u8) proto.misc.CreateSession {
        return .{ .workspace_path = "/work", .model = "test/model", .initial_input = input(), .child = .{ .slot = .small, .site = .{ .session_id = self.parent, .message_id = 2, .part_id = 0 }, .name = name } };
    }

    fn child(self: *Fixture, name: []const u8, launch: *?turn.Launch) !proto.session.SessionResult {
        return commands.sessionCreateForRpc(&self.engine, self.arena.allocator(), self.params(name), launch, null);
    }

    fn toolSite(self: *Fixture, id: proto.ids.SessionId) !proto.input.ToolSite {
        const resident = self.engine.sessions.get(id).?;
        const slot = resident.active_run.?;
        std.debug.assert(resident.draft == null);
        slot.phase = .running;
        const message_id = slot.progress.current.?.message_id;
        resident.draft = try Draft.init(testing.allocator, .{ .session_id = id, .message_id = message_id, .run_id = slot.runId(), .config_rev = 0, .agent = "parent", .created_at_ms = 1 });
        try resident.draft.?.addPart(.{ .session_id = id, .message_id = message_id, .part = .{ .tool = .{ .id = 0, .name = "delegate", .arguments = "{}", .state = .{ .running = .{ .started_at_ms = 1 } } } } });
        return .{ .session_id = id, .message_id = message_id, .part_id = 0 };
    }

    fn releaseParent(self: *Fixture, launch: *?turn.Launch) void {
        const slot = launch.*.?.slot;
        const resident = self.engine.sessions.get(slot.sessionId()).?;
        std.debug.assert(resident.draft != null);
        resident.draft.?.deinit();
        resident.draft = null;
        slot.phase = .pending_start;
        turn.Launch.release(launch, &self.engine);
    }
};

fn input() proto.input.Input {
    return .{ .content = .{ .content = &.{.{ .text = .{ .text = "task" } }} } };
}

test "depth limits admit grandchildren and keep names local to each parent" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    var child_launch: ?turn.Launch = null;
    const child = try f.child("review", &child_launch);
    var params = f.params("review");
    params.child.?.site = try f.toolSite(child.session.id);
    var grandchild_launch: ?turn.Launch = null;
    try testing.expectError(error.AgentDepthLimit, commands.sessionCreateForRpc(&f.engine, a, params, &grandchild_launch, null));
    try f.engine.setAgentLimits(8, 2);
    const grandchild = try commands.sessionCreateForRpc(&f.engine, a, params, &grandchild_launch, null);
    try testing.expectEqual(@as(u32, 2), grandchild_launch.?.slot.depth);
    try testing.expectEqual(f.parent, grandchild_launch.?.slot.tree_root);
    params.child.?.site = .{ .session_id = grandchild.session.id, .message_id = 2, .part_id = 0 };
    var refused: ?turn.Launch = null;
    try testing.expectError(error.AgentDepthLimit, commands.sessionCreateForRpc(&f.engine, a, params, &refused, null));
}

test "one tree limit queues grandchildren and resumes their parent after reports" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    try f.engine.setAgentLimits(1, 2);
    var child_launch: ?turn.Launch = null;
    const child = try f.child("review", &child_launch);
    var params = f.params("scan");
    params.child.?.site = try f.toolSite(child.session.id);
    var grandchild_launch: ?turn.Launch = null;
    const grandchild = try commands.sessionCreateForRpc(&f.engine, a, params, &grandchild_launch, null);
    try testing.expectEqual(@as(u64, 1), grandchild.input.?.queued.capacity.?.active);
    try testing.expectEqual(@as(u64, 0), (try database.event.highWater(&f.db, a, grandchild.session.id.raw)).?.run_id_high);
    var sibling_launch: ?turn.Launch = null;
    const sibling = try f.child("later", &sibling_launch);
    {
        var candidates = try f.db.queries.child_admission_candidates.rows(.{ .parent_id = f.parent.raw });
        defer candidates.deinit();
        try testing.expectEqual(grandchild.session.id.raw, (try candidates.next(a)).?.value.id);
        try testing.expectEqual(sibling.session.id.raw, (try candidates.next(a)).?.value.id);
        try testing.expect(try candidates.next(a) == null);
    }
    turn.Launch.release(&sibling_launch, &f.engine);
    turn.Launch.release(&grandchild_launch, &f.engine);
    try f.engine.setAgentLimits(1, 1);
    var refused: ?turn.Launch = null;
    params.child.?.name = "later";
    try testing.expectError(error.AgentDepthLimit, commands.sessionCreateForRpc(&f.engine, a, params, &refused, null));
    f.releaseParent(&child_launch);
    for (0..1000) |_| {
        const marks = (try database.event.highWater(&f.db, a, child.session.id.raw)).?;
        if (marks.run_id_high >= 2 and admission.capacity(&f.engine, f.parent).active == 0) break;
        try std.Io.sleep(f.resources.runtime.io(), .fromMilliseconds(1), .awake);
    }
    try testing.expectEqual(@as(u64, 0), admission.capacity(&f.engine, f.parent).active);
    try testing.expectEqual(@as(u64, 2), (try database.event.highWater(&f.db, a, child.session.id.raw)).?.run_id_high);
    const history = try database.message.historyPage(&f.db, a, child.session.id.raw, 0, 20);
    var found = false;
    for (history.messages) |message| if (message == .user) {
        if (message.user.source) |source| if (source == .child_report) {
            try testing.expectEqual(grandchild.session.id, source.child_report.session_id);
            try testing.expectEqualStrings("scan", source.child_report.name);
            found = true;
        };
    };
    try testing.expect(found);
}

test "atomic creation binds its receipt and rejects invalid child sites without a row" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    var launch: ?turn.Launch = null;
    const first = try f.child("research", &launch);
    try testing.expectEqual(@as(u64, 1), first.input.?.started.run_id);
    try testing.expectEqual(@as(u64, 1), first.input.?.started.capacity.?.active);
    const history = try database.message.historyPage(&f.db, a, first.session.id.raw, 0, 10);
    try testing.expectEqualStrings("task", history.messages[0].user.content[0].text.text);
    try testing.expectEqual(first.input.?.started.input_id, history.messages[0].user.input_id);
    try testing.expectEqual(f.parent, history.messages[0].user.source.?.parent_instruction.session_id);
    try testing.expectEqual(@as(u64, 2), history.messages[0].user.source.?.parent_instruction.message_id);
    var refused: ?turn.Launch = null;
    try testing.expectError(error.DuplicateChildName, f.child("research", &refused));
    for ([_][]const u8{ "root", "Research", "../escape", "two words", "", "9start", "a" ** 65 }) |name| try testing.expectError(error.BadChildName, f.child(name, &refused));
    var bad = f.params("invalid");
    bad.child.?.site.message_id = 999;
    try testing.expectError(error.BadToolSite, commands.sessionCreateForRpc(&f.engine, a, bad, &refused, null));
    bad = f.params("nested");
    bad.child.?.site.session_id = first.session.id;
    try testing.expectError(error.AgentDepthLimit, commands.sessionCreateForRpc(&f.engine, a, bad, &refused, null));
    bad = f.params("empty");
    bad.initial_input = null;
    try testing.expectError(error.BadChild, commands.sessionCreateForRpc(&f.engine, a, bad, &refused, null));
    try testing.expectEqual(@as(u64, 2), (try commands.sessionList(&f.engine, a, .{ .population = .{ .all = .{} } })).total);
    try testing.expect(refused == null);
}

test "child capacity excludes the parent and admits durable queues in FIFO order" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    try f.engine.setAgentLimits(1, 1);
    var one_launch: ?turn.Launch = null;
    const one = try f.child("one", &one_launch);
    var two_launch: ?turn.Launch = null;
    const two = try f.child("two", &two_launch);
    var three_launch: ?turn.Launch = null;
    const three = try f.child("three", &three_launch);
    try testing.expectEqual(proto.session.InputQueueReason.concurrency_limit, two.input.?.queued.reason);
    try testing.expectEqual(@as(u64, 1), three.input.?.queued.capacity.?.active);
    try testing.expectEqual(@as(u64, 1), try database.input.count(&f.db, a, two.session.id.raw));
    turn.Launch.release(&two_launch, &f.engine);
    turn.Launch.release(&three_launch, &f.engine);
    try testing.expectEqual(@as(u64, 0), (try database.event.highWater(&f.db, a, two.session.id.raw)).?.run_id_high);
    var followup: ?turn.Launch = null;
    const queued = try commands.sessionSendInputForRpc(&f.engine, a, .{ .session_id = one.session.id, .input = input() }, &followup, null);
    try testing.expectEqual(proto.session.InputQueueReason.session_busy, queued.queued.reason);
    turn.Launch.release(&followup, &f.engine);
    turn.Launch.release(&one_launch, &f.engine);
    for (0..1000) |_| {
        if (admission.capacity(&f.engine, f.parent).active == 0) break;
        try std.Io.sleep(f.resources.runtime.io(), .fromMilliseconds(1), .awake);
    }
    try testing.expectEqual(@as(u64, 0), admission.capacity(&f.engine, f.parent).active);
    try testing.expectEqual(@as(u64, 2), (try database.event.highWater(&f.db, a, one.session.id.raw)).?.run_id_high);
    const zqlite = @import("zqlite");
    const row = (try f.db.conn.row("SELECT (SELECT min(rowid) FROM events WHERE session_id = ?1 AND name = 'run.started') < (SELECT min(rowid) FROM events WHERE session_id = ?2 AND name = 'run.started')", .{ zqlite.blob(&two.session.id.raw), zqlite.blob(&three.session.id.raw) })).?;
    defer row.deinit();
    try testing.expectEqual(@as(i64, 1), row.int(0));
    var next: ?turn.Launch = null;
    const reused = try commands.sessionSendInputForRpc(&f.engine, a, .{ .session_id = two.session.id, .input = input() }, &next, null);
    try testing.expectEqual(@as(u64, 2), reused.started.run_id);
}

test "a parent site must name a running tool part in an uncanceled run" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    var refused: ?turn.Launch = null;
    var bad = f.params("outside");
    bad.child.?.site.part_id = 7;
    try testing.expectError(error.BadToolSite, commands.sessionCreateForRpc(&f.engine, a, bad, &refused, null));
    const active = f.engine.sessions.get(f.parent).?.active_run.?;
    active.cancel.requested = true;
    try testing.expectError(error.BadToolSite, f.child("stopping", &refused));
    active.cancel.requested = false;
    try testing.expect(refused == null);
    try testing.expectEqual(@as(u64, 1), (try commands.sessionList(&f.engine, a, .{ .population = .{ .all = .{} } })).total);
}

test "a free slot serves the oldest queued child before a new request" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    try f.engine.setAgentLimits(1, 1);
    var one_launch: ?turn.Launch = null;
    _ = try f.child("one", &one_launch);
    var two_launch: ?turn.Launch = null;
    const two = try f.child("two", &two_launch);
    turn.Launch.release(&two_launch, &f.engine);
    // Free a slot without the drain task, so the rule alone decides.
    f.engine.max_concurrent_children = 2;
    try testing.expect(try admission.available(&f.engine, a, f.parent, two.session.id));
    try testing.expect(!try admission.available(&f.engine, a, f.parent, .bytes([_]u8{9} ** 16)));
    turn.Launch.release(&one_launch, &f.engine);
}

test "admission skips a faulted child and serves its sibling" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    try f.engine.setAgentLimits(1, 1);
    var one_launch: ?turn.Launch = null;
    _ = try f.child("one", &one_launch);
    var two_launch: ?turn.Launch = null;
    const two = try f.child("two", &two_launch);
    var three_launch: ?turn.Launch = null;
    const three = try f.child("three", &three_launch);
    f.engine.sessions.get(two.session.id).?.faulted = true;
    turn.Launch.release(&two_launch, &f.engine);
    turn.Launch.release(&three_launch, &f.engine);
    turn.Launch.release(&one_launch, &f.engine);
    for (0..1000) |_| {
        if ((try database.event.highWater(&f.db, a, three.session.id.raw)).?.run_id_high > 0) break;
        try std.Io.sleep(f.resources.runtime.io(), .fromMilliseconds(1), .awake);
    }
    try testing.expectEqual(@as(u64, 1), (try database.event.highWater(&f.db, a, three.session.id.raw)).?.run_id_high);
    try testing.expectEqual(@as(u64, 0), (try database.event.highWater(&f.db, a, two.session.id.raw)).?.run_id_high);
}

test "a lower live limit preserves active runs and a higher limit drains queued children" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    try f.engine.setAgentLimits(2, 1);
    var first: ?turn.Launch = null;
    _ = try f.child("first", &first);
    var second: ?turn.Launch = null;
    _ = try f.child("second", &second);
    try f.engine.setAgentLimits(1, 1);
    var pending: ?turn.Launch = null;
    const third = try f.child("third", &pending);
    try testing.expectEqual(@as(u64, 2), third.input.?.queued.capacity.?.active);
    try testing.expectEqual(@as(u64, 1), third.input.?.queued.capacity.?.limit);
    try f.engine.setAgentLimits(3, 1);
    for (0..1000) |_| {
        if ((try database.event.highWater(&f.db, a, third.session.id.raw)).?.run_id_high == 1 and admission.capacity(&f.engine, f.parent).active == 2) break;
        try std.Io.sleep(f.resources.runtime.io(), .fromMilliseconds(1), .awake);
    }
    try testing.expectEqual(@as(u64, 1), (try database.event.highWater(&f.db, a, third.session.id.raw)).?.run_id_high);
    try testing.expectEqual(@as(u64, 2), admission.capacity(&f.engine, f.parent).active);
}

test "boot resumes queued children under the limit without a surviving parent draft" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    try f.engine.setAgentLimits(1, 1);
    var first_gate: ?turn.Launch = null;
    const first = try f.child("first", &first_gate);
    var second_gate: ?turn.Launch = null;
    const second = try f.child("second", &second_gate);
    var third_gate: ?turn.Launch = null;
    const third = try f.child("third", &third_gate);
    f.engine.close();
    f.engine = f.resources.makeEngine(&f.db);
    try f.engine.setAgentLimits(1, 1);
    try f.engine.resumeWorkspace("/work");
    try testing.expect(admission.capacity(&f.engine, f.parent).active <= 1);
    for (0..1000) |_| {
        if (admission.capacity(&f.engine, f.parent).active == 0) break;
        try std.Io.sleep(f.resources.runtime.io(), .fromMilliseconds(1), .awake);
    }
    for ([_]proto.ids.SessionId{ first.session.id, second.session.id, third.session.id }) |id| {
        try testing.expectEqual(@as(u64, 1), (try database.event.highWater(&f.db, a, id.raw)).?.run_id_high);
        try testing.expect((try database.session.snapshot(&f.db, a, id.raw)).?.open_run_id == null);
    }
}

test "a full child input queue rejects work without an input id or event" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    var gate: ?turn.Launch = null;
    const child = try f.child("busy", &gate);
    const params: proto.session.SessionSendInputParams = .{ .session_id = child.session.id, .input = input() };
    for (0..proto.meta.limits.max_queued_inputs) |_| {
        var wake: ?turn.Launch = null;
        const result = try commands.sessionSendInputForRpc(&f.engine, a, params, &wake, null);
        try testing.expectEqual(proto.session.InputQueueReason.session_busy, result.queued.reason);
    }
    const before = (try database.event.highWater(&f.db, a, child.session.id.raw)).?;
    var refused: ?turn.Launch = null;
    try testing.expectError(error.QueueFull, commands.sessionSendInputForRpc(&f.engine, a, params, &refused, null));
    const after = (try database.event.highWater(&f.db, a, child.session.id.raw)).?;
    try testing.expectEqual(before.seq_high, after.seq_high);
    try testing.expectEqual(before.input_id_high, after.input_id_high);
    try testing.expect(refused == null);
}

test "a terminal child retains capacity until native cleanup ends" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    try f.engine.setAgentLimits(1, 1);
    var first: ?turn.Launch = null;
    _ = try f.child("first", &first);
    const slot = first.?.slot;
    const Work = @import("../session/work.zig");
    const Cleanup = struct {
        operation: Work.Operation = .{ .cancel = cancel },
        canceled: bool = false,
        fn cancel(operation: *Work.Operation) void {
            const self: *@This() = @fieldParentPtr("operation", operation);
            self.canceled = true;
        }
    };
    var cleanup: Cleanup = .{};
    slot.work.retain(&cleanup.operation);
    var retained = true;
    defer if (retained) slot.work.release(f.resources.runtime.io(), &cleanup.operation);
    var next: ?turn.Launch = null;
    const second = try f.child("second", &next);
    turn.Launch.release(&next, &f.engine);
    turn.Launch.release(&first, &f.engine);
    for (0..1000) |_| {
        if (cleanup.canceled) break;
        try std.Io.sleep(f.resources.runtime.io(), .fromMilliseconds(1), .awake);
    }
    try testing.expect(cleanup.canceled);
    try testing.expectEqual(@as(u64, 1), admission.capacity(&f.engine, f.parent).active);
    try testing.expectEqual(@as(u64, 0), (try database.event.highWater(&f.db, a, second.session.id.raw)).?.run_id_high);
    slot.work.release(f.resources.runtime.io(), &cleanup.operation);
    retained = false;
    for (0..1000) |_| {
        if (admission.capacity(&f.engine, f.parent).active == 0) break;
        try std.Io.sleep(f.resources.runtime.io(), .fromMilliseconds(1), .awake);
    }
    try testing.expectEqual(@as(u64, 0), admission.capacity(&f.engine, f.parent).active);
    try testing.expectEqual(@as(u64, 1), (try database.event.highWater(&f.db, a, second.session.id.raw)).?.run_id_high);
}

test "a failed initial input transaction leaves no session or ownership claim" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    try f.db.conn.execNoArgs("CREATE TEMP TRIGGER refuse_input BEFORE INSERT ON pending_inputs BEGIN SELECT RAISE(FAIL, 'test refusal'); END");
    const owner_count = f.engine.owners.count();
    const session_count = try database.session.count(&f.db, a, .{});
    var gate: ?turn.Launch = null;
    try testing.expectError(error.ConstraintTrigger, commands.sessionCreateForRpc(&f.engine, a, .{ .workspace_path = "/work", .model = "test/model", .initial_input = input() }, &gate, null));
    try testing.expectEqual(owner_count, f.engine.owners.count());
    try testing.expectEqual(session_count, try database.session.count(&f.db, a, .{}));
    try testing.expectEqual(@as(u32, 1), f.engine.sessions.map.count());
    try testing.expect(gate == null);
}

test "child completion stays queued across an active parent interrupt" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    var launch: ?turn.Launch = null;
    const child = try f.child("reporter", &launch);
    f.resources.providers.deinit();
    f.resources.providers = .init(testing.allocator, f.resources.runtime.io(), &f.resources.env);
    turn.Launch.release(&launch, &f.engine);
    for (0..1000) |_| {
        if (admission.capacity(&f.engine, f.parent).active == 0) break;
        try std.Io.sleep(f.resources.runtime.io(), .fromMilliseconds(1), .awake);
    }
    const parent = f.engine.sessions.get(f.parent).?;
    try testing.expectEqual(@as(usize, 1), parent.queueDepth());
    try testing.expectEqual(@as(usize, 1), parent.transcript.list.items.len);
    const pending = parent.queueEntries()[0];
    try testing.expectEqual(child.session.id, pending.source.?.child_report.session_id);
    try testing.expectEqual(proto.enums.RunErrorCode.unknown_model, pending.source.?.child_report.outcome.failed.code);
    const canceled = try commands.sessionCancelRun(&f.engine, a, .{ .session_id = f.parent, .clear_queue = true });
    try testing.expectEqual(@as(usize, 0), canceled.cleared_inputs.len);
    try testing.expect(parent.active_run.?.cancel.requested);
    try testing.expectEqual(@as(usize, 1), parent.queueDepth());
    try testing.expectError(error.ProtectedInput, commands.sessionCancelInput(&f.engine, a, .{ .session_id = f.parent, .input_id = pending.input_id }));
}

test "a canceled active child emits one terminal report" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    var launch: ?turn.Launch = null;
    const child = try f.child("cancel", &launch);
    _ = try commands.sessionCancelRun(&f.engine, a, .{ .session_id = child.session.id });
    turn.Launch.release(&launch, &f.engine);
    for (0..1000) |_| {
        if (admission.capacity(&f.engine, f.parent).active == 0) break;
        try std.Io.sleep(f.resources.runtime.io(), .fromMilliseconds(1), .awake);
    }
    const queue = try database.input.list(&f.db, a, f.parent.raw);
    try testing.expectEqual(@as(usize, 1), queue.len);
    try testing.expect(queue[0].input.source.?.child_report.outcome == .canceled);
    try testing.expectEqual(@as(u64, 1), queue[0].input.source.?.child_report.run_id);
}

test "native child admission enforces the slot and preserves parent instruction sources" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    var gate: ?turn.Launch = null;
    var params = f.params("guarded");
    params.child.?.slot = .medium;
    try testing.expectError(error.AgentSetupRequired, commands.sessionCreateForRpc(&f.engine, a, params, &gate, null));
    params = f.params("guarded");
    params.model = "parent/large";
    try testing.expectError(error.AgentConfigConflict, commands.sessionCreateForRpc(&f.engine, a, params, &gate, null));
    params.model = null;
    params.reasoning = "high";
    try testing.expectError(error.ChildReasoningDerived, commands.sessionCreateForRpc(&f.engine, a, params, &gate, null));
    try testing.expectEqual(@as(u64, 1), (try commands.sessionList(&f.engine, a, .{ .population = .{ .all = .{} } })).total);
    params.reasoning = null;
    params.system_prompt = "custom child prompt";
    const child = try commands.sessionCreateForRpc(&f.engine, a, params, &gate, null);
    try testing.expectEqualStrings("test/model", child.session.model);
    const prompt = (try database.session.prompt(&f.db, a, child.session.id.raw)).?;
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "custom child prompt\n\n{s}\n\n{s}", .{ @import("prompt.zig").default_child_instructions, (try database.session.promptParts(&f.db, a, child.session.id.raw)).environment }), prompt);
    var next: ?turn.Launch = null;
    var followup: proto.session.SessionSendInputParams = .{ .session_id = child.session.id, .input = input(), .parent_tool = .{ .session_id = f.parent, .message_id = 999, .part_id = 0 } };
    try testing.expectError(error.BadToolSite, commands.sessionSendInputForRpc(&f.engine, a, followup, &next, null));
    followup.parent_tool.?.message_id = 2;
    _ = try commands.sessionSendInputForRpc(&f.engine, a, followup, &next, null);
    const queue = try commands.sessionQueue(&f.engine, a, .{ .session_id = child.session.id });
    try testing.expectEqual(f.parent, queue.items[0].source.?.parent_instruction.session_id);
    try testing.expectEqual(@as(u64, 2), queue.items[0].source.?.parent_instruction.message_id);
}

test "child prompts inherit the saved base and snapshot their own policy" {
    var f: Fixture = undefined;
    try f.initWithPrompt("parent base");
    defer f.deinit();
    const a = f.arena.allocator();
    try f.engine.setPromptConfig("new process default", f.engine.child_instructions);
    try f.engine.setPromptConfig(f.engine.default_system_prompt, "policy for ${agent_name} in ${workspace}");
    f.engine.max_agent_depth = 2;
    var launch: ?turn.Launch = null;
    const child = try f.child("worker", &launch);
    const saved = try commands.sessionConfig(&f.engine, a, .{ .session_id = child.session.id });
    const child_parts = try database.session.promptParts(&f.db, a, child.session.id.raw);
    try testing.expectEqualStrings("policy for worker in /work", child_parts.child_policy.?);
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "parent base\n\npolicy for worker in /work\n\n{s}", .{child_parts.environment}), saved.system_prompt.?);
    try testing.expectEqualStrings(saved.system_prompt.?, launch.?.slot.config.system_prompt);
    try testing.expectEqualStrings("parent base", try database.session.basePrompt(&f.db, a, child.session.id.raw));
    try f.engine.setPromptConfig(f.engine.default_system_prompt, "next policy ${agent_name}");
    const site = try f.toolSite(child.session.id);
    var grand_params = f.params("grandchild");
    grand_params.child.?.site = site;
    var grand_launch: ?turn.Launch = null;
    const grandchild = try commands.sessionCreateForRpc(&f.engine, a, grand_params, &grand_launch, null);
    const grand_parts = try database.session.promptParts(&f.db, a, grandchild.session.id.raw);
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "parent base\n\nnext policy grandchild\n\n{s}", .{grand_parts.environment}), (try database.session.prompt(&f.db, a, grandchild.session.id.raw)).?);
    try testing.expectEqualStrings(saved.system_prompt.?, (try database.session.prompt(&f.db, a, child.session.id.raw)).?);
    try f.engine.setPromptConfig(f.engine.default_system_prompt, "");
    var explicit = f.params("explicit");
    explicit.system_prompt = "${agent_name}";
    var explicit_launch: ?turn.Launch = null;
    const custom = try commands.sessionCreateForRpc(&f.engine, a, explicit, &explicit_launch, null);
    const custom_parts = try database.session.promptParts(&f.db, a, custom.session.id.raw);
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "explicit\n\n{s}", .{custom_parts.environment}), (try database.session.prompt(&f.db, a, custom.session.id.raw)).?);
}

test "root templates resolve once and invalid templates create no session" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    try f.engine.setPromptConfig("${agent_name} ${workspace} ${session_id}", f.engine.child_instructions);
    const root = try commands.sessionCreate(&f.engine, a, .{ .workspace_path = "/work", .model = "test/model" });
    const hex = std.fmt.bytesToHex(root.session.id.raw, .lower);
    const parts = try database.session.promptParts(&f.db, a, root.session.id.raw);
    const expected = try std.fmt.allocPrint(a, "root /work {s}\n\n{s}", .{ hex, parts.environment });
    try testing.expectEqualStrings(expected, (try database.session.prompt(&f.db, a, root.session.id.raw)).?);
    try f.engine.setPromptConfig("changed", f.engine.child_instructions);
    var launch: ?turn.Launch = null;
    _ = try commands.sessionSendInputForRpc(&f.engine, a, .{ .session_id = root.session.id, .input = input() }, &launch, null);
    try testing.expectEqualStrings(expected, launch.?.slot.config.system_prompt);
    try testing.expectError(error.InvalidPromptPlaceholder, commands.sessionCreate(&f.engine, a, .{ .workspace_path = "/work", .model = "test/model", .system_prompt = "${missing}" }));
    try testing.expectEqual(@as(u64, 2), (try commands.sessionList(&f.engine, a, .{ .population = .{ .all = .{} } })).total);
}

test "default and empty bases retain the environment and reject oversized composition atomically" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    const prompts = @import("prompt.zig");
    const original = try database.session.promptParts(&f.db, a, f.parent.raw);
    try testing.expectEqualStrings(prompts.default_system_prompt, original.base);
    try testing.expect(original.child_policy == null);
    try testing.expectEqualStrings(try original.render(a), (try database.session.prompt(&f.db, a, f.parent.raw)).?);

    try f.engine.setPromptConfig("configured", null);
    const configured = try commands.sessionCreate(&f.engine, a, .{ .workspace_path = "/work", .model = "test/model" });
    try testing.expectEqualStrings("configured", (try database.session.promptParts(&f.db, a, configured.session.id.raw)).base);
    const explicit = try commands.sessionCreate(&f.engine, a, .{ .workspace_path = "/work", .model = "test/model", .system_prompt = "" });
    const empty = try database.session.promptParts(&f.db, a, explicit.session.id.raw);
    try testing.expectEqualStrings("", empty.base);
    try testing.expectEqualStrings(empty.environment, (try database.session.prompt(&f.db, a, explicit.session.id.raw)).?);

    try f.engine.setPromptConfig("", null);
    const disabled = try commands.sessionCreate(&f.engine, a, .{ .workspace_path = "/work", .model = "test/model" });
    try testing.expectEqualStrings("", (try database.session.promptParts(&f.db, a, disabled.session.id.raw)).base);
    try f.engine.setPromptConfig(null, null);
    const restored = try commands.sessionCreate(&f.engine, a, .{ .workspace_path = "/work", .model = "test/model" });
    try testing.expectEqualStrings(prompts.default_system_prompt, (try database.session.promptParts(&f.db, a, restored.session.id.raw)).base);
    try testing.expectEqualStrings(original.environment, (try database.session.promptParts(&f.db, a, f.parent.raw)).environment);

    const count = (try commands.sessionList(&f.engine, a, .{})).total;
    const oversized = try a.alloc(u8, proto.meta.limits.max_message_string_bytes);
    @memset(oversized, 'x');
    try testing.expectError(error.PromptTooLarge, commands.sessionCreate(&f.engine, a, .{ .workspace_path = "/work", .model = "test/model", .system_prompt = oversized }));
    try testing.expectEqual(count, (try commands.sessionList(&f.engine, a, .{})).total);
}

test "instruction snapshots survive file edits and child creation" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const workspace = path_buf[0..try tmp.dir.realPath(testing.io, &path_buf)];
    const original = "Use the project rules literally: ${unknown}.\n";
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "AGENTS.md", .data = original });
    var root_launch: ?turn.Launch = null;
    const root = try commands.sessionCreateForRpc(&f.engine, a, .{ .workspace_path = workspace, .model = "test/model", .initial_input = input(), .system_prompt = "custom" }, &root_launch, null);
    const root_parts = try database.session.promptParts(&f.db, a, root.session.id.raw);
    try testing.expectEqualStrings("custom", root_parts.base);
    try testing.expect(std.mem.indexOf(u8, root_parts.instructions, original) != null);
    const metadata = (try commands.sessionGet(&f.engine, a, .{ .session_id = root.session.id })).instruction_sources.?;
    try testing.expectEqual(@as(usize, 1), metadata.len);
    try testing.expectEqual(.workspace, metadata[0].scope);
    try testing.expectEqualStrings(try std.fs.path.join(a, &.{ workspace, "AGENTS.md" }), metadata[0].path);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "AGENTS.md", .data = "\xff" });
    f.engine.max_agent_depth = 2;
    var params = f.params("worker");
    params.workspace_path = workspace;
    params.child.?.site = try f.toolSite(root.session.id);
    params.system_prompt = "";
    var child_launch: ?turn.Launch = null;
    const child = try commands.sessionCreateForRpc(&f.engine, a, params, &child_launch, null);
    const child_parts = try database.session.promptParts(&f.db, a, child.session.id.raw);
    try testing.expectEqualStrings("", child_parts.base);
    try testing.expectEqualStrings(root_parts.instructions, child_parts.instructions);
    const sources = try database.session.instructionSnapshots(&f.db, a, child.session.id.raw);
    try testing.expectEqualStrings(original, sources[0].text);
    params.child.?.site = try f.toolSite(child.session.id);
    params.child.?.name = "grandchild";
    var grand_launch: ?turn.Launch = null;
    const grandchild = try commands.sessionCreateForRpc(&f.engine, a, params, &grand_launch, null);
    const grand_parts = try database.session.promptParts(&f.db, a, grandchild.session.id.raw);
    try testing.expectEqualStrings(root_parts.instructions, grand_parts.instructions);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, grand_launch.?.slot.config.system_prompt, original));
    const count = (try commands.sessionList(&f.engine, a, .{})).total;
    var refused: ?turn.Launch = null;
    var diagnostic: ?[]const u8 = null;
    try testing.expectError(error.InvalidInstructions, commands.sessionCreateForRpc(&f.engine, a, .{ .workspace_path = workspace, .model = "test/model" }, &refused, &diagnostic));
    try testing.expect(std.mem.indexOf(u8, diagnostic.?, metadata[0].path) != null);
    try testing.expectEqual(count, (try commands.sessionList(&f.engine, a, .{})).total);
    try testing.expect(refused == null);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "AGENTS.md", .data = "new rules" });
    const fresh = try commands.sessionCreate(&f.engine, a, .{ .workspace_path = workspace, .model = "test/model" });
    const fresh_sources = try database.session.instructionSnapshots(&f.db, a, fresh.session.id.raw);
    try testing.expectEqualStrings("new rules", fresh_sources[0].text);
    try testing.expectEqualStrings(root_parts.instructions, (try database.session.promptParts(&f.db, a, root.session.id.raw)).instructions);
}

const NoticeLog = struct {
    count: usize = 0,
    text: [512]u8 = undefined,
    len: usize = 0,

    fn onEvent(ctx: *anyopaque, note: proto.rpc.Notification) void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (note.method != .notice) return;
        self.count += 1;
        const message_text = note.params.notice.message;
        self.len = @min(message_text.len, self.text.len);
        @memcpy(self.text[0..self.len], message_text[0..self.len]);
    }

    fn last(self: *const @This()) []const u8 {
        return self.text[0..self.len];
    }
};

fn skillFile(tmp: testing.TmpDir, name: []const u8, text: []const u8) !void {
    var buffer: [128]u8 = undefined;
    const sub = try std.fmt.bufPrint(&buffer, ".agents/skills/{s}", .{name});
    try tmp.dir.createDirPath(testing.io, sub);
    var file_buffer: [128]u8 = undefined;
    try tmp.dir.writeFile(testing.io, .{ .sub_path = try std.fmt.bufPrint(&file_buffer, "{s}/SKILL.md", .{sub}), .data = text });
}

test "skill catalogs snapshot at creation, children inherit them, and bodies load from disk" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const workspace = path_buf[0..try tmp.dir.realPath(testing.io, &path_buf)];
    try skillFile(tmp, "pdf", "---\ndescription: Handle PDFs & forms\n---\nDo the pdf thing.\n");
    try skillFile(tmp, "bad", "---\nname: bad\n---\n");
    var notices: NoticeLog = .{};
    f.engine.sinks.add(.{ .ctx = @ptrCast(&notices), .on_event = NoticeLog.onEvent });
    defer f.engine.sinks.remove(@ptrCast(&notices));

    var root_launch: ?turn.Launch = null;
    const root = try commands.sessionCreateForRpc(&f.engine, a, .{ .workspace_path = workspace, .model = "test/model", .initial_input = input() }, &root_launch, null);
    const parts = try database.session.promptParts(&f.db, a, root.session.id.raw);
    try testing.expect(std.mem.indexOf(u8, parts.skills, "<name>pdf</name>") != null);
    try testing.expect(std.mem.indexOf(u8, parts.skills, "Handle PDFs &amp; forms") != null);
    try testing.expect(std.mem.indexOf(u8, (try database.session.prompt(&f.db, a, root.session.id.raw)).?, parts.skills) != null);
    try testing.expectEqual(@as(usize, 1), notices.count);
    try testing.expect(std.mem.indexOf(u8, notices.last(), "bad/SKILL.md") != null);
    try testing.expect(std.mem.indexOf(u8, notices.last(), "description is missing") != null);
    const selection = try @import("request.zig").selectionFor(&f.engine, a, root_launch.?.slot);
    try testing.expect(selection.has_skills);
    try testing.expect(!(try @import("request.zig").selectionFor(&f.engine, a, f.engine.sessions.get(f.parent).?.active_run.?)).has_skills);

    const item = try commands.sessionGet(&f.engine, a, .{ .session_id = root.session.id });
    try testing.expectEqual(@as(usize, 1), item.skills.?.len);
    try testing.expectEqualStrings("pdf", item.skills.?[0].name);
    try testing.expectEqual(.workspace, item.skills.?[0].scope);
    try testing.expect(item.context_changes == null);

    var unused: ?turn.Launch = null;
    var diagnostic: ?[]const u8 = null;
    const loaded = try commands.skillLoad(&f.engine, a, .{ .session_id = root.session.id, .name = "pdf" }, &unused, &diagnostic);
    try testing.expectEqualStrings("Do the pdf thing.", loaded.body);
    try testing.expect(std.mem.startsWith(u8, loaded.content, "<skill_content name=\"pdf\">\nDo the pdf thing.\n\nSkill directory: "));
    try testing.expect(std.mem.endsWith(u8, loaded.directory, ".agents/skills/pdf"));
    try testing.expectError(error.UnknownSkill, commands.skillLoad(&f.engine, a, .{ .session_id = root.session.id, .name = "missing" }, &unused, &diagnostic));
    try testing.expectError(error.UnknownSkill, commands.skillLoad(&f.engine, a, .{ .session_id = root.session.id, .name = "Bad Name" }, &unused, &diagnostic));
    try testing.expectError(error.UnknownSession, commands.skillLoad(&f.engine, a, .{ .session_id = .bytes(.{7} ** 16), .name = "pdf" }, &unused, &diagnostic));

    // The child copies the catalog and never rescans, so a deleted skill stays listed and fails only at load.
    try tmp.dir.deleteTree(testing.io, ".agents/skills/pdf");
    f.engine.max_agent_depth = 2;
    var params = f.params("worker");
    params.workspace_path = workspace;
    params.child.?.site = try f.toolSite(root.session.id);
    var child_launch: ?turn.Launch = null;
    const child = try commands.sessionCreateForRpc(&f.engine, a, params, &child_launch, null);
    const inherited = try database.session.skillCatalog(&f.db, a, child.session.id.raw);
    try testing.expectEqual(@as(usize, 1), inherited.len);
    try testing.expectEqualStrings("pdf", inherited[0].name);
    try testing.expectEqualStrings(parts.skills, (try database.session.promptParts(&f.db, a, child.session.id.raw)).skills);
    try testing.expectError(error.SkillUnreadable, commands.skillLoad(&f.engine, a, .{ .session_id = child.session.id, .name = "pdf" }, &unused, &diagnostic));
    try testing.expect(std.mem.indexOf(u8, diagnostic.?, "pdf/SKILL.md") != null);
    const checked = try commands.sessionGet(&f.engine, a, .{ .session_id = root.session.id, .check_files = true });
    try testing.expect(checked.context_changes.?.skills);
    try testing.expect(!checked.context_changes.?.instructions);
    try testing.expectError(error.SessionBusy, commands.sessionReloadContext(&f.engine, a, .{ .session_id = root.session.id }, &unused, &diagnostic));

    // An explicit invocation reads the body now, so an edit after creation reaches the message.
    try skillFile(tmp, "pdf", "---\ndescription: Handle PDFs\n---\nNew body.\n");
    const queue_before = (try commands.sessionQueue(&f.engine, a, .{ .session_id = root.session.id })).items.len;
    try testing.expectError(error.UnknownSkill, commands.sessionSendInputForRpc(&f.engine, a, .{ .session_id = root.session.id, .input = .{ .skill = .{ .name = "nope" } } }, &unused, &diagnostic));
    try testing.expectEqual(queue_before, (try commands.sessionQueue(&f.engine, a, .{ .session_id = root.session.id })).items.len);
    const queued = try commands.sessionSendInputForRpc(&f.engine, a, .{ .session_id = root.session.id, .input = .{ .skill = .{ .name = "pdf", .arguments = " on report.pdf \n" } } }, &unused, &diagnostic);
    try testing.expect(queued == .queued);
    const queue = try commands.sessionQueue(&f.engine, a, .{ .session_id = root.session.id });
    const text = queue.items[queue.items.len - 1].content[0].text.text;
    try testing.expectEqualStrings("pdf", queue.items[queue.items.len - 1].skill_name.?);
    try testing.expect(std.mem.startsWith(u8, text, "<skill_content name=\"pdf\">\nNew body.\n\nSkill directory: "));
    try testing.expect(std.mem.endsWith(u8, text, "\n</skill_content>\n\non report.pdf"));
}

test "reload replaces both snapshots of an idle session and the stale check tracks the files" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const workspace = path_buf[0..try tmp.dir.realPath(testing.io, &path_buf)];
    try skillFile(tmp, "pdf", "---\ndescription: Handle PDFs\n---\nBody.\n");
    const root = try commands.sessionCreate(&f.engine, a, .{ .workspace_path = workspace, .model = "test/model" });
    const fresh = try commands.sessionGet(&f.engine, a, .{ .session_id = root.session.id, .check_files = true });
    try testing.expect(!fresh.context_changes.?.skills and !fresh.context_changes.?.instructions);

    try skillFile(tmp, "pdf", "---\ndescription: Handle PDFs v2\n---\nBody.\n");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "AGENTS.md", .data = "project rules" });
    const stale = try commands.sessionGet(&f.engine, a, .{ .session_id = root.session.id, .check_files = true });
    try testing.expect(stale.context_changes.?.skills and stale.context_changes.?.instructions);
    try testing.expectEqualStrings("Handle PDFs", stale.skills.?[0].description);

    var unused: ?turn.Launch = null;
    var diagnostic: ?[]const u8 = null;
    const reloaded = try commands.sessionReloadContext(&f.engine, a, .{ .session_id = root.session.id }, &unused, &diagnostic);
    try testing.expectEqual(@as(usize, 1), reloaded.instruction_sources.len);
    try testing.expectEqualStrings("Handle PDFs v2", reloaded.skills[0].description);
    const parts = try database.session.promptParts(&f.db, a, root.session.id.raw);
    try testing.expect(std.mem.indexOf(u8, parts.skills, "Handle PDFs v2") != null);
    try testing.expect(std.mem.indexOf(u8, parts.instructions, "project rules") != null);
    const prompt = (try database.session.prompt(&f.db, a, root.session.id.raw)).?;
    try testing.expect(std.mem.indexOf(u8, prompt, parts.skills) != null);
    try testing.expect(std.mem.indexOf(u8, prompt, parts.instructions).? < std.mem.indexOf(u8, prompt, parts.skills).?);
    const settled = try commands.sessionGet(&f.engine, a, .{ .session_id = root.session.id, .check_files = true });
    try testing.expect(!settled.context_changes.?.skills and !settled.context_changes.?.instructions);
    try testing.expectEqual(@as(usize, 1), settled.instruction_sources.?.len);

    // A root left without skills renders no component and hides the tool on the next run.
    try tmp.dir.deleteTree(testing.io, ".agents");
    const emptied = try commands.sessionReloadContext(&f.engine, a, .{ .session_id = root.session.id }, &unused, &diagnostic);
    try testing.expectEqual(@as(usize, 0), emptied.skills.len);
    try testing.expectEqualStrings("", (try database.session.promptParts(&f.db, a, root.session.id.raw)).skills);
    try testing.expect(!try database.session.hasSkills(&f.db, a, root.session.id.raw));
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "AGENTS.md", .data = "\xff" });
    try testing.expectError(error.InvalidInstructions, commands.sessionReloadContext(&f.engine, a, .{ .session_id = root.session.id }, &unused, &diagnostic));
    try testing.expect(std.mem.indexOf(u8, diagnostic.?, "AGENTS.md") != null);
    try testing.expect(std.mem.indexOf(u8, (try database.session.promptParts(&f.db, a, root.session.id.raw)).instructions, "project rules") != null);
}
