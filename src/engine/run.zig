//! Own run admission, launch gates, terminal state, and cleanup.

const std = @import("std");
const proto = @import("proto");
const database = @import("../store/store.zig");
const util = @import("../util.zig");
const session = @import("../session/session.zig");
const Engine = @import("Engine.zig");
const Session = session.Session;
const ids = proto.ids;
const reports = @import("reports.zig");
const session_events = @import("events.zig");
const admission = @import("admission.zig");
const Input = @import("../session/input.zig");
const sql = @import("sql");
const turn = @import("turn.zig");
const compaction = @import("compaction.zig");

const Database = database.Database;
const session_store = database.session;
const message_store = database.message;
const event_store = database.event;
const input_store = database.input;
const run_store = database.run;

pub const RunHandle = session.RunHandle;
pub const RunSlot = session.RunSlot;

/// Publish these arena-owned user commits before run.started and before arena release.
pub const Started = struct {
    handle: RunHandle,
    user_commits: []const message_store.Commit,
};

/// Append the `run.started` event for a turn. Both turn paths share this record shape.
fn appendRunStarted(db: *Database, arena: std.mem.Allocator, io: std.Io, session_id: [16]u8, run_id: proto.ids.RunId, config_rev: proto.ids.ConfigRev, started_at_ms: u64) !proto.run.RunStartedData {
    return run_store.appendStarted(db, arena, util.newId(io), started_at_ms, .{
        .session_id = .bytes(session_id),
        .seq = 0,
        .run_id = run_id,
        .kind = .turn,
        .config_rev = config_rev,
        .started_at_ms = started_at_ms,
    });
}

/// Commit the validated input and the run start in one transaction.
pub fn beginTurn(db: *Database, io: std.Io, arena: std.mem.Allocator, session_id: [16]u8, input: Input, config_rev: proto.ids.ConfigRev) !Started {
    var tx = try db.begin();
    defer tx.deinit();
    const input_id = try event_store.allocInputId(db, arena, session_id);
    const run_id = try event_store.allocRunId(db, arena, session_id);
    const now = util.nowMillis(io);
    const commits = try arena.alloc(message_store.Commit, 1);
    commits[0] = try commitInput(db, io, arena, session_id, input, input_id, now, now);
    const started = try appendRunStarted(db, arena, io, session_id, run_id, config_rev, now);
    try tx.commit();
    return .{
        .handle = .{ .input_id = input_id, .started = started },
        .user_commits = commits,
    };
}

/// Commit all pending inputs and start one run.
pub fn beginQueuedTurn(
    db: *Database,
    io: std.Io,
    arena: std.mem.Allocator,
    session_id: [16]u8,
    config_rev: proto.ids.ConfigRev,
) !Started {
    var tx = try db.begin();
    defer tx.deinit();
    const result = try beginQueuedTurnInTransaction(db, io, arena, session_id, config_rev);
    try tx.commit();
    return result;
}

/// Create admission can share this transaction without a nested commit.
pub fn beginQueuedTurnInTransaction(db: *Database, io: std.Io, arena: std.mem.Allocator, session_id: [16]u8, config_rev: proto.ids.ConfigRev) !Started {
    std.debug.assert(sql.inTransaction(db.conn));
    const commits = try consumeQueued(db, io, arena, session_id);
    if (commits.len == 0) return error.NoRow;
    const run_id = try event_store.allocRunId(db, arena, session_id);
    const started = try appendRunStarted(db, arena, io, session_id, run_id, config_rev, util.nowMillis(io));
    return .{
        .handle = .{ .input_id = commits[0].data.message.user.input_id, .started = started },
        .user_commits = commits,
    };
}

/// Append pending inputs in FIFO order and remove them in the caller's transaction.
pub fn consumeQueued(db: *Database, io: std.Io, arena: std.mem.Allocator, session_id: [16]u8) ![]const message_store.Commit {
    return consumeEntries(db, io, arena, session_id, try input_store.list(db, arena, session_id));
}

