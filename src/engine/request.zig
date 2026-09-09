//! Build a provider request from a round snapshot and apply its request hooks.

const std = @import("std");
const proto = @import("proto");
const ai = @import("ai");
const Engine = @import("Engine.zig");
const RunSlot = @import("run.zig").RunSlot;
const provider = @import("../provider/provider.zig");
const registry = @import("../provider/registry.zig");
const database = @import("../store/store.zig");
const context = @import("context.zig");

const max_output_tokens = context.default_max_output;

fn reasoningFor(
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

/// Build the real provider request. It sets the run protocol, the endpoint URL, and the auth headers.
pub fn prepare(
    arena: std.mem.Allocator,
    engine: *Engine,
    slot: *RunSlot,
    r: registry.Match,
) !ai.PreparedRequest {
    // A provider the merge could not complete has no route, so it cannot serve a turn.
    const live_route = switch (r.provider.availability) {
        .ready => |ready| ready,
        .unavailable => return error.UnknownModel,
    };
    // The registry and the tool table can rebuild while a build hook waits, so this round holds its own copies.
    const route = try proto.dupe(arena, live_route);
    const model = try proto.dupe(arena, r.model.*);
    slot.protocol = provider.protocolToProto(route.route.protocol);

    const build = try buildConfig(arena, engine, slot, &model);

    const budget = try context.Budget.forRequest(model.limits.context_window, build.max_output_tokens, build.system, build.tools);
    try @import("compaction.zig").beforeRequest(engine, arena, slot, budget);
    const projected = try context.project(arena, engine.deps.db, slot.sessionId().raw, budget);
    const request_ir = try provider.request_builder.build(arena, projected.messages, .{
        .target = .{ .protocol = route.route.protocol, .model = slot.config.model },
        .modalities = model.modalities,
    });

    // Read the credential here, so a rotated key or a lapsed grant takes effect on the next round.
    const secret = registry.credential(route.credential, engine.deps.env, engine.nowMillis()) orelse return error.MissingCredential;
    // The serializer copies this into the request body, so it only has to outlive `prepare`.
    const cache_key = std.fmt.bytesToHex(slot.sessionId().raw, .lower);
    var prepared = try ai.prepare(engine.deps.gpa, .{
        .id = build.model,
        .route = route.route,
        .credential = secret,
        .caps = model.caps,
        .dialect = model.dialect,
    }, .{
        .blocks = request_ir.blocks,
        .system = build.system,
        .tools = build.tools,
        .options = .{
            .max_output_tokens = build.max_output_tokens,
            // The budget shares the ceiling, so it follows whatever the chain left there.
            .reasoning = try reasoningFor(&model, slot.config.reasoning, build.max_output_tokens),
            // Every round of one session repeats a prefix, so the session id keeps them on one cache.
            .cache_key = &cache_key,
        },
    });
    errdefer prepared.deinit();

    // The round arena outlives the prepared request, so a replaced field may live in it.
    switch (engine.deps.hooks.askIfHeld(arena, .@"request.send", RequestSend{
        .url = prepared.transport_request.url,
        .headers = prepared.transport_request.headers,
        .body = prepared.transport_request.body,
    })) {
        .proceed => {},
        .replace => |value| if (std.json.parseFromValueLeaky(RequestSend, arena, value, .{ .ignore_unknown_fields = true })) |sent| {
            prepared.transport_request = .{
                .url = sent.url,
                .headers = sent.headers,
                // An HTTP writer shifts the body it sends, so it needs bytes it may write to.
                .body = try arena.dupe(u8, sent.body),
            };
        } else |_| {},
        .block => |reason| {
            std.log.warn("run {d} stopped at request.send: {s}", .{ slot.runId(), reason });
            return error.HookBlocked;
        },
        .canceled => return error.Canceled,
    }
    return prepared;
}

/// Build the session request configuration once before any context decision.
fn buildConfig(arena: std.mem.Allocator, engine: *Engine, slot: *RunSlot, model: *const registry.ModelSpec) !RequestBuild {
    const output_limit = if (model.limits.max_output_tokens) |limit|
        std.math.cast(u32, limit) orelse max_output_tokens
    else
        max_output_tokens;

    var build: RequestBuild = .{
        .model = model.upstream_id,
        .system = slot.config.system_prompt,
        .tools = try engine.deps.tools.getDecls(engine.deps.tools.ctx, arena, try selectionFor(engine, arena, slot)),
        .max_output_tokens = output_limit,
    };
    if (engine.deps.hooks.holds(engine.deps.hooks.ctx, .@"request.build")) {
        const snapshot = (try database.session.snapshot(engine.deps.db, arena, slot.sessionId().raw)) orelse return error.UnknownSession;
        const hook_payload = .{
            .model = build.model,
            .system = build.system,
            .tools = build.tools,
            .max_output_tokens = build.max_output_tokens,
            .context = .{
                .session_id = slot.sessionId(),
                .parent_id = slot.parent_id,
                .workspace = snapshot.root,
                .agent_name = snapshot.name orelse "root",
                .prompt = try database.session.promptParts(engine.deps.db, arena, slot.sessionId().raw),
            },
        };
        switch (engine.deps.hooks.askIfHeld(arena, .@"request.build", hook_payload)) {
            .proceed => {},
            // A handler that answers an unreadable request keeps the one this round already holds.
            .replace => |value| build = std.json.parseFromValueLeaky(RequestBuild, arena, value, .{ .ignore_unknown_fields = true }) catch build,
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

/// Manual compaction uses the same prompt, tools, output, and build hook as a turn.
pub fn budgetFor(arena: std.mem.Allocator, engine: *Engine, slot: *RunSlot) !context.Budget {
    const resolved = engine.deps.providers.merged.resolveModel(slot.config.model) orelse return error.UnknownModel;
    const model = try proto.dupe(arena, resolved.model.*);
    const build = try buildConfig(arena, engine, slot, &model);
    return context.Budget.forRequest(model.limits.context_window, build.max_output_tokens, build.system, build.tools);
}

/// The serialized request one round sends. A `request.send` handler may replace any field.
const RequestSend = struct {
    url: []const u8,
    headers: []const ai.instance.Header,
    body: []const u8,
};

/// The build hook omits transcript blocks to avoid copies of attachment data.
const RequestBuild = struct {
    model: []const u8,
    system: []const u8,
    tools: []const ai.ir.Tool,
    max_output_tokens: u32,
};

test "an unset level omits the control and off disables it" {
    const model: registry.ModelSpec = .{ .id = "m", .upstream_id = "m", .name = "m" };
    try std.testing.expectEqual(ai.ir.ReasoningControl.default, try reasoningFor(&model, "", 8192));
    try std.testing.expectEqual(ai.ir.ReasoningControl.off, try reasoningFor(&model, "off", 8192));
}

test "an adaptive row resolves to adaptive for every level that is not off" {
    const model: registry.ModelSpec = .{ .id = "m", .upstream_id = "m", .name = "m", .reasoning_levels = &.{.{ .named = "high" }}, .dialect = .{ .anthropic_adaptive = true } };
    try std.testing.expectEqual(ai.ir.ReasoningControl.adaptive, try reasoningFor(&model, "high", 8192));
    try std.testing.expectEqual(ai.ir.ReasoningControl.off, try reasoningFor(&model, "off", 8192));
}

test "a budget row states one budget, whatever effort the caller names" {
    const model: registry.ModelSpec = .{
        .id = "m",
        .upstream_id = "m",
        .name = "m",
        .reasoning_levels = &.{ .{ .named = "max" }, .{ .named = "high" } },
        .dialect = .{ .reasoning_budget = .from(1024, 32000) },
    };
    // Anthropic publishes absolute starting points, so the level never scales the budget.
    try std.testing.expectEqual(@as(u64, 16000), (try reasoningFor(&model, "max", 64000)).budget);
    try std.testing.expectEqual(@as(u64, 16000), (try reasoningFor(&model, "high", 64000)).budget);
}

test "a budget is clamped by the feed bounds and refused when it reaches the ceiling" {
    const capped: registry.ModelSpec = .{ .id = "m", .upstream_id = "m", .name = "m", .reasoning_levels = &.{.{ .named = "high" }}, .dialect = .{ .reasoning_budget = .from(null, 2000) } };
    try std.testing.expectEqual(@as(u64, 2000), (try reasoningFor(&capped, "high", 8192)).budget);

    // A budget that reaches the ceiling falls back to the effort control.
    const tiny: registry.ModelSpec = .{ .id = "m", .upstream_id = "m", .name = "m", .reasoning_levels = &.{.{ .named = "high" }}, .dialect = .{ .reasoning_budget = .from(1024, null) } };
    try std.testing.expectEqual(ai.ir.Effort.high, (try reasoningFor(&tiny, "high", 1024)).effort);

    // The published maximum still wins, so a model that caps itself below the default is honoured.
    try std.testing.expectEqual(@as(u64, 2000), (try reasoningFor(&capped, "high", 64000)).budget);
}

test "a selected level outside the model list is unsupported" {
    const model: registry.ModelSpec = .{ .id = "m", .upstream_id = "m", .name = "m", .reasoning_levels = &.{.{ .named = "high" }} };
    try std.testing.expectError(error.UnsupportedReasoning, reasoningFor(&model, "turbo", 8192));
    try std.testing.expectEqual(ai.ir.Effort.high, (try reasoningFor(&model, "high", 8192)).effort);

    const unlisted: registry.ModelSpec = .{ .id = "m", .upstream_id = "m", .name = "m" };
    try std.testing.expectError(error.UnsupportedReasoning, reasoningFor(&unlisted, "turbo", 8192));
}
