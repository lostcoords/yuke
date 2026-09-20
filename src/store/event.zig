//! The event log is authoritative and projections rebuild from it. Call these inside the caller's write transaction, so an event and its projection commit together. The input inbox owns idempotency.

const std = @import("std");
const sql = @import("sql");
const Database = @import("store.zig").Database;
const queries_gen = @import("queries_gen.zig");

/// Recovery reads these id marks without MAX; the count includes every committed message because no path deletes a message row.
pub const HighWater = queries_gen.ReadHigh.Row;

/// Allocate the next seq, append the event, and return the seq inside a write transaction. The caller mints event_id (UUIDv7) and stamps committed_at_ms.
pub fn append(
    db: *Database,
    arena: std.mem.Allocator,
    session_id: [16]u8,
    event_id: [16]u8,
    committed_at_ms: u64,
    name: []const u8,
    payload: []const u8,
) !u64 {
    std.debug.assert(sql.inTransaction(db.conn)); // A partial failure must not leave a seq hole.
    const seq = try allocSeq(db, arena, session_id);
    try appendAt(db, session_id, seq, event_id, committed_at_ms, name, payload);
    return seq;
}

/// Allocate the next event sequence. Run inside the transaction that appends the event.
pub fn allocSeq(db: *Database, arena: std.mem.Allocator, session_id: [16]u8) !u64 {
    return allocMark("alloc_seq", "seq_high", true, db, arena, session_id);
}

/// Append an event at a sequence that `allocSeq` reserved in the same transaction.
pub fn appendAt(
    db: *Database,
    session_id: [16]u8,
    seq: u64,
    event_id: [16]u8,
    committed_at_ms: u64,
    name: []const u8,
    payload: []const u8,
) !void {
    std.debug.assert(sql.inTransaction(db.conn));
    std.debug.assert(seq > 0);
    std.debug.assert(name.len > 0);
    std.debug.assert(payload.len > 0);
    try db.queries.append_event.exec(.{
        .session_id = session_id,
        .seq = seq,
        .event_id = event_id,
        .committed_at_ms = committed_at_ms,
        .name = name,
        .payload = payload,
    });
}

/// Allocate the next run id for a session. Run inside a write transaction. Return NoRow when absent.
pub fn allocRunId(db: *Database, arena: std.mem.Allocator, session_id: [16]u8) !u64 {
    return allocMark("alloc_run_id", "run_id_high", false, db, arena, session_id);
}

/// Allocate the next message id for a session. Run inside a write transaction. Return NoRow when absent.
pub fn allocMessageId(db: *Database, arena: std.mem.Allocator, session_id: [16]u8) !u64 {
    return allocMark("alloc_message_id", "message_id_high", false, db, arena, session_id);
}

/// Allocate the next input id for a session. Run inside a write transaction. Return NoRow when absent.
pub fn allocInputId(db: *Database, arena: std.mem.Allocator, session_id: [16]u8) !u64 {
    return allocMark("alloc_input_id", "input_id_high", false, db, arena, session_id);
}

fn allocMark(comptime query_name: []const u8, comptime field_name: []const u8, comptime assert_positive: bool, db: *Database, arena: std.mem.Allocator, session_id: [16]u8) !u64 {
    std.debug.assert(sql.inTransaction(db.conn));
    const row = try @field(db.queries, query_name).one(arena, .{ .id = session_id });
    const value = @field(row.value, field_name);
    if (assert_positive) std.debug.assert(value > 0);
    return value;
}

/// Read the high-water marks into `arena`, or null when the session has no row.
pub fn highWater(db: *Database, arena: std.mem.Allocator, session_id: [16]u8) !?HighWater {
    const row = (try db.queries.read_high.maybeOne(arena, .{ .id = session_id })) orelse return null;
    return row.value;
}

const testing = std.testing;
const session = @import("session.zig");

/// A distinct event id for a test. The event_id column is globally unique.
fn eid(n: u8) [16]u8 {
    return [_]u8{n} ** 16;
}

test "append allocates contiguous seqs and raises the high-water mark" {
    var db = try Database.openTest();
    defer db.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const sid = [_]u8{3} ** 16;
    try session.seedSession(&db, sid);

    try db.conn.execNoArgs("BEGIN IMMEDIATE");
    try testing.expectEqual(@as(u64, 1), try append(&db, a, sid, eid(1), 1, "run.started", "{}"));
    try testing.expectEqual(@as(u64, 2), try append(&db, a, sid, eid(2), 1, "message.committed", "{}"));
    try db.conn.execNoArgs("COMMIT");

    const hw = (try highWater(&db, a, sid)).?;
    try testing.expectEqual(@as(u64, 2), hw.seq_high);
}

test "append rejects a missing session" {
    var db = try Database.openTest();
    defer db.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try db.conn.execNoArgs("BEGIN IMMEDIATE");
    defer db.conn.execNoArgs("ROLLBACK") catch {};
    try testing.expectError(error.NoRow, append(&db, a, [_]u8{9} ** 16, eid(1), 1, "x", "{}"));
}

test "a rolled-back append leaves no seq hole" {
    var db = try Database.openTest();
    defer db.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const sid = [_]u8{3} ** 16;
    try session.seedSession(&db, sid);

    try db.conn.execNoArgs("BEGIN IMMEDIATE");
    _ = try append(&db, a, sid, eid(1), 1, "run.started", "{}");
    try db.conn.execNoArgs("ROLLBACK");

    try testing.expectEqual(@as(u64, 0), (try highWater(&db, a, sid)).?.seq_high);

    try db.conn.execNoArgs("BEGIN IMMEDIATE");
    try testing.expectEqual(@as(u64, 1), try append(&db, a, sid, eid(2), 1, "run.started", "{}"));
    try db.conn.execNoArgs("COMMIT");
}

test "two sessions each start at seq 1" {
    var db = try Database.openTest();
    defer db.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const one = [_]u8{1} ** 16;
    const two = [_]u8{2} ** 16;
    try session.seedSession(&db, one);
    try session.seedSession(&db, two);

    try db.conn.execNoArgs("BEGIN IMMEDIATE");
    try testing.expectEqual(@as(u64, 1), try append(&db, a, one, eid(1), 1, "x", "{}"));
    try testing.expectEqual(@as(u64, 1), try append(&db, a, two, eid(2), 1, "x", "{}"));
    try db.conn.execNoArgs("COMMIT");
}

test "highWater returns zeros for a fresh session and null for a missing one" {
    var db = try Database.openTest();
    defer db.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const sid = [_]u8{3} ** 16;
    try session.seedSession(&db, sid);

    const hw = (try highWater(&db, a, sid)).?;
    try testing.expectEqual(@as(u64, 0), hw.seq_high);
    try testing.expectEqual(@as(u64, 0), hw.message_id_high);
    try testing.expect((try highWater(&db, a, [_]u8{9} ** 16)) == null);
}
