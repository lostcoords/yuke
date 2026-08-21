//! Provider/model catalog: health, list/refresh results, and skip reasons.

const std = @import("std");
const ids = @import("ids.zig");
const tagged = @import("tagged.zig");

/// Payload for `catalog.changed`.
pub const CatalogChangedData = struct {
    catalog_rev: ids.CatalogRev,
    health: CatalogHealth,
};

/// Catalog load health.
pub const CatalogHealth = struct {
    skipped: []const SkippedProvider,
    load_error: ?[]const u8 = null,
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
    health: CatalogHealth,
};

/// Client's revision is current; no catalog data included.
pub const CatalogListResultUnchanged = struct {
    catalog_rev: ids.CatalogRev,
};

/// Result of catalog.refresh.
pub const CatalogRefreshResult = struct {
    catalog_rev: ids.CatalogRev,
    health: CatalogHealth,
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

/// Providers skipped during catalog load. Non-owning.
pub const SkippedProvider = struct {
    provider: []const u8,
    reason: SkipReason,
};

/// Reason a provider was skipped.
pub const SkipReason = union(enum) {
    missing_credential: SkipReasonMissingCredential,
    invalid_config: SkipReasonInvalidConfig,

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

/// Provider config was invalid.
pub const SkipReasonInvalidConfig = struct {
    message: []const u8,
};

/// Required credential was absent.
pub const SkipReasonMissingCredential = struct {
    env: []const u8,
};

const testing = std.testing;
const opts: std.json.ParseOptions = .{ .ignore_unknown_fields = true };

test "catalog list result full round-trips with nested skip reason union" {
    // `load_error` is null → omitted on encode; input carries it as null to prove null decodes.
    const in =
        \\{"type":"full","catalog_rev":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","models":[],"health":{"skipped":[{"provider":"acme","reason":{"type":"missing_credential","env":"ACME_API_KEY"}}],"load_error":null}}
    ;
    const out =
        \\{"type":"full","catalog_rev":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","models":[],"health":{"skipped":[{"provider":"acme","reason":{"type":"missing_credential","env":"ACME_API_KEY"}}]}}
    ;
    const parsed = try std.json.parseFromSlice(CatalogListResult, testing.allocator, in, opts);
    defer parsed.deinit();
    try testing.expect(parsed.value == .full);
    try testing.expectEqual(@as(usize, 1), parsed.value.full.health.skipped.len);
    try testing.expect(parsed.value.full.health.skipped[0].reason == .missing_credential);
    try testing.expectEqualStrings("ACME_API_KEY", parsed.value.full.health.skipped[0].reason.missing_credential.env);

    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try std.json.Stringify.value(parsed.value, .{ .emit_null_optional_fields = false }, &buf.writer);
    try testing.expectEqualStrings(out, buf.written());
}

test "catalog list params optional since_rev defaults to null" {
    const parsed = try std.json.parseFromSlice(CatalogListParams, testing.allocator,
        \\{}
    , opts);
    defer parsed.deinit();
    try testing.expect(parsed.value.since_rev == null);
}
