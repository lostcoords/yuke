//! Summarize the history below a boundary into one message. The tail after the boundary stays exact.

const std = @import("std");
const proto = @import("proto");
const database = @import("../store/store.zig");
const context = @import("context.zig");
const request_config = @import("request_config.zig");
const round_request = @import("request.zig");

/// How much recent history one compaction keeps, in estimated tokens.
pub const default_keep_recent_tokens: u64 = 20_000;

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
        var row = owned;
        defer row.deinit();
        if (std.mem.eql(u8, row.value.role, "compaction")) continue;
        const tokens = context.messageTokens(row.value.bytes, row.value.images);
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
const runs = @import("run.zig");
const model_call = @import("model_call.zig");
const session_events = @import("events.zig");
const provider = @import("../provider/provider.zig");

/// The output one summary may take. A checkpoint states the work, not the conversation.
const summary_output_tokens: u32 = 4096;

/// Run one compaction. The engine task group owns this task; the session owns `slot` until cleanup.
pub fn execute(engine: *Engine, slot: *RunSlot) void {
    std.debug.assert(slot.phase == .running);
    std.debug.assert(slot.handle.started.kind == .compaction);
    var arena_state: std.heap.ArenaAllocator = .init(engine.deps.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var completed: ?proto.run.RunOutcome = null;
    const result = switch (slot.cancel.runChild(engine.deps.io, summarizeChild, .{ engine, arena, slot, &completed })) {
        .canceled, .aborted => @as(anyerror!void, error.Canceled),
        .returned => |result| result,
    };
    const outcome = if (completed) |outcome| outcome else if (result) |_| unreachable else |err| blk: {
        if (err == error.Canceled or slot.cancel.isRequested()) break :blk proto.run.RunOutcome{ .canceled = .{} };
        // The wire message names a class, so record the cause before the error loses it.
        std.log.warn("compaction run {d} ended: {t}", .{ slot.runId(), err });
        const detail = provider.failure.classify(err);
        break :blk proto.run.RunOutcome{ .failed = .{ .code = detail.code, .message = detail.message } };
    };
    runs.finishRunOpen(engine, arena, slot, outcome) catch |err| runs.faultSlot(engine, slot, err);
}

fn summarizeChild(engine: *Engine, arena: std.mem.Allocator, slot: *RunSlot, out: *?proto.run.RunOutcome) !void {
    defer slot.cancel.finish(engine.deps.io);
    try slot.cancel.check(engine.deps.io);
    const match = engine.deps.providers.merged.resolveModel(slot.config.model) orelse return error.UnknownModel;
    out.* = try summarize(engine, arena, slot, try round_request.snapshot(arena, engine, slot, match));
}

/// Compact an oversized context; the caller must project the new checkpoint before a request.
pub fn compactForRequest(engine: *Engine, arena: std.mem.Allocator, slot: *RunSlot, held: round_request.Snapshot) !void {
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
    const outcome = try summarize(engine, arena, slot, held);
    if (outcome != .compacted) return error.ContextHistoryTooLarge;
}

/// The instruction that trails the covered range. The turn system prompt leads the request.
const summarize_prompt = summarizer_system_prompt ++ "\n\n" ++ summarize_instructions;
const merge_prompt = summarizer_system_prompt ++ "\n\n" ++ merge_instructions;

/// Summarize the covered range with the request snapshot of the turn, then commit the checkpoint.
fn summarize(engine: *Engine, arena: std.mem.Allocator, slot: *RunSlot, held: round_request.Snapshot) !proto.run.RunOutcome {
    try slot.cancel.check(engine.deps.io);
    const sid = slot.sessionId().raw;
    const db = engine.deps.db;
    const window = held.model.limits.context_window orelse context.default_context_window;
    const head = try context.readHead(engine.deps.gpa, arena, db, sid);
    var cut = (try selectCut(engine.deps.gpa, db, sid, if (head) |h| h.from_id else 0, tailTarget(window))) orelse
        return .{ .skipped = .{ .reason = .too_few_messages } };
    if (head) |h| cut.tokens_before += context.summaryTokens(h.message.compaction.summary);
    if (cut.tokens_kept >= held.budget.input_ceiling) return error.TurnTooLarge;
    // `context.project` refuses a history above the budget, and a compaction runs only above it.
    const covered = try context.collect(engine.deps.gpa, arena, db, sid, head, cut.first_kept_id);
    // The summary reads no blob, so a text-only modality set turns every attachment into its note.
    const built = try provider.request_builder.build(arena, covered, .{
        .target = .{ .protocol = held.route.route.protocol, .model = slot.config.model },
        .modalities = .{ .input = &.{.text} },
    });
    if (built.len == 0) return .{ .skipped = .{ .reason = .nothing_to_summarize } };

    // The summary repeats the system prompt and the tools of the turn, so it reuses the cached prefix.
    const budget = try context.Budget.forRequest(window, summary_output_tokens, held.build.system, held.build.tools);
    // No chunked summary exists, so a range above the window fails and never covers a part.
    if (cut.tokens_before > budget.input_ceiling) return error.CompactionSourceTooLarge;

    // The instruction trails the covered range, so every block above it repeats the turn prefix.
    const blocks = try arena.alloc(ai.ir.Block, built.len + 1);
    @memcpy(blocks[0..built.len], built);
    blocks[built.len] = .{ .role = .user, .value = .{ .text = if (head != null) merge_prompt else summarize_prompt } };

    const session_hex = std.fmt.bytesToHex(slot.sessionId().raw, .lower);
    const answer = try model_call.generateWith(engine, arena, &slot.cancel, held.route, &held.model, .{
        .system = held.build.system,
        .blocks = blocks,
        .tools = held.build.tools,
        .max_output_tokens = summary_output_tokens,
        .reasoning = slot.config.reasoning,
        .session_id = &session_hex,
    });
    if (answer.finish_reason != .stop) return error.IncompleteSummary;
    if (std.mem.trim(u8, answer.text, " \t\r\n").len == 0) return error.EmptySummary;
    const after = cut.tokens_kept + context.summaryTokens(answer.text);
    if (after > held.budget.input_ceiling or after >= cut.tokens_before) return error.CompactionDidNotFit;
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
    const stored = try database.message.appendCommittedMessage(engine.deps.db, arena, session_id.raw, engine.newId(), now, message);
    try tx.commit();

    session_events.emitCommitted(engine, rt, stored);
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
    try Resources.seedSession(&db, sid, .{ .model = "mock", .title = "t" });

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
    try Resources.seedSession(&db, sid, .{ .model = "mock", .title = "t" });
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
    try Resources.seedSession(&db, sid, .{ .model = "mock", .title = "t" });
    try seedMessage(&db, arena.allocator(), sid, 1, .user, 300);
    try seedMessage(&db, arena.allocator(), sid, 2, .assistant, 30_000);

    // The target is inside the only turn, so a cut would summarize nothing.
    try testing.expectEqual(@as(?Cut, null), try selectCut(testing.allocator, &db, sid, 0, 100));
    // A history under the target needs no compaction either.
    try testing.expectEqual(@as(?Cut, null), try selectCut(testing.allocator, &db, sid, 0, 1_000_000));
}

test "the estimate charges each image a fixed cost above its payload bytes" {
    var db = try database.Database.openTest();
    defer db.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sid = [_]u8{10} ** 16;
    try Resources.seedSession(&db, sid, .{ .model = "mock", .title = "t" });
    try seedMessage(&db, a, sid, 1, .user, 300);
    const before = try context.estimate(testing.allocator, a, &db, sid);
    const blob: proto.content.MediaBlob = .{ .hash = .bytes(@splat(0x5a)), .mime = "image/png", .bytes = 64 };
    const message: proto.message.Message = .{ .user = .{ .id = 2, .input_id = 2, .content = &.{ .{ .image = .{ .source = blob } }, .{ .image = .{ .source = blob } } }, .time = .{ .created_at_ms = 2 } } };
    try seedCommitted(&db, a, sid, 2, message);
    const payload = try std.json.Stringify.valueAlloc(a, message, .{ .emit_null_optional_fields = false });
    const after = try context.estimate(testing.allocator, a, &db, sid);
    try testing.expectEqual(before + context.tokensFor(payload.len) + 2 * context.image_tokens, after);
    // The cut charges the same rows the same way, so the covered range carries the image cost.
    try seedMessage(&db, a, sid, 3, .assistant, 300);
    try seedMessage(&db, a, sid, 4, .user, 300);
    try seedMessage(&db, a, sid, 5, .assistant, 3000);
    const cut = (try selectCut(testing.allocator, &db, sid, 0, 100)).?;
    try testing.expectEqual(@as(u64, 4), cut.first_kept_id);
    try testing.expectEqual(try context.estimate(testing.allocator, a, &db, sid), cut.tokens_before);
    try testing.expect(cut.tokens_before - cut.tokens_kept >= after);
}

/// Commit one message of about `bytes` payload bytes, so a scan test states its own sizes.
fn seedMessage(db: *database.Database, arena: std.mem.Allocator, id: [16]u8, message_id: u64, role: enum { user, assistant }, bytes: usize) !void {
    const filler = try arena.alloc(u8, bytes);
    @memset(filler, 'x');
    try seedCommitted(db, arena, id, message_id, switch (role) {
        .user => .{ .user = .{ .id = message_id, .input_id = message_id, .content = &.{.{ .text = .{ .text = filler } }}, .time = .{ .created_at_ms = message_id } } },
        .assistant => .{ .assistant = .{ .id = message_id, .run_id = 1, .config_rev = 0, .agent = "root", .time = .{ .created_at_ms = message_id }, .content = &.{.{ .text = .{ .id = 1, .text = filler } }} } },
    });
}

/// Commit one message as its own event, so a test can seed any content shape.
fn seedCommitted(db: *database.Database, arena: std.mem.Allocator, id: [16]u8, message_id: u64, message: proto.message.Message) !void {
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
        self.models = .{.{ .id = "m", .upstream_id = "m", .name = "M", .protocol = .anthropic_messages, .caps = .{ .tools = true }, .limits = .{ .context_window = 200_000 } }};
        self.rows = .{Resources.mockProvider(&self.models, .{ .base_url = "https://example.test/v1", .credential = .{ .literal = "secret" }, .authenticated = true })};
        // The test owns this snapshot, so no reload can free it under a run.
        self.engine.deps.providers.merged.rows = &self.rows;
        try Resources.seedSession(&self.db, sid, .{ .model = "mock/m", .reasoning = self.reasoning, .title = "t" });
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
        const slot = try runs.prepareCompaction(&self.engine, self.session, reason, null);
        slot.phase = .running; // the test drives the task, so it takes the transition `launch` makes
        var handle = try self.resources.runtime.spawn(runs.execute, .{ &self.engine, slot });
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
    try seedCompactableHistory(&f.db, a);

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
    const projected = try context.project(testing.allocator, a, &f.db, TaskFixture.sid, .{ .input_ceiling = 400_000 });
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
    try seedCompactableHistory(&f.db, a);

    const slot = try runs.prepareCompaction(&f.engine, f.session, .manual, null);
    slot.phase = .running;
    slot.cancel.request(f.resources.runtime.io());
    var handle = try f.resources.runtime.spawn(runs.execute, .{ &f.engine, slot });
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
    try seedCompactableHistory(&f.db, a);

    var gate: ?runs.Launch = null;
    const answer = try commands.sessionCompact(&f.engine, a, .{ .session_id = .bytes(TaskFixture.sid) }, &gate);
    try testing.expectEqual(proto.enums.CompactStatus.started, answer.status);
    const slot = gate.?.slot;
    try testing.expectEqual(answer.run_id, slot.runId());
    gate = null; // the test drives the task instead of the launch gate
    slot.phase = .running;
    var handle = try f.resources.runtime.spawn(runs.execute, .{ &f.engine, slot });
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
    _ = try runs.prepareCompaction(&f.engine, f.session, .manual, null);
    var gate: ?runs.Launch = null;
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
    try seedCompactableHistory(&f.db, a);

    const run_id = try runs.reserveCompaction(&f.engine, a, TaskFixture.sid);
    f.session.pending_compaction = .{ .run_id = run_id, .reason = .auto };
    try testing.expect(runs.startPendingCompaction(&f.engine, f.session));
    try testing.expect(f.session.pending_compaction == null);
    // The start is durable before the task runs, so a stop still leaves a repairable record.
    const row = (try f.db.conn.row("SELECT count(*) FROM events WHERE name = 'run.started'", .{})).?;
    defer row.deinit();
    try testing.expectEqual(@as(i64, 1), row.int(0));
}

const ai = @import("ai");

fn sendAndWait(f: *TaskFixture, arena: std.mem.Allocator, text: []const u8) !void {
    var gate: ?runs.Launch = null;
    _ = try commands.sessionSendInputForRpc(&f.engine, arena, .{
        .session_id = .bytes(TaskFixture.sid),
        .input = .{ .content = .{ .content = &.{.{ .text = .{ .text = text } }} } },
    }, &gate, null);
    runs.Launch.release(&gate, &f.engine);
    try f.engine.turn_tasks.await(f.engine.deps.io);
}

test "a request inside its budget reads the checkpoint and context sizes once" {
    var f: TaskFixture = undefined;
    try f.init();
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var capture: Resources.Capture = .{ .arena = a, .replies = &.{ai.testing.canned_reply} };
    f.engine.deps.route_transport = capture.transport();
    const c = @import("zqlite").c;
    const statements = .{
        f.db.queries.newest_compaction.statement.statement.stmt,
        f.db.queries.context_sizes.statement.statement.stmt,
        f.db.queries.context_messages.statement.statement.stmt,
    };
    inline for (statements) |stmt| _ = c.sqlite3_stmt_status(stmt, c.SQLITE_STMTSTATUS_RUN, 1);
    try sendAndWait(&f, a, "one context read");
    try testing.expectEqual(@as(usize, 1), capture.requests.items.len);
    try testing.expect(std.mem.indexOf(u8, capture.requests.items[0], "one context read") != null);
    inline for (statements) |stmt| try testing.expectEqual(@as(c_int, 1), c.sqlite3_stmt_status(stmt, c.SQLITE_STMTSTATUS_RUN, 0));
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
    var capture: Resources.Capture = .{ .arena = a, .replies = &.{ ai.testing.canned_reply, ai.testing.canned_reply } };
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
    const projected = try context.project(testing.allocator, a, &f.db, TaskFixture.sid, .{ .input_ceiling = 11_000 });
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
        fn decls(_: *anyopaque, tool_arena: std.mem.Allocator, _: []const []const u8) error{OutOfMemory}![]const ai.ir.Tool {
            return proto.dupe(tool_arena, @as([]const ai.ir.Tool, &.{.{
                .name = "read",
                .description = "Read a file.",
                .input_schema = "{\"type\":\"object\"}",
            }}));
        }
    };
    var tool_ctx: u8 = 0;
    f.engine.installTools(.{ .ctx = &tool_ctx, .getDecls = Tools.decls });
    var capture: Resources.Capture = .{ .arena = a, .replies = &.{ai.testing.canned_reply} };
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

test "the summary call omits an image on a vision model and never reads the store" {
    var f: TaskFixture = undefined;
    try f.init();
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    f.models[0].modalities = .{ .input = &.{ .text, .image } };
    // The ref names bytes no store holds, so a blob read would fail the run.
    const blob: proto.content.MediaBlob = .{ .hash = .bytes(@splat(0x5a)), .mime = "image/png", .bytes = 64 };
    try seedCommitted(&f.db, a, TaskFixture.sid, 1, .{ .user = .{
        .id = 1,
        .input_id = 1,
        .content = &.{ .{ .text = .{ .text = "what is this" } }, .{ .image = .{ .source = blob } } },
        .time = .{ .created_at_ms = 1 },
    } });
    try seedMessage(&f.db, a, TaskFixture.sid, 2, .assistant, 300);
    try seedMessage(&f.db, a, TaskFixture.sid, 3, .user, 300);
    try seedMessage(&f.db, a, TaskFixture.sid, 4, .assistant, 70_000);
    var capture: Resources.Capture = .{ .arena = a, .replies = &.{ai.testing.canned_reply} };
    f.engine.deps.route_transport = capture.transport();

    const outcome = try f.run(.manual);
    try testing.expectEqual(@as(u64, 5), outcome.compacted.message_id);
    try testing.expectEqual(@as(usize, 1), capture.requests.items.len);
    const body = capture.requests.items[0];
    try testing.expect(std.mem.indexOf(u8, body, "[image omitted: this model reads no images]") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"type\":\"image\"") == null);
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
    var capture: Resources.Capture = .{ .arena = a, .replies = &.{ai.testing.canned_reply} };
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
    var capture: Resources.Capture = .{ .arena = a, .replies = &.{ai.testing.canned_reply} };
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
        try seedCompactableHistory(&f.db, a);
        _ = try f.run(.manual);
        f.session = try f.engine.activate(.bytes(TaskFixture.sid));
        try seedMessage(&f.db, a, TaskFixture.sid, 6, .user, 300);
        try seedMessage(&f.db, a, TaskFixture.sid, 7, .assistant, 70_000);
        const changed = try std.mem.replaceOwned(u8, a, ai.testing.canned_reply, "end_turn", stop);
        f.resources.transport.bytes = if (std.mem.eql(u8, stop, "end_turn"))
            try std.mem.replaceOwned(u8, a, changed, "Hello from the yuke mock provider.", "   ")
        else
            changed;
        const outcome = try f.run(.manual);
        try testing.expect(outcome == .failed);
        const head = (try context.readHead(testing.allocator, a, &f.db, TaskFixture.sid)).?;
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
        var capture: Resources.Capture = .{ .arena = a, .replies = &.{} };
        f.engine.deps.route_transport = capture.transport();
        const outcome = try f.run(.manual);
        try testing.expect(outcome == .failed);
        try testing.expectEqual(proto.enums.RunErrorCode.context_overflow, outcome.failed.code);
        try testing.expectEqual(@as(usize, 0), capture.requests.items.len);
        try testing.expectEqual(@as(?context.Head, null), try context.readHead(testing.allocator, a, &f.db, TaskFixture.sid));
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
    f.engine.installTools(.{ .names = Resources.serveNames(&.{"unknown"}), .run = Tool.run });
    var capture: Resources.Capture = .{ .arena = a, .replies = &.{ Resources.tool_reply, ai.testing.canned_reply, ai.testing.canned_reply } };
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
    try seedCompactableHistory(&f.db, a);
    f.resources.transport.bytes = try std.mem.replaceOwned(u8, a, ai.testing.canned_reply, "Hello from the yuke mock provider.", "x" ** 6000);
    const outcome = try f.run(.manual);
    try testing.expect(outcome == .failed);
    try testing.expectEqual(proto.enums.RunErrorCode.context_overflow, outcome.failed.code);
    try testing.expectEqual(@as(?context.Head, null), try context.readHead(testing.allocator, a, &f.db, TaskFixture.sid));
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
    try seedCompactableHistory(&f.db, a);
    var blocked: Blocked = .{ .io = f.engine.deps.io, .engine = &f.engine };
    f.engine.deps.route_transport = .{ .ctx = &blocked, .vtable = &.{ .open = Blocked.open } };
    var canceller = try blocked.io.concurrent(Blocked.cancel, .{&blocked});
    defer canceller.cancel(blocked.io) catch {};
    try testing.expect(try f.run(.manual) == .canceled);
    try testing.expect(blocked.closed);
    try testing.expect(!blocked.timed_out);
    try testing.expectEqual(@as(?context.Head, null), try context.readHead(testing.allocator, a, &f.db, TaskFixture.sid));
    try testing.expectEqual(@as(usize, 4), (try database.message.historyPage(&f.db, a, TaskFixture.sid, 0, 10)).messages.len);
}

