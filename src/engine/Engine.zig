//! The engine owns resident sessions and turn tasks and borrows process resources through `Deps`.

const std = @import("std");
const ai = @import("ai");
const proto = @import("proto");
const database = @import("../store/store.zig");
const provider = @import("../provider/provider.zig");
const provider_store = @import("../provider/provider_store.zig");
const Session = @import("../session/session.zig").Session;
const session = @import("../session/session.zig");
const retry = @import("ai").retry;
const transcript = @import("../session/transcript.zig");
const util = @import("../util.zig");
const zio = @import("zio");
const Sinks = @import("sink.zig").Sinks;
const toolset = @import("toolset.zig");
const hookset = @import("hookset.zig");
const execution = @import("../execution.zig");

const reports = @import("reports.zig");
const ownership = @import("ownership.zig");
const run_task = @import("turn.zig");
const session_events = @import("events.zig");

const Engine = @This();

/// Every process resource a turn may reach. The process owns each one and outlives the engine.
pub const Deps = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    /// The one SQLite connection. The process opens and closes it.
    db: *database.Database,
    /// The merged provider view. A turn resolves a model against it.
    providers: *provider_store,
    /// Every resolved route opens its response through this transport.
    route_transport: ai.transport.Transport,
    /// The startup answers every turn reads: the effective environment and the one command shell.
    execution: execution.Context,
    /// The tools this process can run. The engine borrows the set from the extension owner.
    tools: toolset.ToolSet = .{},
    /// The hooks this process can ask. The engine borrows the set from the same owner.
    hooks: hookset.HookSet = .{},
    retry_policy: retry.Policy = .{},
    /// Retry permits for one whole run.
    retry_budget: u8 = 8,
};

deps: Deps,
agents: @import("agent_config.zig").Store = .{},
/// Live per-session state, keyed by session id. A pane pins the session it shows.
sessions: session.Registry,
/// Every turn task. `close` cancels this group before the process closes the transport.
turn_tasks: std.Io.Group = .init,
/// Every subscriber that reads engine events. A frontend installs itself at startup.
sinks: Sinks = .{},
/// A null override selects the built-in base for new root sessions.
default_system_prompt: ?[]const u8 = null,
child_instructions: ?[]const u8 = null,
/// The in-memory session index revision. A restart clears it.
session_revision: u64 = 0,
/// Set while the engine closes, so a finished turn starts no successor.
closing: bool = false,
/// A claim spans repair, turns, idle periods, and native cleanup.
owners: std.AutoHashMapUnmanaged([16]u8, ownership.Guard) = .empty,
owner_mutex: std.Io.Mutex = .init,
max_concurrent_children: u32 = 8,
max_agent_depth: u32 = 1,

/// Claim a fresh root before its creation transaction can expose it.
pub fn ownNewRoot(self: *Engine, id: proto.ids.SessionId) !void {
    if (self.closing) return error.EngineClosing;
    try self.owner_mutex.lock(self.deps.io);
    defer self.owner_mutex.unlock(self.deps.io);
    if (self.closing) return error.EngineClosing;
    std.debug.assert(!self.owners.contains(id.raw));
    try self.owners.ensureUnusedCapacity(self.deps.gpa, 1);
    var guard = try ownership.acquire(self.deps.gpa, self.deps.io, self.deps.db, id.raw);
    if (self.closing) {
        guard.release(self.deps.io);
        return error.EngineClosing;
    }
    guard.repaired = true;
    self.owners.putAssumeCapacity(id.raw, guard);
}

/// Release a root claim after its last resident leaves.
pub fn releaseRoot(self: *Engine, id: proto.ids.SessionId) void {
    std.debug.assert(self.sessions.get(id) == null);
    const entry = self.owners.fetchRemove(id.raw).?;
    std.debug.assert(entry.value.repaired and !entry.value.admitting);
    entry.value.release(self.deps.io);
}

pub fn init(deps: Deps) Engine {
    return .{ .deps = deps, .sessions = session.Registry.init(deps.gpa) };
}

