//! Resolve a provider instance to its request URL and authentication headers.

const std = @import("std");
const instance = @import("instance.zig");

const Header = instance.Header;
const ProviderInstance = instance.ProviderInstance;

/// A pinned header can collide with a generated one, and a pinned header is source input.
pub const Error = error{ HeaderConflict, InvalidCredential } || std.mem.Allocator.Error;

/// Map each protocol to its stream path.
const protocol_path = std.enums.EnumArray(instance.Protocol, []const u8).init(.{
    .anthropic_messages = "/messages",
    .openai_chat = "/chat/completions",
    .openai_responses = "/responses",
});

/// Build the full URL in `gpa`. A final slash on the base gives one separator, not two.
pub fn endpointUrl(gpa: std.mem.Allocator, p: *const ProviderInstance) std.mem.Allocator.Error![]u8 {
    const base = std.mem.trimEnd(u8, p.base_url, "/");
    return std.mem.concat(gpa, u8, &.{ base, protocol_path.get(p.protocol) });
}

/// Hold the credential a run presents. An OAuth grant pins its own identity headers.
pub const Credential = union(enum) {
    none,
    api_key: []const u8,
    oauth: OAuth,

    pub const OAuth = struct {
        access_token: []const u8,
        headers: []const Header = &.{},
    };

    /// Return the credential value, or null when the route presents none.
    pub fn token(self: Credential) ?[]const u8 {
        return switch (self) {
            .none => null,
            .api_key => |key| key,
            .oauth => |grant| grant.access_token,
        };
    }

    /// Return the identity headers the grant pins. An API key pins none.
    pub fn pinned(self: Credential) []const Header {
        return switch (self) {
            .oauth => |grant| grant.headers,
            .none, .api_key => &.{},
        };
    }
};

/// Report whether the generated, pinned, and configured headers name one header twice.
pub fn headerConflict(generated: ?[]const u8, pinned: []const Header, configured: []const Header) bool {
    for (configured) |h| {
        if (generated) |name| if (std.ascii.eqlIgnoreCase(name, h.name)) return true;
        for (pinned) |id| if (std.ascii.eqlIgnoreCase(id.name, h.name)) return true;
    }
    if (generated) |name| {
        for (pinned) |id| if (std.ascii.eqlIgnoreCase(name, id.name)) return true;
    }
    return false;
}

/// Append the credential and pinned headers to `out`, and copy every value into `gpa`.
pub fn authHeaders(
    gpa: std.mem.Allocator,
    p: *const ProviderInstance,
    credential: Credential,
    out: *std.ArrayList(Header),
) Error!void {
    const generated = p.auth.headerName();
    const secret = credential.token();
    if ((generated == null) != (secret == null)) return error.InvalidCredential;

    const identity = credential.pinned();
    if (headerConflict(generated, identity, p.headers)) return error.HeaderConflict;

    switch (p.auth) {
        .none => {},
        .api_key => |kind| {
            const key = secret.?; // The credential check proves that this route has a secret.
            try out.append(gpa, .{
                .name = generated.?,
                .value = switch (kind) {
                    .x_api_key => try gpa.dupe(u8, key),
                    .authorization_bearer => try bearer(gpa, key),
                },
            });
        },
    }

    for (identity) |h| try out.append(gpa, .{
        .name = try gpa.dupe(u8, h.name),
        .value = try gpa.dupe(u8, h.value),
    });
    for (p.headers) |h| try out.append(gpa, .{
        .name = try gpa.dupe(u8, h.name),
        .value = try gpa.dupe(u8, h.value),
    });
}

fn bearer(gpa: std.mem.Allocator, token_value: []const u8) Error![]u8 {
    return std.mem.concat(gpa, u8, &.{ "Bearer ", token_value });
}

const testing = std.testing;

fn header(headers: []const Header, name: []const u8) ?[]const u8 {
    for (headers) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    return null;
}

test "endpoint url appends the protocol path" {
    const url = try endpointUrl(testing.allocator, &.{
        .base_url = "https://api.anthropic.com/v1",
        .protocol = .anthropic_messages,
        .auth = .{ .api_key = .x_api_key },
    });
    defer testing.allocator.free(url);
    try testing.expectEqualStrings("https://api.anthropic.com/v1/messages", url);
}

