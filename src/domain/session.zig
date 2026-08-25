//! One session projection shared by the daemon and the client. Both fold the same events into it.
//! The daemon builds an event, applies it with `applyAuthoritative`, then publishes the same value.
//! The client folds broadcasts with `applyBroadcast`. Both paths share one internal per-event dispatch.
//!
//! The projection owns the live draft, the queue, the durable cursors, and a bounded committed-message
//! window with its configs. The window is a daemon cache for resync. SQLite stays authoritative.

const std = @import("std");
const wire = @import("wire");
const draftmod = @import("draft.zig");
const queuemod = @import("queue.zig");
const committedmod = @import("committed.zig");

const ids = wire.ids;
const message = wire.message;
const Draft = draftmod.Draft;
const Queue = queuemod.Queue;
const Window = committedmod.Window;
const ConfigSet = committedmod.ConfigSet;
const BroadcastData = wire.rpc.BroadcastData;

pub const Error = error{ OutOfMemory, Protocol };

/// The outcome of one fold. The client resyncs on `gap`. The daemon never produces `gap`.
pub const Applied = enum { changed, ignored, gap };

/// A session projection. The daemon owns one per live runtime; the client owns one per open session.
pub const Session = struct {
    gpa: std.mem.Allocator,
    id: ids.SessionId,
    active: ?Draft = null,
    queue: Queue,
    committed: Window,
    configs: ConfigSet,
    base_seq: ids.Seq = 0,
    finalized_message_id: ids.MessageId = 0,

    pub fn init(gpa: std.mem.Allocator, id: ids.SessionId) Session {
        return .{ .gpa = gpa, .id = id, .queue = Queue.init(gpa), .committed = Window.init(gpa), .configs = ConfigSet.init(gpa) };
    }

    pub fn deinit(self: *Session) void {
        if (self.active) |*d| d.deinit();
        self.queue.deinit();
        self.committed.deinit();
        self.configs.deinit();
        self.* = undefined;
    }

    /// The daemon hydrates the cache from SQLite on runtime activation. It seeds the resync window.
    pub const Snapshot = struct {
        base_seq: ids.Seq,
        finalized_message_id: ids.MessageId,
        messages: []const message.Message,
        configs: []const wire.run.RunConfig,
        has_more: bool,
    };

    /// Seed the projection from a store snapshot. Call once before the first fold on a fresh Session.
    pub fn installSnapshot(self: *Session, snap: Snapshot) Error!void {
        std.debug.assert(self.base_seq == 0 and self.finalized_message_id == 0); // a fresh projection
        std.debug.assert(self.active == null and self.queue.depth() == 0);
        std.debug.assert(self.committed.list.items.len == 0 and self.configs.map.count() == 0);
        for (snap.messages) |m| try self.committed.append(m);
        for (snap.configs) |c| try self.configs.record(c);
        self.committed.has_more = self.committed.has_more or snap.has_more;
        self.base_seq = snap.base_seq;
        self.finalized_message_id = snap.finalized_message_id;
    }

    /// Client fold. Validate the durable seq and the part offsets. Return `gap` when the client
    /// missed an event. Malformed peer input returns `error.Protocol`.
    pub fn applyBroadcast(self: *Session, bc: BroadcastData) Error!Applied {
        return self.dispatch(bc, .checked);
    }

    /// Daemon fold. Trust the daemon-built event. Assert the projection invariants.
    pub fn applyAuthoritative(self: *Session, bc: BroadcastData) Error!void {
        const result = try self.dispatch(bc, .trusted);
        std.debug.assert(result != .gap); // the daemon never produces a gap against its own state
    }

    const Mode = enum { checked, trusted };
    const Gate = enum { apply, ignore, gap };

    fn dispatch(self: *Session, bc: BroadcastData, mode: Mode) Error!Applied {
        // An event for another session never touches this projection.
        if (payloadSession(bc)) |s| if (!std.meta.eql(s, self.id)) {
            std.debug.assert(mode == .checked); // the daemon routes only its own session
            return .ignored;
        };
        return switch (bc) {
            .message_started_data => |d| self.onStarted(d, mode),
            .message_part_added_data => |d| self.onPartAdded(d, mode),
            .message_part_delta_data => |d| self.onDelta(d, mode, .text),
            .tool_output_delta_data => |d| self.onDelta(d, mode, .tool),
            .message_part_finalized_data => |d| self.onFinalized(d, mode),
            .tool_state_changed_data => |d| self.onToolState(d, mode),
            .message_discarded_data => |d| self.onDiscarded(d),
            .message_committed_data => |d| self.onCommitted(d, mode),
            .input_queued_data => |d| self.onQueued(d, mode),
            .input_canceled_data => |d| self.onCanceled(d, mode),
            .transcript_truncated_data => |d| self.onTruncated(d, mode),
            .run_started_data => |d| self.onCursor(d.seq, mode),
            .run_done_data => |d| self.onCursor(d.seq, mode),
            .config_changed_data => |d| self.onConfig(d, mode),
            // A shed marker tells the client it missed deltas. It must resync.
            .session_deltas_shed_data => if (mode == .checked) .gap else .ignored,
            // Index, workspace, auth, and notice events are not session-projection state.
            else => .ignored,
        };
    }

    // The durable-sequence gate. A trusted event is always the next seq.
    fn gate(self: *Session, seq: ids.Seq, mode: Mode) Gate {
        if (mode == .trusted) {
            std.debug.assert(seq == self.base_seq + 1);
            return .apply;
        }
        if (seq <= self.base_seq) return .ignore;
        if (seq > self.base_seq + 1) return .gap;
        return .apply;
    }

    // A miss maps to a gap for the client and asserts for the daemon.
    fn miss(mode: Mode) Applied {
        std.debug.assert(mode == .checked);
        return .gap;
    }

    // Resolve a live event to the active draft, a stale ignore, or a gap. A finalized or older message
    // id is stale; a newer message id means the client missed a start.
    const Target = union(enum) { active: *Draft, stale, gap };
    fn target(self: *Session, message_id: ids.MessageId, mode: Mode) Target {
        if (message_id <= self.finalized_message_id) return .stale;
        if (self.active) |*dr| {
            if (dr.message_id == message_id) return .{ .active = dr };
            if (message_id < dr.message_id) return .stale;
            std.debug.assert(mode == .checked);
            return .gap;
        }
        std.debug.assert(mode == .checked);
        return .gap;
    }

    fn onStarted(self: *Session, d: message.MessageStartedData, mode: Mode) Error!Applied {
        if (d.message_id <= self.finalized_message_id) return .ignored; // a finalized message never reopens
        if (self.active) |*dr| {
            if (dr.message_id == d.message_id) return .ignored; // a duplicate start
            std.debug.assert(mode == .checked);
            return .gap; // the previous message never committed
        }
        self.active = Draft.init(self.gpa, d) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => unreachable, // init only allocates the agent copy
        };
        return .changed;
    }

    fn onPartAdded(self: *Session, d: message.MessagePartAddedData, mode: Mode) Error!Applied {
        const dr = switch (self.target(d.message_id, mode)) {
            .active => |p| p,
            .stale => return .ignored,
            .gap => return .gap,
        };
        dr.addPart(d) catch |err| return draftMiss(err, mode);
        return .changed;
    }

    const DeltaKind = enum { text, tool };

    fn onDelta(self: *Session, d: message.PartDelta, mode: Mode, kind: DeltaKind) Error!Applied {
        const dr = switch (self.target(d.message_id, mode)) {
            .active => |p| p,
            .stale => return .ignored,
            .gap => return .gap,
        };
        const outcome = switch (kind) {
            .text => dr.applyPartDelta(d),
            .tool => dr.applyToolOutputDelta(d),
        } catch |err| return draftMiss(err, mode);
        return switch (outcome) {
            .applied => .changed,
            .stale => .ignored,
            .gap => miss(mode),
        };
    }

    fn onFinalized(self: *Session, d: message.MessagePartFinalizedData, mode: Mode) Error!Applied {
        const dr = switch (self.target(d.message_id, mode)) {
            .active => |p| p,
            .stale => return .ignored,
            .gap => return .gap,
        };
        switch (d.final) {
            .reasoning => |r| dr.finalizeReasoning(d.part_id, r.signature) catch |err| return draftMiss(err, mode),
            .redacted_reasoning => |r| dr.finalizeRedacted(d.part_id, r.data) catch |err| return draftMiss(err, mode),
        }
        return .changed;
    }

    fn onToolState(self: *Session, d: wire.tool.ToolStateChangedData, mode: Mode) Error!Applied {
        const dr = switch (self.target(d.message_id, mode)) {
            .active => |p| p,
            .stale => return .ignored,
            .gap => return .gap,
        };
        const outcome = dr.applyToolState(d) catch |err| return draftMiss(err, mode);
        return switch (outcome) {
            .applied => .changed,
            .ignored_terminal => .ignored,
        };
    }

    fn onDiscarded(self: *Session, d: message.MessageDiscardedData) Applied {
        if (self.active) |*dr| {
            if (dr.message_id != d.message_id) return .ignored;
            dr.deinit();
            self.active = null;
            self.raiseFinalized(d.message_id);
            return .changed;
        }
        return .ignored;
    }

    fn onCommitted(self: *Session, d: message.MessageCommittedData, mode: Mode) Error!Applied {
        switch (self.gate(d.seq, mode)) {
            .ignore => return .ignored,
            .gap => return .gap,
            .apply => {},
        }
        // The daemon commits ids in increasing order. A stale id keeps the window oldest-first for trim.
        if (d.message.id() <= self.finalized_message_id) {
            std.debug.assert(mode == .checked);
            return error.Protocol;
        }
        try self.committed.append(d.message); // cache before the draft or queue mutates, so an OOM is clean
        switch (d.message) {
            .user => |u| _ = self.queue.retire(u.input_id),
            .assistant => |a| if (self.active) |*dr| {
                if (dr.message_id == a.id) {
                    dr.deinit();
                    self.active = null;
                }
            },
            .compaction => {},
        }
        self.raiseFinalized(d.message.id());
        self.base_seq = d.seq;
        return .changed;
    }

    fn onConfig(self: *Session, d: wire.misc.ConfigChangedData, mode: Mode) Error!Applied {
        switch (self.gate(d.seq, mode)) {
            .ignore => return .ignored,
            .gap => return .gap,
            .apply => {},
        }
        // A config revision is immutable. A conflicting value for a known revision is malformed.
        if (self.configs.get(d.config.config_rev)) |existing| {
            if (!configEql(existing, d.config)) {
                std.debug.assert(mode == .checked);
                return error.Protocol;
            }
        } else {
            try self.configs.record(d.config);
        }
        self.base_seq = d.seq;
        return .changed;
    }

    fn onQueued(self: *Session, d: wire.input.InputQueuedData, mode: Mode) Error!Applied {
        switch (self.gate(d.seq, mode)) {
            .ignore => return .ignored,
            .gap => return .gap,
            .apply => {},
        }
        const applied = try self.queue.onQueued(d);
        self.base_seq = d.seq;
        return if (applied == .changed) .changed else .ignored;
    }

    fn onCanceled(self: *Session, d: wire.input.InputCanceledData, mode: Mode) Applied {
        switch (self.gate(d.seq, mode)) {
            .ignore => return .ignored,
            .gap => return .gap,
            .apply => {},
        }
        const applied = self.queue.onCanceled(d);
        self.base_seq = d.seq;
        return if (applied == .changed) .changed else .ignored;
    }

    fn onTruncated(self: *Session, d: wire.misc.TranscriptTruncatedData, mode: Mode) Applied {
        switch (self.gate(d.seq, mode)) {
            .ignore => return .ignored,
            .gap => return .gap,
            .apply => {},
        }
        self.raiseFinalized(d.first_removed_id); // truncated ids reject a late draft
        self.committed.trimFrom(d.first_removed_id); // drop the truncated messages from the cache
        self.base_seq = d.seq;
        return .changed;
    }

    fn onCursor(self: *Session, seq: ids.Seq, mode: Mode) Applied {
        return switch (self.gate(seq, mode)) {
            .ignore => .ignored,
            .gap => .gap,
            .apply => blk: {
                self.base_seq = seq;
                break :blk .changed;
            },
        };
    }

    fn raiseFinalized(self: *Session, message_id: ids.MessageId) void {
        if (message_id > self.finalized_message_id) self.finalized_message_id = message_id;
    }

    // A draft error means the client missed a `part_added`, or the peer sent a bad part kind.
    fn draftMiss(err: draftmod.Error, mode: Mode) Error!Applied {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.UnknownPart, error.PartOutOfOrder => miss(mode),
            error.WrongPartKind => blk: {
                std.debug.assert(mode == .checked); // the daemon never sends a wrong part kind
                break :blk error.Protocol;
            },
        };
    }

    /// Compare two projections for semantic equality. The conformance test uses this after every event.
    /// The draft and queue compare by their serialized wire form, so every wire field is significant.
    pub fn eql(a: *const Session, b: *const Session, scratch: std.mem.Allocator) Error!bool {
        if (!std.meta.eql(a.id, b.id)) return false;
        if (a.base_seq != b.base_seq or a.finalized_message_id != b.finalized_message_id) return false;
        if ((a.active == null) != (b.active == null)) return false;
        if (a.active) |*da| {
            if (!try draftEql(scratch, da, &b.active.?)) return false;
        }
        if (!try queueEql(scratch, &a.queue, &b.queue)) return false;
        if (!try windowEql(scratch, &a.committed, &b.committed)) return false;
        return configsEql(scratch, &a.configs, &b.configs);
    }
};

