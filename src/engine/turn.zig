//! Execute model rounds and tools, then commit input at round boundaries.

const std = @import("std");
const proto = @import("proto");
const Engine = @import("Engine.zig");
const session_events = @import("events.zig");
const run = @import("run.zig");
const provider = @import("../provider/provider.zig");
const draft = @import("../session/draft.zig");
const Session = @import("../session/session.zig").Session;
const database = @import("../store/store.zig");
const toolset = @import("toolset.zig");
const registry = @import("../provider/registry.zig");
const ai = @import("ai");
const retry = ai.retry;

const ids = proto.ids;
const message = proto.message;
const RunSlot = run.RunSlot;
const message_store = database.message;
const reports = @import("reports.zig");
const session_store = database.session;
const event_store = database.event;
const event = ai.event;

const agent_name = "claude";
const round_request = @import("request.zig");
const request_context = @import("context.zig");
const request_config_mod = @import("request_config.zig");

/// Run one turn. The engine task group owns this task. The session owns `slot` until cleanup.
pub fn execute(engine: *Engine, slot: *RunSlot) void {
    std.debug.assert(slot.phase == .running);
    std.debug.assert(slot.handle.started.kind == .turn);
    const session_id = slot.sessionId();

    const rt = engine.sessions.get(session_id) orelse unreachable;
    std.debug.assert(rt.active_run == slot);

    // Clear a live draft on an early return. A commit fold nulls it first on the normal path.
    defer if (rt.draft != null) {
        rt.draft.?.deinit();
        rt.draft = null;
    };

    var streamer: Streamer = .{ .engine = engine, .slot = slot, .session = rt };
    defer streamer.blocks.deinit(engine.deps.gpa);

    var boundary_state: std.heap.ArenaAllocator = .init(engine.deps.gpa);
    defer boundary_state.deinit();
    const boundary_arena = boundary_state.allocator();
    consumeInitialInputs(engine, boundary_arena, slot) catch |err| {
        commitFinal(engine, boundary_arena, slot, null, false, null, if (err == error.Canceled) .canceled else .{ .failed = failure(err) });
        return;
    };

    while (true) {
        _ = boundary_state.reset(.retain_capacity);
        // Open this round. A commit reads the streamer, so clear it before any path can fail.
        streamer.reset();
        std.debug.assert(slot.progress.current == null);
        std.debug.assert(rt.draft == null); // one draft per round
        const terminal = streamRound(engine, boundary_arena, slot, &streamer);
        const live = if (rt.draft) |*live| live else {
            commitFinal(engine, boundary_arena, slot, null, false, streamer.usage, terminal);
            return;
        };

        // Settle any tool parts into a terminal state. The request builder rejects a pending tool.
        const has_tools = hasToolPart(live);
        if (has_tools) {
            if (terminal == .success and terminal.success == .tool_calls) {
                settlePendingTools(engine, boundary_arena, slot, &streamer, .run, live) catch |err| {
                    run.faultSlot(engine, slot, err);
                    return;
                };
            } else {
                // Cancel any pending tool part; a canceled/failed stream or a malformed tool_use lands here.
                settlePendingTools(engine, boundary_arena, slot, &streamer, .cancel, live) catch |err| {
                    run.faultSlot(engine, slot, err);
                    return;
                };
                if (terminal == .success) {
                    commitFinal(engine, boundary_arena, slot, live, has_tools, streamer.usage, .{ .failed = .{ .code = .protocol, .message = "a tool part without a tool_calls stop reason" } });
                    return;
                }
            }
        }

        commitRound(engine, boundary_arena, slot, live, has_tools, streamer.usage, terminal) catch |err| {
            run.faultSlot(engine, slot, err);
            return;
        };
        if (slot.phase == .terminalized) return;
    }
}

/// Include input accepted before the run task starts.
fn consumeInitialInputs(engine: *Engine, arena: std.mem.Allocator, slot: *RunSlot) !void {
    try engine.deps.io.checkCancel();
    const protection = engine.deps.io.swapCancelProtection(.blocked);
    defer _ = engine.deps.io.swapCancelProtection(protection);
    if (slot.cancel.isRequested()) return error.Canceled;
    std.debug.assert(slot.progress.current == null);
    var tx = try engine.deps.db.begin();
    defer tx.deinit();
    const inputs = try run.consumeQueued(engine.deps.db, engine.deps.io, arena, slot.sessionId().raw);
    try tx.commit();
    const rt = engine.sessions.get(slot.sessionId()).?;
    session_events.publishUserCommits(engine, rt, inputs);
    if (inputs.len > 0) session_events.announceActivity(engine, rt);
}

/// End a failed or canceled run and fault the slot on a save error.
fn commitFinal(engine: *Engine, arena: std.mem.Allocator, slot: *RunSlot, live: ?*const draft.Draft, has_tools: bool, usage: ?message.TokenUsage, terminal: Terminal) void {
    std.debug.assert(terminal != .success);
    if (live == null) {
        const outcome: proto.run.RunOutcome = switch (terminal) {
            .success => unreachable,
            .canceled => .{ .canceled = .{} },
            .failed => |item| .{ .failed = .{ .code = item.code, .message = item.message, .status = item.status, .request_id = item.request_id, .detail = item.detail } },
        };
        slot.progress.current = null;
        run.finishRunOpen(engine, arena, slot, outcome) catch |err| run.faultSlot(engine, slot, err);
        return;
    }
    commitRound(engine, arena, slot, live.?, has_tools, usage, terminal) catch |err| {
        run.faultSlot(engine, slot, err);
        return;
    };
}

/// Stream one round, and resend the same request while the classifier allows it.
/// Run one round. `out` outlives the round; a failure copies the provider answer into it.
fn streamRound(engine: *Engine, out: std.mem.Allocator, slot: *RunSlot, streamer: *Streamer) Terminal {
    // The request and its attempts die with this round, so a long run never accumulates them.
    var round_state: std.heap.ArenaAllocator = .init(engine.deps.gpa);
    defer round_state.deinit();
    const arena = round_state.allocator();

    // A request hook can await indefinitely, so the build runs as a child a run cancel can reach.
    var request: ?ai.PreparedRequest = null;
    defer if (request) |*prepared| prepared.deinit();
    const built = switch (slot.cancel.runChild(engine.deps.io, requestChild, .{ engine, arena, slot, &request })) {
        .canceled, .aborted => return .canceled,
        .returned => |result| result,
    };
    built catch |err| {
        if (err == error.Canceled) return .canceled;
        std.log.warn("run {d} could not build its request: {t}", .{ slot.runId(), err });
        return .{ .failed = failure(err) };
    };
    std.debug.assert(request != null);
    // The build state dies here, so the projected transcript and the blob bytes do not stay live while the stream runs.
    _ = round_state.reset(.free_all);

    const rt = streamer.session;
    const session_id = slot.sessionId();
    beginRound(engine, arena, slot) catch |err| return .{ .failed = failure(err) };
    const created_at = slot.progress.current.?.created_at_ms;
    const started_note: proto.rpc.Notification = .{ .method = .@"message.started", .params = .{ .message_started_data = .{
        .session_id = session_id,
        .message_id = slot.progress.current.?.message_id,
        .run_id = slot.runId(),
        .config_rev = slot.handle.started.config_rev,
        .agent = agent_name,
        .created_at_ms = created_at,
    } } };
    // Fold the start into the session, then publish. The fold opens the draft.
    rt.apply(started_note.params) catch |err| {
        return .{ .failed = failure(err) };
    };
    engine.sinks.emit(started_note);
    std.debug.assert(slot.round == .none); // the last round closed before this one opened
    slot.round = .waiting;
    defer slot.round = .none; // every exit closes the round, so a phase cannot outlive it
    session_events.announceActivity(engine, rt); // `run.started` says a run exists, not what it does.

    var number: u8 = 1;
    while (true) : (number += 1) {
        streamer.reset();
        _ = round_state.reset(.retain_capacity); // The storage of one attempt dies with it.
        var info: ai.transport.AttemptInfo = .{};
        const terminal = streamAttempt(engine, arena, slot, streamer, &request.?, &info) catch |err| {
            const delay_ms = retry.decide(engine.deps.retry_policy, .{
                .err = err,
                .info = info,
                // The client already folded a published event, so a repeat must not send it again.
                .saw_semantic = streamer.saw_semantic,
                .number = number,
                .budget_left = slot.retry_budget,
            }, engine.jitter()) orelse {
                std.log.warn("run {d} attempt {d} ended: {t} (status {?d})", .{ slot.runId(), number, err, info.status });
                return .{ .failed = attemptFailure(out, err, &info) };
            };

            std.debug.assert(slot.retry_budget > 0); // the classifier refuses a retry at zero
            slot.retry_budget -= 1;
            publishRetrying(engine, rt, slot, number, err, info.status, delay_ms);
            if (slot.cancel.holdFor(engine.deps.io, delay_ms) catch true) return .canceled;
            // The hold is over. The label must say `waiting` again, not the old countdown.
            std.debug.assert(slot.round == .retrying);
            slot.round = .waiting;
            session_events.announceActivity(engine, rt);
            continue;
        };
        return terminal;
    }
}