test "endpoint url collapses a trailing slash on the base" {
    const url = try endpointUrl(testing.allocator, &.{
        .base_url = "https://api.anthropic.com/v1/",
        .protocol = .anthropic_messages,
        .auth = .{ .api_key = .x_api_key },
    });
    defer testing.allocator.free(url);
    try testing.expectEqualStrings("https://api.anthropic.com/v1/messages", url);
}

test "anthropic api key uses x-api-key plus the pinned version header" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var out: std.ArrayList(Header) = .empty;
    try authHeaders(arena.allocator(), &.{
        .base_url = "https://api.anthropic.com/v1",
        .protocol = .anthropic_messages,
        .auth = .{ .api_key = .x_api_key },
        .headers = &.{.{ .name = "anthropic-version", .value = "2023-06-01" }},
    }, .{ .api_key = "sk-secret" }, &out);

    try testing.expectEqualStrings("sk-secret", header(out.items, "x-api-key").?);
    try testing.expectEqualStrings("2023-06-01", header(out.items, "anthropic-version").?);
    try testing.expect(header(out.items, "Authorization") == null);
}

test "a compat host uses Authorization Bearer" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var out: std.ArrayList(Header) = .empty;
    try authHeaders(arena.allocator(), &.{
        .base_url = "https://llm.acme/v1",
        .protocol = .anthropic_messages,
        .auth = .{ .api_key = .authorization_bearer },
    }, .{ .api_key = "sk-2" }, &out);
    try testing.expectEqualStrings("Bearer sk-2", header(out.items, "Authorization").?);
}

test "an oauth grant is a bearer that carries its own identity header" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var out: std.ArrayList(Header) = .empty;
    try authHeaders(arena.allocator(), &.{
        .base_url = "https://chatgpt.com/backend-api/codex",
        .protocol = .openai_responses,
        .auth = .{ .api_key = .authorization_bearer },
        .responses_dialect = .codex,
    }, .{ .oauth = .{
        .access_token = "tok",
        .headers = &.{.{ .name = "ChatGPT-Account-ID", .value = "acct" }},
    } }, &out);
    try testing.expectEqualStrings("Bearer tok", header(out.items, "Authorization").?);
    try testing.expectEqualStrings("acct", header(out.items, "ChatGPT-Account-ID").?);
}

test "a keyless route writes no credential header" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var out: std.ArrayList(Header) = .empty;
    try authHeaders(arena.allocator(), &.{
        .base_url = "http://127.0.0.1:11434/v1",
        .protocol = .openai_chat,
        .auth = .none,
        .headers = &.{.{ .name = "x-note", .value = "local" }},
    }, .none, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqualStrings("local", header(out.items, "x-note").?);
    try testing.expect(header(out.items, "Authorization") == null);
}

test "a pinned header that collides with the credential is rejected" {
    var out: std.ArrayList(Header) = .empty;
    defer out.deinit(testing.allocator);
    try testing.expectError(error.HeaderConflict, authHeaders(testing.allocator, &.{
        .base_url = "x",
        .protocol = .anthropic_messages,
        .auth = .{ .api_key = .x_api_key },
        .headers = &.{.{ .name = "X-Api-Key", .value = "injected" }},
    }, .{ .api_key = "real" }, &out));
}

test "a pinned header that collides with an oauth identity header is rejected" {
    var out: std.ArrayList(Header) = .empty;
    defer out.deinit(testing.allocator);
    try testing.expectError(error.HeaderConflict, authHeaders(testing.allocator, &.{
        .base_url = "x",
        .protocol = .openai_responses,
        .auth = .{ .api_key = .authorization_bearer },
        .headers = &.{.{ .name = "chatgpt-account-id", .value = "injected" }},
    }, .{ .oauth = .{
        .access_token = "tok",
        .headers = &.{.{ .name = "ChatGPT-Account-ID", .value = "acct" }},
    } }, &out));
}

test "a credential must match the authentication mechanism" {
    var out: std.ArrayList(Header) = .empty;
    try testing.expectError(error.InvalidCredential, authHeaders(testing.allocator, &.{
        .base_url = "https://example.test/v1",
        .protocol = .openai_chat,
        .auth = .{ .api_key = .authorization_bearer },
    }, .none, &out));
    try testing.expectEqual(@as(usize, 0), out.items.len);
}
