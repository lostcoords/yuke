//! The yuke daemon entry point.

const std = @import("std");
const builtin = @import("builtin");
const zio = @import("zio");
const zqlite = @import("zqlite");
const http = @import("daemon/http.zig");
const database = @import("database/database.zig");
const paths = @import("paths/paths.zig");
const provider = @import("provider/provider.zig");
const State = @import("daemon/State.zig");

// The timeout wakes a stalled provider read. Cancellation also interrupts the read.
const provider_idle_timeout = zio.Timeout.fromMilliseconds(60_000);

// zio.debug_io breaks the WebSocket upgrade in zio v0.16.0. Keep it disabled.

// Default front-door port. A proxy terminates TLS before remote web clients connect.
const default_port = 7880;

const open_flags = zqlite.OpenFlags.Create | zqlite.OpenFlags.NoMutex | zqlite.OpenFlags.EXResCode;

pub fn main(init: std.process.Init) !void {
    // One executor owns all daemon state. The daemon needs no locks.
    const rt = try zio.Runtime.init(init.gpa, .{ .executors = .exact(1) });
    defer rt.deinit();
    const io = rt.io();

    // Resolve the data directory. Use an in-memory store when no data directory exists.
    const owned_db_path = try resolveDbPath(init.gpa, io, init.environ_map);
    defer if (owned_db_path) |path| init.gpa.free(path);
    const db_path: [:0]const u8 = owned_db_path orelse ":memory:";

    const config: State.Config = .{
        .listen = try zio.net.IpAddress.parseIp4("127.0.0.1", default_port),
        .db_path = db_path,
    };

    // The HTTP client outlives State. State.deinit joins every run before the defer calls HttpTransport.deinit.
    var http_transport = provider.http_transport.HttpTransport.init(init.gpa, io, provider_idle_timeout);
    defer http_transport.deinit();

    const conn = try zqlite.open(config.db_path, open_flags);
    var state = try State.init(
        init.gpa,
        io,
        try database.Database.open(conn),
        config,
        paths.homeDir(init.environ_map) orelse "/",
    );
    defer state.deinit();

    // Load the user providers. An invalid file fails startup. A missing file keeps the placeholder.
    const providers_path = try resolveProvidersPath(init.gpa, init.environ_map);
    defer if (providers_path) |path| init.gpa.free(path);
    if (providers_path) |path| {
        var loaded = try provider.config.load(init.gpa, io, path);
        if (loaded.providers.len > 0) {
            state.providers = loaded;
            state.env = init.environ_map;
            state.transport = http_transport.transportFor();
            std.log.info("loaded {d} provider(s) from providers.json", .{loaded.providers.len});
        } else loaded.deinit();
    }

    std.log.info("daemon store at {s}", .{config.db_path});
    try http.serve(&state);
}

/// Return the `providers.json` path under the config directory. The caller owns it.
fn resolveProvidersPath(gpa: std.mem.Allocator, env: *const std.process.Environ.Map) !?[]u8 {
    const base = try paths.configDir(gpa, env) orelse return null;
    defer gpa.free(base);
    return try std.fs.path.join(gpa, &.{ base, "yuke", "providers.json" });
}

/// Resolve the SQLite path inside the data directory.
/// Return null when no data directory resolves. The caller owns the returned path.
fn resolveDbPath(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) !?[:0]u8 {
    const base = try paths.dataDir(gpa, env) orelse return null;
    defer gpa.free(base);
    try ensureDataDir(io, base);
    const file = try paths.dbPathIn(gpa, base);
    defer gpa.free(file);
    return try gpa.dupeZ(u8, file);
}

/// Create the data directory. Give a new POSIX directory mode 0700 and keep existing permissions.
/// Windows uses its default permissions.
fn ensureDataDir(io: std.Io, dir: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    if (builtin.os.tag == .windows) return cwd.createDirPath(io, dir);
    const perms = std.Io.File.Permissions.fromMode(0o700);
    if (try cwd.createDirPathStatus(io, dir, perms) == .created)
        try cwd.setFilePermissions(io, dir, perms, .{});
}
