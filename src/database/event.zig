//! The event log is authoritative. Projections rebuild from it.
//! Call these primitives inside the caller's write transaction so the event and projection commit together.
//! Idempotency for a retried request lives in the input inbox, not here.

const std = @import("std");
const sql = @import("sql");
const Database = @import("database.zig").Database;

/// Recovery reads these id marks. It never computes them with MAX over the log.
pub const HighWater = struct {
    seq_high: u64,
    message_id_high: u64,
    run_id_high: u64,
    input_id_high: u64,
    config_rev_high: u64,
};

/// Allocate the next seq and append the event. Return the seq. Run inside a write transaction.
pub fn append(db: *Database, arena: std.mem.Allocator, session_id: [16]u8, name: []const u8, payload: []const u8) !u64 {
    std.debug.assert(sql.inTransaction(db.conn)); // else a partial failure leaves a seq hole
    const alloc = try db.queries.alloc_seq.one(arena, .{ .id = session_id });
    const seq = alloc.value.seq_high;
    try db.queries.append_event.exec(.{ .session_id = session_id, .seq = seq, .name = name, .payload = payload });
    return seq;
}

/// Raise the id-minting marks. Each mark only rises. Run inside a write transaction.
pub fn bumpIds(db: *Database, arena: std.mem.Allocator, session_id: [16]u8, marks: struct {
    message_id_high: u64 = 0,
    run_id_high: u64 = 0,
    input_id_high: u64 = 0,
    config_rev_high: u64 = 0,
}) !void {
    std.debug.assert(sql.inTransaction(db.conn)); // else a partial failure desyncs the id marks
    _ = try db.queries.bump_ids.one(arena, .{
        .id = session_id,
        .message_id_high = marks.message_id_high,
        .run_id_high = marks.run_id_high,
        .input_id_high = marks.input_id_high,
        .config_rev_high = marks.config_rev_high,
    });
}

/// Read the high-water marks into `arena`, or null when the session has no row.
pub fn highWater(db: *Database, arena: std.mem.Allocator, session_id: [16]u8) !?HighWater {
    const row = (try db.queries.read_high.maybeOne(arena, .{ .id = session_id })) orelse return null;
    return .{
        .seq_high = row.value.seq_high,
        .message_id_high = row.value.message_id_high,
        .run_id_high = row.value.run_id_high,
        .input_id_high = row.value.input_id_high,
        .config_rev_high = row.value.config_rev_high,
    };
}

const testing = std.testing;
const zqlite = @import("zqlite");
const workspace = @import("workspace.zig");
const session = @import("session.zig");

fn testDb() !Database {
    const conn = try zqlite.open(":memory:", zqlite.OpenFlags.Create | zqlite.OpenFlags.NoMutex | zqlite.OpenFlags.EXResCode);
    return Database.open(conn);
}

fn seedSession(db: *Database, a: std.mem.Allocator, id: [16]u8) !void {
    const ws = try workspace.resolve(db, a, [_]u8{7} ** 16, "/w", "w", "/w");
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

test "append allocates contiguous seqs and raises the high-water mark" {
    var db = try testDb();
    defer db.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const sid = [_]u8{3} ** 16;
    try seedSession(&db, a, sid);

    try db.conn.execNoArgs("BEGIN IMMEDIATE");
    try testing.expectEqual(@as(u64, 1), try append(&db, a, sid, "run.started", "{}"));
    try testing.expectEqual(@as(u64, 2), try append(&db, a, sid, "message.committed", "{}"));
    try db.conn.execNoArgs("COMMIT");

    const hw = (try highWater(&db, a, sid)).?;
    try testing.expectEqual(@as(u64, 2), hw.seq_high);
}

test "bumpIds only raises a mark" {
    var db = try testDb();
    defer db.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const sid = [_]u8{3} ** 16;
    try seedSession(&db, a, sid);

    try db.conn.execNoArgs("BEGIN IMMEDIATE");
    try bumpIds(&db, a, sid, .{ .message_id_high = 5, .run_id_high = 3, .input_id_high = 7, .config_rev_high = 2 });
    try bumpIds(&db, a, sid, .{ .message_id_high = 2 }); // lower value does not lower the mark
    try db.conn.execNoArgs("COMMIT");
    const hw = (try highWater(&db, a, sid)).?;
    try testing.expectEqual(@as(u64, 5), hw.message_id_high);
    try testing.expectEqual(@as(u64, 3), hw.run_id_high);
    try testing.expectEqual(@as(u64, 7), hw.input_id_high);
    try testing.expectEqual(@as(u64, 2), hw.config_rev_high);
}

test "bumpIds rejects a missing session" {
    var db = try testDb();
    defer db.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try db.conn.execNoArgs("BEGIN IMMEDIATE");
    defer db.conn.execNoArgs("ROLLBACK") catch {};
    try testing.expectError(error.NoRow, bumpIds(&db, a, [_]u8{9} ** 16, .{ .run_id_high = 1 }));
}

test "append rejects a missing session" {
    var db = try testDb();
    defer db.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try db.conn.execNoArgs("BEGIN IMMEDIATE");
    defer db.conn.execNoArgs("ROLLBACK") catch {};
    try testing.expectError(error.NoRow, append(&db, a, [_]u8{9} ** 16, "x", "{}"));
}

test "a rolled-back append leaves no seq hole" {
    var db = try testDb();
    defer db.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const sid = [_]u8{3} ** 16;
    try seedSession(&db, a, sid);

    try db.conn.execNoArgs("BEGIN IMMEDIATE");
    _ = try append(&db, a, sid, "run.started", "{}");
    try db.conn.execNoArgs("ROLLBACK");

    try testing.expectEqual(@as(u64, 0), (try highWater(&db, a, sid)).?.seq_high);

    try db.conn.execNoArgs("BEGIN IMMEDIATE");
    try testing.expectEqual(@as(u64, 1), try append(&db, a, sid, "run.started", "{}"));
    try db.conn.execNoArgs("COMMIT");
}

test "two sessions each start at seq 1" {
    var db = try testDb();
    defer db.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const one = [_]u8{1} ** 16;
    const two = [_]u8{2} ** 16;
    const ws = try workspace.resolve(&db, a, [_]u8{7} ** 16, "/w", "w", "/w");
    for ([_][16]u8{ one, two }) |sid| {
        try session.create(&db, .{
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
    }

    try db.conn.execNoArgs("BEGIN IMMEDIATE");
    try testing.expectEqual(@as(u64, 1), try append(&db, a, one, "x", "{}"));
    try testing.expectEqual(@as(u64, 1), try append(&db, a, two, "x", "{}"));
    try db.conn.execNoArgs("COMMIT");
}

test "highWater returns zeros for a fresh session and null for a missing one" {
    var db = try testDb();
    defer db.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const sid = [_]u8{3} ** 16;
    try seedSession(&db, a, sid);

    const hw = (try highWater(&db, a, sid)).?;
    try testing.expectEqual(@as(u64, 0), hw.seq_high);
    try testing.expectEqual(@as(u64, 0), hw.message_id_high);
    try testing.expect((try highWater(&db, a, [_]u8{9} ** 16)) == null);
}
