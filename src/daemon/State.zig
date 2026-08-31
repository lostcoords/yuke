//! Daemon-global state that one reactor executor owns. Per-connection state stays separate.

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
const cloud_http = @import("../net/http.zig");
const cloud_fetch = @import("../cloud/fetch.zig");
const catalog_fetch = @import("../catalog/fetch.zig");
const catalog_store = @import("../catalog/store.zig");
const provider_registry = @import("registry.zig");
const scheduler_mod = @import("scheduler.zig");
const host = @import("../host/host.zig");
const retry = @import("../provider/retry.zig");
const session_runtime = @import("session_runtime.zig");
const connection = @import("connection.zig");
const daemon_config = @import("config.zig");

const State = @This();

/// The daemon build version. `/identity` and the `initialize` result must report one value.
pub const daemon_version = "0.0.1";

gpa: std.mem.Allocator, // The allocator serves long-lived allocations. The per-request arena has a separate lifetime.
io: std.Io, // The reactor uses this I/O for the clock, files, and sockets.
db: database.Database, // The database uses one SQLite connection with prepared queries. One executor writes.
config: Config,
home: []const u8, // The default workspace root. A create that omits a workspace path uses it.
sessions: session_runtime.Sessions, // The daemon stores live per-session state, keyed by session id.
registry: connection.Registry, // The registry tracks live connections and the reverse subscription index.
route_transport: provider.transport.Transport, // Every resolved route opens its response through this transport.
providers: ?provider.config.Loaded = null, // The daemon owns this layer. Replace it only through installProviders.
cloud_client: cloud_http.Client,
cloud_base_url: []u8,
cloud_credential: ?[]u8 = null,
device_id: ?[]u8 = null, // The enrolled device id. `/identity` reports it, and it holds no secret.
cloud_bundle: ?bundle.Snapshot = null, // The account bundle stays in memory, because it holds live credentials.
catalog: provider_registry.Registry, // One merged snapshot serves catalog reads and provider requests.
defaults: daemon_config.Defaults = .{}, // Defaults seed a new session's model and system prompt.
config_owner: ?daemon_config.Loaded = null, // The daemon owns the yuked.json arena when present.
env: *const std.process.Environ.Map, // This pointer borrows the process environment for key lookup.
scheduler: ?*scheduler_mod.Scheduler = null, // The app stores this pointer while the maintenance task runs.
fetching: bool = false, // One control-plane fetch at a time. Two would race the stored ETag.
providers_path: ?[]u8 = null, // State owns this path and frees it in deinit. Null means no config directory.
run_group: std.Io.Group = .init, // The group owns each launched run task until it returns.
shutting_down: bool = false,
tool_host: ?host.Host = null,
retry_policy: retry.Policy = .{}, // A test shortens the delays. Production keeps the defaults.
retry_budget: u8 = 8, // Retry permits for one whole run. // A test injects a tool host; production builds a LocalHost per run.
/// The in-memory session index revision. It counts each `session.summary_changed`, and a restart clears it.
session_revision: u64 = 0,

/// The daemon stores its configuration here.
pub const Config = struct {
    listen: std.Io.net.IpAddress,
    db_path: [:0]const u8 = ":memory:",
    /// The browser origins that admission accepts beyond the official client.
    allowed_origins: []const []const u8 = &.{},
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
    /// The enrolled device id, from the same identity the relay reads. Absent before enrollment.
    device_id: ?[]const u8 = null,
};

/// Duplicate the cloud endpoint, the credential, and the device id. The state then owns them.
fn dupeCloud(gpa: std.mem.Allocator, options: InitOptions) !struct { []u8, ?[]u8, ?[]u8 } {
    const base_url = try gpa.dupe(u8, options.cloud_base_url);
    errdefer gpa.free(base_url);
    const credential = if (options.cloud_credential) |value| try gpa.dupe(u8, value) else null;
    errdefer if (credential) |value| gpa.free(value);
    const device_id = if (options.device_id) |value| try gpa.dupe(u8, value) else null;
    return .{ base_url, credential, device_id };
}

