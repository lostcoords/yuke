//! Request handlers. Each builds a wire result from the stores.
//! Each handler owns its write transaction.

const std = @import("std");
const wire = @import("wire");
const State = @import("State.zig");
const database = @import("../database/database.zig");

const session_store = database.session;
const workspace_store = database.workspace;

/// Handle session.create: resolve the workspace, mint ids, insert the session, and return it.
/// The broadcast fan-out is a later slice; this returns the result only.
pub fn sessionCreate(state: *State, arena: std.mem.Allocator, params: wire.misc.CreateSession) !wire.session.SessionResult {
    // The raw path is the dedup key for now. Canonicalization is a later workspace-chunk refinement.
    const root = params.workspace_path orelse state.home;
    const base = std.fs.path.basename(root);
    const title = if (base.len == 0) root else base;
    const profile = params.profile orelse "default";
    const model = params.model orelse "";
    const reasoning = params.reasoning orelse "";
    const permission = params.permission orelse .normal;
    const now = state.nowMillis();

    var workspace_id: [16]u8 = undefined;
    state.io.random(&workspace_id);
    var id: [16]u8 = undefined;
    state.io.random(&id);

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
    if (params.system_prompt) |prompt| try session_store.setPrompt(&state.db, id, prompt);
    try state.db.conn.execNoArgs("COMMIT");

    return .{ .session = .{
        .id = id,
        .workspace_id = workspace.id,
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
