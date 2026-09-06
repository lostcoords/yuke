//! The durable pending-input projection and its input lifecycle events.

const std = @import("std");
const sql = @import("sql");
const proto = @import("proto");

const Database = @import("store.zig").Database;
const event = @import("event.zig");

pub const Entry = struct {
    input: proto.misc.QueuedInput,
    seq: u64,
};

/// Append input.queued and create its pending projection in one transaction.
pub fn enqueue(
    db: *Database,
    arena: std.mem.Allocator,
    session_id: [16]u8,
    event_id: [16]u8,
    committed_at_ms: u64,
    content: []const proto.content.ContentPart,
    queued_at_ms: u64,
) !Entry {
    return enqueueSource(db, arena, session_id, event_id, committed_at_ms, content, queued_at_ms, null);
}

pub fn enqueueSource(
    db: *Database,
    arena: std.mem.Allocator,
    session_id: [16]u8,
    event_id: [16]u8,
    committed_at_ms: u64,
    content: []const proto.content.ContentPart,
    queued_at_ms: u64,
    source: ?proto.input.InputSource,
) !Entry {
    std.debug.assert(sql.inTransaction(db.conn));

    const input_id = try event.allocInputId(db, arena, session_id);
    const seq = try event.allocSeq(db, arena, session_id);
    const stored_content = try proto.dupe(arena, content);
    const queued: proto.misc.QueuedInput = .{
        .input_id = input_id,
        .source = try proto.dupe(arena, source),
        .content = stored_content,
        .queued_at_ms = queued_at_ms,
    };
    const data: proto.input.InputQueuedData = .{
        .session_id = .bytes(session_id),
        .seq = seq,
        .input = queued,
    };
    const event_payload = try std.json.Stringify.valueAlloc(arena, data, .{ .emit_null_optional_fields = false });
    const projection_payload = try std.json.Stringify.valueAlloc(arena, queued, .{ .emit_null_optional_fields = false });
    try event.appendAt(db, session_id, seq, event_id, committed_at_ms, "input.queued", event_payload);
    try db.queries.insert_pending_input.exec(.{
        .session_id = session_id,
        .input_id = input_id,
        .seq = seq,
        .queued_at_ms = queued_at_ms,
        .payload = projection_payload,
    });
    return .{ .input = queued, .seq = seq };
}

/// List pending inputs in FIFO order. The content borrows `arena`.
pub fn list(db: *Database, arena: std.mem.Allocator, session_id: [16]u8) ![]Entry {
    var rows = try db.queries.pending_inputs.rows(.{ .session_id = session_id });
    defer rows.deinit();

    var out: std.ArrayList(Entry) = .empty;
    while (try rows.next(arena)) |owned| {
        var row = owned;
        defer row.deinit();
        try out.append(arena, try checkedRow(arena, row.value));
    }
    return out.items;
}

/// Read the queue depth of one session from the pending table, for a session no runtime holds.
pub fn count(db: *Database, arena: std.mem.Allocator, session_id: [16]u8) !u64 {
    const row = try db.queries.pending_input_count.one(arena, .{ .session_id = session_id });
    return @intCast(row.value.depth);
}

/// Consume one exact queued input without a new input.canceled event.
pub fn consume(db: *Database, arena: std.mem.Allocator, session_id: [16]u8, input_id: u64) !void {
    std.debug.assert(sql.inTransaction(db.conn));
    _ = try checkedPending(db, arena, session_id, input_id);
    _ = try db.queries.delete_pending_input.one(arena, .{ .session_id = session_id, .input_id = input_id });
}

/// Append input.canceled and delete one exact queued input in one transaction. Return the event seq.
pub fn cancel(
    db: *Database,
    arena: std.mem.Allocator,
    session_id: [16]u8,
    event_id: [16]u8,
    committed_at_ms: u64,
    input_id: u64,
) !u64 {
    std.debug.assert(sql.inTransaction(db.conn));
    const entry = try checkedPending(db, arena, session_id, input_id);
    if (entry.input.source) |source| if (source.protected()) return error.ProtectedInput;

    const seq = try event.allocSeq(db, arena, session_id);
    const data: proto.input.InputCanceledData = .{
        .session_id = .bytes(session_id),
        .seq = seq,
        .input_id = input_id,
    };
    const payload = try std.json.Stringify.valueAlloc(arena, data, .{ .emit_null_optional_fields = false });
    try event.appendAt(db, session_id, seq, event_id, committed_at_ms, "input.canceled", payload);
    _ = try db.queries.delete_pending_input.one(arena, .{ .session_id = session_id, .input_id = input_id });
    return seq;
}

