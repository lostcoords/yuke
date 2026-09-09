//! Terminal records and child reports share one database transaction.

const std = @import("std");
const proto = @import("proto");
const Engine = @import("Engine.zig");
const store = @import("../store/store.zig");
const events = @import("events.zig");
const turn = @import("turn.zig");

pub const max_output_bytes = 64 * 1024;

pub const Terminal = struct {
    done: proto.run.RunDoneData,
    report: ?proto.input.InputQueuedData = null,
    notice: ?proto.message.MessageCommittedData = null,
};

/// Lower limits preserve old reservations and refuse new work until space returns.
pub fn reserve(engine: *Engine, arena: std.mem.Allocator, root: proto.ids.SessionId) !void {
    const row = try engine.deps.db.queries.child_report_credits.one(arena, .{ .parent_id = root.raw });
    const limit = proto.meta.limits.max_queued_inputs + @as(u64, engine.max_concurrent_children);
    std.debug.assert(row.value.used >= 0);
    if (row.value.used >= limit) return error.ReportCapacityFull;
}

pub fn append(engine: *Engine, arena: std.mem.Allocator, data: proto.run.RunDoneData) !Terminal {
    std.debug.assert(@import("sql").inTransaction(engine.deps.db.conn));
    std.debug.assert(data.run_id > 0);
    const db = engine.deps.db;
    const ended = data.timing.ended_at_ms;
    var result: Terminal = .{ .done = try store.run.appendOpenDone(db, arena, engine.newId(), ended, data) };
    const snapshot = (try store.session.snapshot(db, arena, data.session_id.raw)) orelse return error.UnknownSession;
    if (data.kind == .turn) if (snapshot.parent_id) |parent| {
        const name = snapshot.name orelse return error.CorruptDatabase;
        const output = try runOutput(engine, arena, data.session_id, data.run_id);
        const partial = data.outcome != .turn;
        const outcome = try std.json.Stringify.valueAlloc(arena, data.outcome, .{ .emit_null_optional_fields = false });
        const partial_note = if (partial) "This run did not complete successfully. Any output is partial.\n" else "";
        const truncation_note = if (output.truncated) "The report output was truncated at 65536 bytes. Read the child history for the full output.\n" else "";
        const body = if (output.text.len == 0) "This run has no committed text output." else output.text;
        const text = try std.fmt.allocPrint(arena, "Message from {s}, run {d}. Outcome: {s}\n{s}{s}\n{s}", .{ name, data.run_id, outcome, partial_note, truncation_note, body });
        result.report = try enqueue(engine, arena, .bytes(parent), ended, text, .{ .child_report = .{
            .session_id = data.session_id,
            .run_id = data.run_id,
            .name = name,
            .outcome = data.outcome,
            .partial = partial,
            .truncated = output.truncated,
        } });
    };
    if (data.outcome == .failed and data.outcome.failed.code == .interrupted) {
        const message: proto.message.Message = .{ .user = .{
            .id = try store.event.allocMessageId(db, arena, data.session_id.raw),
            .input_id = try store.event.allocInputId(db, arena, data.session_id.raw),
            .source = .{ .engine_interruption = .{ .run_id = data.run_id, .kind = data.kind } },
            .content = &.{.{ .text = .{ .text = try std.fmt.allocPrint(arena, "The previous engine stopped before run {d} ended. Its committed output remains in the transcript. Tool calls may have produced side effects before the stop.", .{data.run_id}) } }},
            .time = .{ .created_at_ms = ended },
        } };
        const seq = try store.message.appendCommittedMessage(db, arena, data.session_id.raw, engine.newId(), ended, message);
        result.notice = .{ .session_id = data.session_id, .seq = seq, .message = message };
    }
    return result;
}

/// A canceled input consumes its reservation without a fabricated run outcome.
pub fn canceledInputs(engine: *Engine, arena: std.mem.Allocator, child: proto.ids.SessionId, input_ids: []const proto.ids.InputId) !?proto.input.InputQueuedData {
    std.debug.assert(@import("sql").inTransaction(engine.deps.db.conn));
    if (input_ids.len == 0) return null;
    const snapshot = (try store.session.snapshot(engine.deps.db, arena, child.raw)) orelse return error.UnknownSession;
    const parent = snapshot.parent_id orelse return null;
    const name = snapshot.name orelse return error.CorruptDatabase;
    const ids = try std.json.Stringify.valueAlloc(arena, input_ids, .{});
    const text = try std.fmt.allocPrint(arena, "Message from {s}: inputs {s} were canceled before they entered the transcript.", .{ name, ids });
    return try enqueue(engine, arena, .bytes(parent), engine.nowMillis(), text, .{ .child_input_canceled = .{
        .session_id = child,
        .name = name,
        .input_ids = input_ids,
    } });
}

