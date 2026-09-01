//! Decode the public provider catalog. This file never asserts on the document.

const std = @import("std");
const wire = @import("wire");
const provider = @import("../provider/provider.zig");

const instance = provider.instance;
const model = provider.model;

/// The document version this decoder accepts.
pub const version = 1;

const max_id_bytes = wire.ids.max_selector_part_bytes;
const max_name_bytes = 256;
const max_url_bytes = 2048;
const max_providers = 4096;
const max_models = 65536;

pub const Error = error{InvalidDocument};

pub const AuthKind = model.AuthKind;

/// The public authentication description. It names the scheme and never carries a credential.
pub const Auth = struct {
    kind: AuthKind,
    /// The API-key header. An OAuth provider leaves it null.
    header: ?instance.ApiKeyHeader = null,
    /// The OAuth flow name. An API-key provider leaves it null.
    flow: ?[]const u8 = null,
};

pub const Limits = model.Limits;
pub const Cost = model.Cost;

/// The catalog publishes model capabilities. The request-shape rules stay in the provider layer.
pub const Flags = struct {
    supports_tools: bool,
    supports_vision: bool,
    /// The OpenAI-chat thinking dialect. An unknown name degrades to no control.
    thinking_format: ?[]const u8 = null,
    /// How a prior assistant turn returns its reasoning on OpenAI-chat.
    reasoning_replay: ?[]const u8 = null,
    /// The output-token member an OpenAI-chat host accepts.
    max_tokens_field: ?[]const u8 = null,
    /// Compatible hosts take `adaptive` in place of a token budget.
    anthropic_adaptive: ?bool = null,
    reasoning_budget_min: ?i64 = null,
    reasoning_budget_max: ?u64 = null,
};

pub const Model = struct {
    id: []const u8,
    upstream_id: []const u8,
    name: []const u8,
    limits: Limits,
    cost: Cost,
    flags: Flags,
    reasoning: bool,
    /// A null level means no effort. The set is open, so a new name must degrade.
    reasoning_levels: []const ?[]const u8,
    /// A release stage such as `beta`. A generally available model leaves it null.
    status: ?[]const u8,
};

/// One catalog provider. A provider with no route keeps a null protocol and stays nameable.
pub const Provider = struct {
    id: []const u8,
    name: []const u8,
    base_url: ?[]const u8,
    protocol: ?instance.Protocol,
    auth: ?Auth,
    cache: instance.CachePolicy,
    headers: []const instance.Header,
    models: []const Model,
};

pub const Document = struct {
    version: u32,
    catalog_rev: []const u8,
    providers: []const Provider,
};

// The decoder ignores an unknown member and rejects a missing field that has no default.
const parse_options: std.json.ParseOptions = .{ .ignore_unknown_fields = true, .allocate = .alloc_always };

/// Decode the catalog document. The result borrows `arena`.
pub fn decode(arena: std.mem.Allocator, body: []const u8) Error!Document {
    const doc = std.json.parseFromSliceLeaky(Document, arena, body, parse_options) catch return error.InvalidDocument;

    if (doc.version != version) return error.InvalidDocument;
    if (!wire.ids.CatalogRev.validText(doc.catalog_rev)) return error.InvalidDocument;
    if (doc.providers.len > max_providers) return error.InvalidDocument;

    var models: usize = 0;
    for (doc.providers, 0..) |p, i| {
        if (!bounded(p.id, max_id_bytes) or !wire.ids.isSelectorPart(p.id)) return error.InvalidDocument;
        if (!bounded(p.name, max_name_bytes)) return error.InvalidDocument;
        // A duplicate id makes one selector ambiguous, so it never reaches the store.
        for (doc.providers[0..i]) |prev| if (std.mem.eql(u8, prev.id, p.id)) return error.InvalidDocument;
        if (p.base_url) |url| if (!bounded(url, max_url_bytes)) return error.InvalidDocument;

        // A route needs every part. A row that names a protocol without a target is malformed.
        if (p.protocol != null and p.base_url == null) return error.InvalidDocument;
        // `std.http.Client` asserts on a malformed header, so a bad one must never reach a route.
        if (!instance.validHeaders(p.headers)) return error.InvalidDocument;

        if (p.auth) |auth| switch (auth.kind) {
            .api_key => if (auth.header == null) return error.InvalidDocument,
            .oauth => if (auth.flow == null or auth.flow.?.len == 0) return error.InvalidDocument,
        };

        models += p.models.len;
        if (models > max_models) return error.InvalidDocument;
        for (p.models, 0..) |m, j| {
            // A model id is the right half of a selector, so it may hold a slash but no space.
            if (!wire.ids.isSelectorTail(m.id)) return error.InvalidDocument;
            if (!bounded(m.upstream_id, max_id_bytes)) return error.InvalidDocument;
            for (p.models[0..j]) |prev| if (std.mem.eql(u8, prev.id, m.id)) return error.InvalidDocument;
        }
    }
    return doc;
}

