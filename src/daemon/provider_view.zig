//! Resolve the providers a user can actually pick, from three sources with one precedence rule:
//! `providers.json` always wins, then the cloud bundle, then the catalog for display data.
//! A provider appears only when a credential is configured for it.

const std = @import("std");
const wire = @import("wire");
const provider = @import("../provider/provider.zig");
const bundle = @import("../cloud/bundle.zig");
const cloud_catalog = @import("../cloud/catalog.zig");

const instance = provider.instance;
const EnvMap = std.process.Environ.Map;

const no_cost: cloud_catalog.Cost = .{ .input = null, .output = null, .cache_read = null, .cache_write = null };

/// One model in the shape both sources share. Every value the source omits stays null.
/// `flags` shapes the request; the cloud publishes none of them, so it keeps the defaults.
pub const ModelView = struct {
    id: []const u8,
    upstream_id: []const u8,
    name: []const u8,
    context_window: ?u64 = null,
    max_output_tokens: ?u64 = null,
    cost: cloud_catalog.Cost = no_cost,
    reasoning_levels: []const ?[]const u8 = &.{},
    flags: instance.ModelFlags = .{},
};

/// This route holds every value that one request needs. A provider that cannot be called has none.
/// The instance keeps the shape that `resolve.endpointUrl` and `resolve.authHeaders` already take.
pub const Route = struct {
    instance: instance.ProviderInstance,
    secret: provider.resolve.Secret,
};

/// One provider the daemon offers, after precedence.
pub const Resolved = struct {
    id: []const u8,
    name: []const u8,
    source: wire.enums.ProviderSource,
    state: wire.enums.ProviderState,
    models: []const ModelView,
    /// Null when a layer left the route incomplete, or the credential is dead.
    route: ?Route = null,
};

/// One model, and the provider that serves it.
pub const Match = struct {
    provider: *const Resolved,
    model: *const ModelView,
};

/// Resolve a `providerId/modelId` selector against the merged list.
pub fn resolveModel(rows: []const Resolved, qualified: []const u8) ?Match {
    const slash = std.mem.indexOfScalar(u8, qualified, '/') orelse return null;
    const provider_id = qualified[0..slash];
    const model_id = qualified[slash + 1 ..];
    for (rows) |*p| {
        if (!std.mem.eql(u8, p.id, provider_id)) continue;
        for (p.models) |*m| if (std.mem.eql(u8, m.id, model_id)) return .{ .provider = p, .model = m };
        return null; // The provider serves no model of that name.
    }
    return null;
}

/// The three layers a resolve reads. The catalog supplies a display name and the models that a
/// source does not carry itself.
pub const Sources = struct {
    local: ?*const provider.config.Loaded = null,
    cloud: ?bundle.Document = null,
    catalog: []const cloud_catalog.Provider = &.{},
    env: ?*const EnvMap = null,
};

/// Build the provider list. The result borrows `arena` and the sources.
pub fn resolve(arena: std.mem.Allocator, sources: Sources) ![]const Resolved {
    var out: std.ArrayList(Resolved) = .empty;

    // `providers.json` wins, so it goes first and later layers skip an id it already claimed.
    if (sources.local) |loaded| {
        for (loaded.providers) |p| {
            // A provider with no reachable key is not configured, so it is not offered.
            const secret = provider.config.resolveApiKey(p.auth.source, sources.env) catch continue;
            const from_catalog = findCatalog(sources.catalog, p.id);
            const route = localRoute(p, from_catalog, secret);
            try out.append(arena, .{
                .id = p.id,
                .name = if (from_catalog) |c| c.name else p.id,
                .source = .local,
                // A provider with no route cannot serve a turn, whatever its credential says.
                .state = if (route != null) .ready else .needs_login,
                .models = if (p.models.len != 0)
                    try localModels(arena, p.models)
                else
                    try catalogModels(arena, from_catalog),
                .route = route,
            });
        }
    }

    if (sources.cloud) |doc| {
        for (doc.providers) |p| {
            if (claimed(out.items, p.id)) continue;
            // A row with no credential is not configured. A dead one still shows, so the user
            // knows to log in again.
            if (!configured(p.auth)) continue;
            const route = bundleRoute(p);
            try out.append(arena, .{
                .id = p.id,
                .name = p.name,
                .source = .cloud,
                // A usable credential is not enough; an incomplete route still cannot serve a turn.
                .state = if (route != null) .ready else .needs_login,
                // The bundle carries its own models. Its id is an account slug, so it never
                // joins to a catalog id. An empty list means the cloud has not synced yet.
                .models = try bundleModels(arena, p.models),
                .route = route,
            });
        }
    }

    return out.items;
}

