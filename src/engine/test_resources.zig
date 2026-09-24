//! Test resources stay at one address until all engines that borrow them close.

const std = @import("std");
const testing = std.testing;
const zio = @import("zio");
const ai = @import("ai");
const proto = @import("proto");
const hookset = @import("hookset.zig");
const Engine = @import("Engine.zig");
const commands = @import("commands.zig");
const runs = @import("run.zig");
const database = @import("../store/store.zig");
const Database = database.Database;
const ProviderStore = @import("../provider/provider_store.zig");
const registry = @import("../provider/registry.zig");
const builtin = @import("builtin");
const execution = @import("../execution.zig");
const Resources = @This();

runtime: *zio.Runtime,
env: std.process.Environ.Map,
providers: ProviderStore,
transport: ai.testing.CannedTransport,
blobs: testing.TmpDir,
blob_dir_buf: [std.Io.Dir.max_path_bytes]u8,
blob_dir: []const u8,

pub fn init(self: *Resources) !void {
    std.debug.assert(builtin.is_test);
    self.runtime = try zio.Runtime.init(std.testing.allocator, .{ .executors = .exact(1) });
    self.env = .init(std.testing.allocator);
    self.providers = .init(std.testing.allocator, self.runtime.io(), &self.env);
    self.transport = .{ .bytes = ai.testing.canned_reply };
    self.blobs = testing.tmpDir(.{});
    self.blob_dir = self.blob_dir_buf[0..try self.blobs.dir.realPath(testing.io, &self.blob_dir_buf)];
    std.debug.assert(self.providers.env == &self.env);
}

pub fn deinit(self: *Resources) void {
    std.debug.assert(self.providers.env == &self.env);
    self.providers.deinit();
    self.env.deinit();
    self.runtime.deinit();
    self.blobs.cleanup();
    self.* = undefined;
}

/// A tool port answer for tests: the tools a canned reply calls, so the run loadout admits them.
pub fn serveTools(comptime list: []const []const u8) *const fn (*anyopaque, std.mem.Allocator) error{OutOfMemory}![]const ai.ir.Tool {
    return struct {
        fn decls(_: *anyopaque, arena: std.mem.Allocator) error{OutOfMemory}![]const ai.ir.Tool {
            const out = try arena.alloc(ai.ir.Tool, list.len);
            for (list, out) |name, *decl| decl.* = .{ .name = name, .description = name, .input_schema = "{}" };
            return out;
        }
    }.decls;
}

pub fn makeEngine(self: *Resources, db: *Database) Engine {
    std.debug.assert(self.providers.env == &self.env);
    return Engine.init(.{
        .gpa = std.testing.allocator,
        .io = self.runtime.io(),
        .db = db,
        .blobs = .{ .dir = self.blob_dir },
        .providers = &self.providers,
        .route_transport = self.transport.transport(),
        .execution = execution.testContext(&self.env),
        .hooks = compaction_prompt_hooks,
    });
}

/// A stand-in for the prompt plugin: it answers `compaction.prompt` with a short text that names the mode.
pub const compaction_prompt_hooks: hookset.HookSet = .{ .holds = CompactionPrompt.holds, .ask = CompactionPrompt.ask };

const CompactionPrompt = struct {
    fn holds(_: *anyopaque, point: proto.hook.Point) bool {
        return point == .@"compaction.prompt";
    }
    fn ask(_: *anyopaque, out: std.mem.Allocator, point: proto.hook.Point, payload: []const u8) hookset.Decision {
        std.debug.assert(point == .@"compaction.prompt");
        const merge = std.mem.indexOf(u8, payload, "\"mode\":\"merge\"") != null;
        const text = if (merge) "{\"prompt\":\"Merge the context summary with the new messages.\"}" else "{\"prompt\":\"You are a context summarization assistant. Write a context checkpoint.\"}";
        return .{ .replace = std.json.parseFromSliceLeaky(std.json.Value, out, text, .{}) catch unreachable };
    }
};

