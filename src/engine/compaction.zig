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
        {
            var row = owned;
            defer row.deinit();
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
        // The row borrows the scratch, so it must release before the reset.
        _ = scratch.reset(.retain_capacity);
    }

    var selected = cut orelse return null;
    selected.tokens_before = total;
    return selected;
}

/// What one compaction reads from the history it covers.
pub const Source = struct {
    /// The conversation the summarizer reads, as plain text.
    text: []const u8,
    /// The summary of the newest checkpoint, which the next summary must keep.
    previous_summary: ?[]const u8,
    read_files: []const []const u8,
    modified_files: []const []const u8,
};

/// Render the covered range and its file list. The checkpoint states the summary a cut cannot reach.
pub fn readSource(arena: std.mem.Allocator, gpa: std.mem.Allocator, db: *database.Database, session_id: [16]u8, head: ?context.Head, first_kept_id: u64) !Source {
    const from_id = if (head) |h| h.from_id else 0;
    std.debug.assert(first_kept_id > from_id);
    var out: std.Io.Writer.Allocating = .init(arena);
    var files: Files = .{ .gpa = gpa };
    defer files.deinit();

    var rows = try db.queries.context_messages.rows(.{ .session_id = session_id, .first_message_id = from_id });
    defer rows.deinit();
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    while (try rows.next(scratch.allocator())) |owned| {
        {
            var row = owned;
            defer row.deinit();
            if (row.value.message_id >= first_kept_id) break;
            const message = try std.json.parseFromSliceLeaky(proto.message.Message, scratch.allocator(), row.value.payload, .{ .ignore_unknown_fields = true });
            if (message.id() != row.value.message_id) return error.CorruptLog;
            // A checkpoint is not conversation, and the head already states its summary.
            if (message != .compaction) try renderMessage(&out.writer, &files, message);
        }
        // The row and the parsed message borrow the scratch, so they release before the reset.
        _ = scratch.reset(.retain_capacity);
    }

    return .{
        .text = out.written(),
        .previous_summary = if (head) |h| h.message.compaction.summary else null,
        .read_files = try files.readOnly(arena),
        .modified_files = try files.modified(arena),
    };
}

/// The files the covered tool calls named. The engine collects them; it never asks the model.
const Files = struct {
    read: std.StringArrayHashMapUnmanaged(void) = .empty,
    written: std.StringArrayHashMapUnmanaged(void) = .empty,
    gpa: std.mem.Allocator,

    fn deinit(self: *Files) void {
        for (self.read.keys()) |key| self.gpa.free(key);
        for (self.written.keys()) |key| self.gpa.free(key);
        self.read.deinit(self.gpa);
        self.written.deinit(self.gpa);
    }

    /// Record the `path` argument of one tool call. An argument the engine cannot read is not a file.
    fn add(self: *Files, name: []const u8, arguments: []const u8) !void {
        const target: *std.StringArrayHashMapUnmanaged(void) = if (std.mem.eql(u8, name, "read"))
            &self.read
        else if (std.mem.eql(u8, name, "write") or std.mem.eql(u8, name, "edit"))
            &self.written
        else
            return;
        var parsed = std.json.parseFromSlice(std.json.Value, self.gpa, arguments, .{}) catch return;
        defer parsed.deinit();
        if (parsed.value != .object) return;
        const path = parsed.value.object.get("path") orelse return;
        if (path != .string or path.string.len == 0) return;
        if (target.contains(path.string)) return;
        const owned = try self.gpa.dupe(u8, path.string);
        errdefer self.gpa.free(owned);
        try target.put(self.gpa, owned, {});
    }

    /// A file that a later call modified is a modified file, never a read-only one.
    fn readOnly(self: *Files, arena: std.mem.Allocator) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (self.read.keys()) |key| {
            if (self.written.contains(key)) continue;
            try out.append(arena, try arena.dupe(u8, key));
        }
        return out.items;
    }

    fn modified(self: *Files, arena: std.mem.Allocator) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (self.written.keys()) |key| try out.append(arena, try arena.dupe(u8, key));
        return out.items;
    }
};

