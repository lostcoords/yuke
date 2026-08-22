//! Wire types for the `initialize` request.

const std = @import("std");

/// Protocol version this build speaks. A client must send exactly this.
pub const protocol_version: u32 = 1;

/// Connection-level client identity.
pub const Client = struct {
    /// Client connection name (e.g. `"yuke-tui"`).
    name: []const u8,
    /// Client build/version string.
    version: []const u8,
};

/// Params of `initialize`; `protocol` defaults to `protocol_version`.
pub const InitializeParams = struct {
    protocol: u32 = protocol_version,
    client: Client,
};

const testing = std.testing;

// Unknown fields are ignored; required fields remain enforced.
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