/// Commit the listed inputs as user messages inside the caller's transaction.
pub fn consumeEntries(db: *Database, io: std.Io, arena: std.mem.Allocator, session_id: [16]u8, queued: []const input_store.Entry) ![]const message_store.Commit {
    std.debug.assert(sql.inTransaction(db.conn));
    const commits = try arena.alloc(message_store.Commit, queued.len);
    const now = util.nowMillis(io);

    for (queued, commits) |entry, *commit| {
        const input: Input = .{ .content = entry.input.content, .source = entry.input.source, .skill_name = entry.input.skill_name };
        commit.* = try commitInput(db, io, arena, session_id, input, entry.input.input_id, entry.input.queued_at_ms, now);
        try input_store.consume(db, arena, session_id, entry.input.input_id);
    }
    return commits;
}

/// Commit one input as a user message in the caller's transaction.
fn commitInput(db: *Database, io: std.Io, arena: std.mem.Allocator, session_id: [16]u8, input: Input, input_id: ids.InputId, created_at_ms: u64, now: u64) !message_store.Commit {
    std.debug.assert(sql.inTransaction(db.conn));
    const message: proto.message.Message = .{ .user = .{
        .id = try event_store.allocMessageId(db, arena, session_id),
        .content = input.content,
        .input_id = input_id,
        .source = input.source,
        .skill_name = input.skill_name,
        .time = .{ .created_at_ms = created_at_ms },
    } };
    return message_store.appendCommittedMessage(db, arena, session_id, util.newId(io), now, message);
}

/// The response gate must launch a prepared run exactly once through an optional token.
pub const Launch = union(enum) {
    slot: *RunSlot,
    wake: ids.SessionId,

    /// Launch the prepared slot. Return when another path consumed the token.
    pub fn release(self: *?Launch, engine: *Engine) void {
        const token = self.* orelse return;
        self.* = null;
        switch (token) {
            .slot => |slot| launch(engine, slot) catch |err| {
                std.log.err("cannot release the run launch gate: {t}", .{err});
            },
            .wake => |parent| admission.drain(engine, parent) catch |err| {
                std.log.err("cannot admit a queued child: {t}", .{err});
            },
        }
    }
};

/// Launch a prepared slot after its durable start and response gate.
pub fn launch(engine: *Engine, slot: *RunSlot) !void {
    std.debug.assert(slot.phase == .pending_start);
    std.debug.assert(slot.progress.current == null);
    std.debug.assert(engine.sessions.get(slot.sessionId()).?.active_run == slot);
    if (slot.handle.started.kind == .turn) slot.retry_budget = engine.deps.retry_budget;
    slot.phase = .running;
    engine.turn_tasks.concurrent(engine.deps.io, execute, .{ engine, slot }) catch |err| {
        var scratch: std.heap.ArenaAllocator = .init(engine.deps.gpa);
        defer scratch.deinit();
        finishRunOpen(engine, scratch.allocator(), slot, .{ .failed = .{
            .code = .internal,
            .message = switch (slot.handle.started.kind) {
                .turn => "the engine could not launch the run task",
                .compaction => "the engine could not launch the compaction task",
            },
        } }) catch |commit_err| faultSlot(engine, slot, commit_err);
        finishSlot(engine, slot);
        return err;
    };
}

/// Retain the slot until the task body and all native work end.
pub fn execute(engine: *Engine, slot: *RunSlot) void {
    std.debug.assert(slot.phase == .running);
    std.debug.assert(engine.sessions.get(slot.sessionId()).?.active_run == slot);
    defer finishSlot(engine, slot);
    switch (slot.handle.started.kind) {
        .turn => turn.execute(engine, slot),
        .compaction => compaction.execute(engine, slot),
    }
}