/// Record the wait on the slot, then publish it, so the wait shows as a retry and not a silent pause.
fn publishRetrying(engine: *Engine, rt: *Session, slot: *RunSlot, number: u8, err: anyerror, status: ?u16, delay_ms: u64) void {
    const detail = failure(err);
    std.log.info("run {d} attempt {d} ended with {t} (status {?d}); the next attempt starts in {d} ms with {d} retries left", .{ slot.runId(), number, err, status, delay_ms, slot.retry_budget });
    std.debug.assert(slot.round == .waiting or slot.round == .streaming); // only a live attempt can fail
    slot.round = .{ .retrying = .{
        .run_id = slot.runId(),
        .attempt = number,
        .max_attempts = engine.deps.retry_policy.max_attempts,
        .next_at_ms = engine.nowMillis() + delay_ms,
        .code = detail.code,
        .message = detail.message,
    } };
    // Announce the whole activity, so the context gauge, the config and the queue stay true.
    session_events.announceActivity(engine, rt);
}

/// Run one attempt. The child owns the body and cancellation.
fn streamAttempt(
    engine: *Engine,
    arena: std.mem.Allocator,
    slot: *RunSlot,
    streamer: *Streamer,
    request: *const ai.PreparedRequest,
    info: *ai.transport.AttemptInfo,
) anyerror!Terminal {
    const result = switch (slot.cancel.runChild(engine.deps.io, streamChild, .{ engine, arena, slot, streamer, request, info })) {
        .canceled, .aborted => return .canceled,
        .returned => |r| r,
    };
    if (result) |_| {
        if (slot.cancel.isRequested()) return .canceled;
        const reason = streamer.stop_reason orelse
            return .{ .failed = .{ .code = .protocol, .message = "the provider stream has no stop reason" } };
        return .{ .success = reason };
    } else |err| {
        if (err == error.Canceled or slot.cancel.isRequested()) return .canceled;
        return err;
    }
}

fn requestChild(engine: *Engine, arena: std.mem.Allocator, slot: *RunSlot, out: *?ai.PreparedRequest) !void {
    std.debug.assert(out.* == null);
    defer slot.cancel.finish(engine.deps.io);
    try slot.cancel.check(engine.deps.io);
    out.* = try roundRequest(engine, arena, slot);
}

/// Build the request for one round. A retry re-sends these bytes, so the cached prefix still matches.
fn roundRequest(engine: *Engine, arena: std.mem.Allocator, slot: *RunSlot) !ai.PreparedRequest {
    const model = slot.config.model;

    // The catalog must resolve the model. An unresolved selector is an operating error, not a bug.
    const resolved = engine.deps.providers.merged.resolveModel(model) orelse return error.UnknownModel;

    const held = try round_request.snapshot(arena, engine, slot, resolved);
    const projected = request_context.project(engine.deps.gpa, arena, engine.deps.db, slot.sessionId().raw, held.budget) catch |err| switch (err) {
        error.ContextHistoryTooLarge => blk: {
            try @import("compaction.zig").compactForRequest(engine, arena, slot, held);
            break :blk try request_context.project(engine.deps.gpa, arena, engine.deps.db, slot.sessionId().raw, held.budget);
        },
        else => return err,
    };
    return round_request.prepare(arena, engine, slot, held, projected);
}

/// Open the response and stream it into the draft, in a child so a cancel can interrupt a blocked read.
fn streamChild(engine: *Engine, arena: std.mem.Allocator, slot: *RunSlot, streamer: *Streamer, request: *const ai.PreparedRequest, info: *ai.transport.AttemptInfo) !void {
    defer slot.cancel.finish(engine.deps.io);
    try slot.cancel.check(engine.deps.io);
    const body = try engine.deps.route_transport.open(arena, request.transport_request, info);
    std.debug.assert(slot.body == null); // one body per run
    slot.body = body;
    // The transport returns after the response head, so the provider accepted this attempt.
    std.debug.assert(slot.round == .waiting);
    slot.round = .streaming;
    session_events.announceActivity(engine, streamer.session);
    defer {
        slot.body = null;
        body.deinit();
    }
    try slot.cancel.check(engine.deps.io);
    try ai.consume(engine.deps.gpa, body, request.protocol, streamer, Streamer.onEvent);
}

const Terminal = union(enum) {
    success: proto.enums.StopReason,
    canceled,
    failed: Failure,
};

const Failure = struct {
    code: proto.enums.RunErrorCode,
    message: []const u8,
    status: ?u16 = null,
    request_id: ?[]const u8 = null,
    detail: ?[]const u8 = null,
};

/// Map a run failure to its wire code and sentence. `provider.failure` holds the one error table.
fn failure(err: anyerror) Failure {
    const detail = provider.failure.classify(err);
    return .{ .code = detail.code, .message = detail.message };
}

/// Map the final attempt, and copy what the provider answered into `out`, because the attempt arena dies with the round.
fn attemptFailure(out: std.mem.Allocator, err: anyerror, info: *const ai.transport.AttemptInfo) Failure {
    var result = failure(err);
    result.status = info.status;
    result.request_id = if (info.request_id) |id| out.dupe(u8, id) catch unreachable else null;
    result.detail = if (info.body) |body| provider.failure.detailText(out, body) catch unreachable else null;
    return result;
}

/// Commit the current round, and terminalize the run only when this is the final round.
fn commitRound(
    engine: *Engine,
    arena: std.mem.Allocator,
    slot: *RunSlot,
    live: *const draft.Draft,
    has_tools: bool,
    usage: ?message.TokenUsage,
    response: Terminal,
) !void {
    std.debug.assert(slot.phase == .running);
    std.debug.assert(slot.body == null);
    std.debug.assert(slot.progress.current != null);
    const old_cancel_protection = engine.deps.io.swapCancelProtection(.blocked);
    defer _ = engine.deps.io.swapCancelProtection(old_cancel_protection);

    const result: Terminal = if (slot.cancel.isRequested()) .canceled else response;
    const session_id = slot.sessionId();
    var tx = try engine.deps.db.begin();
    defer tx.deinit();
    // Only a success can continue, so only a success reads the queue, and one read serves the count and the consume.
    const queued: []const database.input.Entry = if (result == .success) try database.input.list(engine.deps.db, arena, session_id.raw) else &.{};
    const wants_next = result == .success and (has_tools or queued.len > 0);
    const capped = wants_next and if (slot.config.max_rounds) |cap| slot.progress.rounds_committed >= cap -| 1 else false;
    const terminal: Terminal = if (capped) .{ .failed = .{ .code = .max_rounds, .message = "the run reached its max_rounds limit" } } else result;
    const final = !wants_next or capped;
    const rounds_committed = slot.progress.rounds_committed + 1;
    const round = &slot.progress.current.?;
    const content = (try live.toActiveDraft(arena)).message.content;
    const ended_at = @max(engine.nowMillis(), slot.handle.started.started_at_ms);
    const finish: proto.enums.StopReason = switch (terminal) {
        .success => |reason| reason,
        .canceled => .canceled,
        .failed => .@"error",
    };
    const message_error: ?message.MessageError = switch (terminal) {
        .failed => |item| .{ .type = @tagName(item.code), .message = item.message, .status = item.status, .request_id = item.request_id, .detail = item.detail },
        else => null,
    };
    const committed: message.Message = .{ .assistant = .{
        .id = round.message_id,
        .run_id = slot.runId(),
        .config_rev = slot.handle.started.config_rev,
        .agent = agent_name,
        .content = content,
        .finish = finish,
        .tokens = usage,
        .cost = null,
        .time = .{ .created_at_ms = round.created_at_ms, .completed_at_ms = ended_at },
        .@"error" = message_error,
        .provenance = .{ .protocol = slot.protocol, .model = slot.config.model },
    } };
    const outcome: proto.run.RunOutcome = switch (terminal) {
        .success => |reason| .{ .turn = .{ .finish = reason, .rounds = rounds_committed } },
        .canceled => .{ .canceled = .{} },
        .failed => |item| .{ .failed = .{ .code = item.code, .message = item.message, .status = item.status, .request_id = item.request_id, .detail = item.detail } },
    };
    // The committed content borrows the draft. The commit fold frees the draft, so own a copy first.
    const owned = try proto.dupe(arena, committed);
    const commit = try message_store.appendCommittedMessage(engine.deps.db, arena, session_id.raw, engine.newId(), ended_at, owned);
    const done: ?reports.Terminal = if (final) try reports.append(engine, arena, .{
        .session_id = session_id,
        .seq = 0,
        .run_id = slot.runId(),
        .kind = slot.handle.started.kind,
        .timing = .{ .started_at_ms = slot.handle.started.started_at_ms, .ended_at_ms = ended_at },
        .outcome = outcome,
    }) else null;
    const inputs = if (!final) try run.consumeEntries(engine.deps.db, engine.deps.io, arena, session_id.raw, queued) else &.{};
    try tx.commit();
    slot.progress.rounds_committed = rounds_committed;
    slot.progress.current = null;
    if (final) slot.phase = .terminalized;

    const rt = engine.sessions.get(session_id) orelse unreachable;
    session_events.emitCommitted(engine, rt, commit);
    session_events.publishUserCommits(engine, rt, inputs);
    if (inputs.len == 0) session_events.announceSummary(engine, session_id);
    if (!final) session_events.announceActivity(engine, rt);
    if (done) |terminal_result| run.publishTerminal(engine, rt, terminal_result);
}

