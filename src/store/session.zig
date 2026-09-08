//! The session registry stores the primary session state.
//! The event log omits session.summary_changed, so this table is authoritative.

const std = @import("std");
const sql = @import("sql");
const Database = @import("store.zig").Database;
const queries_gen = @import("queries_gen.zig");

/// SessionSnapshot returns the summary for the client and the open-run marker.
pub const Snapshot = queries_gen.SessionSnapshot.Row;

pub const OpenRun = struct {
    id: u64,
    kind: []const u8,
    started_at_ms: u64,
};

/// Store one row of a session.list page. Every page variant selects the same columns.
pub const PageRow = queries_gen.SessionPageRecent.Row;

/// The session.list selector uses a filter only when its field has a value.
/// The top_level filter keeps roots and forks.
pub const Selector = struct {
    parent_id: ?[16]u8 = null,
    top_level: bool = false,
};

/// The cursor stores the last row that a page returned.
pub const Cursor = struct { updated_at_ms: u64, id: [16]u8 };

/// The create operation sets these fields. Their names match the InsertSession parameters.
pub const CreateParams = struct {
    id: [16]u8,
    root: []const u8,
    origin: []const u8,
    parent_id: ?[16]u8 = null,
    parent_message_id: ?u64 = null,
    parent_part_id: ?u64 = null,
    source_id: ?[16]u8 = null,
    profile: []const u8,
    model: []const u8,
    reasoning: []const u8,
    config_rev: u64,
    max_rounds: ?u64 = null,
    title: []const u8,
    agent: ?[]const u8 = null,
    name: ?[]const u8 = null,
    created_by_name: ?[]const u8 = null,
    created_by_version: ?[]const u8 = null,
    created_at_ms: u64,
    updated_at_ms: u64,
};

/// Insert a new session row. The schema accepts an origin only with its related id set.
pub fn create(db: *Database, params: CreateParams) !void {
    try db.queries.insert_session.exec(params);
}

/// Remove one session row. Each child table cascades. A child row and a fork row stay.
pub fn remove(db: *Database, id: [16]u8) !void {
    std.debug.assert(sql.inTransaction(db.conn));
    try db.queries.delete_session.exec(.{ .id = id });
}

/// List the sessions that `parent_id` spawned. A fork is not a child.
pub fn childIds(db: *Database, arena: std.mem.Allocator, parent_id: [16]u8) ![]const [16]u8 {
    var rows = try db.queries.session_child_ids.rows(.{ .parent_id = parent_id });
    defer rows.deinit();
    var out: std.ArrayList([16]u8) = .empty;
    while (try rows.next(arena)) |owned| try out.append(arena, owned.value.id);
    return out.items;
}

pub const PromptParts = @import("../session/prompt.zig").Parts;

pub fn promptParts(db: *Database, arena: std.mem.Allocator, id: [16]u8) !PromptParts {
    const row = (try db.queries.select_prompt_parts.maybeOne(arena, .{ .session_id = id })) orelse return error.MissingSessionPrompt;
    std.debug.assert(row.value.environment.len <= @import("proto").meta.limits.max_message_string_bytes);
    return .{ .base = row.value.base_prompt, .child_policy = row.value.child_policy, .environment = row.value.environment };
}

/// Render and store the exact parts; the caller owns the returned text.
pub fn setPrompt(db: *Database, arena: std.mem.Allocator, id: [16]u8, parts: PromptParts) ![]const u8 {
    const text = try parts.render(arena);
    errdefer arena.free(text);
    try db.queries.insert_prompt.exec(.{ .session_id = id, .prompt = text, .base_prompt = parts.base, .child_policy = parts.child_policy, .environment = parts.environment });
    return text;
}

/// Read the session's system prompt into `arena`, or return null when no prompt exists.
pub fn prompt(db: *Database, arena: std.mem.Allocator, id: [16]u8) !?[]const u8 {
    const row = (try db.queries.select_prompt.maybeOne(arena, .{ .session_id = id })) orelse return null;
    return row.value.prompt;
}

pub fn basePrompt(db: *Database, arena: std.mem.Allocator, id: [16]u8) ![]const u8 {
    const row = (try db.queries.select_base_prompt.maybeOne(arena, .{ .session_id = id })) orelse return error.MissingSessionPrompt;
    return row.value.base_prompt;
}

/// Report whether a session with `id` exists.
pub fn exists(db: *Database, arena: std.mem.Allocator, id: [16]u8) !bool {
    var row = (try db.queries.session_exists.maybeOne(arena, .{ .id = id })) orelse return false;
    defer row.deinit();
    return true;
}

