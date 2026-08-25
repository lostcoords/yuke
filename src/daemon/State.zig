//! Daemon-global state. One reactor executor owns it for the daemon lifetime.
//! Keep the per-connection state separate.

const std = @import("std");
const zio = @import("zio");
const zqlite = @import("zqlite");
const wire = @import("wire");
const database = @import("../database/database.zig");
const committed = @import("../domain/committed.zig");
const domain_session = @import("../domain/session.zig");
const util = @import("../util.zig");
const provider = @import("../provider/provider.zig");
const session_runtime = @import("session_runtime.zig");
const connection = @import("connection.zig");

const State = @This();

gpa: std.mem.Allocator, // The allocator serves long-lived allocations. The per-request arena has a separate lifetime.
io: std.Io, // The reactor uses this I/O for the clock, files, and sockets.
db: database.Database, // The database uses one SQLite connection with prepared queries. One executor writes.
config: Config,
home: []const u8, // The default workspace root. A create that omits a workspace path uses it.
sessions: session_runtime.Sessions, // The daemon stores live per-session state, keyed by session id.
registry: connection.Registry, // The registry tracks live connections and the reverse subscription index.
transport: provider.transport.Transport, // The transport opens each provider response. A test or adapter overrides it.
providers: ?provider.config.Loaded = null, // The daemon owns the loaded providers.json layer when present.
env: ?*const std.process.Environ.Map = null, // This pointer borrows the process environment for key lookup.
run_group: std.Io.Group = .init, // The group owns each launched run task until it returns.
shutting_down: bool = false,
broadcast_tap: ?*BroadcastTap = null, // A conformance test records the published broadcasts here.

/// A test hook. It records each published broadcast, so a conformance test refolds the daemon output.
pub const BroadcastTap = struct {
    arena: std.heap.ArenaAllocator,
    events: std.ArrayList(wire.rpc.BroadcastData) = .empty,

    pub fn init(gpa: std.mem.Allocator) BroadcastTap {
        return .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    }
    pub fn deinit(self: *BroadcastTap) void {
        self.arena.deinit();
    }
    pub fn record(self: *BroadcastTap, params: wire.rpc.BroadcastData) !void {
        const a = self.arena.allocator();
        try self.events.append(a, try wire.dupe(a, params));
    }
};

/// The daemon stores its configuration here.
pub const Config = struct {
    listen: zio.net.IpAddress,
    db_path: [:0]const u8 = ":memory:",
};

/// Build the daemon state. It takes ownership of `db` and borrows `io` for its lifetime.
pub fn init(gpa: std.mem.Allocator, io: std.Io, db: database.Database, config: Config, home: []const u8) !State {
    var self: State = .{
        .gpa = gpa,
        .io = io,
        .db = db,
        .config = config,
        .home = home,
        .sessions = session_runtime.Sessions.init(gpa),
        .registry = connection.Registry.init(gpa),
        .transport = provider.transport.placeholderTransport(),
    };
    errdefer self.deinit();

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var event_ids: RecoveryEventIds = .{ .state = &self };
    const recovered = try database.run.recoverOpen(&self.db, arena.allocator(), self.nowMillis(), &event_ids);
    if (recovered > 0) std.log.info("recovered {d} open runs as canceled", .{recovered});
    const pending_sessions = try database.input.sessionIds(&self.db, arena.allocator());
    for (pending_sessions) |session_id| _ = try self.activate(.bytes(session_id));
    return self;
}

/// Return the live runtime for a session and seed its projection from SQLite once.
/// The caller must know the session exists. A durable event then folds onto the hydrated cursors.
pub fn activate(self: *State, session_id: wire.ids.SessionId) !*session_runtime.SessionRuntime {
    const rt = try self.sessions.getOrCreate(session_id);
    if (!rt.hydrated) {
        var session = domain_session.Session.init(self.gpa, session_id);
        errdefer session.deinit();
        try self.hydrateSession(&session);
        rt.session.deinit();
        rt.session = session;
        session = undefined;
        rt.hydrated = true;
    }
    return rt;
}

/// Load the committed window, the configs, the durable cursors, and the pending inputs into a session.
/// SQLite stays authoritative. The daemon caches the recent tail so resync serializes the projection.
pub fn hydrateSession(self: *State, session: *domain_session.Session) !void {
    std.debug.assert(session.active == null and session.queue.depth() == 0);
    std.debug.assert(session.committed.list.items.len == 0 and session.configs.map.count() == 0);
    std.debug.assert(session.base_seq == 0 and session.finalized_message_id == 0);
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const sid = session.id.raw;
    const hw = (try database.event.highWater(&self.db, a, sid)) orelse return; // No session row exists.
    const page = try database.message.historyPage(&self.db, a, sid, 0, committed.default_max_messages);
    const configs = try database.config.forMessages(&self.db, a, sid, page.messages);
    const finalized: u64 = if (page.messages.len > 0) page.messages[page.messages.len - 1].id() else 0;
    try session.installSnapshot(.{
        .base_seq = hw.seq_high,
        .finalized_message_id = finalized,
        .messages = page.messages,
        .configs = configs,
        .has_more = page.has_more,
    });
    // Pending inputs are historical. Fold them directly, so they do not advance the durable cursor.
    const pending = try database.input.list(&self.db, a, sid);
    for (pending) |entry| {
        const applied = try session.queue.onQueued(.{ .session_id = session.id, .seq = entry.seq, .input = entry.input });
        std.debug.assert(applied == .changed);
    }
}

