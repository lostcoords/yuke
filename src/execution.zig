//! Resolve the effective environment and the command shell once, at process startup.
//! Every built-in child process, native path, and session prompt reads the answers this module installs.

const std = @import("std");
const builtin = @import("builtin");
const paths = @import("paths.zig");

/// The automatic candidates, in order. Bash comes first, because a command may need its syntax.
const bafallback_shell = "/bin/bash";
/// The final candidate, and the shell a caller names when it runs no command of its own.
pub const fallback_shell = "/bin/sh";

/// The cap for one user-database record. A record above this size names no home Yuke can use.
const max_passwd_bytes = 64 * 1024;

/// A startup policy failure. A missing home directory is not one; only a missing shell is.
pub const Error = error{
    ShellNotFound,
    UnsupportedPlatform,
} || std.mem.Allocator.Error;

/// The one command shell of this process. The path is absolute and never changes after startup.
pub const Shell = struct {
    path: []const u8,
};

/// The startup answers every owner borrows. The process outlives every borrow.
pub const Context = struct {
    env: *const std.process.Environ.Map,
    shell: Shell,
};

/// A context for a test. It names the caller's environment and the POSIX shell every platform has.
pub fn testContext(env: *const std.process.Environ.Map) Context {
    std.debug.assert(builtin.is_test);
    return .{ .env = env, .shell = .{ .path = fallback_shell } };
}

/// The platform lookups this module needs. A test replaces them, so no unit test reads this machine.
pub const Probe = struct {
    /// Answer the home directory of the effective user, or null when the platform names none.
    home: *const fn (std.Io, std.mem.Allocator) std.mem.Allocator.Error!?[]const u8,
    /// Answer true when the path names a regular file with an execute bit.
    executable: *const fn (std.Io, []const u8) bool,

    pub const native: Probe = .{ .home = nativeHome, .executable = nativeExecutable };
};

/// Normalize the home directory, then resolve the shell from the normalized environment.
/// `arena` owns the shell path, so the result lives as long as `std.process.Init`.
pub fn startup(arena: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, probe: Probe) Error!Context {
    try normalizeHome(arena, io, env, probe);
    const shell = try resolveShell(arena, io, env, probe);
    // The shell is final here, so every later owner runs the same one.
    std.debug.assert(std.fs.path.isAbsolute(shell.path));
    return .{ .env = env, .shell = shell };
}

/// Keep a valid inherited home directory, or recover one from the platform and install it.
/// A failed recovery is not a startup failure; a container with no passwd entry is usually correct.
fn normalizeHome(arena: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, probe: Probe) Error!void {
    // `paths.homeDir` already rejects an empty and a relative value, so a non-null answer is valid.
    if (paths.homeDir(env) != null) return;
    if (try recoverHome(arena, io, probe)) |home| {
        // The map copies the value, so it owns the installed home directory for the process lifetime.
        try env.put(paths.home_env, home);
        return;
    }
    std.log.warn("no home directory: a ~ path fails and a child process receives no {s}", .{paths.home_env});
}

/// Answer a home directory the platform names and Yuke can use, or null.
fn recoverHome(arena: std.mem.Allocator, io: std.Io, probe: Probe) std.mem.Allocator.Error!?[]const u8 {
    const recovered = (try probe.home(io, arena)) orelse return null;
    if (recovered.len == 0 or !std.fs.path.isAbsolute(recovered)) return null;
    if (std.mem.indexOfScalar(u8, recovered, 0) != null) return null;
    return recovered;
}

/// Answer the one shell: Bash where it exists, then `sh`.
fn resolveShell(arena: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, probe: Probe) Error!Shell {
    // Windows has no `<shell> -c` contract, so it needs its own design instead of a silent fallback.
    if (builtin.os.tag == .windows) return error.UnsupportedPlatform;
    if (probe.executable(io, bafallback_shell)) return .{ .path = bafallback_shell };
    if (try bashOnPath(arena, io, env, probe)) |path| return .{ .path = path };
    if (probe.executable(io, fallback_shell)) return .{ .path = fallback_shell };
    return error.ShellNotFound;
}

/// Search `PATH` for Bash. Only an absolute entry is inspected, and an empty entry is not absolute.
fn bashOnPath(arena: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, probe: Probe) Error!?[]const u8 {
    const list = env.get("PATH") orelse return null;
    var entries = std.mem.splitScalar(u8, list, std.fs.path.delimiter);
    while (entries.next()) |entry| {
        if (!std.fs.path.isAbsolute(entry)) continue;
        const candidate = try std.fs.path.join(arena, &.{ entry, "bash" });
        if (probe.executable(io, candidate)) return candidate;
        arena.free(candidate);
    }
    return null;
}

/// Read the home directory of the effective user from the platform user database.
/// Use the reentrant call, which needs no lock, no helper process, and no shell output.
fn nativeHome(_: std.Io, arena: std.mem.Allocator) std.mem.Allocator.Error!?[]const u8 {
    if (builtin.os.tag == .windows) return null;
    var size: usize = 2048;
    while (size <= max_passwd_bytes) : (size *= 2) {
        const buffer = try arena.alloc(u8, size);
        var record: std.c.passwd = undefined;
        var found: ?*std.c.passwd = null;
        const rc = std.c.getpwuid_r(std.c.geteuid(), &record, buffer.ptr, buffer.len, &found);
        // A long directory-service record needs a larger buffer, and POSIX names this case.
        if (rc == @intFromEnum(std.c.E.RANGE)) continue;
        if (rc != 0) return null;
        // A container that runs as a bare uid has no entry, and that container is usually correct.
        const entry = found orelse return null;
        const dir = entry.dir orelse return null;
        // The buffer belongs to this loop, so the caller gets its own copy.
        return try arena.dupe(u8, std.mem.span(dir));
    }
    return null;
}

