//! Request handlers. Each builds a wire result from the stores.
//! Each handler owns its write transaction.

const std = @import("std");
const wire = @import("wire");
const State = @import("State.zig");
const database = @import("../database/database.zig");
const run = @import("../engine/run.zig");
const run_task = @import("run_task.zig");
const session_events = @import("session_events.zig");
const session_runtime = @import("session_runtime.zig");
const domain_session = @import("domain").session;
const paths = @import("../paths/paths.zig");
const host_mod = @import("../host/host.zig");
const local_host = @import("../host/local.zig");
const provider_config = @import("../provider/config/providers.zig");
const provider_registry = @import("registry.zig");
const catalog_store = @import("../catalog/store.zig");
const catalog_feed = @import("../catalog/feed.zig");
const provider_oauth = @import("../provider/provider.zig").oauth;
const login_runtime = @import("login_runtime.zig");
const login_task = @import("login_task.zig");
const net_http = @import("../net/http.zig");

const session_store = database.session;
const workspace_store = database.workspace;
const message_store = database.message;
const config_store = database.config;
const input_store = database.input;

const cursor_version: u8 = 1;
const cursor_raw_size = 33;

/// Build a selector fingerprint from its complete canonical 35-byte layout.
fn selectorFingerprint(sel: session_store.Selector) u64 {
    var canon = [_]u8{0} ** 35;
    if (sel.workspace_id) |workspace_id| {
        canon[0] = 1;
        @memcpy(canon[1..17], &workspace_id);
    }
    if (sel.parent_id) |parent_id| {
        canon[17] = 1;
        @memcpy(canon[18..34], &parent_id);
    }
    canon[34] = @intFromBool(sel.top_level);
    return std.hash.Wyhash.hash(0, &canon);
}

fn encodeCursor(arena: std.mem.Allocator, sel: session_store.Selector, cursor: session_store.Cursor) ![]const u8 {
    var raw = [_]u8{0} ** cursor_raw_size;
    raw[0] = cursor_version;
    std.mem.writeInt(u64, raw[1..9], selectorFingerprint(sel), .big);
    std.mem.writeInt(u64, raw[9..17], cursor.updated_at_ms, .big);
    @memcpy(raw[17..33], &cursor.id);

    const encoded = try arena.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(raw.len));
    _ = std.base64.url_safe_no_pad.Encoder.encode(encoded, &raw);
    return encoded;
}

fn decodeCursor(sel: session_store.Selector, encoded: []const u8) !session_store.Cursor {
    const decoded_size = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(encoded) catch return error.BadCursor;
    if (decoded_size != cursor_raw_size) return error.BadCursor;

    var raw: [cursor_raw_size]u8 = undefined;
    std.base64.url_safe_no_pad.Decoder.decode(&raw, encoded) catch return error.BadCursor;
    if (raw[0] != cursor_version) return error.BadCursor;
    if (std.mem.readInt(u64, raw[1..9], .big) != selectorFingerprint(sel)) return error.BadCursor;

    var id: [16]u8 = undefined;
    @memcpy(&id, raw[17..33]);
    return .{ .updated_at_ms = std.mem.readInt(u64, raw[9..17], .big), .id = id };
}

fn sessionSelector(params: wire.session.SessionListParams) session_store.Selector {
    var sel: session_store.Selector = .{};
    switch (params.scope) {
        .all => {},
        .workspace => |workspace| sel.workspace_id = workspace.workspace_id.raw,
    }
    switch (params.population) {
        .top_level => sel.top_level = true,
        .children => |children| sel.parent_id = children.parent_id.raw,
        .all => {},
    }
    return sel;
}

/// Handle session.list from durable state. Each item reports idle activity.
pub fn sessionList(state: *State, arena: std.mem.Allocator, params: wire.session.SessionListParams) !wire.session.SessionListResult {
    const sel = sessionSelector(params);
    const requested_limit = params.limit orelse wire.meta.limits.default_session_list_page_size;
    const effective_limit = std.math.clamp(requested_limit, 1, wire.meta.limits.max_session_list_page_size);
    const cursor = if (params.cursor) |encoded| try decodeCursor(sel, encoded) else null;
    const rows = try session_store.list(&state.db, arena, sel, cursor, @intCast(effective_limit + 1));
    const has_next = rows.len > effective_limit;
    const kept = rows[0..@min(rows.len, @as(usize, @intCast(effective_limit)))];
    const next_cursor = if (has_next) try encodeCursor(arena, sel, .{
        .updated_at_ms = kept[kept.len - 1].updated_at_ms,
        .id = kept[kept.len - 1].id,
    }) else null;
    const items = try arena.alloc(wire.session.SessionListItem, kept.len);
    for (kept, 0..) |row, i| items[i] = try session_events.sessionItem(arena, row);

    return .{
        .revision = state.session_revision,
        .items = items,
        .next_cursor = next_cursor,
        .total = try session_store.count(&state.db, arena, sel),
    };
}

