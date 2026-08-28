//! Start a run. Commit the user inputs and write the durable run-start record in one transaction.
//! The daemon streams and commits the assistant reply later in the run task.

const std = @import("std");
const wire = @import("wire");
const database = @import("../database/database.zig");
const util = @import("../util.zig");

const Database = database.Database;
const session_store = database.session;
const message_store = database.message;
const event_store = database.event;
const input_store = database.input;
const run_store = database.run;

/// The run uses this config from its start. A mid-run change applies to the next run.
pub const Config = struct {
    model: []const u8,
    system_prompt: []const u8,
    max_rounds: ?u64 = null, // null means unlimited rounds. A finite cap ends the turn with an error.
};

/// These IDs belong to the started run. session.send_input returns run_id and input_id together.
pub const RunHandle = struct {
    input_id: wire.ids.InputId,
    started: wire.run.RunStartedData,
};

/// One assistant round. The run allocates a fresh message id per round.
pub const RoundState = struct {
    number: u64,
    message_id: wire.ids.MessageId,
    created_at_ms: u64 = 0, // The run task fills this before it commits the round.
    stop_reason: ?wire.enums.StopReason = null,
};

/// The live progress of a run across rounds. The database usage summary is the durable aggregate.
pub const RunProgress = struct {
    rounds_started: u64 = 0,
    rounds_committed: u64 = 0,
    current: ?RoundState = null,
};

/// A started run and the user messages it committed. The daemon publishes each commit before run.started.
/// The commit content borrows `arena`. The caller must publish before it frees the arena.
pub const Started = struct {
    handle: RunHandle,
    first_round: RoundState,
    user_commits: []const wire.message.MessageCommittedData,
};

/// Append the `run.started` event for a turn. Both turn paths share this record shape.
fn appendRunStarted(db: *Database, arena: std.mem.Allocator, io: std.Io, session_id: [16]u8, run_id: wire.ids.RunId, config_rev: wire.ids.ConfigRev, started_at_ms: u64) !wire.run.RunStartedData {
    return run_store.appendStarted(db, arena, util.newId(io), started_at_ms, .{
        .session_id = .bytes(session_id),
        .seq = 0,
        .run_id = run_id,
        .kind = .turn,
        .config_rev = config_rev,
        .started_at_ms = started_at_ms,
    });
}

/// Tx1 allocates the IDs and commits the user message in one transaction. The daemon runs Tx1 before it spawns the run.
/// Therefore, send_input returns the run ID at once. `input` borrows `arena`.
pub fn beginTurn(
    db: *Database,
    io: std.Io,
    arena: std.mem.Allocator,
    session_id: [16]u8,
    input: []const wire.content.ContentPart,
    config_rev: wire.ids.ConfigRev,
) !Started {
    var tx = try db.begin();
    defer tx.deinit();
    const input_id = try event_store.allocInputId(db, arena, session_id);
    const run_id = try event_store.allocRunId(db, arena, session_id);
    const user_message_id = try event_store.allocMessageId(db, arena, session_id);
    const assistant_message_id = try event_store.allocMessageId(db, arena, session_id);
    const user_now = util.nowMillis(io);
    const user_message: wire.message.Message = .{ .user = .{
        .id = user_message_id,
        .content = input,
        .input_id = input_id,
        .time = .{ .created_at_ms = user_now },
    } };
    const user_seq = try message_store.appendCommittedMessage(db, arena, session_id, util.newId(io), user_now, user_message);
    // Build the commit slice before COMMIT, so a late allocation failure cannot orphan the durable run.
    const commits = try arena.alloc(wire.message.MessageCommittedData, 1);
    commits[0] = .{ .session_id = .bytes(session_id), .seq = user_seq, .message = user_message };
    const started = try appendRunStarted(db, arena, io, session_id, run_id, config_rev, user_now);
    try tx.commit();
    return .{
        .handle = .{ .input_id = input_id, .started = started },
        .first_round = .{ .number = 1, .message_id = assistant_message_id },
        .user_commits = commits,
    };
}

