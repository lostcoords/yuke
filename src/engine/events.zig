//! Project and publish session events. Commands and run tasks share this boundary.

const std = @import("std");
const proto = @import("proto");
const Engine = @import("Engine.zig");
const Session = @import("../session/session.zig").Session;
const RunSlot = @import("../session/session.zig").RunSlot;
const context = @import("context.zig");
const database = @import("../store/store.zig");

const session_store = database.session;

/// Map a durable session row to its origin. A broken schema invariant is database corruption.
fn sessionOrigin(row: anytype) !proto.session.SessionOrigin {
    if (std.mem.eql(u8, row.origin, "root")) {
        if (row.parent_id != null or row.parent_message_id != null or row.parent_part_id != null or row.source_id != null)
            return error.CorruptDatabase;
        return .{ .root = .{} };
    }
    if (std.mem.eql(u8, row.origin, "child")) {
        if (row.parent_id == null or row.parent_message_id == null or row.parent_part_id == null or row.source_id != null)
            return error.CorruptDatabase;
        return .{ .child = .{ .site = .{
            .session_id = .bytes(row.parent_id.?),
            .message_id = row.parent_message_id.?,
            .part_id = row.parent_part_id.?,
        } } };
    }
    if (std.mem.eql(u8, row.origin, "fork")) {
        if (row.parent_id != null or row.parent_message_id != null or row.parent_part_id != null or row.source_id == null)
            return error.CorruptDatabase;
        return .{ .fork = .{ .source_id = .bytes(row.source_id.?) } };
    }
    return error.CorruptDatabase;
}

/// Project one durable session row onto its public list item.
pub fn sessionItem(arena: std.mem.Allocator, row: anytype) !proto.session.SessionListItem {
    const created_by = if (row.created_by_name) |name| blk: {
        if (row.created_by_version == null) return error.CorruptDatabase;
        break :blk proto.initialize.Client{
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
            .root = try arena.dupe(u8, row.root),
            .model = try arena.dupe(u8, row.model),
            .reasoning = try arena.dupe(u8, row.reasoning),
            .config_rev = row.config_rev,
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
            .cost = .{
                .total = row.cost_total,
                .without_cache = row.cost_without_cache_total,
                .unpriced = row.unpriced_count,
            },
            .created_at_ms = row.created_at_ms,
            .updated_at_ms = row.updated_at_ms,
            .created_by = created_by,
            .origin = try sessionOrigin(row),
            .name = if (row.name) |text| try arena.dupe(u8, text) else null,
        },
        .activity = .{
            .state = .{ .idle = .{} },
            .config = null,
            .queued = 0,
            // The list fills the live values, because a row holds no count.
            .context_tokens = 0,
            .pending_compaction = null,
        },
    };
}

/// Build an activity from the session projection and its context count.
fn sessionActivity(
    arena: std.mem.Allocator,
    session: *Session,
    slot: ?*RunSlot,
    context_tokens: u64,
) !proto.session.SessionActivity {
    var activity: proto.session.SessionActivity = .{
        .state = .{ .idle = .{} },
        .config = null,
        .queued = session.queueDepth(),
        .context_tokens = context_tokens,
        .pending_compaction = if (session.pending_compaction) |pending| pending.run_id else null,
    };

    const run = slot orelse {
        std.debug.assert(session.draft == null); // A live draft belongs to an active run.
        return activity;
    };
    activity.config = try proto.dupe(arena, proto.run.RunConfig{
        .config_rev = run.handle.started.config_rev,
        .model = run.config.model,
        .reasoning = run.config.reasoning,
    });
    if (session.draft) |*draft| std.debug.assert(draft.config_rev == run.handle.started.config_rev); // one run pins one revision
    if (run.compacting) {
        std.debug.assert(run.round == .none); // compaction runs before the round opens
        activity.state = .{ .compacting = .{ .run_id = run.handle.started.run_id, .reason = .auto, .started_at_ms = run.handle.started.started_at_ms } };
        return activity;
    }
    activity.state = switch (run.round) {
        .retrying => |retry| try proto.dupe(arena, proto.activity.ActivityState{ .retrying = retry }),
        // The draft is open before the send, so the draft alone does not mean the provider answered.
        .waiting => .{ .waiting = .{ .run_id = run.handle.started.run_id, .started_at_ms = run.handle.started.started_at_ms } },
        // A draft with no open round runs its tools between two rounds.
        .streaming, .none => if (session.draft) |*draft| try proto.dupe(arena, draft.deriveStreamingState(run.handle.started.started_at_ms)) else switch (run.handle.started.kind) {
            .turn => .{ .building = .{ .run_id = run.handle.started.run_id, .started_at_ms = run.handle.started.started_at_ms } },
            .compaction => blk: {
                std.debug.assert(run.handle.started.reason != null); // the engine sets the reason at every compaction start
                break :blk .{ .compacting = .{ .run_id = run.handle.started.run_id, .reason = run.handle.started.reason.?, .started_at_ms = run.handle.started.started_at_ms } };
            },
        },
    };
    std.debug.assert(run.round != .streaming or session.draft != null); // a stream writes into an open draft
    return activity;
}

