//! One text-only model call with no transcript or broadcast side effects.

const std = @import("std");
const proto = @import("proto");
const ai = @import("ai");
const Engine = @import("Engine.zig");
const registry = @import("../provider/registry.zig");
const Cancel = @import("../cancel.zig").Cancel;
const context = @import("context.zig");

/// What one call asks for. The caller builds the blocks, so a call can repeat the prefix of a turn.
pub const Request = struct {
    system: []const u8 = "",
    blocks: []const ai.ir.Block,
    /// The tools the turn declares. A call repeats the same tools to keep the turn prefix.
    tools: []const ai.ir.Tool = &.{},
    /// A call answers in text, so the request refuses every tool.
    tool_choice: ai.ir.ToolChoice = .none,
    max_output_tokens: u32,
    /// The session reasoning level. An empty level leaves the provider default.
    reasoning: []const u8 = "",
};

/// What one call returned. The text lives in the arena the caller passed.
pub const Response = struct {
    text: []const u8,
    finish_reason: ai.types.FinishReason,
};

/// Run one call within the caller's cancelable task.
pub fn generateWith(engine: *Engine, arena: std.mem.Allocator, cancel: *Cancel, match: registry.Match, request: Request) !Response {
    std.debug.assert(request.blocks.len > 0);
    std.debug.assert(request.max_output_tokens > 0);
    try cancel.check(engine.deps.io); // A cancel that already landed reports no other refusal.

    // A provider the merge could not complete has no route, so it cannot serve a call.
    const live_route = switch (match.provider.availability) {
        .ready => |ready| ready,
        .unavailable => return error.UnknownModel,
    };
    // The registry can rebuild while this call runs, so the call holds its own copies.
    var route = try proto.dupe(arena, live_route);
    const spec = try proto.dupe(arena, match.model.*);
    // One call repeats no prefix, so it writes no cache breakpoint that it can never read back.
    route.route.cache = null;

    // Read the credential here, so a rotated key or a lapsed grant takes effect on this call.
    const secret = registry.credential(route.credential, engine.deps.execution.env, engine.nowMillis()) orelse return error.MissingCredential;
    const ceiling = if (spec.limits.max_output_tokens) |limit|
        std.math.cast(u32, limit) orelse context.default_max_output
    else
        context.default_max_output;
    const limit = @min(request.max_output_tokens, ceiling);
    if (limit == 0) return error.ContextTooLarge;

    const model: ai.Model = .{
        .id = spec.upstream_id,
        .route = route.route,
        .credential = secret,
        .caps = spec.caps,
        .dialect = spec.dialect,
    };

    const control = try @import("request.zig").reasoningFor(&spec, request.reasoning, limit);
    // A budget shares the output ceiling, and this call sets a small ceiling for its answer alone.
    const reasoning: ai.ir.ReasoningControl = if (control == .budget) .default else control;

    // The caller owns the cancelable task that covers the transport and its blocked reads.
    var result = try ai.generateWithTransport(engine.deps.gpa, engine.deps.route_transport, model, .{
        .blocks = request.blocks,
        .system = request.system,
        .tools = request.tools,
        .options = .{
            .max_output_tokens = limit,
            // A call answers on the session model, so it must reason at the session level too.
            .reasoning = reasoning,
            .tool_choice = request.tool_choice,
        },
    });
    defer result.deinit();
    try cancel.check(engine.deps.io);
    for (result.content) |part| if (part == .tool_call) return error.IncompleteSummary;
    return .{ .text = try arena.dupe(u8, result.text), .finish_reason = result.finish_reason };
}

const testing = std.testing;
const database = @import("../store/store.zig");
const Resources = @import("test_resources.zig");

