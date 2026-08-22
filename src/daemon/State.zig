//! Daemon-global state. One reactor executor owns it for the daemon lifetime.
//! Keep per-connection state separate; later slices add subscriptions and identity.

const std = @import("std");
const zio = @import("zio");
const database = @import("../database/database.zig");

const State = @This();

gpa: std.mem.Allocator, // Long-lived allocations. The per-request arena has a separate lifetime.
io: std.Io, // Reactor I/O for the clock, files, and sockets.
db: database.Database, // One SQLite connection with prepared queries. One executor writes.
config: Config,

/// Daemon configuration. The code sets it directly for now.
pub const Config = struct {
    listen: zio.net.IpAddress,
    db_path: [:0]const u8 = ":memory:",
};

/// Return wall-clock milliseconds since the Unix epoch. Clamp times before 1970 to 0.
/// This clock is not monotonic. Do not use it for durations or timeouts.
pub fn nowMillis(self: *const State) u64 {
    const ms = std.Io.Timestamp.now(self.io, .real).toMilliseconds();
    return @intCast(@max(ms, 0));
}
