//! Wire types for the `initialize` request.

const std = @import("std");

/// This build speaks this protocol version. A client must send this exact value.
pub const protocol_version: u32 = 1;

/// This type identifies the client connection.
pub const Client = struct {
    /// The client connection name.
    name: []const u8,
    /// The client build version.
    version: []const u8,
};

/// These are the parameters for `initialize`. The `protocol` field defaults to `protocol_version`.
pub const InitializeParams = struct {
    protocol: u32 = protocol_version,
    client: Client,
};

const testing = std.testing;

// The decoder ignores unknown fields. It still requires fields without defaults.
const parse_opts: std.json.ParseOptions = .{ .ignore_unknown_fields = true };

test "unknown key ignored, not rejected" {
    const parsed = try std.json.parseFromSlice(InitializeParams, testing.allocator,
        \\{"client":{"name":"c","version":"v"},"future_field":123}
    , parse_opts);
    defer parsed.deinit();
    try testing.expectEqualStrings("c", parsed.value.client.name);
}

test "missing required field rejected" {
    try testing.expectError(error.MissingField, std.json.parseFromSlice(InitializeParams, testing.allocator,
        \\{"protocol":1}
    , parse_opts));
}