fn payloadSession(bc: BroadcastData) ?ids.SessionId {
    return switch (bc) {
        .message_started_data => |d| d.session_id,
        .message_part_added_data => |d| d.session_id,
        .message_part_delta_data => |d| d.session_id,
        .tool_output_delta_data => |d| d.session_id,
        .message_part_finalized_data => |d| d.session_id,
        .tool_state_changed_data => |d| d.session_id,
        .message_discarded_data => |d| d.session_id,
        .message_committed_data => |d| d.session_id,
        .input_queued_data => |d| d.session_id,
        .input_canceled_data => |d| d.session_id,
        .transcript_truncated_data => |d| d.session_id,
        .run_started_data => |d| d.session_id,
        .run_done_data => |d| d.session_id,
        .config_changed_data => |d| d.session_id,
        .session_deltas_shed_data => |d| d.session_id,
        else => null,
    };
}

fn draftEql(scratch: std.mem.Allocator, a: *const Draft, b: *const Draft) Error!bool {
    const ja = try draftJson(scratch, a);
    const jb = try draftJson(scratch, b);
    return std.mem.eql(u8, ja, jb);
}

fn draftJson(scratch: std.mem.Allocator, d: *const Draft) Error![]u8 {
    const ad = d.toActiveDraft(scratch) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Protocol,
    };
    return jsonOf(scratch, ad);
}

