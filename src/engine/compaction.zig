//! Summarize the history below a boundary into one message. The tail after the boundary stays exact.

const std = @import("std");
const proto = @import("proto");
const database = @import("../store/store.zig");
const context = @import("context.zig");

/// How much recent history one compaction keeps, in estimated tokens.
pub const default_keep_recent_tokens: u64 = 20_000;

/// One tool result or one argument blob contributes about this many bytes to the summary source.
const max_source_field_bytes: usize = 2048;

/// The boundary one compaction takes.
pub const Cut = struct {
    /// The first message the tail keeps. Every earlier message enters the summary.
    first_kept_id: proto.ids.MessageId,
    /// The estimate of the whole scanned context, which the summary and the tail replace.
    tokens_before: u64,
    /// The estimate of the tail this cut keeps.
    tokens_kept: u64,
};

/// Cut at the start of the turn that holds the tail target. Null means no earlier turn to summarize.
pub fn selectCut(gpa: std.mem.Allocator, db: *database.Database, session_id: [16]u8, from_id: u64, target: u64) !?Cut {
    std.debug.assert(target > 0);
    var rows = try db.queries.context_sizes.rows(.{ .session_id = session_id, .first_message_id = from_id });
    defer rows.deinit();

    var total: u64 = 0;
    var tail: u64 = 0;
    var crossed = false;
    // The oldest message of the backward run of user messages, which is where a turn starts.
    var pending: u64 = 0;
    var pending_tokens: u64 = 0;
    var cut: ?Cut = null;

    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    while (try rows.next(scratch.allocator())) |owned| {
        defer _ = scratch.reset(.retain_capacity);
        {
            var row = owned;
            defer row.deinit();
            if (std.mem.eql(u8, row.value.role, "compaction")) continue;
            const tokens = context.tokensFor(row.value.bytes);
            total += tokens;
            if (cut == null) {
                tail += tokens;
                if (std.mem.eql(u8, row.value.role, "user")) {
                    // An older user message extends the same turn, so the run start moves back.
                    pending = row.value.message_id;
                    pending_tokens = tail;
                } else {
                    // A message that is not a user message closes the run above it.
                    if (crossed and pending != 0) cut = .{ .first_kept_id = pending, .tokens_before = 0, .tokens_kept = pending_tokens };
                    pending = 0;
                }
                if (tail >= target) crossed = true;
            }
        }
    }

    var selected = cut orelse return null;
    selected.tokens_before = total;
    return selected;
}

pub const summarizer_system_prompt =
    \\You are a context summarization assistant. You read a conversation between a user and an AI assistant, and you write one structured summary in the exact format the instructions name.
    \\
    \\Do not continue the conversation. Do not answer any question in it. Write only the summary.
;

const summarize_instructions =
    \\The conversation above is the history to summarize. Write a context checkpoint that another assistant uses to continue the work.
    \\
    \\Use this exact format:
    \\
    \\## Goal
    \\[What does the user want? Name each task when the session covers more than one.]
    \\
    \\## Constraints and preferences
    \\- [Each constraint, preference, or requirement the user stated]
    \\- [Or "(none)"]
    \\
    \\## Progress
    \\### Done
    \\- [x] [Completed work]
    \\
    \\### In progress
    \\- [ ] [Current work]
    \\
    \\### Blocked
    \\- [What stops the work, if anything]
    \\
    \\## Key decisions
    \\- **[Decision]**: [Short reason]
    \\
    \\## Next steps
    \\1. [What happens next, in order]
    \\
    \\## Critical context
    \\- [Data, examples, or references the next assistant needs]
    \\- [Or "(none)"]
    \\
    \\Keep each section short. Keep exact file paths, symbol names, and error messages.
;

const merge_instructions =
    \\The conversation above holds the new messages. The <previous-summary> block holds the summary of every earlier message.
    \\
    \\Write one summary that replaces both. Rules:
    \\- Keep every fact from the previous summary.
    \\- Add the new progress, decisions, and context from the new messages.
    \\- Move an item from "In progress" to "Done" when the new messages completed it.
    \\- Update "Next steps" against the current state.
    \\- Keep exact file paths, symbol names, and error messages.
    \\- Remove an item only when it no longer applies.
    \\
    \\Use this exact format:
    \\
    \\## Goal
    \\[Keep the earlier goals. Add a new one when the task grew.]
    \\
    \\## Constraints and preferences
    \\- [Keep the earlier ones. Add each new one.]
    \\
    \\## Progress
    \\### Done
    \\- [x] [The earlier done items and the new ones]
    \\
    \\### In progress
    \\- [ ] [Current work]
    \\
    \\### Blocked
    \\- [What stops the work now]
    \\
    \\## Key decisions
    \\- **[Decision]**: [Short reason]
    \\
    \\## Next steps
    \\1. [What happens next, in order]
    \\
    \\## Critical context
    \\- [Data, examples, or references the next assistant needs]
    \\
    \\Keep each section short.
;

const Engine = @import("Engine.zig");
const session_mod = @import("../session/session.zig");
const Session = session_mod.Session;
const RunSlot = session_mod.RunSlot;
const turn = @import("turn.zig");
const model_call = @import("model_call.zig");
const session_events = @import("events.zig");
const provider = @import("../provider/provider.zig");
const admission = @import("admission.zig");

/// The output one summary may take. A checkpoint states the work, not the conversation.
const summary_output_tokens: u32 = 4096;

/// Commit and publish the run start. A reserved id belongs to a compaction the engine already answered.
pub fn begin(engine: *Engine, rt: *Session, reason: proto.enums.CompactionReason, reserved: ?proto.ids.RunId) !*RunSlot {
    try engine.own(rt.id);
    std.debug.assert(rt.active_run == null);
    var arena_state: std.heap.ArenaAllocator = .init(engine.deps.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const sid = rt.id.raw;
    const snapshot = (try database.session.snapshot(engine.deps.db, arena, sid)) orelse return error.UnknownSession;
    const tree = try admission.location(engine, arena, rt.id);
    const prompt = (try database.session.prompt(engine.deps.db, arena, sid)) orelse "";
    var prepared = try RunSlot.prepare(engine.deps.gpa, snapshot.model, snapshot.reasoning, prompt, null);
    errdefer prepared.deinit();

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
        .config_rev = snapshot.config_rev,
        .started_at_ms = started_at,
    });
    try tx.commit();

    const slot = prepared.bind(.{ .input_id = 0, .started = started }, if (snapshot.parent_id) |id| .bytes(id) else null, tree);
    rt.active_run = slot;
    session_events.emitDurable(engine, rt, .{ .method = .@"run.started", .params = .{ .run_started_data = started } });
    session_events.announceActivity(engine, rt); // A compaction opens no round, so nothing else says it runs.
    return slot;
}