fn enqueue(engine: *Engine, arena: std.mem.Allocator, parent: proto.ids.SessionId, now: u64, text: []const u8, source: proto.input.InputSource) !proto.input.InputQueuedData {
    const entry = try store.input.enqueue(engine.deps.db, arena, parent.raw, engine.newId(), now, .{ .content = &.{.{ .text = .{ .text = text } }}, .source = source }, now);
    return .{ .session_id = parent, .seq = entry.seq, .input = entry.input };
}

const Output = struct { text: []const u8, truncated: bool };

/// Select the newest text-bearing message from this run, never an earlier assignment.
fn runOutput(engine: *Engine, arena: std.mem.Allocator, id: proto.ids.SessionId, run_id: proto.ids.RunId) !Output {
    var rows = try engine.deps.db.queries.run_report_messages.rows(.{ .session_id = id.raw, .run_id = run_id });
    defer rows.deinit();
    var scratch: std.heap.ArenaAllocator = .init(engine.deps.gpa);
    defer scratch.deinit();
    while (try rows.next(scratch.allocator())) |row| {
        const message = try std.json.parseFromSliceLeaky(proto.message.Message, scratch.allocator(), row.value.payload, .{});
        if (message != .assistant or message.assistant.run_id != run_id) return error.CorruptLog;
        var output: std.Io.Writer.Allocating = .init(scratch.allocator());
        var truncated = false;
        for (message.assistant.content) |part| if (part == .text and part.text.text.len > 0) {
            if (output.written().len > 0 and output.written().len < max_output_bytes) try output.writer.writeByte('\n');
            const available = max_output_bytes - output.written().len;
            var len = @min(part.text.text.len, available);
            if (len < part.text.text.len) {
                truncated = true;
                while (len > 0 and part.text.text[len] & 0xc0 == 0x80) len -= 1;
            }
            try output.writer.writeAll(part.text.text[0..len]);
            if (truncated) break;
        };
        if (output.written().len > 0) return .{ .text = try arena.dupe(u8, output.written()), .truncated = truncated };
        _ = scratch.reset(.retain_capacity);
    }
    return .{ .text = "", .truncated = false };
}

pub fn publishReport(engine: *Engine, report: proto.input.InputQueuedData, request_wake: bool) void {
    const note: proto.rpc.Notification = .{ .method = .@"input.queued", .params = .{ .input_queued_data = report } };
    if (engine.sessions.get(report.session_id)) |resident| {
        events.emitDurable(engine, resident, note);
        events.announceActivity(engine, resident);
    } else engine.sinks.emit(note);
    if (request_wake) requestWake(engine, report.session_id);
}

/// Tell subscribers that a run needs recovery after its terminal write failed.
pub fn faultNotice(engine: *Engine, session_id: proto.ids.SessionId, run_id: proto.ids.RunId, err: anyerror) void {
    var buffer: [512]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "Run save failed. Restart yuke to recover this run. Run {d}, session {x}: {t}.", .{ run_id, &session_id.raw, err }) catch unreachable;
    engine.sinks.emit(.{ .method = .notice, .params = .{ .notice = .{ .level = .@"error", .source = "engine", .message = text } } });
}

/// A failed wake leaves the durable report for the next input or workspace resume.
pub fn requestWake(engine: *Engine, parent: proto.ids.SessionId) void {
    if (engine.closing) return;
    engine.turn_tasks.concurrent(engine.deps.io, wakeParent, .{ engine, parent }) catch |err| {
        wakeFailed(engine, parent, err);
    };
}

fn wakeParent(engine: *Engine, parent: proto.ids.SessionId) void {
    if (engine.closing) return;
    wake(engine, parent) catch |err| {
        wakeFailed(engine, parent, err);
    };
}

pub fn wake(engine: *Engine, parent: proto.ids.SessionId) !void {
    if (engine.closing) return;
    const resident = try engine.activate(parent);
    if (resident.faulted or resident.active_run != null or resident.queueDepth() == 0) return;
    try turn.resumeSession(engine, resident);
}

fn wakeFailed(engine: *Engine, parent: proto.ids.SessionId, err: anyerror) void {
    var buffer: [256]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "The child report for session {x} is saved, but the parent could not resume: {t}. Send input or resume the workspace to retry.", .{ &parent.raw, err }) catch unreachable;
    std.log.err("{s}", .{text});
    engine.sinks.emit(.{ .method = .notice, .params = .{ .notice = .{ .level = .@"error", .source = "agents", .message = text } } });
}
