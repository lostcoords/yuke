//! Daemon-global state. One reactor executor owns it for the daemon lifetime.
//! Keep the per-connection state separate.

const std = @import("std");
const zio = @import("zio");
const wire = @import("wire");
const database = @import("../database/database.zig");
const committed = @import("domain").committed;
const domain_session = @import("domain").session;
const util = @import("../util.zig");
const provider = @import("../provider/provider.zig");
const bundle = @import("../cloud/bundle.zig");
const cloud_endpoint = @import("../cloud/endpoint.zig");
const cloud_http = @import("../cloud/http.zig");
const cloud_sync = @import("../cloud/sync.zig");
const provider_catalog = @import("provider_catalog.zig");
const host = @import("../host/host.zig");
const retry = @import("../provider/retry.zig");
const session_runtime = @import("session_runtime.zig");
const connection = @import("connection.zig");
const daemon_config = @import("config.zig");

const State = @This();

gpa: std.mem.Allocator, // The allocator serves long-lived allocations. The per-request arena has a separate lifetime.
io: std.Io, // The reactor uses this I/O for the clock, files, and sockets.
db: database.Database, // The database uses one SQLite connection with prepared queries. One executor writes.
config: Config,
home: []const u8, // The default workspace root. A create that omits a workspace path uses it.
sessions: session_runtime.Sessions, // The daemon stores live per-session state, keyed by session id.
registry: connection.Registry, // The registry tracks live connections and the reverse subscription index.
route_transport: provider.transport.Transport, // Every resolved route opens its response through this transport.
providers: ?provider.config.Loaded = null, // The daemon owns the loaded providers.json layer when present.
cloud_client: cloud_http.Client,
cloud_base_url: []u8,
cloud_credential: ?[]u8 = null,
cloud_bundle: ?bundle.Snapshot = null, // The account bundle stays in memory, because it holds live credentials.
cloud_refresh_mutex: std.Io.Mutex = .init,
catalog: provider_catalog.Catalog, // One merged snapshot serves catalog reads and provider requests.
defaults: daemon_config.Defaults = .{}, // Defaults seed a new session's model and system prompt.
config_owner: ?daemon_config.Loaded = null, // The daemon owns the yuked.json arena when present.
env: *const std.process.Environ.Map, // This pointer borrows the process environment for key lookup.
run_group: std.Io.Group = .init, // The group owns each launched run task until it returns.
shutting_down: bool = false,
tool_host: ?host.Host = null,
retry_policy: retry.Policy = .{}, // A test shortens the delays. Production keeps the defaults.
retry_budget: u8 = 8, // Retry permits for one whole run. // A test injects a tool host; production builds a LocalHost per run.
/// The session index revision. It counts each published `session.summary_changed`.
/// It lives in memory, so a restart returns it to zero.
session_revision: u64 = 0,

/// The daemon stores its configuration here.
pub const Config = struct {
    listen: std.Io.net.IpAddress,
    db_path: [:0]const u8 = ":memory:",
};

/// These options provide the state dependencies and the initial cloud identity.
pub const InitOptions = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    db: database.Database,
    config: Config,
    home: []const u8,
    /// The state borrows the process environment for `~` expansion and key lookup.
    env: *const std.process.Environ.Map,
    /// The state borrows the transport owner, which must outlive the state.
    route_transport: provider.transport.Transport,
    cloud_base_url: []const u8 = cloud_endpoint.default_base,
    cloud_credential: ?[]const u8 = null,
};

/// Duplicate the cloud endpoint and credential. The state then owns both values.
fn dupeCloud(gpa: std.mem.Allocator, options: InitOptions) !struct { []u8, ?[]u8 } {
    const base_url = try gpa.dupe(u8, options.cloud_base_url);
    errdefer gpa.free(base_url);
    const credential = if (options.cloud_credential) |value| try gpa.dupe(u8, value) else null;
    return .{ base_url, credential };
}

/// Build the daemon state. It takes ownership of `db` and borrows `io` for its lifetime.
pub fn init(options: InitOptions) !State {
    const gpa = options.gpa;
    std.debug.assert(options.cloud_base_url.len != 0);
    // The state never formed, so close the store the caller gave it.
    const cloud_base_url, const cloud_credential = dupeCloud(gpa, options) catch |err| {
        var db = options.db;
        db.deinit();
        return err;
    };
    var self: State = .{
        .gpa = gpa,
        .io = options.io,
        .db = options.db,
        .config = options.config,
        .home = options.home,
        .env = options.env,
        .route_transport = options.route_transport,
        .sessions = session_runtime.Sessions.init(gpa),
        .registry = connection.Registry.init(gpa),
        .cloud_client = .init(gpa, options.io),
        .cloud_base_url = cloud_base_url,
        .cloud_credential = cloud_credential,
        .catalog = .init(gpa),
    };
    errdefer self.deinit();

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var event_ids: RecoveryEventIds = .{ .state = &self };
    const recovered = try database.run.recoverOpen(&self.db, arena.allocator(), self.nowMillis(), &event_ids);
    if (recovered > 0) std.log.info("recovered {d} open runs as canceled", .{recovered});
    const pending_sessions = try database.input.sessionIds(&self.db, arena.allocator());
    for (pending_sessions) |session_id| _ = try self.activate(.bytes(session_id));
    return self;
}