/// Build the route of a local provider. The file wins field by field; the catalog fills a null.
/// A field that neither layer supplies leaves the provider unroutable.
fn localRoute(p: provider.config.LocalProvider, from_catalog: ?cloud_catalog.Provider, secret: provider.resolve.Secret) ?Route {
    const base_url = p.base_url orelse (if (from_catalog) |c| c.base_url else null) orelse return null;
    const protocol = p.protocol orelse (if (from_catalog) |c| c.protocol else null) orelse return null;
    const header = p.auth.header orelse (if (from_catalog) |c| (if (c.auth) |a| a.header else null) else null) orelse return null;
    return .{
        .instance = .{
            .id = p.id,
            .base_url = base_url,
            .protocol = protocol,
            .auth = .{ .api_key = .{ .header = header, .source = p.auth.source } },
            .headers = p.headers,
            .cache = p.cache orelse (if (from_catalog) |c| c.cache else .unsupported),
        },
        .secret = secret,
    };
}

/// Build the route of a bundled provider. The bundle already carries every routing field.
fn bundleRoute(p: bundle.Provider) ?Route {
    if (!p.auth.usable()) return null;
    const base_url = p.base_url orelse return null;
    const protocol = p.protocol orelse return null;

    var auth: instance.Auth = undefined;
    var secret: provider.resolve.Secret = undefined;
    switch (p.auth.kind) {
        .api_key => {
            const key = p.auth.api_key orelse return null;
            auth = .{ .api_key = .{ .header = p.auth.header orelse return null, .source = .{ .literal = key } } };
            secret = .{ .api_key = key };
        },
        .oauth => {
            const token = p.auth.access_token orelse return null;
            const flow = p.auth.flow orelse return null;
            if (std.mem.eql(u8, flow, "codex")) {
                const account = p.auth.account_id orelse return null;
                auth = .{ .codex_oauth = .{ .access_token = token, .account_id = account } };
                secret = .{ .codex = .{ .access_token = token, .account_id = account } };
            } else if (std.mem.eql(u8, flow, "xai")) {
                auth = .{ .xai_oauth = .{ .access_token = token } };
                secret = .{ .xai = token };
            } else return null; // An unknown flow is not routable.
        },
    }

    return .{
        .instance = .{
            .id = p.id,
            .base_url = base_url,
            .protocol = protocol,
            .auth = auth,
            .headers = p.headers,
            .cache = p.cache,
        },
        .secret = secret,
    };
}

/// Return true when the row holds a credential, whether it works or not.
fn configured(auth: bundle.Auth) bool {
    return switch (auth.kind) {
        .api_key => auth.api_key != null or auth.status != .active,
        .oauth => true,
    };
}

fn claimed(rows: []const Resolved, id: []const u8) bool {
    for (rows) |r| if (std.mem.eql(u8, r.id, id)) return true;
    return false;
}

fn findCatalog(rows: []const cloud_catalog.Provider, id: []const u8) ?cloud_catalog.Provider {
    for (rows) |c| if (std.mem.eql(u8, c.id, id)) return c;
    return null;
}

fn catalogModels(arena: std.mem.Allocator, row: ?cloud_catalog.Provider) ![]const ModelView {
    const p = row orelse return &.{};
    const out = try arena.alloc(ModelView, p.models.len);
    for (p.models, 0..) |m, i| out[i] = .{
        .id = m.id,
        .upstream_id = m.upstream_id,
        .name = m.name,
        .context_window = m.limits.context_window,
        .max_output_tokens = m.limits.max_output_tokens,
        .cost = m.cost,
        .reasoning_levels = m.reasoning_levels,
        .flags = .{ .supports_tools = m.flags.supports_tools, .supports_vision = m.flags.supports_vision },
    };
    return out;
}