/// Allocate the next round: allocate a message id, then advance the progress state.
fn beginRound(engine: *Engine, arena: std.mem.Allocator, slot: *RunSlot) !void {
    std.debug.assert(slot.progress.current == null);
    var tx = try engine.deps.db.*.begin();
    defer tx.deinit();
    const message_id = try event_store.allocMessageId(engine.deps.db, arena, slot.sessionId().raw);
    try tx.commit();
    slot.progress.current = .{ .message_id = message_id, .created_at_ms = engine.nowMillis() };
}

/// Report whether an event carries model output that closes the retry window.
fn isSemantic(ev: event.StreamEvent) bool {
    return switch (ev) {
        .block_started, .block_stopped => true,
        // A completed stream must not repeat either. A later body fault would duplicate the round.
        .done => true,
        .text_delta => |d| d.text.len != 0,
        .reasoning_delta => |d| d.text.len != 0,
        .tool_input_delta => |d| d.partial_json.len != 0,
    };
}

/// One stream block. `part_id` stays null until the block opens its wire part.
const BlockSlot = struct {
    part_id: ?ids.PartId = null,
    /// True after the block stops. A reducer stops a block one time.
    stopped: bool = false,
    /// The byte count that the deltas of this part already carry.
    offset: u64 = 0,
};

const Streamer = struct {
    engine: *Engine,
    slot: *RunSlot,
    session: *Session,
    /// One row per stream block, indexed by the reducer's dense `BlockId`.
    blocks: std.ArrayList(BlockSlot) = .empty,
    /// The next wire part id. A part takes its id when the engine emits it, never from a block id.
    next_part_id: ids.PartId = 0,
    stop_reason: ?proto.enums.StopReason = null,
    usage: ?message.TokenUsage = null,
    /// A semantic event reached the client. A repeat of the request would duplicate it.
    saw_semantic: bool = false,

    /// Reset the per-round stream engine before a new round.
    fn reset(self: *Streamer) void {
        self.blocks.clearRetainingCapacity();
        self.next_part_id = 0;
        self.stop_reason = null;
        self.usage = null;
        self.saw_semantic = false;
    }

    /// Fold the canonical value first, then publish the same value. The engine never folds its own output.
    fn emit(self: *Streamer, note: proto.rpc.Notification) !void {
        try self.session.apply(note.params);
        self.engine.sinks.emit(note);
    }

    fn onEvent(self: *Streamer, ev: event.StreamEvent) !void {
        // Check cancellation after each SSE event.
        try self.slot.cancel.check(self.engine.deps.io);
        // Latch the boundary before the emit below. The latch then blocks a replay of this output.
        if (isSemantic(ev)) self.saw_semantic = true;
        switch (ev) {
            .block_started => |b| {
                // A part takes the next id when it is emitted, so parallel blocks keep the wire ids dense.
                std.debug.assert(b.block == self.blocks.items.len); // the reducer assigns dense ids in start order
                try self.blocks.append(self.engine.deps.gpa, .{});
                // A tool block has no metadata yet. Open its part at block_stopped instead.
                if (b.kind != .tool) {
                    const part_id = self.openPart(b.block);
                    try self.emit(.{ .method = .@"message.part_added", .params = .{ .message_part_added_data = .{
                        .session_id = self.slot.sessionId(),
                        .message_id = self.slot.progress.current.?.message_id,
                        .part = emptyPart(part_id, b.kind),
                    } } });
                    // A block boundary is the only point in a turn that moves the phase. A delta never does.
                    session_events.announceActivity(self.engine, self.session);
                }
            },
            .text_delta => |d| try self.partDelta(d.block, d.text),
            .reasoning_delta => |d| try self.partDelta(d.block, d.text),
            .tool_input_delta => {}, // The reducer joins fragments; the whole call arrives at block_stopped.
            .block_stopped => |b| {
                const stopped_index = self.blockIndex(b.block);
                std.debug.assert(!self.blocks.items[stopped_index].stopped); // the reducer stops a block one time
                self.blocks.items[stopped_index].stopped = true;
                switch (b.result) {
                    .reasoning => |r| try self.emitFinalized(self.partIdOf(b.block), .{ .reasoning = .{ .signature = r.signature } }),
                    .redacted_reasoning => |r| try self.emitFinalized(self.partIdOf(b.block), .{ .redacted_reasoning = .{ .data = r.data } }),
                    .text => {},
                    // A tool part carries its call metadata, so it opens here and not at the start.
                    .tool => |call| try self.emitToolPart(self.openPart(b.block), call),
                }
            },
            .done => |d| {
                self.stop_reason = provider.finishReasonToProto(d.stop_reason);
                self.usage = provider.usageToProto(d.usage);
            },
        }
    }

    /// Give `block` the next wire part id. Parts are dense in emit order.
    fn openPart(self: *Streamer, block: event.BlockId) ids.PartId {
        const slot = &self.blocks.items[self.blockIndex(block)];
        std.debug.assert(slot.part_id == null); // a block opens its part one time
        const part_id = self.next_part_id;
        slot.part_id = part_id;
        self.next_part_id += 1;
        return part_id;
    }

    /// Read the wire part id of an open block.
    fn partIdOf(self: *Streamer, block: event.BlockId) ids.PartId {
        const slot = self.blocks.items[self.blockIndex(block)];
        return slot.part_id.?; // the block opened its part before this event
    }

    fn blockIndex(self: *const Streamer, block: event.BlockId) usize {
        const index: usize = @intCast(block);
        std.debug.assert(index < self.blocks.items.len); // the reducer starts a block before it names it
        return index;
    }

    fn partDelta(self: *Streamer, block: event.BlockId, text: []const u8) !void {
        const index = self.blockIndex(block);
        const part_id = self.blocks.items[index].part_id.?; // a delta follows the part that block_started opened
        const offset = self.blocks.items[index].offset;
        try checkStreamCap(offset, text.len); // The provider is a peer. Return an error for an oversized delta.
        try self.emit(.{ .method = .@"message.part_delta", .params = .{ .message_part_delta_data = .{
            .session_id = self.slot.sessionId(),
            .message_id = self.slot.progress.current.?.message_id,
            .part_id = part_id,
            .delta = text,
            .offset = offset,
        } } });
        self.blocks.items[index].offset += text.len;
    }

    fn emitFinalized(self: *Streamer, part_id: ids.PartId, final: message.PartFinal) !void {
        // The provider controls the final metadata size. Reject an oversized signature or data payload.
        const len = switch (final) {
            .reasoning => |r| r.signature.len,
            .redacted_reasoning => |r| r.data.len,
        };
        try checkStreamCap(0, len);
        try self.emit(.{ .method = .@"message.part_finalized", .params = .{ .message_part_finalized_data = .{
            .session_id = self.slot.sessionId(),
            .message_id = self.slot.progress.current.?.message_id,
            .part_id = part_id,
            .final = final,
        } } });
        session_events.announceActivity(self.engine, self.session); // A closed reasoning part ends the reasoning phase.
    }

    /// Open a pending tool part when its block stops; the provider is a peer, so cap metadata sizes, and the part stays pending until the run settles it into a terminal state.
    fn emitToolPart(self: *Streamer, part_id: ids.PartId, call: event.ToolCall) !void {
        try checkStreamCap(0, call.name.len);
        try checkStreamCap(0, call.call_id.len);
        try checkStreamCap(0, call.arguments.len);
        try self.emit(.{ .method = .@"message.part_added", .params = .{ .message_part_added_data = .{
            .session_id = self.slot.sessionId(),
            .message_id = self.slot.progress.current.?.message_id,
            .part = .{ .tool = .{
                .id = part_id,
                .call_id = call.call_id,
                .name = call.name,
                .arguments = call.arguments,
                .state = .{ .pending = .{} },
            } },
        } } });
        session_events.announceActivity(self.engine, self.session);
    }

    /// Fold and publish a tool engine transition for one part.
    fn emitToolState(self: *Streamer, part_id: proto.ids.PartId, tool_state: proto.tool.ToolState) !void {
        try self.emit(.{ .method = .@"tool.state_changed", .params = .{ .tool_state_changed_data = .{
            .session_id = self.slot.sessionId(),
            .message_id = self.slot.progress.current.?.message_id,
            .part_id = part_id,
            .state = tool_state,
        } } });
        session_events.announceActivity(self.engine, self.session);
    }
};

