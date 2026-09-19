//! The model gate and session.patch share one profile with explicit local providers.

const std = @import("std");
const proto = @import("proto");
const database = @import("../store/store.zig");
const provider = @import("../provider/provider.zig");
const Engine = @import("Engine.zig");
const testing = std.testing;
const Resources = @import("test_resources.zig");
const commands = @import("commands.zig");
const chosen = "local/family/model";

const Fixture = struct {
    resources: Resources,
    db: database.Database,
    arena: std.heap.ArenaAllocator,
    engine: Engine,

    fn init(self: *Fixture) !void {
        try self.resources.init();
        errdefer self.resources.deinit();
        self.arena = .init(testing.allocator);
        errdefer self.arena.deinit();
        self.db = try database.Database.openTest();
        errdefer self.db.deinit();
        var local = try provider.config.loadBytes(testing.allocator,
            \\{"providers":[{"id":"local","base_url":"http://localhost:1/v1","endpoints":[{"protocol":"openai_chat"}],"models":[{"id":"family/model","upstream_id":"family/model","reasoning_levels":["low","medium","high"],"flags":{"supports_tools":true}},{"id":"high-only","upstream_id":"h","reasoning_levels":["high"],"flags":{"supports_tools":true}},{"id":"flat","upstream_id":"f","flags":{"supports_tools":true}},{"id":"no-tools","upstream_id":"n","flags":{"supports_tools":false}},{"id":"unknown-tools","upstream_id":"u"}]},{"id":"locked","base_url":"http://localhost:1/v1","endpoints":[{"protocol":"openai_chat","key_header":"x_api_key"}],"auth":{"api_key":{"source":{"env":"ABSENT_KEY"}}},"models":[{"id":"model","upstream_id":"m","flags":{"supports_tools":true}}]}]}
        );
        _ = self.resources.providers.installLocal(&local) catch |err| {
            local.deinit();
            return err;
        };
        const unknown = self.resources.providers.merged.resolveModel("local/unknown-tools").?;
        @constCast(unknown.model).caps.tools = null;
        self.engine = self.resources.makeEngine(&self.db);
        errdefer self.engine.close();
    }

    fn deinit(self: *Fixture) void {
        self.engine.close();
        self.db.deinit();
        self.arena.deinit();
        self.resources.deinit();
    }
};

fn seed(f: *Fixture, a: std.mem.Allocator) !proto.ids.SessionId {
    return (try commands.sessionCreate(&f.engine, a, .{ .workspace_path = "/work", .model = chosen })).session.id;
}

test "create refuses a session the catalog cannot serve" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    try testing.expectError(error.NoModel, commands.sessionCreate(&f.engine, a, .{ .workspace_path = "/work" }));
    try testing.expectError(error.ModelUnknown, commands.sessionCreate(&f.engine, a, .{ .workspace_path = "/work", .model = "family/model" }));
    try testing.expectError(error.ModelToolsUnsupported, commands.sessionCreate(&f.engine, a, .{ .workspace_path = "/work", .model = "local/no-tools" }));
    try testing.expectError(error.ReasoningUnsupported, commands.sessionCreate(&f.engine, a, .{ .workspace_path = "/work", .model = chosen, .reasoning = "max" }));
    try testing.expectError(error.ReasoningUnsupported, commands.sessionCreate(&f.engine, a, .{ .workspace_path = "/work", .model = chosen, .reasoning = "" }));
}

test "a patch settles one field at a time and a new model takes its own default level" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    const id = try seed(&f, a);

    const level = try commands.sessionPatch(&f.engine, a, .{ .session_id = id, .patch = .{ .reasoning = "high" } });
    try testing.expectEqual(@as(u64, 1), level.config_rev);
    try testing.expectEqualStrings("high", level.reasoning);
    try testing.expectEqualStrings(chosen, level.model);
    try testing.expectEqual(@as(?u64, null), level.max_rounds);

    const rounds = try commands.sessionPatch(&f.engine, a, .{ .session_id = id, .patch = .{ .max_rounds = 4 } });
    try testing.expectEqual(@as(u64, 2), rounds.config_rev);
    try testing.expectEqual(@as(?u64, 4), rounds.max_rounds);
    try testing.expectEqualStrings("high", rounds.reasoning);

    // The new model does not name `high`, so it takes its own default instead.
    const moved = try commands.sessionPatch(&f.engine, a, .{ .session_id = id, .patch = .{ .model = "local/high-only" } });
    try testing.expectEqualStrings("local/high-only", moved.model);
    try testing.expectEqualStrings("high", moved.reasoning);
    try testing.expectEqual(@as(?u64, 4), moved.max_rounds);
}

