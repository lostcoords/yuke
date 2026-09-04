//! Process commands: the provider catalog, credentials, and the filesystem picker.
//! Each handler owns its write transaction.

const std = @import("std");
const proto = @import("proto");
const App = @import("app.zig").App;
const provider_config = @import("../provider/config/providers.zig");
const provider_ai = @import("../provider/provider.zig").ai;
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

/// Handle auth.list: report the credential runtime of every local provider.
pub fn authList(runtime: *App, arena: std.mem.Allocator, _: proto.misc.Empty) !proto.auth.AuthListResult {
    var out: std.ArrayList(proto.auth.AuthProvider) = .empty;
    const loaded = runtime.store.local orelse return .{ .providers = &.{} };
    for (loaded.providers) |p| try out.append(arena, .{
        .provider_id = p.id,
        .credential_kind = credentialKind(p),
        .can_login = runtime.canLogin(p.id),
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

    const row = provider_ai.catalog.find(params.provider_id) orelse return error.UnknownProvider;
    const flow = login_runtime.Flow.parse(flowName(row.auth) orelse return error.NoLoginFlow) orelse return error.NoLoginFlow;

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

    var client: net_http.Client = .init(runtime.gpa, runtime.io, .none);
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
    if (!slot.cancel_requested) {
        slot.cancel_requested = true;
        slot.wake_event.set(runtime.io);
    }
    return .{};
}

/// Handle auth.remove: drop the credential the engine holds for one provider.
pub fn authRemove(runtime: *App, arena: std.mem.Allocator, params: proto.auth.AuthRemoveParams) !proto.misc.Empty {
    if (!proto.ids.isSelectorPart(params.provider_id)) return error.BadProviderId;

    if (try runtime.store.edit(arena, params.provider_id, .remove_credential)) runtime.announceCatalogChanged();
    runtime.announceAuthChanged(params.provider_id, null);
    return .{};
}

/// Report the flow one catalog row names. Only an OAuth provider names one.
fn flowName(auth: provider_ai.catalog.Auth) ?[]const u8 {
    return switch (auth) {
        .oauth => |name| name,
        .api_key => null,
    };
}

/// Report the flows one provider accepts. Only a catalog row naming a known flow offers one.
/// Report which credential one entry holds. An entry that holds none reports null.
fn credentialKind(p: provider_config.LocalProvider) ?proto.enums.AuthCredentialKind {
    return switch (p.auth orelse return null) {
        .api_key => |key| if (key.source == null) null else .api_key,
        .oauth => .oauth,
    };
}