/// Return the canonical workspace root for a session. The built-in tools resolve paths against it.
/// True when the draft holds any tool part.
fn hasToolPart(live: *const draft.Draft) bool {
    for (live.parts.items) |*p| if (p.* == .tool) return true;
    return false;
}

/// One pending tool call. A snapshot frees the tool call from the draft parts array.
const PendingTool = struct { part_id: proto.ids.PartId, name: []const u8, arguments: []const u8 };

/// A round that ended with tool calls runs them; any other end cancels the parts it left pending.
const Settle = enum { run, cancel };

/// Settle pending tools in part order, which is the order the blocks stopped, not the item order.
fn settlePendingTools(engine: *Engine, arena: std.mem.Allocator, slot: *RunSlot, streamer: *Streamer, settle: Settle, live: *const draft.Draft) !void {
    var pending: std.ArrayList(PendingTool) = .empty;
    for (live.parts.items) |*p| {
        if (p.* != .tool or std.meta.activeTag(p.tool.state) != .pending) continue;
        try pending.append(arena, .{ .part_id = p.tool.id, .name = p.tool.name, .arguments = p.tool.arguments });
    }
    for (pending.items) |pt| {
        if (settle == .cancel or slot.cancel.isRequested()) {
            try streamer.emitToolState(pt.part_id, .{ .canceled = .{} });
            continue;
        }
        try runOneTool(engine, slot, streamer, pt);
    }
}

/// Run one tool in a child task, so a cancel can interrupt a blocked call.
fn runOneTool(engine: *Engine, slot: *RunSlot, streamer: *Streamer, pt: PendingTool) !void {
    return switch (slot.cancel.runChild(engine.deps.io, toolChild, .{ engine, slot, streamer, pt })) {
        .canceled => {}, // The child settled its part canceled. The next part still settles.
        .aborted => error.Canceled,
        .returned => |result| result,
    };
}

/// Run one tool and emit exactly one terminal state despite cancellation.
fn toolChild(engine: *Engine, slot: *RunSlot, streamer: *Streamer, pt: PendingTool) !void {
    std.debug.assert(slot.phase == .running); // the run loop owns the slot for this round
    std.debug.assert(slot.progress.current != null); // the round opened the message
    defer slot.cancel.finish(engine.deps.io);
    const started = engine.nowMillis();
    {
        const old = engine.deps.io.swapCancelProtection(.blocked);
        defer _ = engine.deps.io.swapCancelProtection(old);
        try streamer.emitToolState(pt.part_id, .{ .running = .{ .started_at_ms = started } });
    }
    // The session folds the state before this arena releases the tool result.
    var scratch_state: std.heap.ArenaAllocator = .init(engine.deps.gpa);
    defer scratch_state.deinit();
    const res = runHooked(engine, scratch_state.allocator(), slot, pt) catch {
        const cancel_old = engine.deps.io.swapCancelProtection(.blocked);
        defer _ = engine.deps.io.swapCancelProtection(cancel_old);
        try streamer.emitToolState(pt.part_id, .{ .canceled = .{ .duration_ms = engine.nowMillis() -| started } });
        return;
    };
    const duration = engine.nowMillis() -| started; // Saturate; the wall clock can move backward.
    const old = engine.deps.io.swapCancelProtection(.blocked);
    defer _ = engine.deps.io.swapCancelProtection(old);
    const settled: proto.tool.ToolState = if (slot.cancel.isRequested())
        .{ .canceled = .{ .duration_ms = duration } }
    else if (res.is_error)
        .{ .@"error" = .{ .@"error" = res.output, .view = res.view, .duration_ms = duration } }
    else
        .{ .completed = .{ .output = res.output, .view = res.view, .media = if (res.media.len == 0) null else res.media, .duration_ms = duration } };
    try streamer.emitToolState(pt.part_id, settled);
}

/// One tool call the model asked for. A `tool.before` handler may replace either field.
const ToolCall = struct {
    name: []const u8,
    arguments: []const u8,
};

/// The call and the session it runs in. The context is read-only; a replace answers a `ToolCall`.
const ToolCallPayload = struct {
    name: []const u8,
    arguments: []const u8,
    context: request_config_mod.HookContext,
};

test "the run loadout gates a tool call, and a tool.before rewrite lands inside it" {
    const State = struct {
        calls: usize = 0,

        fn names(_: *anyopaque, arena: std.mem.Allocator) error{OutOfMemory}![]const []const u8 {
            return try arena.dupe([]const u8, &.{ "delegate", "read" });
        }

        fn execute(raw: *anyopaque, _: std.mem.Allocator, name: []const u8, _: []const u8, _: toolset.Context) toolset.Outcome {
            const self: *@This() = @ptrCast(@alignCast(raw));
            std.debug.assert(std.mem.eql(u8, name, "delegate"));
            self.calls += 1;
            return .{ .output = "done", .is_error = false };
        }

        fn holds(_: *anyopaque, point: proto.hook.Point) bool {
            return point == .@"tool.before" or point == .@"tools.select";
        }

        fn ask(_: *anyopaque, arena: std.mem.Allocator, point: proto.hook.Point, payload: []const u8) @import("hookset.zig").Decision {
            const sent = std.json.parseFromSliceLeaky(std.json.Value, arena, payload, .{}) catch unreachable;
            const context = sent.object.get("context").?.object;
            std.debug.assert(context.get("parent_id").? == .null);
            std.debug.assert(context.get("depth").?.integer == 0);
            std.debug.assert(std.mem.eql(u8, "root", context.get("agent_name").?.string));
            if (point == .@"tools.select") {
                const value = std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"tools\":[\"delegate\"]}", .{}) catch unreachable;
                return .{ .replace = value };
            }
            std.debug.assert(point == .@"tool.before");
            if (!std.mem.eql(u8, sent.object.get("name").?.string, "read")) return .proceed;
            const value = std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"name\":\"delegate\",\"arguments\":\"{}\"}", .{}) catch unreachable;
            return .{ .replace = value };
        }
    };
    var f: StreamerFixture = undefined;
    try f.init();
    defer f.deinit();
    var state: State = .{};
    f.engine.installTools(.{ .ctx = &state, .names = State.names, .run = State.execute });
    f.engine.installHooks(.{ .ctx = &state, .holds = State.holds, .ask = State.ask });
    var scratch: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer scratch.deinit();
    // `write` is outside the loadout, so the process never runs it.
    const refused = try runHooked(&f.engine, scratch.allocator(), f.slot, .{ .part_id = 0, .name = "write", .arguments = "{}" });
    try std.testing.expect(refused.is_error);
    try std.testing.expectEqual(@as(usize, 0), state.calls);
    // `read` is rewritten to `delegate`, which the loadout allows.
    const accepted = try runHooked(&f.engine, scratch.allocator(), f.slot, .{ .part_id = 0, .name = "read", .arguments = "{}" });
    try std.testing.expect(!accepted.is_error);
    try std.testing.expectEqual(@as(usize, 1), state.calls);
    try std.testing.expectEqual(@as(usize, 1), f.slot.tools.?.names.len);
}

