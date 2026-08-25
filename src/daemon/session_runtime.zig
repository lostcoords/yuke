//! Per-session live state. The reactor owns each SessionRuntime. The `Sessions` registry holds a stable pointer.
//! The session later attaches a run coroutine and a live draft.

const std = @import("std");
const zio = @import("zio");
const wire = @import("wire");
const queue = @import("../domain/queue.zig");
const run = @import("../engine/run.zig");
const transport = @import("../provider/transport.zig");

const ids = wire.ids;

/// Store stable state for one run. The State task group owns execution. The session owns this allocation.
pub const RunSlot = struct {
    gpa: std.mem.Allocator,
    handle: run.RunHandle,
    config: run.Config,
    phase: Phase = .pending_start,
    protocol: wire.enums.ProviderProtocol = .@"anthropic-messages", // The run sets this after provider resolution.
    cancel_requested: bool = false,
    // The RPC task sets this to interrupt the run. The run task waits on it and cancels its reader.
    cancel_event: zio.ResetEvent = .init,
    body: ?transport.ResponseBody = null,

    pub const Phase = enum { pending_start, running, terminalized, faulted };

    /// Allocate the slot and own copies of `model` and `system_prompt`. Bind the handle after Tx1.
    /// The caller allocates before the run transaction, so a late failure cannot orphan an open run.
    pub fn prepare(gpa: std.mem.Allocator, model: []const u8, system_prompt: []const u8) !*RunSlot {
        const model_copy = try gpa.dupe(u8, model);
        errdefer gpa.free(model_copy);
        const prompt_copy = try gpa.dupe(u8, system_prompt);
        errdefer gpa.free(prompt_copy);
        const self = try gpa.create(RunSlot);
        self.* = .{
            .gpa = gpa,
            .handle = undefined,
            .config = .{ .model = model_copy, .config_rev = 0, .system_prompt = prompt_copy },
        };
        return self;
    }

    /// Bind the committed run handle. Call once after Tx1 and before launch.
    pub fn bind(self: *RunSlot, handle: run.RunHandle) void {
        self.handle = handle;
        self.config.config_rev = handle.started.config_rev;
    }

    pub fn destroy(self: *RunSlot) void {
        std.debug.assert(self.body == null);
        self.gpa.free(self.config.model);
        self.gpa.free(self.config.system_prompt);
        self.gpa.destroy(self);
    }
};

/// Store one session's live state. One reactor executor mutates it between await points without a lock.
pub const SessionRuntime = struct {
    gpa: std.mem.Allocator,
    session_id: ids.SessionId,
    queue: queue.Queue,
    active: ?*RunSlot = null,
    faulted: bool = false,

    fn create(gpa: std.mem.Allocator, session_id: ids.SessionId) !*SessionRuntime {
        const self = try gpa.create(SessionRuntime);
        self.* = .{ .gpa = gpa, .session_id = session_id, .queue = queue.Queue.init(gpa) };
        return self;
    }

    fn destroy(self: *SessionRuntime) void {
        if (self.active) |slot| slot.destroy();
        self.queue.deinit();
        self.gpa.destroy(self);
    }

    /// A runtime is idle when it has no active run and no queued input. A later check also requires no subscriber.
    pub fn idle(self: *const SessionRuntime) bool {
        return self.active == null and self.queue.depth() == 0 and !self.faulted;
    }
};

/// Store live session runtimes in a registry. The daemon owns one registry and keys it by session id.
pub const Sessions = struct {
    gpa: std.mem.Allocator,
    map: std.AutoHashMapUnmanaged(ids.SessionId, *SessionRuntime) = .empty,

    pub fn init(gpa: std.mem.Allocator) Sessions {
        return .{ .gpa = gpa };
    }

    /// Destroy every runtime, then free the map.
    pub fn deinit(self: *Sessions) void {
        var it = self.map.valueIterator();
        while (it.next()) |rt| rt.*.destroy();
        self.map.deinit(self.gpa);
        self.* = undefined;
    }

    /// Return the live runtime for a session, or null.
    pub fn get(self: *Sessions, session_id: ids.SessionId) ?*SessionRuntime {
        return self.map.get(session_id);
    }

    /// Return the live runtime for a session. Create it on the first input.
    pub fn getOrCreate(self: *Sessions, session_id: ids.SessionId) !*SessionRuntime {
        const gop = try self.map.getOrPut(self.gpa, session_id);
        errdefer if (!gop.found_existing) std.debug.assert(self.map.remove(session_id));
        if (!gop.found_existing) gop.value_ptr.* = try SessionRuntime.create(self.gpa, session_id);
        return gop.value_ptr.*;
    }

    /// Drop an idle runtime so memory does not grow with dormant sessions.
    pub fn evictIfIdle(self: *Sessions, session_id: ids.SessionId) void {
        const rt = self.map.get(session_id) orelse return;
        if (!rt.idle()) return;
        rt.destroy();
        _ = self.map.remove(session_id);
    }
};

const testing = std.testing;

test "getOrCreate returns one stable runtime per session" {
    var sessions = Sessions.init(testing.allocator);
    defer sessions.deinit();

    const a: ids.SessionId = .bytes([_]u8{1} ** 16);
    const b: ids.SessionId = .bytes([_]u8{2} ** 16);
    const ra = try sessions.getOrCreate(a);
    const ra_again = try sessions.getOrCreate(a);
    const rb = try sessions.getOrCreate(b);

    try testing.expect(ra == ra_again); // One runtime per id has a stable pointer.
    try testing.expect(ra != rb);
    try testing.expect(sessions.get(a) == ra);
    try testing.expect(sessions.get(ids.SessionId.bytes([_]u8{9} ** 16)) == null);
}

test "evictIfIdle drops an idle runtime but keeps an active one" {
    var sessions = Sessions.init(testing.allocator);
    defer sessions.deinit();

    const sid: ids.SessionId = .bytes([_]u8{3} ** 16);
    const rt = try sessions.getOrCreate(sid);
    try testing.expect(rt.idle());

    // A live run pins the runtime.
    rt.active = try RunSlot.prepare(testing.allocator, "model", "");
    rt.active.?.bind(.{
        .run_id = 1,
        .input_id = 1,
        .assistant_message_id = 2,
        .started = .{ .session_id = sid, .seq = 1, .run_id = 1, .kind = .turn, .config_rev = 0, .started_at_ms = 1 },
    });
    try testing.expect(!rt.idle());
    sessions.evictIfIdle(sid);
    try testing.expect(sessions.get(sid) == rt); // The runtime remains present.

    // The run ends, so eviction can reclaim the runtime.
    rt.active.?.destroy();
    rt.active = null;
    sessions.evictIfIdle(sid);
    try testing.expect(sessions.get(sid) == null);
}
