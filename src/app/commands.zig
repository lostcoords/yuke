//! Process commands: the provider catalog, credentials, and the filesystem picker.
//! Each handler owns its write transaction.

const std = @import("std");
const execution = @import("../execution.zig");
const ai = @import("ai");
const proto = @import("proto");
const App = @import("app.zig").App;
const provider_config = @import("../provider/config/providers.zig");
const provider_registry = @import("../provider/registry.zig");
const provider_oauth = @import("../provider/provider.zig").oauth;
const login_runtime = @import("../provider/oauth/login_runtime.zig");
const login_task = @import("../provider/oauth/login_task.zig");
const net_http = @import("../net/http.zig");

/// Handle catalog.list: return every configured provider and its models, or nothing when the
/// client already holds this revision. A signed-out user with a local key still picks a model.
pub fn catalogList(runtime: *App, _: std.mem.Allocator, params: proto.catalog.CatalogListParams) !proto.catalog.CatalogListResult {
    const current = runtime.store.merged.revision;
    if (params.since_rev) |since| {
        if (std.mem.eql(u8, &since.raw, &current.raw)) return .{ .unchanged = .{ .catalog_rev = current } };
    }
    return .{ .full = .{
        .catalog_rev = current,
        .providers = runtime.store.merged.providers,
        .models = runtime.store.merged.models,
    } };
}

/// Handle catalog.reload: read providers.json again, then publish the revision when it moved.
pub fn catalogReload(runtime: *App, _: std.mem.Allocator, _: proto.misc.Empty) !proto.catalog.CatalogReloadResult {
    const changed = runtime.store.reload() catch |err| {
        std.log.warn("cannot reread providers.json: {t}", .{err});
        return error.BadProvidersFile;
    };
    if (changed) runtime.announceCatalogChanged();
    return .{ .catalog_rev = runtime.store.merged.revision, .changed = changed };
}

/// Handle auth.list: report the credential runtime of every local provider.
pub fn authList(runtime: *App, arena: std.mem.Allocator, _: proto.misc.Empty) !proto.auth.AuthListResult {
    var out: std.ArrayList(proto.auth.AuthProvider) = .empty;
    // The merged view holds the providers the environment offers as well as the ones the file names.
    for (runtime.store.merged.rows) |row| try out.append(arena, .{
        .provider_id = row.id,
        .credential_kind = if (localEntry(runtime, row.id)) |p| credentialKind(p) else discoveredKind(row),
        .can_login = runtime.canLogin(row.id),
    });
    return .{ .providers = out.items };
}

/// Handle auth.set_api_key: store one literal key and rebuild the snapshot.
/// The entry keeps every other field, so a hand-written route survives a key change.
pub fn authSetApiKey(runtime: *App, arena: std.mem.Allocator, params: proto.auth.AuthSetApiKeyParams) !proto.misc.Empty {
    if (!proto.ids.isSelectorPart(params.provider_id)) return error.BadProviderId;
    if (params.api_key.len == 0) return error.BadApiKey;

    if (try runtime.store.edit(arena, params.provider_id, .{ .set_api_key = params.api_key })) runtime.announceCatalogChanged();
    runtime.announceAuthChanged(params.provider_id, .api_key);
    return .{};
}

