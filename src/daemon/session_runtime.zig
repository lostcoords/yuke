//! Per-session live state. The reactor owns each SessionRuntime. The `Sessions` registry holds a stable pointer.
//! The projection owns the live draft. The run task borrows it.

const std = @import("std");
const wire = @import("wire");
const Session = @import("domain").session.Session;
const run = @import("../engine/run.zig");
const transport = @import("../provider/transport.zig");

const ids = wire.ids;

/// Store stable state for one run. The State task group owns execution. The session owns this allocation.
pub const RunSlot = struct {
    gpa: std.mem.Allocator,
    handle: run.RunHandle,
    progress: run.RunProgress = .{},
    config: run.Config,
    phase: Phase = .pending_start,
    protocol: wire.enums.ProviderProtocol = .anthropic_messages, // The run sets this after provider resolution.
    cancel_requested: bool = false,
    /// Retry permits left for the whole run. `max_attempts` bounds one request.
    /// A null `max_rounds` would otherwise let the rounds multiply the retries.
    retry_budget: u8 = 8,
    /// The run waits for its next attempt. A resync reports this instead of the draft state.
    retry_state: ?wire.activity.ActivityStateRetrying = null,
    // The RPC task and the reader set this event. The run task waits on it.
    wake_event: std.Io.Event = .unset,
    body: ?transport.ResponseBody = null,

    pub const Phase = enum { pending_start, running, terminalized, faulted };

    /// Allocate the slot and own copies of `model` and `system_prompt`. Bind the handle after Tx1.
    /// The caller allocates before the run transaction, so a late failure cannot orphan an open run.
    pub fn prepare(gpa: std.mem.Allocator, model: []const u8, system_prompt: []const u8, max_rounds: ?u64) !*RunSlot {
        const model_copy = try gpa.dupe(u8, model);
        errdefer gpa.free(model_copy);
        const prompt_copy = try gpa.dupe(u8, system_prompt);
        errdefer gpa.free(prompt_copy);
        const self = try gpa.create(RunSlot);
        self.* = .{
            .gpa = gpa,
            .handle = undefined,
            .config = .{ .model = model_copy, .system_prompt = prompt_copy, .max_rounds = max_rounds },
        };
        return self;
    }

    /// The session that owns this run. Valid after `bind`.
    pub fn sessionId(self: *const RunSlot) wire.ids.SessionId {
        return self.handle.started.session_id;
    }

    /// The durable run id. Valid after `bind`.
    pub fn runId(self: *const RunSlot) wire.ids.RunId {
        return self.handle.started.run_id;
    }

    /// Bind the committed run handle and open the first round. Call once after Tx1 and before launch.
    pub fn bind(self: *RunSlot, handle: run.RunHandle, first_round: run.RoundState) void {
        std.debug.assert(self.phase == .pending_start);
        std.debug.assert(self.progress.current == null); // bind runs once
        std.debug.assert(first_round.number == 1);
        self.handle = handle;
        self.progress = .{ .rounds_started = 1, .current = first_round };
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
    // The projection owns the input queue, the live draft, the committed window, and the cursors.
    session: Session,
    active: ?*RunSlot = null,
    faulted: bool = false,
    hydrated: bool = false, // The daemon seeds the projection from SQLite once on activation.

    fn create(gpa: std.mem.Allocator, session_id: ids.SessionId) !*SessionRuntime {
        const self = try gpa.create(SessionRuntime);
        self.* = .{ .gpa = gpa, .session = Session.init(gpa, session_id) };
        return self;
    }

    fn destroy(self: *SessionRuntime) void {
        if (self.active) |slot| slot.destroy();
        self.session.deinit();
        self.gpa.destroy(self);
    }

    /// A runtime is idle when it has no active run, no queued input, and no fault.
    pub fn idle(self: *const SessionRuntime) bool {
        return self.active == null and self.session.queue.depth() == 0 and !self.faulted;
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
    rt.active = try RunSlot.prepare(testing.allocator, "model", "", null);
    rt.active.?.bind(.{
        .input_id = 1,
        .started = .{ .session_id = sid, .seq = 1, .run_id = 1, .kind = .turn, .config_rev = 0, .started_at_ms = 1 },
    }, .{ .number = 1, .message_id = 2 });
    try testing.expect(!rt.idle());
    sessions.evictIfIdle(sid);
    try testing.expect(sessions.get(sid) == rt); // The runtime remains present.

    // The run ends, so eviction can reclaim the runtime.
    rt.active.?.destroy();
    rt.active = null;
    sessions.evictIfIdle(sid);
    try testing.expect(sessions.get(sid) == null);
}
