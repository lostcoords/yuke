//! The session registry stores the primary session state and is authoritative because the event log omits `session.summary_changed`.

const std = @import("std");
const sql = @import("sql");
const Database = @import("store.zig").Database;
const instructions = @import("../session/instructions.zig");
const prompt_mod = @import("../session/prompt.zig");
const skills = @import("../session/skills.zig");
const instruction_types = @import("proto").instructions;
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

/// The session.list selector uses a filter only when its field has a value, and the top_level filter keeps roots and forks.
pub const Selector = struct {
    parent_id: ?[16]u8 = null,
    top_level: bool = false,
};

/// The cursor stores the last row that a page returned.
pub const Cursor = struct { updated_at_ms: u64, id: [16]u8 };

/// The generated insert type, which gives every optional column a null default.
pub const CreateParams = queries_gen.InsertSession.Params;

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

pub const Section = prompt_mod.Section;
pub const StoredPrompt = struct { text: []const u8, generation: u64 };

/// The stale generation. A run builds the prompt again when the stored value differs from the engine's.
pub const stale_generation: u64 = 0;

/// Render the stored sections, which are the only stored form of the prompt.
pub fn prompt(db: *Database, arena: std.mem.Allocator, id: [16]u8) !?StoredPrompt {
    const row = (try db.queries.select_prompt.maybeOne(arena, .{ .session_id = id })) orelse return null;
    return .{ .text = try prompt_mod.render(arena, try promptSections(db, arena, id)), .generation = row.value.generation };
}

pub fn promptSections(db: *Database, arena: std.mem.Allocator, id: [16]u8) ![]const Section {
    var rows = try db.queries.select_prompt_sections.rows(.{ .session_id = id });
    defer rows.deinit();
    var result: std.ArrayList(Section) = .empty;
    while (try rows.next(arena)) |row| try result.append(arena, .{ .key = row.value.key, .text = row.value.text });
    return result.items;
}

/// Store the sections under `generation` and return their rendered text; the caller owns the text.
pub fn setPrompt(db: *Database, arena: std.mem.Allocator, id: [16]u8, sections: []const Section, generation: u64) ![]const u8 {
    std.debug.assert(prompt_mod.valid(sections));
    const text = try prompt_mod.render(arena, sections);
    errdefer arena.free(text);
    try db.queries.replace_prompt.exec(.{ .session_id = id, .generation = generation });
    try db.queries.delete_prompt_sections.exec(.{ .session_id = id });
    for (sections, 0..) |section, position| try db.queries.insert_prompt_section.exec(.{ .session_id = id, .position = position, .key = section.key, .text = section.text });
    return text;
}

/// Store the file snapshots a new session starts from. Run inside the creation transaction.
pub fn setContext(db: *Database, id: [16]u8, sources: []const instructions.Snapshot, catalog: []const skills.Entry) !void {
    try insertSources(db, id, sources);
    try insertSkills(db, id, catalog);
}

/// Replace the two file snapshots and mark the prompt stale, so the next run builds it again. Run inside one transaction.
pub fn reloadContext(db: *Database, id: [16]u8, sources: []const instructions.Snapshot, catalog: []const skills.Entry) !void {
    std.debug.assert(sql.inTransaction(db.conn));
    try db.queries.delete_instructions.exec(.{ .session_id = id });
    try db.queries.delete_skills.exec(.{ .session_id = id });
    try insertSources(db, id, sources);
    try insertSkills(db, id, catalog);
    try db.queries.stale_prompt.exec(.{ .session_id = id });
}

fn insertSources(db: *Database, id: [16]u8, sources: []const instructions.Snapshot) !void {
    for (sources) |source| try db.queries.insert_instruction.exec(.{ .session_id = id, .scope = @tagName(source.source.scope), .path = source.source.path, .canonical_path = source.source.canonical_path, .content_hash = source.source.content_hash.raw, .text = source.text });
}

