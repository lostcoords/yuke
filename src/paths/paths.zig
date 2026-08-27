//! Resolve the XDG paths for the daemon and the TUI, and the files under them.
//! Return owned paths. The caller frees them. Treat an empty environment value as unset under XDG rules.

const std = @import("std");
const builtin = @import("builtin");

const Map = std.process.Environ.Map;

/// This is the default directory leaf under each platform root. `YUKE_APPNAME` can replace it.
pub const app_dir = "yuke";

/// This environment variable sets the process-wide profile name. It remaps the config and data paths.
pub const app_name_env = "YUKE_APPNAME";

/// This is the SQLite event-log file in the data directory.
pub const db_file = "yuked.db";

/// This is the content-addressed blob directory under the data directory.
pub const blob_subdir = "blobs";

/// This variable names the home directory: `USERPROFILE` on Windows and `HOME` elsewhere.
const home_env = if (builtin.os.tag == .windows) "USERPROFILE" else "HOME";

/// Return the non-empty value for `key`, or null.
fn envNonEmpty(env: *const Map, key: []const u8) ?[]const u8 {
    const value = env.get(key) orelse return null;
    return if (value.len == 0) null else value;
}

/// Return the non-empty absolute value for `key`, or null.
/// Ignore relative values because the XDG specification requires an absolute base directory.
fn envBasePath(env: *const Map, key: []const u8) ?[]const u8 {
    const value = envNonEmpty(env, key) orelse return null;
    return if (std.fs.path.isAbsolute(value)) value else null;
}

/// Return the user's home directory, or null when its environment variable has no value.
/// The result borrows `env`.
pub fn homeDir(env: *const Map) ?[]const u8 {
    return envNonEmpty(env, home_env);
}

/// Return true for a directory name with no separator that is not `.` or `..`.
pub fn appNameValid(name: []const u8) bool {
    return name.len != 0 and
        !std.mem.eql(u8, name, ".") and
        !std.mem.eql(u8, name, "..") and
        std.mem.findAny(u8, name, "/\\\x00") == null;
}

pub const Error = error{InvalidAppName};

/// Return the directory leaf under the platform roots. Use `app_dir` when `YUKE_APPNAME` is unset.
/// An invalid `YUKE_APPNAME` is an error. The result borrows `env`.
pub fn appName(env: *const Map) Error![]const u8 {
    const value = envNonEmpty(env, app_name_env) orelse return app_dir;
    if (!appNameValid(value)) return error.InvalidAppName;
    return value;
}

/// Join `base`, the middle segments, and the profile leaf.
fn joinUnder(alloc: std.mem.Allocator, env: *const Map, base: []const u8, mid: []const []const u8) ![]u8 {
    std.debug.assert(mid.len <= 2);
    const leaf = try appName(env);

    var parts: [4][]const u8 = undefined;
    parts[0] = base;
    for (mid, 0..) |segment, i| parts[1 + i] = segment;
    parts[1 + mid.len] = leaf;

    return try std.fs.path.join(alloc, parts[0 .. 2 + mid.len]);
}

/// Return the shared configuration directory. Use `APPDATA` on Windows, `XDG_CONFIG_HOME` elsewhere, or `~/.config` under home.
/// Return null when no base exists. Return an error for an invalid profile. The caller frees the result.
pub fn configDir(alloc: std.mem.Allocator, env: *const Map) !?[]u8 {
    if (builtin.os.tag == .windows) {
        const base = envBasePath(env, "APPDATA") orelse return null;
        return try joinUnder(alloc, env, base, &.{});
    }
    if (envBasePath(env, "XDG_CONFIG_HOME")) |xdg| return try joinUnder(alloc, env, xdg, &.{});
    const home = homeDir(env) orelse return null;
    return try joinUnder(alloc, env, home, &.{".config"});
}