/// Launch one prepared compaction. The engine task group owns the task.
pub fn launch(engine: *Engine, slot: *RunSlot) !void {
    std.debug.assert(slot.phase == .pending_start);
    std.debug.assert(slot.progress.current == null); // a compaction opens no round
    const session_id = slot.sessionId();
    slot.phase = .running;
    engine.turn_tasks.concurrent(engine.deps.io, runTask, .{ engine, slot }) catch |err| {
        var scratch: std.heap.ArenaAllocator = .init(engine.deps.gpa);
        defer scratch.deinit();
        turn.finishRunOpen(engine, scratch.allocator(), slot, .{ .failed = .{
            .code = .internal,
            .message = "the engine could not launch the compaction task",
        } }) catch |commit_err| turn.faultSlot(engine, session_id, slot, commit_err);
        turn.finishSlot(engine, session_id, slot);
        return err;
    };
}

/// Allocate one run id for a compaction the engine answers before it starts.
pub fn reserveRun(engine: *Engine, arena: std.mem.Allocator, session_id: [16]u8) !proto.ids.RunId {
    var tx = try engine.deps.db.begin();
    defer tx.deinit();
    const run_id = try database.event.allocRunId(engine.deps.db, arena, session_id);
    try tx.commit();
    return run_id;
}

