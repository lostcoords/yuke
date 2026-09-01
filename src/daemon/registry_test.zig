//! Tests for the provider registry. They fix the two composition rules and the availability states.

const std = @import("std");
const wire = @import("wire");
const provider = @import("../provider/provider.zig");
const bundle = @import("../cloud/bundle.zig");
const feed = @import("../catalog/feed.zig");
const registry = @import("registry.zig");
const instance = provider.instance;

const resolve = registry.resolve;
const credential = registry.credential;
const EnvMap = std.process.Environ.Map;
const testing = std.testing;

fn catalogRow(id: []const u8, name: []const u8, models: []const feed.Model) feed.Provider {
    return .{
        .id = id,
        .name = name,
        .base_url = "https://api.example/v1",
        .protocol = .openai_chat,
        .auth = .{ .kind = .api_key, .header = .authorization_bearer },
        .cache = .unsupported,
        .headers = &.{.{ .name = "x-catalog-version", .value = "1" }},
        .models = models,
    };
}

const catalog_model: feed.Model = .{
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
        \\{"version":1,"catalog_rev":null,"providers":[{"id":"grok","name":"Grok",
        \\ "base_url":"https://api.x.ai/v1","protocol":"openai_chat","cache":"unsupported","headers":[],
        \\ "auth":{"kind":"oauth","flow":"xai","status":"active","access_token":"tok"},
        \\ "models":[{"id":"grok-5","upstream_id":"grok-5","name":"Grok 5",
        \\ "limits":{"context_window":256000,"max_output_tokens":null},
        \\ "cost":{"input":null,"output":null,"cache_read":null,"cache_write":null},
        \\ "flags":{},"reasoning":null,"reasoning_levels":[],"status":null}]}]}
    );

    const rows = try resolve(a, .{ .account = doc });
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqualStrings("Grok", rows[0].name);
    try testing.expectEqual(wire.enums.ProviderSource.cloud, rows[0].origin);
    try testing.expectEqual(wire.enums.ProviderState.ready, rows[0].availability.state());
    try testing.expectEqualStrings("grok-5", rows[0].models[0].id);
    try testing.expect(rows[0].models[0].caps.tools == .unknown);
    try testing.expect(rows[0].models[0].caps.vision == .unknown);
}

test "a dead grant still appears with the reason it cannot serve" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const doc = try bundle.decode(a,
        \\{"version":1,"catalog_rev":null,"providers":[{"id":"codex","name":"Codex",
        \\ "base_url":"https://chatgpt.com/backend-api/codex","protocol":"openai_responses",
        \\ "cache":"unsupported","headers":[],
        \\ "auth":{"kind":"oauth","flow":"codex","status":"reauth_required","expires_at_ms":1},"models":[]}]}
    );

    const rows = try resolve(a, .{ .account = doc });
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqual(registry.Reason.expired, rows[0].availability.unavailable);
    try testing.expectEqual(wire.enums.ProviderState.expired, rows[0].availability.state());
}

test "a bundle provider never takes models from a catalog row of the same id" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const doc = try bundle.decode(a,
        \\{"version":1,"catalog_rev":null,"providers":[{"id":"acme","name":"Acme",
        \\ "base_url":"https://acme.example/v1","protocol":"openai_chat","cache":"unsupported","headers":[],
        \\ "auth":{"kind":"api_key","header":"authorization_bearer","status":"active","api_key":"k"},
        \\ "models":[]}]}
    );

    // A bundle row never takes the models of a catalog provider that shares its id.
    const rows = try resolve(a, .{ .account = doc, .catalog = &.{catalogRow("acme", "Acme", &.{catalog_model})} });
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqual(@as(usize, 0), rows[0].models.len);
    try testing.expect(rows[0].availability == .ready); // It still routes; only the model list is empty.
}

