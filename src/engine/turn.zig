//! Own the run tasks. Each round commits one assistant message. The final round also commits run.done.

const std = @import("std");
const proto = @import("proto");
const Engine = @import("Engine.zig");
const session_events = @import("events.zig");
const run = @import("run.zig");
const provider = @import("../provider/provider.zig");
const draft = @import("../session/draft.zig");
const Session = @import("../session/session.zig").Session;
const database = @import("../store/store.zig");
const turn_context = @import("context.zig");
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

/// The response gate must launch a prepared run exactly once through an optional token.
pub const Launch = union(enum) {
    slot: *RunSlot,
    wake: ids.SessionId,

    /// Launch the prepared slot. Return when another path consumed the token.
    pub fn release(self: *?Launch, engine: *Engine) void {
        const launch = self.* orelse return;
        self.* = null;
        switch (launch) {
            .slot => |slot| launchSlot(engine, slot) catch |err| {
                std.log.err("cannot release the run launch gate: {t}", .{err});
            },
            .wake => |parent| @import("admission.zig").drain(engine, parent) catch |err| {
                std.log.err("cannot admit a queued child: {t}", .{err});
            },
        }
    }
};

/// Launch one prepared run.
pub fn launchSlot(engine: *Engine, slot: *RunSlot) !void {
    std.debug.assert(slot.phase == .pending_start);
    std.debug.assert(slot.progress.current != null); // bind must open round 1 before launch
    slot.retry_budget = engine.deps.retry_budget; // The budget covers this run, not one request.
    // The caller already folded and published run.started. This spawns the run task.
    const run_id = slot.runId();
    const session_id = slot.sessionId();
    slot.phase = .running;
    engine.turn_tasks.concurrent(engine.deps.io, runSession, .{ engine, slot }) catch |err| {
        std.log.err("cannot launch run {d}: {t}", .{ run_id, err });
        // The run task never ran, so set the round timestamp here before the commit.
        slot.progress.current.?.created_at_ms = @max(engine.nowMillis(), slot.handle.started.started_at_ms);
        var terminal_arena = std.heap.ArenaAllocator.init(engine.deps.gpa);
        defer terminal_arena.deinit();
        commitFinal(engine, terminal_arena.allocator(), slot, null, null, .{ .failed = .{
            .code = .internal,
            .message = "the engine could not launch the run task",
        } });
        finishSlot(engine, session_id, slot);
        return err;
    };
}

/// Run one turn. The engine task group owns this task. The session owns `slot` until cleanup.
fn runSession(engine: *Engine, slot: *RunSlot) void {
    const session_id = slot.sessionId();
    defer finishSlot(engine, session_id, slot);

    const rt = engine.sessions.get(session_id) orelse unreachable;
    std.debug.assert(rt.active_run == slot);

    // Only a value that outlives one round belongs here, such as the workspace root and commit data.
    // A round builds its request on its own arena, because that memory would otherwise grow all run.
    var arena_state = std.heap.ArenaAllocator.init(engine.deps.gpa);
    defer arena_state.deinit();
    const run_arena = arena_state.allocator();

    // Clear a live draft on an early return. A commit fold nulls it first on the normal path.
    defer if (rt.draft != null) {
        rt.draft.?.deinit();
        rt.draft = null;
    };

    var streamer: Streamer = .{ .engine = engine, .slot = slot, .session = rt };
    defer streamer.blocks.deinit(engine.deps.gpa);

    // The workspace cannot change during a run, so resolve its root once and only when a tool runs.
    var workspace_root: ?[]const u8 = null;
    var root_resolved = false;

    while (true) {
        // Open this round. A commit reads the streamer, so clear it before any path can fail.
        streamer.reset();
        const created_at = engine.nowMillis();
        std.debug.assert(slot.progress.current != null); // bind or beginRound opened the round
        slot.progress.current.?.created_at_ms = created_at;
        std.debug.assert(rt.draft == null); // one draft per round
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
            commitFinal(engine, run_arena, slot, null, streamer.usage, .{ .failed = failure(err) });
            return;
        };
        const live = &rt.draft.?;
        engine.sinks.emit(started_note);
        session_events.announceActivity(engine, rt); // `run.started` says a run exists, not what it does.

        const terminal = streamRound(engine, slot, &streamer);

        // Settle any tool parts into a terminal state. The request builder rejects a pending tool.
        const has_tools = hasToolPart(live);
        if (has_tools) {
            if (terminal == .success and terminal.success == .tool_calls) {
                // Resolve the session root once, then pass it to each asynchronous tool call.
                if (!root_resolved) {
                    workspace_root = workspaceRoot(engine, run_arena, session_id.raw) catch null;
                    root_resolved = true;
                }
                settlePendingTools(engine, run_arena, slot, &streamer, workspace_root, live) catch |err| {
                    faultSlot(engine, session_id, slot, err);
                    return;
                };
                if (workspace_root == null) {
                    commitFinal(engine, run_arena, slot, live, streamer.usage, .{ .failed = .{ .code = .internal, .message = "cannot resolve the workspace" } });
                    return;
                }
            } else {
                // Cancel any pending tool part; a canceled/failed stream or a malformed tool_use lands here.
                settlePendingTools(engine, run_arena, slot, &streamer, null, live) catch |err| {
                    faultSlot(engine, session_id, slot, err);
                    return;
                };
                if (terminal == .success) {
                    commitFinal(engine, run_arena, slot, live, streamer.usage, .{ .failed = .{ .code = .protocol, .message = "a tool part without a tool_calls stop reason" } });
                    return;
                }
            }
        }

        // A cancel forces the canceled terminal. A failed stream or a plain answer also ends the turn.
        const commit_terminal: Terminal = if (slot.cancel_requested) .canceled else terminal;
        if (commit_terminal != .success or !has_tools) {
            commitFinal(engine, run_arena, slot, live, streamer.usage, commit_terminal);
            return;
        }

        // A capped tool round is terminal, so save its failure on the assistant message transaction.
        const capped = if (slot.config.max_rounds) |cap| slot.progress.rounds_committed >= cap -| 1 else false;
        const completion: RoundCompletion = if (capped) .final else .intermediate;
        const round_terminal: Terminal = if (capped) .{ .failed = .{ .code = .max_rounds, .message = "the run reached its max_rounds limit" } } else terminal;
        // The commit fold extends the transcript and, for the capped round, closes the run.
        _ = commitRound(engine, run_arena, slot, live, streamer.usage, round_terminal, completion) catch |err| {
            faultSlot(engine, session_id, slot, err);
            return;
        };
        if (capped) return;
        // A cancel at the round boundary ends the run without a new empty round.
        if (slot.cancel_requested) {
            finishRunOpen(engine, run_arena, slot, .{ .canceled = .{} }) catch |err| faultSlot(engine, session_id, slot, err);
            return;
        }
        beginRound(engine, slot) catch |err| {
            faultSlot(engine, session_id, slot, err);
            return;
        };
    }
}

