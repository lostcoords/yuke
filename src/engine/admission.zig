//! One child scheduler reads the durable queue and counts resident runs through cleanup.

const std = @import("std");
const proto = @import("proto");
const Engine = @import("Engine.zig");
const database = @import("../store/store.zig");
const turn = @import("turn.zig");

pub const Location = struct { root: proto.ids.SessionId, depth: u32 };

/// Parent links define the tree; forks start at depth zero.
pub fn location(engine: *Engine, arena: std.mem.Allocator, session_id: proto.ids.SessionId) !Location {
    if (engine.sessions.get(session_id)) |resident| if (resident.active_run) |slot| {
        if (slot.tree_root) |root| return .{ .root = root, .depth = slot.depth };
    };
    var id = session_id.raw;
    var depth: u32 = 0;
    var seen: std.AutoHashMapUnmanaged([16]u8, void) = .empty;
    while (true) {
        if ((try seen.getOrPut(arena, id)).found_existing) return error.CorruptDatabase;
        const row = (try database.session.snapshot(engine.deps.db, arena, id)) orelse return error.UnknownSession;
        id = row.parent_id orelse return .{ .root = .bytes(id), .depth = depth };
        depth = std.math.add(u32, depth, 1) catch return error.CorruptDatabase;
    }
}

pub fn capacity(engine: *Engine, root: proto.ids.SessionId) proto.session.ChildCapacity {
    std.debug.assert(engine.max_concurrent_children > 0);
    var active: u64 = 0;
    var residents = engine.sessions.map.valueIterator();
    while (residents.next()) |resident| {
        const slot = resident.*.active_run orelse continue;
        std.debug.assert(slot.parent_id == null or slot.tree_root != null);
        if (slot.parent_id != null) if (slot.tree_root) |id| if (std.mem.eql(u8, &id.raw, &root.raw)) {
            active += 1;
        };
    }
    return .{ .active = active, .limit = engine.max_concurrent_children };
}

/// Return the oldest eligible child; active and faulted children keep their place until eligible.
fn next(engine: *Engine, arena: std.mem.Allocator, parent: proto.ids.SessionId) !?proto.ids.SessionId {
    var rows = try engine.deps.db.queries.child_admission_candidates.rows(.{ .parent_id = parent.raw });
    defer rows.deinit();
    while (try rows.next(arena)) |row| {
        const id: proto.ids.SessionId = .bytes(row.value.id);
        if (engine.sessions.get(id)) |resident| {
            if (resident.active_run != null or resident.faulted) continue;
        }
        return id;
    }
    return null;
}

pub fn available(engine: *Engine, arena: std.mem.Allocator, root: proto.ids.SessionId, candidate: proto.ids.SessionId) !bool {
    const slots = capacity(engine, root);
    if (slots.active >= slots.limit) return false;
    const first = try next(engine, arena, root) orelse return true;
    return std.mem.eql(u8, &first.raw, &candidate.raw);
}

/// Drain without recursion when a synchronous launch failure frees a slot.
pub fn drain(engine: *Engine, parent: proto.ids.SessionId) !void {
    if (engine.closing) return;
    try engine.own(parent);
    var scratch: std.heap.ArenaAllocator = .init(engine.deps.gpa);
    defer scratch.deinit();
    const root = (try location(engine, scratch.allocator(), parent)).root;
    if (engine.owners.get(root.raw).?.admitting) return;
    engine.owners.getPtr(root.raw).?.admitting = true;
    defer engine.owners.getPtr(root.raw).?.admitting = false;
    while (!engine.closing) {
        const slots = capacity(engine, root);
        if (slots.active >= slots.limit) return;
        const id = try next(engine, scratch.allocator(), root) orelse return;
        const resident = try engine.activate(id);
        const slot = try turn.prepareQueued(engine, resident);
        turn.launchSlot(engine, slot) catch {};
        _ = scratch.reset(.retain_capacity);
    }
}

pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64 or std.mem.eql(u8, name, "root")) return false;
    if (name[0] < 'a' or name[0] > 'z') return false;
    for (name) |c| if (!(c >= 'a' and c <= 'z') and !std.ascii.isDigit(c) and c != '_' and c != '-') return false;
    return true;
}