test "repeated compaction merges the prior summary and charges only the active context" {
    var f: TaskFixture = undefined;
    try f.init();
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try seedCompactableHistory(&f.db, a);
    var capture: Resources.Capture = .{ .arena = a, .replies = &.{ ai.testing.canned_reply, ai.testing.canned_reply } };
    f.engine.deps.route_transport = capture.transport();
    try testing.expect(try f.run(.manual) == .compacted);
    f.session = try f.engine.activate(.bytes(TaskFixture.sid));
    try seedMessage(&f.db, a, TaskFixture.sid, 6, .user, 300);
    try seedMessage(&f.db, a, TaskFixture.sid, 7, .assistant, 70_000);
    const before = try context.estimate(testing.allocator, a, &f.db, TaskFixture.sid);
    try testing.expect(try f.run(.manual) == .compacted);
    const head = (try context.readHead(testing.allocator, a, &f.db, TaskFixture.sid)).?;
    try testing.expectEqual(@as(u64, 8), head.id);
    try testing.expectEqual(@as(u64, 6), head.from_id);
    try testing.expectEqual(before, head.message.compaction.tokens_before);
    try testing.expectEqual(try context.estimate(testing.allocator, a, &f.db, TaskFixture.sid), head.message.compaction.tokens_after);
    try testing.expect(std.mem.indexOf(u8, capture.requests.items[1], "previous-summary") != null);
    try testing.expect(std.mem.indexOf(u8, capture.requests.items[1], "Hello from the yuke mock provider.") != null);
    const projected = try context.project(testing.allocator, a, &f.db, TaskFixture.sid, .{ .input_ceiling = 100_000 });
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
    var capture: Resources.Capture = .{ .arena = a, .replies = &.{} };
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
    const reply = try std.mem.replaceOwned(u8, a, ai.testing.canned_reply, "Hello from the yuke mock provider.", "x" ** 1800);
    var capture: Resources.Capture = .{ .arena = a, .replies = &.{reply} };
    f.engine.deps.route_transport = capture.transport();
    const outcome = try f.run(.manual);
    try testing.expect(outcome == .failed);
    try testing.expectEqual(@as(usize, 1), capture.requests.items.len);
    try testing.expectEqual(proto.enums.RunErrorCode.context_overflow, outcome.failed.code);
    try testing.expectEqual(@as(?context.Head, null), try context.readHead(testing.allocator, a, &f.db, TaskFixture.sid));
}
