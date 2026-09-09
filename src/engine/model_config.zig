//! One gate for every model and reasoning choice a session stores.

const std = @import("std");
const registry = @import("../provider/registry.zig");
const Engine = @import("Engine.zig");

/// How a caller names the reasoning level.
pub const Reasoning = union(enum) {
    /// Take the level the model prefers.
    default,
    /// Take this level, or refuse when the model does not name it.
    explicit: []const u8,
    /// Take this level when the model names it, else the level the model prefers.
    inherit: []const u8,
};

/// The settings one session runs with. Both fields borrow the caller's arena.
pub const Resolved = struct {
    model: []const u8,
    reasoning: []const u8,
};

/// Check that the catalog serves `model` and settle its reasoning level. The result borrows `arena`.
pub fn validate(engine: *Engine, arena: std.mem.Allocator, model: []const u8, reasoning: Reasoning) !Resolved {
    const match = engine.deps.providers.merged.resolveModel(model) orelse return error.ModelUnknown;
    if (match.provider.availability == .unavailable) return switch (match.provider.availability.unavailable) {
        .needs_route => error.ModelRouteUnavailable,
        .needs_credential, .expired => error.ModelUnavailable,
    };
    if (registry.credential(match.provider.availability.ready.credential, engine.deps.env, engine.nowMillis()) == null) return error.ModelUnavailable;
    if (match.model.caps.tools != true) return error.ModelToolsUnsupported;
    // The merged registry can reload before the caller commits, so the arena keeps its own copies.
    const owned_model = try arena.dupe(u8, model);
    const normal = try registry.defaultLevel(arena, match.model.*);
    const names = try registry.levelNames(arena, match.model.*);
    const wanted: []const u8 = switch (reasoning) {
        .default => normal,
        .explicit => |level| level,
        .inherit => |level| if (named(names, level)) level else normal,
    };
    if (wanted.len == 0) {
        // A model with an effort to prefer must run with one.
        if (normal.len != 0) return error.ReasoningUnsupported;
        return .{ .model = owned_model, .reasoning = "" };
    }
    if (!named(names, wanted)) return error.ReasoningUnsupported;
    return .{ .model = owned_model, .reasoning = try arena.dupe(u8, wanted) };
}

fn named(names: []const []const u8, level: []const u8) bool {
    for (names) |candidate| if (std.mem.eql(u8, level, candidate)) return true;
    return false;
}
