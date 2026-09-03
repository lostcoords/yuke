//! Durable run lifecycle events.

const std = @import("std");
const proto = @import("proto");
const Database = @import("store.zig").Database;
const event = @import("event.zig");
const session = @import("session.zig");

/// Append `run.started` and set its terminal obligation. Run inside the start transaction.
pub fn appendStarted(
    db: *Database,
    arena: std.mem.Allocator,
    event_id: [16]u8,
    committed_at_ms: u64,
    data: proto.run.RunStartedData,
) !proto.run.RunStartedData {
    std.debug.assert(data.seq == 0);
    var stored = data;
    stored.seq = try event.allocSeq(db, arena, data.session_id.raw);
    const payload = try std.json.Stringify.valueAlloc(arena, stored, .{ .emit_null_optional_fields = false });
    try event.appendAt(db, data.session_id.raw, stored.seq, event_id, committed_at_ms, "run.started", payload);
    try session.setOpenRun(db, arena, data.session_id.raw, data.run_id, @tagName(data.kind), data.started_at_ms);
    return stored;
}

/// Append `run.done` for an open run and clear its terminal obligation.
pub fn appendOpenDone(
    db: *Database,
    arena: std.mem.Allocator,
    event_id: [16]u8,
    committed_at_ms: u64,
    data: proto.run.RunDoneData,
) !proto.run.RunDoneData {
    std.debug.assert(data.seq == 0);
    const started_at_ms = data.timing.started_at_ms orelse return error.InvalidRunTiming;
    if (data.timing.ended_at_ms < started_at_ms) return error.InvalidRunTiming;
    var stored = data;
    stored.seq = try event.allocSeq(db, arena, data.session_id.raw);
    const payload = try std.json.Stringify.valueAlloc(arena, stored, .{ .emit_null_optional_fields = false });
    try event.appendAt(db, data.session_id.raw, stored.seq, event_id, committed_at_ms, "run.done", payload);
    try session.clearOpenRun(db, arena, data.session_id.raw, data.run_id, @tagName(data.kind), started_at_ms);
    return stored;
}

const testing = std.testing;
const zqlite = @import("zqlite");