/// Write one message as summarizer text. Reasoning stays out; it is provider-private replay state.
fn renderMessage(w: *std.Io.Writer, files: *Files, message: proto.message.Message) !void {
    switch (message) {
        .user => |user| {
            for (user.content) |part| switch (part) {
                .text => |t| if (t.text.len != 0) try w.print("[User]: {s}\n\n", .{t.text}),
                // An attachment has no text, so the summary states that one arrived.
                .image, .audio, .file => try w.writeAll("[User]: (an attachment)\n\n"),
            };
        },
        .assistant => |assistant| {
            for (assistant.content) |part| switch (part) {
                .text => |t| if (t.text.len != 0) try w.print("[Assistant]: {s}\n\n", .{t.text}),
                .tool => |t| {
                    try files.add(t.name, t.arguments);
                    try w.print("[Assistant tool call]: {s}(", .{t.name});
                    try writeCapped(w, t.arguments);
                    try w.writeAll(")\n\n");
                    try renderToolResult(w, t.state);
                },
                .reasoning, .redacted_reasoning => {},
            };
        },
        .compaction => unreachable, // the caller skips a checkpoint, which is not conversation
    }
}

fn renderToolResult(w: *std.Io.Writer, state: proto.tool.ToolState) !void {
    const text: []const u8 = switch (state) {
        .completed => |c| c.output,
        .@"error" => |e| e.@"error",
        .canceled => "(canceled)",
        // A committed transcript holds only terminal tools.
        .pending, .running => return,
    };
    if (text.len == 0) return;
    try w.writeAll("[Tool result]: ");
    try writeCapped(w, text);
    try w.writeAll("\n\n");
}