/// Copy both validated prompts before the engine releases the old pair.
pub fn setPromptConfig(self: *Engine, base: ?[]const u8, child: ?[]const u8) !void {
    std.debug.assert(!self.closing);
    for ([_]?[]const u8{ base, child }) |prompt| {
        if (prompt) |text| {
            std.debug.assert(text.len <= proto.meta.limits.max_message_string_bytes);
            std.debug.assert(std.unicode.utf8ValidateSlice(text));
        }
    }
    const base_copy = if (base) |text| try self.deps.gpa.dupe(u8, text) else null;
    errdefer if (base_copy) |text| self.deps.gpa.free(text);
    const child_copy = if (child) |text| try self.deps.gpa.dupe(u8, text) else null;
    if (self.default_system_prompt) |old| self.deps.gpa.free(old);
    if (self.child_instructions) |old| self.deps.gpa.free(old);
    self.default_system_prompt = base_copy;
    self.child_instructions = child_copy;
}

/// Give the engine its tools. The set answers live, so a plugin can add or drop one at any time.
pub fn installTools(self: *Engine, set: toolset.ToolSet) void {
    self.deps.tools = set;
}

/// Give the engine its hooks. The set answers live, so a plugin can add or drop one at any time.
pub fn installHooks(self: *Engine, set: hookset.HookSet) void {
    self.deps.hooks = set;
}

/// Drop the tool and hook sets after all turn tasks leave the engine.
pub fn clearExtensions(self: *Engine) void {
    std.debug.assert(self.closing);
    self.deps.tools = .{};
    self.deps.hooks = .{};
}

/// Cancel every turn and wait for each task to leave the engine.
pub fn stopTurns(self: *Engine) void {
    self.closing = true;
    self.turn_tasks.cancel(self.deps.io);
}

/// Cancel every turn, then free the resident sessions. The process closes the store afterwards.
pub fn close(self: *Engine) void {
    if (!self.closing) self.stopTurns();
    self.sessions.deinit();
    var guards = self.owners.valueIterator();
    while (guards.next()) |guard| guard.release(self.deps.io);
    self.owners.deinit(self.deps.gpa);
    if (self.default_system_prompt) |prompt| self.deps.gpa.free(prompt);
    if (self.child_instructions) |prompt| self.deps.gpa.free(prompt);
    self.* = undefined;
}

/// Acquire a tree before any session mutation, then repair its abandoned runs.
pub fn own(self: *Engine, session_id: proto.ids.SessionId) !void {
    if (self.closing) return error.EngineClosing;
    var scratch: std.heap.ArenaAllocator = .init(self.deps.gpa);
    defer scratch.deinit();
    const arena = scratch.allocator();
    const id = (try @import("admission.zig").location(self, arena, session_id)).root.raw;
    // An owned tree needs no await; a queued successor retains its resident across this check.
    if (self.owners.get(id)) |guard| if (guard.repaired) return;
    try self.owner_mutex.lock(self.deps.io);
    defer self.owner_mutex.unlock(self.deps.io);
    if (self.closing) return error.EngineClosing;
    if (!try database.session.exists(self.deps.db, arena, session_id.raw)) return error.UnknownSession;
    if (!self.owners.contains(id)) {
        try self.owners.ensureUnusedCapacity(self.deps.gpa, 1);
        const guard = try ownership.acquire(self.deps.gpa, self.deps.io, self.deps.db, id);
        if (self.closing) {
            guard.release(self.deps.io);
            return error.EngineClosing;
        }
        self.owners.putAssumeCapacity(id, guard);
    }
    const guard = self.owners.getPtr(id).?;
    if (guard.repaired) return;
    const tree = try self.treeIds(arena, id);
    for (tree) |sid| try self.repair(arena, .bytes(sid));
    var wake: std.ArrayList(proto.ids.SessionId) = .empty;
    for (tree) |sid| {
        const protected = try self.deps.db.queries.protected_input_count.one(arena, .{ .session_id = sid });
        if (protected.value.depth > 0) try wake.append(arena, .bytes(sid));
    }
    guard.repaired = true;
    for (wake.items) |sid| reports.requestWake(self, sid);
}

