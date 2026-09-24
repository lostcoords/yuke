//! The private directory for command logs. Only the owner creates a path, and `Host.destroy` deletes the directory.

const std = @import("std");
const h = @import("operations.zig");

pub const Logs = struct {
    /// Null until the first log, so a host that runs no logged command creates nothing.
    dir: ?[]u8 = null,
    count: u32 = 0,

    /// Answer a new absolute log path from `gpa`. The directory has mode 0700, because a log can hold secrets.
    pub fn next(self: *Logs, gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, name: []const u8) h.HostError![]u8 {
        std.debug.assert(name.len > 0 and std.mem.indexOfScalar(u8, name, '/') == null);
        if (self.dir == null) {
            const tmp = env.get("TMPDIR") orelse "/tmp";
            const base = if (std.Io.Dir.path.isAbsolute(tmp)) std.mem.trimEnd(u8, tmp, "/") else "/tmp";
            var random: [4]u8 = undefined;
            io.random(&random);
            const dir = std.fmt.allocPrint(gpa, "{s}/yuke-{d}-{x}", .{ base, std.c.getpid(), std.mem.readInt(u32, &random, .little) }) catch unreachable;
            std.Io.Dir.createDirAbsolute(io, dir, .fromMode(0o700)) catch {
                gpa.free(dir);
                return error.HostFailure;
            };
            self.dir = dir;
        }
        self.count += 1;
        return std.fmt.allocPrint(gpa, "{s}/{s}-{d}.log", .{ self.dir.?, name, self.count }) catch unreachable;
    }

    /// Delete the directory and every log in it. Every task that wrote a log has ended before this call.
    pub fn deinit(self: *Logs, gpa: std.mem.Allocator, io: std.Io) void {
        const dir = self.dir orelse return;
        std.Io.Dir.cwd().deleteTree(io, dir) catch {};
        gpa.free(dir);
        self.* = .{};
    }
};

const testing = std.testing;

test "logs share one private directory that deinit removes" {
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try env.put("TMPDIR", "/tmp/");
    var logs: Logs = .{};
    const first = try logs.next(testing.allocator, testing.io, &env, "exec");
    defer testing.allocator.free(first);
    const second = try logs.next(testing.allocator, testing.io, &env, "job");
    defer testing.allocator.free(second);

    const dir = logs.dir.?;
    try testing.expect(std.mem.startsWith(u8, first, dir) and std.mem.endsWith(u8, first, "/exec-1.log"));
    try testing.expect(std.mem.startsWith(u8, second, dir) and std.mem.endsWith(u8, second, "/job-2.log"));
    const stat = try std.Io.Dir.cwd().statFile(testing.io, dir, .{});
    try testing.expectEqual(@as(std.posix.mode_t, 0o700), stat.permissions.toMode() & 0o777);

    const kept = try testing.allocator.dupe(u8, dir);
    defer testing.allocator.free(kept);
    logs.deinit(testing.allocator, testing.io);
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(testing.io, kept, .{}));
}
