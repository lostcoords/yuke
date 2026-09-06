//! Admission tests hold response gates to make capacity and queue order deterministic.

const std = @import("std");
const zio = @import("zio");
const ai = @import("ai");
const proto = @import("proto");
const database = @import("../store/store.zig");
const Store = @import("../provider/provider_store.zig");
const Engine = @import("Engine.zig");
const commands = @import("commands.zig");
const admission = @import("admission.zig");
const config = @import("agent_config.zig");
const turn = @import("turn.zig");
const Draft = @import("../session/draft.zig").Draft;
const testing = std.testing;

const Fixture = struct {
    tmp: testing.TmpDir,
    runtime: *zio.Runtime,
    db: database.Database,
    env: std.process.Environ.Map,
    store: Store,
    transport: ai.transport.CannedTransport,
    arena: std.heap.ArenaAllocator,
    engine: Engine,
    parent: proto.ids.SessionId,

    fn init(self: *Fixture) !void {
        self.tmp = testing.tmpDir(.{});
        self.runtime = try zio.Runtime.init(testing.allocator, .{ .executors = .exact(1) });
        self.db = try database.Database.openTest();
        self.env = .init(testing.allocator);
        var path: [std.fs.max_path_bytes]u8 = undefined;
        try self.env.put("XDG_CONFIG_HOME", path[0..try self.tmp.dir.realPath(testing.io, &path)]);
        try self.env.put("YUKE_APPNAME", "agents-test");
        self.store = .init(testing.allocator, self.runtime.io(), &self.env);
        var local = try @import("../provider/provider.zig").config.loadBytes(testing.allocator,
            \\{"version":1,"providers":[{"id":"test","base_url":"http://localhost:1/v1","protocol":"openai_chat","models":[{"id":"model","upstream_id":"model","flags":{"supports_tools":true}}]}]}
        );
        _ = try self.store.installLocal(&local);
        self.transport = .{ .bytes = ai.transport.canned_reply };
        self.arena = .init(testing.allocator);
        self.engine = Engine.init(.{ .gpa = testing.allocator, .io = self.runtime.io(), .db = &self.db, .providers = &self.store, .route_transport = self.transport.transport(), .env = &self.env });
        const empty = try config.get(&self.engine, self.arena.allocator());
        _ = try config.update(&self.engine, self.arena.allocator(), .{ .revision = empty.revision, .config = .{ .models = .{ .small = .{ .model = "test/model" } } } });
        const root = try commands.sessionCreate(&self.engine, self.arena.allocator(), .{ .workspace_path = "/work", .model = "test/model" });
        self.parent = root.session.id;
        var launch: ?turn.Launch = null;
        _ = try commands.sessionSendInputForRpc(&self.engine, self.arena.allocator(), .{ .session_id = self.parent, .input = input() }, &launch);
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
        self.store.deinit();
        self.env.deinit();
        self.runtime.deinit();
        self.tmp.cleanup();
    }

    fn params(self: *Fixture, name: []const u8) proto.misc.CreateSession {
        return .{ .workspace_path = "/work", .model = "test/model", .initial_input = input(), .child = .{ .slot = .small, .site = .{ .session_id = self.parent, .message_id = 2, .part_id = 0 }, .name = name } };
    }

    fn child(self: *Fixture, name: []const u8, launch: *?turn.Launch) !proto.session.SessionResult {
        return commands.sessionCreateForRpc(&self.engine, self.arena.allocator(), self.params(name), launch);
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
    try testing.expectError(error.AgentDepthLimit, commands.sessionCreateForRpc(&f.engine, a, params, &grandchild_launch));
    try f.engine.setAgentLimits(8, 2);
    const grandchild = try commands.sessionCreateForRpc(&f.engine, a, params, &grandchild_launch);
    try testing.expectEqual(@as(u32, 2), grandchild_launch.?.slot.depth);
    try testing.expectEqual(f.parent, grandchild_launch.?.slot.tree_root.?);
    params.child.?.site = .{ .session_id = grandchild.session.id, .message_id = 2, .part_id = 0 };
    var refused: ?turn.Launch = null;
    try testing.expectError(error.AgentDepthLimit, commands.sessionCreateForRpc(&f.engine, a, params, &refused));
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
    const grandchild = try commands.sessionCreateForRpc(&f.engine, a, params, &grandchild_launch);
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
    try testing.expectError(error.AgentDepthLimit, commands.sessionCreateForRpc(&f.engine, a, params, &refused));
    f.releaseParent(&child_launch);
    for (0..1000) |_| {
        const marks = (try database.event.highWater(&f.db, a, child.session.id.raw)).?;
        if (marks.run_id_high >= 2 and admission.capacity(&f.engine, f.parent).active == 0) break;
        try std.Io.sleep(f.runtime.io(), .fromMilliseconds(1), .awake);
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
    try testing.expectError(error.BadToolSite, commands.sessionCreateForRpc(&f.engine, a, bad, &refused));
    bad = f.params("nested");
    bad.child.?.site.session_id = first.session.id;
    try testing.expectError(error.AgentDepthLimit, commands.sessionCreateForRpc(&f.engine, a, bad, &refused));
    bad = f.params("empty");
    bad.initial_input = null;
    try testing.expectError(error.BadChild, commands.sessionCreateForRpc(&f.engine, a, bad, &refused));
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
    const queued = try commands.sessionSendInputForRpc(&f.engine, a, .{ .session_id = one.session.id, .input = input() }, &followup);
    try testing.expectEqual(proto.session.InputQueueReason.session_busy, queued.queued.reason);
    turn.Launch.release(&followup, &f.engine);
    turn.Launch.release(&one_launch, &f.engine);
    for (0..1000) |_| {
        if (admission.capacity(&f.engine, f.parent).active == 0) break;
        try std.Io.sleep(f.runtime.io(), .fromMilliseconds(1), .awake);
    }
    try testing.expectEqual(@as(u64, 0), admission.capacity(&f.engine, f.parent).active);
    try testing.expectEqual(@as(u64, 2), (try database.event.highWater(&f.db, a, one.session.id.raw)).?.run_id_high);
    const zqlite = @import("zqlite");
    const row = (try f.db.conn.row("SELECT (SELECT min(rowid) FROM events WHERE session_id = ?1 AND name = 'run.started') < (SELECT min(rowid) FROM events WHERE session_id = ?2 AND name = 'run.started')", .{ zqlite.blob(&two.session.id.raw), zqlite.blob(&three.session.id.raw) })).?;
    defer row.deinit();
    try testing.expectEqual(@as(i64, 1), row.int(0));
    var next: ?turn.Launch = null;
    const reused = try commands.sessionSendInputForRpc(&f.engine, a, .{ .session_id = two.session.id, .input = input() }, &next);
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
    try testing.expectError(error.BadToolSite, commands.sessionCreateForRpc(&f.engine, a, bad, &refused));
    const active = f.engine.sessions.get(f.parent).?.active_run.?;
    active.cancel_requested = true;
    try testing.expectError(error.BadToolSite, f.child("stopping", &refused));
    active.cancel_requested = false;
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
        try std.Io.sleep(f.runtime.io(), .fromMilliseconds(1), .awake);
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
        try std.Io.sleep(f.runtime.io(), .fromMilliseconds(1), .awake);
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
    f.engine = Engine.init(.{ .gpa = testing.allocator, .io = f.runtime.io(), .db = &f.db, .providers = &f.store, .route_transport = f.transport.transport(), .env = &f.env });
    try f.engine.setAgentLimits(1, 1);
    try f.engine.resumeWorkspace("/work");
    try testing.expect(admission.capacity(&f.engine, f.parent).active <= 1);
    for (0..1000) |_| {
        if (admission.capacity(&f.engine, f.parent).active == 0) break;
        try std.Io.sleep(f.runtime.io(), .fromMilliseconds(1), .awake);
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
        const result = try commands.sessionSendInputForRpc(&f.engine, a, params, &wake);
        try testing.expectEqual(proto.session.InputQueueReason.session_busy, result.queued.reason);
    }
    const before = (try database.event.highWater(&f.db, a, child.session.id.raw)).?;
    var refused: ?turn.Launch = null;
    try testing.expectError(error.QueueFull, commands.sessionSendInputForRpc(&f.engine, a, params, &refused));
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
    defer if (retained) slot.work.release(f.runtime.io(), &cleanup.operation);
    var next: ?turn.Launch = null;
    const second = try f.child("second", &next);
    turn.Launch.release(&next, &f.engine);
    turn.Launch.release(&first, &f.engine);
    for (0..1000) |_| {
        if (cleanup.canceled) break;
        try std.Io.sleep(f.runtime.io(), .fromMilliseconds(1), .awake);
    }
    try testing.expect(cleanup.canceled);
    try testing.expectEqual(@as(u64, 1), admission.capacity(&f.engine, f.parent).active);
    try testing.expectEqual(@as(u64, 0), (try database.event.highWater(&f.db, a, second.session.id.raw)).?.run_id_high);
    slot.work.release(f.runtime.io(), &cleanup.operation);
    retained = false;
    for (0..1000) |_| {
        if (admission.capacity(&f.engine, f.parent).active == 0) break;
        try std.Io.sleep(f.runtime.io(), .fromMilliseconds(1), .awake);
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
    try testing.expectError(error.ConstraintTrigger, commands.sessionCreateForRpc(&f.engine, a, .{ .workspace_path = "/work", .model = "test/model", .initial_input = input() }, &gate));
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
    f.store.deinit();
    f.store = .init(testing.allocator, f.runtime.io(), &f.env);
    turn.Launch.release(&launch, &f.engine);
    for (0..1000) |_| {
        if (admission.capacity(&f.engine, f.parent).active == 0) break;
        try std.Io.sleep(f.runtime.io(), .fromMilliseconds(1), .awake);
    }
    const parent = f.engine.sessions.get(f.parent).?;
    try testing.expectEqual(@as(usize, 1), parent.queueDepth());
    try testing.expectEqual(@as(usize, 1), parent.transcript.list.items.len);
    const pending = parent.queueEntries()[0];
    try testing.expectEqual(child.session.id, pending.source.?.child_report.session_id);
    try testing.expectEqual(proto.enums.RunErrorCode.unknown_model, pending.source.?.child_report.outcome.failed.code);
    const canceled = try commands.sessionCancelRun(&f.engine, a, .{ .session_id = f.parent, .clear_queue = true });
    try testing.expectEqual(@as(usize, 0), canceled.cleared_inputs.len);
    try testing.expect(parent.active_run.?.cancel_requested);
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
        try std.Io.sleep(f.runtime.io(), .fromMilliseconds(1), .awake);
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
    try testing.expectError(error.AgentSetupRequired, commands.sessionCreateForRpc(&f.engine, a, params, &gate));
    params = f.params("guarded");
    params.model = "parent/large";
    try testing.expectError(error.AgentConfigConflict, commands.sessionCreateForRpc(&f.engine, a, params, &gate));
    params.model = null;
    params.reasoning = "high";
    try testing.expectError(error.AgentConfigConflict, commands.sessionCreateForRpc(&f.engine, a, params, &gate));
    try testing.expectEqual(@as(u64, 1), (try commands.sessionList(&f.engine, a, .{ .population = .{ .all = .{} } })).total);
    params.reasoning = null;
    params.system_prompt = "custom child prompt";
    const child = try commands.sessionCreateForRpc(&f.engine, a, params, &gate);
    try testing.expectEqualStrings("test/model", child.session.model);
    const prompt = (try database.session.prompt(&f.db, a, child.session.id.raw)).?;
    try testing.expectEqualStrings("custom child prompt", prompt);
    var next: ?turn.Launch = null;
    var followup: proto.session.SessionSendInputParams = .{ .session_id = child.session.id, .input = input(), .parent_tool = .{ .session_id = f.parent, .message_id = 999, .part_id = 0 } };
    try testing.expectError(error.BadToolSite, commands.sessionSendInputForRpc(&f.engine, a, followup, &next));
    followup.parent_tool.?.message_id = 2;
    _ = try commands.sessionSendInputForRpc(&f.engine, a, followup, &next);
    const queue = try commands.sessionQueue(&f.engine, a, .{ .session_id = child.session.id });
    try testing.expectEqual(f.parent, queue.items[0].source.?.parent_instruction.session_id);
    try testing.expectEqual(@as(u64, 2), queue.items[0].source.?.parent_instruction.message_id);
}