/// Start the compaction the session holds. Report whether it took the session.
pub fn startPending(engine: *Engine, rt: *Session) bool {
    const pending = rt.pending_compaction orelse return false;
    std.debug.assert(rt.active_run == null);
    const slot = begin(engine, rt, pending.reason, pending.run_id) catch |err| {
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

/// Run one compaction. The engine task group owns this task; the session owns `slot` until cleanup.
fn runTask(engine: *Engine, slot: *RunSlot) void {
    const session_id = slot.sessionId();
    defer turn.finishSlot(engine, session_id, slot);
    var arena_state: std.heap.ArenaAllocator = .init(engine.deps.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var completed: ?proto.run.RunOutcome = null;
    const result = switch (slot.cancel.runChild(engine.deps.io, summarizeChild, .{ engine, arena, slot, &completed })) {
        .canceled, .aborted => @as(anyerror!void, error.Canceled),
        .returned => |result| result,
    };
    const outcome = if (completed) |outcome| outcome else if (result) |_| unreachable else |err| blk: {
        if (err == error.Canceled or slot.cancel.requested) break :blk proto.run.RunOutcome{ .canceled = .{} };
        // The wire message names a class, so record the cause before the error loses it.
        std.log.warn("compaction run {d} ended: {t}", .{ slot.runId(), err });
        const detail = provider.failure.classify(err);
        break :blk proto.run.RunOutcome{ .failed = .{ .code = detail.code, .message = detail.message } };
    };
    turn.finishRunOpen(engine, arena, slot, outcome) catch |err| turn.faultSlot(engine, session_id, slot, err);
}

fn summarizeChild(engine: *Engine, arena: std.mem.Allocator, slot: *RunSlot, out: *?proto.run.RunOutcome) !void {
    defer slot.cancel.finish(engine.deps.io);
    try slot.cancel.check(engine.deps.io);
    const budget = try @import("request.zig").budgetFor(arena, engine, slot);
    out.* = try summarize(engine, arena, slot, budget);
}

/// Compact once before a request; a failed compaction never permits a partial context.
pub fn beforeRequest(engine: *Engine, arena: std.mem.Allocator, slot: *RunSlot, budget: context.Budget) !void {
    if (try context.estimate(arena, engine.deps.db, slot.sessionId().raw) <= budget.input_ceiling) return;
    std.debug.assert(slot.handle.started.kind == .turn);
    const rt = engine.sessions.get(slot.sessionId()) orelse return error.UnknownSession;
    std.debug.assert(rt.active_run == slot and slot.progress.current == null);
    std.debug.assert(rt.draft == null and !slot.compacting);
    slot.compacting = true;
    session_events.announceActivity(engine, rt);
    defer {
        slot.compacting = false;
        session_events.announceActivity(engine, rt);
    }
    const outcome = try summarize(engine, arena, slot, budget);
    if (outcome != .compacted) return error.ContextHistoryTooLarge;
}

/// Write the instruction that trails the covered range. The turn system prompt leads the request.
fn summaryInstruction(arena: std.mem.Allocator, merges: bool) ![]const u8 {
    return std.mem.concat(arena, u8, &.{
        summarizer_system_prompt,
        "\n\n",
        if (merges) merge_instructions else summarize_instructions,
    });
}

/// Summarize the covered range and commit the checkpoint. A range with no work is a skip.
fn summarize(engine: *Engine, arena: std.mem.Allocator, slot: *RunSlot, request_budget: context.Budget) !proto.run.RunOutcome {
    try slot.cancel.check(engine.deps.io);
    const sid = slot.sessionId().raw;
    const db = engine.deps.db;
    // The registry can rebuild across a file read, so each step reads the window it needs and holds no row.
    const window = blk: {
        const row = engine.deps.providers.merged.resolveModel(slot.config.model) orelse return error.UnknownModel;
        break :blk row.model.limits.context_window orelse context.default_context_window;
    };
    const head = try context.readHead(arena, db, sid);
    var cut = (try selectCut(engine.deps.gpa, db, sid, if (head) |h| h.from_id else 0, tailTarget(window))) orelse
        return .{ .skipped = .{ .reason = .too_few_messages } };
    if (head) |h| cut.tokens_before += context.summaryTokens(h.message.compaction.summary);
    if (cut.tokens_kept >= request_budget.input_ceiling) return error.TurnTooLarge;
    // The merged registry can rebuild, so the resolve and the call stay in one step.
    const match = engine.deps.providers.merged.resolveModel(slot.config.model) orelse return error.UnknownModel;
    const live_route = switch (match.provider.availability) {
        .ready => |ready| ready,
        .unavailable => return error.UnknownModel,
    };
    // The summary repeats the system prompt and the tools of the turn, so it reuses the cached prefix.
    // The selection mirrors `request.selectionFor`, because a different tool list breaks that prefix.
    if (slot.has_skills == null) slot.has_skills = try database.session.hasSkills(db, arena, sid);
    const tools = try engine.deps.tools.getDecls(engine.deps.tools.ctx, arena, .{
        .can_spawn = slot.depth < engine.max_agent_depth,
        .has_skills = slot.has_skills.?,
    });
    // `context.project` refuses a history above the budget, and a compaction runs only above it.
    const covered = try context.collect(arena, db, sid, head, cut.first_kept_id);
    const built = try provider.request_builder.build(arena, covered, .{
        .target = .{ .protocol = live_route.route.protocol, .model = slot.config.model },
        .modalities = match.model.modalities,
    });
    if (built.blocks.len == 0) return .{ .skipped = .{ .reason = .nothing_to_summarize } };

    const budget = try context.Budget.forRequest(window, summary_output_tokens, slot.config.system_prompt, tools);
    // No chunked summary exists, so a range above the window fails and never covers a part.
    if (cut.tokens_before > budget.input_ceiling) return error.CompactionSourceTooLarge;

    // The instruction trails the covered range, so every block above it repeats the turn prefix.
    const blocks = try arena.alloc(ai.ir.Block, built.blocks.len + 1);
    @memcpy(blocks[0..built.blocks.len], built.blocks);
    blocks[built.blocks.len] = .{ .role = .user, .value = .{ .text = try summaryInstruction(arena, head != null) } };

    const answer = try model_call.generateWith(engine, arena, &slot.cancel, match, .{
        .system = slot.config.system_prompt,
        .blocks = blocks,
        .tools = tools,
        .max_output_tokens = summary_output_tokens,
        .reasoning = slot.config.reasoning,
    });
    if (answer.finish_reason != .stop) return error.IncompleteSummary;
    if (std.mem.trim(u8, answer.text, " \t\r\n").len == 0) return error.EmptySummary;
    const after = cut.tokens_kept + context.summaryTokens(answer.text);
    if (after > request_budget.input_ceiling or after >= cut.tokens_before) return error.CompactionDidNotFit;
    try slot.cancel.check(engine.deps.io);
    return commit(engine, arena, slot, cut, answer.text);
}

/// A small window takes a small tail, so one compaction always reclaims a useful share of it.
fn tailTarget(window: u64) u64 {
    return @max(1, @min(default_keep_recent_tokens, window / 10));
}

/// Commit the checkpoint, then publish it. The run terminal follows in the run task.
fn commit(engine: *Engine, arena: std.mem.Allocator, slot: *RunSlot, cut: Cut, summary: []const u8) !proto.run.RunOutcome {
    std.debug.assert(summary.len != 0);
    const session_id = slot.sessionId();
    const rt = engine.sessions.get(session_id) orelse return error.UnknownSession;
    const now = engine.nowMillis();
    const protection = engine.deps.io.swapCancelProtection(.blocked);
    defer _ = engine.deps.io.swapCancelProtection(protection);

    var tx = try engine.deps.db.begin();
    defer tx.deinit();
    std.debug.assert(rt.draft == null);
    std.debug.assert(slot.progress.current == null);
    const message_id = try database.event.allocMessageId(engine.deps.db, arena, session_id.raw);
    const message: proto.message.Message = .{ .compaction = .{
        .id = message_id,
        .run_id = slot.runId(),
        .reason = slot.handle.started.reason orelse .auto,
        .summary = summary,
        .first_kept_id = cut.first_kept_id,
        .tokens_before = cut.tokens_before,
        .tokens_after = cut.tokens_kept + context.summaryTokens(summary),
        .time = .{ .created_at_ms = now },
    } };
    const seq = try database.message.appendCommittedMessage(engine.deps.db, arena, session_id.raw, engine.newId(), now, message);
    try tx.commit();

    session_events.emitDurable(engine, rt, .{ .method = .@"message.committed", .params = .{
        .message_committed_data = .{ .session_id = session_id, .seq = seq, .message = message },
    } });
    session_events.announceSummary(engine, session_id); // the commit moved the message count
    return .{ .compacted = .{ .message_id = message_id } };
}

const testing = std.testing;

test "the cut lands on the start of the turn that holds the tail target" {
    var db = try database.Database.openTest();
    defer db.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const sid = [_]u8{7} ** 16;
    try seedSessionModel(&db, sid, "mock", "");

    try seedMessage(&db, arena.allocator(), sid, 1, .user, 300);
    try seedMessage(&db, arena.allocator(), sid, 2, .assistant, 300);
    try seedMessage(&db, arena.allocator(), sid, 3, .user, 300);
    try seedMessage(&db, arena.allocator(), sid, 4, .assistant, 3000);

    const cut = (try selectCut(testing.allocator, &db, sid, 0, 100)).?;
    try testing.expectEqual(@as(u64, 3), cut.first_kept_id);
    try testing.expect(cut.tokens_kept > context.tokensFor(3300));
    try testing.expect(cut.tokens_before > cut.tokens_kept);
}

test "a drained queue starts one turn, so the cut takes every user message of that run" {
    var db = try database.Database.openTest();
    defer db.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const sid = [_]u8{8} ** 16;
    try seedSessionModel(&db, sid, "mock", "");
    try seedMessage(&db, arena.allocator(), sid, 1, .user, 300);
    try seedMessage(&db, arena.allocator(), sid, 2, .assistant, 300);
    try seedMessage(&db, arena.allocator(), sid, 3, .user, 300);
    try seedMessage(&db, arena.allocator(), sid, 4, .user, 300);
    try seedMessage(&db, arena.allocator(), sid, 5, .assistant, 3000);

    const cut = (try selectCut(testing.allocator, &db, sid, 0, 100)).?;
    try testing.expectEqual(@as(u64, 3), cut.first_kept_id);
}

test "a history with no earlier turn is a skip" {
    var db = try database.Database.openTest();
    defer db.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const sid = [_]u8{9} ** 16;
    try seedSessionModel(&db, sid, "mock", "");
    try seedMessage(&db, arena.allocator(), sid, 1, .user, 300);
    try seedMessage(&db, arena.allocator(), sid, 2, .assistant, 30_000);

    // The target is inside the only turn, so a cut would summarize nothing.
    try testing.expectEqual(@as(?Cut, null), try selectCut(testing.allocator, &db, sid, 0, 100));
    // A history under the target needs no compaction either.
    try testing.expectEqual(@as(?Cut, null), try selectCut(testing.allocator, &db, sid, 0, 1_000_000));
}

fn seedSessionModel(db: *database.Database, id: [16]u8, model: []const u8, reasoning: []const u8) !void {
    try database.session.create(db, .{
        .id = id,
        .root = "/w",
        .origin = "root",
        .profile = "default",
        .model = model,
        .reasoning = reasoning,
        .config_rev = 0,
        .title = "t",
        .created_at_ms = 1,
        .updated_at_ms = 1,
    });
}

/// Commit one message of about `bytes` payload bytes, so a scan test states its own sizes.
fn seedMessage(db: *database.Database, arena: std.mem.Allocator, id: [16]u8, message_id: u64, role: enum { user, assistant }, bytes: usize) !void {
    const filler = try arena.alloc(u8, bytes);
    @memset(filler, 'x');
    const message: proto.message.Message = switch (role) {
        .user => .{ .user = .{ .id = message_id, .input_id = message_id, .content = &.{.{ .text = .{ .text = filler } }}, .time = .{ .created_at_ms = message_id } } },
        .assistant => .{ .assistant = .{ .id = message_id, .run_id = 1, .config_rev = 0, .agent = "root", .time = .{ .created_at_ms = message_id }, .content = &.{.{ .text = .{ .id = 1, .text = filler } }} } },
    };
    var event_id = id;
    event_id[0] = @intCast(message_id);
    var tx = try db.begin();
    defer tx.deinit();
    _ = try database.message.appendCommittedMessage(db, arena, id, event_id, message_id, message);
    try tx.commit();
}

const Resources = @import("test_resources.zig");
const registry = @import("../provider/registry.zig");

/// A resident session whose model resolves to a canned Anthropic route.
const TaskFixture = struct {
    resources: Resources,
    db: database.Database,
    engine: Engine,
    models: [1]registry.ModelSpec,
    rows: [1]registry.Provider,
    session: *Session,
    /// The session reasoning level, which the session row keeps.
    reasoning: []const u8,

    const sid = [_]u8{21} ** 16;

    fn init(self: *TaskFixture) !void {
        return self.initWith("");
    }

    fn initWith(self: *TaskFixture, reasoning: []const u8) !void {
        self.reasoning = reasoning;
        try self.resources.init();
        self.db = try database.Database.openTest();
        self.engine = self.resources.makeEngine(&self.db);
        self.models = .{.{ .id = "m", .upstream_id = "m", .name = "M", .caps = .{ .tools = true }, .limits = .{ .context_window = 200_000 } }};
        self.rows = .{.{ .id = "mock", .name = "Mock", .models = &self.models, .availability = .{ .ready = .{
            .route = .{ .base_url = "https://example.test/v1", .protocol = .anthropic_messages, .auth = .{ .api_key = .x_api_key } },
            .credential = .{ .literal = "secret" },
        } } }};
        // The test owns this snapshot, so no reload can free it under a run.
        self.engine.deps.providers.merged.rows = &self.rows;
        try seedSessionModel(&self.db, sid, "mock/m", self.reasoning);
        self.session = try self.engine.activate(.bytes(sid));
    }

    fn deinit(self: *TaskFixture) void {
        self.engine.deps.providers.merged.rows = &.{};
        self.engine.close();
        self.db.deinit();
        self.resources.deinit();
    }

    /// Run one compaction to its terminal record. The resident session can retire with the run.
    fn run(self: *TaskFixture, reason: proto.enums.CompactionReason) !proto.run.RunOutcome {
        const slot = try begin(&self.engine, self.session, reason, null);
        slot.phase = .running; // the test drives the task, so it takes the transition `launch` makes
        var handle = try self.resources.runtime.spawn(runTask, .{ &self.engine, slot });
        handle.join();
        return self.lastOutcome();
    }

    fn lastOutcome(self: *TaskFixture) !proto.run.RunOutcome {
        const row = (try self.db.conn.row("SELECT payload FROM events WHERE name = 'run.done' ORDER BY seq DESC LIMIT 1", .{})) orelse return error.NoRow;
        defer row.deinit();
        const done = try std.json.parseFromSlice(proto.run.RunDoneData, testing.allocator, row.text(0), .{ .ignore_unknown_fields = true });
        defer done.deinit();
        try testing.expectEqual(proto.enums.RunKind.compaction, done.value.kind);
        return switch (done.value.outcome) {
            .compacted => |compacted| .{ .compacted = compacted },
            .skipped => |skipped| .{ .skipped = skipped },
            .canceled => .{ .canceled = .{} },
            .failed => |failed| .{ .failed = .{ .code = failed.code, .message = "" } },
            .turn => |completed| .{ .turn = completed },
        };
    }
};

test "a compaction commits one checkpoint and ends its run" {
    var f: TaskFixture = undefined;
    try f.init();
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Two turns. The newest turn alone crosses the tail target, so the cut lands at message 3.
    try seedMessage(&f.db, a, TaskFixture.sid, 1, .user, 300);
    try seedMessage(&f.db, a, TaskFixture.sid, 2, .assistant, 300);
    try seedMessage(&f.db, a, TaskFixture.sid, 3, .user, 300);
    try seedMessage(&f.db, a, TaskFixture.sid, 4, .assistant, 70_000);

    const outcome = try f.run(.manual);
    try testing.expectEqual(@as(u64, 5), outcome.compacted.message_id);

    const page = try database.message.historyPage(&f.db, a, TaskFixture.sid, 0, 10);
    const checkpoint = page.messages[page.messages.len - 1].compaction;
    try testing.expectEqual(@as(?u64, 3), checkpoint.first_kept_id);
    try testing.expectEqual(proto.enums.CompactionReason.manual, checkpoint.reason);
    try testing.expect(std.mem.indexOf(u8, checkpoint.summary, "Hello from the yuke mock provider.") != null);
    try testing.expect(checkpoint.tokens_after < checkpoint.tokens_before);
    // The run left no open marker, so a restart repairs nothing.
    const snapshot = (try database.session.snapshot(&f.db, a, TaskFixture.sid)).?;
    try testing.expectEqual(@as(?u64, null), snapshot.open_run_id);

    // The next request reads the checkpoint first, then the tail the cut kept.
    const projected = try context.project(a, &f.db, TaskFixture.sid, .{ .input_ceiling = 400_000 });
    try testing.expectEqual(@as(usize, 3), projected.messages.len);
    try testing.expectEqual(@as(u64, 5), projected.messages[0].compaction.id);
    try testing.expectEqual(@as(u64, 3), projected.messages[1].id());
    try testing.expectEqual(@as(u64, 4), projected.messages[2].id());
}

test "a history with no earlier turn skips instead of a model call" {
    var f: TaskFixture = undefined;
    try f.init();
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try seedMessage(&f.db, a, TaskFixture.sid, 1, .user, 300);
    try seedMessage(&f.db, a, TaskFixture.sid, 2, .assistant, 70_000);

    const outcome = try f.run(.auto);
    try testing.expectEqual(proto.enums.CompactSkipReason.too_few_messages, outcome.skipped.reason);
    // A skip commits no message, so the transcript still holds the two seeded ones.
    const page = try database.message.historyPage(&f.db, a, TaskFixture.sid, 0, 10);
    try testing.expectEqual(@as(usize, 2), page.messages.len);
}

test "a cancel that landed before the summary leaves the transcript alone" {
    var f: TaskFixture = undefined;
    try f.init();
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try seedMessage(&f.db, a, TaskFixture.sid, 1, .user, 300);
    try seedMessage(&f.db, a, TaskFixture.sid, 2, .assistant, 300);
    try seedMessage(&f.db, a, TaskFixture.sid, 3, .user, 300);
    try seedMessage(&f.db, a, TaskFixture.sid, 4, .assistant, 70_000);

    const slot = try begin(&f.engine, f.session, .manual, null);
    slot.phase = .running;
    slot.cancel.request(f.resources.runtime.io());
    var handle = try f.resources.runtime.spawn(runTask, .{ &f.engine, slot });
    handle.join();
    const outcome = try f.lastOutcome();
    try testing.expect(outcome == .canceled);
    const page = try database.message.historyPage(&f.db, a, TaskFixture.sid, 0, 10);
    try testing.expectEqual(@as(usize, 4), page.messages.len);
}

const commands = @import("commands.zig");

test "a compaction on an idle session starts at once and answers its run id" {
    var f: TaskFixture = undefined;
    try f.init();
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try seedMessage(&f.db, a, TaskFixture.sid, 1, .user, 300);
    try seedMessage(&f.db, a, TaskFixture.sid, 2, .assistant, 300);
    try seedMessage(&f.db, a, TaskFixture.sid, 3, .user, 300);
    try seedMessage(&f.db, a, TaskFixture.sid, 4, .assistant, 70_000);

    var gate: ?turn.Launch = null;
    const answer = try commands.sessionCompact(&f.engine, a, .{ .session_id = .bytes(TaskFixture.sid) }, &gate);
    try testing.expectEqual(proto.enums.CompactStatus.started, answer.status);
    const slot = gate.?.slot;
    try testing.expectEqual(answer.run_id, slot.runId());
    gate = null; // the test drives the task instead of the launch gate
    slot.phase = .running;
    var handle = try f.resources.runtime.spawn(runTask, .{ &f.engine, slot });
    handle.join();

    const outcome = try f.lastOutcome();
    try testing.expectEqual(@as(u64, 5), outcome.compacted.message_id);
}

test "a compaction under a run waits, shows in the activity, and a cancel drops it" {
    var f: TaskFixture = undefined;
    try f.init();
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try seedMessage(&f.db, a, TaskFixture.sid, 1, .user, 300);

    // One run holds the session, so the next request waits behind it.
    _ = try begin(&f.engine, f.session, .manual, null);
    var gate: ?turn.Launch = null;
    const held = try commands.sessionCompact(&f.engine, a, .{ .session_id = .bytes(TaskFixture.sid) }, &gate);
    try testing.expectEqual(proto.enums.CompactStatus.queued, held.status);
    try testing.expect(gate == null);
    try testing.expectEqual(@as(?u64, held.run_id), (try session_events.residentActivity(&f.engine, a, f.session)).pending_compaction);

    // A second request answers the compaction the session already holds.
    const again = try commands.sessionCompact(&f.engine, a, .{ .session_id = .bytes(TaskFixture.sid) }, &gate);
    try testing.expectEqual(held.run_id, again.run_id);
    try testing.expectEqual(proto.enums.CompactStatus.queued, again.status);

    const canceled = try commands.sessionCancelRun(&f.engine, a, .{ .session_id = .bytes(TaskFixture.sid) });
    try testing.expectEqual(@as(?u64, held.run_id), canceled.cleared_compaction);
    try testing.expect(f.session.pending_compaction == null);
    try testing.expectEqual(@as(?u64, null), (try session_events.residentActivity(&f.engine, a, f.session)).pending_compaction);
}

test "the session starts the compaction it held once its run ends" {
    var f: TaskFixture = undefined;
    try f.init();
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try seedMessage(&f.db, a, TaskFixture.sid, 1, .user, 300);
    try seedMessage(&f.db, a, TaskFixture.sid, 2, .assistant, 300);
    try seedMessage(&f.db, a, TaskFixture.sid, 3, .user, 300);
    try seedMessage(&f.db, a, TaskFixture.sid, 4, .assistant, 70_000);

    const run_id = blk: {
        var tx = try f.db.begin();
        defer tx.deinit();
        const id = try database.event.allocRunId(&f.db, a, TaskFixture.sid);
        try tx.commit();
        break :blk id;
    };
    f.session.pending_compaction = .{ .run_id = run_id, .reason = .auto };
    try testing.expect(startPending(&f.engine, f.session));
    try testing.expect(f.session.pending_compaction == null);
    // The start is durable before the task runs, so a stop still leaves a repairable record.
    const row = (try f.db.conn.row("SELECT count(*) FROM events WHERE name = 'run.started'", .{})).?;
    defer row.deinit();
    try testing.expectEqual(@as(i64, 1), row.int(0));
}

const ai = @import("ai");

/// Capture model requests and return one deterministic response per request.
const CaptureTransport = struct {
    requests: std.ArrayList([]const u8) = .empty,
    replies: []const []const u8,

    fn deinit(self: *CaptureTransport) void {
        for (self.requests.items) |body| testing.allocator.free(body);
        self.requests.deinit(testing.allocator);
    }

    fn transport(self: *CaptureTransport) ai.transport.Transport {
        return .{ .ctx = self, .vtable = &.{ .open = open } };
    }

    fn open(ctx: *anyopaque, arena: std.mem.Allocator, request: ai.transport.Request, _: *ai.transport.AttemptInfo) !ai.transport.ResponseBody {
        const self: *CaptureTransport = @ptrCast(@alignCast(ctx));
        const index = self.requests.items.len;
        const body = try testing.allocator.dupe(u8, request.body);
        self.requests.append(testing.allocator, body) catch |err| {
            testing.allocator.free(body);
            return err;
        };
        if (index >= self.replies.len) return error.UnexpectedRequest;
        const reader = try arena.create(ai.transport.ReplayReader);
        reader.* = .{ .bytes = self.replies[index] };
        return reader.body();
    }
};

fn sendAndWait(f: *TaskFixture, arena: std.mem.Allocator, text: []const u8) !void {
    var gate: ?turn.Launch = null;
    _ = try commands.sessionSendInputForRpc(&f.engine, arena, .{
        .session_id = .bytes(TaskFixture.sid),
        .input = .{ .content = .{ .content = &.{.{ .text = .{ .text = text } }} } },
    }, &gate, null);
    turn.Launch.release(&gate, &f.engine);
    try f.engine.turn_tasks.await(f.engine.deps.io);
}

test "automatic compaction preserves the exact tail and the next assistant id" {
    var f: TaskFixture = undefined;
    try f.init();
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    f.models[0].limits.context_window = 20_000;
    try seedMessage(&f.db, a, TaskFixture.sid, 1, .user, 300);
    try seedMessage(&f.db, a, TaskFixture.sid, 2, .assistant, 30_000);
    try seedMessage(&f.db, a, TaskFixture.sid, 3, .user, 300);
    try seedMessage(&f.db, a, TaskFixture.sid, 4, .assistant, 7000);
    var capture: CaptureTransport = .{ .replies = &.{ ai.transport.canned_reply, ai.transport.canned_reply } };
    defer capture.deinit();
    f.engine.deps.route_transport = capture.transport();
    try sendAndWait(&f, a, "keep the exact tail");
    try testing.expectEqual(@as(usize, 2), capture.requests.items.len);
    try testing.expect(std.mem.indexOf(u8, capture.requests.items[0], "context checkpoint") != null);
    try testing.expect(std.mem.indexOf(u8, capture.requests.items[1], "context_summary") != null);
    try testing.expect(std.mem.indexOf(u8, capture.requests.items[1], "keep the exact tail") != null);
    const page = try database.message.historyPage(&f.db, a, TaskFixture.sid, 0, 20);
    try testing.expectEqual(@as(usize, 7), page.messages.len);
    try testing.expectEqual(@as(u64, 6), page.messages[5].compaction.id);
    try testing.expectEqual(@as(?u64, 3), page.messages[5].compaction.first_kept_id);
    try testing.expectEqual(@as(u64, 7), page.messages[6].assistant.id);
    try testing.expectEqual(page.messages[5].compaction.run_id, page.messages[6].assistant.run_id);
    try testing.expectEqual(@as(?u64, null), (try database.session.snapshot(&f.db, a, TaskFixture.sid)).?.open_run_id);
    const projected = try context.project(a, &f.db, TaskFixture.sid, .{ .input_ceiling = 11_000 });
    try testing.expectEqual(@as(usize, 5), projected.messages.len);
    try testing.expectEqualSlices(u8, page.messages[3].assistant.content[0].text.text, projected.messages[2].assistant.content[0].text.text);
}

/// Seed a history large enough that one compaction reaches the model instead of skipping.
fn seedCompactableHistory(db: *database.Database, arena: std.mem.Allocator) !void {
    try seedMessage(db, arena, TaskFixture.sid, 1, .user, 300);
    try seedMessage(db, arena, TaskFixture.sid, 2, .assistant, 300);
    try seedMessage(db, arena, TaskFixture.sid, 3, .user, 300);
    try seedMessage(db, arena, TaskFixture.sid, 4, .assistant, 70_000);
}

test "the summary call repeats the prefix of the turn and refuses a tool" {
    var f: TaskFixture = undefined;
    try f.init();
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try seedCompactableHistory(&f.db, a);
    // A turn declares tools, so the summary call declares the same ones.
    const Tools = struct {
        fn decls(_: *anyopaque, tool_arena: std.mem.Allocator, _: @import("toolset.zig").Selection) error{OutOfMemory}![]const ai.ir.Tool {
            return proto.dupe(tool_arena, @as([]const ai.ir.Tool, &.{.{
                .name = "read",
                .description = "Read a file.",
                .input_schema = "{\"type\":\"object\"}",
            }}));
        }
    };
    var tool_ctx: u8 = 0;
    f.engine.installTools(.{ .ctx = &tool_ctx, .getDecls = Tools.decls });
    var capture: CaptureTransport = .{ .replies = &.{ai.transport.canned_reply} };
    defer capture.deinit();
    f.engine.deps.route_transport = capture.transport();

    _ = try f.run(.manual);
    try testing.expectEqual(@as(usize, 1), capture.requests.items.len);
    const body = capture.requests.items[0];
    // JSON escapes the line breaks of the instruction, so the test reads a single line.
    try testing.expect(std.mem.indexOf(u8, body, "You are a context summarization assistant") != null);
    // The tools of the turn ride the call, or the prefix would differ from the cached prefix.
    try testing.expect(std.mem.indexOf(u8, body, "\"name\":\"read\"") != null);
    // The old shape wrapped the history in one text blob. The new shape sends the real message blocks.
    try testing.expect(std.mem.indexOf(u8, body, "<conversation>") == null);
    // A summary answers in text, so the call refuses every tool.
    try testing.expect(std.mem.indexOf(u8, body, "\"type\":\"none\"") != null);
}

test "the summary call reasons at the session level" {
    var f: TaskFixture = undefined;
    try f.initWith("high");
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    f.models[0].reasoning_levels = &.{.{ .named = "high" }};
    try seedCompactableHistory(&f.db, a);
    var capture: CaptureTransport = .{ .replies = &.{ai.transport.canned_reply} };
    defer capture.deinit();
    f.engine.deps.route_transport = capture.transport();

    _ = try f.run(.manual);
    try testing.expectEqual(@as(usize, 1), capture.requests.items.len);
    // The session asks for one effort, so the summary call asks the model for the same one.
    try testing.expect(std.mem.indexOf(u8, capture.requests.items[0], "\"effort\":\"high\"") != null);
}

test "a budget control never rides the summary call, because it would spend the answer ceiling" {
    var f: TaskFixture = undefined;
    try f.initWith("high");
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    f.models[0].reasoning_levels = &.{.{ .named = "high" }};
    // This ceiling sits under the summary output limit, so a budget would take most of the answer.
    f.models[0].dialect.reasoning_budget = .{ .range = .{ .max = 2000 } };
    try seedCompactableHistory(&f.db, a);
    var capture: CaptureTransport = .{ .replies = &.{ai.transport.canned_reply} };
    defer capture.deinit();
    f.engine.deps.route_transport = capture.transport();

    _ = try f.run(.manual);
    try testing.expectEqual(@as(usize, 1), capture.requests.items.len);
    try testing.expect(std.mem.indexOf(u8, capture.requests.items[0], "budget_tokens") == null);
}

test "an incomplete or empty summary leaves the checkpoint unchanged" {
    for ([_][]const u8{ "max_tokens", "refusal", "end_turn" }) |stop| {
        var f: TaskFixture = undefined;
        try f.init();
        defer f.deinit();
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        try seedMessage(&f.db, a, TaskFixture.sid, 1, .user, 300);
        try seedMessage(&f.db, a, TaskFixture.sid, 2, .assistant, 300);
        try seedMessage(&f.db, a, TaskFixture.sid, 3, .user, 300);
        try seedMessage(&f.db, a, TaskFixture.sid, 4, .assistant, 70_000);
        _ = try f.run(.manual);
        f.session = try f.engine.activate(.bytes(TaskFixture.sid));
        try seedMessage(&f.db, a, TaskFixture.sid, 6, .user, 300);
        try seedMessage(&f.db, a, TaskFixture.sid, 7, .assistant, 70_000);
        const changed = try std.mem.replaceOwned(u8, a, ai.transport.canned_reply, "end_turn", stop);
        f.resources.transport.bytes = if (std.mem.eql(u8, stop, "end_turn"))
            try std.mem.replaceOwned(u8, a, changed, "Hello from the yuke mock provider.", "   ")
        else
            changed;
        const outcome = try f.run(.manual);
        try testing.expect(outcome == .failed);
        const head = (try context.readHead(a, &f.db, TaskFixture.sid)).?;
        try testing.expectEqual(@as(u64, 5), head.id);
        const page = try database.message.historyPage(&f.db, a, TaskFixture.sid, 0, 20);
        try testing.expectEqual(@as(usize, 7), page.messages.len);
    }
}

test "oversized summary sources and tails fail before a model request" {
    for ([_]bool{ false, true }) |large_tail| {
        var f: TaskFixture = undefined;
        try f.init();
        defer f.deinit();
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        f.models[0].limits.context_window = 20_000;
        try seedMessage(&f.db, a, TaskFixture.sid, 1, .user, 300);
        try seedMessage(&f.db, a, TaskFixture.sid, 2, .assistant, if (large_tail) 300 else 70_000);
        try seedMessage(&f.db, a, TaskFixture.sid, 3, .user, 300);
        try seedMessage(&f.db, a, TaskFixture.sid, 4, .assistant, if (large_tail) 70_000 else 7000);
        var capture: CaptureTransport = .{ .replies = &.{} };
        defer capture.deinit();
        f.engine.deps.route_transport = capture.transport();
        const outcome = try f.run(.manual);
        try testing.expect(outcome == .failed);
        try testing.expectEqual(proto.enums.RunErrorCode.context_overflow, outcome.failed.code);
        try testing.expectEqual(@as(usize, 0), capture.requests.items.len);
        try testing.expectEqual(@as(?context.Head, null), try context.readHead(a, &f.db, TaskFixture.sid));
    }
}

test "a tool round can compact and resume within the same run" {
    var f: TaskFixture = undefined;
    try f.init();
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    f.models[0].limits.context_window = 20_000;
    try seedMessage(&f.db, a, TaskFixture.sid, 1, .user, 300);
    try seedMessage(&f.db, a, TaskFixture.sid, 2, .assistant, 24_000);
    const toolset = @import("toolset.zig");
    const Tool = struct {
        fn run(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: []const u8, _: toolset.Context) toolset.Outcome {
            return .{ .output = "EXACT_TOOL_OUTPUT" ** 625, .is_error = false };
        }
    };
    f.engine.installTools(.{ .run = Tool.run });
    const tool_reply =
        "data: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":0}}}\n\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"unknown\"}}\n\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{}\"}}\n\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
        "data: {\"type\":\"message_stop\"}\n\n";
    var capture: CaptureTransport = .{ .replies = &.{ tool_reply, ai.transport.canned_reply, ai.transport.canned_reply } };
    defer capture.deinit();
    f.engine.deps.route_transport = capture.transport();
    try sendAndWait(&f, a, "continue after the tool");
    try testing.expectEqual(@as(usize, 3), capture.requests.items.len);
    try testing.expect(std.mem.indexOf(u8, capture.requests.items[0], "context_summary") == null);
    try testing.expect(std.mem.indexOf(u8, capture.requests.items[1], "context checkpoint") != null);
    try testing.expect(std.mem.indexOf(u8, capture.requests.items[2], "EXACT_TOOL_OUTPUT" ** 625) != null);
    const page = try database.message.historyPage(&f.db, a, TaskFixture.sid, 0, 20);
    try testing.expectEqual(@as(usize, 6), page.messages.len);
    try testing.expectEqual(@as(u64, 4), page.messages[3].assistant.id);
    try testing.expectEqual(@as(u64, 5), page.messages[4].compaction.id);
    try testing.expectEqual(@as(?u64, 3), page.messages[4].compaction.first_kept_id);
    try testing.expectEqual(@as(u64, 6), page.messages[5].assistant.id);
    try testing.expectEqual(page.messages[3].assistant.run_id, page.messages[5].assistant.run_id);
    try testing.expectEqual(@as(?u64, null), (try database.session.snapshot(&f.db, a, TaskFixture.sid)).?.open_run_id);
}

