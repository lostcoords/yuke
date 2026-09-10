//! Resolve a provider instance to its request URL and authentication headers.

const std = @import("std");
const instance = @import("instance.zig");
const transport = @import("../transport.zig");

const Header = instance.Header;
const Route = instance.Route;

/// A pinned header can collide with a generated one, and a pinned header is source input.
pub const Error = error{ HeaderConflict, InvalidCredential } || std.mem.Allocator.Error;

/// Map each protocol to its stream path.
const protocol_path = std.enums.EnumArray(instance.Protocol, []const u8).init(.{
    .anthropic_messages = "/messages",
    .openai_chat = "/chat/completions",
    .openai_responses = "/responses",
});

/// Build the full URL in `gpa`. A final slash on the base gives one separator, not two.
pub fn endpointUrl(gpa: std.mem.Allocator, p: *const Route) std.mem.Allocator.Error![]u8 {
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

/// Append the credential and pinned headers to `out`, and copy each string into `arena`, which `out.deinit` cannot free.
pub fn authHeaders(
    arena: std.mem.Allocator,
    p: *const Route,
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
            try out.append(arena, .{
                .name = generated.?,
                .value = switch (kind) {
                    .x_api_key => try arena.dupe(u8, key),
                    .authorization_bearer => try bearer(arena, key),
                },
            });
        },
    }

    for (identity) |h| try out.append(arena, try h.cloneLeaky(arena));
    for (p.headers) |h| try out.append(arena, try h.cloneLeaky(arena));
}

/// Name the header that carries the session id, or null when the route reads no such header.
/// The ChatGPT backend routes a repeated prefix to one prompt cache by this header, not by a body field.
fn sessionHeaderName(p: *const Route) ?[]const u8 {
    if (p.protocol != .openai_responses) return null;
    return switch (p.responses_dialect) {
        .codex => "session-id",
        .standard => null,
    };
}

/// Build the request one route sends, and copy its URL and headers into `arena`.
pub fn request(
    arena: std.mem.Allocator,
    p: *const Route,
    credential: Credential,
    session_id: []const u8,
    body: []u8,
) Error!transport.Request {
    var headers: std.ArrayList(Header) = .empty;
    try authHeaders(arena, p, credential, &headers);
    if (session_id.len != 0) if (sessionHeaderName(p)) |name| {
        // The engine owns this value, so a source that pins its own would send every session to one cache.
        if (header(headers.items, name) != null) return error.HeaderConflict;
        try headers.append(arena, .{ .name = name, .value = try arena.dupe(u8, session_id) });
    };
    return .{
        .url = try endpointUrl(arena, p),
        .headers = headers.items,
        .body = body,
    };
}

fn bearer(gpa: std.mem.Allocator, token_value: []const u8) Error![]u8 {
    return std.mem.concat(gpa, u8, &.{ "Bearer ", token_value });
}

fn header(headers: []const Header, name: []const u8) ?[]const u8 {
    for (headers) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    return null;
}

const testing = std.testing;

test "endpoint url appends the protocol path and collapses a trailing slash" {
    for ([_][]const u8{ "https://api.anthropic.com/v1", "https://api.anthropic.com/v1/" }) |base| {
        const url = try endpointUrl(testing.allocator, &.{
            .base_url = base,
            .protocol = .anthropic_messages,
            .auth = .{ .api_key = .x_api_key },
        });
        defer testing.allocator.free(url);
        try testing.expectEqualStrings("https://api.anthropic.com/v1/messages", url);
    }
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

test "only the codex responses route carries the session id as a header" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var body = "{}".*;

    const codex: Route = .{
        .base_url = "https://chatgpt.com/backend-api/codex",
        .protocol = .openai_responses,
        .auth = .none,
        .responses_dialect = .codex,
    };
    const carried = try request(a, &codex, .none, "0123456789abcdef", &body);
    try testing.expectEqualStrings("0123456789abcdef", header(carried.headers, "session-id").?);

    // The public Responses endpoint routes on the body key, so a header there would be dead weight.
    var standard = codex;
    standard.responses_dialect = .standard;
    const plain = try request(a, &standard, .none, "0123456789abcdef", &body);
    try testing.expect(header(plain.headers, "session-id") == null);

    // No other protocol reads this header.
    const anthropic: Route = .{
        .base_url = "https://api.anthropic.com/v1",
        .protocol = .anthropic_messages,
        .auth = .none,
    };
    const other = try request(a, &anthropic, .none, "0123456789abcdef", &body);
    try testing.expect(header(other.headers, "session-id") == null);

    // A caller that names no session leaves the header off rather than sending an empty one.
    const absent = try request(a, &codex, .none, "", &body);
    try testing.expect(header(absent.headers, "session-id") == null);
}

test "a source that pins the session header is a conflict, not a silent override" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var body = "{}".*;
    const route: Route = .{
        .base_url = "https://chatgpt.com/backend-api/codex",
        .protocol = .openai_responses,
        .auth = .none,
        .responses_dialect = .codex,
        // A header name is case-insensitive, so a different spelling is the same header.
        .headers = &.{.{ .name = "Session-ID", .value = "from-the-route" }},
    };
    try testing.expectError(error.HeaderConflict, request(arena.allocator(), &route, .none, "0123456789abcdef", &body));

    // The same route serves a caller that names no session, because nothing is generated to collide.
    const built = try request(arena.allocator(), &route, .none, "", &body);
    try testing.expectEqualStrings("from-the-route", header(built.headers, "session-id").?);
    try testing.expect(instance.validHeaders(built.headers));
}

test "one call turns a route and a credential into a request that owns its strings" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var body = "{}".*;
    var version = "2023-06-01".*;
    var key = "sk-secret".*;

    const built = try request(arena.allocator(), &.{
        .base_url = "https://api.anthropic.com/v1/",
        .protocol = .anthropic_messages,
        .auth = .{ .api_key = .x_api_key },
        .headers = &.{.{ .name = "anthropic-version", .value = &version }},
    }, .{ .api_key = &key }, "", &body);

    // The request outlives the route and the credential, so a later overwrite must not reach it.
    @memset(&version, 'x');
    @memset(&key, 'x');
    try testing.expectEqualStrings("https://api.anthropic.com/v1/messages", built.url);
    try testing.expectEqualStrings("sk-secret", header(built.headers, "x-api-key").?);
    try testing.expectEqualStrings("2023-06-01", header(built.headers, "anthropic-version").?);
    try testing.expectEqualStrings("{}", built.body);
}
