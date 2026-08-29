//! Resolve the control-plane base URL. The daemon and `yuke login` must agree on it.

const std = @import("std");

/// The control plane serves its API only under the `platform` subdomain.
pub const default_base = "https://platform.yuke.sh";

/// This environment variable replaces the base URL. A local Rails server uses it.
pub const base_env = "YUKE_CLOUD_URL";

/// Return the base URL with no final slash. The `override` value wins, then the environment.
/// The result borrows its input.
pub fn baseUrl(env: ?*const std.process.Environ.Map, override: ?[]const u8) []const u8 {
    const raw = override orelse (if (env) |e| e.get(base_env) else null) orelse default_base;
    const trimmed = std.mem.trimEnd(u8, raw, "/");
    return if (trimmed.len != 0) trimmed else default_base;
}

const testing = std.testing;

test "baseUrl prefers the override, then the environment, then the default" {
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();

    try testing.expectEqualStrings(default_base, baseUrl(&env, null));
    try testing.expectEqualStrings("https://a.example", baseUrl(&env, "https://a.example/"));

    try env.put(base_env, "http://platform.lvh.me:3000/");
    try testing.expectEqualStrings("http://platform.lvh.me:3000", baseUrl(&env, null));
    try testing.expectEqualStrings("https://b.example", baseUrl(&env, "https://b.example"));

    // An empty value is not a base URL.
    try env.put(base_env, "");
    try testing.expectEqualStrings(default_base, baseUrl(&env, null));
}
