//! The baked provider table, and the helpers that turn one selector into a call.

const std = @import("std");
const generated = @import("catalog_gen.zig");
const call = @import("call.zig");
const credentials = @import("instance/resolve.zig");

pub const Provider = generated.Provider;
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
pub fn resolve(selector: []const u8, credential: credentials.Credential) Error!call.Model {
    const parts = try split(selector);
    const provider = find(parts.provider) orelse return Error.UnknownProvider;
    for (provider.models) |*spec| {
        if (!std.mem.eql(u8, spec.id, parts.model)) continue;
        // A gateway may rename a model, so the request sends the upstream id.
        return .{ .id = spec.upstream_id, .provider = provider.route, .credential = credential };
    }
    return Error.UnknownModel;
}

/// Bind this provider's key from the environment, or answer null when the catalog cannot name one.
/// The catalog lists every variable a provider reads, and only a lone variable is certainly the secret.
pub fn envCredential(provider: *const Provider, env: *const std.process.Environ.Map) ?credentials.Credential {
    if (provider.auth == .oauth) return null; // A grant needs a login flow, which this library never runs.
    if (provider.env.len != 1) return null;
    const value = env.get(provider.env[0]) orelse return null;
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

    try testing.expectError(Error.MalformedSelector, split("anthropic"));
    try testing.expectError(Error.MalformedSelector, split("/claude"));
    try testing.expectError(Error.MalformedSelector, split("anthropic/"));
}

test "a selector resolves against the baked table" {
    const row = providers[0];
    var buf: [128]u8 = undefined;
    const selector = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ row.id, row.models[0].id });

    const resolved = try resolve(selector, .{ .api_key = "sk-test" });
    // The whole route reaches the call, so a dropped protocol or header fails here.
    try testing.expectEqualDeep(row.route, resolved.provider);
    try testing.expectEqualStrings("sk-test", resolved.credential.api_key);

    try testing.expectError(Error.UnknownProvider, resolve("nope/model", .none));
    try testing.expectError(Error.UnknownModel, resolve("anthropic/nope", .none));
}

test "only a lone environment variable is certainly the credential" {
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try env.put("BLANK_KEY", "");
    try env.put("ACME_API_KEY", "sk-real");
    try env.put("ACME_RESOURCE_NAME", "acme-eu");

    const lone: Provider = .{
        .id = "acme",
        .name = "Acme",
        .env = &.{"ACME_API_KEY"},
        .auth = .api_key,
        .route = .{ .base_url = "https://acme.test/v1", .protocol = .openai_chat, .auth = .{ .api_key = .authorization_bearer } },
        .models = &.{},
    };
    try testing.expectEqualStrings("sk-real", envCredential(&lone, &env).?.api_key);

    // `azure` names a resource before its key, so a first-wins search would send the resource name.
    var sequence = lone;
    sequence.env = &.{ "ACME_RESOURCE_NAME", "ACME_API_KEY" };
    try testing.expect(envCredential(&sequence, &env) == null);

    var unset = lone;
    unset.env = &.{"MISSING_KEY"};
    try testing.expect(envCredential(&unset, &env) == null);

    var blank = lone;
    blank.env = &.{"BLANK_KEY"};
    try testing.expect(envCredential(&blank, &env) == null);

    var oauth = lone;
    oauth.auth = .oauth;
    try testing.expect(envCredential(&oauth, &env) == null);
}