/// Handle auth.login: get a code, then poll in a task that outlives this connection.
pub fn authLogin(runtime: *App, arena: std.mem.Allocator, params: proto.auth.AuthLoginParams) !proto.auth.AuthLoginResult {
    if (!proto.ids.isSelectorPart(params.provider_id)) return error.BadProviderId;
    if (runtime.shutting_down) return error.Unavailable;
    // One provider holds one login, so a second attempt would race the first for the same grant.
    if (runtime.logins.byProvider(params.provider_id) != null) return error.LoginInProgress;

    const row = provider_registry.find(runtime.store.merged.rows, params.provider_id) orelse return error.UnknownProvider;
    const flow = login_runtime.Flow.parse(row.login_flow orelse return error.NoLoginFlow) orelse return error.NoLoginFlow;

    // The slot arena owns the code and the url, because the login outlives this request arena.
    var slot_arena: std.heap.ArenaAllocator = .init(runtime.gpa);
    const owned_id = slot_arena.allocator().dupe(u8, params.provider_id) catch |err| {
        slot_arena.deinit();
        return err;
    };

    // Reserve before the network call, because `start` yields and a second request would pass
    // the check above. The registry owns the arena from here, so one `remove` frees everything.
    const login_id: proto.ids.LoginId = .bytes(runtime.newId() ++ runtime.newId());
    const slot = runtime.logins.reserve(login_id, slot_arena, owned_id, flow) catch |err| {
        slot_arena.deinit();
        return err;
    };
    errdefer runtime.logins.remove(login_id);

    var client: net_http.Client = .init(runtime.gpa, runtime.io);
    defer client.deinit();
    const body = try arena.alloc(u8, net_http.max_oauth_response_bytes);
    const seam = provider_oauth.Http.fromClient(&client);
    slot.start = try login_task.start(slot.arena.allocator(), seam, flow, body);

    try runtime.tasks.concurrent(runtime.io, login_task.run, .{ runtime, slot });
    return .{ .login_id = login_id, .user_code = slot.start.user_code, .verification_url = slot.start.verification_url };
}

/// Handle auth.cancel_login: mark the login canceled, then wake it so it stops before its next poll.
pub fn authCancelLogin(runtime: *App, _: std.mem.Allocator, params: proto.auth.AuthCancelLoginParams) !proto.misc.Empty {
    // A cancel for a login that already finished is not an error, so a retry stays harmless.
    const slot = runtime.logins.get(params.login_id) orelse return .{};
    if (!slot.cancel.requested) slot.cancel.request(runtime.io);
    return .{};
}

/// Handle auth.remove: drop the credential the engine holds for one provider.
pub fn authRemove(runtime: *App, arena: std.mem.Allocator, params: proto.auth.AuthRemoveParams) !proto.misc.Empty {
    if (!proto.ids.isSelectorPart(params.provider_id)) return error.BadProviderId;

    if (try runtime.store.edit(arena, params.provider_id, .remove_credential)) runtime.announceCatalogChanged();
    runtime.announceAuthChanged(params.provider_id, null);
    return .{};
}

/// Report the flows one provider accepts. Only a catalog row naming a known flow offers one.
/// Report which credential one entry holds. An entry that holds none reports null.
fn localEntry(runtime: *const App, provider_id: []const u8) ?provider_config.LocalProvider {
    const loaded = runtime.store.local orelse return null;
    for (loaded.providers) |p| if (std.mem.eql(u8, p.id, provider_id)) return p;
    return null;
}

/// Report the credential of a provider the file never names. Only the environment can supply one.
fn discoveredKind(row: provider_registry.Provider) ?proto.enums.AuthCredentialKind {
    return if (row.availability == .ready) .api_key else null;
}

fn credentialKind(p: provider_config.LocalProvider) ?proto.enums.AuthCredentialKind {
    return switch (p.auth orelse return null) {
        .api_key => |key| if (key.source == null) null else .api_key,
        .oauth => .oauth,
    };
}

const testing = std.testing;

