//! The event log is authoritative. Projections rebuild from it.
//! Call these primitives inside the caller's write transaction so the event and projection commit together.
//! The input inbox owns idempotency for a retried request.

const std = @import("std");
const sql = @import("sql");
const Database = @import("store.zig").Database;

/// Recovery reads these id marks. It never computes them with MAX over the log.
pub const HighWater = struct {
    seq_high: u64,
    message_id_high: u64,
    run_id_high: u64,
    input_id_high: u64,
    config_rev_high: u64,
    /// Every committed message ever stored. No path deletes a message row.
    message_count: u64,
};

/// Allocate the next seq and append the event. Return the seq. Run inside a write transaction.
/// The caller mints event_id (UUIDv7) and stamps committed_at_ms; both belong to the event envelope.
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
    std.debug.assert(sql.inTransaction(db.conn));
    const alloc = try db.queries.alloc_seq.one(arena, .{ .id = session_id });
    std.debug.assert(alloc.value.seq_high > 0);
    return alloc.value.seq_high;
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
    std.debug.assert(sql.inTransaction(db.conn));
    return (try db.queries.alloc_run_id.one(arena, .{ .id = session_id })).value.run_id_high;
}

/// Allocate the next message id for a session. Run inside a write transaction. Return NoRow when absent.
pub fn allocMessageId(db: *Database, arena: std.mem.Allocator, session_id: [16]u8) !u64 {
    std.debug.assert(sql.inTransaction(db.conn));
    return (try db.queries.alloc_message_id.one(arena, .{ .id = session_id })).value.message_id_high;
}

/// Allocate the next input id for a session. Run inside a write transaction. Return NoRow when absent.
pub fn allocInputId(db: *Database, arena: std.mem.Allocator, session_id: [16]u8) !u64 {
    std.debug.assert(sql.inTransaction(db.conn));
    return (try db.queries.alloc_input_id.one(arena, .{ .id = session_id })).value.input_id_high;
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
        .message_count = row.value.message_count,
    };
}

const testing = std.testing;
const session = @import("session.zig");

/// A distinct event id for a test. The event_id column is globally unique.
fn eid(n: u8) [16]u8 {
    return [_]u8{n} ** 16;
}

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

test "append allocates contiguous seqs and raises the high-water mark" {
    var db = try Database.openTest();
    defer db.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const sid = [_]u8{3} ** 16;
    try seedSession(&db, sid);

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
    try seedSession(&db, sid);

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
    for ([_][16]u8{ one, two }) |sid| {
        try session.create(&db, .{
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
    }

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
    try seedSession(&db, sid);

    const hw = (try highWater(&db, a, sid)).?;
    try testing.expectEqual(@as(u64, 0), hw.seq_high);
    try testing.expectEqual(@as(u64, 0), hw.message_id_high);
    try testing.expect((try highWater(&db, a, [_]u8{9} ** 16)) == null);
}
