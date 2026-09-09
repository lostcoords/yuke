//! The model map, the model gate, and session.patch share one profile with explicit local providers.

const std = @import("std");
const proto = @import("proto");
const database = @import("../store/store.zig");
const provider = @import("../provider/provider.zig");
const Engine = @import("Engine.zig");
const config = @import("agent_config.zig");
const testing = std.testing;
const Resources = @import("test_resources.zig");
const commands = @import("commands.zig");
const chosen: proto.agents.AgentModel = .{ .model = "local/family/model" };

const Fixture = struct {
    tmp: testing.TmpDir,
    resources: Resources,
    db: database.Database,
    arena: std.heap.ArenaAllocator,
    engine: Engine,

    fn init(self: *Fixture) !void {
        self.tmp = testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        try self.resources.init();
        errdefer self.resources.deinit();
        self.arena = .init(testing.allocator);
        errdefer self.arena.deinit();
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const root = buf[0..try self.tmp.dir.realPath(testing.io, &buf)];
        try self.resources.env.put("XDG_CONFIG_HOME", root);
        try self.resources.env.put("YUKE_APPNAME", "agents-test");
        self.db = try database.Database.openTest();
        errdefer self.db.deinit();
        var local = try provider.config.loadBytes(testing.allocator,
            \\{"version":1,"providers":[{"id":"local","base_url":"http://localhost:1/v1","protocol":"openai_chat","models":[{"id":"family/model","upstream_id":"family/model","reasoning_levels":["low","medium","high"],"flags":{"supports_tools":true}},{"id":"high-only","upstream_id":"h","reasoning_levels":["high"],"flags":{"supports_tools":true}},{"id":"flat","upstream_id":"f","flags":{"supports_tools":true}},{"id":"no-tools","upstream_id":"n","flags":{"supports_tools":false}},{"id":"unknown-tools","upstream_id":"u"}]},{"id":"locked","base_url":"http://localhost:1/v1","protocol":"openai_chat","auth":{"api_key":{"header":"x_api_key","source":{"env":"ABSENT_KEY"}}},"models":[{"id":"model","upstream_id":"m","flags":{"supports_tools":true}}]}]}
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
        self.tmp.cleanup();
    }

    fn get(self: *Fixture) !proto.agents.AgentsGetResult {
        return config.get(&self.engine, self.arena.allocator());
    }

    fn save(self: *Fixture, revision: proto.ids.AgentConfigRev, models: proto.agents.AgentModels) !proto.agents.AgentsGetResult {
        return config.update(&self.engine, self.arena.allocator(), .{ .revision = revision, .config = .{ .models = models } });
    }
};

test "agent config accepts only explicit closed slots" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{ "{}", "{\"models\":{}}", "{\"models\":{\"small\":null}}", "{\"models\":{\"small\":{\"model\":\"p/a/b\"},\"medium\":{\"model\":\"p/a/b\"}}}" }) |bytes| _ = try config.parse(arena.allocator(), null, bytes);
    for ([_][]const u8{ "", " ", "{", "null", "[]", "{\"large\":{}}", "{\"models\":null}", "{\"models\":{\"large\":{}}}", "{\"models\":{\"small\":{}}}", "{\"models\":{\"small\":{\"model\":null}}}", "{\"models\":{\"small\":{\"model\":\"\"}}}", "{\"models\":{\"small\":{\"model\":\"p/m\",\"reasoning\":\"high\"}}}", "{\"models\":{\"small\":{\"model\":\"p/m\",\"extra\":true}}}", "{\"models\":{},\"models\":{}}" }) |bytes| try testing.expectError(error.BadAgentConfig, config.parse(arena.allocator(), null, bytes));
}

test "missing agent config has no inherited model and a saved map resolves exact selectors" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    const empty = try f.get();
    try testing.expect(std.mem.endsWith(u8, empty.path.?, "/agents-test/agents.json"));
    try testing.expect(empty.config.models.small == null and empty.config.models.medium == null);
    try testing.expectError(error.AgentSetupRequired, config.slotModel(&f.engine, a, .small));
    const saved = try f.save(empty.revision, .{ .small = chosen, .medium = chosen });
    try testing.expect(!std.mem.eql(u8, &empty.revision.raw, &saved.revision.raw));
    for ([_]proto.agents.AgentModelSlot{ .small, .medium }) |slot|
        try testing.expectEqualStrings(chosen.model, try config.slotModel(&f.engine, a, slot));
    try testing.expectEqualStrings(chosen.model, (try f.get()).config.models.small.?.model);
    var fresh = f.resources.makeEngine(&f.db);
    defer fresh.close();
    try testing.expectEqualStrings(chosen.model, try config.slotModel(&fresh, a, .small));
}