test "a tool.after replacement is the whole result, and the engine admits the media that remains" {
    const State = struct {
        media: [1]proto.content.MediaBlob = .{.{ .hash = .bytes(@splat(0x5a)), .mime = "image/png", .bytes = 1 }},
        replace: bool = true,

        fn execute(raw: *anyopaque, _: std.mem.Allocator, _: []const u8, _: []const u8, _: toolset.Context) toolset.Outcome {
            const self: *@This() = @ptrCast(@alignCast(raw));
            return .{ .output = "raw", .media = &self.media, .is_error = false };
        }

        fn holds(_: *anyopaque, point: proto.hook.Point) bool {
            return point == .@"tool.after";
        }

        fn ask(raw: *anyopaque, arena: std.mem.Allocator, point: proto.hook.Point, _: []const u8) @import("hookset.zig").Decision {
            const self: *@This() = @ptrCast(@alignCast(raw));
            std.debug.assert(point == .@"tool.after");
            if (!self.replace) return .proceed;
            const value = std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"output\":\"clean\",\"is_error\":false}", .{}) catch unreachable;
            return .{ .replace = value };
        }
    };
    var f: StreamerFixture = undefined;
    try f.init();
    defer f.deinit();
    var state: State = .{};
    f.engine.installTools(.{ .ctx = &state, .names = Resources.serveNames(&.{"read"}), .run = State.execute });
    f.engine.installHooks(.{ .ctx = &state, .holds = State.holds, .ask = State.ask });
    var scratch: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer scratch.deinit();
    const pending: PendingTool = .{ .part_id = 0, .name = "read", .arguments = "{}" };
    // The replacement omits the media, so the bad ref is gone before admission.
    const replaced = try runHooked(&f.engine, scratch.allocator(), f.slot, pending);
    try std.testing.expect(!replaced.is_error);
    try std.testing.expectEqualStrings("clean", replaced.output);
    try std.testing.expectEqual(@as(usize, 0), replaced.media.len);
    // Without the replacement, the ref the store lacks turns the result into an error.
    state.replace = false;
    const refused = try runHooked(&f.engine, scratch.allocator(), f.slot, pending);
    try std.testing.expect(refused.is_error);
    try std.testing.expect(std.mem.indexOf(u8, refused.output, "does not hold") != null);
}

/// Run one tool through its hooks. A block answers the model, and the process runs nothing.
fn runHooked(engine: *Engine, arena: std.mem.Allocator, slot: *RunSlot, pt: PendingTool) !toolset.Outcome {
    const hooks = engine.deps.hooks;
    const held = try request_config_mod.loadout(engine, arena, slot);
    var call: ToolCall = .{ .name = pt.name, .arguments = pt.arguments };
    const payload: ToolCallPayload = .{ .name = pt.name, .arguments = pt.arguments, .context = request_config_mod.hookContext(slot, held.has_skills) };
    switch (hooks.askIfHeld(arena, .@"tool.before", payload)) {
        .proceed => {},
        // A handler that answers an unreadable call keeps the one the model chose.
        .replace => |value| call = std.json.parseFromValueLeaky(ToolCall, arena, value, .{ .ignore_unknown_fields = true }) catch blk: {
            std.log.warn("run {d} tool.before answered an unreadable call; the process keeps the original", .{slot.runId()});
            break :blk call;
        },
        .block => |reason| return .{ .output = reason, .is_error = true },
        .canceled => return error.Canceled,
    }

    const tools = engine.deps.tools;
    if (!held.allows(call.name)) return .{ .output = "The tool is unavailable in this session.", .is_error = true };
    const res = tools.run(tools.ctx, arena, call.name, call.arguments, .{
        .workspace_root = slot.config.root,
        .site = .{ .session_id = slot.sessionId(), .message_id = slot.progress.current.?.message_id, .part_id = pt.part_id },
        .work = &slot.work,
    });

    const after = hooks.askIfHeld(arena, .@"tool.after", .{
        .name = call.name,
        .arguments = call.arguments,
        .output = res.output,
        .is_error = res.is_error,
        .view = res.view,
        .media = res.media,
    });
    const outcome: toolset.Outcome = switch (after) {
        .proceed => res,
        // A replacement is the whole result, so a field it omits is gone.
        .replace => |value| std.json.parseFromValueLeaky(toolset.Outcome, arena, value, .{ .ignore_unknown_fields = true }) catch blk: {
            std.log.warn("run {d} tool.after answered an unreadable result; the process keeps the original", .{slot.runId()});
            break :blk res;
        },
        .block => |reason| return .{ .output = reason, .is_error = true },
        .canceled => return error.Canceled,
    };
    return admitMedia(engine, arena, outcome);
}

/// Admit the images a tool answered. An error state carries none, and a bad blob turns the result into an error.
fn admitMedia(engine: *Engine, arena: std.mem.Allocator, outcome: toolset.Outcome) error{ OutOfMemory, Canceled }!toolset.Outcome {
    if (outcome.is_error or outcome.media.len == 0) return outcome;
    engine.deps.blobs.admitBlobs(engine.deps.io, arena, outcome.media) catch |err| switch (err) {
        error.OutOfMemory, error.Canceled => |e| return e,
        error.BlobStoreFailed => return .{
            .output = "The engine could not persist the tool image.",
            .is_error = true,
        },
        error.BlobMissing, error.BlobMismatch, error.BlobTooManyImages, error.BlobUnsupportedPart => return .{
            .output = "The tool answered an image the engine does not hold.",
            .is_error = true,
        },
    };
    return outcome;
}

/// Reject a provider payload that would exceed the stream cap. This is peer input. Return an error.
fn checkStreamCap(offset: u64, len: usize) error{ResponseTooLarge}!void {
    const cap: u64 = @intCast(proto.meta.limits.max_message_string_bytes);
    if (offset > cap or len > cap - offset) return error.ResponseTooLarge;
}

fn emptyPart(part_id: ids.PartId, kind: event.BlockKind) message.AssistantPart {
    return switch (kind) {
        .text => .{ .text = .{ .id = part_id, .text = "" } },
        .reasoning => .{ .reasoning = .{ .id = part_id, .text = "", .signature = "" } },
        .redacted_reasoning => .{ .redacted_reasoning = .{ .id = part_id, .data = "" } },
        .tool => unreachable, // A tool part opens at block_stopped, not block_started.
    };
}

test "the stream cap rejects an oversized provider delta" {
    const max = proto.meta.limits.max_message_string_bytes;
    try checkStreamCap(0, max); // A delta up to the cap is allowed.
    try std.testing.expectError(error.ResponseTooLarge, checkStreamCap(0, max + 1));
    try std.testing.expectError(error.ResponseTooLarge, checkStreamCap(max, 1));
    try std.testing.expectError(error.ResponseTooLarge, checkStreamCap(max + 1, 0));
}

const Resources = @import("test_resources.zig");

