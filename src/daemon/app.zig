//! The yuke daemon entry.

const std = @import("std");
const builtin = @import("builtin");
const zio = @import("zio");
const zqlite = @import("zqlite");
const wire = @import("wire");
const http = @import("http.zig");
const database = @import("../database/database.zig");
const paths = @import("../paths/paths.zig");
const cloud = @import("../cloud/cloud.zig");
const provider = @import("../provider/provider.zig");
const daemon_config = @import("config.zig");
const connection = @import("connection.zig");
const InstanceLock = @import("InstanceLock.zig");
const State = @import("State.zig");

// The timeout wakes a stalled provider read. Cancellation also interrupts the read.
const provider_idle_timeout = std.Io.Duration.fromMilliseconds(60_000);

// zio.debug_io breaks the WebSocket upgrade in zio v0.16.0. Keep it disabled.

// Use this port for the front door. A proxy terminates TLS before remote web clients connect.
const default_port = 7880;

const open_flags = zqlite.OpenFlags.Create | zqlite.OpenFlags.NoMutex | zqlite.OpenFlags.EXResCode;

pub fn run(init: std.process.Init) !void {
    // One executor owns daemon state. Tasks can still interleave at I/O boundaries.
    const rt = try zio.Runtime.init(init.gpa, .{ .executors = .exact(1) });
    defer rt.deinit();
    const io = rt.io();

    // Resolve the data directory. Use an in-memory store when the data directory has no path.
    const data_dir = try resolveDataDir(init.gpa, io, init.environ_map);
    defer if (data_dir) |path| init.gpa.free(path);

    // One daemon owns the data directory and the front door. Take the lock before the store opens.
    const lock = try lockInstance(init.gpa, io, data_dir);
    defer if (lock) |held| held.release(io);

    const owned_db_path = if (data_dir) |base| try dbPathZ(init.gpa, base) else null;
    defer if (owned_db_path) |path| init.gpa.free(path);
    const db_path: [:0]const u8 = owned_db_path orelse ":memory:";

    const config: State.Config = .{
        .listen = try std.Io.net.IpAddress.parseIp4("127.0.0.1", default_port),
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
    // The environment is always needed (a `~` in a workspace path), not only when providers load.
    state.env = init.environ_map;
    state.route_transport = http_transport.transportFor();
    try configureCloud(&state, init.gpa, io, data_dir, init.environ_map);

    // Load the user providers. An invalid file fails startup. An absent file keeps the placeholder.
    const providers_path = try configFilePath(init.gpa, init.environ_map, "providers.json");
    defer if (providers_path) |path| init.gpa.free(path);
    if (providers_path) |path| {
        var loaded = try provider.config.load(init.gpa, io, path);
        if (loaded.providers.len > 0) {
            state.providers = loaded;
            std.log.info("loaded {d} provider(s) from providers.json", .{loaded.providers.len});
        } else loaded.deinit();
    }

    // Load the daemon defaults. An invalid file fails startup. An absent file uses built-in defaults.
    // The daemon trusts the values. A client validates a model selector before it sends the request.
    const yuked_path = try configFilePath(init.gpa, init.environ_map, "yuked.json");
    defer if (yuked_path) |path| init.gpa.free(path);
    if (yuked_path) |path| {
        const loaded = try daemon_config.load(init.gpa, io, path);
        state.defaults = loaded.defaults;
        state.config_owner = loaded;
    }

    _ = try state.rebuildCatalog();

    // Fetch the cloud documents off the request path. The daemon must answer before the network does.
    var maintenance: std.Io.Group = .init;
    defer maintenance.cancel(io);
    maintenance.concurrent(io, cloudTask, .{&state}) catch |err| {
        std.log.warn("cloud refresh not started: {t}", .{err});
    };

    std.log.info("daemon store at {s}", .{config.db_path});
    try http.serve(&state);
}

/// Join a file name under the config directory. `configDir` already ends with the app directory.
/// Return null when no config directory exists. The caller owns the result.
fn configFilePath(gpa: std.mem.Allocator, env: *const std.process.Environ.Map, name: []const u8) !?[]u8 {
    const base = try paths.configDir(gpa, env) orelse return null;
    defer gpa.free(base);
    return try std.fs.path.join(gpa, &.{ base, name });
}

/// Resolve the data directory and create it.
/// Return null when no data directory path exists. The caller owns the returned path.
fn resolveDataDir(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) !?[]u8 {
    const base = try paths.dataDir(gpa, env) orelse return null;
    errdefer gpa.free(base);
    try ensureDataDir(io, base);
    return base;
}

/// Return the SQLite path under `base`. The caller owns the result.
fn dbPathZ(gpa: std.mem.Allocator, base: []const u8) ![:0]u8 {
    const file = try paths.dbPathIn(gpa, base);
    defer gpa.free(file);
    return try gpa.dupeZ(u8, file);
}

/// Take the single-instance lock. A daemon without a data directory takes no lock.
/// Report the conflict, because a bare error name does not tell the user what to do.
fn lockInstance(gpa: std.mem.Allocator, io: std.Io, data_dir: ?[]const u8) !?InstanceLock {
    const base = data_dir orelse {
        std.log.warn("no data directory: the daemon takes no single-instance lock", .{});
        return null;
    };
    const held = InstanceLock.acquire(gpa, io, base) catch |err| {
        if (err == InstanceLock.Error.DaemonAlreadyRunning)
            std.log.err("another yuke daemon already runs; it holds the lock in {s}", .{base});
        return err;
    };
    if (held == null) std.log.warn("{s} gives no lock: a second daemon is not detected", .{base});
    return held;
}

/// Load the device bearer without retaining the device private key.
fn configureCloud(
    state: *State,
    gpa: std.mem.Allocator,
    io: std.Io,
    data_dir: ?[]const u8,
    env: *const std.process.Environ.Map,
) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    const device: ?cloud.identity.Device = blk: {
        const data_path = data_dir orelse break :blk null;
        var dir = std.Io.Dir.cwd().openDir(io, data_path, .{}) catch |err| {
            std.log.warn("cannot open the cloud identity directory: {t}", .{err});
            break :blk null;
        };
        defer dir.close(io);
        break :blk cloud.identity.readMeta(arena.allocator(), io, dir, cloud.identity.Device, .device) catch |err| {
            std.log.warn("cannot read the device credential: {t}", .{err});
            break :blk null;
        };
    };
    defer if (device) |stored| {
        std.crypto.secureZero(u8, @constCast(stored.credential));
        std.crypto.secureZero(u8, @constCast(stored.identity_key));
    };

    try state.configureCloud(
        cloud.endpoint.baseUrl(env, null),
        if (device) |stored| stored.credential else null,
    );
}

