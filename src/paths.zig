//! Resolve the XDG paths for the engine, the TUI, and their files; return owned paths that the caller frees, and treat an empty environment value as unset under XDG rules.

const std = @import("std");
const builtin = @import("builtin");

const Map = std.process.Environ.Map;

/// This is the default directory leaf under each platform root. `YUKE_APPNAME` can replace it.
pub const app_dir = "yuke";

/// This environment variable sets the process-wide profile name. It remaps the config and data paths.
pub const app_name_env = "YUKE_APPNAME";

/// This is the SQLite event-log file in the data directory.
pub const db_file = "yuke.db";
/// The credential refresh lock lives beside the store, not beside the config file it guards.
pub const providers_lock_file = "providers.lock";

/// This variable names the home directory: `USERPROFILE` on Windows and `HOME` elsewhere.
pub const home_env = if (builtin.os.tag == .windows) "USERPROFILE" else "HOME";

/// Return the non-empty value for `key`, or null.
fn envNonEmpty(env: *const Map, key: []const u8) ?[]const u8 {
    const value = env.get(key) orelse return null;
    return if (value.len == 0) null else value;
}

/// Return the non-empty absolute value for `key`, or null; ignore relative values because the XDG specification requires an absolute base directory.
fn envBasePath(env: *const Map, key: []const u8) ?[]const u8 {
    const value = envNonEmpty(env, key) orelse return null;
    return if (std.Io.Dir.path.isAbsolute(value)) value else null;
}

/// Return the user's home directory, or null when its variable is empty or relative, because a home directory is a base path.
pub fn homeDir(env: *const Map) ?[]const u8 {
    return envBasePath(env, home_env);
}

/// Return true for a directory name with no separator that is not `.` or `..`.
pub fn appNameValid(name: []const u8) bool {
    return name.len != 0 and
        !std.mem.eql(u8, name, ".") and
        !std.mem.eql(u8, name, "..") and
        std.mem.findAny(u8, name, "/\\\x00") == null;
}

pub const Error = error{InvalidAppName};

/// Return the directory leaf under platform roots; use `app_dir` when `YUKE_APPNAME` is unset, reject an invalid `YUKE_APPNAME`, and return a result that borrows `env`.
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

    return try std.Io.Dir.path.join(alloc, parts[0 .. 2 + mid.len]);
}

/// Return the shared configuration directory from `APPDATA` on Windows, `XDG_CONFIG_HOME` elsewhere, or `~/.config` under home; return null without a base, return an error for an invalid profile, and let the caller free the result.
pub fn configDir(alloc: std.mem.Allocator, env: *const Map) !?[]u8 {
    return platformDir(alloc, env, "APPDATA", "XDG_CONFIG_HOME", &.{".config"});
}

/// Return the data directory from `LOCALAPPDATA` on Windows, `XDG_DATA_HOME` elsewhere, or `~/.local/share` under home; return null without a base, return an error for an invalid profile, and let the caller free the result.
pub fn dataDir(alloc: std.mem.Allocator, env: *const Map) !?[]u8 {
    return platformDir(alloc, env, "LOCALAPPDATA", "XDG_DATA_HOME", &.{ ".local", "share" });
}

fn platformDir(alloc: std.mem.Allocator, env: *const Map, comptime windows_key: []const u8, comptime xdg_key: []const u8, comptime home_mid: []const []const u8) !?[]u8 {
    if (builtin.os.tag == .windows) {
        const base = envBasePath(env, windows_key) orelse return null;
        return try joinUnder(alloc, env, base, &.{});
    }
    if (envBasePath(env, xdg_key)) |xdg| return try joinUnder(alloc, env, xdg, &.{});
    const home = homeDir(env) orelse return null;
    return try joinUnder(alloc, env, home, home_mid);
}

/// Return the blob directory under `base`. The caller frees the result.
pub fn blobDirIn(alloc: std.mem.Allocator, base: []const u8) ![]u8 {
    std.debug.assert(base.len != 0);
    return std.Io.Dir.path.join(alloc, &.{ base, "blobs" });
}

pub const ExpandError = error{HomeUnavailable} || std.mem.Allocator.Error;

/// Expand a bare `~` or a `~/...` path against an absolute home directory, or return null when `path` starts with no such tilde.
fn homeExpansion(alloc: std.mem.Allocator, env: *const Map, path: []const u8) ExpandError!?[]u8 {
    const sep = std.Io.Dir.path.sep;
    if (path.len == 0 or path[0] != '~') return null;
    if (path.len > 1 and path[1] != sep) return null; // `~alice` stays literal.

    // A tilde that survives expansion would anchor under the workspace root and name the wrong file.
    const home = homeDir(env) orelse return error.HomeUnavailable;
    const rest = std.mem.trimStart(u8, path[1..], &.{sep});
    if (rest.len == 0) return try alloc.dupe(u8, home);
    return try std.Io.Dir.path.join(alloc, &.{ home, rest });
}

