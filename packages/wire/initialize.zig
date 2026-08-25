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

test "decode + fields" {
    const parsed = try std.json.parseFromSlice(InitializeParams, testing.allocator,
        \\{"protocol":1,"client":{"name":"yuke-tui","version":"0.0.0"}}
    , parse_opts);
    defer parsed.deinit();
    try testing.expectEqual(@as(u32, 1), parsed.value.protocol);
    try testing.expectEqualStrings("yuke-tui", parsed.value.client.name);
    try testing.expectEqualStrings("0.0.0", parsed.value.client.version);
}

test "protocol defaults when absent" {
    const parsed = try std.json.parseFromSlice(InitializeParams, testing.allocator,
        \\{"client":{"name":"c","version":"v"}}
    , parse_opts);
    defer parsed.deinit();
    try testing.expectEqual(protocol_version, parsed.value.protocol);
}

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

test "round-trip re-encodes to canonical JSON" {
    const p: InitializeParams = .{ .client = .{ .name = "yuke-tui", .version = "0.0.0" } };

    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try std.json.Stringify.value(p, .{}, &buf.writer);
    try testing.expectEqualStrings(
        \\{"protocol":1,"client":{"name":"yuke-tui","version":"0.0.0"}}
    , buf.written());
}
