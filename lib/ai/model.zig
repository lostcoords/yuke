//! Provider sources share this model vocabulary. A `*Patch` states what one source knows.

const std = @import("std");
const ir = @import("request/ir.zig");
const types = @import("types.zig");

pub const ThinkingFormat = ir.ThinkingFormat;
pub const ReasoningReplay = ir.ReasoningReplay;
pub const MaxTokensField = ir.MaxTokensField;

// ── What a source knows. Null is unknown, and never zero, false, or an empty string. ──

/// Name the credential scheme of a provider. The scheme never carries the secret.
pub const AuthKind = enum { api_key, oauth };

/// A limit the source does not publish stays null.
pub const Limits = struct {
    context_window: ?u64 = null,
    max_output_tokens: ?u64 = null,
};

/// The prices of one band, in US dollars per million tokens. A null price is unknown, and never zero.
pub const PriceBand = struct {
    /// The smallest prompt this band prices. The prompt counts every input token, the cached ones too.
    min_prompt_tokens: u64 = 0,
    input: ?f64 = null,
    output: ?f64 = null,
    /// A reasoning token is also an output token. This price replaces the output price for it.
    reasoning: ?f64 = null,
    cache_read: ?f64 = null,
    cache_write: ?f64 = null,
};

/// The cost of a model that the source does not price: one band of unknown prices.
pub const unknown_cost: []const PriceBand = &.{.{}};

/// Report whether `bands` is a cost: the first band starts at 0, the thresholds rise, and no price is negative.
pub fn validCost(bands: []const PriceBand) bool {
    if (bands.len == 0 or bands[0].min_prompt_tokens != 0) return false;
    for (bands, 0..) |band, i| {
        if (i > 0 and band.min_prompt_tokens <= bands[i - 1].min_prompt_tokens) return false;
        inline for (.{ "input", "output", "reasoning", "cache_read", "cache_write" }) |name| {
            if (@field(band, name)) |price| if (!(price >= 0)) return false;
        }
    }
    return true;
}

pub const Caps = struct {
    tools: ?bool = null,
    /// Deferred tools and tool references need explicit support for the resolved model and endpoint.
    tool_search: ?bool = null,
    /// True when the model takes some attachment. Read `Modalities` to learn which kind.
    vision: ?bool = null,
    /// Whether the model can stop reasoning. Null is unknown, so a caller may still ask.
    disable_reasoning: ?bool = null,
    /// Whether the model accepts an explicit marker. MiniMax M3 caches and refuses one.
    cache_breakpoint: ?bool = null,
};

/// One kind a model reads or writes. The request IR names the same set.
pub const Modality = types.Modality;

/// What a model takes and what it returns. The request IR reads the same shape.
pub const Modalities = types.Modalities;

/// One reasoning effort a user can pick. A source writes null to mean "no effort at all".
pub const ReasoningLevel = union(enum) {
    none,
    named: []const u8,

    /// Wrap a source level. The nullable element of a source list means "no effort".
    pub fn from(patch: ?[]const u8) ReasoningLevel {
        return if (patch) |name| .{ .named = name } else .none;
    }
};

/// The thinking-budget bounds. A model with no budget control reports `unsupported`.
pub const ReasoningBudget = union(enum) {
    unsupported,
    range: Range,

    pub const Range = struct {
        min: ?i64 = null,
        max: ?u64 = null,
    };

    /// Build the budget from a source pair. Two absent bounds mean the model takes no budget.
    pub fn from(min: ?i64, max: ?u64) ReasoningBudget {
        if (min == null and max == null) return .unsupported;
        return .{ .range = .{ .min = min, .max = max } };
    }
};

/// How a request asks this model to reason, and which output-token member it takes.
pub const Dialect = struct {
    thinking_format: ThinkingFormat = .none,
    reasoning_replay: ReasoningReplay = .none,
    max_tokens_field: MaxTokensField = .max_tokens,
    anthropic_adaptive: bool = false,
    reasoning_budget: ReasoningBudget = .unsupported,
};

/// One model in the shape every source shares. It holds no URL and no secret.
pub const ModelSpec = struct {
    id: []const u8,
    upstream_id: []const u8,
    name: []const u8,
    /// Name the endpoint that serves this model. A host can serve several endpoints.
    protocol: types.Protocol,
    limits: Limits = .{},
    /// The price bands in threshold order. The last band that the prompt reaches prices the whole request.
    cost: []const PriceBand = unknown_cost,
    caps: Caps = .{},
    reasoning_levels: []const ReasoningLevel = &.{},
    dialect: Dialect = .{},
    modalities: Modalities = .{},
};

const testing = std.testing;

test "two absent bounds mean the model takes no thinking budget" {
    try testing.expect(ReasoningBudget.from(null, null) == .unsupported);

    // A published zero is a value. Only null reports that the source knows nothing.
    const free = ReasoningBudget.from(@as(i64, 0), null);
    try testing.expectEqual(@as(?i64, 0), free.range.min);
    try testing.expect(free.range.max == null);

    const capped = ReasoningBudget.from(null, @as(u64, 32000));
    try testing.expect(capped == .range);
    try testing.expect(capped.range.min == null);
    try testing.expectEqual(@as(?u64, 32000), capped.range.max);
}

test "an input kind is unknown until the source lists one" {
    const none: Modalities = .{};
    try testing.expect(none.takesInput(.image) == null); // A source that lists nothing blocks nothing.

    const text_only: Modalities = .{ .input = &.{.text}, .output = &.{.text} };
    try testing.expectEqual(false, text_only.takesInput(.image).?);
    try testing.expectEqual(true, text_only.takesInput(.text).?);

    const vision: Modalities = .{ .input = &.{ .text, .image, .pdf } };
    try testing.expectEqual(true, vision.takesInput(.pdf).?);
    try testing.expectEqual(false, vision.takesInput(.audio).?);
}

test "a cost starts at zero, rises, and holds no negative price" {
    try testing.expect(validCost(unknown_cost));
    try testing.expect(validCost(&.{ .{ .input = 4 }, .{ .min_prompt_tokens = 272_001, .input = 8 } }));
    try testing.expect(!validCost(&.{}));
    try testing.expect(!validCost(&.{.{ .min_prompt_tokens = 1 }}));
    try testing.expect(!validCost(&.{ .{}, .{ .min_prompt_tokens = 9 }, .{ .min_prompt_tokens = 9 } }));
    try testing.expect(!validCost(&.{ .{}, .{ .min_prompt_tokens = 9 }, .{ .min_prompt_tokens = 5 } }));
    try testing.expect(!validCost(&.{ .{}, .{ .min_prompt_tokens = 9, .cache_write = -1 } }));
}

test "a null reasoning level means no effort" {
    try testing.expect(ReasoningLevel.from(null) == .none);
    try testing.expectEqualStrings("high", ReasoningLevel.from("high").named);
}