/// Commit the final round and fault the slot on a commit error.
fn commitFinal(engine: *Engine, arena: std.mem.Allocator, slot: *RunSlot, live: ?*const draft.Draft, usage: ?message.TokenUsage, terminal: Terminal) void {
    _ = commitRound(engine, arena, slot, live, usage, terminal, .final) catch |err| {
        faultSlot(engine, slot.sessionId(), slot, err);
        return;
    };
}

/// Stream one round, and resend the same request while the classifier allows it.
fn streamRound(engine: *Engine, slot: *RunSlot, streamer: *Streamer) Terminal {
    // The request and its attempts die with this round, so a long run never accumulates them.
    var round_state: std.heap.ArenaAllocator = .init(engine.deps.gpa);
    defer round_state.deinit();
    const arena = round_state.allocator();

    // A request hook can await indefinitely, so the build runs as a child a run cancel can reach.
    var request: ?ai.PreparedRequest = null;
    defer if (request) |*prepared| prepared.deinit();
    const built = switch (runChild(engine, slot, requestChild, .{ engine, arena, slot, streamer, &request })) {
        .canceled, .aborted => return .canceled,
        .returned => |result| result,
    };
    built catch |err| {
        if (err == error.Canceled) return .canceled;
        std.log.warn("run {d} could not build its request: {t}", .{ slot.runId(), err });
        return .{ .failed = failure(err) };
    };
    std.debug.assert(request != null);

    var number: u8 = 1;
    while (true) : (number += 1) {
        streamer.reset();
        var info: ai.transport.AttemptInfo = .{};
        const terminal = streamAttempt(engine, arena, slot, streamer, &request.?, &info) catch |err| {
            const decision = retry.decide(engine.deps.retry_policy, .{
                .err = err,
                .info = info,
                // A published event outranks every other gate. The client already folded that output.
                .saw_semantic = streamer.saw_semantic,
                .number = number,
                .budget_left = slot.retry_budget,
            }, engine.jitter());
            const delay_ms = switch (decision) {
                .stop => {
                    // The wire message names a class, not the cause. Record the cause before it is lost.
                    std.log.warn("run {d} attempt {d} ended: {t}", .{ slot.runId(), number, err });
                    return .{ .failed = failure(err) };
                },
                .retry_in_ms => |ms| ms,
            };

            std.debug.assert(slot.retry_budget > 0); // the classifier refuses a retry at zero
            slot.retry_budget -= 1;
            publishRetrying(engine, slot, number, err, delay_ms);
            defer slot.retry_state = null;
            // Wait on the slot event, NOT on a plain sleep. `cancel_run` sets this event, and a plain
            // sleep would hold the run for the whole delay because the flag alone never wakes it.
            slot.wake_event.reset();
            const waited: std.Io.Clock.Duration = .{ .raw = .fromMilliseconds(@intCast(delay_ms)), .clock = .awake };
            if (slot.wake_event.waitTimeout(engine.deps.io, .{ .duration = waited })) |_| {
                return .canceled; // The event fired, so a cancel arrived during the delay.
            } else |wait_err| switch (wait_err) {
                error.Timeout => {}, // The delay elapsed. Open the next attempt.
                error.Canceled => return .canceled,
            }
            if (slot.cancel_requested) return .canceled;
            continue;
        };
        return terminal;
    }
}

/// Record the wait on the slot, then publish it, so the wait shows as a retry and not a silent pause.
fn publishRetrying(engine: *Engine, slot: *RunSlot, number: u8, err: anyerror, delay_ms: u64) void {
    // @todo(xyaman): log one line per attempt. Record the attempt number, provider, model, status, the
    // normalized code, the provider request id, the delivery engine, the delay source, and the budget
    // left. Never log the API key. A user report of odd retry behavior has nothing to read today.
    const detail = failure(err);
    slot.retry_state = .{
        .run_id = slot.runId(),
        .attempt = number,
        .max_attempts = engine.deps.retry_policy.max_attempts,
        .next_at_ms = engine.nowMillis() + delay_ms,
        .code = detail.code,
        .message = detail.message,
    };
    // Announce the whole activity, so the context gauge, the config and the queue stay true.
    // `residentActivity` reads the retry engine that this function just set.
    const rt = engine.sessions.get(slot.sessionId()) orelse return;
    session_events.announceActivity(engine, rt);
}

