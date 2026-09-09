//! One resident session owns its draft, queue, transcript, durable cursors, and active run.

const std = @import("std");
const proto = @import("proto");
const draftmod = @import("draft.zig");
const transcriptmod = @import("transcript.zig");
const transport = @import("ai").transport;

const ids = proto.ids;
const message = proto.message;
const Draft = draftmod.Draft;
const Transcript = transcriptmod.Transcript;
const BroadcastData = proto.rpc.BroadcastData;
const content = proto.content;
const input = proto.input;
const misc = proto.misc;

pub const Config = struct {
    model: []const u8,
    reasoning: []const u8 = "",
    system_prompt: []const u8,
    max_rounds: ?u64 = null,
};

pub const RunHandle = struct {
    input_id: ids.InputId,
    started: proto.run.RunStartedData,
};

pub const RoundState = struct {
    number: u64,
    message_id: ids.MessageId,
    created_at_ms: u64 = 0,
};

pub const RunProgress = struct {
    rounds_started: u64 = 0,
    rounds_committed: u64 = 0,
    current: ?RoundState = null,
};

/// The model trim cursor is separate from the resident transcript cache.
pub const ContextFloor = struct {
    message_id: u64 = 0,
    budget: u64 = 0,
};

pub const RunSlot = struct {
    gpa: std.mem.Allocator,
    handle: RunHandle,
    progress: RunProgress = .{},
    config: Config,
    phase: Phase = .pending_start,
    protocol: proto.enums.ProviderProtocol = .anthropic_messages,
    cancel_requested: bool = false,
    retry_budget: u8 = 8,
    retry_state: ?proto.activity.ActivityStateRetrying = null,
    wake_event: std.Io.Event = .unset,
    body: ?transport.ResponseBody = null,
    parent_id: ?ids.SessionId = null,
    tree_root: ids.SessionId,
    depth: u32 = 0,
    work: @import("work.zig") = .{},
    /// The catalog cannot change under a run, so the first tool selection caches this for the run.
    has_skills: ?bool = null,

    pub const Phase = enum { pending_start, running, terminalized, faulted };

    pub const Prepared = struct {
        gpa: std.mem.Allocator,
        slot: ?*RunSlot,
        config: Config,

        pub fn bind(self: *Prepared, handle: RunHandle, first_round: RoundState, parent_id: ?ids.SessionId, location: Location) *RunSlot {
            const slot = self.slot orelse unreachable;
            std.debug.assert(first_round.number == 1);
            if (parent_id == null) std.debug.assert(location.depth == 0) else std.debug.assert(location.depth > 0);
            self.slot = null;
            slot.* = .{
                .gpa = self.gpa,
                .handle = handle,
                .progress = .{ .rounds_started = 1, .current = first_round },
                .config = self.config,
                .parent_id = parent_id,
                .tree_root = location.root,
                .depth = location.depth,
            };
            return slot;
        }

        pub fn deinit(self: *Prepared) void {
            const slot = self.slot orelse return;
            self.gpa.free(self.config.model);
            self.gpa.free(self.config.reasoning);
            self.gpa.free(self.config.system_prompt);
            self.gpa.destroy(slot);
            self.slot = null;
        }
    };

    pub const Location = struct {
        root: ids.SessionId,
        depth: u32,
    };

    pub fn prepare(gpa: std.mem.Allocator, model: []const u8, reasoning: []const u8, system_prompt: []const u8, max_rounds: ?u64) !Prepared {
        const model_copy = try gpa.dupe(u8, model);
        errdefer gpa.free(model_copy);
        const reasoning_copy = try gpa.dupe(u8, reasoning);
        errdefer gpa.free(reasoning_copy);
        const prompt_copy = try gpa.dupe(u8, system_prompt);
        errdefer gpa.free(prompt_copy);
        const slot = try gpa.create(RunSlot);
        return .{ .gpa = gpa, .slot = slot, .config = .{ .model = model_copy, .reasoning = reasoning_copy, .system_prompt = prompt_copy, .max_rounds = max_rounds } };
    }

    pub fn sessionId(self: *const RunSlot) ids.SessionId {
        return self.handle.started.session_id;
    }

    pub fn runId(self: *const RunSlot) proto.ids.RunId {
        return self.handle.started.run_id;
    }

    pub fn destroy(self: *RunSlot) void {
        std.debug.assert(self.body == null);
        std.debug.assert(self.work.pending == 0);
        self.gpa.free(self.config.model);
        self.gpa.free(self.config.reasoning);
        self.gpa.free(self.config.system_prompt);
        self.gpa.destroy(self);
    }
};

