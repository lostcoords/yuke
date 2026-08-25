//! Request handlers. Each builds a wire result from the stores.
//! Each handler owns its write transaction.

const std = @import("std");
const wire = @import("wire");
const State = @import("State.zig");
const database = @import("../database/database.zig");
const run = @import("../engine/run.zig");
const run_task = @import("run_task.zig");
const session_runtime = @import("session_runtime.zig");
const domain_session = @import("../domain/session.zig");

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

fn decodeCursor(arena: std.mem.Allocator, sel: session_store.Selector, encoded: []const u8) !session_store.Cursor {
    const decoded_size = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(encoded) catch return error.BadCursor;
    if (decoded_size != cursor_raw_size) return error.BadCursor;

    const raw = try arena.alloc(u8, cursor_raw_size);
    std.base64.url_safe_no_pad.Decoder.decode(raw, encoded) catch return error.BadCursor;
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

fn sessionItem(arena: std.mem.Allocator, row: anytype) !wire.session.SessionListItem {
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
            .context_usage = .{ .input = 0, .output = 0, .reasoning = 0, .cache_read = 0, .cache_write = 0 },
            .pending_compaction = null,
        },
    };
}

/// Handle session.list from durable state. The active view needs the reactor live-session set.
/// Later code adds that set.
pub fn sessionList(state: *State, arena: std.mem.Allocator, params: wire.session.SessionListParams) !wire.session.SessionListResult {
    const sel = sessionSelector(params);
    const requested_limit = params.limit orelse wire.meta.limits.default_session_list_page_size;
    const effective_limit = @min(@max(requested_limit, 1), wire.meta.limits.max_session_list_page_size);
    const cursor = if (params.cursor) |encoded| try decodeCursor(arena, sel, encoded) else null;
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
        .revision = 0,
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
    const actual = try decodeCursor(a, selector, encoded);
    try std.testing.expectEqual(expected.updated_at_ms, actual.updated_at_ms);
    try std.testing.expectEqualSlices(u8, &expected.id, &actual.id);

    var different = selector;
    different.top_level = false;
    try std.testing.expectError(error.BadCursor, decodeCursor(a, different, encoded));
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
        .session_revision = 0,
        .catalog_rev = .bytes([_]u8{0} ** 64),
        .capabilities = &.{},
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
    const limit: usize = @intCast(@min(@max(requested, 1), wire.meta.limits.max_page_size));
    const page = try message_store.historyPage(&state.db, arena, sid, params.before_message_id, limit);
    return .{
        .session_id = params.session_id,
        .messages = page.messages,
        .configs = try gatherConfigs(state, arena, sid, page.messages),
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
        const run_info: ?RunInfo = if (rt.active) |slot| .{ .run_id = slot.handle.run_id, .started_at_ms = slot.handle.started.started_at_ms } else null;
        return serializeResync(state, arena, snap, &rt.session, run_info, limit);
    }
    // The session is idle. Hydrate a transient projection, serialize it, then release it.
    var transient = domain_session.Session.init(state.gpa, params.session_id);
    defer transient.deinit();
    try state.hydrateSession(&transient);
    return serializeResync(state, arena, snap, &transient, null, limit);
}

/// The active run identity for the resync activity state.
const RunInfo = struct { run_id: wire.ids.RunId, started_at_ms: u64 };

