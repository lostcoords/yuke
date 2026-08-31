//! The catalog snapshot. One row holds one provider and its models, and never a credential.

const std = @import("std");
const cloud_catalog = @import("feed.zig");
const Database = @import("../database/database.zig").Database;

pub const Provider = cloud_catalog.Provider;

const stringify_opts: std.json.Stringify.Options = .{ .emit_null_optional_fields = true };
const parse_opts: std.json.ParseOptions = .{ .ignore_unknown_fields = true };

/// Replace the stored rows in one transaction. The caller stores the ETag later.
pub fn replace(
    db: *Database,
    scratch: std.mem.Allocator,
    rows: []const Provider,
) !void {
    var tx = try db.begin();
    defer tx.deinit();

    try db.queries.delete_providers.exec(.{});
    for (rows) |p| {
        const data = try std.json.Stringify.valueAlloc(scratch, p, stringify_opts);
        defer scratch.free(data);
        try db.queries.insert_provider.exec(.{ .id = p.id, .data = data });
    }
    try tx.commit();
}

/// Return the stored row for one provider id, or null. The result borrows `arena`.
pub fn provider(db: *Database, arena: std.mem.Allocator, id: []const u8) !?Provider {
    const row = (try db.queries.select_provider.maybeOne(arena, .{ .id = id })) orelse return null;
    return try std.json.parseFromSliceLeaky(Provider, arena, row.value.data, parse_opts);
}

/// Store the ETag of the document that the live snapshot holds.
pub fn setEtag(db: *Database, value: []const u8) !void {
    try db.queries.set_etag.exec(.{ .v = value });
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

    try replace(&db, a, &.{sample("acme", &.{one_model})});
    try setEtag(&db, "etag-1");

    const got = (try provider(&db, a, "acme")).?;
    try testing.expectEqualStrings("acme", got.id);
    try testing.expect(got.protocol != null and got.auth != null);

    const m = got.models[0];
    try testing.expectEqualStrings("upstream-1", m.upstream_id);
    try testing.expectEqual(@as(u64, 128000), m.limits.context_window.?);
    try testing.expect(m.cost.cache_write == null); // A null price survives the round trip.
    try testing.expectEqualStrings("beta", m.status.?);
    try testing.expectEqualStrings("high", m.reasoning_levels[1].?);

    try testing.expectEqualStrings("etag-1", (try etag(&db, a)).?);
}

test "a second replace overwrites the prior snapshot" {
    var db = try Database.openTest();
    defer db.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try replace(&db, a, &.{ sample("p1", &.{}), sample("p2", &.{}) });
    try replace(&db, a, &.{sample("p2", &.{})});
    try setEtag(&db, "e2");

    try testing.expect((try provider(&db, a, "p1")) == null); // The replace dropped the old row.
    try testing.expectEqualStrings("p2", (try provider(&db, a, "p2")).?.id);
    try testing.expectEqualStrings("e2", (try etag(&db, a)).?);
}

test "an empty snapshot reads back with no rows" {
    var db = try Database.openTest();
    defer db.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expect((try provider(&db, a, "acme")) == null);
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
    try replace(&db, a, &.{row});

    const got = (try provider(&db, a, "unrouted")).?;
    try testing.expect(got.protocol == null);
    try testing.expectEqualStrings("unrouted", got.id);
}
