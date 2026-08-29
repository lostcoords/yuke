//! The provider catalog snapshot. One row holds one provider and its models, because the
//! executable catalog is small. The catalog names credentials; it never holds one.

const std = @import("std");
const cloud_catalog = @import("../cloud/catalog.zig");
const Database = @import("database.zig").Database;

pub const Provider = cloud_catalog.Provider;

const rev_one = "0123456789abcdef" ** 8;
const rev_two = "fedcba9876543210" ** 8;

const stringify_opts: std.json.Stringify.Options = .{ .emit_null_optional_fields = true };
const parse_opts: std.json.ParseOptions = .{ .ignore_unknown_fields = true };

/// Replace the snapshot in one transaction. The rows, the revision, and the etag commit together.
/// `scratch` holds each JSON blob until SQLite copies it.
pub fn replace(
    db: *Database,
    scratch: std.mem.Allocator,
    rows: []const Provider,
    revision: []const u8,
    etag_value: []const u8,
) !void {
    // The decoder accepts only a sha-512 hex digest, so a stored revision always converts back.
    std.debug.assert(revision.len == 128);

    var tx = try db.begin();
    defer tx.deinit();

    try db.queries.delete_providers.exec(.{});
    for (rows) |p| {
        const data = try std.json.Stringify.valueAlloc(scratch, p, stringify_opts);
        defer scratch.free(data);
        try db.queries.insert_provider.exec(.{ .id = p.id, .data = data });
    }
    try db.queries.set_rev.exec(.{ .v = revision });
    try db.queries.set_etag.exec(.{ .v = etag_value });

    try tx.commit();
}

/// Load every provider into `arena` in id order. The result borrows `arena`.
pub fn providers(db: *Database, arena: std.mem.Allocator) ![]const Provider {
    var it = try db.queries.select_providers.rows(.{});
    defer it.deinit();

    var out: std.ArrayList(Provider) = .empty;
    while (try it.next(arena)) |row| {
        try out.append(arena, try std.json.parseFromSliceLeaky(Provider, arena, row.value.data, parse_opts));
    }
    return out.items;
}

/// Return the stored revision from `arena`, or null. The result borrows `arena`.
pub fn rev(db: *Database, arena: std.mem.Allocator) !?[]const u8 {
    const row = (try db.queries.get_rev.maybeOne(arena, .{})) orelse return null;
    return row.value.v;
}

/// Return the stored etag from `arena`, or null. A conditional request sends it.
pub fn etag(db: *Database, arena: std.mem.Allocator) !?[]const u8 {
    const row = (try db.queries.get_etag.maybeOne(arena, .{})) orelse return null;
    return row.value.v;
}

const testing = std.testing;

fn sample(id: []const u8, models: []const cloud_catalog.Model) Provider {
    return .{
        .id = id,
        .name = "Sample",
        .base_url = "https://api.example/v1",
        .protocol = .openai_chat,
        .auth = .{ .kind = .api_key, .header = .authorization_bearer },
        .cache = .unsupported,
        .headers = &.{},
        .models = models,
    };
}

const one_model: cloud_catalog.Model = .{
    .id = "m1",
    .upstream_id = "upstream-1",
    .name = "Model One",
    .limits = .{ .context_window = 128000, .max_output_tokens = 8192 },
    .cost = .{ .input = 1.0, .output = 2.0, .cache_read = null, .cache_write = null },
    .flags = .{ .supports_tools = true, .supports_vision = false },
    .reasoning = true,
    .reasoning_levels = &.{ "low", "high" },
    .status = "beta",
};

test "a snapshot round-trips a provider with its models" {
    var db = try Database.openTest();
    defer db.deinit();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try replace(&db, a, &.{sample("acme", &.{one_model})}, rev_one, "etag-1");

    const got = try providers(&db, a);
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqualStrings("acme", got[0].id);
    try testing.expect(got[0].routable());

    const m = got[0].models[0];
    try testing.expectEqualStrings("upstream-1", m.upstream_id);
    try testing.expectEqual(@as(u64, 128000), m.limits.context_window.?);
    try testing.expect(m.cost.cache_write == null); // A null price survives the round trip.
    try testing.expectEqualStrings("beta", m.status.?);
    try testing.expectEqualStrings("high", m.reasoning_levels[1].?);

    try testing.expectEqualStrings(rev_one, (try rev(&db, a)).?);
    try testing.expectEqualStrings("etag-1", (try etag(&db, a)).?);
}

test "a second replace overwrites the prior snapshot" {
    var db = try Database.openTest();
    defer db.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try replace(&db, a, &.{ sample("p1", &.{}), sample("p2", &.{}) }, rev_one, "e1");
    try replace(&db, a, &.{sample("p2", &.{})}, rev_two, "e2");

    const got = try providers(&db, a);
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqualStrings("p2", got[0].id);
    try testing.expectEqualStrings(rev_two, (try rev(&db, a)).?);
    try testing.expectEqualStrings("e2", (try etag(&db, a)).?);
}

test "an empty snapshot reads back with no revision" {
    var db = try Database.openTest();
    defer db.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqual(@as(usize, 0), (try providers(&db, a)).len);
    try testing.expect((try rev(&db, a)) == null);
    try testing.expect((try etag(&db, a)) == null);
}

test "an unroutable provider survives storage" {
    var db = try Database.openTest();
    defer db.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var row = sample("unrouted", &.{});
    row.protocol = null;
    row.base_url = null;
    row.auth = null;
    try replace(&db, a, &.{row}, rev_one, "e1");

    const got = try providers(&db, a);
    try testing.expect(!got[0].routable());
    try testing.expectEqualStrings("unrouted", got[0].id);
}
