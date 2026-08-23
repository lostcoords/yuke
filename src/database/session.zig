//! The session registry stores the primary session state.
//! The event log omits session.summary_changed, so this table is authoritative.

const std = @import("std");
const Database = @import("database.zig").Database;
const queries_gen = @import("queries_gen.zig");

/// SessionSnapshot returns the client-facing summary and the open-run marker.
pub const Snapshot = queries_gen.SessionSnapshot.Row;

/// SessionPage returns one row of a session.list page.
pub const PageRow = queries_gen.SessionPage.Row;

/// The session.list selector drops a filter when its field is null.
/// top_level keeps roots and forks.
pub const Selector = struct {
    workspace_id: ?[16]u8 = null,
    parent_id: ?[16]u8 = null,
    job_id: ?[16]u8 = null,
    top_level: bool = false,
};

/// The cursor stores the last row that a page returned.
pub const Cursor = struct { updated_at_ms: u64, id: [16]u8 };

/// The create operation sets these fields. The field names match the InsertSession parameters.
pub const CreateParams = struct {
    id: [16]u8,
    workspace_id: [16]u8,
    origin: []const u8,
    parent_id: ?[16]u8 = null,
    parent_message_id: ?u64 = null,
    parent_part_id: ?u64 = null,
    source_id: ?[16]u8 = null,
    job_id: ?[16]u8 = null,
    profile: []const u8,
    model: []const u8,
    reasoning: []const u8,
    config_rev: u64,
    permission: []const u8,
    max_rounds: ?u64 = null,
    title: []const u8,
    agent: ?[]const u8 = null,
    created_by_name: ?[]const u8 = null,
    created_by_version: ?[]const u8 = null,
    created_at_ms: u64,
    updated_at_ms: u64,
};

/// Insert a new session row. The schema rejects an origin that does not match its id set.
pub fn create(db: *Database, params: CreateParams) !void {
    try db.queries.insert_session.exec(params);
}

/// Store the session's system prompt. Create sets it once; no method changes it.
pub fn setPrompt(db: *Database, id: [16]u8, prompt: []const u8) !void {
    try db.queries.insert_prompt.exec(.{ .session_id = id, .prompt = prompt });
}

/// Report whether a session with `id` exists.
pub fn exists(db: *Database, arena: std.mem.Allocator, id: [16]u8) !bool {
    var row = (try db.queries.session_exists.maybeOne(arena, .{ .id = id })) orelse return false;
    defer row.deinit();
    return true;
}

/// Load the summary of one session into `arena`. Return null when no row exists.
pub fn snapshot(db: *Database, arena: std.mem.Allocator, id: [16]u8) !?Snapshot {
    const row = (try db.queries.session_snapshot.maybeOne(arena, .{ .id = id })) orelse return null;
    return row.value;
}

/// Load one keyset page of the session list into `arena`, newest first. A null cursor starts
/// at the newest row. The result borrows `arena`.
pub fn list(db: *Database, arena: std.mem.Allocator, sel: Selector, cursor: ?Cursor, limit: i64) ![]PageRow {
    if (limit < 0) return error.InvalidLimit; // SQLite reads a negative LIMIT as unbounded.
    var it = try db.queries.session_page.rows(.{
        .filter_workspace_id = sel.workspace_id,
        .filter_parent_id = sel.parent_id,
        .filter_job_id = sel.job_id,
        .top_level = sel.top_level,
        .cursor_updated_at_ms = if (cursor) |c| c.updated_at_ms else null,
        .cursor_id = if (cursor) |c| c.id else null,
        .limit = limit,
    });
    defer it.deinit();

    var out: std.ArrayList(PageRow) = .empty;
    while (try it.next(arena)) |row| try out.append(arena, row.value);
    return out.items;
}

/// Count the whole view the selector describes.
pub fn count(db: *Database, arena: std.mem.Allocator, sel: Selector) !u64 {
    const row = try db.queries.session_count.one(arena, .{
        .filter_workspace_id = sel.workspace_id,
        .filter_parent_id = sel.parent_id,
        .filter_job_id = sel.job_id,
        .top_level = sel.top_level,
    });
    return row.value.total;
}