fn seedSession(db: *Database, id: [16]u8) !void {
    try session.create(db, .{
        .id = id,
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
}

fn countEvents(db: *Database, name: []const u8) !u64 {
    const row = (try db.conn.row("SELECT count(*) FROM events WHERE name = ?1", .{name})) orelse return error.NoRow;
    defer row.deinit();
    return @intCast(row.int(0));
}

test "start and done events move the open-run triad in their transactions" {
    var db = try Database.openTest();
    defer db.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sid = [_]u8{3} ** 16;
    try seedSession(&db, sid);

    try db.conn.execNoArgs("BEGIN IMMEDIATE");
    _ = try event.allocRunId(&db, a, sid);
    const started = try appendStarted(&db, a, [_]u8{1} ** 16, 150, .{
        .session_id = .bytes(sid),
        .seq = 0,
        .run_id = 1,
        .kind = .turn,
        .config_rev = 0,
        .started_at_ms = 150,
    });
    try db.conn.execNoArgs("COMMIT");
    try testing.expectEqual(@as(u64, 1), started.seq);
    try testing.expectEqual(@as(?u64, 1), (try session.snapshot(&db, a, sid)).?.open_run_id);

    try db.conn.execNoArgs("BEGIN IMMEDIATE");
    const started_row = (try db.conn.row(
        "SELECT event_id, committed_at_ms, payload FROM events WHERE session_id = ?1 AND name = 'run.started'",
        .{zqlite.blob(&sid)},
    )) orelse return error.NoRow;
    defer started_row.deinit();
    try testing.expectEqualSlices(u8, &([_]u8{1} ** 16), started_row.blob(0));
    try testing.expectEqual(@as(i64, 150), started_row.int(1));
    const started_payload = try std.json.parseFromSliceLeaky(proto.run.RunStartedData, a, started_row.text(2), .{});
    try testing.expectEqual(proto.ids.SessionId.bytes(sid), started_payload.session_id);
    try testing.expectEqual(@as(u64, 1), started_payload.seq);
    try testing.expectEqual(@as(u64, 1), started_payload.run_id);
    try testing.expectEqual(proto.enums.RunKind.turn, started_payload.kind);
    try testing.expectEqual(@as(u64, 0), started_payload.config_rev);
    try testing.expectEqual(@as(u64, 150), started_payload.started_at_ms);

    const done = try appendOpenDone(&db, a, [_]u8{2} ** 16, 175, .{
        .session_id = .bytes(sid),
        .seq = 0,
        .run_id = 1,
        .kind = .turn,
        .timing = .{ .started_at_ms = 150, .ended_at_ms = 175 },
        .outcome = .{ .turn = .{ .finish = .stop, .rounds = 1 } },
    });
    try db.conn.execNoArgs("COMMIT");
    try testing.expectEqual(@as(u64, 2), done.seq);
    try testing.expect((try session.snapshot(&db, a, sid)).?.open_run_id == null);
}

test "a terminal event must match the complete open-run marker" {
    var db = try Database.openTest();
    defer db.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sid = [_]u8{3} ** 16;
    try seedSession(&db, sid);

    try db.conn.execNoArgs("BEGIN IMMEDIATE");
    _ = try event.allocRunId(&db, a, sid);
    _ = try appendStarted(&db, a, [_]u8{1} ** 16, 150, .{
        .session_id = .bytes(sid),
        .seq = 0,
        .run_id = 1,
        .kind = .turn,
        .config_rev = 0,
        .started_at_ms = 150,
    });
    try db.conn.execNoArgs("COMMIT");

    try db.conn.execNoArgs("BEGIN IMMEDIATE");
    try testing.expectError(error.NoRow, appendOpenDone(&db, a, [_]u8{2} ** 16, 175, .{
        .session_id = .bytes(sid),
        .seq = 0,
        .run_id = 1,
        .kind = .compaction,
        .timing = .{ .started_at_ms = 150, .ended_at_ms = 175 },
        .outcome = .{ .canceled = .{} },
    }));
    try db.conn.execNoArgs("ROLLBACK");

    try db.conn.execNoArgs("BEGIN IMMEDIATE");
    try testing.expectError(error.NoRow, appendOpenDone(&db, a, [_]u8{3} ** 16, 175, .{
        .session_id = .bytes(sid),
        .seq = 0,
        .run_id = 1,
        .kind = .turn,
        .timing = .{ .started_at_ms = 149, .ended_at_ms = 175 },
        .outcome = .{ .canceled = .{} },
    }));
    try db.conn.execNoArgs("ROLLBACK");

    try testing.expectEqual(@as(?u64, 1), (try session.snapshot(&db, a, sid)).?.open_run_id);
    try testing.expectEqual(@as(u64, 1), try countEvents(&db, "run.started"));
    try testing.expectEqual(@as(u64, 0), try countEvents(&db, "run.done"));
    try testing.expectEqual(@as(u64, 1), (try event.highWater(&db, a, sid)).?.seq_high);
}

test "an open-run terminal rejects absent or backwards start timing" {
    var db = try Database.openTest();
    defer db.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sid = [_]u8{3} ** 16;
    try seedSession(&db, sid);

    try db.conn.execNoArgs("BEGIN IMMEDIATE");
    _ = try event.allocRunId(&db, a, sid);
    _ = try appendStarted(&db, a, [_]u8{1} ** 16, 150, .{
        .session_id = .bytes(sid),
        .seq = 0,
        .run_id = 1,
        .kind = .turn,
        .config_rev = 0,
        .started_at_ms = 150,
    });
    try db.conn.execNoArgs("COMMIT");

    try db.conn.execNoArgs("BEGIN IMMEDIATE");
    try testing.expectError(error.InvalidRunTiming, appendOpenDone(&db, a, [_]u8{2} ** 16, 175, .{
        .session_id = .bytes(sid),
        .seq = 0,
        .run_id = 1,
        .kind = .turn,
        .timing = .{ .started_at_ms = null, .ended_at_ms = 175 },
        .outcome = .{ .canceled = .{} },
    }));
    try db.conn.execNoArgs("ROLLBACK");

    try db.conn.execNoArgs("BEGIN IMMEDIATE");
    try testing.expectError(error.InvalidRunTiming, appendOpenDone(&db, a, [_]u8{3} ** 16, 149, .{
        .session_id = .bytes(sid),
        .seq = 0,
        .run_id = 1,
        .kind = .turn,
        .timing = .{ .started_at_ms = 150, .ended_at_ms = 149 },
        .outcome = .{ .canceled = .{} },
    }));
    try db.conn.execNoArgs("ROLLBACK");

    try testing.expectEqual(@as(u64, 1), (try event.highWater(&db, a, sid)).?.seq_high);
    try testing.expectEqual(@as(?u64, 1), (try session.snapshot(&db, a, sid)).?.open_run_id);
}