/// Bound one field, so a large tool result or a whole file argument cannot fill the request.
fn writeCapped(w: *std.Io.Writer, text: []const u8) !void {
    if (text.len <= max_source_field_bytes) return w.writeAll(text);
    var end = max_source_field_bytes;
    while (end > 0 and text[end] & 0xc0 == 0x80) end -= 1;
    try w.writeAll(text[0..end]);
    try w.print("\n[... {d} more bytes]", .{text.len - end});
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

/// Build the one user block the summarizer reads. A previous summary selects the merge instructions.
pub fn buildPrompt(arena: std.mem.Allocator, source: Source) ![]const u8 {
    std.debug.assert(source.text.len != 0);
    var out: std.Io.Writer.Allocating = .init(arena);
    try out.writer.print("<conversation>\n{s}</conversation>\n\n", .{source.text});
    if (source.previous_summary) |previous| {
        try out.writer.print("<previous-summary>\n{s}\n</previous-summary>\n\n", .{previous});
    }
    try out.writer.writeAll(if (source.previous_summary == null) summarize_instructions else merge_instructions);
    return out.written();
}

/// Append the file lists the engine collected. The model states no path that no tool call named.
pub fn appendFiles(arena: std.mem.Allocator, summary: []const u8, source: Source) ![]const u8 {
    if (source.read_files.len == 0 and source.modified_files.len == 0) return summary;
    var out: std.Io.Writer.Allocating = .init(arena);
    try out.writer.writeAll(summary);
    try writeFileList(&out.writer, "read-files", source.read_files);
    try writeFileList(&out.writer, "modified-files", source.modified_files);
    return out.written();
}

fn writeFileList(w: *std.Io.Writer, tag: []const u8, paths: []const []const u8) !void {
    if (paths.len == 0) return;
    try w.print("\n\n<{s}>\n", .{tag});
    for (paths) |path| try w.print("{s}\n", .{path});
    try w.print("</{s}>", .{tag});
}

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
    // A compaction reads the summarizer prompt, never the session prompt.
    var prepared = try RunSlot.prepare(engine.deps.gpa, snapshot.model, snapshot.reasoning, "", null);
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

    const slot = prepared.bindCall(.{ .input_id = 0, .started = started }, if (snapshot.parent_id) |id| .bytes(id) else null, tree);
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

/// One fifth of the window stays free above the high water, as fx and pi both set it.
const high_water_reserve_denominator: u64 = 5;

/// Allocate one run id for a compaction the engine answers before it starts.
pub fn reserveRun(engine: *Engine, arena: std.mem.Allocator, session_id: [16]u8) !proto.ids.RunId {
    var tx = try engine.deps.db.begin();
    defer tx.deinit();
    const run_id = try database.event.allocRunId(engine.deps.db, arena, session_id);
    try tx.commit();
    return run_id;
}

/// Start a compaction above the high water. Only a turn end calls this, so one never starts the next.
pub fn startAutomatic(engine: *Engine, rt: *Session) bool {
    std.debug.assert(rt.active_run == null);
    std.debug.assert(rt.pending_compaction == null);
    var scratch: std.heap.ArenaAllocator = .init(engine.deps.gpa);
    defer scratch.deinit();
    const arena = scratch.allocator();

    const crossed = overHighWater(engine, arena, rt.id.raw) catch |err| {
        std.log.warn("cannot read the context of session {x}: {t}", .{ &rt.id.raw, err });
        return false;
    };
    if (!crossed) return false;
    const run_id = reserveRun(engine, arena, rt.id.raw) catch |err| {
        std.log.warn("cannot reserve an automatic compaction for session {x}: {t}", .{ &rt.id.raw, err });
        return false;
    };
    rt.pending_compaction = .{ .run_id = run_id, .reason = .auto };
    return startPending(engine, rt);
}

/// Report whether the context crosses the high water and still holds an earlier turn to summarize.
fn overHighWater(engine: *Engine, arena: std.mem.Allocator, session_id: [16]u8) !bool {
    const snapshot = (try database.session.snapshot(engine.deps.db, arena, session_id)) orelse return false;
    const row = engine.deps.providers.merged.resolveModel(snapshot.model) orelse return false;
    const window = row.model.limits.context_window orelse context.default_context_window;
    // The provider states what it charged, so the gauge is the truth and no byte estimate replaces it.
    const usage = try database.message.contextUsage(engine.deps.db, arena, session_id);
    const used = usage.input + usage.output + usage.cache_read + usage.cache_write;
    // A provider that reports no usage leaves the trim as the only floor.
    if (used == 0) return false;
    if (used <= window - window / high_water_reserve_denominator) return false;
    // A window with no earlier turn holds nothing to reclaim, so no run starts and no loop follows.
    const head = try context.readHead(arena, engine.deps.db, session_id);
    return (try selectCut(engine.deps.gpa, engine.deps.db, session_id, if (head) |h| h.from_id else 0, tailTarget(window))) != null;
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

    const outcome = summarize(engine, arena, slot) catch |err| blk: {
        if (err == error.Canceled or slot.cancel.requested) break :blk proto.run.RunOutcome{ .canceled = .{} };
        // The wire message names a class, so record the cause before the error loses it.
        std.log.warn("compaction run {d} ended: {t}", .{ slot.runId(), err });
        const detail = provider.failure.classify(err);
        break :blk proto.run.RunOutcome{ .failed = .{ .code = detail.code, .message = detail.message } };
    };
    turn.finishRunOpen(engine, arena, slot, outcome) catch |err| turn.faultSlot(engine, session_id, slot, err);
}

/// Summarize the covered range and commit the checkpoint. A range with no work is a skip.
fn summarize(engine: *Engine, arena: std.mem.Allocator, slot: *RunSlot) !proto.run.RunOutcome {
    const sid = slot.sessionId().raw;
    const db = engine.deps.db;
    // The registry can rebuild across a file read, so each step reads the window it needs and holds no row.
    const window = blk: {
        const row = engine.deps.providers.merged.resolveModel(slot.config.model) orelse return error.UnknownModel;
        break :blk row.model.limits.context_window orelse context.default_context_window;
    };
    const head = try context.readHead(arena, db, sid);
    const cut = (try selectCut(engine.deps.gpa, db, sid, if (head) |h| h.from_id else 0, tailTarget(window))) orelse
        return .{ .skipped = .{ .reason = .too_few_messages } };
    const source = try readSource(arena, engine.deps.gpa, db, sid, head, cut.first_kept_id);
    if (source.text.len == 0) return .{ .skipped = .{ .reason = .nothing_to_summarize } };
    const prompt = try buildPrompt(arena, source);

    // The merged registry can rebuild, so the resolve and the call stay in one step.
    const match = engine.deps.providers.merged.resolveModel(slot.config.model) orelse return error.UnknownModel;
    const budget = try context.Budget.forRequest(window, summary_output_tokens, summarizer_system_prompt, &.{});
    // Chunked summarization is not built, so a source above the window is an error, never a partial summary.
    if (context.tokensFor(prompt.len) > budget.input_ceiling) return error.CompactionSourceTooLarge;

    const answer = try model_call.generateWith(engine, arena, &slot.cancel, match, .{
        .system = summarizer_system_prompt,
        .prompt = prompt,
        .max_output_tokens = summary_output_tokens,
    });
    if (answer.text.len == 0) return error.EmptySummary;
    return commit(engine, arena, slot, cut, try appendFiles(arena, answer.text, source));
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

    var tx = try engine.deps.db.begin();
    defer tx.deinit();
    const message_id = try database.event.allocMessageId(engine.deps.db, arena, session_id.raw);
    const message: proto.message.Message = .{ .compaction = .{
        .id = message_id,
        .run_id = slot.runId(),
        .reason = slot.handle.started.reason.?,
        .summary = summary,
        .first_kept_id = cut.first_kept_id,
        .tokens_before = cut.tokens_before,
        .tokens_after = cut.tokens_kept + context.tokensFor(summary.len),
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
    try seedSessionModel(&db, sid, "mock");

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
    try seedSessionModel(&db, sid, "mock");
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
    try seedSessionModel(&db, sid, "mock");
    try seedMessage(&db, arena.allocator(), sid, 1, .user, 300);
    try seedMessage(&db, arena.allocator(), sid, 2, .assistant, 30_000);

    // The target is inside the only turn, so a cut would summarize nothing.
    try testing.expectEqual(@as(?Cut, null), try selectCut(testing.allocator, &db, sid, 0, 100));
    // A history under the target needs no compaction either.
    try testing.expectEqual(@as(?Cut, null), try selectCut(testing.allocator, &db, sid, 0, 1_000_000));
}

test "the source renders the conversation, collects its files, and caps a large field" {
    var db = try database.Database.openTest();
    defer db.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sid = [_]u8{10} ** 16;
    try seedSessionModel(&db, sid, "mock");

    const long = try a.alloc(u8, max_source_field_bytes + 64);
    @memset(long, 'x');
    const messages = [_]proto.message.Message{
        .{ .user = .{ .id = 1, .input_id = 1, .content = &.{.{ .text = .{ .text = "add a flag" } }}, .time = .{ .created_at_ms = 1 } } },
        .{ .assistant = .{ .id = 2, .run_id = 1, .config_rev = 0, .agent = "root", .time = .{ .created_at_ms = 2 }, .content = &.{
            .{ .reasoning = .{ .id = 1, .text = "PRIVATE", .signature = "s" } },
            .{ .text = .{ .id = 2, .text = "I read the file." } },
            .{ .tool = .{ .id = 3, .call_id = "c1", .name = "read", .arguments = "{\"path\":\"src/main.zig\"}", .state = .{ .completed = .{ .output = long, .duration_ms = 1 } } } },
            .{ .tool = .{ .id = 4, .call_id = "c2", .name = "edit", .arguments = "{\"path\":\"src/main.zig\"}", .state = .{ .completed = .{ .output = "ok", .duration_ms = 1 } } } },
        } } },
        .{ .user = .{ .id = 3, .input_id = 2, .content = &.{.{ .text = .{ .text = "the tail" } }}, .time = .{ .created_at_ms = 3 } } },
    };
    for (messages, 0..) |message, i| {
        var event_id = sid;
        event_id[0] = @intCast(i);
        var tx = try db.begin();
        defer tx.deinit();
        _ = try database.message.appendCommittedMessage(&db, a, sid, event_id, i + 1, message);
        try tx.commit();
    }

    const source = try readSource(a, testing.allocator, &db, sid, null, 3);
    try testing.expect(std.mem.indexOf(u8, source.text, "[User]: add a flag") != null);
    try testing.expect(std.mem.indexOf(u8, source.text, "[Assistant]: I read the file.") != null);
    try testing.expect(std.mem.indexOf(u8, source.text, "read({\"path\":\"src/main.zig\"})") != null);
    try testing.expect(std.mem.indexOf(u8, source.text, "more bytes]") != null);
    try testing.expect(std.mem.indexOf(u8, source.text, "the tail") == null);
    // Reasoning is provider-private replay state, so the summarizer never reads it.
    try testing.expect(std.mem.indexOf(u8, source.text, "PRIVATE") == null);
    try testing.expect(source.previous_summary == null);
    // One file that an edit touched is a modified file, never a read-only one.
    try testing.expectEqual(@as(usize, 0), source.read_files.len);
    try testing.expectEqual(@as(usize, 1), source.modified_files.len);
    try testing.expectEqualStrings("src/main.zig", source.modified_files[0]);
}

test "the checkpoint merges whether the cut lands above it or below it" {
    var db = try database.Database.openTest();
    defer db.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sid = [_]u8{11} ** 16;
    try seedSessionModel(&db, sid, "mock");
    const messages = [_]proto.message.Message{
        .{ .user = .{ .id = 1, .input_id = 1, .content = &.{.{ .text = .{ .text = "covered work" } }}, .time = .{ .created_at_ms = 1 } } },
        .{ .compaction = .{ .id = 2, .run_id = 1, .reason = .manual, .summary = "## Goal\nship it", .first_kept_id = 1, .tokens_before = 10, .tokens_after = 2, .time = .{ .created_at_ms = 2 } } },
        .{ .user = .{ .id = 3, .input_id = 2, .content = &.{.{ .text = .{ .text = "next task" } }}, .time = .{ .created_at_ms = 3 } } },
    };
    for (messages, 0..) |message, i| {
        var event_id = sid;
        event_id[0] = @intCast(i);
        var tx = try db.begin();
        defer tx.deinit();
        _ = try database.message.appendCommittedMessage(&db, a, sid, event_id, i + 1, message);
        try tx.commit();
    }
    const head = (try context.readHead(a, &db, sid)).?;

    // A cut above the checkpoint covers it, and a cut below it leaves it in the tail.
    for ([_]u64{ 3, 2 }) |first_kept_id| {
        const source = try readSource(a, testing.allocator, &db, sid, head, first_kept_id);
        try testing.expectEqualStrings("## Goal\nship it", source.previous_summary.?);
        try testing.expect(std.mem.indexOf(u8, source.text, "covered work") != null);
        const prompt = try buildPrompt(a, source);
        try testing.expect(std.mem.indexOf(u8, prompt, "<previous-summary>") != null);
        try testing.expect(std.mem.indexOf(u8, prompt, "Keep every fact from the previous summary.") != null);
    }

    const first = try buildPrompt(a, .{ .text = "x", .previous_summary = null, .read_files = &.{}, .modified_files = &.{} });
    try testing.expect(std.mem.indexOf(u8, first, "<previous-summary>") == null);
    try testing.expect(std.mem.indexOf(u8, first, "another assistant uses to continue") != null);
}

test "the file lists follow the summary and an empty pair adds nothing" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const empty: Source = .{ .text = "x", .previous_summary = null, .read_files = &.{}, .modified_files = &.{} };
    try testing.expectEqualStrings("summary", try appendFiles(a, "summary", empty));

    const both: Source = .{ .text = "x", .previous_summary = null, .read_files = &.{"a.zig"}, .modified_files = &.{"b.zig"} };
    const text = try appendFiles(a, "summary", both);
    try testing.expect(std.mem.indexOf(u8, text, "<read-files>\na.zig\n</read-files>") != null);
    try testing.expect(std.mem.indexOf(u8, text, "<modified-files>\nb.zig\n</modified-files>") != null);
}

fn seedSessionModel(db: *database.Database, id: [16]u8, model: []const u8) !void {
    try database.session.create(db, .{
        .id = id,
        .root = "/w",
        .origin = "root",
        .profile = "default",
        .model = model,
        .reasoning = "",
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

    const sid = [_]u8{21} ** 16;

    fn init(self: *TaskFixture) !void {
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
        try seedSessionModel(&self.db, sid, "mock/m");
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
    const projected = try context.project(a, &f.db, TaskFixture.sid, .{ .max_tokens = 100_000, .input_ceiling = 400_000 });
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

/// Commit one assistant message that states what the provider charged for the context.
fn seedUsage(db: *database.Database, arena: std.mem.Allocator, id: [16]u8, message_id: u64, bytes: usize, input: u64) !void {
    const filler = try arena.alloc(u8, bytes);
    @memset(filler, 'x');
    const message: proto.message.Message = .{ .assistant = .{
        .id = message_id,
        .run_id = 1,
        .config_rev = 0,
        .agent = "root",
        .time = .{ .created_at_ms = message_id },
        .content = &.{.{ .text = .{ .id = 1, .text = filler } }},
        .tokens = .{ .input = input, .output = 0, .reasoning = 0, .cache_read = 0, .cache_write = 0 },
    } };
    var event_id = id;
    event_id[0] = @intCast(message_id);
    var tx = try db.begin();
    defer tx.deinit();
    _ = try database.message.appendCommittedMessage(db, arena, id, event_id, message_id, message);
    try tx.commit();
}

test "a committed context over the high water starts a compaction by itself" {
    var f: TaskFixture = undefined;
    try f.init();
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try seedMessage(&f.db, a, TaskFixture.sid, 1, .user, 300);
    try seedMessage(&f.db, a, TaskFixture.sid, 2, .assistant, 300);
    try seedMessage(&f.db, a, TaskFixture.sid, 3, .user, 300);
    // The model window is 200000, so this charge crosses four fifths of it.
    try seedUsage(&f.db, a, TaskFixture.sid, 4, 70_000, 170_000);

    try testing.expect(startAutomatic(&f.engine, f.session));
    try testing.expect(f.session.pending_compaction == null); // the start consumed it
    const row = (try f.db.conn.row("SELECT count(*) FROM events WHERE name = 'run.started'", .{})).?;
    defer row.deinit();
    try testing.expectEqual(@as(i64, 1), row.int(0));
}

test "a committed context under the high water starts nothing" {
    var f: TaskFixture = undefined;
    try f.init();
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try seedMessage(&f.db, a, TaskFixture.sid, 1, .user, 300);
    try seedMessage(&f.db, a, TaskFixture.sid, 2, .assistant, 300);
    try seedMessage(&f.db, a, TaskFixture.sid, 3, .user, 300);
    try seedUsage(&f.db, a, TaskFixture.sid, 4, 70_000, 1000);

    try testing.expect(!startAutomatic(&f.engine, f.session));
    try testing.expect(f.session.pending_compaction == null);
}

test "a context with no earlier turn starts nothing, so a compaction cannot loop" {
    var f: TaskFixture = undefined;
    try f.init();
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // One turn holds the whole context, so no cut exists and no run starts.
    try seedMessage(&f.db, a, TaskFixture.sid, 1, .user, 300);
    try seedUsage(&f.db, a, TaskFixture.sid, 2, 70_000, 170_000);

    try testing.expect(!startAutomatic(&f.engine, f.session));
    const row = (try f.db.conn.row("SELECT count(*) FROM events WHERE name = 'run.started'", .{})).?;
    defer row.deinit();
    try testing.expectEqual(@as(i64, 0), row.int(0));
}

test "a provider that reports no usage leaves the trim as the only floor" {
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

    try testing.expect(!startAutomatic(&f.engine, f.session));
}
