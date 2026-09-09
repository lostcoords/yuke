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
const instructions = @import("../session/instructions.zig");
const skills = @import("../session/skills.zig");
const reports = @import("reports.zig");
const admission = @import("admission.zig");
const provider_registry = @import("../provider/registry.zig");

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

/// Handle session.list from durable state. A resident session reports its live activity.
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
    for (kept, 0..) |row, i| {
        items[i] = try session_events.sessionItem(arena, row);
        if (row.parent_id != null) items[i].last_run = try database.run.latestOutcome(engine.deps.db, arena, row.id);
        items[i].activity = try liveActivity(engine, arena, items[i].session.id, items[i].activity);
    }

    return .{
        .revision = engine.session_revision,
        .items = items,
        .next_cursor = next_cursor,
        .total = try session_store.count(engine.deps.db, arena, sel),
    };
}

/// Return the catalog default level of a model, or an empty level for an unknown model.
fn defaultLevelOf(engine: *Engine, arena: std.mem.Allocator, model: []const u8) ![]const u8 {
    const match = engine.deps.providers.merged.resolveModel(model) orelse return "";
    // The level borrows the merged registry, and a reload can free it before the commit, so the arena keeps a copy.
    return arena.dupe(u8, try provider_registry.defaultLevel(arena, match.model.*));
}

/// Handle session.get. The result is one `session.list` item with the activity the engine holds now.
pub fn sessionGet(engine: *Engine, arena: std.mem.Allocator, params: proto.session.SessionGetParams) !proto.session.SessionListItem {
    const session_id = if (params.child_name) |name| blk: {
        if (!admission.validName(name)) return error.BadChildName;
        const child = (try engine.deps.db.queries.child_by_name.maybeOne(arena, .{ .parent_id = params.session_id.raw, .name = name })) orelse return error.UnknownSession;
        break :blk proto.ids.SessionId.bytes(child.value.id);
    } else params.session_id;
    const snapshot = (try session_store.snapshot(engine.deps.db, arena, session_id.raw)) orelse return error.UnknownSession;
    var item = try session_events.sessionItem(arena, snapshot);
    if (snapshot.parent_id != null) item.last_run = try database.run.latestOutcome(engine.deps.db, arena, snapshot.id);
    item.activity = try liveActivity(engine, arena, session_id, item.activity);
    item.instruction_sources = try session_store.instructionSources(engine.deps.db, arena, session_id.raw);
    item.skills = try session_store.skillCatalog(engine.deps.db, arena, session_id.raw);
    if (params.check_files) item.context_changes = .{
        .instructions = try instructionsChanged(engine, arena, snapshot.root, item.instruction_sources.?),
        .skills = try skills.changed(arena, engine.deps.io, engine.deps.env, snapshot.root, item.skills.?),
    };
    return item;
}

/// Report whether the AGENTS.md files on disk differ from the stored sources. An unloadable file counts as a change.
fn instructionsChanged(engine: *Engine, arena: std.mem.Allocator, root: []const u8, stored: []const proto.instructions.InstructionSource) !bool {
    const fresh = instructions.load(arena, engine.deps.io, engine.deps.env, root, null) catch |err| switch (err) {
        error.InvalidInstructions => return true,
        else => |e| return e,
    };
    if (fresh.len != stored.len) return true;
    // Both lists order global before workspace.
    for (fresh, stored) |a, b| {
        if (a.source.scope != b.scope) return true;
        if (!std.mem.eql(u8, a.source.canonical_path, b.canonical_path)) return true;
        if (!std.mem.eql(u8, &a.source.content_hash.raw, &b.content_hash.raw)) return true;
    }
    return false;
}

