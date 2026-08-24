//! Per-session live state. The reactor owns each SessionRuntime. Sessions holds a stable pointer.
//! A run coroutine and a streaming draft attach later.

const std = @import("std");
const wire = @import("wire");
const queue = @import("../domain/queue.zig");
const run = @import("../engine/run.zig");
const transport = @import("../provider/transport.zig");

const ids = wire.ids;

/// Stable state for one run. The State task group owns execution. The session owns this allocation.
pub const RunSlot = struct {
    gpa: std.mem.Allocator,
    handle: run.RunHandle,
    config: run.Config,
    phase: Phase = .pending_start,
    started_published: bool = false,
    cancel_requested: bool = false,
    body: ?transport.ResponseBody = null,

    pub const Phase = enum { pending_start, running, terminalized, faulted };

    /// The slot owns its own copies of `model` and `system_prompt`. The caller keeps its slices.
    pub fn create(gpa: std.mem.Allocator, handle: run.RunHandle, model: []const u8, system_prompt: []const u8) !*RunSlot {
        const model_copy = try gpa.dupe(u8, model);
        errdefer gpa.free(model_copy);
        const prompt_copy = try gpa.dupe(u8, system_prompt);
        errdefer gpa.free(prompt_copy);
        const self = try gpa.create(RunSlot);
        self.* = .{
            .gpa = gpa,
            .handle = handle,
            .config = .{ .model = model_copy, .config_rev = handle.started.config_rev, .system_prompt = prompt_copy },
        };
        return self;
    }

    pub fn destroy(self: *RunSlot) void {
        std.debug.assert(self.body == null);
        self.gpa.free(self.config.model);
        self.gpa.free(self.config.system_prompt);
        self.gpa.destroy(self);
    }
};

/// One session's live state. The reactor mutates it between await points, so it needs no lock.
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

    /// A runtime is idle when no run is active and no input waits. A later check also requires no subscriber.
    pub fn idle(self: *const SessionRuntime) bool {
        return self.active == null and self.queue.depth() == 0 and !self.faulted;
    }
};

/// The live-session registry. The daemon owns one. It keys runtimes by session id.
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

    try testing.expect(ra == ra_again); // one runtime per id, a stable pointer
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
    rt.active = try RunSlot.create(testing.allocator, .{
        .run_id = 1,
        .input_id = 1,
        .user_message_id = 1,
        .assistant_message_id = 2,
        .started = .{ .session_id = sid, .seq = 1, .run_id = 1, .kind = .turn, .config_rev = 0, .started_at_ms = 1 },
    }, "model", "");
    try testing.expect(!rt.idle());
    sessions.evictIfIdle(sid);
    try testing.expect(sessions.get(sid) == rt); // still present

    // The run ends; eviction now reclaims it.
    rt.active.?.destroy();
    rt.active = null;
    sessions.evictIfIdle(sid);
    try testing.expect(sessions.get(sid) == null);
}