test "a local id and an account slug are separate namespaces" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var loaded = try provider.config.loadBytes(testing.allocator,
        \\{"version":1,"providers":[{"id":"acme","base_url":"https://local.example/v1",
        \\ "protocol":"openai_chat","auth":{"api_key":{"header":"x_api_key","source":{"literal":"local-key"}}}}]}
    );
    defer loaded.deinit();

    const doc = try bundle.decode(a,
        \\{"version":1,"catalog_rev":null,"providers":[{"id":"acme","name":"Cloud Acme",
        \\ "base_url":"https://cloud.example/v1","protocol":"openai_chat","cache":"unsupported","headers":[],
        \\ "auth":{"kind":"api_key","header":"authorization_bearer","status":"active","api_key":"cloud-key"},
        \\ "models":[]}]}
    );

    // The two origins are separate namespaces, so one id can name a row in each.
    const rows = try resolve(a, .{ .local = &loaded, .account = doc });
    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expectEqual(wire.enums.ProviderSource.local, rows[0].origin);
    try testing.expectEqualStrings("https://local.example/v1", rows[0].availability.ready.instance.base_url);
    try testing.expectEqual(wire.enums.ProviderSource.cloud, rows[1].origin);
    try testing.expectEqualStrings("https://cloud.example/v1", rows[1].availability.ready.instance.base_url);
}

test "a local provider with an absent environment key reports that it needs one" {
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

    // The entry stays visible, because a user who set the wrong variable name must see the reason.
    const rows = try resolve(a, .{ .local = &loaded, .env = &env });
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqual(registry.Reason.needs_credential, rows[0].availability.unavailable);
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

    const route = rows[0].availability.ready;
    try testing.expectEqualStrings("https://api.example/v1", route.instance.base_url);
    try testing.expectEqual(instance.Protocol.openai_chat, route.instance.protocol);
    try testing.expectEqual(instance.ApiKeyHeader.authorization_bearer, route.instance.auth.api_key);
    try testing.expectEqualStrings("sk-minimal", route.credential.literal);
    try testing.expectEqualStrings("x-catalog-version", route.instance.headers[0].name);

    // The models come from the catalog too, so the picker is complete.
    try testing.expectEqual(@as(usize, 1), rows[0].models.len);
    try testing.expectEqualStrings("cm", rows[0].models[0].id);
}

test "a local field beats the catalog field by field" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The file pins the base URL and clears the headers. Other route fields come from the catalog.
    var loaded = try provider.config.loadBytes(testing.allocator,
        \\{"version":1,"providers":[{"id":"acme","base_url":"https://pinned.example/v1","api_key":"k","headers":[]}]}
    );
    defer loaded.deinit();

    const rows = try resolve(a, .{ .local = &loaded, .catalog = &.{catalogRow("acme", "Acme", &.{})} });
    const route = rows[0].availability.ready;
    try testing.expectEqualStrings("https://pinned.example/v1", route.instance.base_url);
    try testing.expectEqual(instance.Protocol.openai_chat, route.instance.protocol);
    try testing.expectEqual(@as(usize, 0), route.instance.headers.len);
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
    try testing.expectEqual(registry.Reason.needs_route, rows[0].availability.unavailable);
    // The state never claims a provider is ready when no route can be built.
    try testing.expectEqual(wire.enums.ProviderState.needs_route, rows[0].availability.state());
}

test "an active grant with an unknown flow shows but cannot be called" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const doc = try bundle.decode(a,
        \\{"version":1,"catalog_rev":null,"providers":[{"id":"future","name":"Future",
        \\ "base_url":"https://future.example/v1","protocol":"openai_chat","cache":"unsupported","headers":[],
        \\ "auth":{"kind":"oauth","flow":"something-new","status":"active","access_token":"tok"},
        \\ "models":[]}]}
    );

    const rows = try resolve(a, .{ .account = doc });
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqual(registry.Reason.needs_route, rows[0].availability.unavailable); // yuke cannot build auth for an unknown flow.
    try testing.expectEqual(wire.enums.ProviderState.needs_route, rows[0].availability.state());
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
    const match = registry.findModel(rows, "local:acme/cm").?;
    try testing.expectEqualStrings("acme", match.provider.id);
    try testing.expectEqualStrings("cm", match.model.upstream_id);

    try testing.expect(registry.findModel(rows, "local:acme/absent") == null);
    try testing.expect(registry.findModel(rows, "local:absent/cm") == null);
    try testing.expect(registry.findModel(rows, "no-slash") == null);
    try testing.expect(registry.findModel(rows, "acme/cm") == null); // An unqualified selector names no origin.
    try testing.expect(registry.findModel(rows, "cloud:acme/cm") == null); // The row is local, not cloud.
}

/// The catalog row names the OAuth flow for a local provider.
fn oauthCatalogRow(id: []const u8, flow: []const u8) feed.Provider {
    return .{
        .id = id,
        .name = id,
        .base_url = "https://api.example/v1",
        .protocol = .openai_responses,
        .auth = .{ .kind = .oauth, .flow = flow },
        .cache = .unsupported,
        .headers = &.{},
        .models = &.{},
    };
}