/// One ready provider with an Anthropic route, so the canned reply parses.
fn mockMatch(arena: std.mem.Allocator, credential: registry.CredentialSource) !registry.Match {
    const spec = try arena.create(registry.ModelSpec);
    spec.* = .{ .id = "mock", .upstream_id = "mock-1", .name = "Mock", .caps = .{ .tools = true } };
    const row = try arena.create(registry.Provider);
    row.* = .{ .id = "mock", .name = "Mock", .models = &.{}, .availability = .{ .ready = .{
        .route = .{ .base_url = "https://example.test/v1", .protocol = .anthropic_messages, .auth = .{ .api_key = .x_api_key } },
        .credential = credential,
    } } };
    return .{ .provider = row, .model = spec };
}

const test_blocks = [_]ai.ir.Block{.{ .role = .user, .value = .{ .text = "summarize the work" } }};
const test_request: Request = .{ .blocks = &test_blocks, .max_output_tokens = 512 };

const Fixture = struct {
    resources: Resources,
    db: database.Database,
    engine: Engine,
    arena: std.heap.ArenaAllocator,

    fn init(self: *Fixture) !void {
        try self.resources.init();
        self.db = try database.Database.openTest();
        self.engine = self.resources.makeEngine(&self.db);
        self.arena = .init(testing.allocator);
    }

    fn deinit(self: *Fixture) void {
        self.arena.deinit();
        self.engine.close();
        self.db.deinit();
        self.resources.deinit();
    }

    /// A call waits for its own child, so it runs inside a task.
    fn call(self: *Fixture, cancel: *Cancel, match: registry.Match) !Response {
        return self.callWith(cancel, match, test_request);
    }

    fn callWith(self: *Fixture, cancel: *Cancel, match: registry.Match, request: Request) !Response {
        var handle = try self.resources.runtime.spawn(generateWith, .{ &self.engine, self.arena.allocator(), cancel, match, request });
        return handle.join();
    }
};

test "a call answers the model text" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var cancel: Cancel = .{};
    const answer = try f.call(&cancel, try mockMatch(f.arena.allocator(), .{ .literal = "secret" }));
    try testing.expectEqualStrings("Hello from the yuke mock provider.", answer.text);
}

test "a cancel that landed before the call stops it before any request" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var cancel: Cancel = .{};
    cancel.request(f.resources.runtime.io());
    try testing.expectError(error.Canceled, f.call(&cancel, try mockMatch(f.arena.allocator(), .{ .literal = "secret" })));
}

test "a call without a credential sends no request" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var cancel: Cancel = .{};
    // The test environment is empty, so this name resolves to no value.
    try testing.expectError(error.MissingCredential, f.call(&cancel, try mockMatch(f.arena.allocator(), .{ .env = "YUKE_ABSENT_KEY" })));
}

test "a call reasons at the session level, and a level the model lacks never reaches the wire" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var cancel: Cancel = .{};
    const a = f.arena.allocator();
    var match = try mockMatch(a, .{ .literal = "secret" });
    const spec = try a.create(registry.ModelSpec);
    spec.* = match.model.*;
    // A model that declares its levels answers no other level.
    spec.reasoning_levels = &.{.{ .named = "low" }};
    match.model = spec;

    try testing.expectError(error.UnsupportedReasoning, f.callWith(&cancel, match, .{
        .blocks = &test_blocks,
        .max_output_tokens = 512,
        .reasoning = "xhigh",
    }));

    const answer = try f.callWith(&cancel, match, .{
        .blocks = &test_blocks,
        .max_output_tokens = 512,
        .reasoning = "low",
    });
    try testing.expectEqualStrings("Hello from the yuke mock provider.", answer.text);
}

test "a provider the merge could not complete serves no call" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    var match = try mockMatch(a, .{ .literal = "secret" });
    const row = try a.create(registry.Provider);
    row.* = .{ .id = "mock", .name = "Mock", .models = &.{}, .availability = .{ .unavailable = .needs_credential } };
    match.provider = row;
    var cancel: Cancel = .{};
    try testing.expectError(error.UnknownModel, f.call(&cancel, match));
}