fn windowEql(scratch: std.mem.Allocator, a: *const Window, b: *const Window) Error!bool {
    if (a.list.items.len != b.list.items.len or a.has_more != b.has_more) return false;
    for (a.list.items, b.list.items) |*ia, *ib| {
        const ja = try jsonOf(scratch, ia.message);
        const jb = try jsonOf(scratch, ib.message);
        if (!std.mem.eql(u8, ja, jb)) return false;
    }
    return true;
}

// Compare two configs field by field. A config revision is immutable, so a value conflict is malformed.
fn configEql(a: wire.run.RunConfig, b: wire.run.RunConfig) bool {
    return a.config_rev == b.config_rev and std.mem.eql(u8, a.model, b.model) and std.mem.eql(u8, a.reasoning, b.reasoning);
}

fn configsEql(scratch: std.mem.Allocator, a: *const ConfigSet, b: *const ConfigSet) Error!bool {
    if (a.map.count() != b.map.count()) return false;
    var it = a.map.iterator();
    while (it.next()) |entry| {
        const other = b.map.get(entry.key_ptr.*) orelse return false;
        const ja = try jsonOf(scratch, entry.value_ptr.*);
        const jb = try jsonOf(scratch, other);
        if (!std.mem.eql(u8, ja, jb)) return false;
    }
    return true;
}

