//! The process composition root. It owns every process resource and one engine.

const std = @import("std");
const ai = @import("ai");
const builtin = @import("builtin");
const zio = @import("zio");
const zqlite = @import("zqlite");
const proto = @import("proto");
const database = @import("../store/store.zig");
const paths = @import("../paths.zig");
const provider = @import("../provider/provider.zig");
const provider_store = @import("../provider/provider_store.zig");
const provider_registry = @import("../provider/registry.zig");
const login_runtime = @import("../provider/oauth/login_runtime.zig");
const Engine = @import("../engine/Engine.zig");
const scheduler_mod = @import("scheduler.zig");

// The timeout wakes a stalled provider read. Cancellation also interrupts the read.
const provider_idle_timeout = std.Io.Duration.fromMilliseconds(60_000);

const open_flags = zqlite.OpenFlags.Create | zqlite.OpenFlags.NoMutex | zqlite.OpenFlags.EXResCode;

/// The process and every resource it owns.
pub const App = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    /// The HTTP client outlives the app tasks, because they read through it.
    http_transport: ai.http_transport.HttpTransport,
    db: database.Database,
    logins: login_runtime.Logins,
    store: provider_store,
    tasks: std.Io.Group = .init,
    shutting_down: bool = false,
    engine: Engine,
    scheduler: scheduler_mod.Scheduler = undefined,
    maintenance: std.Io.Group = .init,

    /// Open the store, load the configuration, and start the maintenance task.
    pub fn open(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) !*App {
        const self = try gpa.create(App);
        errdefer gpa.destroy(self);

        const data_dir = try resolveDataDir(gpa, io, env);
        defer if (data_dir) |path| gpa.free(path);

        const owned_db_path = if (data_dir) |base| try dbPathZ(gpa, base) else null;
        defer if (owned_db_path) |path| gpa.free(path);

        const db_path: [:0]const u8 = if (owned_db_path) |p| p else ":memory:";

        self.* = .{
            .gpa = gpa,
            .io = io,
            .http_transport = ai.http_transport.HttpTransport.init(gpa, io, provider_idle_timeout),
            .db = undefined,
            .logins = .init(gpa),
            .store = .init(gpa, io, env),
            .engine = undefined,
        };
        errdefer self.http_transport.deinit();

        const conn = try zqlite.open(db_path, open_flags);
        self.db = try database.Database.open(conn);
        errdefer self.deinitState();

        // The app owns this path, because an invalid file fails startup and `auth.set_api_key` rewrites it.
        self.store.path = try configFilePath(gpa, env, "providers.json");
        if (self.store.path) |path| {
            var loaded = try provider.config.load(gpa, io, path);
            if (loaded.providers.len > 0) {
                self.store.local = loaded;
                std.log.info("loaded {d} provider(s) from providers.json", .{loaded.providers.len});
            } else loaded.deinit();
        }

        _ = try self.store.rebuild();

        // The engine borrows every process resource, so it is built after all of them exist.
        self.engine = Engine.init(.{
            .gpa = gpa,
            .io = io,
            .db = &self.db,
            .providers = &self.store,
            .route_transport = self.http_transport.transportFor(),
            .env = env,
        });

        self.scheduler = .init(self);
        self.maintenance.concurrent(io, scheduler_mod.Scheduler.run, .{&self.scheduler}) catch |err| {
            std.log.warn("the scheduler did not start: {t}", .{err});
        };

        // A queued run restarts when a view opens its session, not during process startup.
        std.log.info("engine store at {s}", .{db_path});
        return self;
    }

    /// Build one app around a test database. The caller closes the owned resources.
    pub fn initTest(self: *App, gpa: std.mem.Allocator, io: std.Io, db: database.Database, env: *const std.process.Environ.Map, route_transport: ai.transport.Transport) !void {
        self.* = .{
            .gpa = gpa,
            .io = io,
            .http_transport = undefined,
            .db = db,
            .logins = .init(gpa),
            .store = .init(gpa, io, env),
            .engine = undefined,
        };
        self.engine = Engine.init(.{
            .gpa = gpa,
            .io = io,
            .db = &self.db,
            .providers = &self.store,
            .route_transport = route_transport,
            .env = env,
        });
    }

    /// Publish one provider's new authentication state. A null `kind` means the engine holds no credential.
    pub fn announceAuthChanged(self: *App, provider_id: []const u8, kind: ?proto.enums.AuthCredentialKind) void {
        const note: proto.rpc.Notification = .{
            .method = .@"auth.changed",
            .params = .{
                .auth_changed_data = .{
                    .provider = .{
                        .provider_id = provider_id,
                        .credential_kind = kind,
                        // An empty list here would tell a client the provider lost a login it still offers.
                        .can_login = self.canLogin(provider_id),
                    },
                },
            },
        };
        self.engine.sinks.emit(note);
    }
    /// Publish the new merged revision after the replacement is ready.
    pub fn announceCatalogChanged(self: *App) void {
        const note: proto.rpc.Notification = .{
            .method = .@"catalog.changed",
            .params = .{ .catalog_changed_data = .{ .catalog_rev = self.store.merged.revision } },
        };
        self.engine.sinks.emit(note);
    }
    /// Report whether the engine can start a login for one provider.
    pub fn canLogin(self: *const App, provider_id: []const u8) bool {
        const row = provider_registry.find(self.store.merged.rows, provider_id) orelse return false;
        const name = row.login_flow orelse return false;
        return login_runtime.Flow.parse(name) != null;
    }

    /// Return wall-clock milliseconds since the Unix epoch.
    pub fn nowMillis(self: *const App) u64 {
        return @import("../util.zig").nowMillis(self.io);
    }

    /// Mint a fresh UUIDv7 for a session, workspace, or event.
    pub fn newId(self: *const App) [16]u8 {
        return @import("../util.zig").newId(self.io);
    }

    /// Join the maintenance task and close the store.
    pub fn close(self: *App) void {
        const gpa = self.gpa;
        const io = self.io;
        // Order is load-bearing. A login task publishes through the engine sinks, so every process
        // task must join BEFORE the engine closes: `Engine.close` ends with `self.* = undefined`,
        // and it suspends, so a task that runs after it would publish through a poisoned engine.
        self.maintenance.cancel(io);
        self.tasks.cancel(io);
        self.engine.close();
        self.deinitState();
        self.http_transport.deinit();
        gpa.destroy(self);
    }

    fn deinitState(self: *App) void {
        self.shutting_down = true;
        self.logins.deinit();
        self.store.deinit();
        self.db.deinit();
    }
};

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
var test_transport = ai.transport.CannedTransport{ .bytes = ai.transport.canned_reply };

