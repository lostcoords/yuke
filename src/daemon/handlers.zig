//! Request handlers. Each builds a wire result from the stores.
//! Each handler owns its write transaction.

const std = @import("std");
const wire = @import("wire");
const State = @import("State.zig");
const database = @import("../database/database.zig");
const run = @import("../engine/run.zig");
const run_task = @import("run_task.zig");
const catalog_store = @import("../database/catalog.zig");
const provider_view = @import("provider_view.zig");
const session_runtime = @import("session_runtime.zig");
const domain_session = @import("domain").session;
const paths = @import("../paths/paths.zig");

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

/// Map a durable session row to its origin. A row that breaks the schema invariants is corrupt. The
/// boundary returns an error, so one request fails and the daemon stays alive.
fn sessionOrigin(row: anytype) !wire.session.SessionOrigin {
    if (std.mem.eql(u8, row.origin, "root")) {
        if (row.parent_id != null or row.parent_message_id != null or row.parent_part_id != null or row.source_id != null)
            return error.CorruptDatabase;
        return .{ .root = .{} };
    }
    if (std.mem.eql(u8, row.origin, "child")) {
        if (row.parent_id == null or row.parent_message_id == null or row.parent_part_id == null or row.source_id != null)
            return error.CorruptDatabase;
        return .{ .child = .{
            .parent_id = .bytes(row.parent_id.?),
            .parent_message_id = row.parent_message_id.?,
            .parent_part_id = row.parent_part_id.?,
        } };
    }
    if (std.mem.eql(u8, row.origin, "fork")) {
        if (row.parent_id != null or row.parent_message_id != null or row.parent_part_id != null or row.source_id == null)
            return error.CorruptDatabase;
        return .{ .fork = .{ .source_id = .bytes(row.source_id.?) } };
    }
    return error.CorruptDatabase;
}

pub fn sessionItem(arena: std.mem.Allocator, row: anytype) !wire.session.SessionListItem {
    const permission = std.meta.stringToEnum(wire.enums.PermissionMode, row.permission) orelse return error.CorruptDatabase;

    const created_by = if (row.created_by_name) |name| blk: {
        if (row.created_by_version == null) return error.CorruptDatabase;
        break :blk wire.initialize.Client{
            .name = try arena.dupe(u8, name),
            .version = try arena.dupe(u8, row.created_by_version.?),
        };
    } else blk: {
        if (row.created_by_version != null) return error.CorruptDatabase;
        break :blk null;
    };

    return .{
        .session = .{
            .id = .bytes(row.id),
            .workspace_id = .bytes(row.workspace_id),
            .profile = try arena.dupe(u8, row.profile),
            .model = try arena.dupe(u8, row.model),
            .reasoning = try arena.dupe(u8, row.reasoning),
            .config_rev = row.config_rev,
            .permission = permission,
            .max_rounds = row.max_rounds,
            .title = try arena.dupe(u8, row.title),
            .message_count = row.message_count,
            .usage_total = .{
                .input = row.usage_input_total,
                .output = row.usage_output_total,
                .reasoning = row.usage_reasoning_total,
                .cache_read = row.usage_cache_read_total,
                .cache_write = row.usage_cache_write_total,
            },
            .created_at_ms = row.created_at_ms,
            .updated_at_ms = row.updated_at_ms,
            .created_by = created_by,
            .origin = try sessionOrigin(row),
            .agent = if (row.agent) |text| try arena.dupe(u8, text) else null,
        },
        .activity = .{
            .state = .{ .idle = .{} },
            .config = null,
            .queued = 0,
            .context_usage = contextUsage(row),
            .pending_compaction = null,
        },
    };
}

/// The context gauge that `session_context` joined onto the row. A session with no committed
/// assistant turn joins to nulls, which report as zero.
fn contextUsage(row: anytype) wire.message.TokenUsage {
    return .{
        .input = row.ctx_tokens_input orelse 0,
        .output = row.ctx_tokens_output orelse 0,
        .reasoning = row.ctx_tokens_reasoning orelse 0,
        .cache_read = row.ctx_tokens_cache_read orelse 0,
        .cache_write = row.ctx_tokens_cache_write orelse 0,
    };
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
    for (kept, 0..) |row, i| items[i] = try sessionItem(arena, row);

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
        .daemon = .{ .version = "0.0.1", .server_now_ms = state.nowMillis() },
        .workspaces = workspaces,
        .profiles = &.{},
        .agents = &.{},
        .session_revision = state.session_revision,
        .catalog_rev = .bytes([_]u8{0} ** 64),
        .capabilities = &.{},
    };
}