/// What a cancelable child produced. A run cancel keeps the run alive. A canceled run task unwinds.
const ChildResult = union(enum) {
    /// The child returned. The payload holds its result.
    returned: anyerror!void,
    /// `cancel_run` reached the slot. The child stopped.
    canceled,
    /// A cancel stopped the run task, so the caller must unwind.
    aborted,
};

/// Run `f` in a child task, so a cancel can interrupt a blocked call.
fn runChild(engine: *Engine, slot: *RunSlot, comptime f: anytype, args: anytype) ChildResult {
    slot.wake_event.reset(); // A one-shot event. The next child waits again.
    var child = engine.deps.io.concurrent(f, args) catch |err| return .{ .returned = err };
    slot.wake_event.wait(engine.deps.io) catch {
        child.cancel(engine.deps.io) catch {}; // Shutdown canceled this run task. Stop the child.
        return .aborted;
    };
    if (slot.cancel_requested) {
        child.cancel(engine.deps.io) catch {}; // Interrupt a blocked call, then join the child.
        return .canceled;
    }
    return .{ .returned = child.await(engine.deps.io) };
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
    const result = switch (runChild(engine, slot, streamChild, .{ engine, arena, slot, streamer, request, info })) {
        .canceled, .aborted => return .canceled,
        .returned => |r| r,
    };
    if (result) |_| {
        if (slot.cancel_requested) return .canceled;
        const reason = streamer.stop_reason orelse
            return .{ .failed = .{ .code = .protocol, .message = "the provider stream has no stop reason" } };
        return .{ .success = reason };
    } else |err| {
        if (err == error.Canceled or slot.cancel_requested) return .canceled;
        return err;
    }
}

fn requestChild(engine: *Engine, arena: std.mem.Allocator, slot: *RunSlot, streamer: *Streamer, out: *?ai.PreparedRequest) !void {
    std.debug.assert(out.* == null);
    defer slot.wake_event.set(engine.deps.io);
    try checkCanceled(engine.deps.io, slot);
    out.* = try roundRequest(engine, arena, slot, streamer);
}

/// Build the request for one round. A retry re-sends these bytes, so the cached prefix still matches.
fn roundRequest(engine: *Engine, arena: std.mem.Allocator, slot: *RunSlot, streamer: *Streamer) !ai.PreparedRequest {
    const model = slot.config.model;

    // The catalog must resolve the model. An unresolved selector is an operating error, not a bug.
    const resolved = engine.deps.providers.merged.resolveModel(model) orelse return error.UnknownModel;

    // Project the resident transcript for this round. The model window sets the history budget.
    const budget = turn_context.Budget.forModel(resolved.model.limits.context_window, resolved.model.limits.max_output_tokens);
    const ctx = try turn_context.project(arena, &streamer.session.transcript, budget);
    return round_request.prepare(arena, engine, slot, ctx.messages, resolved);
}

/// Open the response and stream it into the draft, in a child so a cancel can interrupt a blocked read.
fn streamChild(engine: *Engine, arena: std.mem.Allocator, slot: *RunSlot, streamer: *Streamer, request: *const ai.PreparedRequest, info: *ai.transport.AttemptInfo) !void {
    defer slot.wake_event.set(engine.deps.io);
    try checkCanceled(engine.deps.io, slot);
    const body = try engine.deps.route_transport.open(arena, request.transport_request, info);
    std.debug.assert(slot.body == null); // one body per run
    slot.body = body;
    defer {
        slot.body = null;
        body.deinit();
    }
    try checkCanceled(engine.deps.io, slot);
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
};

/// Map a run failure to its wire code and sentence. `provider.failure` holds the one error table.
fn failure(err: anyerror) Failure {
    const detail = provider.failure.classify(err);
    return .{ .code = detail.code, .message = detail.message };
}

/// A round is intermediate (a tool round; the run continues) or final (the run ends).
const RoundCompletion = enum { intermediate, final };