pub const SessionOptions = struct {
    root: []const u8 = "/w",
    origin: []const u8 = "root",
    parent_id: ?[16]u8 = null,
    parent_message_id: ?u64 = null,
    parent_part_id: ?u64 = null,
    name: ?[]const u8 = null,
    model: []const u8 = "mock/m",
    reasoning: []const u8 = "",
    title: []const u8 = "test",
    created_at_ms: u64 = 1,
    updated_at_ms: u64 = 1,
};

pub fn seedSession(db: *Database, id: [16]u8, options: SessionOptions) !void {
    try database.session.create(db, .{
        .id = id,
        .root = options.root,
        .origin = options.origin,
        .parent_id = options.parent_id,
        .parent_message_id = options.parent_message_id,
        .parent_part_id = options.parent_part_id,
        .name = options.name,
        .model = options.model,
        .reasoning = options.reasoning,
        .config_rev = 0,
        .title = options.title,
        .created_at_ms = options.created_at_ms,
        .updated_at_ms = options.updated_at_ms,
    });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = try database.session.setPrompt(db, arena.allocator(), id, &.{}, database.session.stale_generation);
}

pub const MockProviderOptions = struct {
    id: []const u8 = "mock",
    name: []const u8 = "Mock",
    base_url: []const u8 = "https://example.test",
    protocol: ai.Protocol = .anthropic_messages,
    headers: []const ai.Header = &.{},
    credential: registry.CredentialSource = .none,
    authenticated: bool = false,
};

pub fn mockProvider(models: []const registry.ModelSpec, options: MockProviderOptions) registry.Provider {
    const endpoints = switch (options.protocol) {
        .anthropic_messages => if (options.authenticated)
            &[_]ai.route.Endpoint{.{ .protocol = .anthropic_messages, .key_header = .x_api_key }}
        else
            &[_]ai.route.Endpoint{.{ .protocol = .anthropic_messages }},
        .openai_chat => if (options.authenticated)
            &[_]ai.route.Endpoint{.{ .protocol = .openai_chat, .key_header = .authorization_bearer }}
        else
            &[_]ai.route.Endpoint{.{ .protocol = .openai_chat }},
        .openai_responses => if (options.authenticated)
            &[_]ai.route.Endpoint{.{ .protocol = .openai_responses, .key_header = .authorization_bearer }}
        else
            &[_]ai.route.Endpoint{.{ .protocol = .openai_responses }},
    };
    return .{
        .id = options.id,
        .name = options.name,
        .models = models,
        .availability = .{ .ready = .{
            .base_url = options.base_url,
            .headers = options.headers,
            .session_header = .none,
            .endpoints = endpoints,
            .credential = options.credential,
        } },
    };
}

pub fn waitUntil(io: std.Io, state: anytype) !void {
    for (0..1000) |_| {
        if (try state.done()) return;
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    return error.WaitDidNotFinish;
}

pub fn awaitLiveIdle(engine: *Engine, id: proto.ids.SessionId) !void {
    for (0..1000) |_| {
        const resident = engine.sessions.get(id);
        if (resident == null or (resident.?.active_run == null and resident.?.queueDepth() == 0)) return;
        try std.Io.sleep(engine.deps.io, .fromMilliseconds(1), .awake);
    }
    return error.RunDidNotFinish;
}

pub fn awaitDurableRun(engine: *Engine, db: *Database, arena: std.mem.Allocator, id: [16]u8, run_id: u64) !void {
    for (0..1000) |_| {
        const marks = (try database.event.highWater(db, arena, id)).?;
        if (marks.run_id_high >= run_id and (try database.session.snapshot(db, arena, id)).?.open_run_id == null) return;
        try std.Io.sleep(engine.deps.io, .fromMilliseconds(1), .awake);
    }
    return error.RunDidNotFinish;
}

/// One Anthropic stream that calls the tool `unknown` with no arguments and stops for its result.
pub const tool_reply =
    "data: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":0}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"unknown\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

