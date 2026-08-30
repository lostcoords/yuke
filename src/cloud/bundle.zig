//! Decode the account provider bundle. This document carries live credentials, so the daemon holds
//! it in memory and never writes it down. It is the routing source; the catalog is for display.

const std = @import("std");
const wire = @import("wire");
const catalog = @import("catalog.zig");
const provider = @import("../provider/provider.zig");

const instance = provider.instance;

pub const version = 1;

const max_id_bytes = 128;
const max_name_bytes = 256;
const max_url_bytes = 2048;
const max_secret_bytes = 64 * 1024;
const max_providers = 1024;

pub const Error = error{InvalidDocument};

/// Whether the stored credential still works. It is the only liveness signal: a dead grant still
/// carries the expiry of the token it lost.
pub const Status = enum { active, reauth_required, revoked };

/// The credential for one provider. Every optional member is omitted rather than nulled, so an
/// absent member and a null member are different states.
pub const Auth = struct {
    kind: catalog.AuthKind,
    status: Status,
    /// Absent for a custom provider that pins no header.
    header: ?instance.ApiKeyHeader = null,
    /// Absent for a custom OAuth provider with no identity.
    flow: ?[]const u8 = null,
    /// Absent when no key is stored. This is reachable only when the status is not active.
    api_key: ?[]const u8 = null,
    /// Absent for a dead grant. The cloud owns every refresh, so this token is all the daemon gets.
    access_token: ?[]const u8 = null,
    expires_at_ms: ?u64 = null,
    account_id: ?[]const u8 = null,
};

/// The bundle publishes what it knows. An unknown capability stays null rather than a guess.
pub const Flags = struct {
    supports_tools: ?bool = null,
    supports_vision: ?bool = null,
    /// The OpenAI-chat thinking dialect. An unknown name degrades to no control.
    thinking_format: ?[]const u8 = null,
    /// Compatible hosts take `adaptive` in place of a token budget.
    anthropic_adaptive: ?bool = null,
    reasoning_budget_min: ?i64 = null,
    reasoning_budget_max: ?u64 = null,
};

/// One bundled model. The bundle is looser than the catalog: a model the feed does not describe
/// arrives with empty flags and a null `reasoning`.
pub const Model = struct {
    id: []const u8,
    upstream_id: []const u8,
    name: []const u8,
    limits: catalog.Limits,
    cost: catalog.Cost,
    flags: Flags = .{},
    reasoning: ?bool = null,
    reasoning_levels: []const ?[]const u8 = &.{},
    status: ?[]const u8 = null,
};

/// One credentialed provider. `public_id` is the stable key; `id` is the account's slug and only
/// the left half of a selector, so it never joins to a catalog id.
pub const Provider = struct {
    id: []const u8,
    public_id: []const u8,
    name: []const u8,
    base_url: ?[]const u8,
    protocol: ?instance.Protocol,
    cache: instance.CachePolicy,
    headers: []const instance.Header,
    auth: Auth,
    models: []const Model,
};

/// The bundle envelope. `catalog_rev` is null before the cloud's first catalog sync; the routing
/// fields stay correct, but every feed-sourced provider then carries no models.
pub const Document = struct {
    version: u32,
    catalog_rev: ?[]const u8,
    providers: []const Provider,
};

const parse_options: std.json.ParseOptions = .{ .ignore_unknown_fields = true };