/// Return the data directory. Use `LOCALAPPDATA` on Windows, `XDG_DATA_HOME` elsewhere, or `~/.local/share` under home.
/// Return null when no base exists. Return an error for an invalid profile. The caller frees the result.
pub fn dataDir(alloc: std.mem.Allocator, env: *const Map) !?[]u8 {
    if (builtin.os.tag == .windows) {
        const base = envBasePath(env, "LOCALAPPDATA") orelse return null;
        return try joinUnder(alloc, env, base, &.{});
    }
    if (envBasePath(env, "XDG_DATA_HOME")) |xdg| return try joinUnder(alloc, env, xdg, &.{});
    const home = homeDir(env) orelse return null;
    return try joinUnder(alloc, env, home, &.{ ".local", "share" });
}

/// Return the event-log database path under `base`. The caller frees the result.
pub fn dbPathIn(alloc: std.mem.Allocator, base: []const u8) ![]u8 {
    std.debug.assert(base.len != 0);
    return std.fs.path.join(alloc, &.{ base, db_file });
}

/// Return the blob store directory under `base`. The caller frees the result.
pub fn blobDirIn(alloc: std.mem.Allocator, base: []const u8) ![]u8 {
    std.debug.assert(base.len != 0);
    return std.fs.path.join(alloc, &.{ base, blob_subdir });
}

/// Expand an initial `~` against the home directory.
/// Return `path` unchanged when the home directory or the initial `~` is absent. The caller frees the result.
pub fn expandHome(alloc: std.mem.Allocator, env: *const Map, path: []const u8) ![]u8 {
    const sep = std.fs.path.sep;
    if (path.len == 0 or path[0] != '~') return alloc.dupe(u8, path);
    if (path.len > 1 and path[1] != sep) return alloc.dupe(u8, path);

    const home = homeDir(env) orelse return alloc.dupe(u8, path);
    const rest = std.mem.trimStart(u8, path[1..], &.{sep});
    if (rest.len == 0) return alloc.dupe(u8, home);
    return std.fs.path.join(alloc, &.{ home, rest });
}

pub const WorkspaceError = error{RootNotAbsolute};

/// Normalize a workspace root: expand a leading `~`, then resolve `.`/`..`.
/// Reject a relative or empty root with `RootNotAbsolute`. The result is lexical. The caller frees it.
pub fn canonicalizeWorkspace(alloc: std.mem.Allocator, env: ?*const Map, path: []const u8) (WorkspaceError || std.mem.Allocator.Error)![]u8 {
    const expanded = if (env) |e| try expandHome(alloc, e, path) else try alloc.dupe(u8, path);
    defer alloc.free(expanded);
    const resolved = try std.fs.path.resolve(alloc, &.{expanded});
    errdefer alloc.free(resolved);
    if (!std.fs.path.isAbsolute(resolved)) return WorkspaceError.RootNotAbsolute;
    return resolved;
}

const testing = std.testing;

/// Build an environment map from key/value pairs for the resolver tests.
fn testEnv(pairs: []const [2][]const u8) !Map {
    var map = Map.init(testing.allocator);
    errdefer map.deinit();
    for (pairs) |kv| try map.put(kv[0], kv[1]);
    return map;
}

test appNameValid {
    try testing.expect(appNameValid("yuke"));
    try testing.expect(!appNameValid(""));
    try testing.expect(!appNameValid("."));
    try testing.expect(!appNameValid(".."));
    try testing.expect(!appNameValid("a/b"));
    try testing.expect(!appNameValid("a\\b"));
}

test "dataDir prefers XDG_DATA_HOME" {
    var env = try testEnv(&.{ .{ "HOME", "/home/u" }, .{ "XDG_DATA_HOME", "/xdg/data" } });
    defer env.deinit();
    const got = (try dataDir(testing.allocator, &env)).?;
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("/xdg/data/yuke", got);
}

test "dataDir falls back to the home default" {
    var env = try testEnv(&.{.{ "HOME", "/home/u" }});
    defer env.deinit();
    const got = (try dataDir(testing.allocator, &env)).?;
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("/home/u/.local/share/yuke", got);
}

