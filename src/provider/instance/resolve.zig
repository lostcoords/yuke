//! Resolve provider instances to request URLs and authentication headers.
//! Typed secrets select the auth scheme; bearer values use the caller allocator.

const std = @import("std");
const instance = @import("instance.zig");

const Header = instance.Header;
const ProviderInstance = instance.ProviderInstance;

pub const Error = error{ AuthMismatch, HeaderConflict, OutOfMemory };

/// Map each protocol to its stream path.
const protocol_path = std.enums.EnumArray(instance.Protocol, []const u8).init(.{
    .@"anthropic-messages" = "/messages",
    .@"openai-completions" = "/chat/completions",
    .@"openai-responses" = "/responses",
});

/// Build the full URL in `gpa`. A trailing slash on the base gives one separator, not two.
pub fn endpointUrl(gpa: std.mem.Allocator, p: *const ProviderInstance) std.mem.Allocator.Error![]u8 {
    const base = std.mem.trimEnd(u8, p.base_url, "/");
    return std.mem.concat(gpa, u8, &.{ base, protocol_path.get(p.protocol) });
}

/// Hold a credential from the configured source.
pub const Secret = union(enum) {
    api_key: []const u8,
    codex: Codex,
    xai: []const u8,

    pub const Codex = struct {
        access_token: []const u8,
        account_id: []const u8,
    };
};

/// Append the credential and pinned headers to `out`, an arena-backed empty list.
/// The checks run before any allocation, so no error leaves partial output.
pub fn authHeaders(gpa: std.mem.Allocator, p: *const ProviderInstance, secret: Secret, out: *std.ArrayList(Header)) Error!void {
    // This call knows the header names before it allocates memory.
    const generated: []const []const u8 = switch (p.auth) {
        .api_key => |a| switch (a.header) {
            .x_api_key => &.{"x-api-key"},
            .authorization_bearer => &.{"Authorization"},
        },
        .codex_oauth => &.{ "Authorization", "ChatGPT-Account-ID" },
        .xai_oauth => &.{"Authorization"},
    };
    for (p.headers) |h| for (generated) |g| {
        if (std.ascii.eqlIgnoreCase(g, h.name)) return error.HeaderConflict;
    };

    switch (p.auth) {
        .api_key => |a| {
            const key = switch (secret) {
                .api_key => |k| k,
                else => return error.AuthMismatch,
            };
            switch (a.header) {
                .x_api_key => try out.append(gpa, .{ .name = "x-api-key", .value = key }),
                .authorization_bearer => try out.append(gpa, .{ .name = "Authorization", .value = try bearer(gpa, key) }),
            }
        },
        .codex_oauth => {
            const c = switch (secret) {
                .codex => |c| c,
                else => return error.AuthMismatch,
            };
            try out.append(gpa, .{ .name = "Authorization", .value = try bearer(gpa, c.access_token) });
            try out.append(gpa, .{ .name = "ChatGPT-Account-ID", .value = c.account_id });
        },
        .xai_oauth => {
            const token = switch (secret) {
                .xai => |t| t,
                else => return error.AuthMismatch,
            };
            try out.append(gpa, .{ .name = "Authorization", .value = try bearer(gpa, token) });
        },
    }

    for (p.headers) |h| try out.append(gpa, h);
}

fn bearer(gpa: std.mem.Allocator, token: []const u8) Error![]u8 {
    return std.mem.concat(gpa, u8, &.{ "Bearer ", token });
}

const testing = std.testing;

fn header(headers: []const Header, name: []const u8) ?[]const u8 {
    for (headers) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    return null;
}

test "endpoint url appends the protocol path" {
    const url = try endpointUrl(testing.allocator, &.{
        .id = "x",
        .base_url = "https://api.anthropic.com/v1",
        .protocol = .@"anthropic-messages",
        .auth = .{ .api_key = .{ .header = .x_api_key, .source = .{ .env = "K" } } },
    });
    defer testing.allocator.free(url);
    try testing.expectEqualStrings("https://api.anthropic.com/v1/messages", url);
}

