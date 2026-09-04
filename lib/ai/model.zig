//! Provider sources share this model vocabulary. A `*Patch` states what one source knows.

const ir = @import("request/ir.zig");

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

/// A price the source does not publish stays null. A null price is not a zero price.
pub const Cost = struct {
    input: ?f64 = null,
    output: ?f64 = null,
    cache_read: ?f64 = null,
    cache_write: ?f64 = null,
};

pub const Caps = struct {
    tools: ?bool = null,
    /// True when the model takes some attachment. Read `Modalities` to learn which kind.
    vision: ?bool = null,
    structured_output: ?bool = null,
    /// Whether the model can stop reasoning. Null is unknown, so a caller may still ask.
    disable_reasoning: ?bool = null,
};

/// One kind a model reads or writes. A source name outside this set is dropped, never guessed.
pub const Modality = enum { text, image, audio, video, pdf };

/// What a model takes and what it returns.
pub const Modalities = struct {
    input: []const Modality = &.{},
    output: []const Modality = &.{},

    /// Report whether the model takes this kind, or null when the source lists none.
    pub fn takesInput(self: Modalities, kind: Modality) ?bool {
        if (self.input.len == 0) return null;
        for (self.input) |item| if (item == kind) return true;
        return false;
    }
};

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

/// One model in the shape every source shares. It holds no route and no secret.
pub const ModelSpec = struct {
    id: []const u8,
    upstream_id: []const u8,
    name: []const u8,
    limits: Limits = .{},
    cost: Cost = .{},
    caps: Caps = .{},
    reasoning_levels: []const ReasoningLevel = &.{},
    dialect: Dialect = .{},
    modalities: Modalities = .{},
    /// A release stage such as `beta`. The set is open, so an unknown stage is carried as it stands.
    status: ?[]const u8 = null,
};

const std = @import("std");
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

test "a null reasoning level means no effort" {
    try testing.expect(ReasoningLevel.from(null) == .none);
    try testing.expectEqualStrings("high", ReasoningLevel.from("high").named);
}
