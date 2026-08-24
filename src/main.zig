//! The yuke daemon entry point.

const std = @import("std");
const builtin = @import("builtin");
const zio = @import("zio");
const zqlite = @import("zqlite");
const http = @import("daemon/http.zig");
const database = @import("database/database.zig");
const paths = @import("paths/paths.zig");
const State = @import("daemon/State.zig");

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

    const conn = try zqlite.open(config.db_path, open_flags);
    var state = try State.init(
        init.gpa,
        io,
        try database.Database.open(conn),
        config,
        init.environ_map.get("HOME") orelse "/",
    );
    defer state.deinit();

    std.log.info("daemon store at {s}", .{config.db_path});
    try http.serve(&state);
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
