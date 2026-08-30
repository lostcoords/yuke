//! The single-instance lock of the daemon. One daemon owns the data directory and the front door.
//! The lock is advisory. The operating system releases it when the process ends, a crash included.

const std = @import("std");
const paths = @import("../paths/paths.zig");

const InstanceLock = @This();

file: std.Io.File,

pub const Error = error{DaemonAlreadyRunning};

/// Take the exclusive lock under the data directory `base`, which must be absolute.
/// Return `DaemonAlreadyRunning` when another daemon holds it.
/// Return null when the file system gives no lock, because a lock is not available everywhere.
pub fn acquire(gpa: std.mem.Allocator, io: std.Io, base: []const u8) !?InstanceLock {
    std.debug.assert(std.fs.path.isAbsolute(base));
    const path = try paths.lockPathIn(gpa, base);
    defer gpa.free(path);

    // Keep the content. A second daemon must not truncate the file of the daemon that holds the lock.
    const file = try std.Io.Dir.createFileAbsolute(io, path, .{
        .truncate = false,
        .permissions = std.Io.File.Permissions.fromMode(0o600),
    });
    errdefer file.close(io);

    const held = file.tryLock(io, .exclusive) catch |err| switch (err) {
        error.FileLocksUnsupported => return null,
        else => |e| return e,
    };
    if (!held) return Error.DaemonAlreadyRunning;
    return .{ .file = file };
}

pub fn release(self: InstanceLock, io: std.Io) void {
    self.file.unlock(io);
    self.file.close(io);
}

test "the second acquire fails while the first lock is held" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(io, &buf)];

    const first = try acquire(testing.allocator, io, base) orelse return error.SkipZigTest;
    try testing.expectError(Error.DaemonAlreadyRunning, acquire(testing.allocator, io, base));

    // The release frees the lock, so the next daemon starts.
    first.release(io);
    const second = (try acquire(testing.allocator, io, base)).?;
    second.release(io);
}