test "session list cursor round-trips and binds to its selector" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const selector: session_store.Selector = .{
        .workspace_id = [_]u8{1} ** 16,
        .parent_id = [_]u8{2} ** 16,
        .top_level = true,
    };
    const expected: session_store.Cursor = .{ .updated_at_ms = 123, .id = [_]u8{3} ** 16 };
    const encoded = try encodeCursor(a, selector, expected);
    const actual = try decodeCursor(selector, encoded);
    try std.testing.expectEqual(expected.updated_at_ms, actual.updated_at_ms);
    try std.testing.expectEqualSlices(u8, &expected.id, &actual.id);

    var different = selector;
    different.top_level = false;
    try std.testing.expectError(error.BadCursor, decodeCursor(different, encoded));
}

/// Handle initialize: report the daemon snapshot. The session revision starts at 0 each run because
/// it lives in memory. The catalog revision waits for the catalog slice.
pub fn initialize(state: *State, arena: std.mem.Allocator) !wire.misc.InitializeResult {
    const stored = try workspace_store.list(&state.db, arena);
    const workspaces = try arena.alloc(wire.workspace.Workspace, stored.len);
    for (stored, 0..) |ws, i| {
        const kind = std.meta.stringToEnum(wire.enums.WorkspaceKind, ws.kind) orelse return error.CorruptDatabase;
        workspaces[i] = .{ .id = .bytes(ws.id), .kind = kind, .root = ws.root, .title = ws.title };
    }
    return .{
        .protocol = wire.meta.protocol_version,
        .daemon = .{ .version = State.daemon_version, .server_now_ms = state.nowMillis() },
        .workspaces = workspaces,
        .profiles = &.{},
        .agents = &.{},
        .session_revision = state.session_revision,
        .catalog_rev = state.store.merged.revision,
        .capabilities = &.{},
    };
}

/// Handle catalog.list: return every configured provider and its models, or nothing when the
/// client already holds this revision. A signed-out user with a local key still picks a model.
pub fn catalogList(state: *State, _: std.mem.Allocator, params: wire.catalog.CatalogListParams) !wire.catalog.CatalogListResult {
    const current = state.store.merged.revision;
    if (params.since_rev) |since| {
        if (std.mem.eql(u8, &since.raw, &current.raw)) return .{ .unchanged = .{ .catalog_rev = current } };
    }
    return .{ .full = .{
        .catalog_rev = current,
        .providers = state.store.merged.providers,
        .models = state.store.merged.models,
    } };
}

/// Handle auth.list: report the credential state of every local provider.
/// The cloud owns account credentials, so the account bundle is not listed here.
pub fn authList(state: *State, arena: std.mem.Allocator, _: wire.misc.Empty) !wire.auth.AuthListResult {
    var out: std.ArrayList(wire.auth.AuthProvider) = .empty;
    const loaded = state.store.local orelse return .{ .providers = &.{} };
    for (loaded.providers) |p| try out.append(arena, .{
        .provider_id = p.id,
        .credential_kind = credentialKind(p),
        .login_flows = loginFlows(state, p.id),
    });
    return .{ .providers = out.items };
}

/// Handle auth.set_api_key: store one literal key and rebuild the snapshot.
/// The entry keeps every other field, so a hand-written route survives a key change.
pub fn authSetApiKey(state: *State, arena: std.mem.Allocator, params: wire.auth.AuthSetApiKeyParams) !wire.misc.Empty {
    if (!wire.ids.isSelectorPart(params.provider_id)) return error.BadProviderId;
    if (params.api_key.len == 0) return error.BadApiKey;

    if (try state.store.edit(arena, params.provider_id, .{ .set_api_key = params.api_key }, &state.db)) state.announceCatalogChanged();
    state.announceAuthChanged(params.provider_id, .api_key);
    return .{};
}