/// Load one session summary into `arena`. Return null when no row exists.
pub fn snapshot(db: *Database, arena: std.mem.Allocator, id: [16]u8) !?Snapshot {
    const row = (try db.queries.session_snapshot.maybeOne(arena, .{ .id = id })) orelse return null;
    return row.value;
}

/// Return the complete open-run marker, or null when the session has no open run.
pub fn openRun(row: Snapshot) !?OpenRun {
    if (row.open_run_id == null and row.open_run_kind == null and row.open_run_started_at_ms == null) return null;
    if (row.open_run_id == null or row.open_run_kind == null or row.open_run_started_at_ms == null) return error.CorruptDatabase;
    return .{ .id = row.open_run_id.?, .kind = row.open_run_kind.?, .started_at_ms = row.open_run_started_at_ms.? };
}

/// Record the one open run for a session. Run inside the start transaction.
pub fn setOpenRun(db: *Database, arena: std.mem.Allocator, id: [16]u8, run_id: u64, kind: []const u8, started_at_ms: u64) !void {
    std.debug.assert(sql.inTransaction(db.conn));
    _ = try db.queries.set_open_run.one(arena, .{
        .id = id,
        .run_id = run_id,
        .kind = kind,
        .started_at_ms = started_at_ms,
    });
}

/// Clear the exact open run that a terminal event closes. Run inside the terminal transaction.
pub fn clearOpenRun(db: *Database, arena: std.mem.Allocator, id: [16]u8, run_id: u64, kind: []const u8, started_at_ms: u64) !void {
    std.debug.assert(sql.inTransaction(db.conn));
    _ = try db.queries.clear_open_run.one(arena, .{
        .id = id,
        .run_id = run_id,
        .kind = kind,
        .started_at_ms = started_at_ms,
    });
}

/// The first page seeks below this cursor. The schema bounds updated_at_ms to 2^53-1, so this
/// timestamp exceeds every stored row. The row-value predicate keeps one seekable form and admits all.
const first_page: Cursor = .{ .updated_at_ms = std.math.maxInt(i64), .id = [_]u8{0xFF} ** 16 };

/// Load one keyset page of the session list into `arena`, newest first. The result borrows `arena`.
/// The selector picks the index-seek variant: parent scope or recent rows.
pub fn list(db: *Database, arena: std.mem.Allocator, sel: Selector, cursor: ?Cursor, limit: i64) ![]PageRow {
    if (limit < 0) return error.InvalidLimit; // SQLite treats a negative LIMIT as unbounded.
    const c = cursor orelse first_page;

    var out: std.ArrayList(PageRow) = .empty;
    if (sel.parent_id) |p| {
        var it = try db.queries.session_page_parent.rows(.{
            .filter_parent_id = p,
            .top_level = sel.top_level,
            .cursor_updated_at_ms = c.updated_at_ms,
            .cursor_id = c.id,
            .limit = limit,
        });
        defer it.deinit();
        try collectPage(&it, arena, &out);
    } else {
        var it = try db.queries.session_page_recent.rows(.{
            .top_level = sel.top_level,
            .cursor_updated_at_ms = c.updated_at_ms,
            .cursor_id = c.id,
            .limit = limit,
        });
        defer it.deinit();
        try collectPage(&it, arena, &out);
    }
    return out.items;
}

/// Copy each variant row into one PageRow. All variants select the same columns in the same order.
fn collectPage(it: anytype, arena: std.mem.Allocator, out: *std.ArrayList(PageRow)) !void {
    while (try it.next(arena)) |row| try out.append(arena, asPageRow(row.value));
}

fn asPageRow(row: anytype) PageRow {
    if (@TypeOf(row) == PageRow) return row;
    var out: PageRow = undefined;
    inline for (@typeInfo(PageRow).@"struct".fields) |field| @field(out, field.name) = @field(row, field.name);
    return out;
}

/// Count the full view that the selector defines. The selector picks the same variant as `list`.
pub fn count(db: *Database, arena: std.mem.Allocator, sel: Selector) !u64 {
    if (sel.parent_id) |p| {
        const row = try db.queries.session_count_parent.one(arena, .{
            .filter_parent_id = p,
            .top_level = sel.top_level,
        });
        return row.value.total;
    }
    const row = try db.queries.session_count_recent.one(arena, .{ .top_level = sel.top_level });
    return row.value.total;
}

const testing = std.testing;
const event = @import("event.zig");

fn rootParams(id: [16]u8, root: []const u8) CreateParams {
    return .{
        .id = id,
        .root = root,
        .origin = "root",
        .profile = "default",
        .model = "opus",
        .reasoning = "high",
        .config_rev = 0,
        .title = "t",
        .created_at_ms = 100,
        .updated_at_ms = 100,
    };
}