/// Tx1 for a queued drain commits every durable queued input as one run.
/// The handle uses the oldest input id; `first_round` carries the run's assistant message id.
pub fn beginQueuedTurn(
    db: *Database,
    io: std.Io,
    arena: std.mem.Allocator,
    session_id: [16]u8,
    config_rev: wire.ids.ConfigRev,
) !Started {
    var tx = try db.begin();
    defer tx.deinit();

    const queued = try input_store.list(db, arena, session_id);
    if (queued.len == 0) return error.NoRow;

    const run_id = try event_store.allocRunId(db, arena, session_id);
    const started_at_ms = util.nowMillis(io);
    const first_input_id = queued[0].input.input_id;
    const commits = try arena.alloc(wire.message.MessageCommittedData, queued.len);

    for (queued, 0..) |entry, i| {
        const user_message_id = try event_store.allocMessageId(db, arena, session_id);
        const user_message: wire.message.Message = .{ .user = .{
            .id = user_message_id,
            .content = entry.input.content,
            .input_id = entry.input.input_id,
            .time = .{ .created_at_ms = entry.input.queued_at_ms },
        } };
        const seq = try message_store.appendCommittedMessage(
            db,
            arena,
            session_id,
            util.newId(io),
            started_at_ms,
            user_message,
        );
        commits[i] = .{ .session_id = .bytes(session_id), .seq = seq, .message = user_message };
        try input_store.consume(db, arena, session_id, entry.input.input_id);
    }

    const assistant_message_id = try event_store.allocMessageId(db, arena, session_id);
    const started = try appendRunStarted(db, arena, io, session_id, run_id, config_rev, started_at_ms);
    try tx.commit();
    return .{
        .handle = .{ .input_id = first_input_id, .started = started },
        .first_round = .{ .number = 1, .message_id = assistant_message_id },
        .user_commits = commits,
    };
}

const testing = std.testing;
const zio = @import("zio");
const workspace_store = database.workspace;

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
    const ws = try workspace_store.resolve(&db, a, [_]u8{7} ** 16, "/w", "w", "/w");
    try session_store.create(&db, .{
        .id = sid,
        .workspace_id = ws.id,
        .origin = "root",
        .profile = "default",
        .model = "opus",
        .reasoning = "high",
        .config_rev = 0,
        .permission = "normal",
        .title = "t",
        .created_at_ms = 100,
        .updated_at_ms = 100,
    });

    const one = [_]wire.content.ContentPart{.{ .text = .{ .text = "one" } }};
    const two = [_]wire.content.ContentPart{.{ .text = .{ .text = "two" } }};
    try db.conn.execNoArgs("BEGIN IMMEDIATE");
    _ = try input_store.enqueue(&db, a, sid, [_]u8{1} ** 16, 110, &one, 101);
    _ = try input_store.enqueue(&db, a, sid, [_]u8{2} ** 16, 120, &two, 102);
    try db.conn.execNoArgs("COMMIT");

    const started = try beginQueuedTurn(&db, rt.io(), a, sid, 7);
    const handle = started.handle;
    try testing.expectEqual(@as(u64, 1), handle.started.run_id);
    try testing.expectEqual(@as(u64, 1), handle.input_id);
    try testing.expectEqual(@as(u64, 3), started.first_round.message_id);
    // The drain returns one committed user message per input in FIFO order with contiguous sequences.
    try testing.expectEqual(@as(usize, 2), started.user_commits.len);
    try testing.expectEqual(@as(u64, 1), started.user_commits[0].message.user.id);
    try testing.expectEqual(@as(u64, 2), started.user_commits[1].message.user.id);
    try testing.expectEqual(started.user_commits[0].seq + 1, started.user_commits[1].seq);
    try testing.expect(started.user_commits[1].seq < handle.started.seq); // run.started follows the commits
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
    try testing.expectEqualStrings("two", page.messages[1].user.content[0].text.text);
    try testing.expectEqual(@as(i64, 1), try eventCount(&db, "run.started"));
    try testing.expectEqual(@as(i64, 0), try eventCount(&db, "run.done"));
    try testing.expectEqual(@as(?u64, handle.started.run_id), (try session_store.snapshot(&db, a, sid)).?.open_run_id);
}
