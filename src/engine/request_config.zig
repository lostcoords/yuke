//! Shared request configuration for turns and compaction.

const std = @import("std");
const proto = @import("proto");
const ai = @import("ai");
const Engine = @import("Engine.zig");
const Loadout = @import("../session/session.zig").Loadout;
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

/// The session facts every hook payload carries.
pub const HookContext = struct {
    session_id: proto.ids.SessionId,
    parent_id: ?proto.ids.SessionId,
    depth: u32,
    /// The engine owns this limit, so a plugin reads it here and keeps no default of its own.
    max_agent_depth: u32,
    agent_name: []const u8,
    workspace: []const u8,
    has_skills: bool,
};

pub fn hookContext(engine: *const Engine, slot: *const RunSlot, has_skills: bool) HookContext {
    std.debug.assert(engine.max_agent_depth > 0);
    return .{ .session_id = slot.sessionId(), .parent_id = slot.parent_id, .depth = slot.depth, .max_agent_depth = engine.max_agent_depth, .agent_name = slot.config.name orelse "root", .workspace = slot.config.root, .has_skills = has_skills };
}

/// The tools this run may see, chosen once at its first request. `tools.select` may narrow the list; the answer holds for the run.
pub fn loadout(engine: *Engine, arena: std.mem.Allocator, slot: *RunSlot) !*Loadout {
    if (slot.tools) |*held| return held;
    const tools = engine.deps.tools;
    const names = try tools.names(tools.ctx, arena);
    const has_skills = try database.session.hasSkills(engine.deps.db, arena, slot.sessionId().raw);
    const Chosen = struct { tools: []const []const u8 };
    var chosen = names;
    switch (engine.deps.hooks.askIfHeld(arena, .@"tools.select", .{ .tools = names, .context = hookContext(engine, slot, has_skills) })) {
        .proceed => {},
        // An unreadable answer is a plugin bug, and the run fails closed like it does on a throw.
        .replace => |value| chosen = (std.json.parseFromValueLeaky(Chosen, arena, value, .{ .ignore_unknown_fields = true }) catch return error.HookAnswerInvalid).tools,
        .block => |reason| {
            std.log.warn("run {d} stopped at tools.select: {s}", .{ slot.runId(), reason });
            return error.HookBlocked;
        },
        .canceled => return error.Canceled,
    }
    var held: Loadout = .{ .arena = .init(engine.deps.gpa), .names = &.{}, .decls = &.{}, .has_skills = has_skills };
    errdefer held.arena.deinit();
    const own = held.arena.allocator();
    const copied = try own.alloc([]const u8, chosen.len);
    for (chosen, 0..) |name, i| copied[i] = try own.dupe(u8, name);
    held.names = copied;
    held.decls = try tools.getDecls(tools.ctx, own, copied);
    slot.tools = held;
    return &slot.tools.?;
}

/// Defer definitions only when they take at least this share of the context window; Claude Code uses the same default.
const deferral_threshold_percent: u64 = 10;
const search_tool_name = ai.ir.search_tool_name;

/// A route with native client search loads a found definition in place; every other route omits it until a search adds it.
fn decideDeferral(held: *Loadout, spec: *const registry.ModelSpec) !void {
    const own = held.arena.allocator();
    if (!try deferralApplies(spec, held.decls)) {
        held.request_tools = try eagerDecls(own, held.decls);
    } else if (spec.caps.tool_search == true and spec.protocol != .openai_chat) {
        held.deferral = .native;
        held.request_tools = held.decls;
    } else {
        held.deferral = .omitted;
        held.request_tools = try omitDeferred(own, held.decls);
    }
}

/// Deferral needs the search tool in the loadout and a deferred catalog at the threshold.
fn deferralApplies(spec: *const registry.ModelSpec, decls: []const ai.ir.Tool) !bool {
    var deferred_bytes: u64 = 0;
    var searchable = false;
    for (decls) |decl| {
        if (decl.defer_loading) deferred_bytes += try context.jsonBytes(decl);
        searchable = searchable or (!decl.defer_loading and std.mem.eql(u8, decl.name, search_tool_name));
    }
    if (!searchable) return false;
    const window = spec.limits.context_window orelse context.default_context_window;
    // The window is peer input, so the threshold divides instead of multiplying into an overflow.
    const threshold = window / deferral_threshold_percent + @intFromBool(window % deferral_threshold_percent != 0);
    return context.tokensFor(deferred_bytes) >= threshold;
}

/// Keep the eager declarations only. A search adds a deferred one when the model needs it.
fn omitDeferred(own: std.mem.Allocator, decls: []const ai.ir.Tool) ![]const ai.ir.Tool {
    var kept = try std.ArrayList(ai.ir.Tool).initCapacity(own, decls.len);
    for (decls) |decl| if (!decl.defer_loading) kept.appendAssumeCapacity(decl);
    return kept.items;
}