/// Handle skill.load: read the body of one catalog entry. The catalog is the session snapshot, not the disk.
pub fn skillLoad(engine: *Engine, arena: std.mem.Allocator, params: proto.skill.SkillLoadParams, _: *?run_task.Launch, diagnostic: ?*?[]const u8) !proto.skill.SkillLoadResult {
    if (skills.nameFault(params.name) != null) return error.UnknownSkill;
    const sid = params.session_id.raw;
    const entry = (try session_store.skill(engine.deps.db, arena, sid, params.name)) orelse {
        if (!try session_store.exists(engine.deps.db, arena, sid)) return error.UnknownSession;
        return error.UnknownSkill;
    };
    const body = try skills.readBody(arena, engine.deps.io, entry, diagnostic);
    return .{ .body = body.body, .directory = body.directory, .scope = entry.scope, .path = entry.path, .content = try skills.wrap(arena, entry.name, body) };
}

/// Handle session.reload_context: rescan both roots and replace the stored snapshots of one idle session.
pub fn sessionReloadContext(engine: *Engine, arena: std.mem.Allocator, params: proto.session.SessionReloadContextParams, _: *?run_task.Launch, diagnostic: ?*?[]const u8) !proto.session.SessionReloadContextResult {
    try engine.own(params.session_id);
    const sid = params.session_id.raw;
    const snapshot = (try session_store.snapshot(engine.deps.db, arena, sid)) orelse return error.UnknownSession;
    // A run holds its prompt for its whole life, so a swap under it would split one turn across two prompts.
    if (engine.sessions.get(params.session_id)) |rt| if (rt.active_run != null) return error.SessionBusy;
    const sources = try instructions.load(arena, engine.deps.io, engine.deps.env, snapshot.root, diagnostic);
    const catalog = try skills.load(arena, engine.deps.io, engine.deps.env, snapshot.root);
    const notices = try skippedNotices(arena, catalog.skipped);
    const listed = try arena.alloc(proto.instructions.InstructionSource, sources.len);
    for (sources, listed) |source, *out| out.* = source.source;
    // File reads can yield to admission, so repeat the idle check before the transaction.
    if (engine.sessions.get(params.session_id)) |rt| if (rt.active_run != null) return error.SessionBusy;
    {
        var tx = try engine.deps.db.begin();
        defer tx.deinit();
        _ = try session_store.reloadContext(engine.deps.db, arena, sid, sources, catalog.entries);
        try tx.commit();
    }
    emitNotices(engine, notices);
    return .{ .instruction_sources = listed, .skills = catalog.entries };
}

/// Format one notice per skipped skill before the transaction, so the emit after commit cannot fail.
fn skippedNotices(arena: std.mem.Allocator, skipped: []const skills.Skipped) ![]const []const u8 {
    const texts = try arena.alloc([]const u8, skipped.len);
    for (skipped, texts) |entry, *text| text.* = try std.fmt.allocPrint(arena, "The engine skipped the skill at {s}: {s}", .{ entry.path, entry.reason });
    return texts;
}

/// A skipped skill never blocks a session, so a notice is the whole answer.
fn emitNotices(engine: *Engine, texts: []const []const u8) void {
    for (texts) |text| engine.sinks.emit(.{ .method = .notice, .params = .{ .notice = .{ .level = .warn, .source = "skills", .message = text } } });
}

/// Turn an explicit skill invocation into one user message: the wrapped body, then the arguments.
fn skillContent(engine: *Engine, arena: std.mem.Allocator, catalog: []const skills.Entry, invocation: proto.input.InputSkill, diagnostic: ?*?[]const u8) ![]const proto.content.ContentPart {
    if (skills.nameFault(invocation.name) != null) return error.UnknownSkill;
    const entry = skills.find(catalog, invocation.name) orelse return error.UnknownSkill;
    const body = try skills.readBody(arena, engine.deps.io, entry, diagnostic);
    const wrapped = try skills.wrap(arena, entry.name, body);
    const arguments = std.mem.trim(u8, invocation.arguments orelse "", " \t\r\n");
    const text = if (arguments.len == 0) wrapped else try std.mem.concat(arena, u8, &.{ wrapped, "\n\n", arguments });
    const parts = try arena.alloc(proto.content.ContentPart, 1);
    parts[0] = .{ .text = .{ .text = text } };
    return parts;
}

