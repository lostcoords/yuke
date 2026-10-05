//! Terminal records and child reports share one database transaction.

const std = @import("std");
const util = @import("../util.zig");
const proto = @import("proto");
const Engine = @import("Engine.zig");
const store = @import("../store/store.zig");
const events = @import("events.zig");
const runs = @import("run.zig");
const sql = @import("sql");
const toolset = @import("toolset.zig");

pub const Terminal = struct {
    done: proto.run.RunDoneData,
    report: ?proto.input.InputQueuedData = null,
    notice: ?proto.message.MessageCommittedData = null,
};

/// A tree holds at most a fixed number of report credits, whatever the concurrency limit.
pub fn reserve(engine: *Engine, arena: std.mem.Allocator, root: proto.ids.SessionId) !void {
    const row = try engine.deps.db.queries.child_report_credits.one(arena, .{ .parent_id = root.raw });
    std.debug.assert(row.value.used >= 0);
    if (row.value.used >= proto.meta.limits.max_child_report_credits) return error.ReportCapacityFull;
}

/// Append the terminal record. A child turn also reports to its parent when `report` holds.
pub fn append(engine: *Engine, arena: std.mem.Allocator, data: proto.run.RunDoneData, report: bool) !Terminal {
    std.debug.assert(sql.inTransaction(engine.deps.db.conn));
    std.debug.assert(data.run_id > 0);
    const db = engine.deps.db;
    const ended = data.timing.ended_at_ms;
    var result: Terminal = .{ .done = try store.run.appendOpenDone(db, arena, util.newId(engine.deps.io), ended, data) };
    const snapshot = (try store.session.snapshot(db, arena, data.session_id.raw)) orelse return error.UnknownSession;
    if (data.kind == .turn and report) if (snapshot.parent_id) |parent| {
        const name = snapshot.name orelse return error.CorruptDatabase;
        // A stop is a choice of the parent or the user, so the body is a fragment with no value.
        const stopped = data.outcome == .canceled;
        const output = try runOutput(engine, arena, data.session_id, data.run_id, !stopped);
        const status = switch (data.outcome) {
            .turn => "completed",
            .canceled => "stopped",
            .failed => |failed| try std.fmt.allocPrint(arena, "failed: {s}", .{failed.message}),
            .compacted, .skipped => unreachable, // `data.kind == .turn`, so the run was a turn
        };
        const text = if (stopped) "The run was stopped. Its transcript keeps the partial output." else if (output.text.len == 0) "This run has no committed text output." else output.text;
        // The terminal transaction holds the one connection, so this cut writes no file. The child transcript keeps the whole text.
        const body = try toolset.cut(.{}, arena, text) orelse text;
        result.report = try enqueue(engine, arena, .bytes(parent), ended, try endContent(arena, try childId(arena, name, data.session_id), status, body), .{ .child_report = .{
            .session_id = data.session_id,
            .run_id = data.run_id,
            .name = name,
            .outcome = data.outcome,
            .usage = .{ .rounds = output.rounds, .tool_calls = output.tool_calls, .tokens = output.tokens, .duration_ms = ended -| data.timing.started_at_ms },
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
        result.notice = try store.message.appendCommittedMessage(db, arena, data.session_id.raw, util.newId(engine.deps.io), ended, message);
    }
    return result;
}

/// Tell the parent when a stop drops queued input before a run takes it. The parent must not wait for a report that cannot arrive.
pub fn droppedInputs(engine: *Engine, arena: std.mem.Allocator, child: proto.ids.SessionId, count: usize) !?proto.input.InputQueuedData {
    std.debug.assert(sql.inTransaction(engine.deps.db.conn));
    if (count == 0) return null;
    const snapshot = (try store.session.snapshot(engine.deps.db, arena, child.raw)) orelse return error.UnknownSession;
    const parent = snapshot.parent_id orelse return null;
    const name = snapshot.name orelse return error.CorruptDatabase;
    const body = try std.fmt.allocPrint(arena, "A stop dropped {d} queued {s} before a run took {s}.", .{ count, if (count == 1) "input" else "inputs", if (count == 1) "it" else "them" });
    return try enqueue(engine, arena, .bytes(parent), util.nowMillis(engine.deps.io), try endContent(arena, try childId(arena, name, child), "stopped", body), .{ .child_report = .{
        .session_id = child,
        .name = name,
        .outcome = .{ .canceled = .{} },
        .usage = .{ .rounds = 0, .tool_calls = 0, .tokens = .zero, .duration_ms = 0 },
    } });
}

/// Tell the owner session that a background job ended. The input is protected, so no hook rewrites it and no queue clear drops it.
pub fn jobEnded(engine: *Engine, arena: std.mem.Allocator, owner: proto.ids.SessionId, ended: proto.input.JobEnded, body: []const u8) !void {
    std.debug.assert(!sql.inTransaction(engine.deps.db.conn));
    const db = engine.deps.db;
    // A removed session has no transcript, so its job end goes nowhere.
    if (!try store.session.exists(db, arena, owner.raw)) return;
    const status = if (ended.exit_code) |code| try std.fmt.allocPrint(arena, "exited {d}", .{code}) else if (ended.signal) |signal| try std.fmt.allocPrint(arena, "signal {d}", .{signal}) else "failed";
    var tx = try db.*.begin();
    defer tx.deinit();
    const report = try enqueue(engine, arena, owner, util.nowMillis(engine.deps.io), try endContent(arena, try jobId(arena, ended.job_id), status, body), .{ .job_ended = ended });
    try tx.commit();
    publishReport(engine, report, true);
}

/// The end message of a child or a job: one header line, then the body. The user view draws the body only.
fn endContent(arena: std.mem.Allocator, id: []const u8, status: []const u8, body: []const u8) ![]const proto.content.ContentPart {
    const header = try std.fmt.allocPrint(arena, "[{s} {s}. This message is not from the user.]\n", .{ id, status });
    return try arena.dupe(proto.content.ContentPart, &.{ .{ .text = .{ .text = header } }, .{ .text = .{ .text = body } } });
}

/// The child ID the parent model reads: the name and the last 8 hex digits of the session ID, which are random in a UUIDv7.
fn childId(arena: std.mem.Allocator, name: []const u8, id: proto.ids.SessionId) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}-{x}", .{ name, id.raw[12..] });
}

/// The job ID the model reads: `job-` and the four base-36 digits of the id.
fn jobId(arena: std.mem.Allocator, id: proto.ids.JobId) ![]const u8 {
    const digits = "0123456789abcdefghijklmnopqrstuvwxyz";
    var out: [8]u8 = "job-????".*;
    var rest = id;
    var i: usize = out.len;
    while (i > 4) {
        i -= 1;
        out[i] = digits[rest % 36];
        rest /= 36;
    }
    std.debug.assert(rest == 0); // a job id has four base-36 digits
    return arena.dupe(u8, &out);
}

fn enqueue(engine: *Engine, arena: std.mem.Allocator, parent: proto.ids.SessionId, now: u64, content: []const proto.content.ContentPart, source: proto.input.InputSource) !proto.input.InputQueuedData {
    const entry = try store.input.enqueue(engine.deps.db, arena, parent.raw, util.newId(engine.deps.io), now, .{ .content = content, .source = source }, now);
    return .{ .session_id = parent, .seq = entry.seq, .input = entry.input };
}

const Output = struct {
    text: []const u8 = "",
    rounds: u64 = 0,
    tool_calls: u64 = 0,
    tokens: proto.message.TokenUsage = .zero,
};

/// Sum the run usage. With `with_text`, use the newest message with text as the report body.
fn runOutput(engine: *Engine, arena: std.mem.Allocator, id: proto.ids.SessionId, run_id: proto.ids.RunId, with_text: bool) !Output {
    var rows = try engine.deps.db.queries.run_report_messages.rows(.{ .session_id = id.raw, .run_id = run_id });
    defer rows.deinit();
    var scratch: std.heap.ArenaAllocator = .init(engine.deps.gpa);
    defer scratch.deinit();
    var out: Output = .{};
    while (try rows.next(scratch.allocator())) |row| {
        defer _ = scratch.reset(.retain_capacity);
        const message = try std.json.parseFromSliceLeaky(proto.message.Message, scratch.allocator(), row.value.payload, .{});
        if (message != .assistant or message.assistant.run_id != run_id) return error.CorruptLog;
        out.rounds += 1;
        if (message.assistant.tokens) |tokens| {
            out.tokens.input += tokens.input;
            out.tokens.output += tokens.output;
            out.tokens.reasoning += tokens.reasoning;
            out.tokens.cache_read += tokens.cache_read;
            out.tokens.cache_write += tokens.cache_write;
        }
        var output: ?std.Io.Writer.Allocating = null;
        for (message.assistant.content) |part| switch (part) {
            .tool => out.tool_calls += 1,
            .text => |text| if (with_text and out.text.len == 0 and text.text.len > 0) {
                if (output == null) output = .init(scratch.allocator());
                if (output.?.written().len > 0) try output.?.writer.writeByte('\n');
                try output.?.writer.writeAll(text.text);
            },
            else => {},
        };
        if (output) |*writer| {
            if (writer.written().len > 0) out.text = try arena.dupe(u8, writer.written());
        }
    }
    return out;
}

pub fn publishReport(engine: *Engine, report: proto.input.InputQueuedData, request_wake: bool) void {
    const note: proto.rpc.Notification = .{ .method = .@"input.queued", .params = .{ .input_queued_data = report } };
    if (engine.sessions.get(report.session_id)) |resident| {
        events.emitDurable(engine, resident, note);
        events.announceActivity(engine, resident);
    } else engine.sinks.emit(note);
    if (request_wake) requestWake(engine, report.session_id);
}

fn emitErrorNotice(engine: *Engine, source: []const u8, log: bool, comptime buffer_size: usize, comptime format: []const u8, args: anytype) void {
    var buffer: [buffer_size]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    writer.print(format, args) catch {}; // A long error name cuts the notice, and `buffered` holds the written bytes.
    const text = writer.buffered();
    if (log) std.log.err("{s}", .{text});
    engine.sinks.emit(.{ .method = .notice, .params = .{ .notice = .{ .level = .@"error", .source = source, .message = text } } });
}

/// Tell subscribers that a run needs recovery after its terminal write failed.
pub fn faultNotice(engine: *Engine, session_id: proto.ids.SessionId, run_id: proto.ids.RunId, err: anyerror) void {
    emitErrorNotice(engine, "engine", false, 512, "Run save failed. Restart yuke to recover this run. Run {d}, session {x}: {t}.", .{ run_id, &session_id.raw, err });
}

/// A failed wake leaves the durable report for the next input or workspace resume.
pub fn requestWake(engine: *Engine, parent: proto.ids.SessionId) void {
    if (engine.closing) return;
    engine.beginContinuation();
    engine.turn_tasks.concurrent(engine.deps.io, wakeParent, .{ engine, parent }) catch |err| {
        defer engine.endContinuation();
        wakeFailed(engine, parent, err);
    };
}

fn wakeParent(engine: *Engine, parent: proto.ids.SessionId) void {
    defer engine.endContinuation();
    wake(engine, parent) catch |err| {
        wakeFailed(engine, parent, err);
    };
}

pub fn wake(engine: *Engine, parent: proto.ids.SessionId) !void {
    if (engine.closing) return;
    const resident = try engine.activate(parent);
    if (resident.faulted or resident.active_run != null or resident.queueDepth() == 0) return;
    try runs.resumeSession(engine, resident);
}

fn wakeFailed(engine: *Engine, parent: proto.ids.SessionId, err: anyerror) void {
    emitErrorNotice(engine, "agents", true, 256, "The child report for session {x} is saved, but the parent could not resume: {t}. Send input or resume the workspace to retry.", .{ &parent.raw, err });
}