pub const Error = error{OutOfMemory};

/// A session projection. The engine owns one for each active session.
pub const Session = struct {
    gpa: std.mem.Allocator,
    id: ids.SessionId,
    draft: ?Draft = null,
    pending: std.ArrayList(QueueItem) = .empty,
    transcript: Transcript,
    context_floor: ContextFloor = .{},
    base_seq: ids.Seq = 0,
    finalized_message_id: ids.MessageId = 0,
    active_run: ?*RunSlot = null,
    faulted: bool = false,
    hydrated: bool = false,
    context_usage: ?message.TokenUsage = null,
    pins: u32 = 0,

    pub fn init(gpa: std.mem.Allocator, id: ids.SessionId) Session {
        return .{ .gpa = gpa, .id = id, .transcript = Transcript.init(gpa) };
    }

    pub fn deinit(self: *Session) void {
        std.debug.assert(self.active_run == null);
        if (self.draft) |*d| d.deinit();
        for (self.pending.items) |*item| item.deinit();
        self.pending.deinit(self.gpa);
        self.transcript.deinit();
        self.* = undefined;
    }

    pub fn idle(self: *const Session) bool {
        return self.pins == 0 and self.active_run == null and self.pending.items.len == 0 and !self.faulted;
    }

    pub fn pin(self: *Session) void {
        self.pins += 1;
    }

    pub fn unpin(self: *Session) void {
        std.debug.assert(self.pins > 0);
        self.pins -= 1;
    }

    pub fn queueDepth(self: *const Session) usize {
        return self.pending.items.len;
    }

    pub fn queueEntries(self: *const Session) []const QueueItem {
        return self.pending.items;
    }

    /// Engine reports and notices wait outside the user queue limit.
    pub fn userQueueDepth(self: *const Session) usize {
        var depth: usize = 0;
        for (self.pending.items) |item| if (item.source == null or !item.source.?.protected()) {
            depth += 1;
        };
        return depth;
    }

    pub fn queueOnQueued(self: *Session, d: input.InputQueuedData) Error!void {
        std.debug.assert(self.queueIndex(d.input.input_id) == null);
        var item = try QueueItem.clone(self.gpa, d.input);
        errdefer item.deinit();
        try self.pending.append(self.gpa, item);
    }

    pub fn queueOnCanceled(self: *Session, input_id: ids.InputId) void {
        self.removeQueued(input_id);
    }

    pub fn queueRetire(self: *Session, input_id: ids.InputId) void {
        self.removeQueued(input_id);
    }

    /// Seal the projection after the store history is in the transcript. Call once before the first fold on a fresh Session.
    pub fn sealHistory(self: *Session, base_seq: ids.Seq, has_more: bool) void {
        std.debug.assert(self.base_seq == 0 and self.finalized_message_id == 0); // a fresh projection
        std.debug.assert(self.draft == null and self.pending.items.len == 0);
        const items = self.transcript.list.items;
        self.transcript.has_more = self.transcript.has_more or has_more;
        self.base_seq = base_seq;
        // The newest resident message is the finalized one. Eviction drops from the oldest end, so it stays resident.
        self.finalized_message_id = if (items.len > 0) items[items.len - 1].message.id() else 0;
    }

    /// Fold one event the engine built. The engine is the only writer, so this trusts the event
    /// and asserts the projection invariants.
    pub fn apply(self: *Session, bc: BroadcastData) Error!void {
        // The engine routes only its own session, so a mismatch is a routing bug.
        if (sessionOf(bc)) |s| std.debug.assert(std.meta.eql(s, self.id));
        return switch (bc) {
            .message_started_data => |d| self.onStarted(d),
            .message_part_added_data => |d| self.onPartAdded(d),
            .message_part_delta_data => |d| self.onDelta(d, .text),
            .tool_output_delta_data => |d| self.onDelta(d, .tool),
            .message_part_finalized_data => |d| self.onFinalized(d),
            .tool_state_changed_data => |d| self.onToolState(d),
            .message_discarded_data => |d| self.onDiscarded(d),
            .message_committed_data => |d| self.onCommitted(d),
            .input_queued_data => |d| self.onQueued(d),
            .input_canceled_data => |d| self.onCanceled(d),
            .transcript_truncated_data => |d| self.onTruncated(d),
            .run_started_data => |d| self.onCursor(d.seq),
            .run_done_data => |d| self.onCursor(d.seq),
            .config_changed_data => |d| self.onCursor(d.seq),
            // Index, workspace, auth, and notice events are not session-projection state.
            else => {},
        };
    }

    // Advance the durable cursor. A second process shares the store and takes seq values this
    // projection never sees, so the cursor only grows. It never counts by one.
    fn advance(self: *Session, seq: ids.Seq) void {
        std.debug.assert(seq > self.base_seq);
        self.base_seq = seq;
    }

    // Resolve a live event to the open draft. The engine emits in order, so a mismatch is a bug.
    fn activeDraft(self: *Session, message_id: ids.MessageId) *Draft {
        std.debug.assert(message_id > self.finalized_message_id); // a finalized message never reopens
        std.debug.assert(self.draft != null);
        const dr = &self.draft.?;
        std.debug.assert(dr.message_id == message_id);
        return dr;
    }

    fn onStarted(self: *Session, d: message.MessageStartedData) Error!void {
        std.debug.assert(d.message_id > self.finalized_message_id); // a finalized message never reopens
        std.debug.assert(self.draft == null);
        self.draft = try Draft.init(self.gpa, d);
    }

    fn onPartAdded(self: *Session, d: message.MessagePartAddedData) Error!void {
        try self.activeDraft(d.message_id).addPart(d);
    }

    const DeltaKind = enum { text, tool };

    fn onDelta(self: *Session, d: message.PartDelta, kind: DeltaKind) Error!void {
        const dr = self.activeDraft(d.message_id);
        return switch (kind) {
            .text => dr.applyPartDelta(d),
            .tool => dr.applyToolOutputDelta(d),
        };
    }

    fn onFinalized(self: *Session, d: message.MessagePartFinalizedData) Error!void {
        const dr = self.activeDraft(d.message_id);
        return switch (d.final) {
            .reasoning => |r| dr.finalizeReasoning(d.part_id, r.signature),
            .redacted_reasoning => |r| dr.finalizeRedacted(d.part_id, r.data),
        };
    }

    fn onToolState(self: *Session, d: proto.tool.ToolStateChangedData) Error!void {
        try self.activeDraft(d.message_id).applyToolState(d);
    }

    fn onDiscarded(self: *Session, d: message.MessageDiscardedData) void {
        const dr = self.activeDraft(d.message_id);
        dr.deinit();
        self.draft = null;
        self.raiseFinalized(d.message_id);
    }

    fn onCommitted(self: *Session, d: message.MessageCommittedData) Error!void {
        // The engine commits ids in order, which keeps the transcript oldest-first for the trim.
        std.debug.assert(d.message.id() > self.finalized_message_id);
        try self.transcript.append(d.message); // cache before the draft or queue mutates, so an OOM is clean
        switch (d.message) {
            .user => |u| self.queueRetire(u.input_id),
            .assistant => |a| if (self.draft) |*dr| {
                if (dr.message_id == a.id) {
                    dr.deinit();
                    self.draft = null;
                }
            },
            .compaction => {},
        }
        self.raiseFinalized(d.message.id());
        self.advance(d.seq);
    }

    fn onQueued(self: *Session, d: proto.input.InputQueuedData) Error!void {
        try self.queueOnQueued(d);
        self.advance(d.seq);
    }

    fn onCanceled(self: *Session, d: proto.input.InputCanceledData) void {
        self.queueOnCanceled(d.input_id);
        self.advance(d.seq);
    }

    fn onTruncated(self: *Session, d: proto.misc.TranscriptTruncatedData) void {
        self.raiseFinalized(d.first_removed_id); // truncated ids reject a late draft
        self.transcript.trimFrom(d.first_removed_id); // drop the truncated messages from the cache
        self.context_floor = .{};
        self.advance(d.seq);
    }

    fn onCursor(self: *Session, seq: ids.Seq) void {
        self.advance(seq);
    }

    fn raiseFinalized(self: *Session, message_id: ids.MessageId) void {
        if (message_id > self.finalized_message_id) self.finalized_message_id = message_id;
    }

    fn removeQueued(self: *Session, input_id: ids.InputId) void {
        const i = self.queueIndex(input_id) orelse return;
        var item = self.pending.orderedRemove(i);
        item.deinit();
    }

    fn queueIndex(self: *const Session, input_id: ids.InputId) ?usize {
        for (self.pending.items, 0..) |item, i| if (item.input_id == input_id) return i;
        return null;
    }
};

