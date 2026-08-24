//! Daemon-global state. One reactor executor owns it for the daemon lifetime.
//! Keep per-connection state separate; later slices add subscriptions and identity.

const std = @import("std");
const zio = @import("zio");
const database = @import("../database/database.zig");
const util = @import("../util.zig");

const State = @This();

gpa: std.mem.Allocator, // Long-lived allocations. The per-request arena has a separate lifetime.
io: std.Io, // Reactor I/O for the clock, files, and sockets.
db: database.Database, // One SQLite connection with prepared queries. One executor writes.
config: Config,
home: []const u8, // The default workspace root. A create with no workspace path uses it.

/// Daemon configuration. The code sets it directly for now.
pub const Config = struct {
    listen: zio.net.IpAddress,
    db_path: [:0]const u8 = ":memory:",
};

/// Wall-clock milliseconds since the Unix epoch. See util.nowMillis for the clock rules.
pub fn nowMillis(self: *const State) u64 {
    return util.nowMillis(self.io);
}

/// Mint a fresh UUIDv7 for a session, workspace, or event.
pub fn newId(self: *const State) [16]u8 {
    return util.newId(self.io);
}