/// Serialize a session projection into the resync result. Deep-copy so a transient session can release.
fn serializeResync(state: *State, arena: std.mem.Allocator, snap: anytype, session: *domain_session.Session, run_info: ?RunInfo, limit: usize) !wire.session.SessionResyncResult {
    var item = try sessionItem(arena, snap);
    item.activity.queued = session.queue.depth();

    // Resolve the active draft config once. The cache may lack the current run's revision.
    var active_config: ?wire.run.RunConfig = null;
    if (session.active) |*d| {
        const cached = session.configs.get(d.config_rev);
        active_config = cached orelse (try config_store.byRevision(&state.db, arena, snap.id, d.config_rev)) orelse return error.CorruptLog;
    }

    // A draft reports the streaming state. A started run with no draft reports building. Idle reports idle.
    if (session.active) |*d| {
        std.debug.assert(run_info != null); // a live draft belongs to an active run
        item.activity.state = try wire.dupe(arena, d.deriveStreamingState(run_info.?.started_at_ms));
        item.activity.config = try wire.dupe(arena, active_config.?);
    } else if (run_info) |r| {
        item.activity.state = .{ .building = .{ .run_id = r.run_id, .started_at_ms = r.started_at_ms } };
    } else {
        item.activity.state = .{ .idle = .{} };
    }

    // The committed window returns its newest `limit` messages, oldest-first.
    const all = try session.committed.messages(arena);
    const start = if (all.len > limit) all.len - limit else 0;
    const messages = try wire.dupe(arena, all[start..]);
    const has_more = session.committed.has_more or start > 0;

    // Gather a config for every assistant message in the window, plus the active draft, from SQLite.
    // The live config set only tracks config.changed events, so it can miss a live commit.
    var configs: std.ArrayList(wire.run.RunConfig) = .empty;
    for (messages) |m| switch (m) {
        .assistant => |asst| try appendConfigOnce(state, arena, &configs, snap.id, asst.config_rev),
        else => {},
    };
    if (session.active) |*d| try appendConfigOnce(state, arena, &configs, snap.id, d.config_rev);

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

/// Append the config for a revision once. Fetch it from SQLite. A missing revision is a corrupt log.
fn appendConfigOnce(state: *State, arena: std.mem.Allocator, configs: *std.ArrayList(wire.run.RunConfig), session_id: [16]u8, rev: wire.ids.ConfigRev) !void {
    for (configs.items) |c| if (c.config_rev == rev) return;
    const cfg = (try config_store.byRevision(&state.db, arena, session_id, rev)) orelse return error.CorruptLog;
    try configs.append(arena, cfg);
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
        const slot = try session_runtime.RunSlot.prepare(state.gpa, snapshot.model, stored_prompt orelse "");
        errdefer slot.destroy();
        const started = try run.beginTurn(&state.db, state.io, arena, sid, content, snapshot.config_rev);
        slot.bind(started.handle);
        rt.active = slot;
        launch.* = .{ .slot = slot };
        // Fold each durable event in sequence order: the user message, then run.started.
        run_task.publishUserCommits(state, rt, started.user_commits);
        run_task.emitDurable(state, rt, .{ .method = .@"run.started", .params = .{ .run_started_data = started.handle.started } });
        return .{ .started = .{ .input_id = started.handle.input_id, .run_id = started.handle.run_id } };
    }

    // A run is active. Persist and fold the queued input before the response.
    if (rt.session.queue.depth() >= wire.meta.limits.max_queued_inputs) return error.QueueFull;
    const now = state.nowMillis();
    try state.db.conn.execNoArgs("BEGIN IMMEDIATE");
    errdefer state.db.conn.execNoArgs("ROLLBACK") catch {};
    const queued = try input_store.enqueue(&state.db, arena, sid, state.newId(), now, content, now);
    try state.db.conn.execNoArgs("COMMIT");
    run_task.emitDurable(state, rt, .{ .method = .@"input.queued", .params = .{
        .input_queued_data = .{ .session_id = params.session_id, .seq = queued.seq, .input = queued.input },
    } });
    return .{ .queued = .{ .input_id = queued.input.input_id } };
}

