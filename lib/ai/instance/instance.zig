//! A provider instance holds request routing data and no credential.

const std = @import("std");
const types = @import("../types.zig");

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
pub const ResponsesDialect = @import("../request/ir.zig").ResponsesDialect;

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