/// Handle auth.login: get a code, then poll in a task that outlives this connection.
pub fn authLogin(state: *State, arena: std.mem.Allocator, params: wire.auth.AuthLoginParams) !wire.auth.AuthLoginResult {
    if (!wire.ids.isSelectorPart(params.provider_id)) return error.BadProviderId;
    if (state.shutting_down) return error.Unavailable;
    // One provider holds one login, so a second attempt would race the first for the same grant.
    if (state.logins.byProvider(params.provider_id) != null) return error.LoginInProgress;

    const row = try catalog_store.provider(&state.db, arena, params.provider_id) orelse return error.UnknownProvider;
    const flow = login_runtime.Flow.parse(flowName(row.auth) orelse return error.NoLoginFlow) orelse return error.NoLoginFlow;

    // The slot arena owns the code and the url, because the login outlives this request arena.
    var slot_arena: std.heap.ArenaAllocator = .init(state.gpa);
    const owned_id = slot_arena.allocator().dupe(u8, params.provider_id) catch |err| {
        slot_arena.deinit();
        return err;
    };

    // Reserve before the network call, because `start` yields and a second request would pass
    // the check above. The registry owns the arena from here, so one `remove` frees everything.
    const login_id: wire.ids.LoginId = .bytes(state.newId() ++ state.newId());
    const slot = state.logins.reserve(login_id, slot_arena, owned_id, flow) catch |err| {
        slot_arena.deinit();
        return err;
    };
    errdefer state.logins.remove(login_id);

    var client: net_http.Client = .init(state.gpa, state.io, .none);
    defer client.deinit();
    var real: provider_oauth.ClientHttp = .{ .client = &client };
    const body = try arena.alloc(u8, net_http.max_oauth_response_bytes);
    slot.start = try login_task.start(slot.arena.allocator(), state.oauth_http orelse real.seam(), flow, body);

    try state.tasks.concurrent(state.io, login_task.run, .{ state, slot });
    return .{ .login_id = login_id, .user_code = slot.start.user_code, .verification_url = slot.start.verification_url };
}

/// Handle auth.cancel_login: mark the login canceled, then wake it so it stops before its next poll.
pub fn authCancelLogin(state: *State, _: std.mem.Allocator, params: wire.auth.AuthCancelLoginParams) !wire.misc.Empty {
    // A cancel for a login that already finished is not an error, so a retry stays harmless.
    const slot = state.logins.get(params.login_id) orelse return .{};
    if (slot.finalizing) return .{}; // The grant is already landing, so the outcome stands.
    if (!slot.cancel_requested) {
        slot.cancel_requested = true;
        slot.wake_event.set(state.io);
    }
    return .{};
}

/// Handle auth.remove: drop the credential the daemon holds for one provider.
pub fn authRemove(state: *State, arena: std.mem.Allocator, params: wire.auth.AuthRemoveParams) !wire.misc.Empty {
    if (!wire.ids.isSelectorPart(params.provider_id)) return error.BadProviderId;

    if (try state.store.edit(arena, params.provider_id, .remove_credential, &state.db)) state.announceCatalogChanged();
    state.announceAuthChanged(params.provider_id, null);
    return .{};
}

/// Report the flow one catalog row names. Only an OAuth provider names one.
fn flowName(auth: ?catalog_feed.Auth) ?[]const u8 {
    const named = auth orelse return null;
    return if (named.kind == .oauth) named.flow else null;
}

/// Report the flows one provider accepts. Only a catalog row naming a known flow offers one.
fn loginFlows(state: *State, provider_id: []const u8) []const wire.enums.AuthFlow {
    const row = provider_registry.find(state.store.merged.rows, provider_id) orelse return &.{};
    const name = row.login_flow orelse return &.{};
    if (login_runtime.Flow.parse(name) == null) return &.{};
    return &.{.device_code};
}

/// Report which credential one entry holds. An entry that holds none reports null.
fn credentialKind(p: provider_config.LocalProvider) ?wire.enums.AuthCredentialKind {
    return switch (p.auth orelse return null) {
        .api_key => |key| if (key.source == null) null else .api_key,
        .oauth => .oauth,
    };
}

/// Report whether an entry carries only its credential, so removing that leaves nothing to keep.
fn onlyCredential(p: provider_config.LocalProvider) bool {
    if (p.base_url != null or p.protocol != null or p.cache != null) return false;
    if (p.responses_dialect != null or p.headers != null or p.models.len != 0) return false;
    // A keyless entry states that the route needs nothing, so it is configuration.
    // A named header and a declared want are both configuration the user wrote.
    return switch (p.auth orelse return false) {
        .api_key => |key| key.header == null and key.source != null,
        .oauth => true,
    };
}

