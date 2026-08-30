//! Provider instances hold request routing data and no credentials.
//! A new dialect uses a data row with a closed protocol value.

const std = @import("std");
const wire = @import("wire");

pub const Protocol = wire.enums.ProviderProtocol;

/// Select the API-key header.
pub const ApiKeyHeader = enum { x_api_key, authorization_bearer };

/// Select whether the endpoint accepts Anthropic `cache_control`.
pub const CachePolicy = enum { unsupported, ephemeral };

/// Select the authentication scheme. Credentials stay outside the provider instance.
pub const Auth = union(enum) {
    api_key: ApiKeyHeader,
    codex_oauth,
    xai_oauth,
};

/// A pinned non-secret request header.
pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

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

/// Select how prior assistant reasoning returns in an OpenAI Chat request.
pub const ReasoningReplay = enum { none, reasoning, @"reasoning-content", @"reasoning-details" };

/// Select the request shape for reasoning control. This enum keeps a compatibility quirk as data.
pub const ThinkingFormat = enum {
    none,
    openai,
    openrouter,
    deepseek,
    zai,
    qwen,
    together,
    @"string-thinking",
    @"ant-ling",
};

/// Select the output-token field in the OpenAI Chat request.
pub const MaxTokensField = enum { @"max-completion-tokens", @"max-tokens" };

/// Model flags shape request bodies without provider-specific branches.
pub const ModelFlags = struct {
    supports_temperature: bool = true,
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
    flags: ModelFlags = .{},
};

/// Define one provider. The protocol selects a closed request dialect.
pub const ProviderInstance = struct {
    id: []const u8,
    base_url: []const u8,
    protocol: Protocol,
    auth: Auth,
    headers: []const Header = &.{},
    cache: CachePolicy = .unsupported,
};

const testing = std.testing;

test "decode a model with behavioral flags" {
    const json =
        \\{"id":"deepseek-r1","upstream_id":"deepseek-reasoner","limits":{"context_window":65536,"max_output_tokens":8192},
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
}

test "a provider round-trips through JSON" {
    const provider: ProviderInstance = .{
        .id = "acme",
        .base_url = "https://llm.acme.example/v1",
        .protocol = .openai_chat,
        .auth = .{ .api_key = .authorization_bearer },
    };
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try std.json.Stringify.value(provider, .{ .emit_null_optional_fields = false }, &buf.writer);

    const parsed = try std.json.parseFromSlice(ProviderInstance, testing.allocator, buf.written(), .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("acme", parsed.value.id);
    try testing.expectEqual(ApiKeyHeader.authorization_bearer, parsed.value.auth.api_key);
}