/// Drive `Streamer.onEvent` over a real engine, session, and draft. The caller reads the draft parts.
const StreamerFixture = struct {
    resources: Resources,
    db: database.Database,
    engine: Engine,
    slot: *RunSlot,
    session: *Session,

    const session_id = [_]u8{9} ** 16;
    /// The one user turn a request test serializes.
    const hello: message.Message = .{ .user = .{
        .id = 1,
        .input_id = 1,
        .content = &.{.{ .text = .{ .text = "hello" } }},
        .time = .{ .created_at_ms = 0 },
    } };

    fn init(self: *StreamerFixture) !void {
        return self.initWithPrompt(.{ .base = "", .child_policy = null, .environment = "" });
    }

    fn initWithPrompt(self: *StreamerFixture, parts: session_store.PromptInput) !void {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        try self.resources.init();
        errdefer self.resources.deinit();
        self.db = try database.Database.openTest();
        errdefer self.db.deinit();
        try Resources.seedSession(&self.db, session_id, .{ .model = "mock", .title = "t" });
        const system = try session_store.setPrompt(&self.db, arena.allocator(), session_id, parts);
        {
            var tx = try self.db.begin();
            defer tx.deinit();
            try std.testing.expectEqual(@as(u64, 1), try event_store.allocInputId(&self.db, arena.allocator(), session_id));
            try std.testing.expectEqual(@as(u64, 1), try event_store.allocMessageId(&self.db, arena.allocator(), session_id));
            _ = try database.message.appendCommittedMessage(&self.db, arena.allocator(), session_id, [_]u8{8} ** 16, 1, hello);
            try std.testing.expectEqual(@as(u64, 2), try event_store.allocMessageId(&self.db, arena.allocator(), session_id));
            try tx.commit();
        }
        self.engine = self.resources.makeEngine(&self.db);
        errdefer self.engine.close();
        self.session = try self.engine.activate(.bytes(session_id));
        var prepared = try RunSlot.prepare(std.testing.allocator, .{ .model = "mock", .system_prompt = system, .root = "/w" });
        errdefer prepared.deinit();
        self.slot = prepared.bind(
            .{ .input_id = 1, .started = .{ .session_id = .bytes(session_id), .seq = 2, .run_id = 1, .kind = .turn, .config_rev = 0, .started_at_ms = 1 } },
            null,
            .{ .root = .bytes(session_id), .depth = 0 },
        );
        self.slot.progress = .{ .current = .{ .message_id = 2 } };
        self.session.active_run = self.slot;
        try self.session.apply(.{ .message_started_data = .{
            .session_id = .bytes(session_id),
            .message_id = 2,
            .run_id = 1,
            .config_rev = 0,
            .agent = agent_name,
            .created_at_ms = 1,
        } });
    }

    fn deinit(self: *StreamerFixture) void {
        self.engine.close();
        self.db.deinit();
        self.resources.deinit();
    }

    fn persistStarted(self: *StreamerFixture, arena: std.mem.Allocator) !void {
        var tx = try self.db.begin();
        defer tx.deinit();
        const started = self.slot.handle.started;
        _ = try event_store.allocRunId(&self.db, arena, session_id);
        _ = try database.run.appendStarted(&self.db, arena, self.engine.newId(), started.started_at_ms, .{
            .session_id = started.session_id,
            .seq = 0,
            .run_id = started.run_id,
            .kind = started.kind,
            .config_rev = started.config_rev,
            .started_at_ms = started.started_at_ms,
        });
        try tx.commit();
    }

    fn queue(self: *StreamerFixture, arena: std.mem.Allocator, text: []const u8) !ids.InputId {
        var tx = try self.db.begin();
        defer tx.deinit();
        const entry = try database.input.enqueue(&self.db, arena, session_id, self.engine.newId(), 2, .{ .content = &.{.{ .text = .{ .text = text } }} }, 2);
        try tx.commit();
        session_events.emitDurable(&self.engine, self.session, .{ .method = .@"input.queued", .params = .{ .input_queued_data = .{ .session_id = self.session.id, .seq = entry.seq, .input = entry.input } } });
        return entry.input.input_id;
    }

    /// Close the live draft and open the next round, so a test can check the part ids restart.
    fn newRound(self: *StreamerFixture, message_id: ids.MessageId) !void {
        self.session.draft.?.deinit();
        self.session.draft = null;
        try self.session.apply(.{ .message_started_data = .{
            .session_id = .bytes(session_id),
            .message_id = message_id,
            .run_id = 1,
            .config_rev = 0,
            .agent = agent_name,
            .created_at_ms = 2,
        } });
        self.slot.progress.current = .{ .message_id = message_id };
    }

    fn streamer(self: *StreamerFixture) Streamer {
        return .{ .engine = &self.engine, .slot = self.slot, .session = self.session };
    }
};

test "a capped tool round reloads with an assistant error and failed outcome" {
    var fixture: StreamerFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try fixture.persistStarted(a);
    fixture.resources.providers.merged.rows = &.{Resources.mockProvider(&.{.{ .id = "model", .upstream_id = "model", .name = "Model", .protocol = .anthropic_messages, .caps = .{ .tools = true } }}, .{})};
    fixture.slot.gpa.free(fixture.slot.config.model);
    fixture.slot.config.model = try fixture.slot.gpa.dupe(u8, "mock/model");
    fixture.slot.config.max_rounds = 1;
    fixture.resources.transport.bytes = Resources.tool_reply;
    fixture.session.draft.?.deinit();
    fixture.session.draft = null;
    fixture.slot.progress = .{};
    fixture.slot.phase = .running;
    run.execute(&fixture.engine, fixture.slot);

    const restored = try fixture.engine.activate(.bytes(StreamerFixture.session_id));
    var saved_message: ?proto.message.Message = null;
    for (restored.transcript.list.items) |item| if (item.message == .assistant) {
        saved_message = item.message;
        break;
    };
    try std.testing.expect(saved_message != null);
    try std.testing.expectEqualStrings("max_rounds", saved_message.?.assistant.@"error".?.type);
    const outcome = (try database.run.latestOutcome(&fixture.db, a, StreamerFixture.session_id)).?;
    try std.testing.expectEqual(proto.enums.RunErrorCode.max_rounds, outcome.failed.code);
}

// A tool part opens at the stop, so a part id follows the emit order and never the block id.
test "interleaved tool blocks number their parts in emit order" {
    var fixture: StreamerFixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var s = fixture.streamer();
    defer s.blocks.deinit(std.testing.allocator);

    try s.onEvent(.{ .block_started = .{ .block = 0, .kind = .tool } });
    try s.onEvent(.{ .block_started = .{ .block = 1, .kind = .tool } });
    try s.onEvent(.{ .block_started = .{ .block = 2, .kind = .tool } });
    // The last item completes first, so completion order decides the part ids.
    try s.onEvent(.{ .block_stopped = .{ .block = 2, .result = .{ .tool = .{ .call_id = "c", .name = "read", .arguments = "{}" } } } });
    try s.onEvent(.{ .block_stopped = .{ .block = 0, .result = .{ .tool = .{ .call_id = "a", .name = "read", .arguments = "{}" } } } });
    try s.onEvent(.{ .block_stopped = .{ .block = 1, .result = .{ .tool = .{ .call_id = "b", .name = "read", .arguments = "{}" } } } });
    try s.onEvent(.{ .done = .{ .stop_reason = .tool_calls, .raw_stop_reason = "tool_calls", .usage = .{ .input = 0, .output = 0, .reasoning = 0, .cache_read = 0, .cache_write = 0 } } });

    const parts = fixture.session.draft.?.parts.items;
    try std.testing.expectEqual(@as(usize, 3), parts.len);
    for (parts, 0..) |p, i| try std.testing.expectEqual(@as(ids.PartId, @intCast(i)), p.id());
    try std.testing.expectEqualStrings("c", parts[0].tool.call_id.?);
    try std.testing.expectEqualStrings("a", parts[1].tool.call_id.?);
    try std.testing.expectEqualStrings("b", parts[2].tool.call_id.?);
}

// A text block opens its part at the start, so a tool block that stops later takes a later id.
test "a text block and a concurrent tool block keep dense part ids" {
    var fixture: StreamerFixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var s = fixture.streamer();
    defer s.blocks.deinit(std.testing.allocator);

    try s.onEvent(.{ .block_started = .{ .block = 0, .kind = .tool } });
    try s.onEvent(.{ .block_started = .{ .block = 1, .kind = .text } });
    try s.onEvent(.{ .text_delta = .{ .block = 1, .text = "hi" } });
    try s.onEvent(.{ .block_stopped = .{ .block = 1, .result = .text } });
    try s.onEvent(.{ .block_stopped = .{ .block = 0, .result = .{ .tool = .{ .call_id = "a", .name = "read", .arguments = "{}" } } } });

    const parts = fixture.session.draft.?.parts.items;
    try std.testing.expectEqual(@as(usize, 2), parts.len);
    // The text part opened first, so it holds id 0 and the tool part follows it.
    try std.testing.expectEqualStrings("hi", parts[0].text.text.items);
    try std.testing.expectEqual(@as(ids.PartId, 0), parts[0].id());
    try std.testing.expectEqualStrings("a", parts[1].tool.call_id.?);
    try std.testing.expectEqual(@as(ids.PartId, 1), parts[1].id());
}