/// Render the layer, parse it, then write it. A document that cannot load never reaches the file.
fn writeProviders(state: *State, path: []const u8, providers: []const provider_config.LocalProvider) !void {
    const bytes = try provider_config.serialize(state.gpa, providers);
    defer state.gpa.free(bytes);

    var next = try provider_config.loadBytes(state.gpa, bytes);
    errdefer next.deinit();
    try provider_config.writeFileBytes(state.io, path, bytes);
    if (try state.installProviders(&next)) state.announceCatalogChanged();
}

/// Handle session.config: return one config revision and the session's system prompt.
/// Return the current config for a null config_rev. Return UnknownConfigRev for an absent revision.
pub fn sessionConfig(state: *State, arena: std.mem.Allocator, params: wire.session.SessionConfigParams) !wire.session.SessionConfigResult {
    const sid = params.session_id.raw;
    const snap = (try session_store.snapshot(&state.db, arena, sid)) orelse return error.UnknownSession;
    const config: wire.run.RunConfig = if (params.config_rev) |rev|
        (try config_store.byRevision(&state.db, arena, sid, rev)) orelse return error.UnknownConfigRev
    else
        .{ .config_rev = snap.config_rev, .model = snap.model, .reasoning = snap.reasoning };
    return .{ .config = config, .system_prompt = try session_store.prompt(&state.db, arena, sid) };
}

/// Handle session.history: return a page of committed messages oldest first, the configs those
/// assistant turns reference, and whether older messages remain.
pub fn sessionHistory(state: *State, arena: std.mem.Allocator, params: wire.session.SessionHistoryParams) !wire.session.SessionHistoryResult {
    const sid = params.session_id.raw;
    if (!try session_store.exists(&state.db, arena, sid)) return error.UnknownSession;
    const requested = params.limit orelse wire.meta.limits.default_page_size;
    const limit: usize = @intCast(std.math.clamp(requested, 1, wire.meta.limits.max_page_size));
    const page = try message_store.historyPage(&state.db, arena, sid, params.before_message_id, limit);
    return .{
        .session_id = params.session_id,
        .messages = page.messages,
        .configs = try config_store.forMessages(&state.db, arena, sid, page.messages),
        .has_more = page.has_more,
    };
}

/// Handle session.resync: return the full session snapshot plus the live tail for a reconnect.
/// A resident runtime serializes its live projection. An idle session hydrates a transient one.
pub fn sessionResync(state: *State, arena: std.mem.Allocator, params: wire.session.SessionResyncParams) !wire.session.SessionResyncResult {
    if (params.limit) |lim| {
        if (lim == 0 or lim > wire.meta.limits.max_page_size) return error.BadRequest; // The daemon does not clamp.
    }
    const limit: usize = @intCast(params.limit orelse wire.meta.limits.default_page_size);
    const sid = params.session_id.raw;
    const snap = (try session_store.snapshot(&state.db, arena, sid)) orelse return error.UnknownSession;

    if (state.sessions.get(params.session_id)) |rt| {
        const run_info: ?session_events.RunInfo = if (rt.active) |slot| .{ .run_id = slot.handle.started.run_id, .started_at_ms = slot.handle.started.started_at_ms, .retry = slot.retry_state } else null;
        return serializeResync(state, arena, snap, &rt.session, run_info, limit);
    }
    // The session is idle. Hydrate a transient projection, serialize it, then release it.
    var transient = domain_session.Session.init(state.gpa, params.session_id);
    defer transient.deinit();
    try state.hydrateSession(&transient);
    return serializeResync(state, arena, snap, &transient, null, limit);
}

/// Serialize a session projection into the resync result. Deep-copy so a transient session can release.
fn serializeResync(state: *State, arena: std.mem.Allocator, snap: anytype, session: *domain_session.Session, run_info: ?session_events.RunInfo, limit: usize) !wire.session.SessionResyncResult {
    var item = try session_events.sessionItem(arena, snap);
    item.activity = try session_events.sessionActivity(state, arena, snap.id, session, run_info, session_events.contextUsage(snap));

    // The committed window returns its newest `limit` messages, oldest-first.
    const all = try session.committed.messages(arena);
    const start = if (all.len > limit) all.len - limit else 0;
    const messages = try wire.dupe(arena, all[start..]);
    const has_more = session.committed.has_more or start > 0;

    // Gather a config for every assistant message in the window, plus the active draft, from SQLite.
    // The live config set only tracks config.changed events, so it can miss a live commit.
    var configs: std.ArrayList(wire.run.RunConfig) = .empty;
    for (messages) |m| switch (m) {
        .assistant => |asst| try config_store.ensureRevision(&state.db, arena, &configs, snap.id, asst.config_rev),
        else => {},
    };
    if (session.active) |*d| try config_store.ensureRevision(&state.db, arena, &configs, snap.id, d.config_rev);

    const active: ?wire.message.ActiveDraft = if (session.active) |*d| try wire.dupe(arena, try d.toActiveDraft(arena)) else null;

    const entries = session.queue.entries();
    const queued = try arena.alloc(wire.misc.QueuedInput, entries.len);
    for (entries, queued) |*e, *out| out.* = try wire.dupe(arena, wire.misc.QueuedInput{ .input_id = e.input_id, .content = e.content, .queued_at_ms = e.queued_at_ms });

    return .{
        .item = item,
        .base_seq = session.base_seq,
        .highest_finalized_message_id = finalizedHighWater(session),
        .messages = messages,
        .has_more = has_more,
        .configs = configs.items,
        .active = active,
        .queued = queued,
    };
}