/// Cancel one exact queued input. A started input belongs to the active run.
pub fn sessionCancelInput(state: *State, arena: std.mem.Allocator, params: wire.session.SessionCancelInputParams) !wire.session.SessionCancelInputResult {
    const sid = params.session_id.raw;
    if (!try session_store.exists(&state.db, arena, sid)) return error.UnknownSession;
    const rt = try state.activate(params.session_id);

    const now = state.nowMillis();
    try state.db.conn.execNoArgs("BEGIN IMMEDIATE");
    errdefer state.db.conn.execNoArgs("ROLLBACK") catch {};
    const canceled = input_store.cancel(&state.db, arena, sid, state.newId(), now, params.input_id) catch |err| switch (err) {
        error.NoRow => return error.UnknownInput,
        else => return err,
    };
    try state.db.conn.execNoArgs("COMMIT");
    run_task.emitDurable(state, rt, .{ .method = .@"input.canceled", .params = .{
        .input_canceled_data = .{ .session_id = params.session_id, .seq = canceled, .input_id = params.input_id },
    } });
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
        if (active == null or active.?.handle.run_id != expected) return error.RunMismatch;
    }

    var cleared_inputs: []wire.ids.InputId = &.{};
    if (params.clear_queue orelse false) {
        const pending = try input_store.list(&state.db, arena, sid);
        cleared_inputs = try arena.alloc(wire.ids.InputId, pending.len);
        const cleared_seqs = try arena.alloc(wire.ids.Seq, pending.len);
        const now = state.nowMillis();
        try state.db.conn.execNoArgs("BEGIN IMMEDIATE");
        errdefer state.db.conn.execNoArgs("ROLLBACK") catch {};
        for (pending, 0..) |entry, i| {
            cleared_inputs[i] = entry.input.input_id;
            const canceled = try input_store.cancel(&state.db, arena, sid, state.newId(), now, entry.input.input_id);
            cleared_seqs[i] = canceled;
        }
        try state.db.conn.execNoArgs("COMMIT");
        for (cleared_inputs, cleared_seqs) |input_id, seq| {
            run_task.emitDurable(state, rt, .{ .method = .@"input.canceled", .params = .{
                .input_canceled_data = .{ .session_id = params.session_id, .seq = seq, .input_id = input_id },
            } });
        }
    }

    const canceled_run = if (active) |slot| slot.handle.run_id else null;
    if (active) |slot| {
        if (!slot.cancel_requested) {
            slot.cancel_requested = true;
            slot.cancel_event.set(); // Wake the run task so it cancels its reader.
        }
    }
    if (active == null) state.sessions.evictIfIdle(params.session_id);
    return .{ .canceled_run = canceled_run, .cleared_inputs = cleared_inputs };
}

/// Collect the distinct configs the assistant messages reference, in first-reference order.
/// A referenced revision that is absent signals log corruption. The wire request remains valid.
fn gatherConfigs(state: *State, arena: std.mem.Allocator, session_id: [16]u8, messages: []const wire.message.Message) ![]const wire.run.RunConfig {
    var out: std.ArrayList(wire.run.RunConfig) = .empty;
    for (messages) |message| switch (message) {
        .assistant => |a| {
            for (out.items) |seen| {
                if (seen.config_rev == a.config_rev) break;
            } else {
                const config = (try config_store.byRevision(&state.db, arena, session_id, a.config_rev)) orelse return error.CorruptLog;
                try out.append(arena, config);
            }
        },
        else => {},
    };
    return out.items;
}

/// Handle session.create: resolve the workspace, mint ids, insert the session, and return it.
/// Later code adds broadcast fan-out. This function returns only the result.
pub fn sessionCreate(state: *State, arena: std.mem.Allocator, params: wire.misc.CreateSession) !wire.session.SessionResult {
    // Use the raw path as the dedup key for now. A later workspace chunk adds canonicalization.
    const root = params.workspace_path orelse state.home;
    const base = std.fs.path.basename(root);
    const title = if (base.len == 0) root else base;
    const profile = params.profile orelse "default";
    const model = params.model orelse "";
    const reasoning = params.reasoning orelse "";
    const permission = params.permission orelse .normal;
    const now = state.nowMillis();

    const workspace_id = state.newId();
    const id = state.newId();

    try state.db.conn.execNoArgs("BEGIN IMMEDIATE");
    errdefer state.db.conn.execNoArgs("ROLLBACK") catch {};
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
    if (params.system_prompt) |sys| try session_store.setPrompt(&state.db, id, sys);
    try config_store.recordInitial(&state.db, id, model, reasoning);
    try state.db.conn.execNoArgs("COMMIT");

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