/// Build the activity of one resident session.
pub fn residentActivity(engine: *Engine, arena: std.mem.Allocator, rt: *Session) !proto.session.SessionActivity {
    // A commit, a durable event, or a new prompt estimate clears the cached count.
    const tokens = rt.context_tokens orelse blk: {
        // The next request goes to the model that the run pinned, or to the session model between runs.
        const model = if (rt.active_run) |run| run.config.model else null;
        const read = try context.count(engine.deps.gpa, engine.deps.db, rt.id.raw, model, null);
        rt.context_tokens = read;
        break :blk read;
    };
    return sessionActivity(arena, rt, rt.active_run, tokens);
}

/// Fold a durable engine event into the session, then publish the same value.
pub fn emitDurable(engine: *Engine, rt: *Session, note: proto.rpc.Notification) void {
    std.debug.assert(note.method != .@"message.committed");
    // A durable event can move the committed set, so the gauge is re-read on the next activity.
    rt.context_tokens = null;
    // The engine produced this event against its own engine, so a rejection here is a bug.
    rt.apply(note.params) catch |err|
        std.debug.panic("cannot fold the durable event {t}: {t}", .{ note.method, err });
    engine.sinks.emit(note);
}

/// Fold the committed message into the session, then publish the copy that the history owns. The commit message can borrow the draft, and the fold frees the draft.
pub fn emitCommitted(engine: *Engine, rt: *Session, commit: proto.message.MessageCommittedData) void {
    rt.context_tokens = null;
    var held = commit;
    held.message = rt.commit(commit) catch |err|
        std.debug.panic("cannot fold the committed message: {t}", .{err});
    engine.sinks.emit(.{ .method = .@"message.committed", .params = .{ .message_committed_data = held } });
}

/// Fold and publish committed user messages, then announce the moved summary.
pub fn publishUserCommits(engine: *Engine, rt: *Session, commits: []const proto.message.MessageCommittedData) void {
    for (commits) |commit| emitCommitted(engine, rt, commit);
    if (commits.len > 0) announceSummary(engine, rt.id);
}

/// Publish the activity after a phase or queue transition.
pub fn announceActivity(engine: *Engine, rt: *Session) void {
    var arena_state: std.heap.ArenaAllocator = .init(engine.deps.gpa);
    defer arena_state.deinit();
    const activity = residentActivity(engine, arena_state.allocator(), rt) catch |err| {
        std.log.warn("cannot build the activity for session {x}: {t}", .{ &rt.id.raw, err });
        return;
    };
    engine.sinks.emit(.{
        .method = .@"session.activity_changed",
        .params = .{ .session_activity_changed_data = .{ .session_id = rt.id, .activity = activity } },
    });
}

/// Publish the summary after its durable projection changes.
pub fn announceSummary(engine: *Engine, session_id: proto.ids.SessionId) void {
    var arena_state: std.heap.ArenaAllocator = .init(engine.deps.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const snapshot = session_store.snapshot(engine.deps.db, arena, session_id.raw) catch |err| {
        std.log.warn("cannot re-read the summary for session {x}: {t}", .{ &session_id.raw, err });
        return;
    } orelse return;
    const item = sessionItem(arena, snapshot) catch |err| {
        std.log.warn("cannot project the summary for session {x}: {t}", .{ &session_id.raw, err });
        return;
    };

    const revision = engine.session_revision + 1;
    publishIndex(engine, revision, .{ .method = .@"session.summary_changed", .params = .{
        .session_summary_changed_data = .{ .revision = revision, .session = item.session },
    } });
}

/// Publish the removal after the delete, so no client hears of a session that it can read.
pub fn announceRemoved(engine: *Engine, session_id: proto.ids.SessionId) void {
    const revision = engine.session_revision + 1;
    publishIndex(engine, revision, .{ .method = .@"session.removed", .params = .{
        .session_removed_data = .{ .revision = revision, .session_id = session_id },
    } });
}

/// Advance the index revision, then hand the event to the subscriber.
fn publishIndex(engine: *Engine, revision: proto.ids.SessionRevision, note: proto.rpc.Notification) void {
    std.debug.assert(revision == engine.session_revision + 1);
    engine.session_revision = revision;
    engine.sinks.emit(note);
}