/// Commit the current round, and terminalize the run only when this is the final round.
fn commitRound(
    engine: *Engine,
    arena: std.mem.Allocator,
    slot: *RunSlot,
    live: ?*const draft.Draft,
    usage: ?message.TokenUsage,
    terminal: Terminal,
    completion: RoundCompletion,
) !message.Message {
    std.debug.assert(slot.phase == .running);
    std.debug.assert(slot.body == null);
    std.debug.assert(slot.progress.current != null); // bind opened the round before launch
    const old_cancel_protection = engine.deps.io.swapCancelProtection(.blocked);
    defer _ = engine.deps.io.swapCancelProtection(old_cancel_protection);

    const round = &slot.progress.current.?;
    const content = if (live) |value| (try value.toActiveDraft(arena)).message.content else &.{};
    const ended_at = @max(engine.nowMillis(), slot.handle.started.started_at_ms);
    const finish: proto.enums.StopReason = switch (terminal) {
        .success => |reason| reason,
        .canceled => .canceled,
        .failed => .@"error",
    };
    const message_error: ?message.MessageError = switch (terminal) {
        .failed => |item| .{ .type = @tagName(item.code), .message = item.message },
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
    slot.progress.rounds_committed += 1;
    const outcome: proto.run.RunOutcome = switch (terminal) {
        .success => |reason| .{ .turn = .{ .finish = reason, .rounds = slot.progress.rounds_committed } },
        .canceled => .{ .canceled = .{} },
        .failed => |item| .{ .failed = .{ .code = item.code, .message = item.message } },
    };
    // The committed content borrows the draft. The commit fold frees the draft, so own a copy first.
    // Copy before the transaction, so an allocation failure consumes no durable sequence.
    const owned = try proto.dupe(arena, committed);
    const session_id = slot.sessionId();

    var tx = try engine.deps.db.*.begin();
    defer tx.deinit();
    const seq = try message_store.appendCommittedMessage(engine.deps.db, arena, session_id.raw, engine.newId(), ended_at, owned);
    const done: ?reports.Terminal = if (completion == .final) try reports.append(engine, arena, .{
        .session_id = session_id,
        .seq = 0,
        .run_id = slot.runId(),
        .kind = slot.handle.started.kind,
        .timing = .{ .started_at_ms = slot.handle.started.started_at_ms, .ended_at_ms = ended_at },
        .outcome = outcome,
    }) else null;
    try tx.commit();
    if (completion == .final) slot.phase = .terminalized;

    const rt = engine.sessions.get(session_id) orelse unreachable;
    session_events.emitDurable(engine, rt, .{ .method = .@"message.committed", .params = .{
        .message_committed_data = .{ .session_id = session_id, .seq = seq, .message = owned },
    } });
    session_events.announceSummary(engine, session_id); // The commit moved the count, the lifetime usage, and the order.
    if (done) |terminal_result| {
        session_events.emitDurable(engine, rt, .{ .method = .@"run.done", .params = .{ .run_done_data = terminal_result.done } });
        if (terminal_result.notice) |notice| session_events.emitDurable(engine, rt, .{ .method = .@"message.committed", .params = .{ .message_committed_data = notice } });
        if (terminal_result.report) |report| reports.publishReport(engine, report, true);
    }
    return owned;
}

/// Close an open run at a round boundary with `outcome`. The last round is already committed.
fn finishRunOpen(engine: *Engine, arena: std.mem.Allocator, slot: *RunSlot, outcome: proto.run.RunOutcome) !void {
    std.debug.assert(slot.phase == .running);
    const old_cancel_protection = engine.deps.io.swapCancelProtection(.blocked);
    defer _ = engine.deps.io.swapCancelProtection(old_cancel_protection);

    const session_id = slot.sessionId();
    const ended_at = @max(engine.nowMillis(), slot.handle.started.started_at_ms);
    var tx = try engine.deps.db.*.begin();
    defer tx.deinit();
    const done = try reports.append(engine, arena, .{
        .session_id = session_id,
        .seq = 0,
        .run_id = slot.runId(),
        .kind = slot.handle.started.kind,
        .timing = .{ .started_at_ms = slot.handle.started.started_at_ms, .ended_at_ms = ended_at },
        .outcome = outcome,
    });
    try tx.commit();
    slot.phase = .terminalized;

    const rt = engine.sessions.get(session_id) orelse unreachable;
    session_events.emitDurable(engine, rt, .{ .method = .@"run.done", .params = .{ .run_done_data = done.done } });
    if (done.notice) |notice| session_events.emitDurable(engine, rt, .{ .method = .@"message.committed", .params = .{ .message_committed_data = notice } });
    if (done.report) |report| reports.publishReport(engine, report, true);
}

/// Allocate the next round: allocate a message id, then advance the progress state.
fn beginRound(engine: *Engine, slot: *RunSlot) !void {
    var arena_state = std.heap.ArenaAllocator.init(engine.deps.gpa);
    defer arena_state.deinit();
    var tx = try engine.deps.db.*.begin();
    defer tx.deinit();
    const message_id = try event_store.allocMessageId(engine.deps.db, arena_state.allocator(), slot.sessionId().raw);
    try tx.commit();
    slot.progress.rounds_started += 1;
    slot.progress.current = .{ .number = slot.progress.rounds_started, .message_id = message_id };
}

/// Preserve the open marker when Tx2 fails. A matching terminal event must clear it.
fn faultSlot(engine: *Engine, session_id: ids.SessionId, slot: *RunSlot, err: anyerror) void {
    slot.phase = .faulted;
    if (engine.sessions.get(session_id)) |rt| rt.faulted = true;
    reports.faultNotice(engine, session_id, slot.runId(), err);
}

fn finishSlot(engine: *Engine, session_id: ids.SessionId, slot: *RunSlot) void {
    slot.work.drain(engine.deps.io);
    std.debug.assert(slot.body == null);
    std.debug.assert(slot.phase == .terminalized or slot.phase == .faulted);
    const rt = engine.sessions.get(session_id) orelse unreachable;
    std.debug.assert(rt.active_run == slot);
    const can_drain = slot.phase == .terminalized and !engine.closing and !rt.faulted;
    const parent = slot.parent_id;
    rt.active_run = null;
    slot.destroy();

    if (parent != null and !engine.closing) {
        @import("admission.zig").drain(engine, parent.?) catch |err| {
            std.log.err("cannot admit a queued child: {t}", .{err});
        };
    } else if (can_drain and rt.queueDepth() > 0) {
        startQueued(engine, rt) catch |err| {
            if (engine.sessions.get(session_id)) |current| current.faulted = true;
            std.log.err("cannot start a queued run: {t}", .{err});
        };
    }
    // A nested finishSlot can evict the session, so look the runtime up again before it is read.
    if (engine.sessions.get(session_id)) |settled| session_events.announceActivity(engine, settled);
    engine.sessions.evictIfIdle(session_id);
}

fn startQueued(engine: *Engine, rt: *Session) !void {
    const slot = try prepareQueued(engine, rt);
    try launchSlot(engine, slot);
}

/// Commit one run for all queued inputs.
pub fn prepareQueued(engine: *Engine, rt: *Session) !*RunSlot {
    try engine.own(rt.id);
    std.debug.assert(rt.active_run == null);
    std.debug.assert(rt.queueDepth() > 0);

    // Only a value that outlives one round belongs here, such as the workspace root and commit data.
    // A round builds its request on its own arena, because that memory would otherwise grow all run.
    var arena_state = std.heap.ArenaAllocator.init(engine.deps.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const session_id = rt.id;
    const snapshot = (try session_store.snapshot(engine.deps.db, arena, session_id.raw)) orelse return error.UnknownSession;
    const tree = try @import("admission.zig").location(engine, arena, session_id);
    const prompt = try session_store.prompt(engine.deps.db, arena, session_id.raw);
    var prepared = try RunSlot.prepare(engine.deps.gpa, snapshot.model, snapshot.reasoning, prompt orelse "", snapshot.max_rounds);
    errdefer prepared.deinit();
    const started = try run.beginQueuedTurn(engine.deps.db, engine.deps.io, arena, session_id.raw, snapshot.config_rev);
    const slot = prepared.bind(started.handle, started.first_round, if (snapshot.parent_id) |id| .bytes(id) else null, tree);
    // Fold each durable event in sequence order: the drained user messages, then run.started.
    // The commit fold retires each drained input from the queue.
    session_events.publishUserCommits(engine, rt, started.user_commits);
    std.debug.assert(rt.queueDepth() == 0);
    rt.active_run = slot;
    session_events.emitDurable(engine, rt, .{ .method = .@"run.started", .params = .{ .run_started_data = started.handle.started } });
    return slot;
}

/// Restart durable queued work after frontend setup.
pub fn resumeSession(engine: *Engine, rt: *Session) !void {
    if (engine.closing) return error.EngineClosing;
    if (rt.active_run != null) return;
    if (rt.queueDepth() == 0) return;
    var scratch: std.heap.ArenaAllocator = .init(engine.deps.gpa);
    defer scratch.deinit();
    const row = (try session_store.snapshot(engine.deps.db, scratch.allocator(), rt.id.raw)) orelse return error.UnknownSession;
    if (row.parent_id) |parent| return @import("admission.zig").drain(engine, .bytes(parent));
    try startQueued(engine, rt);
}

fn checkCanceled(io: std.Io, slot: *const RunSlot) !void {
    try io.checkCancel();
    if (slot.cancel_requested) return error.Canceled;
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
        try checkCanceled(self.engine.deps.io, self.slot);
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

    /// Open a pending tool part when its block stops. The provider is a peer, so cap the metadata sizes.
    /// The part stays pending until the run settles it into a terminal state.
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
fn workspaceRoot(engine: *Engine, arena: std.mem.Allocator, session_id: [16]u8) ![]const u8 {
    const snap = (try session_store.snapshot(engine.deps.db, arena, session_id)) orelse return error.UnknownSession;
    return snap.root;
}

/// True when the draft holds any tool part.
fn hasToolPart(live: *const draft.Draft) bool {
    for (live.parts.items) |*p| if (p.* == .tool) return true;
    return false;
}

/// One pending tool call. A snapshot frees the tool call from the draft parts array.
const PendingTool = struct { part_id: proto.ids.PartId, name: []const u8, arguments: []const u8 };

/// Settle pending tools in part order, which is the order the blocks stopped, not the item order.
fn settlePendingTools(engine: *Engine, arena: std.mem.Allocator, slot: *RunSlot, streamer: *Streamer, workspace_root: ?[]const u8, live: *const draft.Draft) !void {
    var pending: std.ArrayList(PendingTool) = .empty;
    for (live.parts.items) |*p| {
        if (p.* != .tool or std.meta.activeTag(p.tool.state) != .pending) continue;
        try pending.append(arena, .{ .part_id = p.tool.id, .name = p.tool.name, .arguments = p.tool.arguments });
    }
    for (pending.items) |pt| {
        if (workspace_root == null or slot.cancel_requested) {
            try streamer.emitToolState(pt.part_id, .{ .canceled = .{} });
            continue;
        }
        try runOneTool(engine, slot, streamer, workspace_root.?, pt);
    }
}

/// Run one tool in a child task, so a cancel can interrupt a blocked call.
fn runOneTool(engine: *Engine, slot: *RunSlot, streamer: *Streamer, workspace_root: []const u8, pt: PendingTool) !void {
    return switch (runChild(engine, slot, toolChild, .{ engine, slot, streamer, workspace_root, pt })) {
        .canceled => {}, // The child settled its part canceled. The next part still settles.
        .aborted => error.Canceled,
        .returned => |result| result,
    };
}

/// Run one tool and emit exactly one terminal state despite cancellation.
fn toolChild(engine: *Engine, slot: *RunSlot, streamer: *Streamer, workspace_root: []const u8, pt: PendingTool) !void {
    std.debug.assert(slot.phase == .running); // the run loop owns the slot for this round
    std.debug.assert(slot.progress.current != null); // the round opened the message
    defer slot.wake_event.set(engine.deps.io);
    const started = engine.nowMillis();
    {
        const old = engine.deps.io.swapCancelProtection(.blocked);
        defer _ = engine.deps.io.swapCancelProtection(old);
        try streamer.emitToolState(pt.part_id, .{ .running = .{ .started_at_ms = started } });
    }
    // The session folds the state before this arena releases the tool result.
    var scratch_state: std.heap.ArenaAllocator = .init(engine.deps.gpa);
    defer scratch_state.deinit();
    const res = runHooked(engine, scratch_state.allocator(), slot, pt, workspace_root) catch {
        const cancel_old = engine.deps.io.swapCancelProtection(.blocked);
        defer _ = engine.deps.io.swapCancelProtection(cancel_old);
        try streamer.emitToolState(pt.part_id, .{ .canceled = .{ .duration_ms = engine.nowMillis() -| started } });
        return;
    };
    const duration = engine.nowMillis() -| started; // Saturate; the wall clock can move backward.
    const old = engine.deps.io.swapCancelProtection(.blocked);
    defer _ = engine.deps.io.swapCancelProtection(old);
    const settled: proto.tool.ToolState = if (slot.cancel_requested)
        .{ .canceled = .{ .duration_ms = duration } }
    else if (res.cancellation_reason) |reason|
        .{ .canceled = .{ .duration_ms = duration, .reason = reason } }
    else if (res.is_error)
        .{ .@"error" = .{ .@"error" = res.output, .view = res.view, .duration_ms = duration } }
    else
        .{ .completed = .{ .output = res.output, .view = res.view, .duration_ms = duration } };
    try streamer.emitToolState(pt.part_id, settled);
}

/// One tool call the model asked for. A `tool.before` handler may replace either field.
const ToolCall = struct {
    name: []const u8,
    arguments: []const u8,
};

/// A replacement owns both the output and the view so they cannot disagree.
const ToolResult = struct {
    output: []const u8,
    is_error: bool,
    view: ?[]const proto.view.View = null,
};

test "tool rewrites obey the current depth limit before dispatch" {
    const State = struct {
        calls: usize = 0,

        fn allowed(_: *anyopaque, name: []const u8, selection: toolset.Selection) bool {
            return !std.mem.eql(u8, name, "delegate") or selection.can_spawn;
        }

        fn execute(raw: *anyopaque, _: std.mem.Allocator, name: []const u8, _: []const u8, _: toolset.Context) toolset.Outcome {
            const self: *@This() = @ptrCast(@alignCast(raw));
            std.debug.assert(std.mem.eql(u8, name, "delegate"));
            self.calls += 1;
            return .{ .output = "done", .is_error = false };
        }

        fn holds(_: *anyopaque, point: proto.hook.Point) bool {
            return point == .@"tool.before";
        }

        fn ask(_: *anyopaque, arena: std.mem.Allocator, point: proto.hook.Point, _: []const u8) @import("hookset.zig").Decision {
            std.debug.assert(point == .@"tool.before");
            const value = std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"name\":\"delegate\",\"arguments\":\"{}\"}", .{}) catch unreachable;
            return .{ .replace = value };
        }
    };
    var f: StreamerFixture = undefined;
    try f.init();
    defer f.deinit();
    var state: State = .{};
    f.engine.installTools(.{ .ctx = &state, .isAllowed = State.allowed, .run = State.execute });
    f.engine.installHooks(.{ .ctx = &state, .holds = State.holds, .ask = State.ask });
    f.slot.depth = 1;
    var scratch: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer scratch.deinit();
    const pending: PendingTool = .{ .part_id = 0, .name = "read", .arguments = "{}" };
    const refused = try runHooked(&f.engine, scratch.allocator(), f.slot, pending, "/w");
    try std.testing.expect(refused.is_error);
    try std.testing.expectEqual(@as(usize, 0), state.calls);
    try f.engine.setAgentLimits(8, 2);
    const accepted = try runHooked(&f.engine, scratch.allocator(), f.slot, pending, "/w");
    try std.testing.expect(!accepted.is_error);
    try std.testing.expectEqual(@as(usize, 1), state.calls);
}

/// Run one tool through its hooks. A block answers the model, and the process runs nothing.
fn runHooked(engine: *Engine, arena: std.mem.Allocator, slot: *RunSlot, pt: PendingTool, workspace_root: []const u8) !toolset.Outcome {
    const hooks = engine.deps.hooks;
    var call: ToolCall = .{ .name = pt.name, .arguments = pt.arguments };
    switch (hooks.askIfHeld(arena, .@"tool.before", call)) {
        .proceed => {},
        // A handler that answers an unreadable call keeps the one the model chose.
        .replace => |value| call = std.json.parseFromValueLeaky(ToolCall, arena, value, .{ .ignore_unknown_fields = true }) catch call,
        .block => |reason| return .{ .output = reason, .is_error = true },
        .canceled => return error.Canceled,
    }

    const tools = engine.deps.tools;
    if (!tools.isAllowed(tools.ctx, call.name, .{ .can_spawn = slot.depth < engine.max_agent_depth })) {
        return .{ .output = "The tool is unavailable at this agent depth.", .is_error = true };
    }
    const res = tools.run(tools.ctx, arena, call.name, call.arguments, .{
        .workspace_root = workspace_root,
        .site = .{ .session_id = slot.sessionId(), .message_id = slot.progress.current.?.message_id, .part_id = pt.part_id },
        .work = &slot.work,
    });

    const after = hooks.askIfHeld(arena, .@"tool.after", .{
        .name = call.name,
        .arguments = call.arguments,
        .output = res.output,
        .is_error = res.is_error,
        .view = res.view,
    });
    return switch (after) {
        .proceed => res,
        .replace => |value| blk: {
            const changed = std.json.parseFromValueLeaky(ToolResult, arena, value, .{ .ignore_unknown_fields = true }) catch break :blk res;
            break :blk .{ .output = changed.output, .view = changed.view, .is_error = changed.is_error, .cancellation_reason = res.cancellation_reason };
        },
        .block => |reason| .{ .output = reason, .is_error = true },
        .canceled => return error.Canceled,
    };
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

const zio = @import("zio");
const provider_store = @import("../provider/provider_store.zig");

var stream_test_env: std.process.Environ.Map = .init(std.testing.allocator);
var stream_test_transport = ai.transport.CannedTransport{ .bytes = ai.transport.canned_reply };
const capped_tool_reply =
    "data: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":0}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"unknown\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

/// Drive `Streamer.onEvent` over a real engine, session, and draft. The caller reads the draft parts.
const StreamerFixture = struct {
    runtime: *zio.Runtime,
    db: database.Database,
    store: provider_store,
    engine: Engine,
    slot: *RunSlot,
    session: *Session,

    const session_id = [_]u8{9} ** 16;
    /// The one user turn a request test serializes.
    const hello: message.Message = .{ .user = .{
        .id = 0,
        .input_id = 1,
        .content = &.{.{ .text = .{ .text = "hello" } }},
        .skill = null,
        .time = .{ .created_at_ms = 0 },
    } };

    fn init(self: *StreamerFixture) !void {
        return self.initWithPrompt(.{ .base = "", .child_policy = null, .environment = "" });
    }

    fn initWithPrompt(self: *StreamerFixture, parts: session_store.PromptInput) !void {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        self.runtime = try zio.Runtime.init(std.testing.allocator, .{ .executors = .exact(1) });
        errdefer self.runtime.deinit();
        self.db = try database.Database.openTest();
        errdefer self.db.deinit();
        try session_store.create(&self.db, .{
            .id = session_id,
            .root = "/w",
            .origin = "root",
            .profile = "default",
            .model = "mock",
            .reasoning = "",
            .config_rev = 0,
            .title = "t",
            .created_at_ms = 1,
            .updated_at_ms = 1,
        });
        const system = try session_store.setPrompt(&self.db, arena.allocator(), session_id, parts);
        self.store = .init(std.testing.allocator, self.runtime.io(), &stream_test_env);
        errdefer self.store.deinit();
        self.engine = Engine.init(.{
            .gpa = std.testing.allocator,
            .io = self.runtime.io(),
            .db = &self.db,
            .providers = &self.store,
            .route_transport = stream_test_transport.transport(),
            .env = &stream_test_env,
            .tools = .{},
        });
        errdefer self.engine.close();
        self.session = try self.engine.activate(.bytes(session_id));
        var prepared = try RunSlot.prepare(std.testing.allocator, "mock", "", system, null);
        errdefer prepared.deinit();
        self.slot = prepared.bind(
            .{ .input_id = 1, .started = .{ .session_id = .bytes(session_id), .seq = 1, .run_id = 1, .kind = .turn, .config_rev = 0, .started_at_ms = 1 } },
            .{ .number = 1, .message_id = 1 },
            null,
            .{ .root = .bytes(session_id), .depth = 0 },
        );
        self.session.active_run = self.slot;
        try self.session.apply(.{ .message_started_data = .{
            .session_id = .bytes(session_id),
            .message_id = 1,
            .run_id = 1,
            .config_rev = 0,
            .agent = agent_name,
            .created_at_ms = 1,
        } });
    }

    fn deinit(self: *StreamerFixture) void {
        self.engine.close();
        self.db.deinit();
        self.store.deinit();
        self.runtime.deinit();
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
        self.slot.progress.current = .{ .number = 2, .message_id = message_id };
    }

    fn streamer(self: *StreamerFixture) Streamer {
        return .{ .engine = &self.engine, .slot = self.slot, .session = self.session };
    }
};

const NoticeCapture = struct {
    seen: bool = false,
    source: []const u8 = "",
    text: [512]u8 = undefined,
    len: usize = 0,

    fn onEvent(ctx: *anyopaque, note: proto.rpc.Notification) void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (note.method != .notice) return;
        self.source = note.params.notice.source;
        const message_text = note.params.notice.message;
        self.len = @min(message_text.len, self.text.len);
        @memcpy(self.text[0..self.len], message_text[0..self.len]);
        self.seen = true;
    }

    fn sink(self: *@This()) @import("sink.zig").Sink {
        return .{ .ctx = @ptrCast(self), .on_event = onEvent };
    }
};

test "a terminal commit fault emits recovery notice and leaves the run open" {
    var fixture: StreamerFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try fixture.persistStarted(a);
    var notice: NoticeCapture = .{};
    fixture.engine.sinks.add(notice.sink());
    fixture.slot.phase = .running;

    faultSlot(&fixture.engine, .bytes(StreamerFixture.session_id), fixture.slot, error.ConstraintTrigger);

    try std.testing.expect(fixture.session.faulted);
    try std.testing.expectEqual(RunSlot.Phase.faulted, fixture.slot.phase);
    try std.testing.expect(notice.seen);
    try std.testing.expect(std.mem.indexOf(u8, notice.text[0..notice.len], "Restart yuke to recover") != null);
    try std.testing.expectEqualStrings("engine", notice.source);
    try std.testing.expectEqual(@as(?u64, 1), (try session_store.snapshot(&fixture.db, a, StreamerFixture.session_id)).?.open_run_id);
    const row = (try fixture.db.conn.row("SELECT count(*) FROM events WHERE name = 'run.done'", .{})) orelse return error.NoRow;
    defer row.deinit();
    try std.testing.expectEqual(@as(i64, 0), row.int(0));
}

test "a capped tool round reloads with an assistant error and failed outcome" {
    var fixture: StreamerFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try fixture.persistStarted(a);
    fixture.store.merged.rows = &.{.{
        .id = "mock",
        .name = "Mock",
        .models = &.{.{ .id = "model", .upstream_id = "model", .name = "Model", .caps = .{ .tools = true } }},
        .availability = .{ .ready = .{
            .route = .{ .base_url = "https://example.test", .protocol = .anthropic_messages, .auth = .none },
            .credential = .none,
        } },
    }};
    fixture.slot.gpa.free(fixture.slot.config.model);
    fixture.slot.config.model = try fixture.slot.gpa.dupe(u8, "mock/model");
    fixture.slot.config.max_rounds = 1;
    try fixture.session.transcript.append(StreamerFixture.hello);
    const old_reply = stream_test_transport.bytes;
    defer stream_test_transport.bytes = old_reply;
    stream_test_transport.bytes = capped_tool_reply;
    fixture.session.draft.?.deinit();
    fixture.session.draft = null;
    fixture.slot.phase = .running;
    runSession(&fixture.engine, fixture.slot);

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

    try fixture.newRound(2);
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

        fn decls(ctx: *anyopaque, arena: std.mem.Allocator, _: toolset.Selection) error{OutOfMemory}![]const ai.ir.Tool {
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
            const parts = std.json.parseFromValueLeaky(database.session.PromptParts, arena, context.get("prompt").?, .{}) catch unreachable;
            const rebuilt = parts.render(arena) catch unreachable;
            std.debug.assert(std.mem.eql(u8, value.object.get("system").?.string, rebuilt));
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
        .caps = .{ .tools = true },
        .cost = .{ .input = 1.5 },
    });
    const row = try source.create(registry.Provider);
    row.* = try proto.dupe(source, registry.Provider{
        .id = "provider-before",
        .name = "Before",
        .models = &.{},
        .availability = .{ .ready = .{
            .route = .{
                .base_url = "https://example.test/v1",
                .protocol = .openai_chat,
                .auth = .{ .api_key = .authorization_bearer },
                .headers = &.{.{ .name = "X-Source", .value = "before" }},
            },
            .credential = .{ .literal = "secret-before" },
        } },
    });
    state.tools = try proto.dupe(source, @as([]const ai.ir.Tool, &.{.{
        .name = "tool_before",
        .description = "Before",
        .input_schema = "{\"type\":\"object\",\"properties\":{}}",
    }}));
    f.engine.installTools(.{ .ctx = &state, .getDecls = State.decls });
    f.engine.installHooks(.{ .ctx = &state, .holds = State.holds, .ask = State.ask });
    const transcript = [_]message.Message{StreamerFixture.hello};
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var prepared = try round_request.prepare(arena.allocator(), &f.engine, f.slot, &transcript, .{ .provider = row, .model = model });
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
            self.slot.cancel_requested = true;
            self.slot.wake_event.set(self.io);
        }
    };
    for ([_]proto.hook.Point{ .@"request.build", .@"request.send" }) |point| {
        var f: StreamerFixture = undefined;
        try f.init();
        defer f.deinit();
        f.slot.gpa.free(f.slot.config.model);
        f.slot.config.model = try f.slot.gpa.dupe(u8, "mock/model");
        f.slot.phase = .running;
        f.store.merged.rows = &.{.{
            .id = "mock",
            .name = "Mock",
            .models = &.{.{ .id = "model", .upstream_id = "model", .name = "Model" }},
            .availability = .{ .ready = .{
                .route = .{ .base_url = "https://example.test", .protocol = .openai_chat, .auth = .none },
                .credential = .none,
            } },
        }};
        try f.session.transcript.append(StreamerFixture.hello);
        var state: State = .{ .io = f.engine.deps.io, .slot = f.slot, .point = point };
        f.engine.installHooks(.{ .ctx = &state, .holds = State.holds, .ask = State.ask });
        var canceller = try state.io.concurrent(State.cancel, .{&state});
        defer canceller.cancel(state.io) catch {};
        var streamer = f.streamer();
        defer streamer.blocks.deinit(std.testing.allocator);
        try std.testing.expect(streamRound(&f.engine, f.slot, &streamer) == .canceled);
        try std.testing.expect(state.asked and !state.timed_out);
    }
}

