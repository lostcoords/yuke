//! The workspace registry stores daemon-known execution environments; only local today.
//! The daemon mints each opaque id. A stable key deduplicates a persistent local root.

const std = @import("std");
const Database = @import("database.zig").Database;

/// A workspace row for a broadcast or a describe result.
pub const Workspace = struct {
    id: [16]u8,
    kind: []const u8,
    root: []const u8,
    title: []const u8,
};

/// Resolve returns the workspace id and whether it inserted the row.
pub const Resolved = struct { id: [16]u8, created: bool };

/// Find a workspace by its stable key or insert one with `new_id`.
/// An ephemeral workspace passes no stable key, so resolve always inserts it.
pub fn resolve(
    db: *Database,
    arena: std.mem.Allocator,
    new_id: [16]u8,
    root: []const u8,
    title: []const u8,
    stable_key: ?[]const u8,
) !Resolved {
    if (stable_key) |key| {
        if (try db.queries.workspace_by_stable_key.maybeOne(arena, .{ .kind = "local", .stable_key = key })) |row| {
            return .{ .id = row.value.id, .created = false };
        }
    }
    try db.queries.insert_workspace.exec(.{
        .id = new_id,
        .kind = "local",
        .root = root,
        .title = title,
        .stable_key = stable_key,
    });
    return .{ .id = new_id, .created = true };
}

/// Load one workspace by id into `arena`. Return null when no row exists. The result borrows `arena`.
pub fn byId(db: *Database, arena: std.mem.Allocator, id: [16]u8) !?Workspace {
    const row = (try db.queries.workspace_by_id.maybeOne(arena, .{ .id = id })) orelse return null;
    return .{ .id = row.value.id, .kind = row.value.kind, .root = row.value.root, .title = row.value.title };
}

const testing = std.testing;
const zqlite = @import("zqlite");

fn testDb() !Database {
    const conn = try zqlite.open(":memory:", zqlite.OpenFlags.Create | zqlite.OpenFlags.NoMutex | zqlite.OpenFlags.EXResCode);
    return Database.open(conn);
}

test "resolve inserts a new workspace and byId reads it back" {
    var db = try testDb();
    defer db.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const id = [_]u8{1} ** 16;
    const got = try resolve(&db, a, id, "/home/x", "x", "/home/x");
    try testing.expect(got.created);
    try testing.expectEqualSlices(u8, &id, &got.id);

    const ws = (try byId(&db, a, id)).?;
    try testing.expectEqualStrings("local", ws.kind);
    try testing.expectEqualStrings("/home/x", ws.root);
    try testing.expectEqualStrings("x", ws.title);

    try testing.expect((try byId(&db, a, [_]u8{9} ** 16)) == null); // no such id
}

test "resolve dedups a persistent root by stable_key" {
    var db = try testDb();
    defer db.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const first = try resolve(&db, a, [_]u8{1} ** 16, "/home/x", "x", "/home/x");
    const again = try resolve(&db, a, [_]u8{2} ** 16, "/home/x", "x", "/home/x");
    try testing.expect(first.created);
    try testing.expect(!again.created);
    try testing.expectEqualSlices(u8, &first.id, &again.id); // the second call reuses the first id
}

test "resolve never dedups an ephemeral workspace" {
    var db = try testDb();
    defer db.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const one = try resolve(&db, a, [_]u8{1} ** 16, "/tmp/a", "a", null);
    const two = try resolve(&db, a, [_]u8{2} ** 16, "/tmp/a", "a", null);
    try testing.expect(one.created and two.created);
    try testing.expect(!std.mem.eql(u8, &one.id, &two.id)); // both calls create rows with different ids
}