fn checkedPending(db: *Database, arena: std.mem.Allocator, session_id: [16]u8, input_id: u64) !Entry {
    var row = (try db.queries.pending_input_by_id.maybeOne(arena, .{ .session_id = session_id, .input_id = input_id })) orelse return error.NoRow;
    defer row.deinit();
    return checkedRow(arena, row.value);
}

fn checkedRow(arena: std.mem.Allocator, row: anytype) !Entry {
    if (!std.mem.eql(u8, row.event_name, "input.queued")) return error.CorruptLog;
    const projection = std.json.parseFromSliceLeaky(proto.misc.QueuedInput, arena, row.payload, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.CorruptLog,
    };
    if (row.row_input_id != projection.input_id or row.queued_at_ms != projection.queued_at_ms) return error.CorruptLog;
    return .{ .input = projection, .seq = row.seq };
}

const testing = std.testing;
const zqlite = @import("zqlite");
const session = @import("session.zig");

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

fn textContent(comptime text: []const u8) []const proto.content.ContentPart {
    return &.{.{ .text = .{ .text = text } }};
}

test "enqueue writes the full event, projection, and sequence" {
    var db = try Database.openTest();
    defer db.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sid = [_]u8{3} ** 16;
    try seedSession(&db, sid);

    try db.conn.execNoArgs("BEGIN IMMEDIATE");
    const result = try enqueue(&db, a, sid, [_]u8{1} ** 16, 150, textContent("hello"), 149);
    try db.conn.execNoArgs("COMMIT");

    try testing.expectEqual(@as(u64, 1), result.input.input_id);
    try testing.expectEqual(@as(u64, 1), result.seq);
    const count_row = (try db.conn.row("SELECT count(*) FROM events WHERE name = 'input.queued'", .{})) orelse return error.NoRow;
    defer count_row.deinit();
    try testing.expectEqual(@as(i64, 1), count_row.int(0));
    const row = (try db.conn.row("SELECT payload FROM pending_inputs", .{})) orelse return error.NoRow;
    defer row.deinit();
    const stored = try std.json.parseFromSliceLeaky(proto.misc.QueuedInput, a, row.text(0), .{});
    try testing.expectEqualStrings("hello", stored.content[0].text.text);
}

test "list returns oldest-first owned entries" {
    var db = try Database.openTest();
    defer db.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sid = [_]u8{3} ** 16;
    try seedSession(&db, sid);

    try db.conn.execNoArgs("BEGIN IMMEDIATE");
    _ = try enqueue(&db, a, sid, [_]u8{1} ** 16, 150, textContent("one"), 150);
    _ = try enqueue(&db, a, sid, [_]u8{2} ** 16, 160, textContent("two"), 160);
    try db.conn.execNoArgs("COMMIT");

    const entries = try list(&db, a, sid);
    try testing.expectEqual(@as(usize, 2), entries.len);
    try testing.expectEqual(@as(u64, 1), entries[0].input.input_id);
    try testing.expectEqual(@as(u64, 2), entries[1].input.input_id);
    try testing.expectEqualStrings("one", entries[0].input.content[0].text.text);
}

test "cancel appends the exact event and deletes the projection" {
    var db = try Database.openTest();
    defer db.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sid = [_]u8{3} ** 16;
    try seedSession(&db, sid);

    try db.conn.execNoArgs("BEGIN IMMEDIATE");
    _ = try enqueue(&db, a, sid, [_]u8{1} ** 16, 150, textContent("hello"), 149);
    try db.conn.execNoArgs("COMMIT");
    try db.conn.execNoArgs("BEGIN IMMEDIATE");
    _ = try cancel(&db, a, sid, [_]u8{2} ** 16, 160, 1);
    try db.conn.execNoArgs("COMMIT");

    const pending_count = (try db.conn.row("SELECT count(*) FROM pending_inputs", .{})) orelse return error.NoRow;
    defer pending_count.deinit();
    try testing.expectEqual(@as(i64, 0), pending_count.int(0));
    const row = (try db.conn.row("SELECT seq, event_id, payload FROM events WHERE name = 'input.canceled'", .{})) orelse return error.NoRow;
    defer row.deinit();
    try testing.expectEqual(@as(i64, 2), row.int(0));
    try testing.expectEqualSlices(u8, &([_]u8{2} ** 16), row.blob(1));
    const data = try std.json.parseFromSliceLeaky(proto.input.InputCanceledData, a, row.text(2), .{});
    try testing.expectEqual(@as(u64, 1), data.input_id);
    try testing.expectEqual(proto.ids.SessionId.bytes(sid), data.session_id);
}