/// The revision a client sees before the daemon stores a catalog.
const empty_catalog_rev: wire.ids.CatalogRev = .bytes(@splat(0));

/// Choose the effort a client uses when the user picks none. `medium` wins when the model offers it.
fn defaultReasoning(levels: []const []const u8) []const u8 {
    for (levels) |level| if (std.mem.eql(u8, level, "medium")) return level;
    return if (levels.len != 0) levels[0] else "";
}

/// Handle catalog.list: return every configured provider and its models, or nothing when the
/// client already holds this revision. A signed-out user with a local key still picks a model.
pub fn catalogList(state: *State, arena: std.mem.Allocator, params: wire.catalog.CatalogListParams) !wire.catalog.CatalogListResult {
    const current = try storedRev(state, arena);
    if (params.since_rev) |since| {
        if (std.mem.eql(u8, &since.raw, &current.raw)) return .{ .unchanged = .{ .catalog_rev = current } };
    }

    const rows = try provider_view.resolve(arena, .{
        .local = if (state.providers) |*loaded| loaded else null,
        .cloud = state.cloud_bundle,
        .catalog = try catalog_store.providers(&state.db, arena),
        .env = state.env,
    });

    var providers = try arena.alloc(wire.catalog.ProviderInfo, rows.len);
    var models: std.ArrayList(wire.catalog.ModelInfo) = .empty;
    for (rows, 0..) |row, i| {
        providers[i] = .{ .id = row.id, .name = row.name, .source = row.source, .state = row.state };
        for (row.models) |m| try models.append(arena, try modelInfo(arena, row.id, m));
    }
    return .{ .full = .{ .catalog_rev = current, .providers = providers, .models = models.items } };
}

/// Return the stored catalog revision. A daemon that never synced reports a zero revision.
/// A stored value is durable state, not an invariant, so a bad digest is an error.
fn storedRev(state: *State, arena: std.mem.Allocator) !wire.ids.CatalogRev {
    const stored = try catalog_store.rev(&state.db, arena) orelse return empty_catalog_rev;
    var raw: [wire.ids.CatalogRev.byte_len]u8 = undefined;
    const bytes = std.fmt.hexToBytes(&raw, stored) catch return error.CorruptCatalog;
    if (bytes.len != raw.len) return error.CorruptCatalog;
    return .bytes(raw);
}

/// Project one resolved model onto its wire shape. A value the source omits reads as zero,
/// because the wire keeps these fields required.
fn modelInfo(arena: std.mem.Allocator, provider_id: []const u8, m: provider_view.ModelView) !wire.catalog.ModelInfo {
    // A null level means "no effort at all", so it never reaches a client.
    var levels: std.ArrayList([]const u8) = .empty;
    for (m.reasoning_levels) |level| if (level) |value| try levels.append(arena, value);

    return .{
        .id = m.id,
        .provider = provider_id,
        .name = m.name,
        .context_window = m.context_window orelse 0,
        .max_output_tokens = m.max_output_tokens orelse 0,
        .reasoning_levels = levels.items,
        .default_reasoning = defaultReasoning(levels.items),
        .supports_vision = m.flags.supports_vision,
        .supports_tools = m.flags.supports_tools,
        .cost = .{
            .input = m.cost.input orelse 0,
            .output = m.cost.output orelse 0,
            .cache_read = m.cost.cache_read orelse 0,
            .cache_write = m.cost.cache_write orelse 0,
        },
    };
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
        const run_info: ?RunInfo = if (rt.active) |slot| .{ .run_id = slot.handle.started.run_id, .started_at_ms = slot.handle.started.started_at_ms, .retry = slot.retry_state } else null;
        return serializeResync(state, arena, snap, &rt.session, run_info, limit);
    }
    // The session is idle. Hydrate a transient projection, serialize it, then release it.
    var transient = domain_session.Session.init(state.gpa, params.session_id);
    defer transient.deinit();
    try state.hydrateSession(&transient);
    return serializeResync(state, arena, snap, &transient, null, limit);
}

/// The active run identity for the resync activity state.
const RunInfo = struct { run_id: wire.ids.RunId, started_at_ms: u64, retry: ?wire.activity.ActivityStateRetrying = null };

