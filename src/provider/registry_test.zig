//! Tests for the provider registry. They fix the two composition rules and the availability states.

const std = @import("std");
const proto = @import("proto");
const provider = @import("provider.zig");
const registry = @import("registry.zig");
const instance = provider.instance;
const catalog = provider.ai.catalog;

const resolve = registry.resolve;
const credential = registry.credential;
const EnvMap = std.process.Environ.Map;
const testing = std.testing;

fn catalogRow(id: []const u8, name: []const u8, models: []const registry.ModelSpec) catalog.Provider {
    return .{
        .id = id,
        .name = name,
        .auth = .{ .api_key = null },
        .route = .{
            .base_url = "https://api.example/v1",
            .protocol = .openai_chat,
            .auth = .{ .api_key = .authorization_bearer },
            .cache = .unsupported,
            .headers = &.{.{ .name = "x-catalog-version", .value = "1" }},
        },
        .models = models,
    };
}

const catalog_model: registry.ModelSpec = .{
    .id = "cm",
    .upstream_id = "cm",
    .name = "Catalog Model",
    .limits = .{ .context_window = 1000, .max_output_tokens = 100 },
    .cost = .{ .input = 1, .output = 2 },
    .caps = .{ .tools = true, .vision = false },
};

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

test "local model reasoning levels reach the registry" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var loaded = try provider.config.loadBytes(testing.allocator,
        \\{"version":1,"providers":[{"id":"ollama","base_url":"http://127.0.0.1:11434/v1","protocol":"openai_chat",
        \\ "models":[{"id":"qwen3","upstream_id":"qwen3:8b","limits":{"context_window":40960,"max_output_tokens":8192},
        \\ "reasoning_levels":[null,"high"],"flags":{"thinking_format":"qwen"}}]}]}
    );
    defer loaded.deinit();

    const rows = try resolve(arena.allocator(), .{ .local = &loaded });
    const model = rows[0].models[0];
    try testing.expectEqual(@as(usize, 2), model.reasoning_levels.len);
    try testing.expect(model.reasoning_levels[0] == .none);
    try testing.expectEqualStrings("high", model.reasoning_levels[1].named);
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
    try testing.expectEqual(proto.enums.ProviderState.needs_route, rows[0].availability.state());
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

test "a grant whose pinned header the file also names is never ready" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var loaded = try provider.config.loadBytes(testing.allocator,
        \\{"version":1,"providers":[{"id":"codex",
        \\ "headers":[{"name":"chatgpt-account-id","value":"mine"}],
        \\ "auth":{"oauth":{"access_token":"tok","account_id":"acct","expires_at_ms":9000000000000}}}]}
    );
    defer loaded.deinit();

    const rows = try resolve(arena.allocator(), .{ .local = &loaded, .catalog = &.{oauthCatalogRow("codex", "codex")} });
    // The flow pins this header, so every request would fail. A ready route must be a usable one.
    try testing.expectEqual(proto.enums.ProviderState.needs_route, rows[0].availability.state());
}

test "a catalog row the engine cannot build leaves the grant unroutable" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var loaded = try provider.config.loadBytes(testing.allocator,
        \\{"version":1,"providers":[{"id":"other","auth":{"oauth":{"access_token":"tok","expires_at_ms":9000000000000}}}]}
    );
    defer loaded.deinit();

    const rows = try resolve(arena.allocator(), .{ .local = &loaded, .catalog = &.{oauthCatalogRow("other", "wat")} });
    try testing.expectEqual(proto.enums.ProviderState.needs_route, rows[0].availability.state());
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
    try testing.expectEqual(proto.enums.ProviderState.needs_credential, rows[0].availability.state());
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
    try testing.expectEqual(proto.enums.ProviderState.needs_credential, rows[0].availability.state());
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
    try testing.expectEqual(proto.enums.ProviderState.needs_route, rows[0].availability.state());
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
    try testing.expectEqual(proto.enums.ProviderState.needs_credential, rows[0].availability.state());
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
fn oauthCatalogRow(id: []const u8, flow: []const u8) catalog.Provider {
    return .{
        .id = id,
        .name = id,
        .auth = .{ .oauth = flow },
        .route = .{
            .base_url = "https://api.example/v1",
            .protocol = .openai_responses,
            // Every grant presents a bearer, so the baked route names that header.
            .auth = .{ .api_key = .authorization_bearer },
            .cache = .unsupported,
        },
        .models = &.{},
    };
}

test "load composes the file over the real baked table" {
    // Every merge rule above is fixed on a hand-made row. This fixes only that `load` reads the real one.
    var loaded = try provider.config.loadBytes(testing.allocator,
        \\{"version":1,"providers":[{"id":"anthropic","api_key":"sk-baked"},
        \\ {"id":"openai-codex","auth":{"oauth":{"access_token":"tok","expires_at_ms":9000000000000}}}]}
    );
    defer loaded.deinit();

    var snapshot = try registry.Registry.load(testing.allocator, .{ .local = &loaded });
    defer snapshot.deinit();

    // A synthetic row could never produce this URL, so the route demonstrably came from the table.
    const keyed = registry.find(snapshot.rows, "anthropic").?;
    try testing.expectEqualStrings("https://api.anthropic.com/v1", keyed.availability.ready.instance.base_url);
    try testing.expect(keyed.models.len != 0); // The baked models reach the picker with no copy.

    // Stage 1 bakes this name. Without it the engine cannot start the login at all.
    try testing.expectEqualStrings("codex", registry.find(snapshot.rows, "openai-codex").?.login_flow.?);
}

test "the registry emits a bare selector and resolves it back" {
    var loaded = try provider.config.loadBytes(testing.allocator,
        \\{"version":1,"providers":[{"id":"openrouter","api_key":"sk-x"}]}
    );
    defer loaded.deinit();

    var snapshot = try registry.Registry.load(testing.allocator, .{ .local = &loaded });
    defer snapshot.deinit();

    // `lib/ai` owns the grammar; what the registry owns is emitting it and resolving it back.
    const selector = snapshot.models[0].selector;
    try testing.expect(std.mem.indexOfScalar(u8, selector, ':') == null);

    const match = snapshot.resolveModel(selector).?;
    try testing.expectEqualStrings("openrouter", match.provider.id);
    try testing.expectEqualStrings(selector["openrouter/".len..], match.model.id);

    try testing.expect(snapshot.resolveModel("openrouter/nope") == null);
    // The origin prefix is gone, so a selector stored in the old format resolves to nothing.
    try testing.expect(snapshot.resolveModel("local:openrouter/aion-labs/aion-2.0") == null);
}