test "a local codex grant routes with a bearer and its account header" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var loaded = try provider.config.loadBytes(testing.allocator,
        \\{"version":1,"providers":[{"id":"codex",
        \\ "auth":{"oauth":{"access_token":"tok","account_id":"acct","expires_at_ms":9000000000000}}}]}
    );
    defer loaded.deinit();

    const rows = try resolve(arena.allocator(), .{ .local = &loaded, .catalog = &.{oauthCatalogRow("codex", "codex")} });
    const route = rows[0].availability.ready;
    // The file stores only the grant, so the catalog row is what selects this shape.
    try testing.expectEqual(instance.ApiKeyHeader.authorization_bearer, route.instance.auth.api_key);
    try testing.expectEqual(instance.ResponsesDialect.codex, route.instance.responses_dialect);
    try testing.expectEqualStrings("tok", route.credential.oauth.grant.access_token);
    try testing.expectEqualStrings("ChatGPT-Account-ID", route.credential.oauth.grant.headers[0].name);
    try testing.expectEqualStrings("acct", route.credential.oauth.grant.headers[0].value);
}

test "a catalog row the daemon cannot build leaves the grant unroutable" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var loaded = try provider.config.loadBytes(testing.allocator,
        \\{"version":1,"providers":[{"id":"other","auth":{"oauth":{"access_token":"tok","expires_at_ms":9000000000000}}}]}
    );
    defer loaded.deinit();

    const rows = try resolve(arena.allocator(), .{ .local = &loaded, .catalog = &.{oauthCatalogRow("other", "wat")} });
    try testing.expectEqual(wire.enums.ProviderState.needs_route, rows[0].availability.state());
}

test "a lapsed grant presents no credential to a run" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var loaded = try provider.config.loadBytes(testing.allocator,
        \\{"version":1,"providers":[{"id":"xai",
        \\ "auth":{"oauth":{"access_token":"tok","expires_at_ms":1000}}}]}
    );
    defer loaded.deinit();

    var env = EnvMap.init(testing.allocator);
    defer env.deinit();
    const rows = try resolve(arena.allocator(), .{ .local = &loaded, .catalog = &.{oauthCatalogRow("xai", "xai")}, .env = &env });
    const route = rows[0].availability.ready;

    // The run reads the clock, so a grant that lapses needs no catalog rebuild.
    try testing.expect(credential(route.credential, &env, 999) != null);
    try testing.expect(credential(route.credential, &env, 1000) == null);
}

test "a cloud oauth provider routes with its access token" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const doc = try bundle.decode(a,
        \\{"version":1,"catalog_rev":null,"providers":[{"id":"codex","name":"Codex",
        \\ "base_url":"https://chatgpt.com/backend-api/codex","protocol":"openai_responses",
        \\ "cache":"unsupported","headers":[],
        \\ "auth":{"kind":"oauth","flow":"codex","status":"active","access_token":"tok","account_id":"acct"},
        \\ "models":[]}]}
    );

    const rows = try resolve(a, .{ .account = doc });
    const route = rows[0].availability.ready;
    // Every grant is a bearer, so the flow selects only the identity header and the dialect.
    try testing.expectEqual(instance.ApiKeyHeader.authorization_bearer, route.instance.auth.api_key);
    try testing.expectEqual(instance.ResponsesDialect.codex, route.instance.responses_dialect);
    try testing.expectEqualStrings("tok", route.credential.oauth.grant.access_token);
    try testing.expectEqualStrings("ChatGPT-Account-ID", route.credential.oauth.grant.headers[0].name);
    try testing.expectEqualStrings("acct", route.credential.oauth.grant.headers[0].value);
}

test "a lapsed cloud grant also presents no credential" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const doc = try bundle.decode(a,
        \\{"version":1,"catalog_rev":null,"providers":[{"id":"xai","name":"xAI",
        \\ "base_url":"https://api.x.ai/v1","protocol":"openai_chat","cache":"unsupported","headers":[],
        \\ "auth":{"kind":"oauth","flow":"xai","status":"active","access_token":"tok","expires_at_ms":1000},
        \\ "models":[]}]}
    );

    var env = EnvMap.init(testing.allocator);
    defer env.deinit();
    const rows = try resolve(a, .{ .account = doc });
    const route = rows[0].availability.ready;

    // The cloud states the expiry, so the run refuses the grant without waiting for a bundle refresh.
    try testing.expect(credential(route.credential, &env, 999) != null);
    try testing.expect(credential(route.credential, &env, 1000) == null);
}