/// Decode the bundle. The result borrows `arena` and holds credentials, so the caller wipes it.
pub fn decode(arena: std.mem.Allocator, body: []const u8) Error!Document {
    const doc = std.json.parseFromSliceLeaky(Document, arena, body, parse_options) catch return error.InvalidDocument;

    if (doc.version != version) return error.InvalidDocument;
    if (doc.catalog_rev) |rev| if (!catalog.validRev(rev)) return error.InvalidDocument;
    if (doc.providers.len > max_providers) return error.InvalidDocument;

    for (doc.providers, 0..) |p, i| {
        if (!bounded(p.id, max_id_bytes) or !wire.ids.isSelectorPart(p.id)) return error.InvalidDocument;
        if (!bounded(p.public_id, max_id_bytes)) return error.InvalidDocument;
        // A duplicate id or public id makes one selector ambiguous.
        for (doc.providers[0..i]) |prev| {
            if (std.mem.eql(u8, prev.id, p.id)) return error.InvalidDocument;
            if (std.mem.eql(u8, prev.public_id, p.public_id)) return error.InvalidDocument;
        }
        if (!bounded(p.name, max_name_bytes)) return error.InvalidDocument;
        if (p.base_url) |url| if (!bounded(url, max_url_bytes)) return error.InvalidDocument;
        if (p.protocol != null and p.base_url == null) return error.InvalidDocument;

        if (p.auth.api_key) |key| if (!bounded(key, max_secret_bytes)) return error.InvalidDocument;
        if (p.auth.access_token) |token| if (!bounded(token, max_secret_bytes)) return error.InvalidDocument;
        switch (p.auth.kind) {
            .api_key => if (p.auth.status == .active and p.auth.api_key == null) return error.InvalidDocument,
            .oauth => if (p.auth.status == .active and p.auth.access_token == null) return error.InvalidDocument,
        }

        for (p.models, 0..) |m, j| {
            // A model id is the right half of a selector, so it may hold a slash.
            if (!bounded(m.id, max_id_bytes)) return error.InvalidDocument;
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

test "decode reads an active api-key provider" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const doc = try decode(arena.allocator(),
        \\{"version":1,"catalog_rev":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        \\ "providers":[{"id":"anthropic","public_id":"abc123","name":"Anthropic",
        \\ "base_url":"https://api.anthropic.com/v1","protocol":"anthropic_messages","cache":"ephemeral",
        \\ "headers":[],"auth":{"kind":"api_key","header":"x_api_key","status":"active","api_key":"sk-live"},
        \\ "models":[]}]}
    );
    const p = doc.providers[0];
    try testing.expectEqualStrings("abc123", p.public_id);
    try testing.expectEqual(Status.active, p.auth.status);
    try testing.expectEqualStrings("sk-live", p.auth.api_key.?);
    try testing.expect(p.auth.access_token == null);
}

test "a dead grant keeps its expiry and drops its token" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    // `access_token` is omitted entirely, and status is the only liveness signal.
    const doc = try decode(arena.allocator(),
        \\{"version":1,"catalog_rev":null,"providers":[{"id":"grok","public_id":"p2","name":"Grok",
        \\ "base_url":"https://api.x.ai/v1","protocol":"openai_chat","cache":"unsupported","headers":[],
        \\ "auth":{"kind":"oauth","flow":"xai","status":"reauth_required","expires_at_ms":1700000000000,
        \\ "account_id":"acct-1"},"models":[]}]}
    );
    const p = doc.providers[0];
    try testing.expectEqual(Status.reauth_required, p.auth.status);
    try testing.expectEqual(@as(u64, 1700000000000), p.auth.expires_at_ms.?);
    try testing.expectEqualStrings("acct-1", p.auth.account_id.?);
    try testing.expect(doc.catalog_rev == null);
}

test "decode accepts a model the feed does not describe" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    // A new Codex model arrives with empty flags and a null `reasoning`.
    const doc = try decode(arena.allocator(),
        \\{"version":1,"catalog_rev":null,"providers":[{"id":"openai-codex","public_id":"p3","name":"Codex",
        \\ "base_url":"https://chatgpt.com/backend-api/codex","protocol":"openai_responses",
        \\ "cache":"unsupported","headers":[],
        \\ "auth":{"kind":"oauth","flow":"codex","status":"active","access_token":"tok","expires_at_ms":1},
        \\ "models":[{"id":"gpt-new","upstream_id":"gpt-new","name":"GPT New",
        \\ "limits":{"context_window":null,"max_output_tokens":null},
        \\ "cost":{"input":null,"output":null,"cache_read":null,"cache_write":null},
        \\ "flags":{},"reasoning":null,"reasoning_levels":[],"status":null}]}]}
    );
    const p = doc.providers[0];
    try testing.expectEqual(Status.active, p.auth.status);

    const m = p.models[0];
    try testing.expect(m.flags.supports_tools == null); // Unknown, not false.
    try testing.expect(m.flags.supports_vision == null);
    try testing.expect(m.reasoning == null);
    try testing.expect(m.limits.context_window == null);
}

