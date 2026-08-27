//! Run the built-in file-system primitives natively over `std.Io`. There is no path confinement (a
//! trusted local user); the container backend is the boundary. See docs/plan.md "Execution isolation".

const std = @import("std");
const t = @import("tool.zig");
const paths = @import("../paths/paths.zig");

const Map = std.process.Environ.Map;

/// Bound one file read so a huge file cannot exhaust memory.
const max_file_bytes = 16 * 1024 * 1024;

pub const LocalHost = struct {
    io: std.Io,
    root: []const u8, // The canonical workspace root, the base for a relative path.
    env: ?*const Map, // The environment expands an initial `~`.

    pub fn host(self: *LocalHost) t.ToolHost {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable: t.ToolHost.VTable = .{ .readFile = readFile };

    fn readFile(ctx: *anyopaque, scratch: std.mem.Allocator, path: []const u8, start: ?usize, end: ?usize) t.HostError![]const u8 {
        const self: *LocalHost = @ptrCast(@alignCast(ctx));
        const full = self.resolve(scratch, path) catch |err| return mapError(err);
        const text = std.Io.Dir.cwd().readFileAlloc(self.io, full, scratch, .limited(max_file_bytes)) catch |err| return mapError(err);
        // A replacement character corrupts a later exact edit, so refuse text the daemon cannot decode.
        if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
        return t.sliceLines(text, start, end);
    }

    /// Expand an initial `~` and resolve a relative path against the workspace root. An absolute path or a
    /// `..` escape is allowed (no confinement). The caller owns the result.
    fn resolve(self: *LocalHost, scratch: std.mem.Allocator, path: []const u8) FsError![]const u8 {
        const expanded = if (self.env) |e| try paths.expandHome(scratch, e, path) else path;
        if (std.fs.path.isAbsolute(expanded)) return std.fs.path.resolve(scratch, &.{expanded});
        return std.fs.path.resolve(scratch, &.{ self.root, expanded });
    }
};

const ExpandError = @typeInfo(@typeInfo(@TypeOf(paths.expandHome)).@"fn".return_type.?).error_union.error_set;

/// Every native error the local backend can raise. `mapError` covers this set, not `anyerror`.
const FsError = ExpandError || std.mem.Allocator.Error || std.Io.Dir.ReadFileAllocError;

/// Map a native file-system error to `HostError`. Map an unlisted error to `HostFailure`.
fn mapError(err: FsError) t.HostError {
    return switch (err) {
        error.FileNotFound, error.NotDir => error.NotFound,
        error.IsDir => error.NotAFile,
        error.AccessDenied, error.PermissionDenied, error.ReadOnlyFileSystem => error.AccessDenied,
        error.StreamTooLong, error.FileTooBig => error.TooLarge,
        error.Canceled => error.Canceled,
        error.OutOfMemory => error.OutOfMemory,
        else => error.HostFailure,
    };
}

const testing = std.testing;

test "LocalHost reads a whole file and a line range" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.txt", .data = "one\ntwo\nthree\n" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(testing.io, &root_buf)];

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var local: LocalHost = .{ .io = testing.io, .root = root, .env = null };
    const h = local.host();

    try testing.expectEqualStrings("one\ntwo\nthree\n", try h.readFile(a, "a.txt", null, null));
    try testing.expectEqualStrings("two\nthree\n", try h.readFile(a, "a.txt", 2, 3));
}

test "LocalHost expands a leading tilde against HOME" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.txt", .data = "hi\n" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(testing.io, &root_buf)];

    var env = Map.init(testing.allocator);
    defer env.deinit();
    try env.put("HOME", root);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var local: LocalHost = .{ .io = testing.io, .root = "/unused", .env = &env };
    try testing.expectEqualStrings("hi\n", try local.host().readFile(a, "~/a.txt", null, null));
}

test "LocalHost does not confine reads to the workspace" {
    var work = testing.tmpDir(.{});
    defer work.cleanup();
    var other = testing.tmpDir(.{});
    defer other.cleanup();
    try other.dir.writeFile(testing.io, .{ .sub_path = "outside.txt", .data = "secret\n" });

    var work_buf: [std.fs.max_path_bytes]u8 = undefined;
    const work_root = work_buf[0..try work.dir.realPath(testing.io, &work_buf)];
    var other_buf: [std.fs.max_path_bytes]u8 = undefined;
    const other_root = other_buf[0..try other.dir.realPath(testing.io, &other_buf)];

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var local: LocalHost = .{ .io = testing.io, .root = work_root, .env = null };
    const outside = try std.fs.path.join(a, &.{ other_root, "outside.txt" });
    // An absolute path outside the workspace reads freely (no confinement).
    try testing.expectEqualStrings("secret\n", try local.host().readFile(a, outside, null, null));
}
