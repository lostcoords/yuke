//! Shared request configuration for turns and compaction.

const std = @import("std");
const proto = @import("proto");
const ai = @import("ai");
const Engine = @import("Engine.zig");
const RunSlot = @import("run.zig").RunSlot;
const registry = @import("../provider/registry.zig");
const database = @import("../store/store.zig");
const context = @import("context.zig");

/// Use the advertised ceiling unless it reaches the known context, when yuke's safe default leaves room for input.
pub fn outputLimit(model: *const registry.ModelSpec) u32 {
    const advertised = model.limits.max_output_tokens orelse return context.default_max_output;
    const limit = std.math.cast(u32, advertised) orelse context.default_max_output;
    if (model.limits.context_window) |window| {
        if (window > 0 and advertised >= window)
            return @min(context.default_max_output, limit);
    }
    return limit;
}

test "an output ceiling at context leaves room for input" {
    const t = std.testing;
    var model: registry.ModelSpec = .{ .id = "m", .upstream_id = "m", .name = "m", .protocol = .openai_chat };
    const Case = struct { limits: @TypeOf(model.limits), want: u32 };
    for ([_]Case{
        .{ .limits = .{}, .want = context.default_max_output },
        .{ .limits = .{ .context_window = 500_000, .max_output_tokens = 4_096 }, .want = 4_096 },
        .{ .limits = .{ .context_window = 500_000, .max_output_tokens = 500_000 }, .want = context.default_max_output },
        .{ .limits = .{ .context_window = 100_000, .max_output_tokens = 500_000 }, .want = context.default_max_output },
        .{ .limits = .{ .context_window = 500_000, .max_output_tokens = 450_000 }, .want = 450_000 },
        .{ .limits = .{ .context_window = 0, .max_output_tokens = 450_000 }, .want = 450_000 },
        .{ .limits = .{ .context_window = 500_000, .max_output_tokens = 0 }, .want = 0 },
        .{ .limits = .{ .max_output_tokens = @as(u64, std.math.maxInt(u32)) + 1 }, .want = context.default_max_output },
    }) |case| {
        model.limits = case.limits;
        try t.expectEqual(case.want, outputLimit(&model));
    }
}

/// Map a configured reasoning level onto one model. An empty level leaves the provider default.
pub fn reasoningFor(
    model: *const registry.ModelSpec,
    level: []const u8,
    output_limit: u32,
) !ai.ir.ReasoningControl {
    if (level.len == 0) return .default;
    if (std.mem.eql(u8, level, "off")) {
        // A model that states it cannot stop would reject the control, so refuse before the request.
        if (model.caps.disable_reasoning) |can| if (!can) return error.UnsupportedReasoning;
        return .off;
    }
    if (model.reasoning_levels.len != 0 and !hasReasoningLevel(model.reasoning_levels, level))
        return error.UnsupportedReasoning;
    if (model.dialect.anthropic_adaptive) return .adaptive;
    if (thinkingBudget(model, output_limit)) |tokens| return .{ .budget = tokens };
    const effort = std.meta.stringToEnum(ai.ir.Effort, level) orelse return error.UnsupportedReasoning;
    return .{ .effort = effort };
}

fn hasReasoningLevel(levels: []const ai.model.ReasoningLevel, wanted: []const u8) bool {
    for (levels) |level| switch (level) {
        .none => {},
        .named => |name| if (std.mem.eql(u8, name, wanted)) return true,
    };
    return false;
}

/// The smallest budget an Anthropic-shaped endpoint accepts.
const thinking_budget_min: u64 = 1024;

/// Anthropic starts a complex task at this absolute budget, while larger budgets need batch processing.
const thinking_budget_default: u64 = 16_000;

/// Choose the thinking budget. Anthropic states absolute starting points, never a share of the ceiling.
fn thinkingBudget(model: *const registry.ModelSpec, output_limit: u32) ?u64 {
    const bounds = switch (model.dialect.reasoning_budget) {
        .unsupported => return null,
        .range => |range| range,
    };

    var budget: u64 = thinking_budget_default;
    if (bounds.max) |maximum| budget = @min(budget, maximum);
    if (bounds.min) |minimum| {
        if (minimum > 0) budget = @max(budget, @as(u64, @intCast(minimum)));
    }
    budget = @max(budget, thinking_budget_min);

    // The budget must leave room for the answer, so a ceiling it cannot fit under sends none.
    return if (budget >= output_limit) null else budget;
}

/// The tools this run may see: spawn tools below the depth limit, and the skill tool with a catalog.
pub fn selectionFor(engine: *Engine, arena: std.mem.Allocator, slot: *RunSlot) !@import("toolset.zig").Selection {
    // A reload refuses an active run, so one read per run answers every round and tool call.
    if (slot.has_skills == null) slot.has_skills = try database.session.hasSkills(engine.deps.db, arena, slot.sessionId().raw);
    return .{ .can_spawn = slot.depth < engine.max_agent_depth, .has_skills = slot.has_skills.? };
}

