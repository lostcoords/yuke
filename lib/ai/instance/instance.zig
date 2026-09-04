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

/// Define one provider. The protocol selects a closed request dialect.
pub const ProviderInstance = struct {
    base_url: []const u8,
    protocol: Protocol,
    auth: AuthMechanism,
    headers: []const Header = &.{},
    cache: ?CachePolicy = null,
    responses_dialect: ResponsesDialect = .standard,
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

test "a repeated header name is rejected whatever its case" {
    try testing.expect(!validHeaders(&.{
        .{ .name = "X-Trace", .value = "a" },
        .{ .name = "x-trace", .value = "b" },
    }));
}
