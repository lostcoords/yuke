//! Shared request configuration for turns and compaction.

const std = @import("std");
const proto = @import("proto");
const ai = @import("ai");
const Engine = @import("Engine.zig");
const Loadout = @import("../session/session.zig").Loadout;
const RunSlot = @import("run.zig").RunSlot;
const toolset = @import("toolset.zig");
const registry = @import("../provider/registry.zig");
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
) error{UnsupportedReasoning}!ai.ir.ReasoningSettings {
    // The sources accept an Anthropic thinking shape only on Anthropic Messages.
    std.debug.assert(model.dialect.anthropic_thinking == .none or model.protocol == .anthropic_messages);
    if (level.len == 0) return .{};
    if (std.mem.eql(u8, level, "off")) {
        // A model that states it cannot stop would reject the control, so refuse before the request.
        if (model.caps.disable_reasoning) |can| if (!can) return error.UnsupportedReasoning;
        return .{ .thinking = .off };
    }
    if (model.reasoning_levels.len != 0 and !hasReasoningLevel(model.reasoning_levels, level))
        return error.UnsupportedReasoning;
    switch (model.dialect.anthropic_thinking) {
        .none => {},
        .toggle => return .{ .thinking = .{ .adaptive = null } },
        .adaptive => return .{ .thinking = .{ .adaptive = .summarized }, .effort = try effortOf(level) },
        .budget => |bounds| {
            // Anthropic states absolute starting points, never a share of the ceiling.
            var budget: u64 = thinking_budget_default;
            if (bounds.max) |maximum| budget = @min(budget, maximum);
            if (bounds.min) |minimum| if (minimum > 0) {
                budget = @max(budget, @as(u64, @intCast(minimum)));
            };
            budget = @max(budget, thinking_budget_min);
            // The budget must leave room for the answer, so one that cannot fit falls back to the effort.
            if (budget < output_limit) return .{ .thinking = .{ .budget = budget } };
        },
    }
    return .{ .effort = try effortOf(level) };
}