test "endpoint url collapses a trailing slash on the base" {
    const url = try endpointUrl(testing.allocator, &.{
        .id = "x",
        .base_url = "https://api.anthropic.com/v1/",
        .protocol = .@"anthropic-messages",
        .auth = .{ .api_key = .{ .header = .x_api_key, .source = .{ .env = "K" } } },
    });
    defer testing.allocator.free(url);
    try testing.expectEqualStrings("https://api.anthropic.com/v1/messages", url);
}

test "anthropic api key uses x-api-key plus the pinned version header" {
    var out: std.ArrayList(Header) = .empty;
    defer out.deinit(testing.allocator);
    try authHeaders(testing.allocator, &.{
        .id = "anthropic",
        .base_url = "https://api.anthropic.com/v1",
        .protocol = .@"anthropic-messages",
        .auth = .{ .api_key = .{ .header = .x_api_key, .source = .{ .env = "K" } } },
        .headers = &.{.{ .name = "anthropic-version", .value = "2023-06-01" }},
    }, .{ .api_key = "sk-secret" }, &out);

    try testing.expectEqualStrings("sk-secret", header(out.items, "x-api-key").?);
    try testing.expectEqualStrings("2023-06-01", header(out.items, "anthropic-version").?);
    try testing.expect(header(out.items, "Authorization") == null);
}

test "a compat host uses Authorization Bearer" {
    var out: std.ArrayList(Header) = .empty;
    defer out.deinit(testing.allocator);
    try authHeaders(testing.allocator, &.{
        .id = "compat",
        .base_url = "https://llm.acme/v1",
        .protocol = .@"anthropic-messages",
        .auth = .{ .api_key = .{ .header = .authorization_bearer, .source = .{ .env = "K" } } },
    }, .{ .api_key = "sk-2" }, &out);
    defer for (out.items) |h| if (std.mem.startsWith(u8, h.value, "Bearer ")) testing.allocator.free(h.value);

    try testing.expectEqualStrings("Bearer sk-2", header(out.items, "Authorization").?);
}

test "codex oauth emits the account header" {
    var out: std.ArrayList(Header) = .empty;
    defer out.deinit(testing.allocator);
    try authHeaders(testing.allocator, &.{
        .id = "codex",
        .base_url = "https://chatgpt.com/backend-api/codex",
        .protocol = .@"openai-responses",
        .auth = .{ .codex_oauth = .{ .store = "t", .account_store = "a" } },
    }, .{ .codex = .{ .access_token = "tok", .account_id = "acct" } }, &out);
    defer for (out.items) |h| if (std.mem.startsWith(u8, h.value, "Bearer ")) testing.allocator.free(h.value);

    try testing.expectEqualStrings("Bearer tok", header(out.items, "Authorization").?);
    try testing.expectEqualStrings("acct", header(out.items, "ChatGPT-Account-ID").?);
}

test "a secret of the wrong kind is rejected" {
    var out: std.ArrayList(Header) = .empty;
    defer out.deinit(testing.allocator);
    try testing.expectError(error.AuthMismatch, authHeaders(testing.allocator, &.{
        .id = "codex",
        .base_url = "x",
        .protocol = .@"openai-responses",
        .auth = .{ .codex_oauth = .{ .store = "t", .account_store = "a" } },
    }, .{ .api_key = "wrong" }, &out));
}

test "a pinned header that collides with the credential is rejected" {
    var out: std.ArrayList(Header) = .empty;
    defer out.deinit(testing.allocator);
    try testing.expectError(error.HeaderConflict, authHeaders(testing.allocator, &.{
        .id = "x",
        .base_url = "x",
        .protocol = .@"anthropic-messages",
        .auth = .{ .api_key = .{ .header = .x_api_key, .source = .{ .env = "K" } } },
        .headers = &.{.{ .name = "X-Api-Key", .value = "injected" }},
    }, .{ .api_key = "real" }, &out));
}
