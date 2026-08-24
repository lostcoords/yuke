//! Provider/model catalog and list/refresh results.

const std = @import("std");
const ids = @import("ids.zig");
const tagged = @import("tagged.zig");

/// Payload for `catalog.changed`.
pub const CatalogChangedData = struct {
    catalog_rev: ids.CatalogRev,
};

/// Params for catalog.list.
pub const CatalogListParams = struct {
    since_rev: ?ids.CatalogRev = null,
};

/// Result of catalog.list: unchanged since `since_rev`, or a full catalog snapshot.
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

/// Client's revision was stale or absent; full catalog included.
pub const CatalogListResultFull = struct {
    catalog_rev: ids.CatalogRev,
    models: []const ModelInfo,
};

/// Client's revision is current; no catalog data included.
pub const CatalogListResultUnchanged = struct {
    catalog_rev: ids.CatalogRev,
};

/// Result of catalog.refresh.
pub const CatalogRefreshResult = struct {
    catalog_rev: ids.CatalogRev,
};

/// United States dollars per million tokens.
pub const ModelCost = struct {
    input: f64,
    output: f64,
    cache_read: f64,
    cache_write: f64,
};

/// Closed projection of a provider model record. Non-owning.
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
        \\{"type":"full","catalog_rev":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","models":[]}
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