fn effortOf(level: []const u8) error{UnsupportedReasoning}!ai.ir.Effort {
    return std.meta.stringToEnum(ai.ir.Effort, level) orelse error.UnsupportedReasoning;
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

/// The session facts every hook payload carries.
pub const HookContext = struct {
    session_id: proto.ids.SessionId,
    parent_id: ?proto.ids.SessionId,
    depth: u32,
    /// The engine owns this limit, so a plugin reads it here and keeps no default of its own.
    max_agent_depth: u32,
    agent_name: []const u8,
    workspace: []const u8,
};

pub fn hookContext(engine: *const Engine, slot: *const RunSlot) HookContext {
    std.debug.assert(engine.max_agent_depth > 0);
    return .{ .session_id = slot.sessionId(), .parent_id = slot.parent_id, .depth = slot.depth, .max_agent_depth = engine.max_agent_depth, .agent_name = slot.config.name orelse "root", .workspace = slot.config.root };
}

/// The tools this run may see, chosen once at its first request. `tools.select` may narrow the list; the answer holds for the run.
pub fn loadout(engine: *Engine, arena: std.mem.Allocator, slot: *RunSlot) !*Loadout {
    if (slot.tools) |*held| return held;
    const tools = engine.deps.tools;
    var table = try tools.decls(tools.ctx, arena);
    var served = try resolveVariants(engine, arena, slot, table);
    const Chosen = struct { tools: []const []const u8 };
    // A run without a tools.select handler keeps the whole table, so it builds no name list.
    var chosen: ?Chosen = null;
    if (engine.deps.hooks.holds(engine.deps.hooks.ctx, .@"tools.select")) {
        // A handler may register a tool while it runs. A changed table gets one more ask, so the choice covers the late tool.
        // An unchanged table keeps its variant choice, so each `when` answers once for each table.
        for (0..2) |_| {
            const names = try arena.alloc([]const u8, served.len);
            for (served, names) |entry, *name| name.* = entry.decl.name;
            chosen = try engine.deps.hooks.decide(Chosen, arena, slot.runId(), .@"tools.select", .{ .tools = names, .context = hookContext(engine, slot) });
            const fresh = try tools.decls(tools.ctx, arena);
            const changed = fresh.len != table.len or for (table, fresh) |old, new| {
                if (old.id != new.id) break true;
            } else false;
            if (!changed) break;
            table = fresh;
            served = try resolveVariants(engine, arena, slot, table);
        }
    }
    var held: Loadout = .{ .arena = .init(engine.deps.gpa), .decls = &.{}, .ids = &.{} };
    errdefer held.arena.deinit();
    const own = held.arena.allocator();
    var kept: std.ArrayList(ai.ir.Tool) = try .initCapacity(own, served.len);
    var ids: std.ArrayList(u32) = try .initCapacity(own, served.len);
    for (served) |entry| {
        if (chosen) |answer| if (!named(answer.tools, entry.decl.name)) continue;
        kept.appendAssumeCapacity(try proto.dupe(own, entry.decl));
        ids.appendAssumeCapacity(entry.id);
    }
    held.decls = kept.items;
    held.ids = ids.items;
    slot.tools = held;
    return &slot.tools.?;
}

/// Keep one entry per name: the newest variant that the session takes, else the global entry, else none.
/// A table without variants asks nothing.
fn resolveVariants(engine: *Engine, arena: std.mem.Allocator, slot: *RunSlot, served: []const toolset.Served) ![]const toolset.Served {
    var variants: std.ArrayList(toolset.Id) = .empty;
    for (served) |entry| if (entry.conditional) try variants.append(arena, entry.id);
    if (variants.items.len == 0) return served;
    const payload = try std.json.Stringify.valueAlloc(arena, .{ .context = hookContext(engine, slot), .ids = variants.items }, .{});
    const accepted = try engine.deps.tools.accept(engine.deps.tools.ctx, arena, payload);
    var kept: std.ArrayList(toolset.Served) = try .initCapacity(arena, served.len);
    // The answer keeps the asked order, and the asked ids follow the table, so one cursor walks it.
    var next: usize = 0;
    var first: usize = 0;
    while (first < served.len) {
        var end = first + 1;
        while (end < served.len and std.mem.eql(u8, served[end].decl.name, served[first].decl.name)) end += 1;
        // A name group keeps registration order, so a later accepted variant replaces an earlier pick.
        var pick: ?toolset.Served = null;
        for (served[first..end]) |entry| {
            if (!entry.conditional) {
                if (pick == null) pick = entry;
            } else if (next < accepted.len and accepted[next] == entry.id) {
                next += 1;
                pick = entry;
            }
        }
        if (pick) |entry| kept.appendAssumeCapacity(entry);
        first = end;
    }
    return kept.items;
}

fn named(names: []const []const u8, name: []const u8) bool {
    for (names) |item| if (std.mem.eql(u8, item, name)) return true;
    return false;
}

const search_tool_name = ai.ir.search_tool_name;

/// A route with native client search loads a found definition in place; every other route omits it until a search adds it.
fn decideDeferral(held: *Loadout, spec: *const registry.ModelSpec) !void {
    const own = held.arena.allocator();
    if (!deferralApplies(held.decls)) {
        held.request_tools = try eagerDecls(own, held.decls);
    } else if (spec.caps.tool_search == true and spec.protocol != .openai_chat) {
        held.deferral = .native;
        held.request_tools = held.decls;
    } else {
        held.deferral = .omitted;
        held.request_tools = try omitDeferred(own, held.decls);
    }
}

/// Deferral needs a deferred tool and the eager search tool that loads it.
fn deferralApplies(decls: []const ai.ir.Tool) bool {
    var deferred = false;
    var searchable = false;
    for (decls) |decl| {
        deferred = deferred or decl.defer_loading;
        searchable = searchable or (!decl.defer_loading and std.mem.eql(u8, decl.name, search_tool_name));
    }
    return deferred and searchable;
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

test "deferral needs a deferred tool and the search tool, and the route picks the mode" {
    const decls = [_]ai.ir.Tool{
        .{ .name = "read", .description = "Read.", .input_schema = "{}" },
        .{ .name = "mcp_a", .description = "A.", .input_schema = "{}", .defer_loading = true },
        .{ .name = "mcp_b", .description = "B.", .input_schema = "{}", .defer_loading = true },
        .{ .name = search_tool_name, .description = "Find.", .input_schema = "{}" },
    };
    try std.testing.expect(deferralApplies(&decls));
    // Without the search tool nothing could load a deferred definition, so every tool stays eager.
    try std.testing.expect(!deferralApplies(decls[0..3]));
    try std.testing.expect(!deferralApplies(decls[0..1]));

    var spec: registry.ModelSpec = .{ .id = "m", .upstream_id = "m", .name = "M", .protocol = .anthropic_messages, .caps = .{ .tool_search = true } };
    const ids = [_]u32{ 0, 1, 2, 3 };
    var held: Loadout = .{ .arena = .init(std.testing.allocator), .decls = &decls, .ids = &ids };
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

    // Without the search tool every declaration is eager, with one copy that clears the flags.
    held.decls = decls[0..3];
    held.ids = ids[0..3];
    held.request_tools = null;
    held.deferral = .none;
    try decideDeferral(&held, &spec);
    try std.testing.expectEqual(Loadout.Deferral.none, held.deferral);
    try std.testing.expectEqual(@as(usize, 3), held.request_tools.?.len);
    for (held.request_tools.?) |decl| try std.testing.expect(!decl.defer_loading);
    // A catalog with no deferred tool is returned as it is, with no copy.
    try std.testing.expectEqual(decls[0..1].ptr, (try eagerDecls(held.arena.allocator(), decls[0..1])).ptr);
}

/// Build the session request configuration once before any context decision.
pub fn buildConfig(engine: *Engine, arena: std.mem.Allocator, slot: *RunSlot, model: *const registry.ModelSpec) !RequestBuild {
    const held = try loadout(engine, arena, slot);
    // The model is known here and not at the loadout, so the deferral policy applies at the first build and holds for the run.
    if (held.request_tools == null) try decideDeferral(held, model);
    var build: RequestBuild = .{
        .model = model.upstream_id,
        .system = slot.config.system_prompt,
        .tools = held.request_tools.?,
        .max_output_tokens = outputLimit(model),
    };
    if (try engine.deps.hooks.decide(RequestBuild, arena, slot.runId(), .@"request.build", .{
        .model = build.model,
        .system = build.system,
        .tools = build.tools,
        .max_output_tokens = build.max_output_tokens,
        .context = hookContext(engine, slot),
    })) |answer| build = answer;

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

test "unset and off reasoning controls take precedence over a thinking shape" {
    const model: registry.ModelSpec = .{ .id = "m", .upstream_id = "m", .name = "m", .protocol = .anthropic_messages, .reasoning_levels = &.{.{ .named = "high" }}, .dialect = .{ .anthropic_thinking = .adaptive } };
    try std.testing.expectEqual(ai.ir.ReasoningSettings{}, try reasoningFor(&model, "", 8192));
    try std.testing.expectEqual(ai.ir.ReasoningSettings{ .thinking = .off }, try reasoningFor(&model, "off", 8192));
}

test "adaptive thinking carries the level as an effort; a toggle host takes no effort" {
    const adaptive: registry.ModelSpec = .{ .id = "m", .upstream_id = "m", .name = "m", .protocol = .anthropic_messages, .reasoning_levels = &.{ .{ .named = "low" }, .{ .named = "high" } }, .dialect = .{ .anthropic_thinking = .adaptive } };
    try std.testing.expectEqual(ai.ir.ReasoningSettings{ .thinking = .{ .adaptive = .summarized }, .effort = .low }, try reasoningFor(&adaptive, "low", 8192));

    const toggle: registry.ModelSpec = .{ .id = "m", .upstream_id = "m", .name = "m", .protocol = .anthropic_messages, .reasoning_levels = &.{.{ .named = "high" }}, .dialect = .{ .anthropic_thinking = .toggle } };
    try std.testing.expectEqual(ai.ir.ReasoningSettings{ .thinking = .{ .adaptive = null } }, try reasoningFor(&toggle, "high", 8192));
}

test "a budget row states one budget, whatever effort the caller names" {
    const model: registry.ModelSpec = .{
        .id = "m",
        .upstream_id = "m",
        .name = "m",
        .protocol = .anthropic_messages,
        .reasoning_levels = &.{ .{ .named = "max" }, .{ .named = "high" } },
        .dialect = .{ .anthropic_thinking = .{ .budget = .{ .min = 1024, .max = 32000 } } },
    };
    // Anthropic publishes absolute starting points, so the level never scales the budget.
    try std.testing.expectEqual(@as(u64, 16000), (try reasoningFor(&model, "max", 64000)).thinking.budget);
    try std.testing.expectEqual(@as(u64, 16000), (try reasoningFor(&model, "high", 64000)).thinking.budget);
}

test "a budget is clamped by the feed bounds and refused when it reaches the ceiling" {
    const capped: registry.ModelSpec = .{ .id = "m", .upstream_id = "m", .name = "m", .protocol = .anthropic_messages, .reasoning_levels = &.{.{ .named = "high" }}, .dialect = .{ .anthropic_thinking = .{ .budget = .{ .max = 2000 } } } };
    try std.testing.expectEqual(@as(u64, 2000), (try reasoningFor(&capped, "high", 8192)).thinking.budget);

    // A budget that reaches the ceiling falls back to the effort control.
    const tiny: registry.ModelSpec = .{ .id = "m", .upstream_id = "m", .name = "m", .protocol = .anthropic_messages, .reasoning_levels = &.{.{ .named = "high" }}, .dialect = .{ .anthropic_thinking = .{ .budget = .{ .min = 1024 } } } };
    try std.testing.expectEqual(ai.ir.Effort.high, (try reasoningFor(&tiny, "high", 1024)).effort.?);
}

test "a selected level outside the model list is unsupported" {
    const model: registry.ModelSpec = .{ .id = "m", .upstream_id = "m", .name = "m", .protocol = .openai_chat, .reasoning_levels = &.{.{ .named = "high" }} };
    try std.testing.expectError(error.UnsupportedReasoning, reasoningFor(&model, "turbo", 8192));
    try std.testing.expectEqual(ai.ir.Effort.high, (try reasoningFor(&model, "high", 8192)).effort.?);

    const unlisted: registry.ModelSpec = .{ .id = "m", .upstream_id = "m", .name = "m", .protocol = .openai_chat };
    try std.testing.expectError(error.UnsupportedReasoning, reasoningFor(&unlisted, "turbo", 8192));
}