// A reducer drops a tool block that the terminal leaves open, so `done` arrives with a block unstopped.
test "a dropped tool block leaves the earlier parts intact" {
    var fixture: StreamerFixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var s = fixture.streamer();
    defer s.blocks.deinit(std.testing.allocator);

    try s.onEvent(.{ .block_started = .{ .block = 0, .kind = .text } });
    try s.onEvent(.{ .text_delta = .{ .block = 0, .text = "hi" } });
    try s.onEvent(.{ .block_stopped = .{ .block = 0, .result = .text } });
    try s.onEvent(.{ .block_started = .{ .block = 1, .kind = .tool } });
    try s.onEvent(.{ .done = .{ .stop_reason = .stop, .raw_stop_reason = "completed", .usage = .{ .input = 0, .output = 0, .reasoning = 0, .cache_read = 0, .cache_write = 0 } } });

    const parts = fixture.session.draft.?.parts.items;
    try std.testing.expectEqual(@as(usize, 1), parts.len);
    try std.testing.expectEqualStrings("hi", parts[0].text.text.items);
    try std.testing.expectEqual(proto.enums.StopReason.stop, s.stop_reason.?);
}

// A round reuses the streamer, so the part ids must restart from zero for the next message.
test "part ids restart for each round" {
    var fixture: StreamerFixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var s = fixture.streamer();
    defer s.blocks.deinit(std.testing.allocator);

    try s.onEvent(.{ .block_started = .{ .block = 0, .kind = .text } });
    try s.onEvent(.{ .block_stopped = .{ .block = 0, .result = .text } });
    try s.onEvent(.{ .block_started = .{ .block = 1, .kind = .tool } });
    try s.onEvent(.{ .block_stopped = .{ .block = 1, .result = .{ .tool = .{ .call_id = "a", .name = "read", .arguments = "{}" } } } });
    try std.testing.expectEqual(@as(usize, 2), fixture.session.draft.?.parts.items.len);

    try fixture.newRound(3);
    s.reset();
    try s.onEvent(.{ .block_started = .{ .block = 0, .kind = .tool } });
    try s.onEvent(.{ .block_stopped = .{ .block = 0, .result = .{ .tool = .{ .call_id = "b", .name = "read", .arguments = "{}" } } } });

    const parts = fixture.session.draft.?.parts.items;
    try std.testing.expectEqual(@as(usize, 1), parts.len);
    try std.testing.expectEqual(@as(ids.PartId, 0), parts[0].id());
    try std.testing.expectEqualStrings("b", parts[0].tool.call_id.?);
}

test "a build hook can discard the live registry and tools before the request serializes" {
    const hookset = @import("hookset.zig");
    const State = struct {
        source: std.heap.ArenaAllocator,
        tools: []const ai.ir.Tool,
        session_id: ids.SessionId,
        discarded: bool = false,

        fn decls(ctx: *anyopaque, arena: std.mem.Allocator, _: []const []const u8) error{OutOfMemory}![]const ai.ir.Tool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return proto.dupe(arena, self.tools);
        }

        fn holds(_: *anyopaque, point: proto.hook.Point) bool {
            return point == .@"request.build";
        }

        fn ask(ctx: *anyopaque, arena: std.mem.Allocator, point: proto.hook.Point, payload: []const u8) hookset.Decision {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            std.debug.assert(point == .@"request.build");
            std.debug.assert(!self.discarded);
            const value = std.json.parseFromSliceLeaky(std.json.Value, arena, payload, .{}) catch unreachable;
            const context = value.object.get("context").?.object;
            const hex = std.fmt.bytesToHex(self.session_id.raw, .lower);
            std.debug.assert(std.mem.eql(u8, &hex, context.get("session_id").?.string));
            std.debug.assert(context.get("parent_id").? == .null);
            std.debug.assert(context.get("workspace").?.string.len > 0);
            std.debug.assert(std.mem.eql(u8, "root", context.get("agent_name").?.string));
            std.debug.assert(context.get("prompt") == null);
            self.source.deinit();
            self.tools = &.{};
            self.discarded = true;
            return .proceed;
        }
    };
    var f: StreamerFixture = undefined;
    try f.initWithPrompt(.{ .base = "base\n\nwith separators", .child_policy = "child policy", .environment = "<environment>\nworkspace: /w\n</environment>" });
    defer f.deinit();
    var state: State = .{ .source = .init(std.testing.allocator), .tools = &.{}, .session_id = f.slot.sessionId() };
    defer if (!state.discarded) state.source.deinit();
    const source = state.source.allocator();
    const model = try source.create(registry.ModelSpec);
    model.* = try proto.dupe(source, registry.ModelSpec{
        .id = "mock",
        .upstream_id = "model-before",
        .name = "Before",
        .protocol = .openai_chat,
        .caps = .{ .tools = true },
        .cost = .{ .input = 1.5 },
    });
    const row = try source.create(registry.Provider);
    row.* = try proto.dupe(source, Resources.mockProvider(&.{}, .{
        .id = "provider-before",
        .name = "Before",
        .base_url = "https://example.test/v1",
        .protocol = .openai_chat,
        .headers = &.{.{ .name = "X-Source", .value = "before" }},
        .credential = .{ .literal = "secret-before" },
        .authenticated = true,
    }));
    state.tools = try proto.dupe(source, @as([]const ai.ir.Tool, &.{.{
        .name = "tool_before",
        .description = "Before",
        .input_schema = "{\"type\":\"object\",\"properties\":{}}",
    }}));
    f.engine.installTools(.{ .ctx = &state, .getDecls = State.decls });
    f.engine.installHooks(.{ .ctx = &state, .holds = State.holds, .ask = State.ask });
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const held = try round_request.snapshot(arena.allocator(), &f.engine, f.slot, .{ .provider = row, .model = model });
    const projected = try request_context.project(std.testing.allocator, arena.allocator(), &f.db, f.slot.sessionId().raw, held.budget);
    var prepared = try round_request.prepare(arena.allocator(), &f.engine, f.slot, held, projected);
    defer prepared.deinit();
    try std.testing.expect(state.discarded);
    const body = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, prepared.transport_request.body, .{});
    defer body.deinit();
    try std.testing.expectEqualStrings("model-before", body.value.object.get("model").?.string);
    const tool = body.value.object.get("tools").?.array.items[0].object.get("function").?;
    try std.testing.expectEqualStrings("tool_before", tool.object.get("name").?.string);
    try std.testing.expect(std.mem.startsWith(u8, prepared.transport_request.url, "https://example.test/v1/"));
    var auth_seen = false;
    var source_seen = false;
    for (prepared.transport_request.headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "authorization")) {
            try std.testing.expectEqualStrings("Bearer secret-before", header.value);
            auth_seen = true;
        }
        if (std.mem.eql(u8, header.name, "X-Source")) {
            try std.testing.expectEqualStrings("before", header.value);
            source_seen = true;
        }
    }
    try std.testing.expect(auth_seen and source_seen);
}

test "a run cancel interrupts either request hook before it settles" {
    const hookset = @import("hookset.zig");
    const State = struct {
        io: std.Io,
        slot: *RunSlot,
        point: proto.hook.Point,
        entered: std.Io.Event = .unset,
        parked: std.Io.Event = .unset,
        timed_out: bool = false,
        asked: bool = false,

        fn holds(ctx: *anyopaque, point: proto.hook.Point) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return point == self.point;
        }

        fn ask(ctx: *anyopaque, _: std.mem.Allocator, point: proto.hook.Point, _: []const u8) hookset.Decision {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            std.debug.assert(point == self.point);
            std.debug.assert(!self.asked);
            self.asked = true;
            self.entered.set(self.io);
            self.parked.waitTimeout(self.io, .{ .duration = .{ .raw = .fromSeconds(1), .clock = .awake } }) catch |err| switch (err) {
                error.Canceled => return .canceled,
                error.Timeout => self.timed_out = true,
            };
            return .proceed;
        }

        fn cancel(self: *@This()) !void {
            try self.entered.wait(self.io);
            self.slot.cancel.request(self.io);
        }
    };
    for ([_]proto.hook.Point{ .@"request.build", .@"request.send" }) |point| {
        var f: StreamerFixture = undefined;
        try f.init();
        defer f.deinit();
        f.slot.gpa.free(f.slot.config.model);
        f.slot.config.model = try f.slot.gpa.dupe(u8, "mock/model");
        f.slot.phase = .running;
        f.resources.providers.merged.rows = &.{Resources.mockProvider(&.{.{ .id = "model", .upstream_id = "model", .name = "Model", .protocol = .openai_chat }}, .{ .protocol = .openai_chat })};
        var state: State = .{ .io = f.engine.deps.io, .slot = f.slot, .point = point };
        f.engine.installHooks(.{ .ctx = &state, .holds = State.holds, .ask = State.ask });
        var canceller = try state.io.concurrent(State.cancel, .{&state});
        defer canceller.cancel(state.io) catch {};
        var streamer = f.streamer();
        defer streamer.blocks.deinit(std.testing.allocator);
        try std.testing.expect(streamRound(&f.engine, std.testing.allocator, f.slot, &streamer) == .canceled);
        try std.testing.expect(state.asked);
        try std.testing.expect(!state.timed_out);
    }
}