test "create inserts a root session and exists finds it" {
    var db = try Database.openTest();
    defer db.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const id = [_]u8{3} ** 16;
    try create(&db, rootParams(id, "/w"));

    try testing.expect(try exists(&db, a, id));
    try testing.expect(!try exists(&db, a, [_]u8{9} ** 16));

    const snap = (try snapshot(&db, a, id)).?;
    try testing.expectEqualStrings("root", snap.origin);
    try testing.expectEqual(@as(u64, 0), snap.message_count);
    try testing.expect(snap.open_run_id == null);
    try testing.expect((try snapshot(&db, a, [_]u8{9} ** 16)) == null);
}

test "a root session rejects a stray parent id" {
    var db = try Database.openTest();
    defer db.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var params = rootParams([_]u8{3} ** 16, "/w");
    params.parent_id = [_]u8{4} ** 16; // A root must have no parent marks.
    try testing.expectError(error.ConstraintCheck, create(&db, params));
}

test "a child session needs all three parent marks" {
    var db = try Database.openTest();
    defer db.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // A valid child sets all three marks.
    var ok = rootParams([_]u8{1} ** 16, "/w");
    ok.origin = "child";
    ok.parent_id = [_]u8{4} ** 16;
    ok.parent_message_id = 1;
    ok.parent_part_id = 0;
    ok.name = "kid";
    try create(&db, ok);

    // Each absent mark fails the check.
    const missing = [_]struct { m: ?u64, p: ?u64 }{
        .{ .m = null, .p = 0 },
        .{ .m = 1, .p = null },
        .{ .m = null, .p = null },
    };
    for (missing, 0..) |case, i| {
        var bad = rootParams([_]u8{ 2, @intCast(i) } ++ [_]u8{0} ** 14, "/w");
        bad.origin = "child";
        bad.parent_id = [_]u8{4} ** 16;
        bad.parent_message_id = case.m;
        bad.parent_part_id = case.p;
        bad.name = "kid";
        try testing.expectError(error.ConstraintCheck, create(&db, bad));
    }
}

test "fork needs a source id" {
    var db = try Database.openTest();
    defer db.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var fork = rootParams([_]u8{1} ** 16, "/w");
    fork.origin = "fork";
    fork.source_id = [_]u8{5} ** 16;
    try create(&db, fork);

    var bad_fork = rootParams([_]u8{3} ** 16, "/w");
    bad_fork.origin = "fork"; // A fork must have a source_id.
    try testing.expectError(error.ConstraintCheck, create(&db, bad_fork));
}

test "create rejects an empty root" {
    var db = try Database.openTest();
    defer db.deinit();
    try testing.expectError(
        error.ConstraintCheck,
        create(&db, rootParams([_]u8{8} ** 16, "")),
    );
}

test "prompt reads a set prompt and null when absent" {
    var db = try Database.openTest();
    defer db.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const id = [_]u8{3} ** 16;
    try create(&db, rootParams(id, "/w"));

    try testing.expect((try prompt(&db, a, id)) == null); // No prompt row exists yet.
    _ = try setPrompt(&db, a, id, .{ .base = "be helpful", .child_policy = null, .environment = "" });
    try testing.expectEqualStrings("be helpful", (try prompt(&db, a, id)).?);
}

test "an open run cannot exceed the run high-water mark" {
    var db = try Database.openTest();
    defer db.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const id = [_]u8{3} ** 16;
    try create(&db, rootParams(id, "/w"));

    // run_id_high is 0, so the mark check rejects an open run.
    const open =
        "UPDATE sessions SET open_run_id = 1, open_run_kind = 'turn', open_run_started_at_ms = 0 " ++
        "WHERE id = x'03030303030303030303030303030303'";
    try testing.expectError(error.ConstraintCheck, db.conn.execNoArgs(open));

    // Raise the mark, then the same open run passes the check.
    try db.conn.execNoArgs("BEGIN IMMEDIATE");
    _ = try event.allocRunId(&db, a, id);
    try db.conn.execNoArgs("COMMIT");
    try db.conn.execNoArgs(open);
}