/// Traverse only child links; a fork owns its own tree.
fn treeIds(self: *Engine, arena: std.mem.Allocator, root: [16]u8) ![]const [16]u8 {
    var ids: std.ArrayList([16]u8) = .empty;
    var seen: std.AutoHashMapUnmanaged([16]u8, void) = .empty;
    try ids.append(arena, root);
    try seen.put(arena, root, {});
    var index: usize = 0;
    while (index < ids.items.len) : (index += 1) {
        for (try database.session.childIds(self.deps.db, arena, ids.items[index])) |id| {
            if ((try seen.getOrPut(arena, id)).found_existing) return error.CorruptDatabase;
            try ids.append(arena, id);
        }
    }
    return ids.items;
}

/// The owner lock proves that an open marker has no live run in another engine.
fn repair(self: *Engine, arena: std.mem.Allocator, id: proto.ids.SessionId) !void {
    if (self.sessions.get(id)) |resident| std.debug.assert(resident.active_run == null);
    var done: ?reports.Terminal = null;
    {
        var tx = try self.deps.db.begin();
        defer tx.deinit();
        const row = (try database.session.snapshot(self.deps.db, arena, id.raw)) orelse return error.UnknownSession;
        if (try database.session.openRun(row)) |open| {
            const kind = std.meta.stringToEnum(proto.enums.RunKind, open.kind) orelse return error.CorruptDatabase;
            const started = open.started_at_ms;
            const ended = @max(self.nowMillis(), started);
            done = try reports.append(self, arena, .{
                .session_id = id,
                .seq = 0,
                .run_id = open.id,
                .kind = kind,
                .timing = .{ .started_at_ms = started, .ended_at_ms = ended },
                .outcome = .{ .failed = .{ .code = .interrupted, .message = "the previous engine stopped before this run ended" } },
            });
        }
        try tx.commit();
    }
    if (self.sessions.get(id)) |resident| {
        const pins = resident.pins;
        resident.deinit();
        resident.* = Session.init(self.deps.gpa, id);
        resident.pins = pins;
        try self.hydrate(resident);
        resident.hydrated = true;
    }
    if (done) |data| {
        self.sinks.emit(.{ .method = .@"run.done", .params = .{ .run_done_data = data.done } });
        if (data.notice) |notice| self.sinks.emit(.{ .method = .@"message.committed", .params = .{ .message_committed_data = notice } });
        if (data.report) |report| reports.publishReport(self, report, false);
        session_events.announceSummary(self, id);
    }
}

/// Frontends call this after their tools, hooks, and interaction sink exist.
pub fn resumeWorkspace(self: *Engine, workspace: []const u8) !void {
    if (self.closing) return error.EngineClosing;
    var scratch: std.heap.ArenaAllocator = .init(self.deps.gpa);
    defer scratch.deinit();
    const arena = scratch.allocator();
    var candidates: std.ArrayList(proto.ids.SessionId) = .empty;
    {
        var rows = try self.deps.db.queries.session_recovery_candidates.rows(.{ .root = workspace });
        defer rows.deinit();
        while (try rows.next(arena)) |row| try candidates.append(arena, .bytes(row.value.id));
    }
    var ready: std.ArrayList(proto.ids.SessionId) = .empty;
    for (candidates.items) |id| {
        self.own(id) catch |err| switch (err) {
            error.SessionOwned, error.UnknownSession => continue,
            else => return err,
        };
        try ready.append(arena, id);
    }
    for (ready.items) |id| {
        const resident = try self.activate(id);
        try run_task.resumeSession(self, resident);
    }
}

/// Return the resident for one session, and hydrate it from the store on the first use.
pub fn activate(self: *Engine, session_id: proto.ids.SessionId) !*Session {
    const resident = try self.sessions.getOrCreate(session_id);
    if (!resident.hydrated) {
        try self.hydrate(resident);
        resident.hydrated = true;
    }
    return resident;
}

