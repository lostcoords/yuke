//! Model map tests use an isolated profile and explicit local providers.

const std = @import("std");
const proto = @import("proto");
const database = @import("../store/store.zig");
const provider = @import("../provider/provider.zig");
const Engine = @import("Engine.zig");
const config = @import("agent_config.zig");
const testing = std.testing;
const Resources = @import("test_resources.zig");
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
            \\{"version":1,"providers":[{"id":"local","base_url":"http://localhost:1/v1","protocol":"openai_chat","models":[{"id":"family/model","upstream_id":"family/model","reasoning_levels":["low","medium","high"],"flags":{"supports_tools":true}},{"id":"no-tools","upstream_id":"n","flags":{"supports_tools":false}},{"id":"unknown-tools","upstream_id":"u"}]},{"id":"locked","base_url":"http://localhost:1/v1","protocol":"openai_chat","auth":{"api_key":{"header":"x_api_key","source":{"env":"ABSENT_KEY"}}},"models":[{"id":"model","upstream_id":"m","flags":{"supports_tools":true}}]}]}
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
    for ([_][]const u8{ "{}", "{\"models\":{}}", "{\"models\":{\"small\":null}}", "{\"models\":{\"small\":{\"model\":\"p/a/b\"},\"medium\":{\"model\":\"p/a/b\",\"reasoning\":\"high\"}}}" }) |bytes| _ = try config.parse(arena.allocator(), null, bytes);
    for ([_][]const u8{ "", " ", "{", "null", "[]", "{\"large\":{}}", "{\"models\":null}", "{\"models\":{\"large\":{}}}", "{\"models\":{\"small\":{}}}", "{\"models\":{\"small\":{\"model\":null}}}", "{\"models\":{\"small\":{\"model\":\"\"}}}", "{\"models\":{\"small\":{\"model\":\"p/m\",\"extra\":true}}}", "{\"models\":{},\"models\":{}}" }) |bytes| try testing.expectError(error.BadAgentConfig, config.parse(arena.allocator(), null, bytes));
}

test "missing agent config has no inherited model and a saved map resolves exact selectors" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    const empty = try f.get();
    try testing.expect(std.mem.endsWith(u8, empty.path.?, "/agents-test/agents.json"));
    try testing.expect(empty.config.models.small == null and empty.config.models.medium == null);
    try testing.expectError(error.AgentSetupRequired, config.resolve(&f.engine, a, .{ .model = .small }));
    const saved = try f.save(empty.revision, .{ .small = chosen, .medium = chosen });
    try testing.expect(!std.mem.eql(u8, &empty.revision.raw, &saved.revision.raw));
    for ([_]proto.agents.AgentModelSlot{ .small, .medium }) |slot| {
        const resolved = try config.resolve(&f.engine, a, .{ .model = slot });
        try testing.expectEqualStrings(chosen.model, resolved.model);
        try testing.expectEqualStrings("medium", resolved.reasoning);
    }
    try testing.expectEqualStrings(chosen.model, (try f.get()).config.models.small.?.model);
    var fresh = f.resources.makeEngine(&f.db);
    defer fresh.close();
    const restored = try config.resolve(&fresh, a, .{ .model = .small });
    try testing.expectEqualStrings(chosen.model, restored.model);
}

test "model validation checks readiness known tools and reasoning before save" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const empty = try f.get();
    try testing.expectError(error.AgentUnknownModel, f.save(empty.revision, .{ .small = .{ .model = "family/model" } }));
    try testing.expectError(error.AgentProviderUnavailable, f.save(empty.revision, .{ .small = .{ .model = "locked/model" } }));
    @constCast(f.resources.providers.merged.resolveModel("locked/model").?.provider).availability = .{ .unavailable = .needs_route };
    try testing.expectError(error.AgentRouteUnavailable, f.save(empty.revision, .{ .small = .{ .model = "locked/model" } }));
    for ([_][]const u8{ "local/no-tools", "local/unknown-tools" }) |model| try testing.expectError(error.AgentToolsUnsupported, f.save(empty.revision, .{ .small = .{ .model = model } }));
    try testing.expectError(error.AgentReasoningUnsupported, f.save(empty.revision, .{ .small = .{ .model = chosen.model, .reasoning = "max" } }));
    try testing.expectError(error.AgentReasoningUnsupported, f.save(empty.revision, .{ .small = .{ .model = chosen.model, .reasoning = "" } }));
    try testing.expectEqual(empty.revision, (try f.get()).revision);
    const saved = try f.save(empty.revision, .{ .small = .{ .model = chosen.model, .reasoning = "high" } });
    try testing.expectEqualStrings("high", saved.config.models.small.?.reasoning.?);
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

test "an explicit model edit preserves a child history and requires an idle run boundary" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    const commands = @import("commands.zig");
    const parent = try commands.sessionCreate(&f.engine, a, .{ .workspace_path = "/work", .model = chosen.model });
    const child: proto.ids.SessionId = .bytes([_]u8{7} ** 16);
    try database.session.create(&f.db, .{ .id = child.raw, .root = "/work", .origin = "child", .parent_id = parent.session.id.raw, .parent_message_id = 1, .parent_part_id = 0, .name = "kid", .profile = "default", .model = chosen.model, .reasoning = "low", .config_rev = 0, .title = "child", .created_at_ms = 1, .updated_at_ms = 1 });
    {
        var tx = try f.db.begin();
        defer tx.deinit();
        try database.config.recordInitial(&f.db, child.raw, chosen.model, "low");
        try tx.commit();
    }
    const initial = try f.get();
    _ = try f.save(initial.revision, .{ .small = .{ .model = chosen.model, .reasoning = "high" } });
    try testing.expectEqualStrings("low", (try database.session.snapshot(&f.db, a, child.raw)).?.reasoning);
    const changed = try config.setModel(&f.engine, a, .{ .session_id = child, .model = .{ .model = chosen.model, .reasoning = "high" } });
    try testing.expectEqual(@as(u64, 1), changed.config.config_rev);
    try testing.expectEqualStrings("low", (try database.config.byRevision(&f.db, a, child.raw, 0)).?.reasoning);
    var launch: ?@import("turn.zig").Launch = null;
    _ = try commands.sessionSendInputForRpc(&f.engine, a, .{ .session_id = child, .input = .{ .content = .{ .content = &.{.{ .text = .{ .text = "continue" } }} } } }, &launch, null);
    try testing.expectError(error.SessionBusy, config.setModel(&f.engine, a, .{ .session_id = child, .model = chosen }));
    try testing.expectEqual(@as(u64, 1), (try database.event.highWater(&f.db, a, child.raw)).?.run_id_high);
    try testing.expectEqualStrings("high", (try database.session.snapshot(&f.db, a, child.raw)).?.reasoning);
}
