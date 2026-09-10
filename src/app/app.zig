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
const execution = @import("../execution.zig");

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
    pub fn open(gpa: std.mem.Allocator, io: std.Io, context: execution.Context) !*App {
        const self = try gpa.create(App);
        errdefer gpa.destroy(self);

        // A store that resolves from no base at all would lose every session at exit, so it stops startup.
        const data_dir = (try resolveDataDir(gpa, io, context.env)) orelse return error.NoStateDirectory;
        defer gpa.free(data_dir);

        const db_path = try dbPathZ(gpa, data_dir);
        defer gpa.free(db_path);

        self.* = .{
            .gpa = gpa,
            .io = io,
            .http_transport = ai.http_transport.HttpTransport.init(gpa, io, provider_idle_timeout),
            .db = undefined,
            .logins = .init(gpa),
            .store = .init(gpa, io, context.env),
            .engine = undefined,
        };
        errdefer self.http_transport.deinit();

        const conn = try zqlite.open(db_path, open_flags);
        self.db = try database.Database.open(conn);
        errdefer self.deinitState();

        // The app owns this path, because an invalid file fails startup and `auth.set_api_key` rewrites it.
        self.store.path = try configFilePath(gpa, context.env, "providers.json");
        if (self.store.path != null) {
            // An absent or empty file installs an empty layer, which every reader treats like none.
            _ = try self.store.reload();
            std.log.info("loaded {d} provider(s) from providers.json", .{self.store.local.?.providers.len});
        } else _ = try self.store.rebuild();

        // The engine borrows every process resource, so it is built after all of them exist.
        self.engine = Engine.init(.{
            .gpa = gpa,
            .io = io,
            .db = &self.db,
            .providers = &self.store,
            .route_transport = self.http_transport.transportFor(),
            .execution = context,
        });

        self.scheduler = .init(self);
        self.maintenance.concurrent(io, scheduler_mod.Scheduler.run, .{&self.scheduler}) catch |err| {
            std.log.warn("the scheduler did not start: {t}", .{err});
        };

        // The frontend resumes workspace queues after tools and interaction handlers exist.
        std.log.info("engine store at {s}", .{db_path});
        return self;
    }

    /// Build one app around a test database. The caller closes the owned resources.
    pub fn initTest(self: *App, gpa: std.mem.Allocator, io: std.Io, db: database.Database, context: execution.Context, route_transport: ai.transport.Transport) !void {
        self.* = .{
            .gpa = gpa,
            .io = io,
            .http_transport = undefined,
            .db = db,
            .logins = .init(gpa),
            .store = .init(gpa, io, context.env),
            .engine = undefined,
        };
        self.engine = Engine.init(.{
            .gpa = gpa,
            .io = io,
            .db = &self.db,
            .providers = &self.store,
            .route_transport = route_transport,
            .execution = context,
        });
    }

    /// Offer `test/model` so a test that creates a session can name a model the catalog serves.
    pub fn installTestModel(self: *App) !void {
        std.debug.assert(builtin.is_test);
        var local = try provider.config.loadBytes(self.gpa,
            \\{"version":1,"providers":[{"id":"test","base_url":"http://localhost:1/v1","protocol":"openai_chat","models":[{"id":"model","upstream_id":"model","flags":{"supports_tools":true}}]}]}
        );
        _ = self.store.installLocal(&local) catch |err| {
            local.deinit();
            return err;
        };
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

test "an environment with no base for the store stops startup instead of losing every session" {
    const testing = std.testing;
    const rt = try zio.Runtime.init(testing.allocator, .{ .executors = .exact(1) });
    defer rt.deinit();
    // No home directory and no XDG base, which is the container case the plan names.
    var bare: std.process.Environ.Map = .init(testing.allocator);
    defer bare.deinit();
    try testing.expectError(error.NoStateDirectory, App.open(testing.allocator, rt.io(), execution.testContext(&bare)));
}

test "an absolute XDG base opens the store with no home directory at all" {
    const testing = std.testing;
    const rt = try zio.Runtime.init(testing.allocator, .{ .executors = .exact(1) });
    defer rt.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(testing.io, &buf)];
    var xdg: std.process.Environ.Map = .init(testing.allocator);
    defer xdg.deinit();
    try xdg.put("XDG_DATA_HOME", root);
    const opened = try App.open(testing.allocator, rt.io(), execution.testContext(&xdg));
    opened.close();
}

test "a catalog replacement announces the merged revision" {
    const testing = std.testing;
    const rt = try zio.Runtime.init(testing.allocator, .{ .executors = .exact(1) });
    defer rt.deinit();
    var runtime: App = undefined;
    try runtime.initTest(testing.allocator, rt.io(), try database.Database.openTest(), execution.testContext(&test_env), test_transport.transport());
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