/// Refresh the public catalog and the account bundle once at startup.
fn cloudTask(state: *State) void {
    _ = state.refreshCloud() catch |err| {
        std.log.warn("cloud refresh failed: {t}", .{err});
        return;
    };
    std.log.info("cloud documents are current", .{});
}

/// Create the data directory. Give a new POSIX directory mode 0700 and keep current permissions.
/// Windows uses its default permissions.
fn ensureDataDir(io: std.Io, dir: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    if (builtin.os.tag == .windows) return cwd.createDirPath(io, dir);
    const perms = std.Io.File.Permissions.fromMode(0o700);
    if (try cwd.createDirPathStatus(io, dir, perms) == .created)
        try cwd.setFilePermissions(io, dir, perms, .{});
}

test "a catalog replacement announces the merged revision" {
    const testing = std.testing;
    const rt = try zio.Runtime.init(testing.allocator, .{ .executors = .exact(1) });
    defer rt.deinit();
    const listen = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var state = try State.init(testing.allocator, rt.io(), try database.Database.openTest(), .{ .listen = listen }, "/home/test");
    defer state.deinit();

    var conn: connection.Connection = undefined;
    conn.init(testing.allocator, rt.io());
    defer conn.deinit();
    try state.registry.register(&conn);
    defer state.registry.unregister(&conn);

    state.catalog.revision = .bytes(@splat(0xab));
    state.announceCatalogChanged();

    const item = (try conn.tryReceive()).?;
    defer testing.allocator.free(item.bytes);
    try testing.expect(std.mem.indexOf(u8, item.bytes, "\"method\":\"catalog.changed\"") != null);
    try testing.expect(std.mem.indexOf(u8, item.bytes, "ab" ** 64) != null);
}