test "a build hook cannot send an oversized system prompt" {
    const hookset = @import("hookset.zig");
    const State = struct {
        fn holds(_: *anyopaque, point: proto.hook.Point) bool {
            return point == .@"request.build";
        }

        fn ask(_: *anyopaque, arena: std.mem.Allocator, point: proto.hook.Point, payload: []const u8) hookset.Decision {
            std.debug.assert(point == .@"request.build");
            var value = std.json.parseFromSliceLeaky(std.json.Value, arena, payload, .{}) catch unreachable;
            const text = arena.alloc(u8, proto.meta.limits.max_message_string_bytes + 1) catch unreachable;
            @memset(text, 'x');
            value.object.put(arena, "system", .{ .string = text }) catch unreachable;
            return .{ .replace = value };
        }
    };
    var f: StreamerFixture = undefined;
    try f.init();
    defer f.deinit();
    var state: State = .{};
    f.engine.installHooks(.{ .ctx = &state, .holds = State.holds, .ask = State.ask });
    const row: registry.Provider = .{
        .id = "mock",
        .name = "Mock",
        .models = &.{},
        .availability = .{ .ready = .{
            .route = .{ .base_url = "https://example.test", .protocol = .openai_chat, .auth = .none },
            .credential = .none,
        } },
    };
    const model: registry.ModelSpec = .{ .id = "model", .upstream_id = "model", .name = "Model" };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.PromptTooLarge, round_request.prepare(arena.allocator(), &f.engine, f.slot, &.{StreamerFixture.hello}, .{ .provider = &row, .model = &model }));
}