/// Return the finalized high-water for resync, or null for a session with no finalized message.
/// A truncation or a discard can raise this above the newest committed id.
fn finalizedHighWater(session: *domain_session.Session) ?wire.ids.MessageId {
    return if (session.finalized_message_id == 0) null else session.finalized_message_id;
}

/// Accept input for an RPC and return its prepared run to the response gate.
pub fn sessionSendInputForRpc(state: *State, arena: std.mem.Allocator, params: wire.session.SessionSendInputParams, launch: *?run_task.Launch) !wire.session.SessionSendInputResult {
    std.debug.assert(launch.* == null);
    const content = switch (params.input) {
        .content => |c| c.content,
        .skill => return error.SkillUnsupported,
    };
    const sid = params.session_id.raw;
    const snapshot = (try session_store.snapshot(&state.db, arena, sid)) orelse return error.UnknownSession;
    const rt = try state.activate(params.session_id);
    if (rt.faulted) return error.RuntimeFailed;
    if (rt.active == null and rt.session.queue.depth() > 0) launch.* = .{ .slot = try run_task.prepareQueued(state, rt) };

    if (rt.active == null) {
        const stored_prompt = try session_store.prompt(&state.db, arena, sid);
        const slot = try session_runtime.RunSlot.prepare(state.gpa, snapshot.model, snapshot.reasoning, stored_prompt orelse "", snapshot.max_rounds);
        errdefer slot.destroy();
        const started = try run.beginTurn(&state.db, state.io, arena, sid, content, snapshot.config_rev);
        slot.bind(started.handle, started.first_round);
        rt.active = slot;
        launch.* = .{ .slot = slot };
        // Fold each durable event in sequence order: the user message, then run.started.
        session_events.publishUserCommits(state, rt, started.user_commits);
        session_events.emitDurable(state, rt, .{ .method = .@"run.started", .params = .{ .run_started_data = started.handle.started } });
        return .{ .started = .{ .input_id = started.handle.input_id, .run_id = started.handle.started.run_id } };
    }

    // A run is active. Persist and fold the queued input before the response.
    if (rt.session.queue.depth() >= wire.meta.limits.max_queued_inputs) return error.QueueFull;
    const now = state.nowMillis();
    var tx = try state.db.begin();
    defer tx.deinit();
    const queued = try input_store.enqueue(&state.db, arena, sid, state.newId(), now, content, now);
    try tx.commit();
    session_events.emitDurable(state, rt, .{ .method = .@"input.queued", .params = .{
        .input_queued_data = .{ .session_id = params.session_id, .seq = queued.seq, .input = queued.input },
    } });
    session_events.announceActivity(state, rt);
    return .{ .queued = .{ .input_id = queued.input.input_id } };
}

/// Cancel one exact queued input. A started input belongs to the active run.
pub fn sessionCancelInput(state: *State, arena: std.mem.Allocator, params: wire.session.SessionCancelInputParams) !wire.session.SessionCancelInputResult {
    const sid = params.session_id.raw;
    if (!try session_store.exists(&state.db, arena, sid)) return error.UnknownSession;
    const rt = try state.activate(params.session_id);

    const now = state.nowMillis();
    var tx = try state.db.begin();
    defer tx.deinit();
    const canceled = input_store.cancel(&state.db, arena, sid, state.newId(), now, params.input_id) catch |err| switch (err) {
        error.NoRow => return error.UnknownInput,
        else => return err,
    };
    try tx.commit();
    session_events.emitDurable(state, rt, .{ .method = .@"input.canceled", .params = .{
        .input_canceled_data = .{ .session_id = params.session_id, .seq = canceled, .input_id = params.input_id },
    } });
    session_events.announceActivity(state, rt); // The queue is shorter. Announce before an evict frees `rt`.
    state.sessions.evictIfIdle(params.session_id);
    return .{ .canceled_input = params.input_id };
}

