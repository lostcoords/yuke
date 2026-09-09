//! Project and publish session events. Commands and run tasks share this boundary.

const std = @import("std");
const proto = @import("proto");
const Engine = @import("Engine.zig");
const Session = @import("../session/session.zig").Session;
const database = @import("../store/store.zig");

const message_store = database.message;
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

/// The context gauge that `session_context` joined onto the row.
pub fn contextUsage(row: anytype) proto.message.TokenUsage {
    return .{
        .input = row.ctx_tokens_input orelse 0,
        .output = row.ctx_tokens_output orelse 0,
        .reasoning = row.ctx_tokens_reasoning orelse 0,
        .cache_read = row.ctx_tokens_cache_read orelse 0,
        .cache_write = row.ctx_tokens_cache_write orelse 0,
    };
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
            .profile = try arena.dupe(u8, row.profile),
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
            .created_at_ms = row.created_at_ms,
            .updated_at_ms = row.updated_at_ms,
            .created_by = created_by,
            .origin = try sessionOrigin(row),
            .agent = if (row.agent) |text| try arena.dupe(u8, text) else null,
            .name = if (row.name) |text| try arena.dupe(u8, text) else null,
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

/// The active run identity that an activity projection needs.
pub const RunInfo = struct {
    run_id: proto.ids.RunId,
    started_at_ms: u64,
    kind: proto.enums.RunKind,
    /// The reason for a compaction run. A turn carries none.
    reason: ?proto.enums.CompactionReason = null,
    /// The run pins one config revision, so the activity reads it here and never queries.
    config: proto.run.RunConfig,
    retry: ?proto.activity.ActivityStateRetrying = null,
    compacting: bool = false,
};

/// Build an activity from the session projection and its context usage.
fn sessionActivity(
    arena: std.mem.Allocator,
    session: *Session,
    run_info: ?RunInfo,
    context_usage: proto.message.TokenUsage,
) !proto.session.SessionActivity {
    var activity: proto.session.SessionActivity = .{
        .state = .{ .idle = .{} },
        .config = null,
        .queued = session.queueDepth(),
        .context_usage = context_usage,
        .pending_compaction = if (session.pending_compaction) |pending| pending.run_id else null,
    };

    const waiting: ?proto.activity.ActivityStateRetrying = if (run_info) |run| run.retry else null;
    if (run_info != null and run_info.?.compacting) {
        const run = run_info.?;
        activity.state = .{ .compacting = .{ .run_id = run.run_id, .reason = .auto, .started_at_ms = run.started_at_ms } };
        activity.config = try proto.dupe(arena, run.config);
    } else if (waiting) |retry| {
        activity.state = try proto.dupe(arena, proto.activity.ActivityState{ .retrying = retry });
        if (session.active_run != null) activity.config = try proto.dupe(arena, run_info.?.config);
    } else if (session.draft) |*draft| {
        std.debug.assert(run_info != null); // A live draft belongs to an active run.
        std.debug.assert(draft.config_rev == run_info.?.config.config_rev); // one run pins one revision
        activity.state = try proto.dupe(arena, draft.deriveStreamingState(run_info.?.started_at_ms));
        activity.config = try proto.dupe(arena, run_info.?.config);
    } else if (run_info) |run| switch (run.kind) {
        .turn => activity.state = .{ .building = .{ .run_id = run.run_id, .started_at_ms = run.started_at_ms } },
        .compaction => {
            std.debug.assert(run.reason != null); // the engine sets the reason at every compaction start
            activity.state = .{ .compacting = .{ .run_id = run.run_id, .reason = run.reason.?, .started_at_ms = run.started_at_ms } };
        },
    };
    return activity;
}

/// Build the activity of one resident session.
pub fn residentActivity(engine: *Engine, arena: std.mem.Allocator, rt: *Session) !proto.session.SessionActivity {
    const session_id = rt.id.raw;
    const run_info: ?RunInfo = if (rt.active_run) |slot| .{
        .run_id = slot.handle.started.run_id,
        .started_at_ms = slot.handle.started.started_at_ms,
        .kind = slot.handle.started.kind,
        .reason = slot.handle.started.reason,
        .config = .{
            .config_rev = slot.handle.started.config_rev,
            .model = slot.config.model,
            .reasoning = slot.config.reasoning,
        },
        .retry = slot.retry_state,
        .compacting = slot.compacting,
    } else null;
    // Only a committed message moves the gauge, and nothing commits inside a round.
    const usage = rt.context_usage orelse blk: {
        const read = try message_store.contextUsage(engine.deps.db, arena, session_id);
        rt.context_usage = read;
        break :blk read;
    };
    return sessionActivity(arena, rt, run_info, usage);
}

/// Fold a durable engine event into the session, then publish the same value.
pub fn emitDurable(engine: *Engine, rt: *Session, note: proto.rpc.Notification) void {
    // A durable event can move the committed set, so the gauge is re-read on the next activity.
    rt.context_usage = null;
    // The engine produced this event against its own engine, so a rejection here is a bug.
    rt.apply(note.params) catch |err|
        std.debug.panic("cannot fold the durable event {t}: {t}", .{ note.method, err });
    engine.sinks.emit(note);
}

/// Fold and publish committed user messages, then announce the moved summary.
pub fn publishUserCommits(engine: *Engine, rt: *Session, commits: []const proto.message.MessageCommittedData) void {
    for (commits) |commit| emitDurable(engine, rt, .{
        .method = .@"message.committed",
        .params = .{ .message_committed_data = commit },
    });
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