test "model validation checks readiness and known tools before save" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const empty = try f.get();
    try testing.expectError(error.ModelUnknown, f.save(empty.revision, .{ .small = .{ .model = "family/model" } }));
    try testing.expectError(error.ModelUnavailable, f.save(empty.revision, .{ .small = .{ .model = "locked/model" } }));
    @constCast(f.resources.providers.merged.resolveModel("locked/model").?.provider).availability = .{ .unavailable = .needs_route };
    try testing.expectError(error.ModelRouteUnavailable, f.save(empty.revision, .{ .small = .{ .model = "locked/model" } }));
    for ([_][]const u8{ "local/no-tools", "local/unknown-tools" }) |model| try testing.expectError(error.ModelToolsUnsupported, f.save(empty.revision, .{ .small = .{ .model = model } }));
    try testing.expectEqual(empty.revision, (try f.get()).revision);
    const saved = try f.save(empty.revision, .{ .small = chosen });
    try testing.expectEqualStrings(chosen.model, saved.config.models.small.?.model);
}

test "stale writers cannot replace another process choice and corrupt files stay intact" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    const initial = try f.get();
    var other = f.resources.makeEngine(&f.db);
    defer other.close();
    _ = try config.get(&other, a);
    const saved = try f.save(initial.revision, .{ .small = chosen });
    try testing.expectError(error.AgentConfigConflict, config.update(&other, a, .{ .revision = initial.revision, .config = .{ .models = .{ .medium = chosen } } }));
    try testing.expectEqual(saved.revision, (try f.get()).revision);
    try provider.config.writeFileBytes(f.resources.runtime.io(), saved.path.?, "{broken");
    try testing.expectError(error.BadAgentConfig, f.get());
    try testing.expectError(error.BadAgentConfig, f.save(saved.revision, .{ .medium = chosen }));
    const bytes = try std.Io.Dir.cwd().readFileAlloc(f.resources.runtime.io(), saved.path.?, a, .limited(1024));
    try testing.expectEqualStrings("{broken", bytes);
}

test "a failed atomic save preserves both file and live map" {
    if (std.c.geteuid() == 0) return error.SkipZigTest;
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const initial = try f.get();
    const saved = try f.save(initial.revision, .{ .small = chosen });
    const directory = try std.Io.Dir.openDirAbsolute(f.resources.runtime.io(), std.fs.path.dirname(saved.path.?).?, .{ .iterate = true });
    defer directory.close(f.resources.runtime.io());
    try directory.setPermissions(f.resources.runtime.io(), .fromMode(0o500));
    defer directory.setPermissions(f.resources.runtime.io(), .fromMode(0o700)) catch unreachable;
    try testing.expectError(error.AgentConfigSaveFailed, f.save(saved.revision, .{ .medium = chosen }));
    try testing.expectEqual(saved.revision, (try f.get()).revision);
}

/// A session on `chosen.model`, whose levels are low, medium, and high, and whose default is medium.
fn seed(f: *Fixture, a: std.mem.Allocator) !proto.ids.SessionId {
    return (try commands.sessionCreate(&f.engine, a, .{ .workspace_path = "/work", .model = chosen.model })).session.id;
}

test "create refuses a session the catalog cannot serve" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    try testing.expectError(error.NoModel, commands.sessionCreate(&f.engine, a, .{ .workspace_path = "/work" }));
    try testing.expectError(error.ModelUnknown, commands.sessionCreate(&f.engine, a, .{ .workspace_path = "/work", .model = "family/model" }));
    try testing.expectError(error.ModelToolsUnsupported, commands.sessionCreate(&f.engine, a, .{ .workspace_path = "/work", .model = "local/no-tools" }));
    try testing.expectError(error.ReasoningUnsupported, commands.sessionCreate(&f.engine, a, .{ .workspace_path = "/work", .model = chosen.model, .reasoning = "max" }));
    try testing.expectError(error.ReasoningUnsupported, commands.sessionCreate(&f.engine, a, .{ .workspace_path = "/work", .model = chosen.model, .reasoning = "" }));
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
    try testing.expectEqualStrings(chosen.model, level.model);
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
    var launch: ?@import("turn.zig").Launch = null;
    defer @import("turn.zig").Launch.release(&launch, &f.engine);
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
    const same = try model_config.validate(&f.engine, a, chosen.model, .{ .inherit = "low" });
    try testing.expectEqualStrings("low", same.reasoning);
    const named = try model_config.validate(&f.engine, a, "local/high-only", .{ .inherit = "high" });
    try testing.expectEqualStrings("high", named.reasoning);

    // A level the child model does not name falls back to that model's default.
    const fallback = try model_config.validate(&f.engine, a, "local/high-only", .{ .inherit = "low" });
    try testing.expectEqualStrings("high", fallback.reasoning);
    const none = try model_config.validate(&f.engine, a, "local/flat", .{ .inherit = "medium" });
    try testing.expectEqualStrings("", none.reasoning);
    const empty = try model_config.validate(&f.engine, a, chosen.model, .{ .inherit = "" });
    try testing.expectEqualStrings("medium", empty.reasoning);

    // An explicit level is a claim, so the same mismatch refuses instead.
    try testing.expectError(error.ReasoningUnsupported, model_config.validate(&f.engine, a, "local/high-only", .{ .explicit = "low" }));
}
