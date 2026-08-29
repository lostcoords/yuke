//! The provider and model catalog and its list and refresh results.

const std = @import("std");
const ids = @import("ids.zig");
const enums = @import("enums.zig");
const tagged = @import("tagged.zig");

/// This payload describes `catalog.changed`.
pub const CatalogChangedData = struct {
    catalog_rev: ids.CatalogRev,
};

/// These are the parameters for `catalog.list`.
pub const CatalogListParams = struct {
    since_rev: ?ids.CatalogRev = null,
};

/// This result reports a catalog unchanged since `since_rev`, or a full catalog snapshot.
pub const CatalogListResult = union(enum) {
    unchanged: CatalogListResultUnchanged,
    full: CatalogListResultFull,

    /// Decode a tagged wire union from JSON.
    pub fn jsonParse(a: std.mem.Allocator, s: anytype, o: std.json.ParseOptions) !@This() {
        return tagged.jsonParse(@This(), a, s, o);
    }
    pub fn jsonParseFromValue(a: std.mem.Allocator, v: std.json.Value, o: std.json.ParseOptions) !@This() {
        return tagged.fromValue(@This(), a, v, o);
    }
    pub fn jsonStringify(self: @This(), jw: *std.json.Stringify) !void {
        return tagged.stringify(@This(), self, jw);
    }
};

/// The client sent a stale or absent revision, so the daemon returns the full catalog.
pub const CatalogListResultFull = struct {
    catalog_rev: ids.CatalogRev,
    providers: []const ProviderInfo,
    models: []const ModelInfo,
};

/// This type describes one configured provider. The daemon lists a provider that holds a
/// credential, so a client can tell a usable provider from one that needs a new login.
pub const ProviderInfo = struct {
    /// The left half of a `provider/model` selector.
    id: []const u8,
    name: []const u8,
    source: enums.ProviderSource,
    state: enums.ProviderState,
};

/// The client sent the current revision, so the daemon returns no catalog data.
pub const CatalogListResultUnchanged = struct {
    catalog_rev: ids.CatalogRev,
};

/// This result describes `catalog.refresh`.
pub const CatalogRefreshResult = struct {
    catalog_rev: ids.CatalogRev,
};

/// These costs use United States dollars per million tokens.
pub const ModelCost = struct {
    input: f64,
    output: f64,
    cache_read: f64,
    cache_write: f64,
};

/// This type exposes a closed projection of a provider model record. Its fields borrow their data.
pub const ModelInfo = struct {
    id: ids.ModelId,
    provider: []const u8,
    name: []const u8,
    context_window: u64,
    max_output_tokens: u64,
    reasoning_levels: []const []const u8,
    default_reasoning: []const u8,
    supports_vision: bool,
    supports_tools: bool,
    cost: ModelCost,
};

test "catalog list result full round-trips without availability state" {
    const testing = std.testing;
    const input =
        \\{"type":"full","catalog_rev":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","providers":[],"models":[]}
    ;
    const parsed = try std.json.parseFromSlice(CatalogListResult, testing.allocator, input, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value == .full);
    try testing.expectEqual(@as(usize, 0), parsed.value.full.models.len);

    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try std.json.Stringify.value(parsed.value, .{ .emit_null_optional_fields = false }, &buf.writer);
    try testing.expectEqualStrings(input, buf.written());
}
