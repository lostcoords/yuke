//! Durable run lifecycle events and the open-run recovery obligation.

const std = @import("std");
const wire = @import("wire");
const Database = @import("database.zig").Database;
const event = @import("event.zig");
const session = @import("session.zig");

/// Append `run.started` and set its terminal obligation. Run inside the start transaction.
pub fn appendStarted(
    db: *Database,
    arena: std.mem.Allocator,
    event_id: [16]u8,
    committed_at_ms: u64,
    data: wire.run.RunStartedData,
) !wire.run.RunStartedData {
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
    data: wire.run.RunDoneData,
) !wire.run.RunDoneData {
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

/// Close every run left open by a prior process. Return the durable terminal events.
pub fn recoverOpen(
    db: *Database,
    arena: std.mem.Allocator,
    ended_at_ms: u64,
    event_ids: anytype,
) !usize {
    const open = try session.openRuns(db, arena);
    for (open) |item| {
        const kind = std.meta.stringToEnum(wire.enums.RunKind, item.kind) orelse return error.CorruptDatabase;
        try db.conn.execNoArgs("BEGIN IMMEDIATE");
        errdefer db.conn.execNoArgs("ROLLBACK") catch {};
        _ = try appendOpenDone(db, arena, try event_ids.next(), @max(ended_at_ms, item.started_at_ms), .{
            .session_id = .bytes(item.session_id),
            .seq = 0,
            .run_id = item.run_id,
            .kind = kind,
            .timing = .{ .started_at_ms = item.started_at_ms, .ended_at_ms = @max(ended_at_ms, item.started_at_ms) },
            .outcome = .{ .canceled = .{} },
        });
        try db.conn.execNoArgs("COMMIT");
    }
    return open.len;
}

const testing = std.testing;
const zqlite = @import("zqlite");
const workspace = @import("workspace.zig");

fn testDb() !Database {
    const conn = try zqlite.open(":memory:", zqlite.OpenFlags.Create | zqlite.OpenFlags.NoMutex | zqlite.OpenFlags.EXResCode);
    return Database.open(conn);
}

fn seedSession(db: *Database, arena: std.mem.Allocator, id: [16]u8) !void {
    const ws = try workspace.resolve(db, arena, [_]u8{7} ** 16, "/w", "w", "/w");
    try session.create(db, .{
        .id = id,
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
}

const TestIds = struct {
    value: u8,

    pub fn next(self: *TestIds) ![16]u8 {
        self.value += 1;
        return [_]u8{self.value} ** 16;
    }
};

const FailingIds = struct {
    value: u8,
    remaining: usize,

    pub fn next(self: *FailingIds) ![16]u8 {
        if (self.remaining == 0) return error.Injected;
        self.remaining -= 1;
        self.value += 1;
        return [_]u8{self.value} ** 16;
    }
};

fn countEvents(db: *Database, name: []const u8) !u64 {
    const row = (try db.conn.row("SELECT count(*) FROM events WHERE name = ?1", .{name})) orelse return error.NoRow;
    defer row.deinit();
    return @intCast(row.int(0));
}

test "start and done events move the open-run triad in their transactions" {
    var db = try testDb();
    defer db.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sid = [_]u8{3} ** 16;
    try seedSession(&db, a, sid);

    try db.conn.execNoArgs("BEGIN IMMEDIATE");
    try event.bumpIds(&db, a, sid, .{ .run_id_high = 1 });
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
    const started_payload = try std.json.parseFromSliceLeaky(wire.run.RunStartedData, a, started_row.text(2), .{});
    try testing.expectEqual(wire.ids.SessionId.bytes(sid), started_payload.session_id);
    try testing.expectEqual(@as(u64, 1), started_payload.seq);
    try testing.expectEqual(@as(u64, 1), started_payload.run_id);
    try testing.expectEqual(wire.enums.RunKind.turn, started_payload.kind);
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
    var db = try testDb();
    defer db.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sid = [_]u8{3} ** 16;
    try seedSession(&db, a, sid);

    try db.conn.execNoArgs("BEGIN IMMEDIATE");
    try event.bumpIds(&db, a, sid, .{ .run_id_high = 1 });
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
    var db = try testDb();
    defer db.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sid = [_]u8{3} ** 16;
    try seedSession(&db, a, sid);

    try db.conn.execNoArgs("BEGIN IMMEDIATE");
    try event.bumpIds(&db, a, sid, .{ .run_id_high = 1 });
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

test "recovery cancels each open run and clears its triad atomically" {
    var db = try testDb();
    defer db.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const one = [_]u8{1} ** 16;
    const two = [_]u8{2} ** 16;
    try seedSession(&db, a, one);
    try seedSession(&db, a, two);

    for ([_][16]u8{ one, two }, 0..) |sid, i| {
        try db.conn.execNoArgs("BEGIN IMMEDIATE");
        try event.bumpIds(&db, a, sid, .{ .run_id_high = 1 });
        _ = try appendStarted(&db, a, [_]u8{@intCast(9 + i)} ** 16, 120, .{
            .session_id = .bytes(sid),
            .seq = 0,
            .run_id = 1,
            .kind = .turn,
            .config_rev = 0,
            .started_at_ms = 120,
        });
        try db.conn.execNoArgs("COMMIT");
    }

    var ids: TestIds = .{ .value = 20 };
    try testing.expectEqual(@as(usize, 2), try recoverOpen(&db, a, 200, &ids));
    try testing.expect((try session.snapshot(&db, a, one)).?.open_run_id == null);
    try testing.expect((try session.snapshot(&db, a, two)).?.open_run_id == null);

    const row = (try db.conn.row(
        "SELECT seq, event_id, committed_at_ms, payload FROM events WHERE session_id = ?1 AND name = 'run.done'",
        .{zqlite.blob(&one)},
    )) orelse return error.NoRow;
    defer row.deinit();
    try testing.expectEqual(@as(i64, 2), row.int(0));
    try testing.expectEqualSlices(u8, &([_]u8{21} ** 16), row.blob(1));
    try testing.expectEqual(@as(i64, 200), row.int(2));
    const payload = try std.json.parseFromSliceLeaky(wire.run.RunDoneData, a, row.text(3), .{});
    try testing.expectEqual(@as(u64, 2), payload.seq);
    try testing.expect(payload.outcome == .canceled);
    try testing.expectEqual(@as(?u64, 120), payload.timing.started_at_ms);
    try testing.expectEqual(@as(u64, 200), payload.timing.ended_at_ms);
}

test "a recovery failure leaves the remaining run recoverable" {
    var db = try testDb();
    defer db.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const one = [_]u8{1} ** 16;
    const two = [_]u8{2} ** 16;
    try seedSession(&db, a, one);
    try seedSession(&db, a, two);

    for ([_][16]u8{ one, two }, 0..) |sid, i| {
        try db.conn.execNoArgs("BEGIN IMMEDIATE");
        try event.bumpIds(&db, a, sid, .{ .run_id_high = 1 });
        _ = try appendStarted(&db, a, [_]u8{@intCast(5 + i)} ** 16, 120, .{
            .session_id = .bytes(sid),
            .seq = 0,
            .run_id = 1,
            .kind = .turn,
            .config_rev = 0,
            .started_at_ms = 120,
        });
        try db.conn.execNoArgs("COMMIT");
    }

    var failing: FailingIds = .{ .value = 30, .remaining = 1 };
    try testing.expectError(error.Injected, recoverOpen(&db, a, 200, &failing));
    try testing.expect((try session.snapshot(&db, a, one)).?.open_run_id == null);
    try testing.expectEqual(@as(?u64, 1), (try session.snapshot(&db, a, two)).?.open_run_id);
    try testing.expectEqual(@as(u64, 1), try countEvents(&db, "run.done"));

    var ids: TestIds = .{ .value = 40 };
    try testing.expectEqual(@as(usize, 1), try recoverOpen(&db, a, 210, &ids));
    try testing.expect((try session.snapshot(&db, a, two)).?.open_run_id == null);
    try testing.expectEqual(@as(u64, 2), try countEvents(&db, "run.done"));
}

test "file-backed recovery is idempotent across reopen" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buffer, ".zig-cache/tmp/{s}/runs.db", .{tmp.sub_path});
    const flags = zqlite.OpenFlags.Create | zqlite.OpenFlags.NoMutex | zqlite.OpenFlags.EXResCode;
    const sid = [_]u8{3} ** 16;

    {
        var db = try Database.open(try zqlite.open(path, flags));
        defer db.deinit();
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        try seedSession(&db, a, sid);
        try db.conn.execNoArgs("BEGIN IMMEDIATE");
        try event.bumpIds(&db, a, sid, .{ .run_id_high = 1 });
        _ = try appendStarted(&db, a, [_]u8{1} ** 16, 120, .{
            .session_id = .bytes(sid),
            .seq = 0,
            .run_id = 1,
            .kind = .turn,
            .config_rev = 0,
            .started_at_ms = 120,
        });
        try db.conn.execNoArgs("COMMIT");
    }

    {
        var db = try Database.open(try zqlite.open(path, flags));
        defer db.deinit();
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var ids: TestIds = .{ .value = 10 };
        try testing.expectEqual(@as(usize, 1), try recoverOpen(&db, a, 200, &ids));
        try testing.expectEqual(@as(u64, 1), try countEvents(&db, "run.done"));
    }

    {
        var db = try Database.open(try zqlite.open(path, flags));
        defer db.deinit();
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var ids: TestIds = .{ .value = 20 };
        try testing.expectEqual(@as(usize, 0), try recoverOpen(&db, a, 210, &ids));
        try testing.expectEqual(@as(u64, 1), try countEvents(&db, "run.done"));
        try testing.expect((try session.snapshot(&db, a, sid)).?.open_run_id == null);
    }
}