/// Hydrate one session from SQLite, and cache its recent tail as the resident transcript.
pub fn hydrate(self: *Engine, resident: *Session) !void {
    std.debug.assert(resident.active_run == null and resident.queueDepth() == 0);
    std.debug.assert(resident.transcript.list.items.len == 0);
    std.debug.assert(resident.base_seq == 0 and resident.finalized_message_id == 0);
    var scratch = std.heap.ArenaAllocator.init(self.deps.gpa);
    defer scratch.deinit();
    const sid = resident.id.raw;
    const hw = (try database.event.highWater(self.deps.db, scratch.allocator(), sid)) orelse return; // no session row
    const limit = transcript.default_max_messages;
    var history = try database.message.tail(self.deps.db, sid, limit);
    defer history.deinit();
    // The scratch holds one message at a time, so the load peak follows the largest message, not the history.
    while (try history.next(scratch.allocator())) |m| {
        try resident.transcript.appendSized(m.message, m.bytes);
        _ = scratch.reset(.retain_capacity);
    }
    resident.sealHistory(hw.seq_high, hw.message_count > limit);
    // Pending inputs are historical. Fold them directly, so they do not advance the durable cursor.
    const pending = try database.input.list(self.deps.db, scratch.allocator(), sid);
    for (pending) |entry| {
        try resident.queueOnQueued(.{ .session_id = resident.id, .seq = entry.seq, .input = entry.input });
    }
}

/// Return wall-clock milliseconds since the Unix epoch. See util.nowMillis for the clock rules.
pub fn nowMillis(self: *const Engine) u64 {
    return util.nowMillis(self.deps.io);
}

/// Mint a fresh UUIDv7 for a session, workspace, or event.
pub fn newId(self: *const Engine) [16]u8 {
    return util.newId(self.deps.io);
}

/// Draw a retry jitter in [0, 1) from the UUIDv7 bytes that stay random.
pub fn jitter(self: *const Engine) f64 {
    return util.jitterFrom(self.newId());
}

test "activation restores durable pending input into the runtime queue" {
    var resources: @import("test_resources.zig") = undefined;
    try resources.init();
    defer resources.deinit();
    var db = try database.Database.openTest();
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const session_id = [_]u8{2} ** 16;
    try database.session.create(&db, .{
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
    const queued = try database.input.enqueue(&db, arena, session_id, [_]u8{3} ** 16, 2, .{ .content = &.{.{ .text = .{ .text = "recover" } }} }, 2);
    try db.conn.execNoArgs("COMMIT");

    var engine = resources.makeEngine(&db);
    defer engine.close();
    defer db.deinit();
    const rt = try engine.activate(.bytes(session_id));
    try std.testing.expectEqual(@as(usize, 1), rt.queueDepth());
    try std.testing.expectEqual(queued.input.input_id, rt.queueEntries()[0].input_id);
}

test {
    _ = @import("recovery_test.zig");
    _ = @import("admission_test.zig");
    _ = @import("reports_test.zig");
    _ = @import("model_config_test.zig");
    _ = @import("model_call.zig");
    _ = @import("compaction.zig");
    _ = @import("steering_test.zig");
}

/// Depth changes affect new children; active runs retain their slots.
pub fn setAgentLimits(self: *Engine, limit: u32, max_depth: u32) !void {
    std.debug.assert(limit > 0);
    std.debug.assert(max_depth > 0);
    if (self.closing) return error.EngineClosing;
    const old = self.max_concurrent_children;
    const old_depth = self.max_agent_depth;
    self.max_concurrent_children = limit;
    self.max_agent_depth = max_depth;
    errdefer {
        self.max_concurrent_children = old;
        self.max_agent_depth = old_depth;
    }
    if (limit > old) try self.turn_tasks.concurrent(self.deps.io, drainOwnedChildren, .{self});
}

fn drainOwnedChildren(self: *Engine) void {
    var scratch: std.heap.ArenaAllocator = .init(self.deps.gpa);
    defer scratch.deinit();
    var roots: std.ArrayList(proto.ids.SessionId) = .empty;
    var iterator = self.owners.iterator();
    while (iterator.next()) |entry| if (entry.value_ptr.repaired) {
        roots.append(scratch.allocator(), .bytes(entry.key_ptr.*)) catch return;
    };
    for (roots.items) |id| @import("admission.zig").drain(self, id) catch |err| {
        std.log.warn("cannot admit a queued child: {t}", .{err});
    };
}
