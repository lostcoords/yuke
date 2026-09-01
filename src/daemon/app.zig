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
const scheduler_mod = @import("scheduler.zig");
const connection = @import("connection.zig");
const run_task = @import("run_task.zig");
const shutdown = @import("shutdown.zig");
const InstanceLock = @import("InstanceLock.zig");
const State = @import("State.zig");

// The timeout wakes a stalled provider read. Cancellation also interrupts the read.
const provider_idle_timeout = std.Io.Duration.fromMilliseconds(60_000);

// Use this port for the front door. A proxy terminates TLS before remote web clients connect.
const default_port = 9853;

// The device credential and its key fit this buffer. A larger file fails the read.
const secret_buffer_bytes = 16 * 1024;

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
    };

    // The HTTP client outlives State. State.deinit joins every run before the defer calls HttpTransport.deinit.
    var http_transport = provider.http_transport.HttpTransport.init(init.gpa, io, provider_idle_timeout);
    defer http_transport.deinit();

    const conn = try zqlite.open(db_path, open_flags);
    // The fixed buffer bounds the read, and State.init copies the credential before the buffer ends.
    var state = state: {
        var secrets: [secret_buffer_bytes]u8 = undefined;
        var fixed: std.heap.FixedBufferAllocator = .init(&secrets);
        const device = readDevice(fixed.allocator(), io, data_dir);
        break :state try State.init(.{
            .gpa = init.gpa,
            .io = io,
            .db = try database.Database.open(conn),
            .config = config,
            .home = paths.homeDir(init.environ_map) orelse "/",
            .env = init.environ_map,
            .route_transport = http_transport.transportFor(),
            .cloud_base_url = cloud.endpoint.baseUrl(init.environ_map, null),
            .cloud_credential = if (device) |stored| stored.credential else null,
            .device_id = if (device) |stored| stored.device_id else null,
        });
    };
    defer state.deinit();

    // State owns this path, because an invalid file fails startup and `auth.set_api_key` rewrites it.
    state.providers_path = try configFilePath(init.gpa, init.environ_map, "providers.json");
    if (state.providers_path) |path| {
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
        // The origins borrow the `Loaded` arena, which `state.config_owner` then owns.
        state.config.allowed_origins = loaded.allowed_origins;
        state.config_owner = loaded;
    }

    _ = try state.rebuildCatalog();

    // Fetch the cloud documents off the request path. The daemon must answer before the network does.
    var scheduler: scheduler_mod.Scheduler = .init(&state);
    state.scheduler = &scheduler;
    var maintenance: std.Io.Group = .init;
    // The cancel joins the task, and the pointer goes with it, so no later caller can reach it.
    defer {
        maintenance.cancel(io);
        state.scheduler = null;
    }
    maintenance.concurrent(io, scheduler_mod.Scheduler.run, .{&scheduler}) catch |err| {
        std.log.warn("the scheduler did not start: {t}", .{err});
    };

    // Restart the durable work before the front door opens, so no client sees a half-resumed daemon.
    try run_task.resumeSessions(&state);

    // Reuse the address, because the instance lock, not the bind, keeps one daemon on the port.
    var listener = try config.listen.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    std.log.info("daemon store at {s}", .{db_path});
    std.log.info("front door on http://{f}", .{listener.socket.address});

    var stop: shutdown.Watcher = try .init();

    // The cancel stops the accept and joins every live connection before State closes.
    var front_door: std.Io.Group = .init;
    defer front_door.cancel(io);
    // This defer is declared last, so it runs first and restores the signal disposition early.
    defer stop.deinit();
    try front_door.concurrent(io, http.serve, .{ &state, &listener, &stop });

    try stop.wait();
}

/// Join a file name under the config directory, or null when none exists. The caller owns it.
fn configFilePath(gpa: std.mem.Allocator, env: *const std.process.Environ.Map, name: []const u8) !?[]u8 {
    const base = try paths.configDir(gpa, env) orelse return null;
    defer gpa.free(base);
    return try std.fs.path.join(gpa, &.{ base, name });
}

/// Resolve and create the data directory, or null when no path exists. The caller owns it.
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

/// Take the single-instance lock, and report a conflict with a message the user can act on.
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

/// Read the stored device credential. `State.init` copies it before the read buffer ends.
fn readDevice(arena: std.mem.Allocator, io: std.Io, data_dir: ?[]const u8) ?cloud.identity.Device {
    const data_path = data_dir orelse return null;
    var dir = std.Io.Dir.cwd().openDir(io, data_path, .{}) catch |err| {
        std.log.warn("cannot open the cloud identity directory: {t}", .{err});
        return null;
    };
    defer dir.close(io);
    return cloud.identity.readMeta(arena, io, dir, cloud.identity.Device, .device) catch |err| {
        std.log.warn("cannot read the device credential: {t}", .{err});
        return null;
    };
}

/// Create the data directory with mode 0700 on POSIX, and default permissions on Windows.
fn ensureDataDir(io: std.Io, dir: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    if (builtin.os.tag == .windows) return cwd.createDirPath(io, dir);
    const perms = std.Io.File.Permissions.fromMode(0o700);
    if (try cwd.createDirPathStatus(io, dir, perms) == .created)
        try cwd.setFilePermissions(io, dir, perms, .{});
}

/// The test dependencies. An empty environment allocates nothing, so no test frees it.
var test_env: std.process.Environ.Map = .init(std.testing.allocator);
var test_transport = provider.transport.CannedTransport{ .bytes = provider.transport.canned_reply };

test "a catalog replacement announces the merged revision" {
    const testing = std.testing;
    const rt = try zio.Runtime.init(testing.allocator, .{ .executors = .exact(1) });
    defer rt.deinit();
    const listen = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var state = try State.init(.{ .gpa = testing.allocator, .io = rt.io(), .db = try database.Database.openTest(), .config = .{ .listen = listen }, .home = "/home/test", .env = &test_env, .route_transport = test_transport.transport() });
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
