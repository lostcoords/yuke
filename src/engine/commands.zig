//! Session commands. Each builds a wire result from the engine and the store.
//! Each handler owns its write transaction.

const std = @import("std");
const proto = @import("proto");
const Engine = @import("Engine.zig");

/// The build version. `initialize` reports one value for the whole process.
pub const version = "0.0.1";
const database = @import("../store/store.zig");
const run = @import("run.zig");
const run_task = @import("turn.zig");
const session_events = @import("events.zig");
const paths = @import("../paths.zig");

const session_store = database.session;
const message_store = database.message;
const config_store = database.config;
const input_store = database.input;

const cursor_version: u8 = 1;
const cursor_raw_size = 33;

/// Build a selector fingerprint from its complete canonical 18-byte layout.
fn selectorFingerprint(sel: session_store.Selector) u64 {
    var canon = [_]u8{0} ** 18;
    if (sel.parent_id) |parent_id| {
        canon[0] = 1;
        @memcpy(canon[1..17], &parent_id);
    }
    canon[17] = @intFromBool(sel.top_level);
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

fn sessionSelector(params: proto.session.SessionListParams) session_store.Selector {
    var sel: session_store.Selector = .{};
    switch (params.population) {
        .top_level => sel.top_level = true,
        .children => |children| sel.parent_id = children.parent_id.raw,
        .all => {},
    }
    return sel;
}

/// Handle session.list from durable state. Each item reports idle activity.
pub fn sessionList(engine: *Engine, arena: std.mem.Allocator, params: proto.session.SessionListParams) !proto.session.SessionListResult {
    const sel = sessionSelector(params);
    const requested_limit = params.limit orelse proto.meta.limits.default_session_list_page_size;
    const effective_limit = std.math.clamp(requested_limit, 1, proto.meta.limits.max_session_list_page_size);
    const cursor = if (params.cursor) |encoded| try decodeCursor(sel, encoded) else null;
    const rows = try session_store.list(engine.deps.db, arena, sel, cursor, @intCast(effective_limit + 1));
    const has_next = rows.len > effective_limit;
    const kept = rows[0..@min(rows.len, @as(usize, @intCast(effective_limit)))];
    const next_cursor = if (has_next) try encodeCursor(arena, sel, .{
        .updated_at_ms = kept[kept.len - 1].updated_at_ms,
        .id = kept[kept.len - 1].id,
    }) else null;
    const items = try arena.alloc(proto.session.SessionListItem, kept.len);
    for (kept, 0..) |row, i| items[i] = try session_events.sessionItem(arena, row);

    return .{
        .revision = engine.session_revision,
        .items = items,
        .next_cursor = next_cursor,
        .total = try session_store.count(engine.deps.db, arena, sel),
    };
}

test "session list cursor round-trips and binds to its selector" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const selector: session_store.Selector = .{
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

/// Handle initialize: report the engine snapshot. The session revision starts at 0 each run because
/// it lives in memory. The catalog revision waits for the catalog slice.
pub fn initialize(engine: *Engine, _: std.mem.Allocator) !proto.misc.InitializeResult {
    return .{
        .protocol = proto.meta.protocol_version,
        .engine = .{ .version = version },
        .session_revision = engine.session_revision,
        .catalog_rev = engine.deps.providers.merged.revision,
    };
}

/// Handle session.config: return one config revision and the session's system prompt.
/// Return the current config for a null config_rev. Return UnknownConfigRev for an absent revision.
pub fn sessionConfig(engine: *Engine, arena: std.mem.Allocator, params: proto.session.SessionConfigParams) !proto.session.SessionConfigResult {
    const sid = params.session_id.raw;
    const snap = (try session_store.snapshot(engine.deps.db, arena, sid)) orelse return error.UnknownSession;
    const config: proto.run.RunConfig = if (params.config_rev) |rev|
        (try config_store.byRevision(engine.deps.db, arena, sid, rev)) orelse return error.UnknownConfigRev
    else
        .{ .config_rev = snap.config_rev, .model = snap.model, .reasoning = snap.reasoning };
    return .{ .config = config, .system_prompt = try session_store.prompt(engine.deps.db, arena, sid) };
}

/// Handle session.history: return a page of committed messages oldest first, the configs those
/// assistant turns reference, and whether older messages remain.
pub fn sessionHistory(engine: *Engine, arena: std.mem.Allocator, params: proto.session.SessionHistoryParams) !proto.session.SessionHistoryResult {
    const sid = params.session_id.raw;
    if (!try session_store.exists(engine.deps.db, arena, sid)) return error.UnknownSession;
    const requested = params.limit orelse proto.meta.limits.default_page_size;
    const limit: usize = @intCast(std.math.clamp(requested, 1, proto.meta.limits.max_page_size));
    const page = try message_store.historyPage(engine.deps.db, arena, sid, params.before_message_id, limit);
    return .{
        .session_id = params.session_id,
        .messages = page.messages,
        .configs = try config_store.forMessages(engine.deps.db, arena, sid, page.messages),
        .has_more = page.has_more,
    };
}

/// Accept input for an RPC and return its prepared run to the response gate.
pub fn sessionSendInputForRpc(engine: *Engine, arena: std.mem.Allocator, params: proto.session.SessionSendInputParams, launch: *?run_task.Launch) !proto.session.SessionSendInputResult {
    std.debug.assert(launch.* == null);
    const content = switch (params.input) {
        .content => |c| c.content,
        .skill => return error.SkillUnsupported,
    };
    const sid = params.session_id.raw;
    const snapshot = (try session_store.snapshot(engine.deps.db, arena, sid)) orelse return error.UnknownSession;
    const rt = try engine.activate(params.session_id);
    if (rt.faulted) return error.RuntimeFailed;
    if (rt.active_run == null and rt.queueDepth() > 0) launch.* = .{ .slot = try run_task.prepareQueued(engine, rt) };

    if (rt.active_run == null) {
        const stored_prompt = try session_store.prompt(engine.deps.db, arena, sid);
        const slot = try run.RunSlot.prepare(engine.deps.gpa, snapshot.model, snapshot.reasoning, stored_prompt orelse "", snapshot.max_rounds);
        errdefer slot.destroy();
        const started = try run.beginTurn(engine.deps.db, engine.deps.io, arena, sid, content, snapshot.config_rev);
        slot.bind(started.handle, started.first_round);
        rt.active_run = slot;
        launch.* = .{ .slot = slot };
        // Fold each durable event in sequence order: the user message, then run.started.
        session_events.publishUserCommits(engine, rt, started.user_commits);
        session_events.emitDurable(engine, rt, .{ .method = .@"run.started", .params = .{ .run_started_data = started.handle.started } });
        return .{ .started = .{ .input_id = started.handle.input_id, .run_id = started.handle.started.run_id } };
    }

    // A run is active. Persist and fold the queued input before the response.
    if (rt.queueDepth() >= proto.meta.limits.max_queued_inputs) return error.QueueFull;
    const now = engine.nowMillis();
    var tx = try engine.deps.db.*.begin();
    defer tx.deinit();
    const queued = try input_store.enqueue(engine.deps.db, arena, sid, engine.newId(), now, content, now);
    try tx.commit();
    session_events.emitDurable(engine, rt, .{ .method = .@"input.queued", .params = .{
        .input_queued_data = .{ .session_id = params.session_id, .seq = queued.seq, .input = queued.input },
    } });
    session_events.announceActivity(engine, rt);
    return .{ .queued = .{ .input_id = queued.input.input_id } };
}

/// Cancel one exact queued input. A started input belongs to the active run.
pub fn sessionCancelInput(engine: *Engine, arena: std.mem.Allocator, params: proto.session.SessionCancelInputParams) !proto.session.SessionCancelInputResult {
    const sid = params.session_id.raw;
    if (!try session_store.exists(engine.deps.db, arena, sid)) return error.UnknownSession;
    const rt = try engine.activate(params.session_id);

    const now = engine.nowMillis();
    var tx = try engine.deps.db.*.begin();
    defer tx.deinit();
    const canceled = input_store.cancel(engine.deps.db, arena, sid, engine.newId(), now, params.input_id) catch |err| switch (err) {
        error.NoRow => return error.UnknownInput,
        else => return err,
    };
    try tx.commit();
    session_events.emitDurable(engine, rt, .{ .method = .@"input.canceled", .params = .{
        .input_canceled_data = .{ .session_id = params.session_id, .seq = canceled, .input_id = params.input_id },
    } });
    session_events.announceActivity(engine, rt); // The queue is shorter. Announce before an evict frees `rt`.
    engine.sessions.evictIfIdle(params.session_id);
    return .{ .canceled_input = params.input_id };
}

/// Request cancellation of the active run. Clear the durable queue only when requested.
pub fn sessionCancelRun(engine: *Engine, arena: std.mem.Allocator, params: proto.session.SessionCancelRunParams) !proto.session.SessionCancelRunResult {
    const sid = params.session_id.raw;
    if (!try session_store.exists(engine.deps.db, arena, sid)) return error.UnknownSession;
    const rt = try engine.activate(params.session_id);

    const active = rt.active_run;
    if (params.run_id) |expected| {
        if (active == null or active.?.handle.started.run_id != expected) return error.RunMismatch;
    }

    var cleared_inputs: []proto.ids.InputId = &.{};
    if (params.clear_queue orelse false) {
        const pending = try input_store.list(engine.deps.db, arena, sid);
        cleared_inputs = try arena.alloc(proto.ids.InputId, pending.len);
        const cleared_seqs = try arena.alloc(proto.ids.Seq, pending.len);
        const now = engine.nowMillis();
        var tx = try engine.deps.db.*.begin();
        defer tx.deinit();
        for (pending, 0..) |entry, i| {
            cleared_inputs[i] = entry.input.input_id;
            const canceled = try input_store.cancel(engine.deps.db, arena, sid, engine.newId(), now, entry.input.input_id);
            cleared_seqs[i] = canceled;
        }
        try tx.commit();
        for (cleared_inputs, cleared_seqs) |input_id, seq| {
            session_events.emitDurable(engine, rt, .{ .method = .@"input.canceled", .params = .{
                .input_canceled_data = .{ .session_id = params.session_id, .seq = seq, .input_id = input_id },
            } });
        }
        if (cleared_inputs.len > 0) session_events.announceActivity(engine, rt);
    }

    const canceled_run = if (active) |slot| slot.handle.started.run_id else null;
    if (active) |slot| {
        if (!slot.cancel_requested) {
            slot.cancel_requested = true;
            slot.wake_event.set(engine.deps.io); // Wake the run task so it cancels its reader.
        }
    }
    if (active == null) engine.sessions.evictIfIdle(params.session_id);
    return .{ .canceled_run = canceled_run, .cleared_inputs = cleared_inputs };
}

/// Collect the session and, with `cascade`, each session below it. The walk follows parent_id.
fn removalSet(engine: *Engine, arena: std.mem.Allocator, root: [16]u8, cascade: bool) ![]const [16]u8 {
    var out: std.ArrayList([16]u8) = .empty;
    try out.append(arena, root);
    if (!cascade) return out.items;
    // A parent_id chain forms a tree, so a repeated id means a corrupt row.
    var seen: std.AutoHashMapUnmanaged([16]u8, void) = .empty;
    try seen.put(arena, root, {});
    var frontier: usize = 0;
    while (frontier < out.items.len) : (frontier += 1) {
        for (try session_store.childIds(engine.deps.db, arena, out.items[frontier])) |child| {
            if ((try seen.getOrPut(arena, child)).found_existing) return error.CorruptDatabase;
            try out.append(arena, child);
        }
    }
    return out.items;
}

/// Handle session.remove: delete the session and, with `cascade_children`, its children.
pub fn sessionRemove(engine: *Engine, arena: std.mem.Allocator, params: proto.session.SessionRemoveParams) !proto.misc.Empty {
    const sid = params.session_id.raw;
    if (!try session_store.exists(engine.deps.db, arena, sid)) return error.UnknownSession;

    // A child points into the parent transcript, so it cannot outlive its parent.
    if (!params.cascade_children and (try session_store.childIds(engine.deps.db, arena, sid)).len > 0)
        return error.SessionHasChildren;

    const doomed = try removalSet(engine, arena, sid, params.cascade_children);
    // Check each session before the first delete, so a busy child leaves no partial removal.
    // A pinned session is open in a view, and a removal would leave that view with no resident.
    for (doomed) |id| {
        const rt = engine.sessions.get(.bytes(id)) orelse continue;
        if (rt.active_run != null or rt.pins != 0) return error.SessionBusy;
    }

    var tx = try engine.deps.db.*.begin();
    defer tx.deinit();
    for (doomed) |id| try session_store.remove(engine.deps.db, id);
    try tx.commit();

    // Announce the deepest session first, so a client tree holds no orphan.
    var i = doomed.len;
    while (i > 0) {
        i -= 1;
        const id: proto.ids.SessionId = .bytes(doomed[i]);
        engine.sessions.remove(id);
        session_events.announceRemoved(engine, id);
    }
    return .{};
}

/// Handle session.create: resolve the workspace, mint ids, insert the session, and return it.
pub fn sessionCreate(engine: *Engine, arena: std.mem.Allocator, params: proto.misc.CreateSession) !proto.session.SessionResult {
    // Normalize the path so one directory maps to one workspace.
    const root = try paths.canonicalizeWorkspace(arena, engine.deps.env, params.workspace_path);
    const base = std.fs.path.basename(root);
    const title = if (base.len == 0) root else base;
    const profile = params.profile orelse "default";
    const model = params.model orelse "";
    const reasoning = params.reasoning orelse "";
    const now = engine.nowMillis();

    const id = engine.newId();

    var tx = try engine.deps.db.*.begin();
    defer tx.deinit();
    try session_store.create(engine.deps.db, .{
        .id = id,
        .root = root,
        .origin = "root",
        .profile = profile,
        .model = model,
        .reasoning = reasoning,
        .config_rev = 0,
        .max_rounds = params.max_rounds,
        .title = title,
        .created_at_ms = now,
        .updated_at_ms = now,
    });
    const system_prompt = params.system_prompt orelse engine.default_system_prompt;
    if (system_prompt) |sys| try session_store.setPrompt(engine.deps.db, id, sys);
    try config_store.recordInitial(engine.deps.db, id, model, reasoning);
    try tx.commit();

    // Announce the session after the commit, never before it.
    session_events.announceSummary(engine, .bytes(id));

    return .{ .session = .{
        .id = .bytes(id),
        .root = root,
        .profile = profile,
        .model = model,
        .reasoning = reasoning,
        .config_rev = 0,
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