/// Return the live runtime for a session and seed its projection from SQLite once.
/// The caller must know the session exists. A durable event then folds onto the hydrated cursors.
pub fn activate(self: *State, session_id: wire.ids.SessionId) !*session_runtime.SessionRuntime {
    const rt = try self.sessions.getOrCreate(session_id);
    if (!rt.hydrated) {
        var session = domain_session.Session.init(self.gpa, session_id);
        errdefer session.deinit();
        try self.hydrateSession(&session);
        rt.session.deinit();
        rt.session = session;
        session = undefined;
        rt.hydrated = true;
    }
    return rt;
}

/// Load the committed window, the configs, the durable cursors, and the pending inputs into a session.
/// SQLite stays authoritative. The daemon caches the recent tail so resync serializes the projection.
pub fn hydrateSession(self: *State, session: *domain_session.Session) !void {
    std.debug.assert(session.active == null and session.queue.depth() == 0);
    std.debug.assert(session.committed.list.items.len == 0 and session.configs.map.count() == 0);
    std.debug.assert(session.base_seq == 0 and session.finalized_message_id == 0);
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const sid = session.id.raw;
    const hw = (try database.event.highWater(&self.db, a, sid)) orelse return; // No session row exists.
    const page = try database.message.historyPage(&self.db, a, sid, 0, committed.default_max_messages);
    const configs = try database.config.forMessages(&self.db, a, sid, page.messages);
    const finalized: u64 = if (page.messages.len > 0) page.messages[page.messages.len - 1].id() else 0;
    try session.installSnapshot(.{
        .base_seq = hw.seq_high,
        .finalized_message_id = finalized,
        .messages = page.messages,
        .configs = configs,
        .has_more = page.has_more,
    });
    // Pending inputs are historical. Fold them directly, so they do not advance the durable cursor.
    const pending = try database.input.list(&self.db, a, sid);
    for (pending) |entry| {
        const applied = try session.queue.onQueued(.{ .session_id = session.id, .seq = entry.seq, .input = entry.input });
        std.debug.assert(applied == .changed);
    }
}

const RecoveryEventIds = struct {
    state: *State,

    pub fn next(self: *RecoveryEventIds) ![16]u8 {
        return self.state.newId();
    }
};

/// Free the live sessions and the registry, then close the store.
pub fn deinit(self: *State) void {
    self.shutting_down = true;
    self.run_group.cancel(self.io);
    self.registry.deinit();
    self.sessions.deinit();
    self.catalog.deinit();
    if (self.cloud_bundle) |*loaded| loaded.deinit();
    if (self.cloud_credential) |credential| {
        std.crypto.secureZero(u8, credential);
        self.gpa.free(credential);
    }
    self.gpa.free(self.cloud_base_url);
    self.cloud_client.deinit();
    if (self.providers) |*p| p.deinit();
    if (self.config_owner) |*c| c.deinit();
    self.db.deinit();
}

/// Replace the merged provider snapshot. Build the replacement before the live snapshot changes.
pub fn rebuildCatalog(self: *State) !bool {
    const next = try provider_catalog.Catalog.load(self.gpa, &self.db, .{
        .local = if (self.providers) |*loaded| loaded else null,
        .cloud = if (self.cloud_bundle) |*loaded| loaded.document else null,
        .env = self.env,
    });

    const changed = !std.mem.eql(u8, &self.catalog.revision.raw, &next.revision.raw);
    var previous = self.catalog;
    self.catalog = next;
    previous.deinit();
    return changed;
}

/// Fetch the public catalog and the account bundle. Only one check runs at a time.
pub fn refreshCloud(self: *State) !wire.ids.CatalogRev {
    try self.cloud_refresh_mutex.lock(self.io);
    defer self.cloud_refresh_mutex.unlock(self.io);
    try self.refreshCloudLocked();
    return self.catalog.revision;
}