test "a catalog replacement announces the merged revision" {
    const testing = std.testing;
    const rt = try zio.Runtime.init(testing.allocator, .{ .executors = .exact(1) });
    defer rt.deinit();
    var runtime: App = undefined;
    try runtime.initTest(testing.allocator, rt.io(), try database.Database.openTest(), &test_env, test_transport.transport());
    defer runtime.logins.deinit();
    defer runtime.store.deinit();
    defer runtime.db.deinit();
    defer runtime.engine.close();

    const Seen = struct {
        var method: ?proto.enums.BroadcastName = null;
        var revision: proto.ids.CatalogRev = undefined;
        fn onEvent(_: *anyopaque, note: proto.rpc.Notification) void {
            method = note.method;
            revision = note.params.catalog_changed_data.catalog_rev;
        }
    };
    Seen.method = null;
    var anchor: u8 = 0;
    runtime.engine.sinks.add(.{ .ctx = @ptrCast(&anchor), .on_event = Seen.onEvent });

    runtime.store.merged.revision = .bytes(@splat(0xab));
    runtime.announceCatalogChanged();

    try testing.expectEqual(proto.enums.BroadcastName.@"catalog.changed", Seen.method.?);
    try testing.expectEqualSlices(u8, &(@as([64]u8, @splat(0xab))), &Seen.revision.raw);
}