test "a summary that grows the context does not replace the checkpoint" {
    var f: TaskFixture = undefined;
    try f.init();
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try seedMessage(&f.db, a, TaskFixture.sid, 1, .user, 300);
    try seedMessage(&f.db, a, TaskFixture.sid, 2, .assistant, 300);
    try seedMessage(&f.db, a, TaskFixture.sid, 3, .user, 300);
    try seedMessage(&f.db, a, TaskFixture.sid, 4, .assistant, 70_000);
    f.resources.transport.bytes = try std.mem.replaceOwned(u8, a, ai.transport.canned_reply, "Hello from the yuke mock provider.", "x" ** 6000);
    const outcome = try f.run(.manual);
    try testing.expect(outcome == .failed);
    try testing.expectEqual(proto.enums.RunErrorCode.context_overflow, outcome.failed.code);
    try testing.expectEqual(@as(?context.Head, null), try context.readHead(a, &f.db, TaskFixture.sid));
}

test "a cancel interrupts a blocked summary and leaves the history intact" {
    const Blocked = struct {
        io: std.Io,
        engine: *Engine,
        entered: std.Io.Event = .unset,
        parked: std.Io.Event = .unset,
        timed_out: bool = false,
        closed: bool = false,

        fn open(ctx: *anyopaque, _: std.mem.Allocator, _: ai.transport.Request, _: *ai.transport.AttemptInfo) !ai.transport.ResponseBody {
            return .{ .ctx = ctx, .vtable = &.{ .peek = peek, .toss = toss, .deinit = close } };
        }

        fn peek(ctx: *anyopaque) anyerror![]const u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.entered.set(self.io);
            self.parked.waitTimeout(self.io, .{ .duration = .{ .raw = .fromSeconds(1), .clock = .awake } }) catch |err| {
                if (err == error.Timeout) self.timed_out = true;
                return err;
            };
            return "";
        }

        fn toss(_: *anyopaque, _: usize) void {}

        fn close(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.closed = true;
        }

        fn cancel(self: *@This()) !void {
            try self.entered.wait(self.io);
            self.engine.sessions.get(.bytes(TaskFixture.sid)).?.active_run.?.cancel.request(self.io);
        }
    };
    var f: TaskFixture = undefined;
    try f.init();
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try seedMessage(&f.db, a, TaskFixture.sid, 1, .user, 300);
    try seedMessage(&f.db, a, TaskFixture.sid, 2, .assistant, 300);
    try seedMessage(&f.db, a, TaskFixture.sid, 3, .user, 300);
    try seedMessage(&f.db, a, TaskFixture.sid, 4, .assistant, 70_000);
    var blocked: Blocked = .{ .io = f.engine.deps.io, .engine = &f.engine };
    f.engine.deps.route_transport = .{ .ctx = &blocked, .vtable = &.{ .open = Blocked.open } };
    var canceller = try blocked.io.concurrent(Blocked.cancel, .{&blocked});
    defer canceller.cancel(blocked.io) catch {};
    try testing.expect(try f.run(.manual) == .canceled);
    try testing.expect(blocked.closed);
    try testing.expect(!blocked.timed_out);
    try testing.expectEqual(@as(?context.Head, null), try context.readHead(a, &f.db, TaskFixture.sid));
    try testing.expectEqual(@as(usize, 4), (try database.message.historyPage(&f.db, a, TaskFixture.sid, 0, 10)).messages.len);
}