fn queueEql(scratch: std.mem.Allocator, a: *const Queue, b: *const Queue) Error!bool {
    if (a.depth() != b.depth()) return false;
    for (a.entries(), b.entries()) |*ia, *ib| {
        if (ia.input_id != ib.input_id or ia.queued_at_ms != ib.queued_at_ms) return false;
        const ja = try jsonOf(scratch, ia.content);
        const jb = try jsonOf(scratch, ib.content);
        if (!std.mem.eql(u8, ja, jb)) return false;
    }
    return true;
}

fn jsonOf(scratch: std.mem.Allocator, value: anytype) Error![]u8 {
    return std.json.Stringify.valueAlloc(scratch, value, .{ .emit_null_optional_fields = false }) catch error.OutOfMemory;
}

const testing = std.testing;
const sid: ids.SessionId = .bytes(@splat(1));

fn started(message_id: ids.MessageId) BroadcastData {
    return .{ .message_started_data = .{ .session_id = sid, .message_id = message_id, .run_id = 1, .config_rev = 0, .agent = "claude", .created_at_ms = 1 } };
}
fn textPartAdded(message_id: ids.MessageId, part_id: ids.PartId) BroadcastData {
    return .{ .message_part_added_data = .{ .session_id = sid, .message_id = message_id, .part = .{ .text = .{ .id = part_id, .text = "" } } } };
}
fn textDelta(message_id: ids.MessageId, part_id: ids.PartId, offset: u64, delta: []const u8) BroadcastData {
    return .{ .message_part_delta_data = .{ .session_id = sid, .message_id = message_id, .part_id = part_id, .delta = delta, .offset = offset } };
}
fn userCommitted(seq: ids.Seq, message_id: ids.MessageId, input_id: ids.InputId) BroadcastData {
    return .{ .message_committed_data = .{ .session_id = sid, .seq = seq, .message = .{ .user = .{ .id = message_id, .content = &.{}, .input_id = input_id, .time = .{ .created_at_ms = 1 } } } } };
}
fn queuedInput(seq: ids.Seq, input_id: ids.InputId) BroadcastData {
    return .{ .input_queued_data = .{ .session_id = sid, .seq = seq, .input = .{ .input_id = input_id, .content = &.{}, .queued_at_ms = 1 } } };
}
fn configChanged(seq: ids.Seq, rev: ids.ConfigRev) BroadcastData {
    return .{ .config_changed_data = .{ .session_id = sid, .seq = seq, .config = .{ .config_rev = rev, .model = "opus", .reasoning = "high" } } };
}

