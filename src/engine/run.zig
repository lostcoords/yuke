//! Start a run. Commit the user inputs and write the durable run-start record in one transaction.
//! The engine streams and commits the assistant reply later in the run task.

const std = @import("std");
const proto = @import("proto");
const database = @import("../store/store.zig");
const util = @import("../util.zig");
const session = @import("../session/session.zig");

const Database = database.Database;
const session_store = database.session;
const message_store = database.message;
const event_store = database.event;
const input_store = database.input;
const run_store = database.run;

pub const RunHandle = session.RunHandle;
pub const RunSlot = session.RunSlot;

/// A started run and the user messages it committed. The engine publishes each commit before run.started.
/// The commit content borrows `arena`. The caller must publish before it frees the arena.
pub const Started = struct {
    handle: RunHandle,
    user_commits: []const proto.message.MessageCommittedData,
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
pub fn beginTurn(db: *Database, io: std.Io, arena: std.mem.Allocator, session_id: [16]u8, input: @import("../session/input.zig"), config_rev: proto.ids.ConfigRev) !Started {
    var tx = try db.begin();
    defer tx.deinit();
    const input_id = try event_store.allocInputId(db, arena, session_id);
    const run_id = try event_store.allocRunId(db, arena, session_id);
    const user_message_id = try event_store.allocMessageId(db, arena, session_id);
    const user_now = util.nowMillis(io);
    const user_message: proto.message.Message = .{ .user = .{
        .id = user_message_id,
        .content = input.content,
        .input_id = input_id,
        .source = input.source,
        .skill_name = input.skill_name,
        .time = .{ .created_at_ms = user_now },
    } };
    const user_seq = try message_store.appendCommittedMessage(db, arena, session_id, util.newId(io), user_now, user_message);
    // Build the commit slice before COMMIT, so a late allocation failure cannot orphan the durable run.
    const commits = try arena.alloc(proto.message.MessageCommittedData, 1);
    commits[0] = .{ .session_id = .bytes(session_id), .seq = user_seq, .message = user_message };
    const started = try appendRunStarted(db, arena, io, session_id, run_id, config_rev, user_now);
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
    std.debug.assert(@import("sql").inTransaction(db.conn));
    const commits = try consumeQueued(db, io, arena, session_id);
    if (commits.len == 0) return error.NoRow;
    const run_id = try event_store.allocRunId(db, arena, session_id);
    const started = try appendRunStarted(db, arena, io, session_id, run_id, config_rev, util.nowMillis(io));
    return .{
        .handle = .{ .input_id = commits[0].message.user.input_id, .started = started },
        .user_commits = commits,
    };
}

/// Append pending inputs in FIFO order and remove them in the caller's transaction.
pub fn consumeQueued(db: *Database, io: std.Io, arena: std.mem.Allocator, session_id: [16]u8) ![]const proto.message.MessageCommittedData {
    std.debug.assert(@import("sql").inTransaction(db.conn));
    const queued = try input_store.list(db, arena, session_id);
    const commits = try arena.alloc(proto.message.MessageCommittedData, queued.len);
    const now = util.nowMillis(io);

    for (queued, 0..) |entry, i| {
        const user_message_id = try event_store.allocMessageId(db, arena, session_id);
        const user_message: proto.message.Message = .{ .user = .{
            .id = user_message_id,
            .content = entry.input.content,
            .source = entry.input.source,
            .skill_name = entry.input.skill_name,
            .input_id = entry.input.input_id,
            .time = .{ .created_at_ms = entry.input.queued_at_ms },
        } };
        const seq = try message_store.appendCommittedMessage(
            db,
            arena,
            session_id,
            util.newId(io),
            now,
            user_message,
        );
        commits[i] = .{ .session_id = .bytes(session_id), .seq = seq, .message = user_message };
        try input_store.consume(db, arena, session_id, entry.input.input_id);
    }

    return commits;
}

const testing = std.testing;
const zio = @import("zio");

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
    try session_store.create(&db, .{
        .id = sid,
        .root = "/w",
        .origin = "root",
        .profile = "default",
        .model = "opus",
        .reasoning = "high",
        .config_rev = 0,
        .title = "t",
        .created_at_ms = 100,
        .updated_at_ms = 100,
    });

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
    try testing.expectEqualStrings("pdf", page.messages[0].user.skill_name.?);
    try testing.expect(page.messages[1].user.skill_name == null);
    try testing.expectEqualStrings("two", page.messages[1].user.content[0].text.text);
    try testing.expectEqual(@as(i64, 1), try eventCount(&db, "run.started"));
    try testing.expectEqual(@as(i64, 0), try eventCount(&db, "run.done"));
    try testing.expectEqual(@as(?u64, handle.started.run_id), (try session_store.snapshot(&db, a, sid)).?.open_run_id);
}
