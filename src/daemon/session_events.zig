//! Project and publish session events. Request handlers and run tasks share this boundary.

const std = @import("std");
const wire = @import("wire");
const State = @import("State.zig");
const connection = @import("connection.zig");
const session_runtime = @import("session_runtime.zig");
const domain_session = @import("domain").session;
const database = @import("../database/database.zig");

const config_store = database.config;
const message_store = database.message;
const session_store = database.session;

/// Map a durable session row to its origin. A broken schema invariant is database corruption.
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

/// The context gauge that `session_context` joined onto the row.
pub fn contextUsage(row: anytype) wire.message.TokenUsage {
    return .{
        .input = row.ctx_tokens_input orelse 0,
        .output = row.ctx_tokens_output orelse 0,
        .reasoning = row.ctx_tokens_reasoning orelse 0,
        .cache_read = row.ctx_tokens_cache_read orelse 0,
        .cache_write = row.ctx_tokens_cache_write orelse 0,
    };
}

/// Project one durable session row onto its public list item.
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

/// The active run identity that an activity projection needs.
pub const RunInfo = struct {
    run_id: wire.ids.RunId,
    started_at_ms: u64,
    retry: ?wire.activity.ActivityStateRetrying = null,
};

/// Build an activity from the session projection and its context usage.
pub fn sessionActivity(
    state: *State,
    arena: std.mem.Allocator,
    session_id: [16]u8,
    session: *domain_session.Session,
    run_info: ?RunInfo,
    context_usage: wire.message.TokenUsage,
) !wire.session.SessionActivity {
    var active_config: ?wire.run.RunConfig = null;
    if (session.active) |*draft| {
        const cached = session.configs.get(draft.config_rev);
        active_config = cached orelse (try config_store.byRevision(&state.db, arena, session_id, draft.config_rev)) orelse return error.CorruptLog;
    }

    var activity: wire.session.SessionActivity = .{
        .state = .{ .idle = .{} },
        .config = null,
        .queued = session.queue.depth(),
        .context_usage = context_usage,
        .pending_compaction = null,
    };

    const waiting: ?wire.activity.ActivityStateRetrying = if (run_info) |run| run.retry else null;
    if (waiting) |retry| {
        activity.state = try wire.dupe(arena, wire.activity.ActivityState{ .retrying = retry });
        if (session.active != null) activity.config = try wire.dupe(arena, active_config.?);
    } else if (session.active) |*draft| {
        std.debug.assert(run_info != null); // A live draft belongs to an active run.
        activity.state = try wire.dupe(arena, draft.deriveStreamingState(run_info.?.started_at_ms));
        activity.config = try wire.dupe(arena, active_config.?);
    } else if (run_info) |run| {
        activity.state = .{ .building = .{ .run_id = run.run_id, .started_at_ms = run.started_at_ms } };
    }
    return activity;
}

/// Build the activity of one resident session.
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

/// Fold a durable daemon event into the session, then publish the same value.
pub fn emitDurable(state: *State, rt: *session_runtime.SessionRuntime, note: wire.rpc.Notification) void {
    rt.session.applyAuthoritative(note.params) catch |err| {
        std.debug.panic("cannot fold the durable event {t}: {t}", .{ note.method, err });
    };
    publishBestEffort(state, rt.session.id, note);
}

/// Fold and publish committed user messages, then announce the moved summary.
pub fn publishUserCommits(state: *State, rt: *session_runtime.SessionRuntime, commits: []const wire.message.MessageCommittedData) void {
    for (commits) |commit| emitDurable(state, rt, .{
        .method = .@"message.committed",
        .params = .{ .message_committed_data = commit },
    });
    if (commits.len > 0) announceSummary(state, rt.session.id);
}

/// Publish the activity after a phase or queue transition.
pub fn announceActivity(state: *State, rt: *session_runtime.SessionRuntime) void {
    var arena_state: std.heap.ArenaAllocator = .init(state.gpa);
    defer arena_state.deinit();
    const activity = residentActivity(state, arena_state.allocator(), rt) catch |err| {
        std.log.warn("cannot build the activity for session {x}: {t}", .{ &rt.session.id.raw, err });
        return;
    };
    publishBestEffort(state, rt.session.id, .{
        .method = .@"session.activity_changed",
        .params = .{ .session_activity_changed_data = .{ .session_id = rt.session.id, .activity = activity } },
    });
}

/// Publish the summary after its durable projection changes.
pub fn announceSummary(state: *State, session_id: wire.ids.SessionId) void {
    var arena_state: std.heap.ArenaAllocator = .init(state.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const snapshot = session_store.snapshot(&state.db, arena, session_id.raw) catch |err| {
        std.log.warn("cannot re-read the summary for session {x}: {t}", .{ &session_id.raw, err });
        return;
    } orelse return;
    const item = sessionItem(arena, snapshot) catch |err| {
        std.log.warn("cannot project the summary for session {x}: {t}", .{ &session_id.raw, err });
        return;
    };

    const revision = state.session_revision + 1;
    publishIndex(state, revision, .{ .method = .@"session.summary_changed", .params = .{
        .session_summary_changed_data = .{ .revision = revision, .session = item.session },
    } });
}

/// Publish the workspace after the commit, so each client learns of a row that it can read.
pub fn announceWorkspaceCreated(state: *State, workspace: wire.workspace.Workspace) void {
    const note: wire.rpc.Notification = .{ .method = .@"workspace.created", .params = .{
        .workspace_created_data = .{ .workspace = workspace },
    } };
    const bytes = connection.frameNotification(state.gpa, note) catch |err| {
        std.log.warn("cannot frame {t}: {t}", .{ note.method, err });
        return;
    };
    defer state.gpa.free(bytes);
    state.registry.publishAll(bytes);
}

/// Publish the removal after the delete, so no client hears of a session that it can read.
pub fn announceRemoved(state: *State, session_id: wire.ids.SessionId) void {
    const revision = state.session_revision + 1;
    publishIndex(state, revision, .{ .method = .@"session.removed", .params = .{
        .session_removed_data = .{ .revision = revision, .session_id = session_id },
    } });
}

/// Frame one index event and send it to each connection. A failed frame keeps the revision.
fn publishIndex(state: *State, revision: wire.ids.SessionRevision, note: wire.rpc.Notification) void {
    std.debug.assert(revision == state.session_revision + 1);
    const bytes = connection.frameNotification(state.gpa, note) catch |err| {
        std.log.warn("cannot frame {t}: {t}", .{ note.method, err });
        return;
    };
    defer state.gpa.free(bytes);
    state.session_revision = revision;
    state.registry.publishAll(bytes);
}

pub fn publishBestEffort(state: *State, session_id: wire.ids.SessionId, note: wire.rpc.Notification) void {
    publish(state, session_id, note) catch |err| {
        std.log.warn("cannot publish {t}: {t}", .{ note.method, err });
    };
}

pub fn publish(state: *State, session_id: wire.ids.SessionId, note: wire.rpc.Notification) !void {
    const bytes = try connection.frameNotification(state.gpa, note);
    defer state.gpa.free(bytes);
    state.registry.publish(session_id, bytes, connection.classOf(note.method));
}