test "repeated compaction merges the prior summary and charges only the active context" {
    var f: TaskFixture = undefined;
    try f.init();
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try seedMessage(&f.db, a, TaskFixture.sid, 1, .user, 300);
    try seedMessage(&f.db, a, TaskFixture.sid, 2, .assistant, 300);
    try seedMessage(&f.db, a, TaskFixture.sid, 3, .user, 300);
    try seedMessage(&f.db, a, TaskFixture.sid, 4, .assistant, 70_000);
    var capture: CaptureTransport = .{ .replies = &.{ ai.transport.canned_reply, ai.transport.canned_reply } };
    defer capture.deinit();
    f.engine.deps.route_transport = capture.transport();
    try testing.expect(try f.run(.manual) == .compacted);
    f.session = try f.engine.activate(.bytes(TaskFixture.sid));
    try seedMessage(&f.db, a, TaskFixture.sid, 6, .user, 300);
    try seedMessage(&f.db, a, TaskFixture.sid, 7, .assistant, 70_000);
    const before = try context.estimate(a, &f.db, TaskFixture.sid);
    try testing.expect(try f.run(.manual) == .compacted);
    const head = (try context.readHead(a, &f.db, TaskFixture.sid)).?;
    try testing.expectEqual(@as(u64, 8), head.id);
    try testing.expectEqual(@as(u64, 6), head.from_id);
    try testing.expectEqual(before, head.message.compaction.tokens_before);
    try testing.expectEqual(try context.estimate(a, &f.db, TaskFixture.sid), head.message.compaction.tokens_after);
    try testing.expect(std.mem.indexOf(u8, capture.requests.items[1], "previous-summary") != null);
    try testing.expect(std.mem.indexOf(u8, capture.requests.items[1], "Hello from the yuke mock provider.") != null);
    const projected = try context.project(a, &f.db, TaskFixture.sid, .{ .input_ceiling = 100_000 });
    try testing.expectEqual(@as(usize, 3), projected.messages.len);
    try testing.expectEqual(@as(u64, 6), projected.messages[1].id());
    try testing.expectEqual(@as(u64, 7), projected.messages[2].id());
}