test "the session hydrates a snapshot then caches a config change and a commit" {
    var s = Session.init(testing.allocator, sid);
    defer s.deinit();
    const msgs = [_]message.Message{.{ .user = .{ .id = 1, .content = &.{}, .input_id = 1, .time = .{ .created_at_ms = 1 } } }};
    const cfgs = [_]wire.run.RunConfig{.{ .config_rev = 0, .model = "opus", .reasoning = "high" }};
    try s.installSnapshot(.{ .base_seq = 5, .finalized_message_id = 1, .messages = &msgs, .configs = &cfgs, .has_more = true });
    try testing.expectEqual(@as(?ids.MessageId, 1), s.committed.newestId());
    try testing.expectEqual(@as(ids.Seq, 5), s.base_seq);
    try testing.expect(s.committed.has_more and s.configs.map.get(0) != null);

    // A config change folds at seq 6. A user commit folds at seq 7 and enters the window.
    try testing.expectEqual(Applied.changed, try s.applyBroadcast(configChanged(6, 1)));
    try testing.expect(s.configs.map.get(1) != null);
    try testing.expectEqual(Applied.changed, try s.applyBroadcast(userCommitted(7, 2, 50)));
    try testing.expectEqual(@as(?ids.MessageId, 2), s.committed.newestId());
    try testing.expectEqual(@as(ids.Seq, 7), s.base_seq);
}

