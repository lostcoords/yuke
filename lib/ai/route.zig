//! A route holds how one request reaches a provider, and the credential headers it presents.

const std = @import("std");
const types = @import("types.zig");

pub const Protocol = types.Protocol;

/// Select the API-key header.
pub const ApiKeyHeader = enum { x_api_key, authorization_bearer };

/// Name how an endpoint caches. A null policy means the control plane did not verify the host.
pub const CachePolicy = enum {
    unsupported,
    /// The host caches a repeated prefix on its own, so a request marks nothing.
    automatic,
    anthropic_breakpoint,
    openai_breakpoint,

    /// Report the marker for one route and model. Only a model that states it takes one gets one.
    pub fn markerFor(self: ?CachePolicy, accepts_breakpoint: ?bool) types.CacheMarker {
        return if (accepts_breakpoint == true) marker(self) else .none;
    }

    /// Report the marker a request writes. A new policy must answer here.
    pub fn marker(self: ?CachePolicy) types.CacheMarker {
        return switch (self orelse return .none) {
            .unsupported, .automatic => .none,
            .anthropic_breakpoint => .anthropic,
            .openai_breakpoint => .openai,
        };
    }
};

/// Select which header presents the credential. The mechanism never holds the secret.
pub const AuthMechanism = union(enum) {
    none,
    api_key: ApiKeyHeader,

    /// Return the header name this mechanism generates, or null when it presents no credential.
    pub fn headerName(self: AuthMechanism) ?[]const u8 {
        return switch (self) {
            .none => null,
            .api_key => |header| switch (header) {
                .x_api_key => "x-api-key",
                .authorization_bearer => "Authorization",
            },
        };
    }
};

/// A pinned non-secret request header.
pub const Header = struct {
    name: []const u8,
    value: []const u8,

    /// Copy both strings into `gpa`, which must be an arena, because a `Header` frees nothing itself.
    pub fn cloneLeaky(self: Header, gpa: std.mem.Allocator) std.mem.Allocator.Error!Header {
        return .{ .name = try gpa.dupe(u8, self.name), .value = try gpa.dupe(u8, self.value) };
    }
};

/// RFC 9110 defines the field-name token characters. A colon would split the field line.
fn isTchar(c: u8) bool {
    return switch (c) {
        '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
        '0'...'9', 'A'...'Z', 'a'...'z' => true,
        else => false,
    };
}

/// Return true when a header name is one RFC 9110 token. `std.http` asserts these same rules.
pub fn validHeaderName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| if (!isTchar(c)) return false;
    return true;
}

/// Return true when a header value holds no control byte except a tab. This rejects CR and LF.
pub fn validHeaderValue(value: []const u8) bool {
    for (value) |c| if (c != '\t' and std.ascii.isControl(c)) return false;
    return true;
}

/// Return true when every header can reach a request, because `std.http.Client` asserts and aborts.
pub fn validHeaders(headers: []const Header) bool {
    for (headers, 0..) |h, i| {
        if (!validHeaderName(h.name) or !validHeaderValue(h.value)) return false;
        for (headers[0..i]) |prev| if (std.ascii.eqlIgnoreCase(prev.name, h.name)) return false;
    }
    return true;
}

/// Select the Responses flavor an endpoint speaks. The route owns it, because it follows the host.
pub const ResponsesDialect = @import("request/ir.zig").ResponsesDialect;

/// Select the header that carries the session id. Each value names one header, so a second host can reuse it.
pub const SessionHeader = enum {
    none,
    /// The ChatGPT backend routes a repeated prefix to one prompt cache by this header.
    session_id,
    /// OpenCode Zen and Go route one conversation to one upstream by this header, and refuse a request without it.
    x_opencode_session,

    /// Return the header name, or null when the route carries the session id in no header.
    pub fn name(self: SessionHeader) ?[]const u8 {
        return switch (self) {
            .none => null,
            .session_id => "session-id",
            .x_opencode_session => "x-opencode-session",
        };
    }
};

/// One protocol a host serves. The key header lives here because one host can read a different header per path.
pub const Endpoint = struct {
    protocol: Protocol,
    /// The header that carries the credential on this path. Null means that the path takes no credential.
    key_header: ?ApiKeyHeader = null,
    cache: ?CachePolicy = null,
    responses_dialect: ResponsesDialect = .standard,

    /// Return the mechanism this endpoint presents a credential with.
    pub fn mechanism(self: Endpoint) AuthMechanism {
        return if (self.key_header) |header| .{ .api_key = header } else .none;
    }

    /// Compose the route one model calls: the host fields, and the path fields of this endpoint.
    pub fn route(self: Endpoint, base_url: []const u8, headers: []const Header, session_header: SessionHeader) Route {
        return .{
            .base_url = base_url,
            .protocol = self.protocol,
            .auth = self.mechanism(),
            .headers = headers,
            .cache = self.cache,
            .responses_dialect = self.responses_dialect,
            .session_header = session_header,
        };
    }
};

