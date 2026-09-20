//! An advisory lock protects a shared `providers.json`; it covers the whole refresh—the disk read, expiry check, network call, and write—because a rotating refresh token is spent once, the provider rotates it, and the loser's grant dies, while a sibling lock file keeps the lock when `providers.json` replaces its inode.

const std = @import("std");
const zio = @import("zio");

const CredentialLock = @This();

/// How long one acquire waits before it gives up and leaves the grant for the next pass.
pub const wait_ms: u64 = 30_000;
/// How long one attempt waits before it tries again.
const retry_ms: u64 = 25;

file: std.Io.File,

/// Take the lock beside `providers_path`; return null when the file system gives no lock, and `error.Busy` when another process holds it for the whole wait.
pub fn acquire(gpa: std.mem.Allocator, io: std.Io, providers_path: []const u8) !?CredentialLock {
    return acquireFor(gpa, io, providers_path, wait_ms);
}

/// Take the lock with the given wait bound. A test waits a short bound where a refresh waits the full one.
fn acquireFor(gpa: std.mem.Allocator, io: std.Io, providers_path: []const u8, wait: u64) !?CredentialLock {
    std.debug.assert(wait >= retry_ms);
    const path = try std.mem.concat(gpa, u8, &.{ providers_path, ".lock" });
    defer gpa.free(path);

    const file = try std.Io.Dir.createFileAbsolute(io, path, .{
        .truncate = false,
        .permissions = std.Io.File.Permissions.fromMode(0o600),
    });
    errdefer file.close(io);

    var waited: u64 = 0;
    while (waited < wait) : (waited += retry_ms) {
        const held = file.tryLock(io, .exclusive) catch |err| switch (err) {
            error.FileLocksUnsupported => return null,
            else => |e| return e,
        };
        if (held) return .{ .file = file };
        try std.Io.sleep(io, .fromMilliseconds(retry_ms), .awake);
    }
    return error.Busy;
}

pub fn release(self: CredentialLock, io: std.Io) void {
    self.file.unlock(io);
    self.file.close(io);
}

test "one holder blocks a second acquire and a release lets it through" {
    const rt = try zio.Runtime.init(std.testing.allocator, .{ .executors = .exact(1) });
    defer rt.deinit();
    const io = rt.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &buf);
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/providers.json", .{buf[0..len]});

    const first = (try acquire(std.testing.allocator, io, path)) orelse return; // no locks here
    // A second acquire in this process must stay busy for the short bound, not report a free lock.
    const second = acquireFor(std.testing.allocator, io, path, 100);
    try std.testing.expectError(error.Busy, second);

    first.release(io);
    const third = (try acquire(std.testing.allocator, io, path)) orelse return;
    third.release(io);
}
