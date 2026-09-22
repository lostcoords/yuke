//! The baked provider table, and the helpers that turn one selector into a call.

const std = @import("std");
const generated = @import("catalog_gen.zig");
const call = @import("call.zig");
const model = @import("model.zig");
const route = @import("route.zig");

pub const Provider = generated.Provider;
pub const Auth = generated.Auth;
pub const providers = generated.providers;
pub const revision = generated.revision;
pub const find = generated.find;
pub const findModel = generated.findModel;

pub const Error = error{ MalformedSelector, UnknownProvider, UnknownModel };

/// The two halves of a `provider/model` selector.
pub const Selector = struct {
    provider: []const u8,
    model: []const u8,
};

/// Split `provider/model` on the first slash, because a model id may hold further slashes.
pub fn split(selector: []const u8) Error!Selector {
    const slash = std.mem.indexOfScalar(u8, selector, '/') orelse return Error.MalformedSelector;
    const parts: Selector = .{ .provider = selector[0..slash], .model = selector[slash + 1 ..] };
    if (parts.provider.len == 0 or parts.model.len == 0) return Error.MalformedSelector;
    return parts;
}

/// Resolve `provider/model` against the baked table, which lives for the whole program.
pub fn resolve(selector: []const u8, credential: route.Credential) Error!call.Model {
    const parts = try split(selector);
    const provider = find(parts.provider) orelse return Error.UnknownProvider;
    for (provider.models) |*spec| {
        if (!std.mem.eql(u8, spec.id, parts.model)) continue;
        // A gateway may rename a model, so the request sends the upstream id.
        return .{
            .id = spec.upstream_id,
            .route = routeFor(provider, spec),
            .credential = credential,
            .caps = spec.caps,
            .dialect = spec.dialect,
        };
    }
    return Error.UnknownModel;
}

/// Compose the route one model calls. The generator proves that each baked model names a declared endpoint with a credential.
fn routeFor(provider: *const Provider, spec: *const model.ModelSpec) route.Route {
    const endpoint = route.findEndpoint(provider.endpoints, spec.protocol).?;
    std.debug.assert(endpoint.key_header != null);
    return endpoint.route(provider.base_url, provider.headers, provider.session_header);
}

/// Bind this provider's key from the variable the catalog names, or answer null when it names none.
pub fn envCredential(provider: *const Provider, env: *const std.process.Environ.Map) ?route.Credential {
    // A grant needs a login flow, which this library never runs, so only an API key reads a variable.
    const name = switch (provider.auth) {
        .oauth => return null,
        .api_key => |named| named orelse return null,
    };
    const value = env.get(name) orelse return null;
    // An empty value is no value, so a blank variable never becomes a blank header.
    return if (value.len == 0) null else .{ .api_key = value };
}

const testing = std.testing;

test "a selector splits on the first slash" {
    const parts = try split("anthropic/claude-fable-5");
    try testing.expectEqualStrings("anthropic", parts.provider);
    try testing.expectEqualStrings("claude-fable-5", parts.model);

    // An OpenRouter model id holds its own slash, so only the first one divides the selector.
    const nested = try split("openrouter/amazon/nova-2-lite-v1");
    try testing.expectEqualStrings("openrouter", nested.provider);
    try testing.expectEqualStrings("amazon/nova-2-lite-v1", nested.model);

    // The baked table really does carry such ids, so the rule above is not a hypothetical.
    const row = find("openrouter").?;
    var buf: [512]u8 = undefined;
    const built = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ row.id, row.models[0].id });
    const real = try split(built);
    try testing.expectEqualStrings("openrouter", real.provider);
    try testing.expectEqualStrings(row.models[0].id, real.model);
    try testing.expect(std.mem.indexOfScalar(u8, real.model, '/') != null);

    try testing.expectError(Error.MalformedSelector, split("anthropic"));
    try testing.expectError(Error.MalformedSelector, split("/claude"));
    try testing.expectError(Error.MalformedSelector, split("anthropic/"));
}

test "a selector resolves against the baked table" {
    const row = &providers[0];
    var buf: [128]u8 = undefined;
    const selector = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ row.id, row.models[0].id });

    const resolved = try resolve(selector, .{ .api_key = "sk-test" });
    // The whole route reaches the call, so a dropped protocol or header fails here.
    try testing.expectEqualDeep(routeFor(row, &row.models[0]), resolved.route);
    try testing.expectEqualStrings("sk-test", resolved.credential.api_key);

    try testing.expectError(Error.UnknownProvider, resolve("nope/model", .none));
    try testing.expectError(Error.UnknownModel, resolve("anthropic/nope", .none));
}

