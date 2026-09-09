//! One model call outside a turn. It answers its caller and touches no transcript and no broadcast.

const std = @import("std");
const proto = @import("proto");
const ai = @import("ai");
const Engine = @import("Engine.zig");
const registry = @import("../provider/registry.zig");
const Cancel = @import("../cancel.zig").Cancel;
const context = @import("context.zig");

/// What one call asks for. The prompt is one user text block, so each task builds its own text.
pub const Request = struct {
    system: []const u8 = "",
    prompt: []const u8,
    max_output_tokens: u32,
};

/// What one call returned. The text lives in the arena the caller passed.
pub const Response = struct {
    text: []const u8,
};

/// Run one call against a resolved match. A retry belongs to the caller, which owns the policy.
pub fn generateWith(engine: *Engine, arena: std.mem.Allocator, cancel: *Cancel, match: registry.Match, request: Request) !Response {
    std.debug.assert(request.prompt.len > 0);
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
    const secret = registry.credential(route.credential, engine.deps.env, engine.nowMillis()) orelse return error.MissingCredential;
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

    var response: ?Response = null;
    switch (cancel.runChild(engine.deps.io, callChild, .{ engine, arena, cancel, model, request, limit, &response })) {
        .canceled, .aborted => return error.Canceled,
        .returned => |result| try result,
    }
    std.debug.assert(response != null);
    return response.?;
}

/// Open the response and collect its text, in a child so a cancel can interrupt a blocked read.
fn callChild(
    engine: *Engine,
    arena: std.mem.Allocator,
    cancel: *Cancel,
    model: ai.Model,
    request: Request,
    limit: u32,
    out: *?Response,
) !void {
    defer cancel.finish(engine.deps.io);
    try cancel.check(engine.deps.io);
    const blocks = [_]ai.ir.Block{.{ .role = .user, .value = .{ .text = request.prompt } }};
    var result = try ai.generateWithTransport(engine.deps.gpa, engine.deps.route_transport, model, .{
        .blocks = &blocks,
        .system = request.system,
        .options = .{ .max_output_tokens = limit },
    });
    defer result.deinit();
    out.* = .{ .text = try arena.dupe(u8, result.text) };
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

const test_request: Request = .{ .prompt = "summarize the work", .max_output_tokens = 512 };

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
        var handle = try self.resources.runtime.spawn(generateWith, .{ &self.engine, self.arena.allocator(), cancel, match, test_request });
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