fn bounded(value: []const u8, max: usize) bool {
    return value.len != 0 and value.len <= max;
}

const testing = std.testing;

const routable_document =
    \\{"version":1,"catalog_rev":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","providers":[
    \\{"id":"anthropic","name":"Anthropic","base_url":"https://api.anthropic.com/v1",
    \\ "protocol":"anthropic_messages","auth":{"kind":"api_key","header":"x_api_key"},
    \\ "cache":"ephemeral","headers":[{"name":"anthropic-version","value":"2023-06-01"}],
    \\ "models":[{"id":"claude","upstream_id":"claude-5","name":"Claude","limits":{"context_window":200000,
    \\ "max_output_tokens":64000},"cost":{"input":3.0,"output":15.0,"cache_read":0.3,"cache_write":3.75},
    \\ "flags":{"supports_tools":true,"supports_vision":true},"reasoning":true,
    \\ "reasoning_levels":["low","high"],"status":null}]}]}
;

// OpenRouter names its models `vendor/model`, and the model half of a selector keeps that slash.
test "a model id with a slash decodes" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const doc = try decode(arena.allocator(),
        \\{"version":1,"catalog_rev":"00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000","providers":[{"id":"openrouter","name":"OpenRouter",
        \\ "base_url":"https://openrouter.ai/api/v1","protocol":"openai_chat","auth":{"kind":"api_key","header":"authorization_bearer"},
        \\ "cache":"unsupported","headers":[],"models":[{"id":"anthropic/claude-opus-5","upstream_id":"anthropic/claude-opus-5",
        \\ "name":"Opus","limits":{"context_window":null,"max_output_tokens":null},
        \\ "cost":{"input":null,"output":null,"cache_read":null,"cache_write":null},
        \\ "flags":{"supports_tools":true,"supports_vision":false},"reasoning":true,
        \\ "reasoning_levels":[],"status":null}]}]}
    );
    try testing.expectEqualStrings("anthropic/claude-opus-5", doc.providers[0].models[0].id);
}

test "decode reads a routable provider" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const doc = try decode(arena.allocator(), routable_document);
    try testing.expectEqual(@as(usize, 1), doc.providers.len);

    const p = doc.providers[0];
    try testing.expect(p.protocol != null and p.auth != null);
    try testing.expectEqual(instance.Protocol.anthropic_messages, p.protocol.?);
    try testing.expectEqual(instance.CachePolicy.ephemeral, p.cache);
    try testing.expectEqual(instance.ApiKeyHeader.x_api_key, p.auth.?.header.?);
    try testing.expectEqualStrings("anthropic-version", p.headers[0].name);

    const m = p.models[0];
    try testing.expectEqualStrings("claude-5", m.upstream_id);
    try testing.expectEqual(@as(u64, 200000), m.limits.context_window.?);
    try testing.expect(m.reasoning);
    try testing.expectEqual(@as(usize, 2), m.reasoning_levels.len);
    try testing.expect(m.status == null);
}

