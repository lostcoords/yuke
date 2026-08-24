//! The durable pending-input projection and its input lifecycle events.

const std = @import("std");
const sql = @import("sql");
const wire = @import("wire");

const Database = @import("database.zig").Database;
const event = @import("event.zig");

pub const Entry = struct {
    input: wire.misc.QueuedInput,
    seq: u64,
};

/// Append input.queued and create its pending projection in one transaction.
pub fn enqueue(
    db: *Database,
    arena: std.mem.Allocator,
    session_id: [16]u8,
    event_id: [16]u8,
    committed_at_ms: u64,
    content: []const wire.content.ContentPart,
    queued_at_ms: u64,
) !Entry {
    std.debug.assert(sql.inTransaction(db.conn));

    const input_id = try event.allocInputId(db, arena, session_id);
    const seq = try event.allocSeq(db, arena, session_id);
    const stored_content = try wire.dupe(arena, content);
    const queued: wire.misc.QueuedInput = .{
        .input_id = input_id,
        .content = stored_content,
        .queued_at_ms = queued_at_ms,
    };
    const data: wire.input.InputQueuedData = .{
        .session_id = .bytes(session_id),
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

/// Consume one exact queued input without appending input.canceled.
pub fn consume(db: *Database, arena: std.mem.Allocator, session_id: [16]u8, input_id: u64) !void {
    std.debug.assert(sql.inTransaction(db.conn));
    _ = try checkedPending(db, arena, session_id, input_id);
    _ = try db.queries.delete_pending_input.one(arena, .{ .session_id = session_id, .input_id = input_id });
}

/// Append input.canceled and delete one exact queued input in one transaction.
pub fn cancel(
    db: *Database,
    arena: std.mem.Allocator,
    session_id: [16]u8,
    event_id: [16]u8,
    committed_at_ms: u64,
    input_id: u64,
) !void {
    std.debug.assert(sql.inTransaction(db.conn));
    _ = try checkedPending(db, arena, session_id, input_id);

    const data: wire.input.InputCanceledData = .{
        .session_id = .bytes(session_id),
        .input_id = input_id,
    };
    const payload = try std.json.Stringify.valueAlloc(arena, data, .{ .emit_null_optional_fields = false });
    _ = try event.append(db, arena, session_id, event_id, committed_at_ms, "input.canceled", payload);
    _ = try db.queries.delete_pending_input.one(arena, .{ .session_id = session_id, .input_id = input_id });
}

/// List sessions that have at least one pending input.
pub fn sessionIds(db: *Database, arena: std.mem.Allocator) ![][16]u8 {
    var rows = try db.queries.pending_session_ids.rows(.{});
    defer rows.deinit();

    var out: std.ArrayList([16]u8) = .empty;
    while (try rows.next(arena)) |owned| {
        var row = owned;
        defer row.deinit();
        try out.append(arena, row.value.session_id);
    }
    return out.items;
}

fn checkedPending(db: *Database, arena: std.mem.Allocator, session_id: [16]u8, input_id: u64) !Entry {
    var row = (try db.queries.pending_input_by_id.maybeOne(arena, .{ .session_id = session_id, .input_id = input_id })) orelse return error.NoRow;
    defer row.deinit();
    return checkedRow(arena, row.value);
}

fn checkedRow(arena: std.mem.Allocator, row: anytype) !Entry {
    if (!std.mem.eql(u8, row.event_name, "input.queued")) return error.CorruptLog;
    const projection = std.json.parseFromSliceLeaky(wire.misc.QueuedInput, arena, row.payload, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.CorruptLog,
    };
    if (row.row_input_id != projection.input_id or row.queued_at_ms != projection.queued_at_ms) return error.CorruptLog;
    return .{ .input = projection, .seq = row.seq };
}

const testing = std.testing;
const zqlite = @import("zqlite");
const workspace = @import("workspace.zig");
const session = @import("session.zig");

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

fn textContent(comptime text: []const u8) []const wire.content.ContentPart {
    return &.{.{ .text = .{ .text = text } }};
}

test "enqueue writes the full event, projection, and sequence" {
    var db = try testDb();
    defer db.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sid = [_]u8{3} ** 16;
    try seedSession(&db, a, sid);

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
    const stored = try std.json.parseFromSliceLeaky(wire.misc.QueuedInput, a, row.text(0), .{});
    try testing.expectEqualStrings("hello", stored.content[0].text.text);
}

test "list returns oldest-first owned entries and session ids" {
    var db = try testDb();
    defer db.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sid = [_]u8{3} ** 16;
    const sid_two = [_]u8{4} ** 16;
    try seedSession(&db, a, sid);
    try seedSession(&db, a, sid_two);

    try db.conn.execNoArgs("BEGIN IMMEDIATE");
    _ = try enqueue(&db, a, sid, [_]u8{1} ** 16, 150, textContent("one"), 150);
    _ = try enqueue(&db, a, sid, [_]u8{2} ** 16, 160, textContent("two"), 160);
    _ = try enqueue(&db, a, sid_two, [_]u8{3} ** 16, 170, textContent("other"), 170);
    try db.conn.execNoArgs("COMMIT");

    const entries = try list(&db, a, sid);
    try testing.expectEqual(@as(usize, 2), entries.len);
    try testing.expectEqual(@as(u64, 1), entries[0].input.input_id);
    try testing.expectEqual(@as(u64, 2), entries[1].input.input_id);
    try testing.expectEqualStrings("one", entries[0].input.content[0].text.text);
    const ids = try sessionIds(&db, a);
    try testing.expectEqual(@as(usize, 2), ids.len);
    try testing.expectEqual(sid, ids[0]);
    try testing.expectEqual(sid_two, ids[1]);
}

test "cancel appends the exact event and deletes the projection" {
    var db = try testDb();
    defer db.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sid = [_]u8{3} ** 16;
    try seedSession(&db, a, sid);

    try db.conn.execNoArgs("BEGIN IMMEDIATE");
    _ = try enqueue(&db, a, sid, [_]u8{1} ** 16, 150, textContent("hello"), 149);
    try db.conn.execNoArgs("COMMIT");
    try db.conn.execNoArgs("BEGIN IMMEDIATE");
    try cancel(&db, a, sid, [_]u8{2} ** 16, 160, 1);
    try db.conn.execNoArgs("COMMIT");

    const pending_count = (try db.conn.row("SELECT count(*) FROM pending_inputs", .{})) orelse return error.NoRow;
    defer pending_count.deinit();
    try testing.expectEqual(@as(i64, 0), pending_count.int(0));
    const row = (try db.conn.row("SELECT seq, event_id, payload FROM events WHERE name = 'input.canceled'", .{})) orelse return error.NoRow;
    defer row.deinit();
    try testing.expectEqual(@as(i64, 2), row.int(0));
    try testing.expectEqualSlices(u8, &([_]u8{2} ** 16), row.blob(1));
    const data = try std.json.parseFromSliceLeaky(wire.input.InputCanceledData, a, row.text(2), .{});
    try testing.expectEqual(@as(u64, 1), data.input_id);
    try testing.expectEqual(wire.ids.SessionId.bytes(sid), data.session_id);
}

test "consume removes an input without a cancellation event" {
    var db = try testDb();
    defer db.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sid = [_]u8{3} ** 16;
    try seedSession(&db, a, sid);

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
    var db = try testDb();
    defer db.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sid = [_]u8{3} ** 16;
    try seedSession(&db, a, sid);

    try db.conn.execNoArgs("BEGIN IMMEDIATE");
    try testing.expectError(error.NoRow, cancel(&db, a, sid, [_]u8{1} ** 16, 150, 1));
    try db.conn.execNoArgs("ROLLBACK");
    const count_row = (try db.conn.row("SELECT count(*) FROM events", .{})) orelse return error.NoRow;
    defer count_row.deinit();
    try testing.expectEqual(@as(i64, 0), count_row.int(0));
}

test "pending projection enforces ownership and event foreign keys" {
    var db = try testDb();
    defer db.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sid = [_]u8{3} ** 16;
    try seedSession(&db, a, sid);
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
    var db = try testDb();
    defer db.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sid = [_]u8{3} ** 16;
    try seedSession(&db, a, sid);

    try db.conn.execNoArgs("BEGIN IMMEDIATE");
    _ = try enqueue(&db, a, sid, [_]u8{1} ** 16, 150, textContent("hello"), 149);
    try db.conn.execNoArgs("COMMIT");
    try db.conn.exec("UPDATE events SET name = 'run.started' WHERE session_id = ?1", .{zqlite.blob(&sid)});
    try testing.expectError(error.CorruptLog, list(&db, a, sid));
}
