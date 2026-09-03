//! An advisory lock over the credential file.
//!
//! Several yuke processes may share one `providers.json`. A rotating refresh token can be spent
//! exactly once, so two processes must never send the same one: the provider rotates, and the
//! loser's grant dies. The lock therefore covers the WHOLE refresh — the read from disk, the
//! expiry check, the network call, and the write — not only the write.
//!
//! The lock lives on a sibling file, because a write to `providers.json` replaces its inode and
//! would drop a lock held on the file itself.

const std = @import("std");

const CredentialLock = @This();

/// How long one acquire waits before it gives up and leaves the grant for the next pass.
pub const wait_ms: u64 = 30_000;
/// How long one attempt waits before it tries again.
const retry_ms: u64 = 25;

file: std.Io.File,

/// Take the lock beside `providers_path`. Return null when the file system gives no lock, and
/// `error.Busy` when another process holds it for the whole wait.
pub fn acquire(gpa: std.mem.Allocator, io: std.Io, providers_path: []const u8) !?CredentialLock {
    const path = try std.mem.concat(gpa, u8, &.{ providers_path, ".lock" });
    defer gpa.free(path);

    const file = try std.Io.Dir.createFileAbsolute(io, path, .{
        .truncate = false,
        .permissions = std.Io.File.Permissions.fromMode(0o600),
    });
    errdefer file.close(io);

    var waited: u64 = 0;
    while (waited < wait_ms) : (waited += retry_ms) {
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
    const zio = @import("zio");
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
    // A second acquire on the same path in this process reports the same lock, so it must not
    // report a free lock. The wait is bounded, so the test never hangs.
    const second = acquire(std.testing.allocator, io, path);
    try std.testing.expectError(error.Busy, second);

    first.release(io);
    const third = (try acquire(std.testing.allocator, io, path)) orelse return;
    third.release(io);
}