/// Report whether the path names a regular file this process can run.
/// `access` is the question we mean; mode bits alone accept a noexec mount and an ACL that denies.
fn nativeExecutable(io: std.Io, path: []const u8) bool {
    const info = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    if (info.kind != .file) return false;
    std.Io.Dir.accessAbsolute(io, path, .{ .execute = true }) catch return false;
    return true;
}

const testing = std.testing;

/// The answers the test probe gives. A test sets them before it calls `startup`.
var fake_home: ?[]const u8 = null;
var fake_executables: []const []const u8 = &.{};

fn fakeHome(_: std.Io, arena: std.mem.Allocator) std.mem.Allocator.Error!?[]const u8 {
    return try arena.dupe(u8, fake_home orelse return null);
}

fn fakeExecutable(_: std.Io, path: []const u8) bool {
    for (fake_executables) |name| if (std.mem.eql(u8, name, path)) return true;
    return false;
}

const fake_probe: Probe = .{ .home = fakeHome, .executable = fakeExecutable };

/// Build an environment from key and value pairs. The caller frees it.
fn testEnv(pairs: []const [2][]const u8) !std.process.Environ.Map {
    var map: std.process.Environ.Map = .init(testing.allocator);
    errdefer map.deinit();
    for (pairs) |kv| try map.put(kv[0], kv[1]);
    return map;
}

test "an absolute home stays, and every invalid form recovers from the platform" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    fake_home = "/native/home";
    fake_executables = &.{fallback_shell};

    // An absolute value is kept; an absent, an empty, and a relative value each recover.
    const cases = [_][2][]const u8{
        .{ "/keep/me", "/keep/me" },
        .{ "", "/native/home" },
        .{ "relative/home", "/native/home" },
    };
    for (cases) |case| {
        var env = try testEnv(&.{.{ paths.home_env, case[0] }});
        defer env.deinit();
        _ = try startup(arena.allocator(), testing.io, &env, fake_probe);
        try testing.expectEqualStrings(case[1], paths.homeDir(&env).?);
    }
    var absent = try testEnv(&.{});
    defer absent.deinit();
    _ = try startup(arena.allocator(), testing.io, &absent, fake_probe);
    try testing.expectEqualStrings("/native/home", paths.homeDir(&absent).?);
}

test "an unusable platform home installs nothing and still starts" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    fake_executables = &.{fallback_shell};

    // A container with no passwd entry is usually correct, so none of these may stop the process.
    const cases = [_]?[]const u8{ "", "relative/home", "/has\x00nul", null };
    for (cases) |home| {
        var env = try testEnv(&.{});
        defer env.deinit();
        fake_home = home;
        const context = try startup(arena.allocator(), testing.io, &env, fake_probe);
        try testing.expectEqualStrings(fallback_shell, context.shell.path);
        // `paths.homeDir` rejects these itself, so the map must hold no value at all.
        try testing.expect(env.get(paths.home_env) == null);
    }
}

test "the native probe answers what the process can actually run" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(testing.io, &buf)];

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "plain", .data = "#!/bin/sh\n" });
    const plain = try std.fs.path.join(a, &.{ root, "plain" });

    // A readable file is not a runnable one, and the mode bits alone would say it is.
    try testing.expect(!Probe.native.executable(testing.io, plain));
    try tmp.dir.setFilePermissions(testing.io, "plain", .fromMode(0o755), .{});
    try testing.expect(Probe.native.executable(testing.io, plain));
    // A directory carries execute bits and is never a shell.
    try testing.expect(!Probe.native.executable(testing.io, root));
}

test "the shell resolver follows one order and every result is absolute" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    fake_home = "/native/home";
    const home: [2][]const u8 = .{ paths.home_env, "/home/u" };

    const Case = struct {
        pairs: []const [2][]const u8,
        present: []const []const u8,
        want: []const u8,
    };
    const cases = [_]Case{
        .{ .pairs = &.{home}, .present = &.{ bafallback_shell, fallback_shell }, .want = bafallback_shell },
        // A lost skip would join an empty entry to `bash` or a relative one to `rel/bin/bash`.
        .{ .pairs = &.{ home, .{ "PATH", ":rel/bin:/opt/bin" } }, .present = &.{ "bash", "rel/bin/bash", "/opt/bin/bash", fallback_shell }, .want = "/opt/bin/bash" },
        .{ .pairs = &.{ home, .{ "PATH", "/opt/bin" } }, .present = &.{fallback_shell}, .want = fallback_shell },
    };
    for (cases) |case| {
        var env = try testEnv(case.pairs);
        defer env.deinit();
        fake_executables = case.present;
        const context = try startup(arena.allocator(), testing.io, &env, fake_probe);
        try testing.expectEqualStrings(case.want, context.shell.path);
    }
}

test "a machine with no shell at all names its own failure" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    fake_home = "/native/home";
    const home: [2][]const u8 = .{ paths.home_env, "/home/u" };

    var env = try testEnv(&.{home});
    defer env.deinit();
    fake_executables = &.{};
    try testing.expectError(error.ShellNotFound, startup(arena.allocator(), testing.io, &env, fake_probe));
}