fn refreshCloudLocked(self: *State) !void {
    std.debug.assert(self.cloud_base_url.len != 0);

    var first_error: ?anyerror = null;
    var rebuild = false;
    const catalog_outcome = cloud_sync.refreshCatalog(self.gpa, &self.cloud_client, &self.db, self.cloud_base_url) catch |err| blk: {
        first_error = err;
        break :blk null;
    };
    if (catalog_outcome) |outcome| switch (outcome) {
        .updated, .unchanged => rebuild = true,
        .unavailable => std.log.warn("catalog not synced by the control plane yet", .{}),
    };

    var next_bundle: ?bundle.Snapshot = null;
    defer if (next_bundle) |*loaded| loaded.deinit();
    if (self.cloud_credential) |credential| {
        const etag = if (self.cloud_bundle) |*loaded| loaded.etag else "";
        const providers_outcome = cloud_sync.refreshProviders(
            self.gpa,
            &self.cloud_client,
            self.cloud_base_url,
            credential,
            etag,
        ) catch |err| blk: {
            if (first_error == null) first_error = err;
            break :blk null;
        };
        if (providers_outcome) |outcome| switch (outcome) {
            .unchanged => {},
            .updated => |loaded| {
                next_bundle = loaded;
                rebuild = true;
            },
        };
    }

    var changed = false;
    if (rebuild) {
        if (next_bundle) |*loaded| {
            changed = try self.installCloudBundle(loaded);
            next_bundle = null;
        } else {
            changed = try self.rebuildCatalog();
        }
    }
    if (changed) self.announceCatalogChanged();
    if (first_error) |err| return err;
}

/// Install one bundle only after the merged replacement is ready.
fn installCloudBundle(self: *State, next_bundle: *bundle.Snapshot) !bool {
    const next_catalog = try provider_catalog.Catalog.load(self.gpa, &self.db, .{
        .local = if (self.providers) |*loaded| loaded else null,
        .cloud = next_bundle.document,
        .env = self.env,
    });

    const changed = !std.mem.eql(u8, &self.catalog.revision.raw, &next_catalog.revision.raw);
    var previous_catalog = self.catalog;
    var previous_bundle = self.cloud_bundle;
    self.catalog = next_catalog;
    self.cloud_bundle = next_bundle.*;
    next_bundle.* = undefined;
    previous_catalog.deinit();
    if (previous_bundle) |*loaded| loaded.deinit();
    return changed;
}

/// Publish the new merged revision after the replacement is ready.
pub fn announceCatalogChanged(self: *State) void {
    const note: wire.rpc.Notification = .{
        .method = .@"catalog.changed",
        .params = .{ .catalog_changed_data = .{ .catalog_rev = self.catalog.revision } },
    };
    const bytes = connection.frameNotification(self.gpa, note) catch |err| {
        std.log.warn("cannot frame catalog.changed: {t}", .{err});
        return;
    };
    defer self.gpa.free(bytes);
    self.registry.publishAll(bytes);
}

/// Return wall-clock milliseconds since the Unix epoch. See util.nowMillis for the clock rules.
pub fn nowMillis(self: *const State) u64 {
    return util.nowMillis(self.io);
}

/// Mint a fresh UUIDv7 for a session, workspace, or event.
pub fn newId(self: *const State) [16]u8 {
    return util.newId(self.io);
}

/// Draw a jitter value in [0, 1) for one retry delay.
/// A UUIDv7 pins its version and variant bits, so this reads only bytes that stay random.
pub fn jitter(self: *const State) f64 {
    const id = self.newId();
    // Bytes 9..16 hold 56 random bits. Byte 8 carries the variant, so it must not take part.
    var raw: u64 = 0;
    for (id[9..16]) |b| raw = (raw << 8) | b;
    const bits = raw >> 3; // 53 bits fit an f64 exactly
    return @as(f64, @floatFromInt(bits)) / @as(f64, @floatFromInt(@as(u64, 1) << 53));
}

/// These test dependencies use an empty environment. The map has no allocation to free.
var test_env: std.process.Environ.Map = .init(std.testing.allocator);
var test_transport = provider.transport.CannedTransport{ .bytes = provider.transport.canned_reply };

test "a cloud bundle and its etag install as one snapshot" {
    var runtime = try zio.Runtime.init(std.testing.allocator, .{ .executors = .exact(1) });
    defer runtime.deinit();
    const listen = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var state = try State.init(.{
        .gpa = std.testing.allocator,
        .io = runtime.io(),
        .db = try database.Database.openTest(),
        .config = .{ .listen = listen },
        .home = "/home/test",
        .env = &test_env,
        .route_transport = test_transport.transport(),
    });
    defer state.deinit();

    var snapshot = try bundle.Snapshot.init(std.testing.allocator,
        \\{"version":1,"catalog_rev":null,"providers":[{"id":"acme","public_id":"p1","name":"Acme",
        \\ "base_url":"https://acme.example/v1","protocol":"openai_chat","cache":"unsupported","headers":[],
        \\ "auth":{"kind":"api_key","header":"authorization_bearer","status":"active","api_key":"secret"},
        \\ "models":[{"id":"m","upstream_id":"upstream-m","name":"Model","limits":{"context_window":null,"max_output_tokens":null},
        \\ "cost":{"input":null,"output":null,"cache_read":null,"cache_write":null},"flags":{},"reasoning":null,
        \\ "reasoning_levels":[],"status":null}]}]}
    , "etag-1");
    var installed = false;
    defer if (!installed) snapshot.deinit();

    const changed = try state.installCloudBundle(&snapshot);
    installed = true;
    try std.testing.expect(changed);
    try std.testing.expectEqualStrings("etag-1", state.cloud_bundle.?.etag);
    try std.testing.expectEqualStrings("secret", state.cloud_bundle.?.document.providers[0].auth.api_key.?);
    const resolved = state.catalog.resolveModel("acme/m").?;
    try std.testing.expectEqual(wire.enums.ProviderSource.cloud, resolved.provider.source);
    try std.testing.expect(resolved.provider.route != null);
    try std.testing.expect(resolved.model.supports_tools == null);
}