/// Publish the terminal record before its notice and child report.
pub fn publishTerminal(engine: *Engine, rt: *Session, terminal: reports.Terminal) void {
    std.debug.assert(!sql.inTransaction(engine.deps.db.conn));
    std.debug.assert(std.meta.eql(rt.id, terminal.done.session_id));
    session_events.emitDurable(engine, rt, .{ .method = .@"run.done", .params = .{ .run_done_data = terminal.done } });
    if (terminal.notice) |notice| session_events.emitCommitted(engine, rt, notice);
    if (terminal.report) |report| reports.publishReport(engine, report, true);
}

/// End a run with no active assistant message.
pub fn finishRunOpen(engine: *Engine, arena: std.mem.Allocator, slot: *RunSlot, outcome: proto.run.RunOutcome) !void {
    std.debug.assert(slot.phase == .running);
    std.debug.assert(slot.progress.current == null);
    const old_cancel_protection = engine.deps.io.swapCancelProtection(.blocked);
    defer _ = engine.deps.io.swapCancelProtection(old_cancel_protection);

    const session_id = slot.sessionId();
    const ended_at = @max(engine.nowMillis(), slot.handle.started.started_at_ms);
    var tx = try engine.deps.db.*.begin();
    defer tx.deinit();
    const done = try reports.append(engine, arena, .{
        .session_id = session_id,
        .seq = 0,
        .run_id = slot.runId(),
        .kind = slot.handle.started.kind,
        .timing = .{ .started_at_ms = slot.handle.started.started_at_ms, .ended_at_ms = ended_at },
        .outcome = outcome,
    });
    try tx.commit();
    slot.phase = .terminalized;

    const rt = engine.sessions.get(session_id) orelse unreachable;
    publishTerminal(engine, rt, done);
}

/// Preserve the open marker after a failed terminal transaction.
pub fn faultSlot(engine: *Engine, slot: *RunSlot, err: anyerror) void {
    const session_id = slot.sessionId();
    std.debug.assert(slot.phase == .running);
    const rt = engine.sessions.get(session_id).?;
    std.debug.assert(rt.active_run == slot);
    slot.phase = .faulted;
    rt.faulted = true;
    reports.faultNotice(engine, session_id, slot.runId(), err);
}

fn finishSlot(engine: *Engine, slot: *RunSlot) void {
    engine.beginContinuation();
    defer engine.endContinuation();
    const session_id = slot.sessionId();
    slot.work.drain(engine.deps.io);
    std.debug.assert(slot.body == null);
    std.debug.assert(slot.phase == .terminalized or slot.phase == .faulted);
    const rt = engine.sessions.get(session_id) orelse unreachable;
    std.debug.assert(rt.active_run == slot);
    const can_drain = slot.phase == .terminalized and !engine.closing and !rt.faulted;
    const parent = slot.parent_id;
    rt.active_run = null;
    slot.destroy();

    // A manual compaction takes priority over queued input.
    const compacting = can_drain and startPendingCompaction(engine, rt);
    if (parent != null and !engine.closing) {
        admission.drain(engine, parent.?) catch |err| {
            std.log.err("cannot admit a queued child: {t}", .{err});
        };
    } else if (!compacting and can_drain) {
        // A failed launch nests a finish that can evict this session, so read the registry again.
        if (engine.sessions.get(session_id)) |current| if (current.queueDepth() > 0) {
            startQueued(engine, current) catch |err| {
                if (engine.sessions.get(session_id)) |failed| failed.faulted = true;
                std.log.err("cannot start a queued run: {t}", .{err});
            };
        };
    }
    // A nested finishSlot can evict the session, so look the runtime up again before it is read.
    if (engine.sessions.get(session_id)) |settled| session_events.announceActivity(engine, settled);
    engine.sessions.evictIfIdle(session_id);
}

fn startQueued(engine: *Engine, rt: *Session) !void {
    const slot = try prepareQueued(engine, rt);
    try launch(engine, slot);
}