pub const QueueItem = struct {
    arena: std.heap.ArenaAllocator,
    input_id: ids.InputId,
    content: []const content.ContentPart,
    queued_at_ms: u64,
    source: ?proto.input.InputSource = null,
    skill_name: ?[]const u8 = null,

    fn clone(gpa: std.mem.Allocator, qi: misc.QueuedInput) Error!QueueItem {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const owned = try proto.dupe(arena.allocator(), qi.content);
        const source = try proto.dupe(arena.allocator(), qi.source);
        const skill_name = try proto.dupe(arena.allocator(), qi.skill_name);
        return .{ .arena = arena, .input_id = qi.input_id, .content = owned, .queued_at_ms = qi.queued_at_ms, .source = source, .skill_name = skill_name };
    }

    fn deinit(self: *QueueItem) void {
        self.arena.deinit();
    }
};

pub const Registry = struct {
    gpa: std.mem.Allocator,
    map: std.AutoHashMapUnmanaged(ids.SessionId, *Session) = .empty,

    pub fn init(gpa: std.mem.Allocator) Registry {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Registry) void {
        var it = self.map.valueIterator();
        while (it.next()) |session| {
            if (session.*.active_run) |slot| slot.destroy();
            session.*.active_run = null;
            session.*.deinit();
            self.gpa.destroy(session.*);
        }
        self.map.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn get(self: *Registry, session_id: ids.SessionId) ?*Session {
        return self.map.get(session_id);
    }

    pub fn getOrCreate(self: *Registry, session_id: ids.SessionId) !*Session {
        const gop = try self.map.getOrPut(self.gpa, session_id);
        errdefer if (!gop.found_existing) std.debug.assert(self.map.remove(session_id));
        if (!gop.found_existing) {
            const session = try self.gpa.create(Session);
            session.* = Session.init(self.gpa, session_id);
            gop.value_ptr.* = session;
        }
        return gop.value_ptr.*;
    }

    pub fn remove(self: *Registry, session_id: ids.SessionId) void {
        const entry = self.map.fetchRemove(session_id) orelse return;
        std.debug.assert(entry.value.active_run == null);
        std.debug.assert(entry.value.pins == 0);
        entry.value.deinit();
        self.gpa.destroy(entry.value);
    }

    pub fn evictIfIdle(self: *Registry, session_id: ids.SessionId) void {
        const session = self.map.get(session_id) orelse return;
        if (!session.idle()) return;
        std.debug.assert(self.map.remove(session_id));
        session.deinit();
        self.gpa.destroy(session);
    }
};

/// Return the session id a broadcast names, or null when the event carries none.
fn sessionOf(bc: BroadcastData) ?ids.SessionId {
    return switch (bc) {
        inline else => |d| if (@hasField(@TypeOf(d), "session_id")) d.session_id else null,
    };
}
