//! The baked provider table, and the lookup that turns one selector into a call model.

const std = @import("std");
const generated = @import("catalog_gen.zig");
const call = @import("call.zig");
const model = @import("model.zig");
const route = @import("route.zig");
const failure = @import("failure.zig");

pub const Provider = generated.Provider;
pub const Auth = generated.Auth;
pub const providers = generated.providers;
pub const revision = generated.revision;
pub const find = generated.find;

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

/// One catalog model and the provider that serves it. Both live for the whole program.
pub const Entry = struct {
    provider: *const Provider,
    spec: *const model.ModelSpec,

    /// Compose the route this model calls: the host fields, and the path fields of the model's endpoint.
    pub fn compose(self: Entry) route.Route {
        // The generator proves that each baked model names a declared endpoint.
        const endpoint = route.findEndpoint(self.provider.endpoints, self.spec.protocol).?;
        return endpoint.route(self.provider.base_url, self.provider.headers, self.provider.session_header);
    }

    /// Bind this model to a credential. The wire carries the upstream id, because a gateway may rename a model.
    pub fn bind(self: Entry, credential: route.Credential) call.Model {
        return .{
            .id = self.spec.upstream_id,
            .route = self.compose(),
            .credential = credential,
            .caps = self.spec.caps,
            .dialect = self.spec.dialect,
            .limits = self.spec.limits,
        };
    }
};

/// Find `provider/model` in the baked table.
pub fn lookup(selector: []const u8) Error!Entry {
    const parts = try split(selector);
    const provider = find(parts.provider) orelse return Error.UnknownProvider;
    for (provider.models) |*spec| {
        if (std.mem.eql(u8, spec.id, parts.model)) return .{ .provider = provider, .spec = spec };
    }
    return Error.UnknownModel;
}

/// Resolve `provider/model` into a call model that presents `credential`.
pub fn resolve(selector: []const u8, credential: route.Credential) Error!call.Model {
    return (try lookup(selector)).bind(credential);
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
    const row = find("openrouter") orelse return error.TestUnexpectedResult;
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

test "a selector resolves against the baked table and sends the upstream id" {
    const row = &providers[0];
    var buf: [128]u8 = undefined;
    const selector = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ row.id, row.models[0].id });

    const resolved = try resolve(selector, .{ .api_key = "sk-test" });
    const entry = try lookup(selector);
    // The whole route reaches the call, so a dropped protocol or header fails here.
    try testing.expectEqualDeep(entry.compose(), resolved.route);
    try testing.expectEqualStrings(row.models[0].upstream_id, resolved.id);
    try testing.expectEqualStrings("sk-test", resolved.credential.api_key);
    try testing.expectEqual(row.models[0].limits.max_output_tokens, resolved.limits.max_output_tokens);

    try testing.expectError(Error.UnknownProvider, resolve("nope/model", .none));
    try testing.expectError(Error.UnknownModel, resolve("anthropic/nope", .none));
    try testing.expectError(Error.MalformedSelector, resolve("anthropic", .none));
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
    const messages = (Entry{ .provider = &gateway, .spec = &gateway.models[0] }).compose();
    try testing.expectEqual(route.Protocol.anthropic_messages, messages.protocol);
    try testing.expectEqual(route.ApiKeyHeader.x_api_key, messages.auth.api_key);
    try testing.expectEqual(@as(?route.CachePolicy, .anthropic_breakpoint), messages.cache);
    const chat = (Entry{ .provider = &gateway, .spec = &gateway.models[1] }).compose();
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
        try testing.expectEqual(spec.protocol, (Entry{ .provider = row, .spec = spec }).compose().protocol);
    };
}

test "the credential comes from the variable the catalog names" {
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try env.put("BLANK_KEY", "");
    try env.put("ACME_API_KEY", "sk-real");

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

test "catalog errors have a permanent user-facing classification" {
    // A catalog error that classifies as unknown would hide a caller's selector mistake.
    inline for (@typeInfo(Error).error_set.?) |raised| {
        const got = failure.classify(@field(anyerror, raised.name));
        try testing.expectEqual(failure.Class.permanent, got.class);
        try testing.expect(got.reason != .unknown);
    }
}

test "baked tool search support remains specific to the provider and model" {
    try testing.expectEqual(@as(?bool, true), (try bakedCaps("openai", "gpt-5.4")).tool_search);
    try testing.expectEqual(@as(?bool, false), (try bakedCaps("openai", "gpt-5.4-nano")).tool_search);
    // The producer states Codex support after a live verification on the backend.
    try testing.expectEqual(@as(?bool, true), (try bakedCaps("openai-codex", "gpt-5.4")).tool_search);
    try testing.expectEqual(@as(?bool, false), (try bakedCaps("openai-codex", "gpt-5.4-nano")).tool_search);
    try testing.expectEqual(@as(?bool, true), (try bakedCaps("anthropic", "claude-opus-4-6")).tool_search);
}

fn bakedCaps(provider_id: []const u8, model_id: []const u8) !model.Caps {
    var buf: [128]u8 = undefined;
    return (try lookup(try std.fmt.bufPrint(&buf, "{s}/{s}", .{ provider_id, model_id }))).spec.caps;
}