fn insertSkills(db: *Database, id: [16]u8, catalog: []const skills.Entry) !void {
    for (catalog) |entry| {
        std.debug.assert(skills.nameFault(entry.name) == null);
        try db.queries.insert_skill.exec(.{ .session_id = id, .name = entry.name, .description = entry.description, .scope = @tagName(entry.scope), .path = entry.path, .canonical_path = entry.canonical_path });
    }
}

/// Return the catalog snapshot of one session, sorted by name.
pub fn skillCatalog(db: *Database, arena: std.mem.Allocator, id: [16]u8) ![]const skills.Entry {
    var rows = try db.queries.select_skills.rows(.{ .session_id = id });
    defer rows.deinit();
    var result: std.ArrayList(skills.Entry) = .empty;
    while (try rows.next(arena)) |row| try result.append(arena, skillEntry(row.value));
    return result.items;
}

/// Return the catalog entry with `name`, or null when the session does not list it.
pub fn skill(db: *Database, arena: std.mem.Allocator, id: [16]u8, name: []const u8) !?skills.Entry {
    const row = (try db.queries.select_skill.maybeOne(arena, .{ .session_id = id, .name = name })) orelse return null;
    return skillEntry(row.value);
}

pub fn hasSkills(db: *Database, arena: std.mem.Allocator, id: [16]u8) !bool {
    var row = (try db.queries.session_has_skills.maybeOne(arena, .{ .session_id = id })) orelse return false;
    defer row.deinit();
    return true;
}

fn skillEntry(row: anytype) skills.Entry {
    const scope = std.meta.stringToEnum(instruction_types.InstructionScope, row.scope) orelse unreachable;
    std.debug.assert(skills.nameFault(row.name) == null);
    return .{ .name = row.name, .description = row.description, .scope = scope, .path = row.path, .canonical_path = row.canonical_path };
}

pub fn instructionSnapshots(db: *Database, arena: std.mem.Allocator, id: [16]u8) ![]const instructions.Snapshot {
    var rows = try db.queries.select_instructions.rows(.{ .session_id = id });
    defer rows.deinit();
    var result: std.ArrayList(instructions.Snapshot) = .empty;
    while (try rows.next(arena)) |row| try result.append(arena, .{ .source = instructionSource(row.value), .text = row.value.text });
    std.debug.assert(result.items.len <= 2);
    return result.items;
}

pub fn instructionSources(db: *Database, arena: std.mem.Allocator, id: [16]u8) ![]const instruction_types.InstructionSource {
    var rows = try db.queries.select_instruction_sources.rows(.{ .session_id = id });
    defer rows.deinit();
    var result: std.ArrayList(instruction_types.InstructionSource) = .empty;
    while (try rows.next(arena)) |row| try result.append(arena, instructionSource(row.value));
    std.debug.assert(result.items.len <= 2);
    return result.items;
}