test "an empty XDG value means unset" {
    var env = try testEnv(&.{ .{ "HOME", "/home/u" }, .{ "XDG_DATA_HOME", "" } });
    defer env.deinit();
    const got = (try dataDir(testing.allocator, &env)).?;
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("/home/u/.local/share/yuke", got);
}

test "a relative XDG value is ignored, per the spec" {
    var env = try testEnv(&.{ .{ "HOME", "/home/u" }, .{ "XDG_DATA_HOME", "relative/dir" } });
    defer env.deinit();
    const got = (try dataDir(testing.allocator, &env)).?;
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("/home/u/.local/share/yuke", got);
}

test "no home resolves to null" {
    var env = try testEnv(&.{});
    defer env.deinit();
    try testing.expect((try dataDir(testing.allocator, &env)) == null);
}

test "YUKE_APPNAME remaps the leaf" {
    var env = try testEnv(&.{ .{ "HOME", "/home/u" }, .{ "YUKE_APPNAME", "yuke-dev" } });
    defer env.deinit();
    const got = (try dataDir(testing.allocator, &env)).?;
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("/home/u/.local/share/yuke-dev", got);
}

test "an invalid YUKE_APPNAME is an error, not a silent fallback" {
    var env = try testEnv(&.{ .{ "HOME", "/home/u" }, .{ "YUKE_APPNAME", "a/b" } });
    defer env.deinit();
    try testing.expectError(error.InvalidAppName, dataDir(testing.allocator, &env));
}

test "configDir falls back to dot-config" {
    var env = try testEnv(&.{.{ "HOME", "/home/u" }});
    defer env.deinit();
    const got = (try configDir(testing.allocator, &env)).?;
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("/home/u/.config/yuke", got);
}

test "dbPathIn and blobDirIn append the file and subdirectory" {
    const db = try dbPathIn(testing.allocator, "/data/yuke");
    defer testing.allocator.free(db);
    try testing.expectEqualStrings("/data/yuke/yuked.db", db);

    const blobs = try blobDirIn(testing.allocator, "/data/yuke");
    defer testing.allocator.free(blobs);
    try testing.expectEqualStrings("/data/yuke/blobs", blobs);
}

test "expandHome substitutes a leading tilde" {
    var env = try testEnv(&.{.{ "HOME", "/home/u" }});
    defer env.deinit();

    const a = try expandHome(testing.allocator, &env, "~/x");
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("/home/u/x", a);

    const b = try expandHome(testing.allocator, &env, "/abs");
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("/abs", b);

    const c = try expandHome(testing.allocator, &env, "~");
    defer testing.allocator.free(c);
    try testing.expectEqualStrings("/home/u", c);
}

test "canonicalizeWorkspace folds equivalent forms to one root" {
    var env = try testEnv(&.{.{ "HOME", "/home/u" }});
    defer env.deinit();

    // Every form resolves to the same root.
    const forms = [_][]const u8{ "/home/u/proj", "/home/u/proj/", "/home/u/proj/.", "/home/u/x/../proj", "~/proj" };
    for (forms) |form| {
        const got = try canonicalizeWorkspace(testing.allocator, &env, form);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings("/home/u/proj", got);
    }
}

test "canonicalizeWorkspace rejects a relative or empty root" {
    var env = try testEnv(&.{.{ "HOME", "/home/u" }});
    defer env.deinit();

    // A relative root, an empty root, and an unexpandable `~` are not absolute.
    try testing.expectError(WorkspaceError.RootNotAbsolute, canonicalizeWorkspace(testing.allocator, &env, "relative/dir"));
    try testing.expectError(WorkspaceError.RootNotAbsolute, canonicalizeWorkspace(testing.allocator, &env, ""));
    try testing.expectError(WorkspaceError.RootNotAbsolute, canonicalizeWorkspace(testing.allocator, null, "~/proj"));
}
