//! Provider instances hold request routing data and no credential.

const std = @import("std");
const proto = @import("proto");

pub const Protocol = proto.enums.ProviderProtocol;

/// Select the API-key header.
pub const ApiKeyHeader = enum { x_api_key, authorization_bearer };

/// Select whether the endpoint accepts Anthropic `cache_control`.
pub const CachePolicy = enum { unsupported, ephemeral };

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

pub const Limits = struct {
    context_window: u64,
    max_output_tokens: u64,
};

pub const Cost = struct {
    input: f64 = 0,
    output: f64 = 0,
    cache_read: f64 = 0,
    cache_write: f64 = 0,
};

/// Select how prior assistant reasoning returns. The serializers own the vocabulary.
pub const ReasoningReplay = @import("../request/ir.zig").ReasoningReplay;

/// Select the request shape for reasoning control. The serializers own the vocabulary.
pub const ThinkingFormat = @import("../request/ir.zig").ThinkingFormat;

/// Select the output-token field. The serializers own the vocabulary.
pub const MaxTokensField = @import("../request/ir.zig").MaxTokensField;

/// Select the Responses flavor an endpoint speaks. The route owns it, because it follows the host.
pub const ResponsesDialect = @import("../request/ir.zig").ResponsesDialect;

/// Model flags shape request bodies without provider-specific branches.
pub const ModelFlags = struct {
    supports_vision: bool = false,
    supports_tools: bool = true,
    reasoning_replay: ReasoningReplay = .none,
    thinking_format: ThinkingFormat = .none,
    anthropic_adaptive: bool = false,
    reasoning_budget_min: ?i64 = null,
    reasoning_budget_max: ?u64 = null,
    max_tokens_field: MaxTokensField = .@"max-tokens",
};

/// Bind a public model ID to upstream data and request behavior.
pub const ModelBinding = struct {
    id: []const u8,
    upstream_id: []const u8,
    limits: Limits,
    cost: Cost = .{},
    /// The ordered levels a local model accepts. Null means no effort.
    reasoning_levels: []const ?[]const u8 = &.{},
    flags: ModelFlags = .{},
};

/// Define one provider. The protocol selects a closed request dialect.
pub const ProviderInstance = struct {
    base_url: []const u8,
    protocol: Protocol,
    auth: AuthMechanism,
    headers: []const Header = &.{},
    cache: CachePolicy = .unsupported,
    responses_dialect: ResponsesDialect = .standard,
};

const testing = std.testing;

test "decode a model with behavioral flags" {
    const json =
        \\{"id":"deepseek-r1","upstream_id":"deepseek-reasoner","limits":{"context_window":65536,"max_output_tokens":8192},
        \\ "reasoning_levels":[null,"high"],
        \\ "flags":{"reasoning_replay":"reasoning-content","thinking_format":"deepseek","max_tokens_field":"max-completion-tokens","supports_vision":true,"reasoning_budget_max":32000}}
    ;
    const parsed = try std.json.parseFromSlice(ModelBinding, testing.allocator, json, .{});
    defer parsed.deinit();
    const f = parsed.value.flags;
    try testing.expectEqual(ReasoningReplay.@"reasoning-content", f.reasoning_replay);
    try testing.expectEqual(ThinkingFormat.deepseek, f.thinking_format);
    try testing.expectEqual(MaxTokensField.@"max-completion-tokens", f.max_tokens_field);
    try testing.expect(f.supports_vision);
    try testing.expect(f.supports_tools); // The default is true.
    try testing.expectEqual(@as(?u64, 32000), f.reasoning_budget_max);
    try testing.expectEqual(@as(usize, 2), parsed.value.reasoning_levels.len);
    try testing.expect(parsed.value.reasoning_levels[0] == null);
    try testing.expectEqualStrings("high", parsed.value.reasoning_levels[1].?);
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
