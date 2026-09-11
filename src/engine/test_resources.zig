//! Test resources stay at one address until all engines that borrow them close.

const std = @import("std");
const testing = std.testing;
const zio = @import("zio");
const ai = @import("ai");
const proto = @import("proto");
const Engine = @import("Engine.zig");
const commands = @import("commands.zig");
const turn = @import("turn.zig");
const database = @import("../store/store.zig");
const Database = database.Database;
const ProviderStore = @import("../provider/provider_store.zig");
const registry = @import("../provider/registry.zig");
const Resources = @This();

runtime: *zio.Runtime,
env: std.process.Environ.Map,
providers: ProviderStore,
transport: ai.transport.CannedTransport,
blobs: testing.TmpDir,
blob_dir_buf: [std.fs.max_path_bytes]u8,
blob_dir: []const u8,

pub fn init(self: *Resources) !void {
    std.debug.assert(@import("builtin").is_test);
    self.runtime = try zio.Runtime.init(std.testing.allocator, .{ .executors = .exact(1) });
    self.env = .init(std.testing.allocator);
    self.providers = .init(std.testing.allocator, self.runtime.io(), &self.env);
    self.transport = .{ .bytes = ai.transport.canned_reply };
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

pub fn makeEngine(self: *Resources, db: *Database) Engine {
    std.debug.assert(self.providers.env == &self.env);
    return Engine.init(.{
        .gpa = std.testing.allocator,
        .io = self.runtime.io(),
        .db = db,
        .blobs = .{ .dir = self.blob_dir },
        .providers = &self.providers,
        .route_transport = self.transport.transport(),
        .execution = @import("../execution.zig").testContext(&self.env),
    });
}

/// Record every request body, and answer each with the next reply. A request past the list fails.
pub const Capture = struct {
    arena: std.mem.Allocator,
    replies: []const []const u8,
    requests: std.ArrayList([]const u8) = .empty,

    pub fn transport(self: *Capture) ai.transport.Transport {
        return .{ .ctx = self, .vtable = &.{ .open = open } };
    }

    fn open(ctx: *anyopaque, arena: std.mem.Allocator, request: ai.transport.Request, _: *ai.transport.AttemptInfo) !ai.transport.ResponseBody {
        const self: *Capture = @ptrCast(@alignCast(ctx));
        const index = self.requests.items.len;
        try self.requests.append(self.arena, try self.arena.dupe(u8, request.body));
        if (index >= self.replies.len) return error.UnexpectedRequest;
        const reader = try arena.create(ai.transport.ReplayReader);
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
    gate: ?turn.Launch = null,

    pub const id: proto.ids.SessionId = .bytes([_]u8{74} ** 16);

    pub const Options = struct {
        modalities: ai.types.Modalities = .{},
        replies: []const []const u8 = &.{ai.transport.canned_reply},
    };

    pub fn init(self: *Fixture, options: Options) !void {
        self.* = .{ .resources = undefined, .db = undefined, .engine = undefined, .arena = .init(testing.allocator), .models = undefined, .rows = undefined, .capture = undefined };
        try self.resources.init();
        self.db = try Database.openTest();
        self.engine = self.resources.makeEngine(&self.db);
        self.models = .{.{ .id = "m", .upstream_id = "m", .name = "M", .caps = .{ .tools = true }, .modalities = options.modalities }};
        self.rows = .{.{ .id = "mock", .name = "Mock", .models = &self.models, .availability = .{ .ready = .{
            .route = .{ .base_url = "https://example.test", .protocol = .anthropic_messages, .auth = .none },
            .credential = .none,
        } } }};
        self.resources.providers.merged.rows = &self.rows;
        self.capture = .{ .arena = self.arena.allocator(), .replies = options.replies };
        self.engine.deps.route_transport = self.capture.transport();
        try database.session.create(&self.db, .{ .id = id.raw, .root = "/work", .origin = "root", .profile = "default", .model = "mock/m", .reasoning = "", .config_rev = 0, .title = "test", .created_at_ms = 1, .updated_at_ms = 1 });
        _ = try database.session.setPrompt(&self.db, self.arena.allocator(), id.raw, .{ .base = "", .child_policy = null, .environment = "" });
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
        turn.Launch.release(&self.gate, &self.engine);
        for (0..1000) |_| {
            const resident = self.engine.sessions.get(session);
            if (resident == null or (resident.?.active_run == null and resident.?.queueDepth() == 0)) return;
            try std.Io.sleep(self.engine.deps.io, .fromMilliseconds(1), .awake);
        }
        return error.RunDidNotFinish;
    }

    pub fn history(self: *Fixture) ![]const proto.message.Message {
        return (try database.message.historyPage(&self.db, self.arena.allocator(), id.raw, 0, 100)).messages;
    }
};