/// Find the endpoint that serves `protocol`, or null. A list holds each protocol at most once.
pub fn findEndpoint(endpoints: []const Endpoint, protocol: Protocol) ?*const Endpoint {
    for (endpoints) |*e| if (e.protocol == protocol) return e;
    return null;
}

/// Define how one request reaches a provider. The protocol selects a closed request dialect.
pub const Route = struct {
    base_url: []const u8,
    protocol: Protocol,
    auth: AuthMechanism,
    headers: []const Header = &.{},
    cache: ?CachePolicy = null,
    responses_dialect: ResponsesDialect = .standard,
    session_header: SessionHeader = .none,
};

/// A pinned header can collide with a generated one, and a pinned header is source input.
pub const Error = error{ HeaderConflict, InvalidCredential, InvalidHeaders } || std.mem.Allocator.Error;

/// Map each protocol to its stream path.
const protocol_path = std.enums.EnumArray(Protocol, []const u8).init(.{
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

/// The request one route sends. A transport reads it and an HTTP writer shifts the body on a partial write.
pub const Request = struct {
    url: []const u8 = "",
    headers: []const Header = &.{},
    body: []u8,
};

/// Build the headers one route sends, in order: the credential, the identity headers, the route headers, the session id.
pub fn requestHeaders(arena: std.mem.Allocator, p: *const Route, credential: Credential, session_id: []const u8) Error![]Header {
    const generated = p.auth.headerName();
    const secret = credential.token();
    if ((generated == null) != (secret == null)) return error.InvalidCredential;

    const identity = credential.pinned();
    if (headerConflict(generated, identity, p.headers)) return error.HeaderConflict;
    const session = if (session_id.len != 0) p.session_header.name() else null;
    // The engine owns the session id, so a source that pins the header would send every session to one cache.
    if (session) |name| if (findHeader(identity, name) != null or findHeader(p.headers, name) != null) return error.HeaderConflict;

    // Every check ran, so the exact count is known and the arena keeps no grown buffer.
    const count = @intFromBool(generated != null) + identity.len + p.headers.len + @intFromBool(session != null);
    const out = try arena.alloc(Header, count);
    var i: usize = 0;
    if (generated) |name| {
        const key = secret.?; // The credential check proves that this route has a secret.
        out[i] = .{ .name = name, .value = switch (p.auth.api_key) {
            .x_api_key => try arena.dupe(u8, key),
            .authorization_bearer => try bearer(arena, key),
        } };
        i += 1;
    }
    for (identity, out[i..][0..identity.len]) |h, *slot| slot.* = try h.cloneLeaky(arena);
    i += identity.len;
    for (p.headers, out[i..][0..p.headers.len]) |h, *slot| slot.* = try h.cloneLeaky(arena);
    i += p.headers.len;
    if (session) |name| {
        out[i] = .{ .name = name, .value = try arena.dupe(u8, session_id) };
        i += 1;
    }
    std.debug.assert(i == count);
    // A custom transport reads these headers too, so the route rejects a name or value `std.http` would abort on.
    if (!validHeaders(out)) return error.InvalidHeaders;
    return out;
}

/// Build the request one route sends, and copy its URL and headers into `arena`.
pub fn request(arena: std.mem.Allocator, p: *const Route, credential: Credential, session_id: []const u8, body: []u8) Error!Request {
    return .{
        .url = try endpointUrl(arena, p),
        .headers = try requestHeaders(arena, p, credential, session_id),
        .body = body,
    };
}

fn bearer(gpa: std.mem.Allocator, token_value: []const u8) Error![]u8 {
    return std.mem.concat(gpa, u8, &.{ "Bearer ", token_value });
}

fn findHeader(headers: []const Header, name: []const u8) ?[]const u8 {
    for (headers) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    return null;
}

const testing = std.testing;

test "only a model that states it takes a marker is marked" {
    const anthropic: ?CachePolicy = .anthropic_breakpoint;
    try testing.expectEqual(types.CacheMarker.anthropic, CachePolicy.markerFor(anthropic, true));

    // MiniMax M3 caches but refuses a marker, so an unknown capability must never write one.
    try testing.expectEqual(types.CacheMarker.none, CachePolicy.markerFor(anthropic, null));
    try testing.expectEqual(types.CacheMarker.none, CachePolicy.markerFor(anthropic, false));

    // A host that caches on its own takes no marker whatever the model says.
    try testing.expectEqual(types.CacheMarker.none, CachePolicy.markerFor(.automatic, true));
    try testing.expectEqual(types.CacheMarker.none, CachePolicy.markerFor(null, true));
    try testing.expectEqual(types.CacheMarker.openai, CachePolicy.markerFor(.openai_breakpoint, true));
}

test "header validation rejects what std.http asserts on" {
    try testing.expect(validHeaders(&.{.{ .name = "anthropic-version", .value = "2023-06-01" }}));
    try testing.expect(!validHeaders(&.{.{ .name = "", .value = "x" }})); // An empty name aborts the client.
    try testing.expect(!validHeaders(&.{.{ .name = "bad:name", .value = "x" }}));
    try testing.expect(!validHeaders(&.{.{ .name = "bad name", .value = "x" }}));
    try testing.expect(!validHeaders(&.{.{ .name = "x-note", .value = "a\r\nb" }}));
    try testing.expect(validHeaders(&.{.{ .name = "x-note", .value = "a\tb" }})); // A tab is legal.
}

test "an endpoint names the header its key travels in, or none" {
    const keyed: Endpoint = .{ .protocol = .anthropic_messages, .key_header = .x_api_key };
    try testing.expectEqual(ApiKeyHeader.x_api_key, keyed.mechanism().api_key);
    const open: Endpoint = .{ .protocol = .openai_chat };
    try testing.expect(open.mechanism() == .none);

    const both = [_]Endpoint{ keyed, open };
    try testing.expectEqual(&both[1], findEndpoint(&both, .openai_chat).?);
    try testing.expect(findEndpoint(&both, .openai_responses) == null);
}

test "a repeated header name is rejected whatever its case" {
    try testing.expect(!validHeaders(&.{
        .{ .name = "X-Trace", .value = "a" },
        .{ .name = "x-trace", .value = "b" },
    }));
}

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

test "every credential shape writes its own headers and no other" {
    for ([_]struct {
        name: []const u8,
        route: Route,
        credential: Credential,
        want: []const Header,
        absent: []const []const u8 = &.{},
        count: ?usize = null,
    }{
        .{
            .name = "anthropic api key",
            .route = .{ .base_url = "https://api.anthropic.com/v1", .protocol = .anthropic_messages, .auth = .{ .api_key = .x_api_key }, .headers = &.{.{ .name = "anthropic-version", .value = "2023-06-01" }} },
            .credential = .{ .api_key = "sk-secret" },
            .want = &.{ .{ .name = "x-api-key", .value = "sk-secret" }, .{ .name = "anthropic-version", .value = "2023-06-01" } },
            .absent = &.{"Authorization"},
        },
        .{
            .name = "compat host bearer",
            .route = .{ .base_url = "https://llm.acme/v1", .protocol = .anthropic_messages, .auth = .{ .api_key = .authorization_bearer } },
            .credential = .{ .api_key = "sk-2" },
            .want = &.{.{ .name = "Authorization", .value = "Bearer sk-2" }},
        },
        // An oauth grant is a bearer that carries its own identity header.
        .{
            .name = "oauth grant",
            .route = .{ .base_url = "https://chatgpt.com/backend-api/codex", .protocol = .openai_responses, .auth = .{ .api_key = .authorization_bearer }, .responses_dialect = .codex },
            .credential = .{ .oauth = .{ .access_token = "tok", .headers = &.{.{ .name = "ChatGPT-Account-ID", .value = "acct" }} } },
            .want = &.{ .{ .name = "Authorization", .value = "Bearer tok" }, .{ .name = "ChatGPT-Account-ID", .value = "acct" } },
        },
        // A keyless route writes the pinned header and nothing else.
        .{
            .name = "keyless route",
            .route = .{ .base_url = "http://127.0.0.1:11434/v1", .protocol = .openai_chat, .auth = .none, .headers = &.{.{ .name = "x-note", .value = "local" }} },
            .credential = .none,
            .want = &.{.{ .name = "x-note", .value = "local" }},
            .absent = &.{"Authorization"},
            .count = 1,
        },
    }) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.name});
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const out = try requestHeaders(arena.allocator(), &case.route, case.credential, "");
        if (case.count) |n| try testing.expectEqual(n, out.len);
        for (case.want) |h| try testing.expectEqualStrings(h.value, findHeader(out, h.name).?);
        for (case.absent) |name| try testing.expect(findHeader(out, name) == null);
    }
}