/// Build the activity from the session projection and its context usage. Every surface builds it here.
/// The caller supplies `context_usage`: a page joins it, a broadcast reads it. The result borrows `arena`.
pub fn sessionActivity(
    state: *State,
    arena: std.mem.Allocator,
    session_id: [16]u8,
    session: *domain_session.Session,
    run_info: ?RunInfo,
    context_usage: wire.message.TokenUsage,
) !wire.session.SessionActivity {
    // Resolve the active draft config once. The cache may lack the current run's revision.
    var active_config: ?wire.run.RunConfig = null;
    if (session.active) |*d| {
        const cached = session.configs.get(d.config_rev);
        active_config = cached orelse (try config_store.byRevision(&state.db, arena, session_id, d.config_rev)) orelse return error.CorruptLog;
    }

    var activity: wire.session.SessionActivity = .{
        .state = .{ .idle = .{} },
        .config = null,
        .queued = session.queue.depth(),
        .context_usage = context_usage,
        .pending_compaction = null,
    };

    // A waiting retry outranks the draft. The stream already stopped, so a draft state would mislead.
    const waiting: ?wire.activity.ActivityStateRetrying = if (run_info) |r| r.retry else null;
    if (waiting) |state_retry| {
        activity.state = try wire.dupe(arena, wire.activity.ActivityState{ .retrying = state_retry });
        if (session.active != null) activity.config = try wire.dupe(arena, active_config.?);
    } else if (session.active) |*d| {
        std.debug.assert(run_info != null); // a live draft belongs to an active run
        activity.state = try wire.dupe(arena, d.deriveStreamingState(run_info.?.started_at_ms));
        activity.config = try wire.dupe(arena, active_config.?);
    } else if (run_info) |r| {
        activity.state = .{ .building = .{ .run_id = r.run_id, .started_at_ms = r.started_at_ms } };
    }
    return activity;
}

/// The activity of one resident session, for a broadcast. It reads the context gauge from SQLite.
pub fn residentActivity(state: *State, arena: std.mem.Allocator, rt: *session_runtime.SessionRuntime) !wire.session.SessionActivity {
    const session_id = rt.session.id.raw;
    const run_info: ?RunInfo = if (rt.active) |slot| .{
        .run_id = slot.handle.started.run_id,
        .started_at_ms = slot.handle.started.started_at_ms,
        .retry = slot.retry_state,
    } else null;
    const usage = try message_store.contextUsage(&state.db, arena, session_id);
    return sessionActivity(state, arena, session_id, &rt.session, run_info, usage);
}

/// Serialize a session projection into the resync result. Deep-copy so a transient session can release.
fn serializeResync(state: *State, arena: std.mem.Allocator, snap: anytype, session: *domain_session.Session, run_info: ?RunInfo, limit: usize) !wire.session.SessionResyncResult {
    var item = try sessionItem(arena, snap);
    item.activity = try sessionActivity(state, arena, snap.id, session, run_info, contextUsage(snap));

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
        const slot = try session_runtime.RunSlot.prepare(state.gpa, snapshot.model, stored_prompt orelse "", snapshot.max_rounds);
        errdefer slot.destroy();
        const started = try run.beginTurn(&state.db, state.io, arena, sid, content, snapshot.config_rev);
        slot.bind(started.handle, started.first_round);
        rt.active = slot;
        launch.* = .{ .slot = slot };
        // Fold each durable event in sequence order: the user message, then run.started.
        run_task.publishUserCommits(state, rt, started.user_commits);
        run_task.emitDurable(state, rt, .{ .method = .@"run.started", .params = .{ .run_started_data = started.handle.started } });
        return .{ .started = .{ .input_id = started.handle.input_id, .run_id = started.handle.started.run_id } };
    }

    // A run is active. Persist and fold the queued input before the response.
    if (rt.session.queue.depth() >= wire.meta.limits.max_queued_inputs) return error.QueueFull;
    const now = state.nowMillis();
    var tx = try state.db.begin();
    defer tx.deinit();
    const queued = try input_store.enqueue(&state.db, arena, sid, state.newId(), now, content, now);
    try tx.commit();
    run_task.emitDurable(state, rt, .{ .method = .@"input.queued", .params = .{
        .input_queued_data = .{ .session_id = params.session_id, .seq = queued.seq, .input = queued.input },
    } });
    run_task.announceActivity(state, rt);
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
    run_task.emitDurable(state, rt, .{ .method = .@"input.canceled", .params = .{
        .input_canceled_data = .{ .session_id = params.session_id, .seq = canceled, .input_id = params.input_id },
    } });
    run_task.announceActivity(state, rt); // The queue is shorter. Announce before an evict frees `rt`.
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
            run_task.emitDurable(state, rt, .{ .method = .@"input.canceled", .params = .{
                .input_canceled_data = .{ .session_id = params.session_id, .seq = seq, .input_id = input_id },
            } });
        }
        if (cleared_inputs.len > 0) run_task.announceActivity(state, rt);
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

    // The index gained a session. Announce it after the commit, so no client hears of an unwritten one.
    run_task.announceSummary(state, .bytes(id));

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