test "consume removes an input without a cancellation event" {
    var db = try Database.openTest();
    defer db.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sid = [_]u8{3} ** 16;
    try seedSession(&db, sid);

    try db.conn.execNoArgs("BEGIN IMMEDIATE");
    _ = try enqueue(&db, a, sid, [_]u8{1} ** 16, 150, textContent("hello"), 149);
    try db.conn.execNoArgs("COMMIT");
    try db.conn.execNoArgs("BEGIN IMMEDIATE");
    try consume(&db, a, sid, 1);
    try db.conn.execNoArgs("COMMIT");

    const pending_count = (try db.conn.row("SELECT count(*) FROM pending_inputs", .{})) orelse return error.NoRow;
    defer pending_count.deinit();
    try testing.expectEqual(@as(i64, 0), pending_count.int(0));
    const canceled_count = (try db.conn.row("SELECT count(*) FROM events WHERE name = 'input.canceled'", .{})) orelse return error.NoRow;
    defer canceled_count.deinit();
    try testing.expectEqual(@as(i64, 0), canceled_count.int(0));
}

test "missing cancel does not append an event" {
    var db = try Database.openTest();
    defer db.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sid = [_]u8{3} ** 16;
    try seedSession(&db, sid);

    try db.conn.execNoArgs("BEGIN IMMEDIATE");
    try testing.expectError(error.NoRow, cancel(&db, a, sid, [_]u8{1} ** 16, 150, 1));
    try db.conn.execNoArgs("ROLLBACK");
    const count_row = (try db.conn.row("SELECT count(*) FROM events", .{})) orelse return error.NoRow;
    defer count_row.deinit();
    try testing.expectEqual(@as(i64, 0), count_row.int(0));
}

test "pending projection enforces ownership and event foreign keys" {
    var db = try Database.openTest();
    defer db.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sid = [_]u8{3} ** 16;
    try seedSession(&db, sid);
    const row = (try db.conn.row("SELECT sql FROM sqlite_master WHERE name = 'pending_inputs'", .{})) orelse return error.NoRow;
    defer row.deinit();
    try testing.expect(std.mem.indexOf(u8, row.text(0), "WITHOUT ROWID") != null);
    const foreign_id = [_]u8{9} ** 16;
    try testing.expectError(error.ConstraintForeignKey, db.conn.exec(
        "INSERT INTO pending_inputs(session_id, input_id, seq, queued_at_ms, payload) VALUES (?1, 1, 1, 1, '{}')",
        .{zqlite.blob(&foreign_id)},
    ));
    try testing.expectError(error.ConstraintForeignKey, db.conn.exec(
        "INSERT INTO pending_inputs(session_id, input_id, seq, queued_at_ms, payload) VALUES (?1, 1, 1, 1, '{}')",
        .{zqlite.blob(&sid)},
    ));

    try db.conn.execNoArgs("BEGIN IMMEDIATE");
    _ = try enqueue(&db, a, sid, [_]u8{1} ** 16, 150, textContent("hello"), 149);
    try db.conn.execNoArgs("COMMIT");
    try db.conn.exec("DELETE FROM events WHERE session_id = ?1", .{zqlite.blob(&sid)});
    const pending_count = (try db.conn.row("SELECT count(*) FROM pending_inputs", .{})) orelse return error.NoRow;
    defer pending_count.deinit();
    try testing.expectEqual(@as(i64, 0), pending_count.int(0));
}

test "list rejects a projection whose source event has the wrong name" {
    var db = try Database.openTest();
    defer db.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sid = [_]u8{3} ** 16;
    try seedSession(&db, sid);

    try db.conn.execNoArgs("BEGIN IMMEDIATE");
    _ = try enqueue(&db, a, sid, [_]u8{1} ** 16, 150, textContent("hello"), 149);
    try db.conn.execNoArgs("COMMIT");
    try db.conn.exec("UPDATE events SET name = 'run.started' WHERE session_id = ?1", .{zqlite.blob(&sid)});
    try testing.expectError(error.CorruptLog, list(&db, a, sid));
}