fn instructionSource(row: anytype) instruction_types.InstructionSource {
    const scope = std.meta.stringToEnum(instruction_types.InstructionScope, row.scope) orelse unreachable;
    std.debug.assert(row.path.len > 0 and row.canonical_path.len > 0);
    return .{ .scope = scope, .path = row.path, .canonical_path = row.canonical_path, .content_hash = .bytes(row.content_hash) };
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

/// The first page seeks below this cursor. The schema bounds updated_at_ms to 2^53-1, so this value exceeds every row and the one seek form admits all.
const first_page: Cursor = .{ .updated_at_ms = std.math.maxInt(i64), .id = [_]u8{0xFF} ** 16 };

/// Load one keyset page of the session list into `arena`, newest first; the result borrows `arena`, and the selector picks the parent-scope or recent-row index-seek variant.
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

/// Both index variants return the same generated row type.
fn collectPage(it: anytype, arena: std.mem.Allocator, out: *std.ArrayList(PageRow)) !void {
    while (try it.next(arena)) |row| try out.append(arena, row.value);
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
const builtin = @import("builtin");
const zqlite = @import("zqlite");

/// Insert the one root session that every store and engine test seeds.
pub fn seedSession(db: *Database, id: [16]u8) !void {
    std.debug.assert(builtin.is_test);
    try create(db, rootParams(id, "/w"));
}

fn rootParams(id: [16]u8, root: []const u8) CreateParams {
    return .{
        .id = id,
        .root = root,
        .origin = "root",
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

test "prompt reads a set prompt and null when absent" {
    var db = try Database.openTest();
    defer db.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const id = [_]u8{3} ** 16;
    try create(&db, rootParams(id, "/w"));

    try testing.expect((try prompt(&db, a, id)) == null); // No prompt row exists yet.
    _ = try setPrompt(&db, a, id, &.{.{ .key = "base", .text = "be helpful" }}, 3);
    try testing.expectEqualStrings("be helpful", (try prompt(&db, a, id)).?.text);
    try testing.expectEqual(@as(u64, 3), (try prompt(&db, a, id)).?.generation);
}

test "list rejects a bad limit, answers empty, then pages newest first" {
    var db = try Database.openTest();
    defer db.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqual(@as(usize, 0), (try list(&db, a, .{}, null, 10)).len);
    try testing.expectError(error.InvalidLimit, list(&db, a, .{}, null, -1));

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

test "the top_level and parent selectors filter and count" {
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

    try testing.expectEqual(@as(u64, 3), try count(&db, a, .{}));

    // top_level drops the child and keeps both roots.
    try testing.expectEqual(@as(u64, 2), try count(&db, a, .{ .top_level = true }));
    const tops = try list(&db, a, .{ .top_level = true }, null, 10);
    try testing.expectEqual(@as(usize, 2), tops.len);
    for (tops) |row| try testing.expectEqualStrings("root", row.origin);

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

/// Assert that the planner SEARCHes `index` for the generated query with no sort step. A SCAN or a temp B-tree means the keyset does not hold.
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

test "prompt sections and the composed text survive a database restart, and a reload marks them stale" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const directory = path_buffer[0..try tmp.dir.realPath(testing.io, &path_buffer)];
    const path = try std.fmt.allocPrintSentinel(a, "{s}/session.db", .{directory}, 0);
    const id = [_]u8{9} ** 16;
    const sections = [_]Section{ .{ .key = "base", .text = "base\n\nwith separators" }, .{ .key = "agent", .text = "policy" }, .{ .key = "environment", .text = "<environment>\nsession_start_date_utc: 2026-09-08\n</environment>" } };
    const sources = [_]instructions.Snapshot{.{ .source = .{ .scope = .workspace, .path = "/w/AGENTS.md", .canonical_path = "/w/AGENTS.md", .content_hash = .bytes(.{42} ** 32) }, .text = "literal ${workspace}" }};
    const text = try prompt_mod.render(a, &sections);
    {
        var db = try Database.open(try zqlite.open(path, zqlite.OpenFlags.Create | zqlite.OpenFlags.NoMutex));
        defer db.deinit();
        var tx = try db.begin();
        defer tx.deinit();
        try create(&db, rootParams(id, "/w"));
        try setContext(&db, id, &sources, &.{});
        try testing.expectEqualStrings(text, try setPrompt(&db, a, id, &sections, 7));
        try tx.commit();
    }
    var db = try Database.open(try zqlite.open(path, zqlite.OpenFlags.NoMutex));
    defer db.deinit();
    const saved = try promptSections(&db, a, id);
    try testing.expectEqual(@as(usize, 3), saved.len);
    try testing.expectEqualStrings("agent", saved[1].key);
    try testing.expectEqualStrings("policy", saved[1].text);
    try testing.expectEqualStrings(text, (try prompt(&db, a, id)).?.text);
    try testing.expectEqual(@as(u64, 7), (try prompt(&db, a, id)).?.generation);
    const restored = try instructionSnapshots(&db, a, id);
    try testing.expectEqual(@as(usize, 1), restored.len);
    try testing.expectEqualStrings(sources[0].text, restored[0].text);
    {
        var tx = try db.begin();
        defer tx.deinit();
        try reloadContext(&db, id, &.{}, &.{});
        try tx.commit();
    }
    try testing.expectEqual(stale_generation, (try prompt(&db, a, id)).?.generation);
    try testing.expectEqual(@as(usize, 0), (try instructionSnapshots(&db, a, id)).len);
}