/// Return the live activity of a resident session, or the idle activity with the queue depth for the rest.
fn liveActivity(engine: *Engine, arena: std.mem.Allocator, id: proto.ids.SessionId, durable: proto.session.SessionActivity) !proto.session.SessionActivity {
    if (engine.sessions.get(id)) |rt| return session_events.residentActivity(engine, arena, rt);
    std.debug.assert(durable.state == .idle);
    var activity = durable;
    activity.queued = try input_store.count(engine.deps.db, arena, id.raw);
    return activity;
}

/// Handle session.queue from durable state. The runtime queue mirrors it, so no residency is needed.
pub fn sessionQueue(engine: *Engine, arena: std.mem.Allocator, params: proto.session.SessionQueueParams) !proto.session.SessionQueueResult {
    const sid = params.session_id.raw;
    if (!try session_store.exists(engine.deps.db, arena, sid)) return error.UnknownSession;
    const entries = try input_store.list(engine.deps.db, arena, sid);
    const items = try arena.alloc(proto.misc.QueuedInput, entries.len);
    for (entries, 0..) |entry, i| items[i] = entry.input;
    return .{ .items = items };
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
pub fn sessionSendInputForRpc(engine: *Engine, arena: std.mem.Allocator, params: proto.session.SessionSendInputParams, launch: *?run_task.Launch, diagnostic: ?*?[]const u8) !proto.session.SessionSendInputResult {
    try engine.own(params.session_id);
    std.debug.assert(launch.* == null);
    const sid = params.session_id.raw;
    const content = switch (params.input) {
        .content => |c| c.content,
        .skill => |invocation| try skillContent(engine, arena, try session_store.skillCatalog(engine.deps.db, arena, sid), invocation, diagnostic),
    };
    // A skill file read can yield, so use the current config after the read.
    const snapshot = (try session_store.snapshot(engine.deps.db, arena, sid)) orelse return error.UnknownSession;
    const rt = try engine.activate(params.session_id);
    if (rt.faulted) return error.RuntimeFailed;
    const parent: ?proto.ids.SessionId = if (snapshot.parent_id) |id| .bytes(id) else null;
    const tree = try admission.location(engine, arena, params.session_id);
    const source: ?proto.input.InputSource = if (params.parent_tool) |site| blk: {
        if (parent == null or !std.mem.eql(u8, &parent.?.raw, &site.session_id.raw)) return error.BadToolSite;
        try validateParentSite(engine, site);
        break :blk .{ .parent_instruction = site };
    } else null;
    if (parent != null) try reports.reserve(engine, arena, tree.root);
    const available = parent == null or try admission.available(engine, arena, tree.root, params.session_id);
    if (available and rt.active_run == null and rt.queueDepth() > 0) launch.* = .{ .slot = try run_task.prepareQueued(engine, rt) };

    if (available and rt.active_run == null) {
        const stored_prompt = try session_store.prompt(engine.deps.db, arena, sid);
        var prepared = try run.RunSlot.prepare(engine.deps.gpa, snapshot.model, snapshot.reasoning, stored_prompt orelse "", snapshot.max_rounds);
        errdefer prepared.deinit();
        const started = try run.beginTurn(engine.deps.db, engine.deps.io, arena, sid, .{ .content = content, .source = source, .skill_name = if (params.input == .skill) params.input.skill.name else null }, snapshot.config_rev);
        const slot = prepared.bind(started.handle, started.first_round, parent, tree);
        rt.active_run = slot;
        launch.* = .{ .slot = slot };
        // Fold each durable event in sequence order: the user message, then run.started.
        session_events.publishUserCommits(engine, rt, started.user_commits);
        session_events.emitDurable(engine, rt, .{ .method = .@"run.started", .params = .{ .run_started_data = started.handle.started } });
        return .{ .started = .{ .input_id = started.handle.input_id, .run_id = started.handle.started.run_id, .capacity = if (parent != null) admission.capacity(engine, tree.root) else null } };
    }

    // A run is active. Persist and fold the queued input before the response.
    if (rt.userQueueDepth() >= proto.meta.limits.max_queued_inputs) return error.QueueFull;
    const now = engine.nowMillis();
    var tx = try engine.deps.db.*.begin();
    defer tx.deinit();
    const queued = try input_store.enqueue(engine.deps.db, arena, sid, engine.newId(), now, .{ .content = content, .source = source, .skill_name = if (params.input == .skill) params.input.skill.name else null }, now);
    try tx.commit();
    session_events.emitDurable(engine, rt, .{ .method = .@"input.queued", .params = .{
        .input_queued_data = .{ .session_id = params.session_id, .seq = queued.seq, .input = queued.input },
    } });
    session_events.announceActivity(engine, rt);
    if (parent) |id| if (launch.* == null) {
        launch.* = .{ .wake = id };
    };
    return .{ .queued = .{ .input_id = queued.input.input_id, .reason = if (rt.active_run != null) .session_busy else .concurrency_limit, .capacity = if (parent != null) admission.capacity(engine, tree.root) else null } };
}

/// Cancel one exact queued input. A started input belongs to the active run.
pub fn sessionCancelInput(engine: *Engine, arena: std.mem.Allocator, params: proto.session.SessionCancelInputParams) !proto.session.SessionCancelInputResult {
    try engine.own(params.session_id);
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
    const report = try reports.canceledInputs(engine, arena, params.session_id, &.{params.input_id});
    try tx.commit();
    session_events.emitDurable(engine, rt, .{ .method = .@"input.canceled", .params = .{
        .input_canceled_data = .{ .session_id = params.session_id, .seq = canceled, .input_id = params.input_id },
    } });
    session_events.announceActivity(engine, rt); // The queue is shorter. Announce before an evict frees `rt`.
    engine.sessions.evictIfIdle(params.session_id);
    if (report) |note| reports.publishReport(engine, note, true);
    return .{ .canceled_input = params.input_id };
}

/// Request cancellation of the active run. Clear the durable queue only when requested.
pub fn sessionCancelRun(engine: *Engine, arena: std.mem.Allocator, params: proto.session.SessionCancelRunParams) !proto.session.SessionCancelRunResult {
    try engine.own(params.session_id);
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
        var count: usize = 0;
        for (pending) |entry| {
            if (entry.input.source) |source| if (source.protected()) continue;
            const i = count;
            count += 1;
            cleared_inputs[i] = entry.input.input_id;
            const canceled = try input_store.cancel(engine.deps.db, arena, sid, engine.newId(), now, entry.input.input_id);
            cleared_seqs[i] = canceled;
        }
        cleared_inputs = cleared_inputs[0..count];
        const report = try reports.canceledInputs(engine, arena, params.session_id, cleared_inputs);
        try tx.commit();
        for (cleared_inputs, cleared_seqs[0..count]) |input_id, seq| {
            session_events.emitDurable(engine, rt, .{ .method = .@"input.canceled", .params = .{
                .input_canceled_data = .{ .session_id = params.session_id, .seq = seq, .input_id = input_id },
            } });
        }
        if (cleared_inputs.len > 0) session_events.announceActivity(engine, rt);
        if (report) |note| reports.publishReport(engine, note, true);
    }

    const canceled_run = if (active) |slot| slot.handle.started.run_id else null;
    if (active) |slot| {
        if (!slot.cancel.requested) {
            slot.cancel.request(engine.deps.io); // Wake the run task so it cancels its reader.
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
    try engine.own(params.session_id);
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
    if (engine.owners.contains(sid)) engine.releaseRoot(params.session_id);
    return .{};
}

/// The parent instruction must name a live tool in the owning parent run.
fn validateParentSite(engine: *Engine, site: proto.input.ToolSite) !void {
    const resident = engine.sessions.get(site.session_id) orelse return error.BadToolSite;
    const active = resident.active_run orelse return error.BadToolSite;
    if (active.cancel.requested or active.phase != .running) return error.BadToolSite;
    const current = active.progress.current orelse return error.BadToolSite;
    if (current.message_id != site.message_id) return error.BadToolSite;
    const draft = resident.draft orelse return error.BadToolSite;
    if (site.part_id >= draft.parts.items.len) return error.BadToolSite;
    const part = draft.parts.items[@intCast(site.part_id)];
    if (part != .tool or part.tool.state != .running) return error.BadToolSite;
}

/// Handle session.create: resolve the workspace, mint ids, insert the session, and return it.
pub fn sessionCreate(engine: *Engine, arena: std.mem.Allocator, params: proto.misc.CreateSession) !proto.session.SessionResult {
    var launch: ?run_task.Launch = null;
    defer run_task.Launch.release(&launch, engine);
    return sessionCreateForRpc(engine, arena, params, &launch, null);
}

/// Save the session and its first input under one transaction and one response gate.
pub fn sessionCreateForRpc(engine: *Engine, arena: std.mem.Allocator, params: proto.misc.CreateSession, launch: *?run_task.Launch, diagnostic: ?*?[]const u8) !proto.session.SessionResult {
    std.debug.assert(launch.* == null);
    if (engine.closing) return error.EngineClosing;
    const root = try paths.canonicalizeWorkspace(arena, engine.deps.env, params.workspace_path);
    const parent: ?proto.ids.SessionId = if (params.child) |child| child.site.session_id else null;
    // A child inherits the parent's catalog. A root scans the two skill roots once.
    const catalog: skills.Catalog = if (parent) |pid| .{ .entries = try session_store.skillCatalog(engine.deps.db, arena, pid.raw), .skipped = &.{} } else try skills.load(arena, engine.deps.io, engine.deps.env, root);
    const notices = try skippedNotices(arena, catalog.skipped);
    const content: ?[]const proto.content.ContentPart = if (params.initial_input) |input| switch (input) {
        .content => |c| c.content,
        .skill => |invocation| try skillContent(engine, arena, catalog.entries, invocation, diagnostic),
    } else null;
    var parent_tree: ?admission.Location = null;
    var selected: ?proto.agents.AgentsResolveResult = null;
    if (params.child) |child| {
        if (content == null) return error.BadChild;
        if (!admission.validName(child.name)) return error.BadChildName;
        try engine.own(child.site.session_id);
        const row = (try session_store.snapshot(engine.deps.db, arena, child.site.session_id.raw)) orelse return error.UnknownSession;
        if (!std.mem.eql(u8, row.root, root)) return error.BadChild;
        parent_tree = try admission.location(engine, arena, child.site.session_id);
        if ((try engine.deps.db.queries.child_by_name.maybeOne(arena, .{ .parent_id = child.site.session_id.raw, .name = child.name })) != null) return error.DuplicateChildName;
        selected = try @import("agent_config.zig").resolve(engine, arena, .{ .model = child.slot });
        if (parent_tree.?.depth >= engine.max_agent_depth) return error.AgentDepthLimit;
        if (params.model) |model| if (!std.mem.eql(u8, model, selected.?.model)) return error.AgentConfigConflict;
        if (params.reasoning) |reasoning| if (!std.mem.eql(u8, reasoning, selected.?.reasoning)) return error.AgentConfigConflict;
        try validateParentSite(engine, child.site);
    }
    const id: proto.ids.SessionId = .bytes(engine.newId());
    if (content != null and parent == null) try engine.ownNewRoot(id);
    errdefer if (content != null and parent == null) engine.releaseRoot(id);
    const base = std.fs.path.basename(root);
    const title = if (params.child) |child| child.name else if (base.len == 0) root else base;
    const profile = params.profile orelse "default";
    const model = if (selected) |value| value.model else params.model orelse "";
    const reasoning = if (selected) |value| value.reasoning else params.reasoning orelse try defaultLevelOf(engine, arena, model);
    const prompts = @import("prompt.zig");
    const prompt_context: prompts.Context = .{ .workspace = root, .session_id = id, .agent_name = if (params.child) |child| child.name else "root" };
    const base_prompt = if (params.system_prompt) |text|
        try prompts.expand(arena, text, prompt_context)
    else if (parent) |pid|
        try session_store.basePrompt(engine.deps.db, arena, pid.raw)
    else if (engine.default_system_prompt) |text|
        try prompts.expand(arena, text, prompt_context)
    else
        prompts.default_system_prompt;
    const child_prompt = if (parent != null) try prompts.expand(arena, engine.child_instructions orelse prompts.default_child_instructions, prompt_context) else null;
    const sources = if (parent) |pid| try session_store.instructionSnapshots(engine.deps.db, arena, pid.raw) else try instructions.load(arena, engine.deps.io, engine.deps.env, root, diagnostic);
    const now = engine.nowMillis();
    const environment = try prompts.environment(arena, root, now);
    if (parent_tree) |tree| try reports.reserve(engine, arena, tree.root);
    const available = content != null and (parent_tree == null or try admission.available(engine, arena, parent_tree.?.root, id));
    var prepared: ?run.RunSlot.Prepared = null;
    errdefer if (prepared) |*held| held.deinit();
    const resident = if (content != null) try engine.sessions.getOrCreate(id) else null;
    errdefer if (resident != null) engine.sessions.remove(id);
    var queued: ?database.input.Entry = null;
    var started: ?run.Started = null;
    {
        var tx = try engine.deps.db.begin();
        defer tx.deinit();
        try session_store.create(engine.deps.db, .{
            .id = id.raw,
            .root = root,
            .origin = if (parent != null) "child" else "root",
            .parent_id = if (params.child) |child| child.site.session_id.raw else null,
            .parent_message_id = if (params.child) |child| child.site.message_id else null,
            .parent_part_id = if (params.child) |child| child.site.part_id else null,
            .name = if (params.child) |child| child.name else null,
            .profile = profile,
            .model = model,
            .reasoning = reasoning,
            .config_rev = 0,
            .max_rounds = params.max_rounds,
            .title = title,
            .created_at_ms = now,
            .updated_at_ms = now,
        });
        const system_prompt = try session_store.setPrompt(engine.deps.db, arena, id.raw, .{ .base = base_prompt, .child_policy = child_prompt, .environment = environment, .sources = sources, .skills = catalog.entries });
        if (available) prepared = try run.RunSlot.prepare(engine.deps.gpa, model, reasoning, system_prompt, params.max_rounds);
        try config_store.recordInitial(engine.deps.db, id.raw, model, reasoning);
        if (content) |parts| queued = try input_store.enqueue(engine.deps.db, arena, id.raw, engine.newId(), now, .{ .content = parts, .source = if (params.child) |child| .{ .parent_instruction = child.site } else null, .skill_name = if (params.initial_input.? == .skill) params.initial_input.?.skill.name else null }, now);
        if (prepared != null) started = try run.beginQueuedTurnInTransaction(engine.deps.db, engine.deps.io, arena, id.raw, 0);
        try tx.commit();
    }
    if (resident) |rt| {
        rt.hydrated = true;
        session_events.emitDurable(engine, rt, .{ .method = .@"input.queued", .params = .{ .input_queued_data = .{ .session_id = id, .seq = queued.?.seq, .input = queued.?.input } } });
        if (started) |run_start| {
            const location: run.RunSlot.Location = if (parent_tree) |tree| .{ .root = tree.root, .depth = tree.depth + 1 } else .{ .root = id, .depth = 0 };
            const slot = prepared.?.bind(run_start.handle, run_start.first_round, parent, location);
            rt.active_run = slot;
            launch.* = .{ .slot = slot };
            session_events.publishUserCommits(engine, rt, run_start.user_commits);
            session_events.emitDurable(engine, rt, .{ .method = .@"run.started", .params = .{ .run_started_data = run_start.handle.started } });
        } else if (parent) |pid| launch.* = .{ .wake = pid };
    }
    emitNotices(engine, notices);
    session_events.announceSummary(engine, id);
    return .{ .session = .{
        .id = id,
        .root = root,
        .profile = profile,
        .model = model,
        .reasoning = reasoning,
        .config_rev = 0,
        .max_rounds = params.max_rounds,
        .title = title,
        .message_count = if (started != null) 1 else 0,
        .usage_total = .{ .input = 0, .output = 0, .reasoning = 0, .cache_read = 0, .cache_write = 0 },
        .created_at_ms = now,
        .updated_at_ms = now,
        .origin = if (params.child) |child| .{ .child = .{ .site = child.site } } else .{ .root = .{} },
        .name = if (params.child) |child| child.name else null,
    }, .input = if (started) |run_start| .{ .started = .{
        .input_id = run_start.handle.input_id,
        .run_id = run_start.handle.started.run_id,
        .capacity = if (parent_tree) |tree| admission.capacity(engine, tree.root) else null,
    } } else if (queued) |entry| .{ .queued = .{
        .input_id = entry.input.input_id,
        .reason = .concurrency_limit,
        .capacity = if (parent_tree) |tree| admission.capacity(engine, tree.root) else null,
    } } else null };
}

const zio = @import("zio");
const ai = @import("ai");
const provider = @import("../provider/provider.zig");
const provider_store = @import("../provider/provider_store.zig");

/// These test dependencies use an empty environment. The map has no allocation to free.
var test_env: std.process.Environ.Map = .init(std.testing.allocator);
var test_transport = ai.transport.CannedTransport{ .bytes = ai.transport.canned_reply };

test "session.get and session.queue read the durable queue, resident or not" {
    var runtime = try zio.Runtime.init(std.testing.allocator, .{ .executors = .exact(1) });
    defer runtime.deinit();
    var db = try database.Database.openTest();
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const session_id = [_]u8{2} ** 16;
    try session_store.create(&db, .{
        .id = session_id,
        .root = "/boot",
        .origin = "root",
        .profile = "default",
        .model = "mock",
        .reasoning = "",
        .config_rev = 0,
        .title = "boot",
        .created_at_ms = 1,
        .updated_at_ms = 1,
    });
    try db.conn.execNoArgs("BEGIN IMMEDIATE");
    const queued = try input_store.enqueue(&db, arena, session_id, [_]u8{3} ** 16, 2, .{ .content = &.{.{ .text = .{ .text = "recover" } }} }, 2);
    try db.conn.execNoArgs("COMMIT");

    var store: provider_store = .init(std.testing.allocator, runtime.io(), &test_env);
    defer store.deinit();
    var engine = Engine.init(.{
        .gpa = std.testing.allocator,
        .io = runtime.io(),
        .db = &db,
        .providers = &store,
        .route_transport = test_transport.transport(),
        .env = &test_env,
        .tools = .{},
    });
    defer engine.close();
    defer db.deinit();

    const id: proto.ids.SessionId = .bytes(session_id);
    // Not resident: the durable row is idle, and the queue depth comes from the pending table.
    const durable = try sessionGet(&engine, arena, .{ .session_id = id });
    try std.testing.expect(durable.activity.state == .idle);
    try std.testing.expectEqual(@as(u64, 1), durable.activity.queued);
    try std.testing.expectEqualStrings("boot", durable.session.title);

    const queue = try sessionQueue(&engine, arena, .{ .session_id = id });
    try std.testing.expectEqual(@as(usize, 1), queue.items.len);
    try std.testing.expectEqual(queued.input.input_id, queue.items[0].input_id);
    try std.testing.expectEqualStrings("recover", queue.items[0].content[0].text.text);

    // Resident: the runtime answers, and its restored queue reports the same depth.
    const rt = try engine.activate(id);
    const resident = try sessionGet(&engine, arena, .{ .session_id = id });
    try std.testing.expectEqual(@as(u64, 1), resident.activity.queued);

    // A bound run slot makes the read report the live run, where the durable row says idle.
    var prepared = try run.RunSlot.prepare(std.testing.allocator, "mock", "", "", null);
    const slot = prepared.bind(
        .{ .input_id = 1, .started = .{ .session_id = id, .seq = 1, .run_id = 7, .kind = .turn, .config_rev = 0, .started_at_ms = 5 } },
        .{ .number = 1, .message_id = 1 },
        null,
        .{ .root = id, .depth = 0 },
    );
    rt.active_run = slot;
    defer {
        rt.active_run = null;
        slot.destroy();
    }
    const working = try sessionGet(&engine, arena, .{ .session_id = id });
    try std.testing.expect(working.activity.state == .building);
    try std.testing.expectEqual(@as(u64, 7), working.activity.state.building.run_id);
    try std.testing.expectEqual(@as(u64, 5), working.activity.state.building.started_at_ms);

    const listed = try sessionList(&engine, arena, .{});
    try std.testing.expectEqual(@as(usize, 1), listed.items.len);
    try std.testing.expect(listed.items[0].activity.state == .building);
    try std.testing.expectEqual(@as(u64, 1), listed.items[0].activity.queued);

    const child_id = [_]u8{5} ** 16;
    const other_root = [_]u8{6} ** 16;
    const other_child = [_]u8{7} ** 16;
    for ([_]struct { id: [16]u8, root: []const u8, parent_id: ?[16]u8, name: ?[]const u8 }{
        .{ .id = child_id, .root = "/boot", .parent_id = session_id, .name = "research" },
        .{ .id = other_root, .root = "/other", .parent_id = null, .name = null },
        .{ .id = other_child, .root = "/other", .parent_id = other_root, .name = "research" },
    }) |entry| try session_store.create(&db, .{
        .id = entry.id,
        .root = entry.root,
        .origin = if (entry.parent_id == null) "root" else "child",
        .parent_id = entry.parent_id,
        .parent_message_id = if (entry.parent_id != null) 1 else null,
        .parent_part_id = if (entry.parent_id != null) 0 else null,
        .name = entry.name,
        .profile = "default",
        .model = "mock",
        .reasoning = "",
        .config_rev = 0,
        .title = entry.name orelse "other",
        .created_at_ms = 1,
        .updated_at_ms = 1,
    });
    try std.testing.expectEqual(child_id, (try sessionGet(&engine, arena, .{ .session_id = id, .child_name = "research" })).session.id.raw);
    try std.testing.expectEqual(other_child, (try sessionGet(&engine, arena, .{ .session_id = .bytes(other_root), .child_name = "research" })).session.id.raw);
    try std.testing.expectError(error.UnknownSession, sessionGet(&engine, arena, .{ .session_id = id, .child_name = "missing" }));
    try std.testing.expectError(error.BadChildName, sessionGet(&engine, arena, .{ .session_id = id, .child_name = "../research" }));

    try std.testing.expectError(error.UnknownSession, sessionGet(&engine, arena, .{ .session_id = .bytes([_]u8{9} ** 16) }));
    try std.testing.expectError(error.UnknownSession, sessionQueue(&engine, arena, .{ .session_id = .bytes([_]u8{9} ** 16) }));
}

test "a new session takes the catalog default level, and a stated level stays" {
    var runtime = try zio.Runtime.init(std.testing.allocator, .{ .executors = .exact(1) });
    defer runtime.deinit();
    var db = try database.Database.openTest();
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var store: provider_store = .init(std.testing.allocator, runtime.io(), &test_env);
    defer store.deinit();
    var loaded = try provider.config.loadBytes(std.testing.allocator,
        \\{"version":1,"providers":[{"id":"minimax","api_key":"k"}]}
    );
    _ = try store.installLocal(&loaded);
    var engine = Engine.init(.{
        .gpa = std.testing.allocator,
        .io = runtime.io(),
        .db = &db,
        .providers = &store,
        .route_transport = test_transport.transport(),
        .env = &test_env,
        .tools = .{},
    });
    defer engine.close();
    defer db.deinit();

    const by_default = try sessionCreate(&engine, arena, .{ .workspace_path = "/tmp", .model = "minimax/MiniMax-M3" });
    try std.testing.expectEqualStrings("high", by_default.session.reasoning);
    const stated = try sessionCreate(&engine, arena, .{ .workspace_path = "/tmp", .model = "minimax/MiniMax-M3", .reasoning = "off" });
    try std.testing.expectEqualStrings("off", stated.session.reasoning);
    const unknown = try sessionCreate(&engine, arena, .{ .workspace_path = "/tmp", .model = "nope/nope" });
    try std.testing.expectEqualStrings("", unknown.session.reasoning);
    // A stated empty level is a choice, not an absence, so the default does not replace it.
    const empty = try sessionCreate(&engine, arena, .{ .workspace_path = "/tmp", .model = "minimax/MiniMax-M3", .reasoning = "" });
    try std.testing.expectEqualStrings("", empty.session.reasoning);
}
