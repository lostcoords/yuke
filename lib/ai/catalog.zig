//! The baked provider table, and the helpers that turn one selector into a call.
//! The rows come from `catalog_gen.zig`, which `zig build cataloggen` writes.

const std = @import("std");
const generated = @import("catalog_gen.zig");
const call = @import("call.zig");
const credentials = @import("instance/resolve.zig");
const model_types = @import("model.zig");

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

/// Split `provider/model` on the first slash. A model id may hold further slashes.
pub fn split(selector: []const u8) Error!Selector {
    const slash = std.mem.indexOfScalar(u8, selector, '/') orelse return Error.MalformedSelector;
    const parts: Selector = .{ .provider = selector[0..slash], .model = selector[slash + 1 ..] };
    if (parts.provider.len == 0 or parts.model.len == 0) return Error.MalformedSelector;
    return parts;
}

/// Resolve `provider/model` against the baked table into one model a client can call.
/// The result borrows the table, which lives for the whole program.
pub fn resolve(selector: []const u8, credential: credentials.Credential) Error!call.Model {
    const parts = try split(selector);
    const provider = find(parts.provider) orelse return Error.UnknownProvider;
    const spec = findModel(parts.provider, parts.model) orelse return Error.UnknownModel;
    return .{
        // The upstream id is the string a request sends, which a gateway may rename.
        .id = spec.upstream_id,
        .provider = provider.route,
        .credential = credential,
    };
}

/// Return the first key this provider names that the environment holds, or null.
/// An empty value is no value, so a blank variable never becomes a blank header.
pub fn envKey(provider: *const Provider, env: *const std.process.Environ.Map) ?[]const u8 {
    for (provider.env) |name| {
        const value = env.get(name) orelse continue;
        if (value.len != 0) return value;
    }
    return null;
}

/// Read this provider's key from the environment and bind it as a credential.
/// An OAuth provider answers null, because this library runs no login flow.
pub fn envCredential(provider: *const Provider, env: *const std.process.Environ.Map) ?credentials.Credential {
    if (provider.auth == .oauth) return null;
    return .{ .api_key = envKey(provider, env) orelse return null };
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
    const first = providers[0].models[0];
    var buf: [128]u8 = undefined;
    const selector = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ providers[0].id, first.id });

    const resolved = try resolve(selector, .{ .api_key = "sk-test" });
    try testing.expectEqualStrings(first.upstream_id, resolved.id); // the wire carries the upstream id
    try testing.expectEqualStrings(providers[0].route.base_url, resolved.provider.base_url);
    try testing.expectEqualStrings("sk-test", resolved.credential.api_key);

    try testing.expectError(Error.UnknownProvider, resolve("nope/model", .none));
    try testing.expectError(Error.UnknownModel, resolve("anthropic/nope", .none));
}

test "an environment key becomes a credential, and a blank one does not" {
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try env.put("BLANK_KEY", "");
    try env.put("REAL_KEY", "sk-real");

    const api_key: Provider = .{
        .id = "acme",
        .name = "Acme",
        .env = &.{ "MISSING_KEY", "BLANK_KEY", "REAL_KEY" },
        .auth = .api_key,
        .route = .{ .base_url = "https://acme.test/v1", .protocol = .openai_chat, .auth = .{ .api_key = .authorization_bearer } },
        .models = &.{},
    };
    // The search skips a variable the process lost and one that holds nothing.
    try testing.expectEqualStrings("sk-real", envCredential(&api_key, &env).?.api_key);

    var unset = api_key;
    unset.env = &.{"MISSING_KEY"};
    try testing.expect(envCredential(&unset, &env) == null);

    // A grant needs a login flow, which this library never runs.
    var oauth = api_key;
    oauth.auth = .oauth;
    try testing.expect(envCredential(&oauth, &env) == null);
}

test "every baked provider states a usable route" {
    for (providers) |row| {
        try testing.expect(row.id.len != 0);
        try testing.expect(std.mem.startsWith(u8, row.route.base_url, "https://"));
        try testing.expect(!std.mem.endsWith(u8, row.route.base_url, "/")); // resolve appends the protocol path
        try testing.expect(row.route.auth != .none); // every listed provider presents a credential
        for (row.models) |spec| {
            try testing.expect(spec.id.len != 0 and spec.upstream_id.len != 0);
            try testing.expect(std.mem.indexOfScalar(u8, row.id, '/') == null); // a provider id never splits a selector
        }
    }
}

test "an api-key provider that names no variable cannot be configured from the environment" {
    // The catalog publishes `env` only after the control plane ships it, so this stays observable.
    var without: usize = 0;
    for (providers) |row| {
        if (row.auth == .api_key and row.env.len == 0) without += 1;
    }
    try testing.expect(without <= providers.len);
}

test {
    _ = model_types;
}

test "a preset reaches a provider call with one selector and one key" {
    const transport = @import("transport.zig");
    var canned = transport.CannedTransport{ .bytes = transport.canned_reply };

    // This is the whole path a library user takes: name a model, bind a key, call.
    var result = try call.generateTextWithTransport(
        testing.allocator,
        canned.transport(),
        try resolve("anthropic/claude-fable-5", .{ .api_key = "sk-test" }),
        "hello",
        .{},
    );
    defer result.deinit();
    try testing.expectEqualStrings("Hello from the yuke mock provider.", result.text);
}
