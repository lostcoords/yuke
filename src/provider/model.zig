//! The model vocabulary every provider source shares. A `*Patch` states what one source knows.

const ir = @import("request/ir.zig");

pub const ThinkingFormat = ir.ThinkingFormat;
pub const ReasoningReplay = ir.ReasoningReplay;
pub const MaxTokensField = ir.MaxTokensField;

/// An unknown value is a value. Never use zero, false, or an empty string to mean unknown.
pub fn Known(comptime T: type) type {
    return union(enum) {
        unknown,
        value: T,

        const Self = @This();

        /// Wrap a source patch field. An absent field becomes an unknown value.
        pub fn from(patch: ?T) Self {
            return if (patch) |v| .{ .value = v } else .unknown;
        }

        /// Return the value, or `fallback` when the source published none.
        pub fn orElse(self: Self, fallback: T) T {
            return switch (self) {
                .unknown => fallback,
                .value => |v| v,
            };
        }

        /// Return the value, or null. The wire omits an unknown value.
        pub fn optional(self: Self) ?T {
            return switch (self) {
                .unknown => null,
                .value => |v| v,
            };
        }
    };
}

// ── Source patches. A null field means the source does not publish that value. ──

/// A limit that the source does not publish stays null.
pub const LimitsPatch = struct {
    context_window: ?u64,
    max_output_tokens: ?u64,
};

/// A price that the source does not publish stays null. A null price is not a zero price.
pub const CostPatch = struct {
    input: ?f64,
    output: ?f64,
    cache_read: ?f64,
    cache_write: ?f64,
};

/// Name the credential scheme of a provider. The scheme never carries the secret.
pub const AuthKind = enum { api_key, oauth };

// ── Effective knowledge. No field here is optional. ──

pub const Limits = struct {
    context_window: Known(u64) = .unknown,
    max_output_tokens: Known(u64) = .unknown,
};

pub const Cost = struct {
    input: Known(f64) = .unknown,
    output: Known(f64) = .unknown,
    cache_read: Known(f64) = .unknown,
    cache_write: Known(f64) = .unknown,
};

pub const Caps = struct {
    tools: Known(bool) = .unknown,
    vision: Known(bool) = .unknown,
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
        min: Known(i64) = .unknown,
        max: Known(u64) = .unknown,
    };

    /// Build the budget from a source pair. Two absent bounds mean the model takes no budget.
    pub fn from(min: ?i64, max: ?u64) ReasoningBudget {
        if (min == null and max == null) return .unsupported;
        return .{ .range = .{ .min = .from(min), .max = .from(max) } };
    }
};

/// How a request asks this model to reason, and which output-token member it takes.
pub const Dialect = struct {
    thinking_format: ThinkingFormat = .none,
    reasoning_replay: ReasoningReplay = .none,
    max_tokens_field: MaxTokensField = .@"max-tokens",
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
};

const std = @import("std");
const testing = std.testing;

test "an unknown value is not a zero value" {
    const price: Known(f64) = .from(null);
    try testing.expect(price == .unknown);
    try testing.expectEqual(@as(f64, 0), price.orElse(0));
    try testing.expect(price.optional() == null);

    const free: Known(f64) = .from(@as(f64, 0));
    try testing.expect(free == .value);
    try testing.expectEqual(@as(?f64, 0), free.optional());
}

test "two absent bounds mean the model takes no thinking budget" {
    try testing.expect(ReasoningBudget.from(null, null) == .unsupported);

    const capped = ReasoningBudget.from(null, @as(u64, 32000));
    try testing.expect(capped == .range);
    try testing.expect(capped.range.min == .unknown);
    try testing.expectEqual(@as(?u64, 32000), capped.range.max.optional());
}

test "a null reasoning level means no effort" {
    try testing.expect(ReasoningLevel.from(null) == .none);
    try testing.expectEqualStrings("high", ReasoningLevel.from("high").named);
}