pub const Preparation = struct {
    snapshot: session_store.Snapshot,
    tree: admission.Location,
};

/// Load the session values that a run slot needs.
pub fn prepareContext(engine: *Engine, arena: std.mem.Allocator, rt: *Session, ensure_owner: bool) !Preparation {
    if (ensure_owner) try engine.own(rt.id);
    const snapshot = (try session_store.snapshot(engine.deps.db, arena, rt.id.raw)) orelse return error.UnknownSession;
    return .{ .snapshot = snapshot, .tree = try admission.location(engine, arena, rt.id) };
}

/// Read the configuration of a run slot before its start transaction, so no read can fail after the commit.
pub fn slotConfig(engine: *Engine, arena: std.mem.Allocator, rt: *Session, context: Preparation, kind: proto.enums.RunKind) !session.Config {
    std.debug.assert(rt.active_run == null);
    const prompt = if (try session_store.prompt(engine.deps.db, arena, rt.id.raw)) |stored| stored.text else "";
    return .{ .model = context.snapshot.model, .reasoning = context.snapshot.reasoning, .system_prompt = prompt, .max_rounds = if (kind == .turn) context.snapshot.max_rounds else null, .root = context.snapshot.root, .name = context.snapshot.name };
}

/// Create the slot of a committed start. Only an allocation follows the commit.
pub fn createSlot(engine: *Engine, context: Preparation, started: Started, config: session.Config) !*RunSlot {
    return RunSlot.create(engine.deps.gpa, started.handle, if (context.snapshot.parent_id) |id| .bytes(id) else null, context.tree, config);
}

/// Emit the durable start after the caller folds any user commits.
pub fn emitStarted(engine: *Engine, rt: *Session, started: Started) void {
    session_events.emitDurable(engine, rt, .{ .method = .@"run.started", .params = .{ .run_started_data = started.handle.started } });
}