test "a patch refuses an empty change an unknown session and a model the catalog cannot serve" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    const id = try seed(&f, a);
    try testing.expectError(error.EmptyPatch, commands.sessionPatch(&f.engine, a, .{ .session_id = id, .patch = .{} }));
    try testing.expectError(error.UnknownSession, commands.sessionPatch(&f.engine, a, .{ .session_id = .bytes([_]u8{9} ** 16), .patch = .{ .reasoning = "high" } }));
    try testing.expectError(error.ModelUnknown, commands.sessionPatch(&f.engine, a, .{ .session_id = id, .patch = .{ .model = "family/model" } }));
    try testing.expectError(error.ModelToolsUnsupported, commands.sessionPatch(&f.engine, a, .{ .session_id = id, .patch = .{ .model = "local/no-tools" } }));
    try testing.expectError(error.ReasoningUnsupported, commands.sessionPatch(&f.engine, a, .{ .session_id = id, .patch = .{ .reasoning = "max" } }));
    // A refusal writes nothing, so the birth revision still stands.
    try testing.expectEqual(@as(u64, 0), (try database.session.snapshot(&f.db, a, id.raw)).?.config_rev);
}

test "a patch keeps every superseded revision readable" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    const id = try seed(&f, a);
    _ = try commands.sessionPatch(&f.engine, a, .{ .session_id = id, .patch = .{ .reasoning = "high", .max_rounds = 3 } });

    const birth = (try database.config.byRevision(&f.db, a, id.raw, 0)).?;
    try testing.expectEqualStrings("medium", birth.reasoning); // Create settled the model's default level.
    try testing.expectEqual(@as(?u64, null), birth.max_rounds);
    const current = (try database.config.byRevision(&f.db, a, id.raw, 1)).?;
    try testing.expectEqualStrings("high", current.reasoning);
    try testing.expectEqual(@as(?u64, 3), current.max_rounds);

    // A null config_rev reads the live row, which must carry the same fields as a stored revision.
    const live = try commands.sessionConfig(&f.engine, a, .{ .session_id = id });
    try testing.expectEqual(@as(u64, 1), live.config.config_rev);
    try testing.expectEqual(@as(?u64, 3), live.config.max_rounds);
    try testing.expectEqualStrings("high", live.config.reasoning);
}

test "a patch lands on the next turn while a run holds its own config" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    const id = try seed(&f, a);
    var launch: ?@import("run.zig").Launch = null;
    defer @import("run.zig").Launch.release(&launch, &f.engine);
    _ = try commands.sessionSendInputForRpc(&f.engine, a, .{ .session_id = id, .input = .{ .content = .{ .content = &.{.{ .text = .{ .text = "go" } }} } } }, &launch, null);

    // The run copied its settings at start, so a patch during the turn is accepted and does not disturb it.
    const patched = try commands.sessionPatch(&f.engine, a, .{ .session_id = id, .patch = .{ .reasoning = "high" } });
    try testing.expectEqualStrings("high", patched.reasoning);
    try testing.expectEqualStrings("medium", f.engine.sessions.get(id).?.active_run.?.config.reasoning);
}

test "an inherited level crosses only to a model that names it" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    const model_config = @import("model_config.zig");

    // The level the parent holds survives when the child model names it.
    const same = try model_config.validate(&f.engine, a, chosen, .{ .inherit = "low" });
    try testing.expectEqualStrings("low", same.reasoning);
    const named = try model_config.validate(&f.engine, a, "local/high-only", .{ .inherit = "high" });
    try testing.expectEqualStrings("high", named.reasoning);

    // A level the child model does not name falls back to that model's default.
    const fallback = try model_config.validate(&f.engine, a, "local/high-only", .{ .inherit = "low" });
    try testing.expectEqualStrings("high", fallback.reasoning);
    const none = try model_config.validate(&f.engine, a, "local/flat", .{ .inherit = "medium" });
    try testing.expectEqualStrings("", none.reasoning);
    const empty = try model_config.validate(&f.engine, a, chosen, .{ .inherit = "" });
    try testing.expectEqualStrings("medium", empty.reasoning);

    // An explicit level is a claim, so the same mismatch refuses instead.
    try testing.expectError(error.ReasoningUnsupported, model_config.validate(&f.engine, a, "local/high-only", .{ .explicit = "low" }));
}