test "a live turn folds text and commits" {
    var s = Session.init(testing.allocator, sid);
    defer s.deinit();

    try testing.expectEqual(Applied.changed, try s.applyBroadcast(started(1)));
    try testing.expectEqual(Applied.changed, try s.applyBroadcast(textPartAdded(1, 0)));
    try testing.expectEqual(Applied.changed, try s.applyBroadcast(textDelta(1, 0, 0, "hel")));
    try testing.expectEqual(Applied.changed, try s.applyBroadcast(textDelta(1, 0, 3, "lo")));
    try testing.expect(s.active != null);
    try testing.expectEqualStrings("hello", s.active.?.parts.items[0].text.text.items);

    // The committed assistant message clears the draft and raises the finalized id.
    const commit: BroadcastData = .{ .message_committed_data = .{ .session_id = sid, .seq = 1, .message = .{ .assistant = .{
        .id = 1,
        .run_id = 1,
        .config_rev = 0,
        .agent = "claude",
        .content = &.{},
        .time = .{ .created_at_ms = 1 },
    } } } };
    try testing.expectEqual(Applied.changed, try s.applyBroadcast(commit));
    try testing.expect(s.active == null);
    try testing.expectEqual(@as(ids.MessageId, 1), s.finalized_message_id);
    try testing.expectEqual(@as(ids.Seq, 1), s.base_seq);
}

test "a delta hole and a missing draft return a gap" {
    var s = Session.init(testing.allocator, sid);
    defer s.deinit();
    // A part event before message.started is a gap.
    try testing.expectEqual(Applied.gap, try s.applyBroadcast(textPartAdded(1, 0)));

    _ = try s.applyBroadcast(started(1));
    _ = try s.applyBroadcast(textPartAdded(1, 0));
    // An offset past the buffer end is a gap; a stale offset is ignored.
    try testing.expectEqual(Applied.gap, try s.applyBroadcast(textDelta(1, 0, 5, "x")));
    _ = try s.applyBroadcast(textDelta(1, 0, 0, "ab"));
    try testing.expectEqual(Applied.ignored, try s.applyBroadcast(textDelta(1, 0, 0, "ab")));
}

test "durable seq gates ignore duplicates and gap on a hole" {
    var s = Session.init(testing.allocator, sid);
    defer s.deinit();
    try testing.expectEqual(Applied.changed, try s.applyBroadcast(queuedInput(1, 10)));
    try testing.expectEqual(@as(ids.Seq, 1), s.base_seq);
    // seq <= base_seq is a duplicate.
    try testing.expectEqual(Applied.ignored, try s.applyBroadcast(queuedInput(1, 11)));
    // seq > base_seq + 1 is a gap.
    try testing.expectEqual(Applied.gap, try s.applyBroadcast(queuedInput(3, 12)));
    // The user commit at the next seq retires the queued input.
    try testing.expectEqual(Applied.changed, try s.applyBroadcast(userCommitted(2, 20, 10)));
    try testing.expectEqual(@as(usize, 0), s.queue.depth());
}

test "applyAuthoritative folds a turn and matches a client fold" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var daemon = Session.init(testing.allocator, sid);
    defer daemon.deinit();
    var client = Session.init(testing.allocator, sid);
    defer client.deinit();

    const events = [_]BroadcastData{ started(1), textPartAdded(1, 0), textDelta(1, 0, 0, "hi"), queuedInput(1, 7) };
    for (events) |bc| {
        try daemon.applyAuthoritative(bc);
        _ = try client.applyBroadcast(bc);
    }
    try testing.expect(try daemon.eql(&client, arena.allocator()));

    // A divergent fold is detected.
    _ = try client.applyBroadcast(textDelta(1, 0, 2, "!"));
    try testing.expect(!try daemon.eql(&client, arena.allocator()));
}