/// Request cancellation of the active run. Clear the durable queue only when requested.
pub fn sessionCancelRun(state: *State, arena: std.mem.Allocator, params: wire.session.SessionCancelRunParams) !wire.session.SessionCancelRunResult {
    const sid = params.session_id.raw;
    if (!try session_store.exists(&state.db, arena, sid)) return error.UnknownSession;
    const rt = try state.activate(params.session_id);

    const active = rt.active;
    if (params.run_id) |expected| {
        if (active == null or active.?.handle.started.run_id != expected) return error.RunMismatch;
    }

    var cleared_inputs: []wire.ids.InputId = &.{};
    if (params.clear_queue orelse false) {
        const pending = try input_store.list(&state.db, arena, sid);
        cleared_inputs = try arena.alloc(wire.ids.InputId, pending.len);
        const cleared_seqs = try arena.alloc(wire.ids.Seq, pending.len);
        const now = state.nowMillis();
        var tx = try state.db.begin();
        defer tx.deinit();
        for (pending, 0..) |entry, i| {
            cleared_inputs[i] = entry.input.input_id;
            const canceled = try input_store.cancel(&state.db, arena, sid, state.newId(), now, entry.input.input_id);
            cleared_seqs[i] = canceled;
        }
        try tx.commit();
        for (cleared_inputs, cleared_seqs) |input_id, seq| {
            session_events.emitDurable(state, rt, .{ .method = .@"input.canceled", .params = .{
                .input_canceled_data = .{ .session_id = params.session_id, .seq = seq, .input_id = input_id },
            } });
        }
        if (cleared_inputs.len > 0) session_events.announceActivity(state, rt);
    }

    const canceled_run = if (active) |slot| slot.handle.started.run_id else null;
    if (active) |slot| {
        if (!slot.cancel_requested) {
            slot.cancel_requested = true;
            slot.wake_event.set(state.io); // Wake the run task so it cancels its reader.
        }
    }
    if (active == null) state.sessions.evictIfIdle(params.session_id);
    return .{ .canceled_run = canceled_run, .cleared_inputs = cleared_inputs };
}

/// Collect the session and, with `cascade`, each session below it. The walk follows parent_id.
fn removalSet(state: *State, arena: std.mem.Allocator, root: [16]u8, cascade: bool) ![]const [16]u8 {
    var out: std.ArrayList([16]u8) = .empty;
    try out.append(arena, root);
    if (!cascade) return out.items;
    // A parent_id chain forms a tree, so a repeated id means a corrupt row.
    var seen: std.AutoHashMapUnmanaged([16]u8, void) = .empty;
    try seen.put(arena, root, {});
    var frontier: usize = 0;
    while (frontier < out.items.len) : (frontier += 1) {
        for (try session_store.childIds(&state.db, arena, out.items[frontier])) |child| {
            if ((try seen.getOrPut(arena, child)).found_existing) return error.CorruptDatabase;
            try out.append(arena, child);
        }
    }
    return out.items;
}

/// Handle session.remove: delete the session and, with `cascade_children`, its children.
pub fn sessionRemove(state: *State, arena: std.mem.Allocator, params: wire.session.SessionRemoveParams) !wire.misc.Empty {
    const sid = params.session_id.raw;
    if (!try session_store.exists(&state.db, arena, sid)) return error.UnknownSession;

    // A child points into the parent transcript, so it cannot outlive its parent.
    if (!params.cascade_children and (try session_store.childIds(&state.db, arena, sid)).len > 0)
        return error.SessionHasChildren;

    const doomed = try removalSet(state, arena, sid, params.cascade_children);
    // Check each session before the first delete, so a busy child leaves no partial removal.
    for (doomed) |id| {
        const rt = state.sessions.get(.bytes(id)) orelse continue;
        if (rt.active != null) return error.SessionBusy;
    }

    var tx = try state.db.begin();
    defer tx.deinit();
    for (doomed) |id| try session_store.remove(&state.db, id);
    try tx.commit();

    // Announce the deepest session first, so a client tree holds no orphan.
    var i = doomed.len;
    while (i > 0) {
        i -= 1;
        const id: wire.ids.SessionId = .bytes(doomed[i]);
        state.sessions.remove(id);
        session_events.announceRemoved(state, id);
    }
    return .{};
}

