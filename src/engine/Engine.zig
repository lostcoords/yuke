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
    env: *const std.process.Environ.Map,
    /// The tools this process can run. The engine borrows the set from the extension owner.
    tools: toolset.ToolSet = .{},
    /// The hooks this process can ask. The engine borrows the set from the same owner.
    hooks: hookset.HookSet = .{},
    retry_policy: retry.Policy = .{},
    /// Retry permits for one whole run.
    retry_budget: u8 = 8,
};

deps: Deps,
/// Live per-session state, keyed by session id. A pane pins the session it shows.
sessions: session.Registry,
/// Every turn task. `close` cancels this group before the process closes the transport.
turn_tasks: std.Io.Group = .init,
/// Every subscriber that reads engine events. A frontend installs itself at startup.
sinks: Sinks = .{},
/// The default prompt for a session that does not provide one.
default_system_prompt: ?[]const u8 = null,
/// The in-memory session index revision. A restart clears it.
session_revision: u64 = 0,
/// Set while the engine closes, so a finished turn starts no successor.
closing: bool = false,

pub fn init(deps: Deps) Engine {
    return .{ .deps = deps, .sessions = session.Registry.init(deps.gpa) };
}

/// Set the default system prompt and copy it into engine-owned storage.
pub fn setDefaultSystemPrompt(self: *Engine, prompt: ?[]const u8) !void {
    std.debug.assert(!self.closing);
    if (prompt) |text| std.debug.assert(text.len <= proto.meta.limits.max_message_string_bytes);
    const copy = if (prompt) |text| try self.deps.gpa.dupe(u8, text) else null;
    if (self.default_system_prompt) |old| self.deps.gpa.free(old);
    self.default_system_prompt = copy;
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
    if (self.default_system_prompt) |prompt| self.deps.gpa.free(prompt);
    self.* = undefined;
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

/// These test dependencies use an empty environment. The map has no allocation to free.
var test_env: std.process.Environ.Map = .init(std.testing.allocator);
var test_transport = ai.transport.CannedTransport{ .bytes = ai.transport.canned_reply };

test "activation restores durable pending input into the runtime queue" {
    var runtime = try zio.Runtime.init(std.testing.allocator, .{ .executors = .exact(1) });
    defer runtime.deinit();
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
    const queued = try database.input.enqueue(&db, arena, session_id, [_]u8{3} ** 16, 2, &.{.{ .text = .{ .text = "recover" } }}, 2);
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
    const rt = try engine.activate(.bytes(session_id));
    try std.testing.expectEqual(@as(usize, 1), rt.queueDepth());
    try std.testing.expectEqual(queued.input.input_id, rt.queueEntries()[0].input_id);
}