/// Copy the declarations with every defer flag cleared. A catalog with no deferred tool copies nothing.
fn eagerDecls(own: std.mem.Allocator, decls: []const ai.ir.Tool) ![]const ai.ir.Tool {
    const any_deferred = for (decls) |decl| {
        if (decl.defer_loading) break true;
    } else false;
    if (!any_deferred) return decls;
    const eager = try own.dupe(ai.ir.Tool, decls);
    for (eager) |*decl| decl.defer_loading = false;
    return eager;
}

test "deferral needs the search tool and a catalog at the threshold, and the route picks the mode" {
    const big = "x" ** 4000;
    const decls = [_]ai.ir.Tool{
        .{ .name = "read", .description = "Read.", .input_schema = "{}" },
        .{ .name = "mcp_a", .description = big, .input_schema = "{}", .defer_loading = true },
        .{ .name = "mcp_b", .description = big, .input_schema = "{}", .defer_loading = true },
        .{ .name = search_tool_name, .description = "Find.", .input_schema = "{}" },
    };
    var spec: registry.ModelSpec = .{ .id = "m", .upstream_id = "m", .name = "M", .protocol = .anthropic_messages, .caps = .{ .tool_search = true }, .limits = .{ .context_window = 20_000 } };
    try std.testing.expect(try deferralApplies(&spec, &decls));
    spec.limits.context_window = 200_000; // The two schemas are under ten percent of this window.
    try std.testing.expect(!try deferralApplies(&spec, &decls));
    spec.limits.context_window = 20_000;
    // Without the search tool nothing could load a deferred definition, so every tool stays eager.
    try std.testing.expect(!try deferralApplies(&spec, decls[0..3]));
    try std.testing.expect(!try deferralApplies(&spec, decls[0..1]));

    var held: Loadout = .{ .arena = .init(std.testing.allocator), .names = &.{}, .decls = &decls, .has_skills = false };
    defer held.arena.deinit();
    try decideDeferral(&held, &spec);
    try std.testing.expectEqual(Loadout.Deferral.native, held.deferral);
    try std.testing.expectEqual(@as([*]const ai.ir.Tool, &decls), held.request_tools.?.ptr);

    // A route without native search omits the deferred tools; a search adds one later.
    spec.protocol = .openai_chat;
    held.request_tools = null;
    try decideDeferral(&held, &spec);
    try std.testing.expectEqual(Loadout.Deferral.omitted, held.deferral);
    try std.testing.expectEqual(@as(usize, 2), held.request_tools.?.len);
    try std.testing.expectEqualStrings(search_tool_name, held.request_tools.?[1].name);

    // Under the threshold every declaration is eager, with one copy that clears the flags.
    spec.limits.context_window = 200_000;
    held.request_tools = null;
    held.deferral = .none;
    try decideDeferral(&held, &spec);
    try std.testing.expectEqual(Loadout.Deferral.none, held.deferral);
    try std.testing.expectEqual(@as(usize, 4), held.request_tools.?.len);
    for (held.request_tools.?) |decl| try std.testing.expect(!decl.defer_loading);
    // A catalog with no deferred tool is returned as it is, with no copy.
    try std.testing.expectEqual(decls[0..1].ptr, (try eagerDecls(held.arena.allocator(), decls[0..1])).ptr);
}

/// Build the session request configuration once before any context decision.
pub fn buildConfig(arena: std.mem.Allocator, engine: *Engine, slot: *RunSlot, model: *const registry.ModelSpec) !RequestBuild {
    const held = try loadout(engine, arena, slot);
    // The model is known here and not at the loadout, so the deferral policy applies at the first build and holds for the run.
    if (held.request_tools == null) try decideDeferral(held, model);
    var build: RequestBuild = .{
        .model = model.upstream_id,
        .system = slot.config.system_prompt,
        .tools = held.request_tools.?,
        .max_output_tokens = outputLimit(model),
    };
    if (engine.deps.hooks.holds(engine.deps.hooks.ctx, .@"request.build")) {
        const hook_payload = .{
            .model = build.model,
            .system = build.system,
            .tools = build.tools,
            .max_output_tokens = build.max_output_tokens,
            .context = hookContext(engine, slot, held.has_skills),
        };
        switch (engine.deps.hooks.askIfHeld(arena, .@"request.build", hook_payload)) {
            .proceed => {},
            .replace => |value| build = std.json.parseFromValueLeaky(RequestBuild, arena, value, .{ .ignore_unknown_fields = true }) catch return error.HookAnswerInvalid,
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
