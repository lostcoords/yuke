//! The baked provider table and the selector split.

const std = @import("std");
const generated = @import("catalog_gen.zig");
const model = @import("model.zig");

pub const Provider = generated.Provider;
pub const Auth = generated.Auth;
pub const providers = generated.providers;
pub const revision = generated.revision;
pub const find = generated.find;

pub const Error = error{MalformedSelector};

/// The two halves of a `provider/model` selector.
pub const Selector = struct {
    provider: []const u8,
    model: []const u8,
};

/// Split `provider/model` on the first slash, because a model id may hold further slashes.
pub fn split(selector: []const u8) Error!Selector {
    const slash = std.mem.indexOfScalar(u8, selector, '/') orelse return Error.MalformedSelector;
    const parts: Selector = .{ .provider = selector[0..slash], .model = selector[slash + 1 ..] };
    if (parts.provider.len == 0 or parts.model.len == 0) return Error.MalformedSelector;
    return parts;
}

const testing = std.testing;

test "a selector splits on the first slash" {
    const parts = try split("anthropic/claude-fable-5");
    try testing.expectEqualStrings("anthropic", parts.provider);
    try testing.expectEqualStrings("claude-fable-5", parts.model);

    // An OpenRouter model id holds its own slash, so only the first one divides the selector.
    const nested = try split("openrouter/amazon/nova-2-lite-v1");
    try testing.expectEqualStrings("openrouter", nested.provider);
    try testing.expectEqualStrings("amazon/nova-2-lite-v1", nested.model);

    // The baked table really does carry such ids, so the rule above is not a hypothetical.
    const row = find("openrouter").?;
    var buf: [512]u8 = undefined;
    const built = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ row.id, row.models[0].id });
    const real = try split(built);
    try testing.expectEqualStrings("openrouter", real.provider);
    try testing.expectEqualStrings(row.models[0].id, real.model);
    try testing.expect(std.mem.indexOfScalar(u8, real.model, '/') != null);

    try testing.expectError(Error.MalformedSelector, split("anthropic"));
    try testing.expectError(Error.MalformedSelector, split("/claude"));
    try testing.expectError(Error.MalformedSelector, split("anthropic/"));
}

test "catalog errors have a permanent user-facing classification" {
    const failure = @import("failure.zig");
    // A catalog error that classifies as unknown would hide a caller's selector mistake.
    inline for (@typeInfo(Error).error_set.?) |raised| {
        const got = failure.classify(@field(anyerror, raised.name));
        try testing.expectEqual(failure.Class.permanent, got.class);
        try testing.expect(got.reason != .unknown);
    }
}

test "baked tool search support remains specific to the provider and model" {
    try testing.expectEqual(@as(?bool, true), bakedCaps("openai", "gpt-5.4").tool_search);
    try testing.expectEqual(@as(?bool, false), bakedCaps("openai", "gpt-5.4-nano").tool_search);
    // The producer states Codex support after a live verification on the backend.
    try testing.expectEqual(@as(?bool, true), bakedCaps("openai-codex", "gpt-5.4").tool_search);
    try testing.expectEqual(@as(?bool, false), bakedCaps("openai-codex", "gpt-5.4-nano").tool_search);
    try testing.expectEqual(@as(?bool, true), bakedCaps("anthropic", "claude-opus-4-6").tool_search);
}

fn bakedCaps(provider_id: []const u8, model_id: []const u8) model.Caps {
    for (find(provider_id).?.models) |spec| if (std.mem.eql(u8, spec.id, model_id)) return spec.caps;
    unreachable;
}