fn bundleModels(arena: std.mem.Allocator, models: []const bundle.Model) ![]const ModelView {
    const out = try arena.alloc(ModelView, models.len);
    for (models, 0..) |m, i| {
        var flags: instance.ModelFlags = .{};
        // The bundle publishes what it knows. An unknown capability keeps the default.
        if (m.flags.supports_tools) |v| flags.supports_tools = v;
        if (m.flags.supports_vision) |v| flags.supports_vision = v;
        out[i] = .{
            .id = m.id,
            .upstream_id = m.upstream_id,
            .name = m.name,
            .context_window = m.limits.context_window,
            .max_output_tokens = m.limits.max_output_tokens,
            .cost = m.cost,
            .reasoning_levels = m.reasoning_levels,
            .flags = flags,
        };
    }
    return out;
}

/// A local model binding carries no display name, so the id names it.
fn localModels(arena: std.mem.Allocator, models: []const instance.ModelBinding) ![]const ModelView {
    const out = try arena.alloc(ModelView, models.len);
    for (models, 0..) |m, i| out[i] = .{
        .id = m.id,
        .upstream_id = m.upstream_id,
        .name = m.id,
        .context_window = m.limits.context_window,
        .max_output_tokens = m.limits.max_output_tokens,
        .cost = .{ .input = m.cost.input, .output = m.cost.output, .cache_read = m.cost.cache_read, .cache_write = m.cost.cache_write },
        .flags = m.flags,
    };
    return out;
}

const testing = std.testing;

fn catalogRow(id: []const u8, name: []const u8, models: []const cloud_catalog.Model) cloud_catalog.Provider {
    return .{
        .id = id,
        .name = name,
        .base_url = "https://api.example/v1",
        .protocol = .openai_chat,
        .auth = .{ .kind = .api_key, .header = .authorization_bearer },
        .cache = .unsupported,
        .headers = &.{},
        .models = models,
    };
}

const catalog_model: cloud_catalog.Model = .{
    .id = "cm",
    .upstream_id = "cm",
    .name = "Catalog Model",
    .limits = .{ .context_window = 1000, .max_output_tokens = 100 },
    .cost = .{ .input = 1, .output = 2, .cache_read = null, .cache_write = null },
    .flags = .{ .supports_tools = true, .supports_vision = false },
    .reasoning = false,
    .reasoning_levels = &.{},
    .status = null,
};

test "a cloud provider takes its name, models and ready state from the bundle" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const doc = try bundle.decode(a,
        \\{"version":1,"catalog_rev":null,"providers":[{"id":"grok","public_id":"p1","name":"Grok",
        \\ "base_url":"https://api.x.ai/v1","protocol":"openai_chat","cache":"unsupported","headers":[],
        \\ "auth":{"kind":"oauth","flow":"xai","status":"active","access_token":"tok"},
        \\ "models":[{"id":"grok-5","upstream_id":"grok-5","name":"Grok 5",
        \\ "limits":{"context_window":256000,"max_output_tokens":null},
        \\ "cost":{"input":null,"output":null,"cache_read":null,"cache_write":null},
        \\ "flags":{},"reasoning":null,"reasoning_levels":[],"status":null}]}]}
    );

    const rows = try resolve(a, .{ .cloud = doc });
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqualStrings("Grok", rows[0].name);
    try testing.expectEqual(wire.enums.ProviderSource.cloud, rows[0].source);
    try testing.expectEqual(wire.enums.ProviderState.ready, rows[0].state);
    try testing.expectEqualStrings("grok-5", rows[0].models[0].id);
    // The bundle published no flags, so the model keeps the defaults.
    try testing.expect(rows[0].models[0].flags.supports_tools);
    try testing.expect(!rows[0].models[0].flags.supports_vision);
}