test "a failed attempt keeps the provider status, request id, and detail past its round" {
    const Failing = struct {
        fn open(_: *anyopaque, arena: std.mem.Allocator, _: ai.transport.Request, info: *ai.transport.AttemptInfo) anyerror!ai.transport.ResponseBody {
            info.status = 400;
            info.request_id = try arena.dupe(u8, "req_9");
            info.body = try arena.dupe(u8, "{\"error\":{\"type\":\"invalid_request_error\",\"message\":\"too long\"}}");
            return ai.transport.HttpError.BadStatus;
        }
        const vtable: ai.transport.Transport.VTable = .{ .open = open };
    };
    var f: StreamerFixture = undefined;
    try f.init();
    defer f.deinit();
    f.slot.gpa.free(f.slot.config.model);
    f.slot.config.model = try f.slot.gpa.dupe(u8, "mock/model");
    f.slot.phase = .running;
    f.resources.providers.merged.rows = &.{Resources.mockProvider(&.{.{ .id = "model", .upstream_id = "model", .name = "Model", .protocol = .openai_chat }}, .{ .protocol = .openai_chat })};
    var marker: u8 = 0;
    f.engine.deps.route_transport = .{ .ctx = &marker, .vtable = &Failing.vtable };
    f.slot.progress.current = null; // the round opens its own message and its own draft
    if (f.session.draft) |*held| held.deinit();
    f.session.draft = null;
    var out: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer out.deinit();
    var streamer = f.streamer();
    defer streamer.blocks.deinit(std.testing.allocator);
    const terminal = streamRound(&f.engine, out.allocator(), f.slot, &streamer);
    try std.testing.expect(terminal == .failed);
    try std.testing.expectEqual(proto.enums.RunErrorCode.provider, terminal.failed.code);
    try std.testing.expectEqual(@as(?u16, 400), terminal.failed.status);
    try std.testing.expectEqualStrings("req_9", terminal.failed.request_id.?);
    try std.testing.expectEqualStrings("invalid_request_error: too long", terminal.failed.detail.?);
}

test "an advertised output ceiling equal to context leaves a usable request budget" {
    var f: StreamerFixture = undefined;
    try f.init();
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const row = Resources.mockProvider(&.{}, .{ .protocol = .openai_chat });
    const model: registry.ModelSpec = .{
        .id = "model",
        .upstream_id = "model",
        .name = "Model",
        .protocol = .openai_chat,
        .limits = .{ .context_window = 500_000, .max_output_tokens = 500_000 },
    };
    const held = try round_request.snapshot(arena.allocator(), &f.engine, f.slot, .{ .provider = &row, .model = &model });
    try std.testing.expectEqual(@as(u32, 8192), held.build.max_output_tokens);
    try std.testing.expect(held.budget.input_ceiling > 0);
}

test "the final build hook obeys prompt and context limits without a new floor" {
    const hookset = @import("hookset.zig");
    const State = struct {
        size: usize = proto.meta.limits.max_message_string_bytes + 1,
        output: u32 = 8192,
        fn holds(_: *anyopaque, point: proto.hook.Point) bool {
            return point == .@"request.build";
        }

        fn ask(ctx: *anyopaque, arena: std.mem.Allocator, point: proto.hook.Point, payload: []const u8) hookset.Decision {
            std.debug.assert(point == .@"request.build");
            var value = std.json.parseFromSliceLeaky(std.json.Value, arena, payload, .{}) catch unreachable;
            const self: *@This() = @ptrCast(@alignCast(ctx));
            const text = arena.alloc(u8, self.size) catch unreachable;
            @memset(text, 'x');
            value.object.put(arena, "system", .{ .string = text }) catch unreachable;
            value.object.put(arena, "max_output_tokens", .{ .integer = self.output }) catch unreachable;
            return .{ .replace = value };
        }
    };
    var f: StreamerFixture = undefined;
    try f.init();
    defer f.deinit();
    var state: State = .{};
    f.engine.installHooks(.{ .ctx = &state, .holds = State.holds, .ask = State.ask });
    const row = Resources.mockProvider(&.{}, .{ .protocol = .openai_chat });
    const model: registry.ModelSpec = .{ .id = "model", .upstream_id = "model", .name = "Model", .protocol = .openai_chat };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.PromptTooLarge, round_request.snapshot(arena.allocator(), &f.engine, f.slot, .{ .provider = &row, .model = &model }));
    state.size = 400_000;
    try std.testing.expectError(error.ContextTooLarge, round_request.snapshot(arena.allocator(), &f.engine, f.slot, .{ .provider = &row, .model = &model }));
    state.size = 0;
    state.output = 128_000;
    try std.testing.expectError(error.ContextTooLarge, round_request.snapshot(arena.allocator(), &f.engine, f.slot, .{ .provider = &row, .model = &model }));
}

test "a failed boundary transaction preserves the draft progress and pending input" {
    var f: StreamerFixture = undefined;
    try f.init();
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try f.persistStarted(a);
    f.slot.phase = .running;
    const input_id = try f.queue(a, "next input");
    try f.db.conn.execNoArgs("CREATE TEMP TRIGGER refuse_consume BEFORE DELETE ON pending_inputs BEGIN SELECT RAISE(FAIL, 'test refusal'); END");
    try std.testing.expectError(error.ConstraintTrigger, commitRound(&f.engine, a, f.slot, &f.session.draft.?, false, null, .{ .success = .stop }));
    try std.testing.expectEqual(@as(usize, 1), (try database.message.historyPage(&f.db, a, StreamerFixture.session_id, 0, 10)).messages.len);
    try std.testing.expectEqual(@as(u64, 0), f.slot.progress.rounds_committed);
    try std.testing.expectEqual(@as(u64, 2), f.slot.progress.current.?.message_id);
    try std.testing.expectEqual(@as(usize, 1), f.session.queueDepth());
    try std.testing.expectEqual(@as(u64, 1), try database.input.count(&f.db, a, StreamerFixture.session_id));
    try f.db.conn.execNoArgs("DROP TRIGGER refuse_consume");
    try commitRound(&f.engine, a, f.slot, &f.session.draft.?, false, null, .{ .success = .stop });
    try std.testing.expectEqual(@as(u64, 1), f.slot.progress.rounds_committed);
    try std.testing.expect(f.slot.progress.current == null and f.session.draft == null);
    try std.testing.expectEqual(@as(usize, 0), f.session.queueDepth());
    const messages = (try database.message.historyPage(&f.db, a, StreamerFixture.session_id, 0, 10)).messages;
    try std.testing.expectEqual(@as(usize, 3), messages.len);
    try std.testing.expectEqual(@as(u64, 2), messages[1].assistant.id);
    try std.testing.expectEqual(@as(u64, 3), messages[2].user.id);
    try std.testing.expectEqual(input_id, messages[2].user.input_id);
    try run.finishRunOpen(&f.engine, a, f.slot, .{ .canceled = .{} });
}

test "a cancel at the boundary wins over a successful response and preserves pending input" {
    var f: StreamerFixture = undefined;
    try f.init();
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try f.persistStarted(a);
    f.slot.phase = .running;
    _ = try f.queue(a, "pending");
    f.slot.cancel.request(f.engine.deps.io);
    try commitRound(&f.engine, a, f.slot, &f.session.draft.?, false, null, .{ .success = .stop });
    try std.testing.expectEqual(RunSlot.Phase.terminalized, f.slot.phase);
    try std.testing.expectEqual(@as(usize, 1), f.session.queueDepth());
    try std.testing.expectEqual(@as(u64, 1), try database.input.count(&f.db, a, StreamerFixture.session_id));
    try std.testing.expect((try database.run.latestOutcome(&f.db, a, StreamerFixture.session_id)).? == .canceled);
}