const testing = std.testing;
const zqlite = @import("zqlite");
const workspace = @import("workspace.zig");
const event = @import("event.zig");

fn testDb() !Database {
    const conn = try zqlite.open(":memory:", zqlite.OpenFlags.Create | zqlite.OpenFlags.NoMutex | zqlite.OpenFlags.EXResCode);
    return Database.open(conn);
}

fn rootParams(id: [16]u8, workspace_id: [16]u8) CreateParams {
    return .{
        .id = id,
        .workspace_id = workspace_id,
        .origin = "root",
        .profile = "default",
        .model = "opus",
        .reasoning = "high",
        .config_rev = 0,
        .permission = "normal",
        .title = "t",
        .created_at_ms = 100,
        .updated_at_ms = 100,
    };
}

test "create inserts a root session and exists finds it" {
    var db = try testDb();
    defer db.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const ws = try workspace.resolve(&db, a, [_]u8{7} ** 16, "/w", "w", "/w");
    const id = [_]u8{3} ** 16;
    try create(&db, rootParams(id, ws.id));

    try testing.expect(try exists(&db, a, id));
    try testing.expect(!try exists(&db, a, [_]u8{9} ** 16));

    const snap = (try snapshot(&db, a, id)).?;
    try testing.expectEqualStrings("root", snap.origin);
    try testing.expectEqual(@as(u64, 0), snap.message_count);
    try testing.expect(snap.open_run_id == null);
    try testing.expect((try snapshot(&db, a, [_]u8{9} ** 16)) == null);
}

test "a root session rejects a stray parent id" {
    var db = try testDb();
    defer db.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const ws = try workspace.resolve(&db, a, [_]u8{7} ** 16, "/w", "w", "/w");
    var params = rootParams([_]u8{3} ** 16, ws.id);
    params.parent_id = [_]u8{4} ** 16; // A root must have no parent marks.
    try testing.expectError(error.ConstraintCheck, create(&db, params));
}

test "a child session needs all three parent marks" {
    var db = try testDb();
    defer db.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const ws = try workspace.resolve(&db, a, [_]u8{7} ** 16, "/w", "w", "/w");

    // A valid child sets all three marks.
    var ok = rootParams([_]u8{1} ** 16, ws.id);
    ok.origin = "child";
    ok.parent_id = [_]u8{4} ** 16;
    ok.parent_message_id = 1;
    ok.parent_part_id = 0;
    try create(&db, ok);

    // Each missing mark fails the check.
    const missing = [_]struct { m: ?u64, p: ?u64 }{
        .{ .m = null, .p = 0 },
        .{ .m = 1, .p = null },
        .{ .m = null, .p = null },
    };
    for (missing, 0..) |case, i| {
        var bad = rootParams([_]u8{ 2, @intCast(i) } ++ [_]u8{0} ** 14, ws.id);
        bad.origin = "child";
        bad.parent_id = [_]u8{4} ** 16;
        bad.parent_message_id = case.m;
        bad.parent_part_id = case.p;
        try testing.expectError(error.ConstraintCheck, create(&db, bad));
    }
}

test "fork needs a source id and cron needs a job id" {
    var db = try testDb();
    defer db.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const ws = try workspace.resolve(&db, a, [_]u8{7} ** 16, "/w", "w", "/w");

    var fork = rootParams([_]u8{1} ** 16, ws.id);
    fork.origin = "fork";
    fork.source_id = [_]u8{5} ** 16;
    try create(&db, fork);

    var cron = rootParams([_]u8{2} ** 16, ws.id);
    cron.origin = "cron";
    cron.job_id = [_]u8{6} ** 16;
    try create(&db, cron);

    var bad_fork = rootParams([_]u8{3} ** 16, ws.id);
    bad_fork.origin = "fork"; // The fork has no source_id.
    try testing.expectError(error.ConstraintCheck, create(&db, bad_fork));
}

test "create rejects a missing workspace" {
    var db = try testDb();
    defer db.deinit();
    try testing.expectError(
        error.ConstraintForeignKey,
        create(&db, rootParams([_]u8{8} ** 16, [_]u8{9} ** 16)),
    );
}