/// Expand a leading `~` or copy the path into caller-owned memory.
pub fn expandHome(alloc: std.mem.Allocator, env: *const Map, path: []const u8) ExpandError![]u8 {
    return (try homeExpansion(alloc, env, path)) orelse try alloc.dupe(u8, path);
}

/// Anchor a tool path: expand an initial `~`, then resolve it against `root`. There is no confinement.
pub fn anchorAt(alloc: std.mem.Allocator, env: *const Map, root: []const u8, path: []const u8) ExpandError![]const u8 {
    const owned = try homeExpansion(alloc, env, path);
    defer if (owned) |o| alloc.free(o);
    const expanded = owned orelse path;
    if (std.Io.Dir.path.isAbsolute(expanded)) return std.Io.Dir.path.resolve(alloc, &.{expanded});
    return std.Io.Dir.path.resolve(alloc, &.{ root, expanded });
}

pub const WorkspaceError = error{RootNotAbsolute};

/// Normalize a workspace root by expanding a leading `~` and resolving `.`/`..`; reject a relative or empty root with `RootNotAbsolute`, return a lexical result, and let the caller free it.
pub fn canonicalizeWorkspace(alloc: std.mem.Allocator, env: *const Map, path: []const u8) (WorkspaceError || ExpandError)![]u8 {
    const owned = try homeExpansion(alloc, env, path);
    defer if (owned) |o| alloc.free(o);
    const expanded = owned orelse path;
    const resolved = try std.Io.Dir.path.resolve(alloc, &.{expanded});
    errdefer alloc.free(resolved);
    if (!std.Io.Dir.path.isAbsolute(resolved)) return WorkspaceError.RootNotAbsolute;
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
    var homeless = try testEnv(&.{});
    defer homeless.deinit();

    // A relative root and an empty root return `RootNotAbsolute`; an unexpandable `~` returns `HomeUnavailable`.
    try testing.expectError(WorkspaceError.RootNotAbsolute, canonicalizeWorkspace(testing.allocator, &env, "relative/dir"));
    try testing.expectError(WorkspaceError.RootNotAbsolute, canonicalizeWorkspace(testing.allocator, &env, ""));
    try testing.expectError(error.HomeUnavailable, canonicalizeWorkspace(testing.allocator, &homeless, "~/proj"));
}

test "a tilde without an absolute home fails instead of resolving somewhere else" {
    const a = testing.allocator;
    // An absent, an empty, and a relative value all give the environment no home directory.
    const homeless = [_][]const u8{ "", "relative/home" };
    var absent = try testEnv(&.{});
    defer absent.deinit();
    try testing.expectError(error.HomeUnavailable, expandHome(a, &absent, "~"));
    try testing.expectError(error.HomeUnavailable, expandHome(a, &absent, "~/x"));
    for (homeless) |value| {
        var env = try testEnv(&.{.{ home_env, value }});
        defer env.deinit();
        try testing.expectError(error.HomeUnavailable, expandHome(a, &env, "~"));
        try testing.expectError(error.HomeUnavailable, expandHome(a, &env, "~/x"));
        try testing.expectError(error.HomeUnavailable, anchorAt(a, &env, "/work", "~/x"));
    }

    // A path that needs no home directory still resolves, and `~alice` is not home expansion here.
    for ([_][]const u8{ "rel/x", "/abs/x", "~alice/x" }) |path| {
        const got = try expandHome(a, &absent, path);
        defer a.free(got);
        try testing.expectEqualStrings(path, got);
    }
}

test "anchorAt never turns a tilde into a path under the workspace" {
    const a = testing.allocator;
    var env = try testEnv(&.{.{ home_env, "/home/u" }});
    defer env.deinit();

    const cases = [_][2][]const u8{
        .{ "~", "/home/u" },
        .{ "~/x", "/home/u/x" },
        .{ "rel/x", "/work/rel/x" },
        .{ "/abs/x", "/abs/x" },
    };
    for (cases) |case| {
        const got = try anchorAt(a, &env, "/work", case[0]);
        defer a.free(got);
        try testing.expectEqualStrings(case[1], got);
        try testing.expect(std.mem.indexOfScalar(u8, got, '~') == null);
    }
}