const browse_cursor_version: u8 = 1;
const browse_cursor_head = 9; // one version byte and one 64-bit path fingerprint
const git_head_max_bytes: u32 = 4096;

/// Build the picker host. The local backend uses the home directory as its root.
fn pickerHost(state: *State, backend: *local_host.LocalHost) host_mod.Host {
    if (state.tool_host) |installed| return installed;
    backend.* = .{ .io = state.io, .root = state.home, .env = state.env };
    return backend.host();
}

/// Store a directory fingerprint in each browse cursor.
fn browseFingerprint(path: []const u8) u64 {
    return std.hash.Wyhash.hash(0, path);
}

fn encodeBrowseCursor(arena: std.mem.Allocator, path: []const u8, after: []const u8) ![]const u8 {
    const raw = try arena.alloc(u8, browse_cursor_head + after.len);
    raw[0] = browse_cursor_version;
    std.mem.writeInt(u64, raw[1..9], browseFingerprint(path), .big);
    @memcpy(raw[browse_cursor_head..], after);
    const size = std.base64.url_safe_no_pad.Encoder.calcSize(raw.len);
    std.debug.assert(size <= wire.meta.limits.max_fs_browse_cursor_bytes);
    const encoded = try arena.alloc(u8, size);
    _ = std.base64.url_safe_no_pad.Encoder.encode(encoded, raw);
    return encoded;
}

fn decodeBrowseCursor(arena: std.mem.Allocator, path: []const u8, encoded: []const u8) ![]const u8 {
    // Measure the peer cursor before the decode allocates for it.
    if (encoded.len > wire.meta.limits.max_fs_browse_cursor_bytes) return error.BadCursor;
    const size = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(encoded) catch return error.BadCursor;
    if (size <= browse_cursor_head) return error.BadCursor;
    const raw = try arena.alloc(u8, size);
    std.base64.url_safe_no_pad.Decoder.decode(raw, encoded) catch return error.BadCursor;
    if (raw[0] != browse_cursor_version) return error.BadCursor;
    if (std.mem.readInt(u64, raw[1..9], .big) != browseFingerprint(path)) return error.BadCursor;
    return raw[browse_cursor_head..];
}

/// Read the HEAD text. A worktree stores `.git` as a file that names the real Git directory.
fn readHead(arena: std.mem.Allocator, backend: host_mod.Host, dir_path: []const u8) !?[]const u8 {
    const marker = try std.fs.path.join(arena, &.{ dir_path, ".git" });
    const head_path = try std.fs.path.join(arena, &.{ marker, "HEAD" });
    if (backend.readAll(arena, head_path, git_head_max_bytes)) |text| return text else |err| switch (err) {
        error.NotFound, error.NotAFile => {},
        else => return err,
    }
    const link = backend.readAll(arena, marker, git_head_max_bytes) catch |err| switch (err) {
        error.NotFound, error.NotAFile => return null,
        else => return err,
    };
    const prefix = "gitdir: ";
    const line = std.mem.trimEnd(u8, link, "\r\n");
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    const git_dir = try std.fs.path.resolve(arena, &.{ dir_path, line[prefix.len..] });
    const linked_head = try std.fs.path.join(arena, &.{ git_dir, "HEAD" });
    return backend.readAll(arena, linked_head, git_head_max_bytes) catch |err| switch (err) {
        error.NotFound, error.NotAFile => null,
        else => err,
    };
}

/// Read the branch of a Git repository. Return null when the directory contains no `.git` entry.
fn gitInfo(arena: std.mem.Allocator, backend: host_mod.Host, dir_path: []const u8) !?wire.fs.GitInfo {
    const text = (try readHead(arena, backend, dir_path)) orelse return null;
    const prefix = "ref: refs/heads/";
    const line = std.mem.trimEnd(u8, text, "\r\n");
    if (!std.mem.startsWith(u8, line, prefix)) return .{}; // a detached HEAD holds a raw commit id
    return .{ .branch = line[prefix.len..] };
}

/// Handle fs.stat: describe one path. A path that does not exist returns no entry.
pub fn fsStat(state: *State, arena: std.mem.Allocator, params: wire.fs.FsStatParams) !wire.fs.FsStatResult {
    var local: local_host.LocalHost = undefined;
    const backend = pickerHost(state, &local);
    const path = paths.canonicalizeWorkspace(arena, state.env, params.path) catch return error.BadPath;
    const info = backend.stat(arena, path) catch |err| switch (err) {
        error.NotFound => return .{ .path = path },
        error.AccessDenied, error.NotAFile, error.InvalidUtf8, error.TooLarge => return error.BadPath,
        else => return err, // Canceled and HostFailure are operating errors, not bad input.
    };
    return .{ .path = path, .entry = .{
        .is_dir = info.is_dir,
        .last_modified_ms = info.last_modified_ms,
        .git = if (info.is_dir) try gitInfo(arena, backend, path) else null,
    } };
}