/// Build the daemon state. It takes ownership of `db` and borrows `io` for its lifetime.
pub fn init(options: InitOptions) !State {
    const gpa = options.gpa;
    std.debug.assert(options.cloud_base_url.len != 0);
    // The state never formed, so close the store the caller gave it.
    const cloud_base_url, const cloud_credential, const device_id = dupeCloud(gpa, options) catch |err| {
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
        .cloud_client = .init(gpa, options.io, cloud_http.default_timeout),
        .cloud_base_url = cloud_base_url,
        .cloud_credential = cloud_credential,
        .device_id = device_id,
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

/// Return the live runtime of a known session, and seed its projection from SQLite once.
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

/// Hydrate one session from SQLite, and cache its recent tail so a resync can serialize it.
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
    if (self.cloud_credential) |credential| self.gpa.free(credential);
    if (self.device_id) |id| self.gpa.free(id);
    if (self.providers_path) |path| self.gpa.free(path);
    self.gpa.free(self.cloud_base_url);
    self.cloud_client.deinit();
    if (self.providers) |*p| p.deinit();
    if (self.config_owner) |*c| c.deinit();
    self.db.deinit();
}

/// Replace the merged provider snapshot. Build the replacement before the live snapshot changes.
pub fn rebuildCatalog(self: *State) !bool {
    const next = try provider_registry.Registry.load(self.gpa, &self.db, .{
        .local = if (self.providers) |*loaded| loaded else null,
        .account = if (self.cloud_bundle) |*loaded| loaded.document else null,
        .env = self.env,
    });

    const changed = !std.mem.eql(u8, &self.catalog.revision.raw, &next.revision.raw);
    var previous = self.catalog;
    self.catalog = next;
    previous.deinit();
    return changed;
}

/// Report what one cloud refresh achieved.
pub const RefreshStatus = enum {
    /// The stored documents match the control plane.
    current,
    /// The control plane answered without a catalog.
    catalog_unavailable,
};

/// Fetch the public catalog and install it. The scheduler owns the cadence.
pub fn refreshCatalogOnce(self: *State) !RefreshStatus {
    std.debug.assert(self.cloud_base_url.len != 0);

    // A second fetch would read the same stored ETag and install its response out of order.
    std.debug.assert(!self.fetching);
    self.fetching = true;
    defer self.fetching = false;

    var etag_buf: [catalog_fetch.max_etag_bytes]u8 = undefined;
    const outcome = try catalog_fetch.refreshCatalog(self.gpa, &self.cloud_client, &self.db, self.cloud_base_url, &etag_buf);
    switch (outcome) {
        .unchanged => return .current,
        .unavailable => return .catalog_unavailable,
        .updated => |etag| {
            const changed = try self.rebuildCatalog();
            // The stored ETag means the live snapshot holds that document, so it commits first.
            try catalog_store.setEtag(&self.db, etag);
            if (changed) self.announceCatalogChanged();
            return .current;
        },
    }
}

/// Fetch the account bundle and install it. A daemon with no credential has nothing to fetch.
pub fn refreshBundleOnce(self: *State) !void {
    std.debug.assert(self.cloud_base_url.len != 0);

    const credential = self.cloud_credential orelse return;
    // A second fetch would hold this ETag while the first install frees the arena behind it.
    std.debug.assert(!self.fetching);
    self.fetching = true;
    defer self.fetching = false;

    const etag = if (self.cloud_bundle) |*loaded| loaded.etag else "";
    const outcome = try cloud_fetch.refreshProviders(self.gpa, &self.cloud_client, self.cloud_base_url, credential, etag);
    switch (outcome) {
        .unchanged => {},
        .updated => |loaded| {
            var next = loaded;
            errdefer next.deinit();
            if (try self.installCloudBundle(&next)) self.announceCatalogChanged();
        },
    }
}

/// Report when the soonest ACTIVE account token expires, because a dead grant keeps a stale expiry.
pub fn bundleExpiryMillis(self: *const State) ?u64 {
    const loaded = self.cloud_bundle orelse return null;
    var soonest: ?u64 = null;
    for (loaded.document.providers) |p| {
        if (p.auth.status != .active) continue;
        const at = p.auth.expires_at_ms orelse continue;
        if (soonest == null or at < soonest.?) soonest = at;
    }
    return soonest;
}

/// Install one bundle after the merged replacement is ready. State takes ownership of `next_bundle`.
fn installCloudBundle(self: *State, next_bundle: *bundle.Snapshot) !bool {
    const next_catalog = try provider_registry.Registry.load(self.gpa, &self.db, .{
        .local = if (self.providers) |*loaded| loaded else null,
        .account = next_bundle.document,
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

/// Install one providers layer after the replacement is ready, because a direct assignment frees live routes.
pub fn installProviders(self: *State, next: *provider.config.Loaded) !bool {
    const next_catalog = try provider_registry.Registry.load(self.gpa, &self.db, .{
        .local = next,
        .account = if (self.cloud_bundle) |*loaded| loaded.document else null,
        .env = self.env,
    });

    const changed = !std.mem.eql(u8, &self.catalog.revision.raw, &next_catalog.revision.raw);
    var previous_catalog = self.catalog;
    var previous_providers = self.providers;
    self.catalog = next_catalog;
    self.providers = next.*;
    next.* = undefined;
    previous_catalog.deinit();
    if (previous_providers) |*loaded| loaded.deinit();
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

/// Ask the scheduler for a catalog fetch now. The caller returns before the network answers.
pub fn requestCatalogRefresh(self: *State) void {
    if (self.scheduler) |s| s.requestCatalog();
}

/// Publish one provider's new authentication state. A null `kind` means the daemon holds no credential.
pub fn announceAuthChanged(self: *State, provider_id: []const u8, kind: ?wire.enums.AuthCredentialKind) void {
    const note: wire.rpc.Notification = .{
        .method = .@"auth.changed",
        .params = .{ .auth_changed_data = .{ .provider = .{
            .provider_id = provider_id,
            .credential_kind = kind,
            .login_flows = &.{},
        } } },
    };
    const bytes = connection.frameNotification(self.gpa, note) catch |err| {
        std.log.warn("cannot frame auth.changed: {t}", .{err});
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

/// Draw a retry jitter in [0, 1) from the UUIDv7 bytes that stay random.
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
        \\{"version":1,"catalog_rev":null,"providers":[{"id":"acme","name":"Acme",
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
    const resolved = state.catalog.resolveModel("cloud:acme/m").?;
    try std.testing.expectEqual(wire.enums.ProviderSource.cloud, resolved.provider.origin);
    try std.testing.expect(resolved.provider.availability == .ready);
    try std.testing.expect(resolved.model.caps.tools == .unknown);
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