test "an oversized single turn fails without a summary request or a context trim" {
    var f: TaskFixture = undefined;
    try f.init();
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    f.models[0].limits.context_window = 20_000;
    var capture: CaptureTransport = .{ .replies = &.{} };
    defer capture.deinit();
    f.engine.deps.route_transport = capture.transport();
    try sendAndWait(&f, a, "x" ** 40_000);
    try testing.expectEqual(@as(usize, 0), capture.requests.items.len);
    const page = try database.message.historyPage(&f.db, a, TaskFixture.sid, 0, 10);
    try testing.expectEqual(@as(usize, 1), page.messages.len);
    try testing.expectEqualStrings("x" ** 40_000, page.messages[0].user.content[0].text.text);
    const outcome = (try database.run.latestOutcome(&f.db, a, TaskFixture.sid)).?;
    try testing.expectEqual(proto.enums.RunErrorCode.context_overflow, outcome.failed.code);
}

test "a smaller summary that still exceeds the request budget does not commit" {
    var f: TaskFixture = undefined;
    try f.init();
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    f.models[0].limits = .{ .context_window = 20_000, .max_output_tokens = 16_000 };
    try seedMessage(&f.db, a, TaskFixture.sid, 1, .user, 300);
    try seedMessage(&f.db, a, TaskFixture.sid, 2, .assistant, 30_000);
    try seedMessage(&f.db, a, TaskFixture.sid, 3, .user, 300);
    try seedMessage(&f.db, a, TaskFixture.sid, 4, .assistant, 7000);
    const reply = try std.mem.replaceOwned(u8, a, ai.transport.canned_reply, "Hello from the yuke mock provider.", "x" ** 1800);
    var capture: CaptureTransport = .{ .replies = &.{reply} };
    defer capture.deinit();
    f.engine.deps.route_transport = capture.transport();
    const outcome = try f.run(.manual);
    try testing.expect(outcome == .failed);
    try testing.expectEqual(@as(usize, 1), capture.requests.items.len);
    try testing.expectEqual(proto.enums.RunErrorCode.context_overflow, outcome.failed.code);
    try testing.expectEqual(@as(?context.Head, null), try context.readHead(a, &f.db, TaskFixture.sid));
}
