//! Request handlers. Each builds a wire result from the stores.
//! Each handler owns its write transaction.

const std = @import("std");
const wire = @import("wire");
const State = @import("State.zig");
const database = @import("../database/database.zig");

const session_store = database.session;
const workspace_store = database.workspace;

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
        .workspace => |workspace| sel.workspace_id = workspace.workspace_id,
    }
    switch (params.population) {
        .top_level => sel.top_level = true,
        .children => |children| sel.parent_id = children.parent_id,
        .all => {},
    }
    return sel;
}

fn copyOptional(arena: std.mem.Allocator, value: ?[]const u8) !?[]const u8 {
    return if (value) |text| try arena.dupe(u8, text) else null;
}

fn sessionOrigin(row: session_store.PageRow) wire.session.SessionOrigin {
    if (std.mem.eql(u8, row.origin, "root")) {
        std.debug.assert(row.parent_id == null);
        std.debug.assert(row.parent_message_id == null);
        std.debug.assert(row.parent_part_id == null);
        std.debug.assert(row.source_id == null);
        return .{ .root = .{} };
    }
    if (std.mem.eql(u8, row.origin, "child")) {
        std.debug.assert(row.parent_id != null);
        std.debug.assert(row.parent_message_id != null);
        std.debug.assert(row.parent_part_id != null);
        std.debug.assert(row.source_id == null);
        return .{ .child = .{
            .parent_id = row.parent_id.?,
            .parent_message_id = row.parent_message_id.?,
            .parent_part_id = row.parent_part_id.?,
        } };
    }
    if (std.mem.eql(u8, row.origin, "fork")) {
        std.debug.assert(row.parent_id == null);
        std.debug.assert(row.parent_message_id == null);
        std.debug.assert(row.parent_part_id == null);
        std.debug.assert(row.source_id != null);
        return .{ .fork = .{ .source_id = row.source_id.? } };
    }
    std.debug.assert(false);
    unreachable;
}

fn sessionItem(arena: std.mem.Allocator, row: session_store.PageRow) !wire.session.SessionListItem {
    const permission = std.meta.stringToEnum(wire.enums.PermissionMode, row.permission);
    std.debug.assert(permission != null);

    const created_by = if (row.created_by_name) |name| blk: {
        std.debug.assert(row.created_by_version != null);
        break :blk wire.initialize.Client{
            .name = try arena.dupe(u8, name),
            .version = try arena.dupe(u8, row.created_by_version.?),
        };
    } else blk: {
        std.debug.assert(row.created_by_version == null);
        break :blk null;
    };

    return .{
        .session = .{
            .id = row.id,
            .workspace_id = row.workspace_id,
            .profile = try arena.dupe(u8, row.profile),
            .model = try arena.dupe(u8, row.model),
            .reasoning = try arena.dupe(u8, row.reasoning),
            .config_rev = row.config_rev,
            .permission = permission.?,
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
            .origin = sessionOrigin(row),
            .agent = try copyOptional(arena, row.agent),
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

/// Handle session.list from durable state. The active view needs the reactor live-session set in a later slice.
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