test "a dead api-key provider may omit its key" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const doc = try decode(arena.allocator(),
        \\{"version":1,"catalog_rev":null,"providers":[{"id":"acme","public_id":"p4","name":"Acme",
        \\ "base_url":"https://acme.example/v1","protocol":"openai_chat","cache":"unsupported","headers":[],
        \\ "auth":{"kind":"api_key","header":"authorization_bearer","status":"revoked"},"models":[]}]}
    );
    try testing.expectEqual(Status.revoked, doc.providers[0].auth.status);
    try testing.expect(doc.providers[0].auth.api_key == null);
}

test "decode rejects a bad version, a bad revision, and an incomplete route" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectError(error.InvalidDocument, decode(a,
        \\{"version":2,"catalog_rev":null,"providers":[]}
    ));
    try testing.expectError(error.InvalidDocument, decode(a,
        \\{"version":1,"catalog_rev":"short","providers":[]}
    ));
    try testing.expectError(error.InvalidDocument, decode(a,
        \\{"version":1,"catalog_rev":null,"providers":[{"id":"x","public_id":"p","name":"X",
        \\ "base_url":null,"protocol":"openai_chat","cache":"unsupported","headers":[],
        \\ "auth":{"kind":"api_key","status":"active"},"models":[]}]}
    ));
    try testing.expectError(error.InvalidDocument, decode(a, "not json"));
}

test "decode rejects an active credential with no secret" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectError(error.InvalidDocument, decode(a,
        \\{"version":1,"catalog_rev":null,"providers":[{"id":"key","public_id":"p1","name":"Key",
        \\ "base_url":"https://key.example/v1","protocol":"openai_chat","cache":"unsupported","headers":[],
        \\ "auth":{"kind":"api_key","header":"authorization_bearer","status":"active"},"models":[]}]}
    ));
    try testing.expectError(error.InvalidDocument, decode(a,
        \\{"version":1,"catalog_rev":null,"providers":[{"id":"oauth","public_id":"p2","name":"OAuth",
        \\ "base_url":"https://oauth.example/v1","protocol":"openai_chat","cache":"unsupported","headers":[],
        \\ "auth":{"kind":"oauth","flow":"future","status":"active"},"models":[]}]}
    ));
}

test "decode rejects a slash in a provider id but keeps one in a model id" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectError(error.InvalidDocument, decode(a,
        \\{"version":1,"catalog_rev":null,"providers":[{"id":"bad/provider","public_id":"opaque/value","name":"Bad",
        \\ "base_url":null,"protocol":null,"cache":"unsupported","headers":[],
        \\ "auth":{"kind":"api_key","status":"revoked"},"models":[]}]}
    ));
    // OpenRouter names 408 of its models `vendor/model`. The selector splits on the first slash.
    const doc = try decode(a,
        \\{"version":1,"catalog_rev":null,"providers":[{"id":"provider","public_id":"opaque/value","name":"Ok",
        \\ "base_url":null,"protocol":null,"cache":"unsupported","headers":[],
        \\ "auth":{"kind":"api_key","status":"revoked"},"models":[{"id":"anthropic/claude-opus-5","upstream_id":"anthropic/claude-opus-5",
        \\ "name":"Opus","limits":{"context_window":null,"max_output_tokens":null},
        \\ "cost":{"input":null,"output":null,"cache_read":null,"cache_write":null}}]}]}
    );
    try testing.expectEqualStrings("anthropic/claude-opus-5", doc.providers[0].models[0].id);
}

test "an empty account decodes to no providers" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const doc = try decode(arena.allocator(),
        \\{"version":1,"catalog_rev":null,"providers":[]}
    );
    try testing.expectEqual(@as(usize, 0), doc.providers.len);
}