/// One Anthropic stream that searches for a tool and pauses before the server loop ends.
pub const pause_reply =
    "data: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":0}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"searching\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"server_tool_use\",\"id\":\"srvtoolu_1\",\"name\":\"tool_search_tool_bm25\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"query\\\":\\\"read\\\"}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":1}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"pause_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

/// Record every request body and header set, and answer each with the next reply. A request past the list fails.
pub const Capture = struct {
    arena: std.mem.Allocator,
    replies: []const []const u8,
    requests: std.ArrayList([]const u8) = .empty,
    headers: std.ArrayList([]const ai.Header) = .empty,

    pub fn transport(self: *Capture) ai.transport.Transport {
        return .{ .ctx = self, .vtable = &.{ .open = open } };
    }

    fn open(ctx: *anyopaque, arena: std.mem.Allocator, request: ai.transport.Request, _: *ai.transport.AttemptInfo) !ai.transport.ResponseBody {
        const self: *Capture = @ptrCast(@alignCast(ctx));
        const index = self.requests.items.len;
        try self.requests.append(self.arena, try self.arena.dupe(u8, request.body));
        const copied = try self.arena.alloc(ai.Header, request.headers.len);
        for (request.headers, 0..) |h, i| copied[i] = try h.cloneLeaky(self.arena);
        try self.headers.append(self.arena, copied);
        if (index >= self.replies.len) return error.UnexpectedRequest;
        const reader = try arena.create(ai.testing.ReplayReader);
        reader.* = .{ .bytes = self.replies[index] };
        return reader.body();
    }
};

/// One engine over a mock Anthropic route, one session, and a capture transport. It must not move.
pub const Fixture = struct {
    resources: Resources,
    db: Database,
    engine: Engine,
    arena: std.heap.ArenaAllocator,
    models: [1]registry.ModelSpec,
    rows: [1]registry.Provider,
    capture: Capture,
    gate: ?runs.Launch = null,

    pub const id: proto.ids.SessionId = .bytes([_]u8{74} ** 16);

    pub const Options = struct {
        modalities: ai.Modalities = .{},
        replies: []const []const u8 = &.{ai.testing.canned_reply},
    };

    pub fn init(self: *Fixture, options: Options) !void {
        self.* = .{ .resources = undefined, .db = undefined, .engine = undefined, .arena = .init(testing.allocator), .models = undefined, .rows = undefined, .capture = undefined };
        try self.resources.init();
        self.db = try Database.openTest();
        self.engine = self.resources.makeEngine(&self.db);
        self.models = .{.{ .id = "m", .upstream_id = "m", .name = "M", .protocol = .anthropic_messages, .caps = .{ .tools = true }, .modalities = options.modalities }};
        self.rows = .{mockProvider(&self.models, .{})};
        self.resources.providers.merged.rows = &self.rows;
        self.capture = .{ .arena = self.arena.allocator(), .replies = options.replies };
        self.engine.deps.route_transport = self.capture.transport();
        try seedSession(&self.db, id.raw, .{ .root = "/work" });
    }

    pub fn deinit(self: *Fixture) void {
        self.engine.close();
        self.resources.providers.merged.rows = &.{};
        self.db.deinit();
        self.resources.deinit();
        self.arena.deinit();
    }

    /// Queue one input on the fixture session. `finish` releases the launch.
    pub fn send(self: *Fixture, content: []const proto.content.ContentPart) !proto.session.SessionSendInputResult {
        return commands.sessionSendInputForRpc(&self.engine, self.arena.allocator(), .{ .session_id = id, .input = .{ .content = .{ .content = content } } }, &self.gate, null);
    }

    /// Start the launched run and wait until the session is idle again.
    pub fn finish(self: *Fixture, session: proto.ids.SessionId) !void {
        runs.Launch.release(&self.gate, &self.engine);
        try awaitLiveIdle(&self.engine, session);
    }

    pub fn history(self: *Fixture) ![]const proto.message.Message {
        return (try database.message.historyPage(&self.db, self.arena.allocator(), id.raw, 0, 100)).messages;
    }
};