/// Handle fs.browse: list one page of a directory for the workspace picker.
pub fn fsBrowse(state: *State, arena: std.mem.Allocator, params: wire.fs.FsBrowseParams) !wire.fs.FsBrowseResult {
    var local: local_host.LocalHost = undefined;
    const backend = pickerHost(state, &local);
    const path = paths.canonicalizeWorkspace(arena, state.env, params.path orelse state.home) catch return error.BadPath;
    const after = if (params.cursor) |cursor| try decodeBrowseCursor(arena, path, cursor) else null;
    const requested = params.limit orelse wire.meta.limits.default_fs_browse_page_size;
    if (requested == 0 or requested > wire.meta.limits.max_fs_browse_page_size) return error.BadRequest;
    const limit: u32 = @intCast(requested);

    const page = backend.listDir(arena, path, .{
        .after = after,
        .limit = limit,
        .include_files = params.include_files,
    }) catch |err| switch (err) {
        error.NotFound, error.AccessDenied, error.NotAFile, error.InvalidUtf8, error.TooLarge => return error.BadPath,
        else => return err, // Canceled and HostFailure are operating errors, not bad input.
    };

    const entries = try arena.alloc(wire.fs.DirEntry, page.items.len);
    for (page.items, entries) |item, *entry| entry.* = .{
        .name = item.name,
        .path = try std.fs.path.join(arena, &.{ path, item.name }),
        .is_dir = item.is_dir,
        .is_git_repo = item.is_git_repo,
    };
    return .{
        .path = path,
        .parent = std.fs.path.dirname(path),
        .entries = entries,
        .next_cursor = if (page.next_after) |name| try encodeBrowseCursor(arena, path, name) else null,
    };
}

/// Handle session.create: resolve the workspace, mint ids, insert the session, and return it.
pub fn sessionCreate(state: *State, arena: std.mem.Allocator, params: wire.misc.CreateSession) !wire.session.SessionResult {
    // Normalize the path so one directory maps to one workspace.
    const root = try paths.canonicalizeWorkspace(arena, state.env, params.workspace_path orelse state.home);
    const base = std.fs.path.basename(root);
    const title = if (base.len == 0) root else base;
    const profile = params.profile orelse "default";
    const model = params.model orelse "";
    const reasoning = params.reasoning orelse "";
    const permission = params.permission orelse .normal;
    const now = state.nowMillis();

    const workspace_id = state.newId();
    const id = state.newId();

    var tx = try state.db.begin();
    defer tx.deinit();
    const workspace = try workspace_store.resolve(&state.db, arena, workspace_id, root, title, root);
    try session_store.create(&state.db, .{
        .id = id,
        .workspace_id = workspace.id,
        .origin = "root",
        .profile = profile,
        .model = model,
        .reasoning = reasoning,
        .config_rev = 0,
        .permission = @tagName(permission),
        .max_rounds = params.max_rounds,
        .title = title,
        .created_at_ms = now,
        .updated_at_ms = now,
    });
    const system_prompt = params.system_prompt orelse state.defaults.system_prompt;
    if (system_prompt) |sys| try session_store.setPrompt(&state.db, id, sys);
    try config_store.recordInitial(&state.db, id, model, reasoning);
    try tx.commit();

    // Announce the new workspace and the session after the commit, never before it.
    if (workspace.created) session_events.announceWorkspaceCreated(state, .{
        .id = .bytes(workspace.id),
        .root = root,
        .title = title,
    });
    session_events.announceSummary(state, .bytes(id));

    return .{ .session = .{
        .id = .bytes(id),
        .workspace_id = .bytes(workspace.id),
        .profile = profile,
        .model = model,
        .reasoning = reasoning,
        .config_rev = 0,
        .permission = permission,
        .max_rounds = params.max_rounds,
        .title = title,
        .message_count = 0,
        .usage_total = .{ .input = 0, .output = 0, .reasoning = 0, .cache_read = 0, .cache_write = 0 },
        .created_at_ms = now,
        .updated_at_ms = now,
        .created_by = null,
        .origin = .{ .root = .{} },
        .agent = null,
    } };
}
