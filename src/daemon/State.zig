//! Daemon-global state. One reactor executor owns it for the daemon lifetime.
//! Keep per-connection state separate; connection identity is added later.

const std = @import("std");
const zio = @import("zio");
const database = @import("../database/database.zig");
const util = @import("../util.zig");
const session_runtime = @import("session_runtime.zig");
const connection = @import("connection.zig");

const State = @This();

gpa: std.mem.Allocator, // Long-lived allocations. The per-request arena has a separate lifetime.
io: std.Io, // Reactor I/O for the clock, files, and sockets.
db: database.Database, // One SQLite connection with prepared queries. One executor writes.
config: Config,
home: []const u8, // The default workspace root. A create with no workspace path uses it.
sessions: session_runtime.Sessions, // Live per-session state, keyed by session id.
registry: connection.Registry, // Live connections and the reverse subscription index.

/// Daemon configuration. The code sets it directly for now.
pub const Config = struct {
    listen: zio.net.IpAddress,
    db_path: [:0]const u8 = ":memory:",
};

/// Build the daemon state. The caller keeps `db` and `io` alive for the daemon lifetime.
pub fn init(gpa: std.mem.Allocator, io: std.Io, db: database.Database, config: Config, home: []const u8) State {
    return .{
        .gpa = gpa,
        .io = io,
        .db = db,
        .config = config,
        .home = home,
        .sessions = session_runtime.Sessions.init(gpa),
        .registry = connection.Registry.init(gpa),
    };
}

/// Free the live sessions and the registry, then close the store.
pub fn deinit(self: *State) void {
    self.registry.deinit();
    self.sessions.deinit();
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
