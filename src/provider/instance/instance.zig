//! Provider instances hold protocol data and credential references, not secrets.
//! A new dialect uses a data row with a closed protocol value.

const std = @import("std");
const wire = @import("wire");

pub const Protocol = wire.enums.ProviderProtocol;

/// Selects the API-key header.
pub const ApiKeyHeader = enum { x_api_key, authorization_bearer };

/// Selects whether the endpoint accepts Anthropic `cache_control`.
pub const CachePolicy = enum { unsupported, ephemeral };

/// Names the source of a key. The source holds no key value.
pub const CredentialSource = union(enum) {
    env: []const u8,
    store: []const u8,
};

/// Selects the authentication scheme. The secret resolves by reference.
pub const Auth = union(enum) {
    api_key: ApiKey,
    codex_oauth: CodexOAuth,
    xai_oauth: XaiOAuth,
};

pub const ApiKey = struct {
    header: ApiKeyHeader,
    source: CredentialSource,
};

/// Names the Codex token and account-ID entries in the credential store.
pub const CodexOAuth = struct {
    store: []const u8,
    account_store: []const u8,
};

pub const XaiOAuth = struct {
    store: []const u8,
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

/// Selects how prior assistant reasoning returns in an OpenAI Chat request.
pub const ReasoningReplay = enum { none, reasoning, @"reasoning-content", @"reasoning-details" };

/// Selects the request shape for reasoning control. This enum keeps a compat quirk as data.
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

/// Selects the output-token field in the OpenAI Chat request.
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

/// Binds a public model ID to upstream data and request behavior.
pub const ModelBinding = struct {
    id: []const u8,
    upstream_id: []const u8,
    limits: Limits,
    cost: Cost = .{},
    flags: ModelFlags = .{},
};

/// Defines one provider. The protocol selects a closed request dialect.
pub const ProviderInstance = struct {
    id: []const u8,
    base_url: []const u8,
    protocol: Protocol,
    auth: Auth,
    headers: []const Header = &.{},
    cache: CachePolicy = .unsupported,
    models: []const ModelBinding = &.{},
};

/// Defines the providers.json document for user and built-in configuration.
pub const Config = struct {
    providers: []const ProviderInstance = &.{},
};

const testing = std.testing;
const parse_opts: std.json.ParseOptions = .{ .ignore_unknown_fields = true };

test "decode an anthropic provider with an env api key" {
    const json =
        \\{"providers":[
        \\  {"id":"anthropic","base_url":"https://api.anthropic.com/v1","protocol":"anthropic-messages",
        \\   "auth":{"api_key":{"header":"x_api_key","source":{"env":"ANTHROPIC_API_KEY"}}},
        \\   "headers":[{"name":"anthropic-version","value":"2023-06-01"}],
        \\   "cache":"ephemeral",
        \\   "models":[{"id":"opus","upstream_id":"claude-opus-4-8","limits":{"context_window":200000,"max_output_tokens":16000},"cost":{"input":15,"output":75}}]}
        \\]}
    ;
    const parsed = try std.json.parseFromSlice(Config, testing.allocator, json, parse_opts);
    defer parsed.deinit();

    const p = parsed.value.providers[0];
    try testing.expectEqualStrings("anthropic", p.id);
    try testing.expectEqual(Protocol.@"anthropic-messages", p.protocol);
    try testing.expectEqual(ApiKeyHeader.x_api_key, p.auth.api_key.header);
    try testing.expectEqualStrings("ANTHROPIC_API_KEY", p.auth.api_key.source.env);
    try testing.expectEqualStrings("anthropic-version", p.headers[0].name);
    try testing.expectEqual(CachePolicy.ephemeral, p.cache);
    try testing.expectEqualStrings("claude-opus-4-8", p.models[0].upstream_id);
    try testing.expectEqual(@as(u64, 16000), p.models[0].limits.max_output_tokens);
}

test "decode a model with behavioral flags" {
    const json =
        \\{"id":"deepseek-r1","upstream_id":"deepseek-reasoner","limits":{"context_window":65536,"max_output_tokens":8192},
        \\ "flags":{"reasoning_replay":"reasoning-content","thinking_format":"deepseek","max_tokens_field":"max-completion-tokens","supports_vision":true,"reasoning_budget_max":32000}}
    ;
    const parsed = try std.json.parseFromSlice(ModelBinding, testing.allocator, json, parse_opts);
    defer parsed.deinit();
    const f = parsed.value.flags;
    try testing.expectEqual(ReasoningReplay.@"reasoning-content", f.reasoning_replay);
    try testing.expectEqual(ThinkingFormat.deepseek, f.thinking_format);
    try testing.expectEqual(MaxTokensField.@"max-completion-tokens", f.max_tokens_field);
    try testing.expect(f.supports_vision);
    try testing.expect(f.supports_tools); // The default is true.
    try testing.expectEqual(@as(?u64, 32000), f.reasoning_budget_max);
}

test "decode a codex oauth provider" {
    const json =
        \\{"providers":[
        \\  {"id":"openai-codex","base_url":"https://chatgpt.com/backend-api/codex","protocol":"openai-responses",
        \\   "auth":{"codex_oauth":{"store":"chatgpt-oauth","account_store":"chatgpt-account-id"}}}
        \\]}
    ;
    const parsed = try std.json.parseFromSlice(Config, testing.allocator, json, parse_opts);
    defer parsed.deinit();

    const p = parsed.value.providers[0];
    try testing.expectEqual(Protocol.@"openai-responses", p.protocol);
    try testing.expectEqualStrings("chatgpt-oauth", p.auth.codex_oauth.store);
    try testing.expectEqual(CachePolicy.unsupported, p.cache); // The default is unsupported.
    try testing.expectEqual(@as(usize, 0), p.models.len);
}

test "a provider round-trips through JSON" {
    const provider: ProviderInstance = .{
        .id = "acme",
        .base_url = "https://llm.acme.example/v1",
        .protocol = .@"openai-completions",
        .auth = .{ .api_key = .{ .header = .authorization_bearer, .source = .{ .store = "acme" } } },
    };
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try std.json.Stringify.value(provider, .{ .emit_null_optional_fields = false }, &buf.writer);

    const parsed = try std.json.parseFromSlice(ProviderInstance, testing.allocator, buf.written(), parse_opts);
    defer parsed.deinit();
    try testing.expectEqualStrings("acme", parsed.value.id);
    try testing.expectEqual(ApiKeyHeader.authorization_bearer, parsed.value.auth.api_key.header);
    try testing.expectEqualStrings("acme", parsed.value.auth.api_key.source.store);
}