test "auth.list reports the providers the environment offers, not only the file" {
    const zio = @import("zio");
    const database = @import("../store/store.zig");
    const rt = try zio.Runtime.init(testing.allocator, .{ .executors = .exact(1) });
    defer rt.deinit();

    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try env.put("ANTHROPIC_API_KEY", "sk-env");

    var transport = ai.transport.CannedTransport{ .bytes = ai.transport.canned_reply };
    var blobs = std.testing.tmpDir(.{});
    defer blobs.cleanup();
    var blob_dir: [std.fs.max_path_bytes]u8 = undefined;
    var runtime: App = undefined;
    try runtime.initTest(testing.allocator, rt.io(), try database.Database.openTest(), blob_dir[0..try blobs.dir.realPath(testing.io, &blob_dir)], execution.testContext(&env), transport.transport());
    defer runtime.deinit();
    _ = try runtime.store.rebuild();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const result = try authList(&runtime, arena.allocator(), .{});

    var anthropic: ?proto.auth.AuthProvider = null;
    var codex: ?proto.auth.AuthProvider = null;
    for (result.providers) |p| {
        if (std.mem.eql(u8, p.provider_id, "anthropic")) anthropic = p;
        if (std.mem.eql(u8, p.provider_id, "openai-codex")) codex = p;
    }

    // `providers.json` names neither of these, so before discovery the list was empty.
    try testing.expectEqual(proto.enums.AuthCredentialKind.api_key, anthropic.?.credential_kind.?);
    try testing.expect(!anthropic.?.can_login);

    // A grant provider holds no credential yet, and it must still advertise its login.
    try testing.expect(codex.?.credential_kind == null);
    try testing.expect(codex.?.can_login);
}

test "catalog.reload reads the file again and reports whether the revision moved" {
    const zio = @import("zio");
    const database = @import("../store/store.zig");
    const rt = try zio.Runtime.init(testing.allocator, .{ .executors = .exact(1) });
    defer rt.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    var transport = ai.transport.CannedTransport{ .bytes = ai.transport.canned_reply };
    var blobs = std.testing.tmpDir(.{});
    defer blobs.cleanup();
    var blob_dir: [std.fs.max_path_bytes]u8 = undefined;
    var runtime: App = undefined;
    try runtime.initTest(testing.allocator, rt.io(), try database.Database.openTest(), blob_dir[0..try blobs.dir.realPath(testing.io, &blob_dir)], execution.testContext(&env), transport.transport());
    defer runtime.deinit();
    _ = try runtime.store.rebuild();

    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(rt.io(), &dir_buf)];
    runtime.store.path = try std.fs.path.join(testing.allocator, &.{ dir, "providers.json" });
    const path = runtime.store.path.?;

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var sink: CatalogSink = .{};
    runtime.engine.sinks.add(.{ .ctx = &sink, .on_event = CatalogSink.onEvent });

    // Another process wrote a provider the running engine never saw.
    try provider_config.writeFileBytes(rt.io(), path,
        \\{"version":1,"providers":[{"id":"local","base_url":"http://127.0.0.1:1/v1","protocol":"openai_chat",
        \\ "models":[{"id":"m","upstream_id":"m","reasoning_levels":[]}]}]}
    );
    const first = try catalogReload(&runtime, a, .{});
    try testing.expect(first.changed);
    try testing.expectEqual(@as(usize, 1), sink.changed);
    try testing.expect(provider_registry.find(runtime.store.merged.rows, "local") != null);
    try testing.expect(std.mem.eql(u8, &first.catalog_rev.raw, &runtime.store.merged.revision.raw));

    // The same bytes again produce the same revision.
    try testing.expect(!(try catalogReload(&runtime, a, .{})).changed);

    // A broken file never replaces the layer in memory.
    try provider_config.writeFileBytes(rt.io(), path, "{\"version\":1,\"providers\":[{\"id\":");
    try testing.expectError(error.BadProvidersFile, catalogReload(&runtime, a, .{}));
    try testing.expect(provider_registry.find(runtime.store.merged.rows, "local") != null);
    try testing.expectEqual(@as(usize, 1), sink.changed); // The unchanged and the failed reload stayed quiet.
}

/// Count the catalog announcements one reload test triggers.
const CatalogSink = struct {
    changed: usize = 0,

    fn onEvent(ctx: *anyopaque, note: proto.rpc.Notification) void {
        const self: *CatalogSink = @ptrCast(@alignCast(ctx));
        if (note.method == .@"catalog.changed") self.changed += 1;
    }
};