/// Commit one run for all queued inputs.
pub fn prepareQueued(engine: *Engine, rt: *Session) !*RunSlot {
    var arena_state = std.heap.ArenaAllocator.init(engine.deps.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const context = try prepareContext(engine, arena, rt, true);
    std.debug.assert(rt.active_run == null);
    std.debug.assert(rt.queueDepth() > 0);

    // The arena holds store values until the slot owns its prompt and run ids.
    const session_id = rt.id;
    const config = try slotConfig(engine, arena, rt, context, .turn);
    const started = try beginQueuedTurn(engine.deps.db, engine.deps.io, arena, session_id.raw, context.snapshot.config_rev);
    const slot = try createSlot(engine, context, started, config);
    // Publish the user commits before run.started to retire the queue in sequence order.
    session_events.publishUserCommits(engine, rt, started.user_commits);
    std.debug.assert(rt.queueDepth() == 0);
    rt.active_run = slot;
    emitStarted(engine, rt, started);
    return slot;
}

/// Restart durable queued work after frontend setup.
pub fn resumeSession(engine: *Engine, rt: *Session) !void {
    if (engine.closing) return error.EngineClosing;
    if (rt.active_run != null) return;
    if (rt.queueDepth() == 0) return;
    var scratch: std.heap.ArenaAllocator = .init(engine.deps.gpa);
    defer scratch.deinit();
    const row = (try session_store.snapshot(engine.deps.db, scratch.allocator(), rt.id.raw)) orelse return error.UnknownSession;
    if (row.parent_id) |parent| return admission.drain(engine, .bytes(parent));
    try startQueued(engine, rt);
}

/// Commit and publish the run start. A reserved id belongs to a compaction the engine already answered.
pub fn prepareCompaction(engine: *Engine, rt: *Session, reason: proto.enums.CompactionReason, reserved: ?proto.ids.RunId) !*RunSlot {
    var arena_state: std.heap.ArenaAllocator = .init(engine.deps.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const context = try prepareContext(engine, arena, rt, true);
    std.debug.assert(rt.active_run == null);
    const sid = rt.id.raw;
    const config = try slotConfig(engine, arena, rt, context, .compaction);

    const started_at = engine.nowMillis();
    var tx = try engine.deps.db.begin();
    defer tx.deinit();
    const run_id = reserved orelse try database.event.allocRunId(engine.deps.db, arena, sid);
    const started = try database.run.appendStarted(engine.deps.db, arena, engine.newId(), started_at, .{
        .session_id = rt.id,
        .seq = 0,
        .run_id = run_id,
        .kind = .compaction,
        .reason = reason,
        .config_rev = context.snapshot.config_rev,
        .started_at_ms = started_at,
    });
    try tx.commit();

    const started_result: Started = .{ .handle = .{ .input_id = 0, .started = started }, .user_commits = &.{} };
    const slot = try createSlot(engine, context, started_result, config);
    rt.active_run = slot;
    emitStarted(engine, rt, started_result);
    session_events.announceActivity(engine, rt); // A compaction opens no round, so nothing else says it runs.
    return slot;
}

/// Allocate one run id for a compaction the engine answers before it starts.
pub fn reserveCompaction(engine: *Engine, arena: std.mem.Allocator, session_id: [16]u8) !proto.ids.RunId {
    var tx = try engine.deps.db.begin();
    defer tx.deinit();
    const run_id = try database.event.allocRunId(engine.deps.db, arena, session_id);
    try tx.commit();
    return run_id;
}

/// Start the compaction the session holds. Report whether it took the session.
pub fn startPendingCompaction(engine: *Engine, rt: *Session) bool {
    const pending = rt.pending_compaction orelse return false;
    std.debug.assert(rt.active_run == null);
    const slot = prepareCompaction(engine, rt, pending.reason, pending.run_id) catch |err| {
        std.log.err("cannot start the pending compaction of run {d}: {t}", .{ pending.run_id, err });
        rt.pending_compaction = null; // A compaction that cannot start must not block the queue.
        return false;
    };
    rt.pending_compaction = null;
    launch(engine, slot) catch |err| {
        std.log.err("cannot launch the pending compaction of run {d}: {t}", .{ pending.run_id, err });
        return false; // `launch` terminalized the run and released the session.
    };
    return true;
}

const testing = std.testing;
const zio = @import("zio");
const test_resources = @import("test_resources.zig");
const commands = @import("commands.zig");

test "queued input and compaction retain process activity through successor admission" {
    const Fixture = test_resources.Fixture;
    const Probe = struct {
        engine: *Engine,
        last: bool = false,
        changes: usize = 0,

        fn onEvent(ctx: *anyopaque, _: proto.rpc.Notification) void {
            onActivity(ctx);
        }

        fn onActivity(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            const busy = self.engine.isBusy();
            if (self.last == busy) return;
            self.last = busy;
            self.changes += 1;
        }
    };
    var f: Fixture = undefined;
    try f.init(.{});
    defer f.deinit();
    var probe: Probe = .{ .engine = &f.engine };
    f.engine.sinks.add(.{ .ctx = &probe, .on_event = Probe.onEvent, .on_activity = Probe.onActivity });
    defer f.engine.sinks.remove(&probe);
    try testing.expect(!f.engine.isBusy());
    _ = try f.send(&.{.{ .text = .{ .text = "first" } }});
    try testing.expect(f.engine.isBusy());
    const resident = f.engine.sessions.get(Fixture.id).?;
    try testing.expectEqual(@as(u32, 0), resident.pins);
    var queued_gate: ?Launch = null;
    _ = try commands.sessionSendInputForRpc(&f.engine, f.arena.allocator(), .{
        .session_id = Fixture.id,
        .input = .{ .content = .{ .content = &.{.{ .text = .{ .text = "second" } }} } },
    }, &queued_gate, null);
    try testing.expect(queued_gate == null);
    const compact = try commands.sessionCompact(&f.engine, f.arena.allocator(), .{ .session_id = Fixture.id }, &queued_gate);
    try testing.expectEqual(proto.enums.CompactStatus.queued, compact.status);
    const slot = f.gate.?.slot;
    f.gate = null;
    slot.phase = .running;
    try finishRunOpen(&f.engine, f.arena.allocator(), slot, .{ .turn = .{ .finish = .stop, .rounds = 0 } });
    finishSlot(&f.engine, slot);
    try test_resources.awaitLiveIdle(&f.engine, Fixture.id);
    try testing.expect(!f.engine.isBusy());
    try testing.expectEqual(@as(usize, 2), probe.changes);
    try testing.expectEqual(@as(i64, 3), try eventCount(&f.db, "run.started"));
}
fn eventCount(db: *Database, name: []const u8) !i64 {
    const row = (try db.conn.row("SELECT count(*) FROM events WHERE name = ?1", .{name})) orelse return error.NoRow;
    defer row.deinit();
    return row.int(0);
}

test "beginQueuedTurn drains all durable inputs in FIFO order" {
    const rt = try zio.Runtime.init(testing.allocator, .{ .executors = .exact(1) });
    defer rt.deinit();
    var db = try Database.openTest();
    defer db.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sid = [_]u8{3} ** 16;
    try session_store.seedSession(&db, sid);

    const one = [_]proto.content.ContentPart{.{ .text = .{ .text = "one" } }};
    const two = [_]proto.content.ContentPart{.{ .text = .{ .text = "two" } }};
    try db.conn.execNoArgs("BEGIN IMMEDIATE");
    _ = try input_store.enqueue(&db, a, sid, [_]u8{1} ** 16, 110, .{ .content = &one, .skill_name = "pdf" }, 101);
    _ = try input_store.enqueue(&db, a, sid, [_]u8{2} ** 16, 120, .{ .content = &two }, 102);
    try db.conn.execNoArgs("COMMIT");

    const started = try beginQueuedTurn(&db, rt.io(), a, sid, 7);
    const handle = started.handle;
    try testing.expectEqual(@as(u64, 1), handle.started.run_id);
    try testing.expectEqual(@as(u64, 1), handle.input_id);
    // The drain returns one committed user message per input in FIFO order with contiguous sequences.
    try testing.expectEqual(@as(usize, 2), started.user_commits.len);
    try testing.expectEqual(@as(u64, 1), started.user_commits[0].data.message.user.id);
    try testing.expectEqual(@as(u64, 2), started.user_commits[1].data.message.user.id);
    try testing.expectEqual(started.user_commits[0].data.seq + 1, started.user_commits[1].data.seq);
    try testing.expect(started.user_commits[1].data.seq < handle.started.seq); // run.started follows the commits
    try testing.expectEqual(@as(i64, 0), blk: {
        const row = (try db.conn.row("SELECT count(*) FROM pending_inputs", .{})) orelse return error.NoRow;
        defer row.deinit();
        break :blk row.int(0);
    });

    const page = try message_store.historyPage(&db, a, sid, 0, 10);
    try testing.expectEqual(@as(usize, 2), page.messages.len);
    try testing.expectEqual(@as(u64, 1), page.messages[0].user.id);
    try testing.expectEqual(@as(u64, 2), page.messages[1].user.id);
    try testing.expectEqual(@as(u64, 1), page.messages[0].user.input_id);
    try testing.expectEqual(@as(u64, 2), page.messages[1].user.input_id);
    try testing.expectEqual(@as(u64, 101), page.messages[0].user.time.created_at_ms);
    try testing.expectEqual(@as(u64, 102), page.messages[1].user.time.created_at_ms);
    try testing.expectEqualStrings("one", page.messages[0].user.content[0].text.text);
    try testing.expectEqualStrings("pdf", page.messages[0].user.skill_name.?);
    try testing.expect(page.messages[1].user.skill_name == null);
    try testing.expectEqualStrings("two", page.messages[1].user.content[0].text.text);
    try testing.expectEqual(@as(i64, 1), try eventCount(&db, "run.started"));
    try testing.expectEqual(@as(i64, 0), try eventCount(&db, "run.done"));
    try testing.expectEqual(@as(?u64, handle.started.run_id), (try session_store.snapshot(&db, a, sid)).?.open_run_id);
}

test "launch failure releases both run kinds and preserves a failed terminal transaction" {
    const Fixture = test_resources.Fixture;
    const Notice = struct {
        session: *Session,
        seen: bool = false,

        fn onEvent(ctx: *anyopaque, note: proto.rpc.Notification) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (note.method != .notice) return;
            self.seen = self.session.active_run.?.phase == .faulted and
                std.mem.eql(u8, note.params.notice.source, "engine") and
                std.mem.indexOf(u8, note.params.notice.message, "Restart yuke to recover") != null;
        }
    };
    for ([_]proto.enums.RunKind{ .turn, .compaction }) |kind| {
        for ([_]bool{ false, true }) |reject_terminal| {
            var f: Fixture = undefined;
            try f.init(.{});
            defer f.deinit();
            const a = f.arena.allocator();
            const resident = try f.engine.activate(Fixture.id);
            resident.pin();
            const slot = switch (kind) {
                .turn => slot: {
                    _ = try f.send(&.{.{ .text = .{ .text = "hello" } }});
                    const prepared = f.gate.?.slot;
                    f.gate = null;
                    break :slot prepared;
                },
                .compaction => try prepareCompaction(&f.engine, resident, .manual, null),
            };
            const run_id = slot.runId();
            try testing.expect(f.engine.isBusy());
            if (reject_terminal) try f.db.conn.execNoArgs("CREATE TEMP TRIGGER refuse_done BEFORE INSERT ON events WHEN NEW.name = 'run.done' BEGIN SELECT RAISE(FAIL, 'test refusal'); END");
            var notice: Notice = .{ .session = resident };
            f.engine.sinks.add(.{ .ctx = &notice, .on_event = Notice.onEvent });
            defer f.engine.sinks.remove(&notice);
            const io = f.engine.deps.io;
            var vtable = io.vtable.*;
            vtable.groupConcurrent = std.Io.failingGroupConcurrent;
            f.engine.deps.io.vtable = &vtable;
            defer f.engine.deps.io = io;

            try testing.expectError(error.ConcurrencyUnavailable, launch(&f.engine, slot));
            try testing.expect(resident.active_run == null);
            try testing.expect(!f.engine.isBusy());
            try testing.expectEqual(reject_terminal, resident.faulted);
            try testing.expectEqual(reject_terminal, notice.seen);
            try testing.expectEqual(@as(usize, 0), f.capture.requests.items.len);
            const snapshot = (try session_store.snapshot(&f.db, a, Fixture.id.raw)).?;
            if (reject_terminal) {
                try testing.expectEqual(@as(?u64, run_id), snapshot.open_run_id);
                try testing.expectEqual(@as(i64, 0), try eventCount(&f.db, "run.done"));
            } else {
                try testing.expect(snapshot.open_run_id == null);
                try testing.expectEqual(@as(i64, 1), try eventCount(&f.db, "run.done"));
                const row = (try f.db.conn.row("SELECT payload FROM events WHERE name = 'run.done'", .{})).?;
                defer row.deinit();
                const done = try std.json.parseFromSliceLeaky(proto.run.RunDoneData, a, row.text(0), .{});
                try testing.expectEqual(kind, done.kind);
                try testing.expectEqual(run_id, done.run_id);
                try testing.expectEqual(proto.enums.RunErrorCode.internal, done.outcome.failed.code);
            }
        }
    }
}