/// Build the session request configuration once before any context decision.
pub fn buildConfig(arena: std.mem.Allocator, engine: *Engine, slot: *RunSlot, model: *const registry.ModelSpec) !RequestBuild {
    var build: RequestBuild = .{
        .model = model.upstream_id,
        .system = slot.config.system_prompt,
        .tools = try engine.deps.tools.getDecls(engine.deps.tools.ctx, arena, try selectionFor(engine, arena, slot)),
        .max_output_tokens = outputLimit(model),
    };
    if (engine.deps.hooks.holds(engine.deps.hooks.ctx, .@"request.build")) {
        const hook_payload = .{
            .model = build.model,
            .system = build.system,
            .tools = build.tools,
            .max_output_tokens = build.max_output_tokens,
            .context = .{
                .session_id = slot.sessionId(),
                .parent_id = slot.parent_id,
                .workspace = slot.config.root,
                .agent_name = slot.config.name orelse "root",
                .prompt = try database.session.promptParts(engine.deps.db, arena, slot.sessionId().raw),
            },
        };
        switch (engine.deps.hooks.askIfHeld(arena, .@"request.build", hook_payload)) {
            .proceed => {},
            // A handler that answers an unreadable request keeps the one this round already holds.
            .replace => |value| build = std.json.parseFromValueLeaky(RequestBuild, arena, value, .{ .ignore_unknown_fields = true }) catch blk: {
                std.log.warn("run {d} request.build answered an unreadable request; the round keeps its own", .{slot.runId()});
                break :blk build;
            },
            .block => |reason| {
                // The wire message names a class, so record the reason before the error loses it.
                std.log.warn("run {d} stopped at request.build: {s}", .{ slot.runId(), reason });
                return error.HookBlocked;
            },
            .canceled => return error.Canceled,
        }
    }

    if (build.system.len > proto.meta.limits.max_message_string_bytes) return error.PromptTooLarge;
    return build;
}

/// The build hook omits transcript blocks to avoid copies of attachment data.
pub const RequestBuild = struct {
    model: []const u8,
    system: []const u8,
    tools: []const ai.ir.Tool,
    max_output_tokens: u32,
};

test "an unset level omits the control and off disables it" {
    const model: registry.ModelSpec = .{ .id = "m", .upstream_id = "m", .name = "m", .protocol = .openai_chat };
    try std.testing.expectEqual(ai.ir.ReasoningControl.default, try reasoningFor(&model, "", 8192));
    try std.testing.expectEqual(ai.ir.ReasoningControl.off, try reasoningFor(&model, "off", 8192));
}

test "an adaptive row resolves to adaptive for every level that is not off" {
    const model: registry.ModelSpec = .{ .id = "m", .upstream_id = "m", .name = "m", .protocol = .openai_chat, .reasoning_levels = &.{.{ .named = "high" }}, .dialect = .{ .anthropic_adaptive = true } };
    try std.testing.expectEqual(ai.ir.ReasoningControl.adaptive, try reasoningFor(&model, "high", 8192));
    try std.testing.expectEqual(ai.ir.ReasoningControl.off, try reasoningFor(&model, "off", 8192));
}

test "a budget row states one budget, whatever effort the caller names" {
    const model: registry.ModelSpec = .{
        .id = "m",
        .upstream_id = "m",
        .name = "m",
        .protocol = .anthropic_messages,
        .reasoning_levels = &.{ .{ .named = "max" }, .{ .named = "high" } },
        .dialect = .{ .reasoning_budget = .from(1024, 32000) },
    };
    // Anthropic publishes absolute starting points, so the level never scales the budget.
    try std.testing.expectEqual(@as(u64, 16000), (try reasoningFor(&model, "max", 64000)).budget);
    try std.testing.expectEqual(@as(u64, 16000), (try reasoningFor(&model, "high", 64000)).budget);
}

test "a budget is clamped by the feed bounds and refused when it reaches the ceiling" {
    const capped: registry.ModelSpec = .{ .id = "m", .upstream_id = "m", .name = "m", .protocol = .openai_chat, .reasoning_levels = &.{.{ .named = "high" }}, .dialect = .{ .reasoning_budget = .from(null, 2000) } };
    try std.testing.expectEqual(@as(u64, 2000), (try reasoningFor(&capped, "high", 8192)).budget);

    // A budget that reaches the ceiling falls back to the effort control.
    const tiny: registry.ModelSpec = .{ .id = "m", .upstream_id = "m", .name = "m", .protocol = .openai_chat, .reasoning_levels = &.{.{ .named = "high" }}, .dialect = .{ .reasoning_budget = .from(1024, null) } };
    try std.testing.expectEqual(ai.ir.Effort.high, (try reasoningFor(&tiny, "high", 1024)).effort);

    // The published maximum still wins, so a model that caps itself below the default is honoured.
    try std.testing.expectEqual(@as(u64, 2000), (try reasoningFor(&capped, "high", 64000)).budget);
}

test "a selected level outside the model list is unsupported" {
    const model: registry.ModelSpec = .{ .id = "m", .upstream_id = "m", .name = "m", .protocol = .openai_chat, .reasoning_levels = &.{.{ .named = "high" }} };
    try std.testing.expectError(error.UnsupportedReasoning, reasoningFor(&model, "turbo", 8192));
    try std.testing.expectEqual(ai.ir.Effort.high, (try reasoningFor(&model, "high", 8192)).effort);

    const unlisted: registry.ModelSpec = .{ .id = "m", .upstream_id = "m", .name = "m", .protocol = .openai_chat };
    try std.testing.expectError(error.UnsupportedReasoning, reasoningFor(&unlisted, "turbo", 8192));
}
