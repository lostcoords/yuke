//! The models.dev catalog stores the current provider and model snapshot.
//! It stores credential names only. An unsupported protocol remains null.

const std = @import("std");
const provider = @import("../provider/provider.zig");
const Database = @import("database.zig").Database;

const instance = provider.instance;
pub const ModelBinding = instance.ModelBinding;
pub const Protocol = instance.Protocol;

/// Describe a provider and its credential variable names.
/// It stores no credential.
pub const CatalogProvider = struct {
    id: []const u8,
    models_dev_id: []const u8,
    name: []const u8,
    base_url: []const u8,
    protocol: ?Protocol = null,
    env: []const []const u8 = &.{},
};

/// Bind a model to its provider. The model id is unique in the catalog.
/// The models.dev decoder supplies the provider namespace.
pub const CatalogModel = struct {
    provider_id: []const u8,
    binding: ModelBinding,
};

const stringify_opts: std.json.Stringify.Options = .{ .emit_null_optional_fields = false };
const parse_opts: std.json.ParseOptions = .{ .ignore_unknown_fields = true };

fn loadRows(comptime T: type, arena: std.mem.Allocator, iterator: anytype) ![]const T {
    var out: std.ArrayList(T) = .empty;
    while (try iterator.next(arena)) |row| {
        try out.append(arena, try std.json.parseFromSliceLeaky(T, arena, row.value.data, parse_opts));
    }
    return out.items;
}

/// Replace the snapshot in one transaction. Deletes and inserts commit together or roll back.
/// `scratch` holds each JSON blob until SQLite copies it.
pub fn replace(
    db: *Database,
    scratch: std.mem.Allocator,
    provider_rows: []const CatalogProvider,
    model_rows: []const CatalogModel,
    etag_value: []const u8,
) !void {
    try db.conn.execNoArgs("BEGIN IMMEDIATE");
    errdefer db.conn.execNoArgs("ROLLBACK") catch {};

    try db.queries.delete_models.exec(.{});
    try db.queries.delete_providers.exec(.{});

    for (provider_rows) |p| {
        const data = try std.json.Stringify.valueAlloc(scratch, p, stringify_opts);
        defer scratch.free(data);
        try db.queries.insert_provider.exec(.{ .id = p.id, .data = data });
    }
    for (model_rows) |m| {
        const data = try std.json.Stringify.valueAlloc(scratch, m.binding, stringify_opts);
        defer scratch.free(data);
        try db.queries.insert_model.exec(.{ .id = m.binding.id, .provider_id = m.provider_id, .data = data });
    }
    try db.queries.set_etag.exec(.{ .v = etag_value });

    try db.conn.execNoArgs("COMMIT");
}

/// Load providers into `arena` in id order. The result borrows `arena`.
pub fn providers(db: *Database, arena: std.mem.Allocator) ![]const CatalogProvider {
    var it = try db.queries.select_providers.rows(.{});
    defer it.deinit();
    return loadRows(CatalogProvider, arena, &it);
}

/// Load models for `provider_id` into `arena` in id order. The result borrows `arena`.
pub fn models(db: *Database, arena: std.mem.Allocator, provider_id: []const u8) ![]const ModelBinding {
    var it = try db.queries.select_models.rows(.{ .provider_id = provider_id });
    defer it.deinit();
    return loadRows(ModelBinding, arena, &it);
}

/// Return the last feed etag from `arena`, or null. The result borrows `arena`.
pub fn etag(db: *Database, arena: std.mem.Allocator) !?[]const u8 {
    const row = (try db.queries.get_etag.maybeOne(arena, .{})) orelse return null;
    return row.value.v;
}

const testing = std.testing;
const sql = @import("sql");
const zqlite = @import("zqlite");

fn memoryConn() !sql.Connection {
    return zqlite.open(":memory:", zqlite.OpenFlags.Create | zqlite.OpenFlags.NoMutex | zqlite.OpenFlags.EXResCode);
}

test "a snapshot round-trips providers, models, and behavioral flags" {
    const conn = try memoryConn();
    var db = try Database.open(conn);
    defer db.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const in_providers = [_]CatalogProvider{
        .{ .id = "anthropic", .models_dev_id = "anthropic", .name = "Anthropic", .base_url = "https://api.anthropic.com/v1", .protocol = .@"anthropic-messages", .env = &.{"ANTHROPIC_API_KEY"} },
        .{ .id = "google", .models_dev_id = "google", .name = "Google", .base_url = "https://x", .protocol = null }, // Keep an unsupported protocol visible with null.
    };
    const in_models = [_]CatalogModel{
        .{ .provider_id = "anthropic", .binding = .{ .id = "opus", .upstream_id = "claude-opus-4-8", .limits = .{ .context_window = 200000, .max_output_tokens = 16000 }, .flags = .{ .anthropic_adaptive = true, .supports_vision = true } } },
        .{ .provider_id = "google", .binding = .{ .id = "gemini", .upstream_id = "gemini-3", .limits = .{ .context_window = 1000000, .max_output_tokens = 8192 } } },
    };
    try replace(&db, a, &in_providers, &in_models, "etag-1");

    const got_providers = try providers(&db, a);
    try testing.expectEqual(@as(usize, 2), got_providers.len);
    try testing.expectEqualStrings("anthropic", got_providers[0].id); // The query sorts by id.

    const anthropic_models = try models(&db, a, "anthropic");
    try testing.expectEqual(@as(usize, 1), anthropic_models.len);
    try testing.expectEqualStrings("claude-opus-4-8", anthropic_models[0].upstream_id);
    try testing.expect(anthropic_models[0].flags.anthropic_adaptive);
    try testing.expect(anthropic_models[0].flags.supports_vision);

    try testing.expectEqualStrings("etag-1", (try etag(&db, a)).?);
}

test "a second replace overwrites the prior snapshot" {
    const conn = try memoryConn();
    var db = try Database.open(conn);
    defer db.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try replace(&db, a, &.{.{ .id = "p1", .models_dev_id = "p1", .name = "P1", .base_url = "x", .protocol = .@"openai-completions" }}, &.{}, "e1");
    try replace(&db, a, &.{.{ .id = "p2", .models_dev_id = "p2", .name = "P2", .base_url = "y", .protocol = .@"openai-completions" }}, &.{}, "e2");

    const got = try providers(&db, a);
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqualStrings("p2", got[0].id);
    try testing.expectEqualStrings("e2", (try etag(&db, a)).?);
}

test "an unsupported provider is stored but marked null" {
    const conn = try memoryConn();
    var db = try Database.open(conn);
    defer db.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try replace(&db, a, &.{.{ .id = "google", .models_dev_id = "google", .name = "Google", .base_url = "x", .protocol = null }}, &.{}, "e");
    const got = try providers(&db, a);
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expect(got[0].protocol == null);
}
