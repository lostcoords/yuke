//! Daemon-global state. One reactor executor owns it for the daemon lifetime.
//! Keep per-connection state separate. Add connection identity later.

const std = @import("std");
const zio = @import("zio");
const zqlite = @import("zqlite");
const database = @import("../database/database.zig");
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
run_group: zio.Group = .init, // The group owns each launched run task until it returns.
shutting_down: bool = false,

/// The daemon uses this configuration directly for now.
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
    for (pending_sessions) |session_id| {
        const rt = try self.sessions.getOrCreate(.bytes(session_id));
        const entries = try database.input.list(&self.db, arena.allocator(), session_id);
        for (entries) |entry| {
            const applied = try rt.queue.onQueued(.{ .session_id = .bytes(session_id), .input = entry.input });
            std.debug.assert(applied == .changed);
        }
    }
    return self;
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
    self.run_group.cancel();
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
    try std.testing.expectEqual(@as(usize, 1), rt.queue.depth());
    try std.testing.expectEqual(queued.input.input_id, rt.queue.entries()[0].input_id);
}