test "wrong-session, finalized, and shed events are handled" {
    var s = Session.init(testing.allocator, sid);
    defer s.deinit();
    // An event for another session never touches this projection.
    const other: ids.SessionId = .bytes(@splat(2));
    const wrong: BroadcastData = .{ .message_started_data = .{ .session_id = other, .message_id = 1, .run_id = 1, .config_rev = 0, .agent = "x", .created_at_ms = 1 } };
    try testing.expectEqual(Applied.ignored, try s.applyBroadcast(wrong));
    try testing.expect(s.active == null);

    // Commit message 1, then a late part for it is stale, not a gap.
    _ = try s.applyBroadcast(started(1));
    const commit: BroadcastData = .{ .message_committed_data = .{ .session_id = sid, .seq = 1, .message = .{ .assistant = .{ .id = 1, .run_id = 1, .config_rev = 0, .agent = "claude", .content = &.{}, .time = .{ .created_at_ms = 1 } } } } };
    _ = try s.applyBroadcast(commit);
    try testing.expectEqual(Applied.ignored, try s.applyBroadcast(textPartAdded(1, 0)));
    try testing.expectEqual(Applied.ignored, try s.applyBroadcast(started(1)));

    // A shed marker forces a resync.
    const shed: BroadcastData = .{ .session_deltas_shed_data = .{ .session_id = sid, .count = 3 } };
    try testing.expectEqual(Applied.gap, try s.applyBroadcast(shed));
}

test "a committed message enters the window and config.changed records its config" {
    var s = Session.init(testing.allocator, sid);
    defer s.deinit();
    try testing.expectEqual(Applied.changed, try s.applyBroadcast(configChanged(1, 7)));
    try testing.expectEqual(Applied.changed, try s.applyBroadcast(userCommitted(2, 5, 10)));
    try testing.expectEqual(@as(?ids.MessageId, 5), s.committed.newestId());
    try testing.expect(s.configs.get(7) != null);
}

test "a non-increasing committed id is rejected in checked mode" {
    var s = Session.init(testing.allocator, sid);
    defer s.deinit();
    _ = try s.applyBroadcast(userCommitted(1, 5, 10));
    // A later commit at a fresh seq with a smaller id is malformed.
    try testing.expectError(error.Protocol, s.applyBroadcast(userCommitted(2, 3, 11)));
}

test "a conflicting config revision is rejected in checked mode" {
    var s = Session.init(testing.allocator, sid);
    defer s.deinit();
    _ = try s.applyBroadcast(configChanged(1, 7)); // model opus
    try testing.expectEqual(Applied.changed, try s.applyBroadcast(configChanged(2, 7))); // same value is fine
    const conflict: BroadcastData = .{ .config_changed_data = .{ .session_id = sid, .seq = 3, .config = .{ .config_rev = 7, .model = "sonnet", .reasoning = "high" } } };
    try testing.expectError(error.Protocol, s.applyBroadcast(conflict));
}

test "installSnapshot seeds the window, configs, and cursors" {
    var s = Session.init(testing.allocator, sid);
    defer s.deinit();
    const msgs = [_]message.Message{
        .{ .user = .{ .id = 1, .content = &.{}, .input_id = 1, .time = .{ .created_at_ms = 1 } } },
        .{ .user = .{ .id = 2, .content = &.{}, .input_id = 2, .time = .{ .created_at_ms = 1 } } },
    };
    const cfgs = [_]wire.run.RunConfig{.{ .config_rev = 0, .model = "opus", .reasoning = "high" }};
    try s.installSnapshot(.{ .base_seq = 5, .finalized_message_id = 2, .messages = &msgs, .configs = &cfgs, .has_more = true });
    try testing.expectEqual(@as(ids.Seq, 5), s.base_seq);
    try testing.expectEqual(@as(?ids.MessageId, 2), s.committed.newestId());
    try testing.expect(s.committed.has_more);
    try testing.expect(s.configs.get(0) != null);
    // A live commit at the next seq folds onto the hydrated window.
    try testing.expectEqual(Applied.changed, try s.applyBroadcast(userCommitted(6, 3, 20)));
    try testing.expectEqual(@as(?ids.MessageId, 3), s.committed.newestId());
}