test "a dead grant still appears so the user can log in again" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const doc = try bundle.decode(a,
        \\{"version":1,"catalog_rev":null,"providers":[{"id":"codex","public_id":"p2","name":"Codex",
        \\ "base_url":"https://chatgpt.com/backend-api/codex","protocol":"openai_responses",
        \\ "cache":"unsupported","headers":[],
        \\ "auth":{"kind":"oauth","flow":"codex","status":"reauth_required","expires_at_ms":1},"models":[]}]}
    );

    const rows = try resolve(a, .{ .cloud = doc });
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqual(wire.enums.ProviderState.needs_login, rows[0].state);
}

test "a bundle provider never takes models from a catalog row of the same id" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const doc = try bundle.decode(a,
        \\{"version":1,"catalog_rev":null,"providers":[{"id":"acme","public_id":"p3","name":"Acme",
        \\ "base_url":"https://acme.example/v1","protocol":"openai_chat","cache":"unsupported","headers":[],
        \\ "auth":{"kind":"api_key","header":"authorization_bearer","status":"active","api_key":"k"},
        \\ "models":[]}]}
    );

    // The bundle id is an account slug and the catalog id is an overlay identity. A shared
    // spelling is a coincidence, so the catalog models must not leak into the bundle row.
    const rows = try resolve(a, .{ .cloud = doc, .catalog = &.{catalogRow("acme", "Acme", &.{catalog_model})} });
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqual(@as(usize, 0), rows[0].models.len);
    try testing.expect(rows[0].route != null); // It still routes; only the model list is empty.
}

test "providers.json wins over the same id in the bundle" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var loaded = try provider.config.loadBytes(testing.allocator,
        \\{"version":1,"providers":[{"id":"acme","base_url":"https://local.example/v1",
        \\ "protocol":"openai_chat","auth":{"api_key":{"header":"x_api_key","source":{"literal":"local-key"}}}}]}
    );
    defer loaded.deinit();

    const doc = try bundle.decode(a,
        \\{"version":1,"catalog_rev":null,"providers":[{"id":"acme","public_id":"p4","name":"Cloud Acme",
        \\ "base_url":"https://cloud.example/v1","protocol":"openai_chat","cache":"unsupported","headers":[],
        \\ "auth":{"kind":"api_key","header":"authorization_bearer","status":"active","api_key":"cloud-key"},
        \\ "models":[]}]}
    );

    const rows = try resolve(a, .{ .local = &loaded, .cloud = doc });
    try testing.expectEqual(@as(usize, 1), rows.len); // The cloud row is skipped, not duplicated.
    try testing.expectEqual(wire.enums.ProviderSource.local, rows[0].source);
}

test "a local provider with no key is not offered" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var loaded = try provider.config.loadBytes(testing.allocator,
        \\{"version":1,"providers":[{"id":"acme","base_url":"https://local.example/v1",
        \\ "protocol":"openai_chat","auth":{"api_key":{"header":"x_api_key","source":{"env":"ABSENT_KEY"}}}}]}
    );
    defer loaded.deinit();

    var env: EnvMap = .init(testing.allocator);
    defer env.deinit();

    const rows = try resolve(a, .{ .local = &loaded, .env = &env });
    try testing.expectEqual(@as(usize, 0), rows.len);
}

test "an empty setup resolves to nothing" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(@as(usize, 0), (try resolve(arena.allocator(), .{})).len);
}

test "an id and a key alone resolve a full route from the catalog" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // This is the whole entry: no base_url, no protocol, no header, no models.
    var loaded = try provider.config.loadBytes(testing.allocator,
        \\{"version":1,"providers":[{"id":"acme","api_key":"sk-minimal"}]}
    );
    defer loaded.deinit();

    const rows = try resolve(a, .{ .local = &loaded, .catalog = &.{catalogRow("acme", "Acme", &.{catalog_model})} });
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqualStrings("Acme", rows[0].name); // The catalog names it.

    const route = rows[0].route.?;
    try testing.expectEqualStrings("https://api.example/v1", route.instance.base_url);
    try testing.expectEqual(instance.Protocol.openai_chat, route.instance.protocol);
    try testing.expectEqual(instance.ApiKeyHeader.authorization_bearer, route.instance.auth.api_key.header);
    try testing.expectEqualStrings("sk-minimal", route.secret.api_key);

    // The models come from the catalog too, so the picker is complete.
    try testing.expectEqual(@as(usize, 1), rows[0].models.len);
    try testing.expectEqualStrings("cm", rows[0].models[0].id);
}