test "a pinned header that collides with the credential is rejected" {
    try testing.expectError(error.HeaderConflict, requestHeaders(testing.allocator, &.{
        .base_url = "x",
        .protocol = .anthropic_messages,
        .auth = .{ .api_key = .x_api_key },
        .headers = &.{.{ .name = "X-Api-Key", .value = "injected" }},
    }, .{ .api_key = "real" }, ""));
}

test "a pinned header that collides with an oauth identity header is rejected" {
    try testing.expectError(error.HeaderConflict, requestHeaders(testing.allocator, &.{
        .base_url = "x",
        .protocol = .openai_responses,
        .auth = .{ .api_key = .authorization_bearer },
        .headers = &.{.{ .name = "chatgpt-account-id", .value = "injected" }},
    }, .{ .oauth = .{
        .access_token = "tok",
        .headers = &.{.{ .name = "ChatGPT-Account-ID", .value = "acct" }},
    } }, ""));
}

test "a credential must match the authentication mechanism" {
    try testing.expectError(error.InvalidCredential, requestHeaders(testing.allocator, &.{
        .base_url = "https://example.test/v1",
        .protocol = .openai_chat,
        .auth = .{ .api_key = .authorization_bearer },
    }, .none, ""));
}

test "the route names the header that carries the session id, and a plain route names none" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var body = "{}".*;

    const codex: Route = .{
        .base_url = "https://chatgpt.com/backend-api/codex",
        .protocol = .openai_responses,
        .auth = .none,
        .responses_dialect = .codex,
        .session_header = .session_id,
    };
    const carried = try request(a, &codex, .none, "0123456789abcdef", &body);
    try testing.expectEqualStrings("0123456789abcdef", findHeader(carried.headers, "session-id").?);
    try testing.expect(findHeader(carried.headers, "x-opencode-session") == null);

    // The header follows the host, not the protocol: OpenCode reads it on every path it serves.
    for ([_]Protocol{ .anthropic_messages, .openai_chat, .openai_responses }) |protocol| {
        const opencode: Route = .{
            .base_url = "https://opencode.ai/zen/v1",
            .protocol = protocol,
            .auth = .none,
            .session_header = .x_opencode_session,
        };
        const sent = try request(a, &opencode, .none, "0123456789abcdef", &body);
        try testing.expectEqualStrings("0123456789abcdef", findHeader(sent.headers, "x-opencode-session").?);
        try testing.expect(findHeader(sent.headers, "session-id") == null);
    }

    // The public Responses endpoint routes on the body key, so a header there would be dead weight.
    const standard: Route = .{
        .base_url = "https://api.openai.com/v1",
        .protocol = .openai_responses,
        .auth = .none,
    };
    const plain = try request(a, &standard, .none, "0123456789abcdef", &body);
    try testing.expect(findHeader(plain.headers, "session-id") == null);
    try testing.expect(findHeader(plain.headers, "x-opencode-session") == null);

    // A caller that names no session leaves the header off rather than sending an empty one.
    const absent = try request(a, &codex, .none, "", &body);
    try testing.expect(findHeader(absent.headers, "session-id") == null);
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
        .session_header = .session_id,
        // A header name is case-insensitive, so a different spelling is the same header.
        .headers = &.{.{ .name = "Session-ID", .value = "from-the-route" }},
    };
    try testing.expectError(error.HeaderConflict, request(arena.allocator(), &route, .none, "0123456789abcdef", &body));

    // The same route serves a caller that names no session, because nothing is generated to collide.
    const built = try request(arena.allocator(), &route, .none, "", &body);
    try testing.expectEqualStrings("from-the-route", findHeader(built.headers, "session-id").?);
    try testing.expect(validHeaders(built.headers));
}

test "a route header std.http would abort on fails before any transport sees it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var body = "{}".*;
    for ([_]Header{
        .{ .name = "bad name", .value = "x" },
        .{ .name = "x-note", .value = "a\r\nb" },
    }) |pinned| {
        try testing.expectError(error.InvalidHeaders, request(arena.allocator(), &.{
            .base_url = "https://example.test/v1",
            .protocol = .openai_chat,
            .auth = .none,
            .headers = &.{pinned},
        }, .none, "", &body));
    }
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
    try testing.expectEqualStrings("sk-secret", findHeader(built.headers, "x-api-key").?);
    try testing.expectEqualStrings("2023-06-01", findHeader(built.headers, "anthropic-version").?);
    try testing.expectEqualStrings("{}", built.body);
}