const RecoveryEventIds = struct {
    state: *State,

    pub fn next(self: *RecoveryEventIds) ![16]u8 {
        return self.state.newId();
    }
};

/// Free the live sessions and the registry, then close the store.
pub fn deinit(self: *State) void {
    self.shutting_down = true;
    self.run_group.cancel(self.io);
    self.registry.deinit();
    self.sessions.deinit();
    if (self.providers) |*p| p.deinit();
    self.db.deinit();
}

/// Return wall-clock milliseconds since the Unix epoch. See util.nowMillis for the clock rules.
pub fn nowMillis(self: *const State) u64 {
    return util.nowMillis(self.io);
}

/// Mint a fresh UUIDv7 for a session, workspace, or event.
pub fn newId(self: *const State) [16]u8 {
    return util.newId(self.io);
}

test "init restores durable pending input into the runtime queue" {
    var runtime = try zio.Runtime.init(std.testing.allocator, .{ .executors = .exact(1) });
    defer runtime.deinit();
    const listen = try zio.net.IpAddress.parseIp4("127.0.0.1", 0);
    const sqlite = try zqlite.open(":memory:", zqlite.OpenFlags.Create | zqlite.OpenFlags.NoMutex | zqlite.OpenFlags.EXResCode);
    var db = try database.Database.open(sqlite);
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const workspace_id = [_]u8{1} ** 16;
    const session_id = [_]u8{2} ** 16;
    _ = try database.workspace.resolve(&db, arena, workspace_id, "/boot", "boot", null);
    try database.session.create(&db, .{
        .id = session_id,
        .workspace_id = workspace_id,
        .origin = "root",
        .profile = "default",
        .model = "mock",
        .reasoning = "",
        .config_rev = 0,
        .permission = "normal",
        .title = "boot",
        .created_at_ms = 1,
        .updated_at_ms = 1,
    });
    try db.conn.execNoArgs("BEGIN IMMEDIATE");
    const queued = try database.input.enqueue(&db, arena, session_id, [_]u8{3} ** 16, 2, &.{.{ .text = .{ .text = "recover" } }}, 2);
    try db.conn.execNoArgs("COMMIT");

    var state = try State.init(std.testing.allocator, runtime.io(), db, .{ .listen = listen }, "/home/test");
    defer state.deinit();
    const rt = state.sessions.get(.bytes(session_id)).?;
    try std.testing.expectEqual(@as(usize, 1), rt.session.queue.depth());
    try std.testing.expectEqual(queued.input.input_id, rt.session.queue.entries()[0].input_id);
}

test "activation does not retain partial hydration after allocation failure" {
    var runtime = try zio.Runtime.init(std.testing.allocator, .{ .executors = .exact(1) });
    defer runtime.deinit();
    const listen = try zio.net.IpAddress.parseIp4("127.0.0.1", 0);
    const sqlite = try zqlite.open(":memory:", zqlite.OpenFlags.Create | zqlite.OpenFlags.NoMutex | zqlite.OpenFlags.EXResCode);
    var db = try database.Database.open(sqlite);
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const workspace_id = [_]u8{4} ** 16;
    const session_id = [_]u8{5} ** 16;
    _ = try database.workspace.resolve(&db, arena, workspace_id, "/oom", "oom", null);
    try database.session.create(&db, .{
        .id = session_id,
        .workspace_id = workspace_id,
        .origin = "root",
        .profile = "default",
        .model = "mock",
        .reasoning = "",
        .config_rev = 0,
        .permission = "normal",
        .title = "oom",
        .created_at_ms = 1,
        .updated_at_ms = 1,
    });
    try db.conn.execNoArgs("BEGIN IMMEDIATE");
    _ = try database.input.enqueue(&db, arena, session_id, [_]u8{6} ** 16, 2, &.{.{ .text = .{ .text = "recover" } }}, 2);
    try db.conn.execNoArgs("COMMIT");

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var state = try State.init(failing.allocator(), runtime.io(), db, .{ .listen = listen }, "/home/test");
    defer state.deinit();
    const rt = state.sessions.get(.bytes(session_id)).?;
    const baseline = failing.alloc_index;
    var saw_oom = false;

    var fail_offset: usize = 0;
    while (fail_offset < 128) : (fail_offset += 1) {
        rt.session.deinit();
        rt.session = domain_session.Session.init(failing.allocator(), .bytes(session_id));
        rt.hydrated = false;
        failing.alloc_index = baseline;
        failing.fail_index = baseline + fail_offset;
        failing.has_induced_failure = false;

        _ = state.activate(.bytes(session_id)) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            saw_oom = true;
            try std.testing.expect(!rt.hydrated);
            try std.testing.expectEqual(@as(usize, 0), rt.session.queue.depth());
            try std.testing.expectEqual(@as(usize, 0), rt.session.committed.list.items.len);
            try std.testing.expectEqual(@as(u64, 0), rt.session.base_seq);
            continue;
        };
    }
    try std.testing.expect(saw_oom);
}