test "list pages newest first and count matches" {
    var db = try Database.openTest();
    defer db.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    for (0..3) |i| {
        var p = rootParams([_]u8{@as(u8, @intCast(i + 1))} ** 16, "/w");
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
    var db = try Database.openTest();
    defer db.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqual(@as(usize, 0), (try list(&db, a, .{}, null, 10)).len);
    try testing.expectError(error.InvalidLimit, list(&db, a, .{}, null, -1));
}

test "the keyset tiebreaks equal timestamps by id descending" {
    var db = try Database.openTest();
    defer db.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    for (1..4) |i| {
        var p = rootParams([_]u8{@as(u8, @intCast(i))} ** 16, "/w");
        p.created_at_ms = 100;
        p.updated_at_ms = 100; // Equal timestamps force the id tiebreak.
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
    var db = try Database.openTest();
    defer db.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try create(&db, rootParams([_]u8{1} ** 16, "/w"));

    var child = rootParams([_]u8{2} ** 16, "/w");
    child.origin = "child";
    child.parent_id = [_]u8{1} ** 16;
    child.parent_message_id = 1;
    child.parent_part_id = 0;
    child.name = "kid";
    try create(&db, child);

    try testing.expectEqual(@as(u64, 2), try count(&db, a, .{}));
    try testing.expectEqual(@as(u64, 1), try count(&db, a, .{ .top_level = true }));

    const top = try list(&db, a, .{ .top_level = true }, null, 10);
    try testing.expectEqual(@as(usize, 1), top.len);
    try testing.expectEqualStrings("root", top[0].origin);
}

test "the workspace and parent selectors filter and page" {
    var db = try Database.openTest();
    defer db.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const root_a = [_]u8{1} ** 16;
    try create(&db, rootParams(root_a, "/a"));
    try create(&db, rootParams([_]u8{2} ** 16, "/b"));

    var child = rootParams([_]u8{3} ** 16, "/a");
    child.origin = "child";
    child.parent_id = root_a;
    child.parent_message_id = 1;
    child.parent_part_id = 0;
    child.name = "kid";
    try create(&db, child);

    // The parent selector keeps only the children of root a.
    try testing.expectEqual(@as(u64, 1), try count(&db, a, .{ .parent_id = root_a }));
    const kids = try list(&db, a, .{ .parent_id = root_a }, null, 10);
    try testing.expectEqual(@as(usize, 1), kids.len);
    try testing.expectEqualStrings("child", kids[0].origin);
}

test "each list variant seeks its index and never sorts" {
    var db = try Database.openTest();
    defer db.deinit();

    try expectPlan(&db, queries_gen.SessionPageRecent.sql, "sessions_by_recent");
    try expectPlan(&db, queries_gen.SessionPageParent.sql, "sessions_by_parent");
}

/// Assert the planner SEARCHes `index` for the real generated query and adds no sort step.
/// SEARCH proves a subset seek; a plain SCAN or a temp b-tree would mean the keyset does not hold.
fn expectPlan(db: *Database, comptime query: [:0]const u8, index: []const u8) !void {
    var rows = try db.conn.rows("EXPLAIN QUERY PLAN " ++ query, .{});
    defer rows.deinit();
    var seeks_index = false;
    while (rows.next()) |row| {
        const detail = row.text(3);
        if (std.mem.indexOf(u8, detail, "SEARCH") != null and std.mem.indexOf(u8, detail, index) != null)
            seeks_index = true;
        try testing.expect(std.mem.indexOf(u8, detail, "USE TEMP B-TREE") == null);
    }
    if (rows.err) |err| return err;
    try testing.expect(seeks_index);
}

test "prompt components and the composed text survive a database restart" {
    const zqlite = @import("zqlite");
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory = path_buffer[0..try tmp.dir.realPath(testing.io, &path_buffer)];
    const path = try std.fmt.allocPrintSentinel(a, "{s}/session.db", .{directory}, 0);
    const id = [_]u8{9} ** 16;
    const parts: PromptParts = .{ .base = "base\n\nwith separators", .child_policy = "policy", .environment = "<environment>\nsession_start_date_utc: 2026-09-08\n</environment>" };
    const text = "base\n\nwith separators\n\npolicy\n\n<environment>\nsession_start_date_utc: 2026-09-08\n</environment>";
    {
        var db = try Database.open(try zqlite.open(path, zqlite.OpenFlags.Create | zqlite.OpenFlags.NoMutex));
        defer db.deinit();
        var tx = try db.begin();
        defer tx.deinit();
        try create(&db, rootParams(id, "/w"));
        try testing.expectEqualStrings(text, try setPrompt(&db, a, id, parts));
        try tx.commit();
    }
    var db = try Database.open(try zqlite.open(path, zqlite.OpenFlags.NoMutex));
    defer db.deinit();
    const saved = try promptParts(&db, a, id);
    try testing.expectEqualStrings(parts.base, saved.base);
    try testing.expectEqualStrings(parts.child_policy.?, saved.child_policy.?);
    try testing.expectEqualStrings(parts.environment, saved.environment);
    try testing.expectEqualStrings(text, (try prompt(&db, a, id)).?);
}