test "init restores durable pending input into the runtime queue" {
    var runtime = try zio.Runtime.init(std.testing.allocator, .{ .executors = .exact(1) });
    defer runtime.deinit();
    const listen = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var db = try database.Database.openTest();
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const workspace_id = [_]u8{1} ** 16;
    const session_id = [_]u8{2} ** 16;
    _ = try database.workspace.resolve(&db, arena, workspace_id, "/boot", "boot", null);
    try database.session.create(&db, .{
        .id = session_id,
        .workspace_id = workspace_id,
        .origin = "root",
        .profile = "default",
        .model = "mock",
        .reasoning = "",
        .config_rev = 0,
        .permission = "normal",
        .title = "boot",
        .created_at_ms = 1,
        .updated_at_ms = 1,
    });
    try db.conn.execNoArgs("BEGIN IMMEDIATE");
    const queued = try database.input.enqueue(&db, arena, session_id, [_]u8{3} ** 16, 2, &.{.{ .text = .{ .text = "recover" } }}, 2);
    try db.conn.execNoArgs("COMMIT");

    var state = try State.init(.{ .gpa = std.testing.allocator, .io = runtime.io(), .db = db, .config = .{ .listen = listen }, .home = "/home/test", .env = &test_env, .route_transport = test_transport.transport() });
    defer state.deinit();
    const rt = state.sessions.get(.bytes(session_id)).?;
    try std.testing.expectEqual(@as(usize, 1), rt.session.queue.depth());
    try std.testing.expectEqual(queued.input.input_id, rt.session.queue.entries()[0].input_id);
}

test "activation does not retain partial hydration after allocation failure" {
    var runtime = try zio.Runtime.init(std.testing.allocator, .{ .executors = .exact(1) });
    defer runtime.deinit();
    const listen = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var db = try database.Database.openTest();
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const workspace_id = [_]u8{4} ** 16;
    const session_id = [_]u8{5} ** 16;
    _ = try database.workspace.resolve(&db, arena, workspace_id, "/oom", "oom", null);
    try database.session.create(&db, .{
        .id = session_id,
        .workspace_id = workspace_id,
        .origin = "root",
        .profile = "default",
        .model = "mock",
        .reasoning = "",
        .config_rev = 0,
        .permission = "normal",
        .title = "oom",
        .created_at_ms = 1,
        .updated_at_ms = 1,
    });
    try db.conn.execNoArgs("BEGIN IMMEDIATE");
    _ = try database.input.enqueue(&db, arena, session_id, [_]u8{6} ** 16, 2, &.{.{ .text = .{ .text = "recover" } }}, 2);
    try db.conn.execNoArgs("COMMIT");

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var state = try State.init(.{ .gpa = failing.allocator(), .io = runtime.io(), .db = db, .config = .{ .listen = listen }, .home = "/home/test", .env = &test_env, .route_transport = test_transport.transport() });
    defer state.deinit();
    const rt = state.sessions.get(.bytes(session_id)).?;
    const baseline = failing.alloc_index;
    var saw_oom = false;

    var fail_offset: usize = 0;
    while (fail_offset < 128) : (fail_offset += 1) {
        rt.session.deinit();
        rt.session = domain_session.Session.init(failing.allocator(), .bytes(session_id));
        rt.hydrated = false;
        failing.alloc_index = baseline;
        failing.fail_index = baseline + fail_offset;
        failing.has_induced_failure = false;

        _ = state.activate(.bytes(session_id)) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            saw_oom = true;
            try std.testing.expect(!rt.hydrated);
            try std.testing.expectEqual(@as(usize, 0), rt.session.queue.depth());
            try std.testing.expectEqual(@as(usize, 0), rt.session.committed.list.items.len);
            try std.testing.expectEqual(@as(u64, 0), rt.session.base_seq);
            continue;
        };
    }
    try std.testing.expect(saw_oom);
}