test "decode tolerates a null level, a null limit, and a null price" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    // The feed writes a null level, and publishes no price or limit for many models.
    const doc = try decode(arena.allocator(),
        \\{"version":1,"catalog_rev":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","providers":[
        \\{"id":"p","name":"P","base_url":"https://x","protocol":"openai_chat",
        \\ "auth":{"kind":"api_key","header":"authorization_bearer"},"cache":"unsupported","headers":[],
        \\ "models":[{"id":"m","upstream_id":"m","name":"M","limits":{"context_window":null,
        \\ "max_output_tokens":null},"cost":{"input":null,"output":null,"cache_read":null,"cache_write":null},
        \\ "flags":{"supports_tools":false,"supports_vision":false},"reasoning":true,
        \\ "reasoning_levels":[null,"low"],"status":"beta"}]}]}
    );
    const m = doc.providers[0].models[0];
    try testing.expect(m.limits.context_window == null);
    try testing.expect(m.cost.cache_write == null);
    try testing.expectEqual(@as(usize, 2), m.reasoning_levels.len);
    try testing.expect(m.reasoning_levels[0] == null);
    try testing.expectEqualStrings("low", m.reasoning_levels[1].?);
    try testing.expectEqualStrings("beta", m.status.?);
}

test "decode rejects a slash in a provider id" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.InvalidDocument, decode(arena.allocator(),
        \\{"version":1,"catalog_rev":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","providers":[
        \\ {"id":"bad/provider","name":"Bad","base_url":null,"protocol":null,"auth":null,
        \\ "cache":"unsupported","headers":[],"models":[]}]}
    ));
}

test "decode keeps an unroutable provider visible" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    // Most of the catalog looks like this: a name and models, but no way to call it.
    const doc = try decode(arena.allocator(),
        \\{"version":1,"catalog_rev":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","providers":[
        \\{"id":"someone","name":"Someone","base_url":null,"protocol":null,"auth":null,
        \\ "cache":"unsupported","headers":[],"models":[]}]}
    );
    const p = doc.providers[0];
    try testing.expect(p.protocol == null);
    try testing.expectEqualStrings("Someone", p.name);
}

test "decode ignores a new cloud field" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const doc = try decode(arena.allocator(),
        \\{"version":1,"catalog_rev":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","future_field":42,"providers":[
        \\{"id":"p","name":"P","base_url":null,"protocol":null,"auth":null,"cache":"unsupported",
        \\ "headers":[],"models":[],"another_new_one":"x"}]}
    );
    try testing.expectEqualStrings("p", doc.providers[0].id);
}

test "decode rejects a revision that is not a sha-512 hex digest" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.InvalidDocument, decode(arena.allocator(),
        \\{"version":1,"catalog_rev":"abc","providers":[]}
    ));
}

test "decode rejects a wrong version and a missing member" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectError(error.InvalidDocument, decode(a,
        \\{"version":2,"catalog_rev":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","providers":[]}
    ));
    // `cache` is guaranteed by the contract, so its absence is drift, not a default.
    try testing.expectError(error.InvalidDocument, decode(a,
        \\{"version":1,"catalog_rev":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","providers":[
        \\{"id":"p","name":"P","base_url":null,"protocol":null,"auth":null,"headers":[],"models":[]}]}
    ));
    try testing.expectError(error.InvalidDocument, decode(a, "not json"));
}

test "decode rejects an incomplete route and a bad auth" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A protocol with no base_url could never be called.
    try testing.expectError(error.InvalidDocument, decode(a,
        \\{"version":1,"catalog_rev":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","providers":[
        \\{"id":"p","name":"P","base_url":null,"protocol":"openai_chat","auth":null,
        \\ "cache":"unsupported","headers":[],"models":[]}]}
    ));
    // An api_key provider must name its header.
    try testing.expectError(error.InvalidDocument, decode(a,
        \\{"version":1,"catalog_rev":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","providers":[
        \\{"id":"p","name":"P","base_url":"https://x","protocol":"openai_chat","auth":{"kind":"api_key"},
        \\ "cache":"unsupported","headers":[],"models":[]}]}
    ));
}