test "an open run cannot exceed the run high-water mark" {
    var db = try testDb();
    defer db.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const ws = try workspace.resolve(&db, a, [_]u8{7} ** 16, "/w", "w", "/w");
    const id = [_]u8{3} ** 16;
    try create(&db, rootParams(id, ws.id));

    // run_id_high is 0, so an open run fails the mark check.
    const open =
        "UPDATE sessions SET open_run_id = 1, open_run_kind = 'turn', open_run_started_at_ms = 0 " ++
        "WHERE id = x'03030303030303030303030303030303'";
    try testing.expectError(error.ConstraintCheck, db.conn.execNoArgs(open));

    // Raise the mark, then the same open run passes.
    try db.conn.execNoArgs("BEGIN IMMEDIATE");
    try event.bumpIds(&db, a, id, .{ .run_id_high = 1 });
    try db.conn.execNoArgs("COMMIT");
    try db.conn.execNoArgs(open);
}

test "list pages newest first and count matches" {
    var db = try testDb();
    defer db.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const ws = try workspace.resolve(&db, a, [_]u8{7} ** 16, "/w", "w", "/w");
    for (0..3) |i| {
        var p = rootParams([_]u8{@as(u8, @intCast(i + 1))} ** 16, ws.id);
        p.created_at_ms = 100 + @as(u64, @intCast(i)) * 10;
        p.updated_at_ms = p.created_at_ms;
        try create(&db, p);
    }

    try testing.expectEqual(@as(u64, 3), try count(&db, a, .{}));

    const page1 = try list(&db, a, .{}, null, 2);
    try testing.expectEqual(@as(usize, 2), page1.len);
    try testing.expectEqual(@as(u64, 120), page1[0].updated_at_ms);
    try testing.expectEqual(@as(u64, 110), page1[1].updated_at_ms);

    const page2 = try list(&db, a, .{}, .{ .updated_at_ms = page1[1].updated_at_ms, .id = page1[1].id }, 2);
    try testing.expectEqual(@as(usize, 1), page2.len);
    try testing.expectEqual(@as(u64, 100), page2[0].updated_at_ms);
}

test "an empty list and a negative limit" {
    var db = try testDb();
    defer db.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqual(@as(usize, 0), (try list(&db, a, .{}, null, 10)).len);
    try testing.expectError(error.InvalidLimit, list(&db, a, .{}, null, -1));
}

test "the keyset tiebreaks equal timestamps by id descending" {
    var db = try testDb();
    defer db.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const ws = try workspace.resolve(&db, a, [_]u8{7} ** 16, "/w", "w", "/w");
    for (1..4) |i| {
        var p = rootParams([_]u8{@as(u8, @intCast(i))} ** 16, ws.id);
        p.created_at_ms = 100;
        p.updated_at_ms = 100; // equal timestamps force the id tiebreak
        try create(&db, p);
    }

    const page1 = try list(&db, a, .{}, null, 2);
    try testing.expectEqual(@as(u8, 3), page1[0].id[0]);
    try testing.expectEqual(@as(u8, 2), page1[1].id[0]);

    const page2 = try list(&db, a, .{}, .{ .updated_at_ms = 100, .id = page1[1].id }, 2);
    try testing.expectEqual(@as(usize, 1), page2.len);
    try testing.expectEqual(@as(u8, 1), page2[0].id[0]);
}

test "top_level excludes a child session" {
    var db = try testDb();
    defer db.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const ws = try workspace.resolve(&db, a, [_]u8{7} ** 16, "/w", "w", "/w");
    try create(&db, rootParams([_]u8{1} ** 16, ws.id));

    var child = rootParams([_]u8{2} ** 16, ws.id);
    child.origin = "child";
    child.parent_id = [_]u8{1} ** 16;
    child.parent_message_id = 1;
    child.parent_part_id = 0;
    try create(&db, child);

    try testing.expectEqual(@as(u64, 2), try count(&db, a, .{}));
    try testing.expectEqual(@as(u64, 1), try count(&db, a, .{ .top_level = true }));

    const top = try list(&db, a, .{ .top_level = true }, null, 10);
    try testing.expectEqual(@as(usize, 1), top.len);
    try testing.expectEqualStrings("root", top[0].origin);
}