test "a local field beats the catalog field by field" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The file pins only the base_url; the protocol and the header still come from the catalog.
    var loaded = try provider.config.loadBytes(testing.allocator,
        \\{"version":1,"providers":[{"id":"acme","base_url":"https://pinned.example/v1","api_key":"k"}]}
    );
    defer loaded.deinit();

    const rows = try resolve(a, .{ .local = &loaded, .catalog = &.{catalogRow("acme", "Acme", &.{})} });
    const route = rows[0].route.?;
    try testing.expectEqualStrings("https://pinned.example/v1", route.instance.base_url);
    try testing.expectEqual(instance.Protocol.openai_chat, route.instance.protocol);
}

test "a minimal entry with no catalog row is offered but not routable" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var loaded = try provider.config.loadBytes(testing.allocator,
        \\{"version":1,"providers":[{"id":"unknown","api_key":"k"}]}
    );
    defer loaded.deinit();

    const rows = try resolve(a, .{ .local = &loaded });
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expect(rows[0].route == null); // Nothing supplies a url or a protocol.
    // The state never claims a provider is ready when no route can be built.
    try testing.expectEqual(wire.enums.ProviderState.needs_login, rows[0].state);
}

test "an active grant with an unknown flow shows but cannot be called" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const doc = try bundle.decode(a,
        \\{"version":1,"catalog_rev":null,"providers":[{"id":"future","public_id":"pf","name":"Future",
        \\ "base_url":"https://future.example/v1","protocol":"openai_chat","cache":"unsupported","headers":[],
        \\ "auth":{"kind":"oauth","flow":"something-new","status":"active","access_token":"tok"},
        \\ "models":[]}]}
    );

    const rows = try resolve(a, .{ .cloud = doc });
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expect(rows[0].route == null); // yuke cannot build auth for an unknown flow.
    try testing.expectEqual(wire.enums.ProviderState.needs_login, rows[0].state);
}

test "resolveModel finds a model through the merged list" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var loaded = try provider.config.loadBytes(testing.allocator,
        \\{"version":1,"providers":[{"id":"acme","api_key":"k"}]}
    );
    defer loaded.deinit();

    const rows = try resolve(a, .{ .local = &loaded, .catalog = &.{catalogRow("acme", "Acme", &.{catalog_model})} });

    // The model came from the catalog, so the old providers.json-only lookup would have missed it.
    const match = resolveModel(rows, "acme/cm").?;
    try testing.expectEqualStrings("acme", match.provider.id);
    try testing.expectEqualStrings("cm", match.model.upstream_id);

    try testing.expect(resolveModel(rows, "acme/absent") == null);
    try testing.expect(resolveModel(rows, "absent/cm") == null);
    try testing.expect(resolveModel(rows, "no-slash") == null);
}

test "a cloud oauth provider routes with its access token" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const doc = try bundle.decode(a,
        \\{"version":1,"catalog_rev":null,"providers":[{"id":"codex","public_id":"p9","name":"Codex",
        \\ "base_url":"https://chatgpt.com/backend-api/codex","protocol":"openai_responses",
        \\ "cache":"unsupported","headers":[],
        \\ "auth":{"kind":"oauth","flow":"codex","status":"active","access_token":"tok","account_id":"acct"},
        \\ "models":[]}]}
    );

    const rows = try resolve(a, .{ .cloud = doc });
    const route = rows[0].route.?;
    try testing.expectEqualStrings("tok", route.instance.auth.codex_oauth.access_token);
    try testing.expectEqualStrings("acct", route.secret.codex.account_id);
}