test "an entry that names a key and holds none needs a credential" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var loaded = try provider.config.loadBytes(testing.allocator,
        \\{"version":1,"providers":[{"id":"acme","base_url":"https://acme.example/v1","protocol":"openai_chat",
        \\ "auth":{"api_key":{"header":"x_api_key"}}}]}
    );
    defer loaded.deinit();

    const rows = try resolve(arena.allocator(), .{ .local = &loaded });
    // The route is complete, so only the missing value keeps it from serving a turn.
    try testing.expectEqual(wire.enums.ProviderState.needs_credential, rows[0].availability.state());
}

test "a keyless entry routes with no credential" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var loaded = try provider.config.loadBytes(testing.allocator,
        \\{"version":1,"providers":[{"id":"ollama","base_url":"http://127.0.0.1:11434/v1","protocol":"openai_chat"}]}
    );
    defer loaded.deinit();

    const rows = try resolve(arena.allocator(), .{ .local = &loaded });
    const route = rows[0].availability.ready;
    try testing.expect(route.instance.auth == .none);
    try testing.expect(route.credential == .none);
}

test "a local entry with no credential never routes a catalog provider that needs one" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    // The file names only the id. The catalog supplies a complete API-key route.
    var loaded = try provider.config.loadBytes(testing.allocator,
        \\{"version":1,"providers":[{"id":"acme"}]}
    );
    defer loaded.deinit();

    const rows = try resolve(arena.allocator(), .{ .local = &loaded, .catalog = &.{catalogRow("acme", "Acme", &.{})} });
    // A ready row here would send an unauthenticated request to a paid endpoint.
    try testing.expectEqual(wire.enums.ProviderState.needs_credential, rows[0].availability.state());
}

test "a pinned header that shadows the catalog credential header is not ready" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    // The file pins Authorization, and the catalog names authorization_bearer for the credential.
    var loaded = try provider.config.loadBytes(testing.allocator,
        \\{"version":1,"providers":[{"id":"acme","api_key":"k","headers":[{"name":"Authorization","value":"other"}]}]}
    );
    defer loaded.deinit();

    const rows = try resolve(arena.allocator(), .{ .local = &loaded, .catalog = &.{catalogRow("acme", "Acme", &.{})} });
    // The loader cannot see the catalog header, so the merge must reject the collision.
    try testing.expectEqual(wire.enums.ProviderState.needs_route, rows[0].availability.state());
}

test "an empty environment value is no credential" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var loaded = try provider.config.loadBytes(testing.allocator,
        \\{"version":1,"providers":[{"id":"acme","base_url":"https://acme.example/v1","protocol":"openai_chat",
        \\ "auth":{"api_key":{"header":"x_api_key","source":{"env":"EMPTY_KEY"}}}}]}
    );
    defer loaded.deinit();

    var env = EnvMap.init(testing.allocator);
    defer env.deinit();
    try env.put("EMPTY_KEY", "");

    const rows = try resolve(arena.allocator(), .{ .local = &loaded, .env = &env });
    try testing.expectEqual(wire.enums.ProviderState.needs_credential, rows[0].availability.state());
    try testing.expect(credential(.{ .env = "EMPTY_KEY" }, &env, 0) == null);
}

test "an environment credential resolves through the production path" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var loaded = try provider.config.loadBytes(testing.allocator,
        \\{"version":1,"providers":[{"id":"acme","base_url":"https://acme.example/v1","protocol":"openai_chat",
        \\ "auth":{"api_key":{"header":"x_api_key","source":{"env":"ACME_KEY"}}}}]}
    );
    defer loaded.deinit();

    var env = EnvMap.init(testing.allocator);
    defer env.deinit();
    try env.put("ACME_KEY", "sk-from-env");

    const rows = try resolve(arena.allocator(), .{ .local = &loaded, .env = &env });
    const route = rows[0].availability.ready;
    // The row names the variable, and the run reads it again when it starts.
    try testing.expectEqualStrings("ACME_KEY", route.credential.env);
    try testing.expectEqualStrings("sk-from-env", credential(route.credential, &env, 0).?.api_key);
}