test "a route takes the host fields from the provider and the path fields from the model's endpoint" {
    const gateway: Provider = .{
        .id = "gateway",
        .name = "Gateway",
        .auth = .{ .api_key = "GATEWAY_API_KEY" },
        .base_url = "https://gateway.test/v1",
        .session_header = .x_opencode_session,
        .headers = &.{.{ .name = "x-pinned", .value = "1" }},
        .endpoints = &.{
            .{ .protocol = .anthropic_messages, .key_header = .x_api_key, .cache = .anthropic_breakpoint },
            .{ .protocol = .openai_chat, .key_header = .authorization_bearer, .cache = .automatic },
        },
        .models = &.{
            .{ .id = "a", .upstream_id = "a", .name = "A", .protocol = .anthropic_messages },
            .{ .id = "c", .upstream_id = "c", .name = "C", .protocol = .openai_chat },
        },
    };

    // Two models on one host reach two paths, and the key header follows the path.
    const messages = routeFor(&gateway, &gateway.models[0]);
    try testing.expectEqual(route.Protocol.anthropic_messages, messages.protocol);
    try testing.expectEqual(route.ApiKeyHeader.x_api_key, messages.auth.api_key);
    try testing.expectEqual(@as(?route.CachePolicy, .anthropic_breakpoint), messages.cache);
    const chat = routeFor(&gateway, &gateway.models[1]);
    try testing.expectEqual(route.Protocol.openai_chat, chat.protocol);
    try testing.expectEqual(route.ApiKeyHeader.authorization_bearer, chat.auth.api_key);
    try testing.expectEqual(@as(?route.CachePolicy, .automatic), chat.cache);

    for ([_]route.Route{ messages, chat }) |composed| {
        try testing.expectEqualStrings("https://gateway.test/v1", composed.base_url);
        try testing.expectEqual(route.SessionHeader.x_opencode_session, composed.session_header);
        try testing.expectEqualStrings("x-pinned", composed.headers[0].name);
    }

    // Every baked provider composes without a gap, so a table with a model on no endpoint cannot ship.
    for (&providers) |*row| for (row.models) |*spec| {
        try testing.expectEqual(spec.protocol, routeFor(row, spec).protocol);
    };
}

test "catalog errors have a permanent user-facing classification" {
    const failure = @import("failure.zig");
    // A catalog error that classifies as unknown would hide a caller's selector mistake.
    inline for (@typeInfo(Error).error_set.?) |raised| {
        const got = failure.classify(@field(anyerror, raised.name));
        try testing.expectEqual(failure.Class.permanent, got.class);
        try testing.expect(got.reason != .unknown);
    }
}

test "the credential comes from the variable the catalog names" {
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try env.put("BLANK_KEY", "");
    try env.put("ACME_API_KEY", "sk-real");
    try env.put("ACME_RESOURCE_NAME", "acme-eu");

    const lone: Provider = .{
        .id = "acme",
        .name = "Acme",
        .auth = .{ .api_key = "ACME_API_KEY" },
        .base_url = "https://acme.test/v1",
        .endpoints = &.{.{ .protocol = .openai_chat, .key_header = .authorization_bearer }},
        .models = &.{},
    };
    try testing.expectEqualStrings("sk-real", envCredential(&lone, &env).?.api_key);

    // `azure` names a resource before its key, so the catalog names no single variable for it.
    var unnamed = lone;
    unnamed.auth = .{ .api_key = null };
    try testing.expect(envCredential(&unnamed, &env) == null);

    var unset = lone;
    unset.auth = .{ .api_key = "MISSING_KEY" };
    try testing.expect(envCredential(&unset, &env) == null);

    var blank = lone;
    blank.auth = .{ .api_key = "BLANK_KEY" };
    try testing.expect(envCredential(&blank, &env) == null);

    // A grant needs a login flow, which this library never runs, so it reads no variable.
    var oauth = lone;
    oauth.auth = .{ .oauth = "codex" };
    try testing.expect(envCredential(&oauth, &env) == null);
}

test "baked hosted search support remains specific to the provider and model" {
    const supported = try resolve("openai/gpt-5.4", .{ .api_key = "test-key" });
    const refused = try resolve("openai/gpt-5.4-nano", .{ .api_key = "test-key" });
    const codex = try resolve("openai-codex/gpt-5.4", .none);
    const claude = try resolve("anthropic/claude-opus-4-6", .{ .api_key = "test-key" });
    try testing.expectEqual(@as(?bool, true), supported.caps.hosted_tool_search);
    try testing.expectEqual(@as(?bool, false), refused.caps.hosted_tool_search);
    try testing.expectEqual(@as(?bool, null), codex.caps.hosted_tool_search);
    try testing.expectEqual(@as(?bool, true), claude.caps.hosted_tool_search);
    const request: call.Request = .{
        .blocks = &.{.{ .role = .user, .value = .{ .text = "read" } }},
        .options = .{ .tool_search = .hosted },
    };
    var prepared = try call.prepare(testing.allocator, supported, request);
    defer prepared.deinit();
    try testing.expect(std.mem.indexOf(u8, prepared.transport_request.body, "tool_search") != null);
    try testing.expectError(error.UnsupportedToolSearch, call.prepare(testing.allocator, refused, request));
    try testing.expectError(error.UnsupportedToolSearch, call.prepare(testing.allocator, codex, request));
}
