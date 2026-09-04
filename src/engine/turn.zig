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
const registry = @import("../provider/registry.zig");
const retry = @import("../provider/retry.zig");

const ids = proto.ids;
const message = proto.message;
const RunSlot = run.RunSlot;
const message_store = database.message;
const run_store = database.run;
const session_store = database.session;
const event_store = database.event;
const event = provider.event;

const agent_name = "claude";
const max_output_tokens: u32 = 8192;

/// The response gate must launch a prepared run exactly once. Callers hold the token as `?Launch`.
/// `release` clears the token before launch. `launchSlot` asserts the slot phase to catch a re-launch.
pub const Launch = struct {
    slot: *RunSlot,

    /// Launch the prepared slot. Return when another path consumed the token.
    pub fn release(self: *?Launch, engine: *Engine) void {
        const launch = self.* orelse return;
        self.* = null;
        launchSlot(engine, launch.slot) catch |err| {
            std.log.err("cannot release the run launch gate: {t}", .{err});
        };
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

    var arena_state = std.heap.ArenaAllocator.init(engine.deps.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

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
            commitFinal(engine, arena, slot, null, streamer.usage, .{ .failed = failure(err) });
            return;
        };
        const live = &rt.draft.?;
        engine.sinks.emit(started_note);
        session_events.announceActivity(engine, rt); // `run.started` says a run exists, not what it does.

        const terminal = streamRound(engine, arena, slot, &streamer);

        // Settle any tool parts into a terminal state. The request builder rejects a pending tool.
        const has_tools = hasToolPart(live);
        if (has_tools) {
            if (terminal == .success and terminal.success == .tool_calls) {
                // Resolve the session root once, then pass it to each asynchronous tool call.
                if (!root_resolved) {
                    workspace_root = workspaceRoot(engine, arena, session_id.raw) catch null;
                    root_resolved = true;
                }
                settlePendingTools(engine, arena, slot, &streamer, workspace_root, live) catch |err| {
                    faultSlot(engine, session_id, slot, err);
                    return;
                };
                if (workspace_root == null) {
                    commitFinal(engine, arena, slot, live, streamer.usage, .{ .failed = .{ .code = .internal, .message = "cannot resolve the workspace" } });
                    return;
                }
            } else {
                // Cancel any pending tool part; a canceled/failed stream or a malformed tool_use lands here.
                settlePendingTools(engine, arena, slot, &streamer, null, live) catch |err| {
                    faultSlot(engine, session_id, slot, err);
                    return;
                };
                if (terminal == .success) {
                    commitFinal(engine, arena, slot, live, streamer.usage, .{ .failed = .{ .code = .protocol, .message = "a tool part without a tool_calls stop reason" } });
                    return;
                }
            }
        }

        // A cancel forces the canceled terminal. A failed stream or a plain answer also ends the turn.
        const commit_terminal: Terminal = if (slot.cancel_requested) .canceled else terminal;
        if (commit_terminal != .success or !has_tools) {
            commitFinal(engine, arena, slot, live, streamer.usage, commit_terminal);
            return;
        }

        // A tool round: commit it and start the next round. The commit fold extends the transcript.
        _ = commitRound(engine, arena, slot, live, streamer.usage, terminal, .intermediate) catch |err| {
            faultSlot(engine, session_id, slot, err);
            return;
        };
        // A cancel at the round boundary ends the run without a new empty round.
        if (slot.cancel_requested) {
            finishRunOpen(engine, arena, slot, .{ .canceled = .{} }) catch |err| faultSlot(engine, session_id, slot, err);
            return;
        }
        // A finite max_rounds ends the turn after the capped tool round. null is unlimited.
        if (slot.config.max_rounds) |cap| {
            if (slot.progress.rounds_committed >= cap) {
                finishRunOpen(engine, arena, slot, .{ .failed = .{ .code = .max_rounds, .message = "the run reached its max_rounds limit" } }) catch |err| faultSlot(engine, session_id, slot, err);
                return;
            }
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
fn streamRound(engine: *Engine, arena: std.mem.Allocator, slot: *RunSlot, streamer: *Streamer) Terminal {
    // Build once for the round. Every attempt then sends the same bytes and the same tool prefix.
    const request = roundRequest(engine, arena, slot, streamer) catch |err| {
        std.log.warn("run {d} could not build its request: {t}", .{ slot.runId(), err });
        return .{ .failed = failure(err) };
    };

    var number: u8 = 1;
    while (true) : (number += 1) {
        streamer.reset();
        var info: provider.transport.AttemptInfo = .{};
        const terminal = streamAttempt(engine, arena, slot, streamer, request, &info) catch |err| {
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
    request: provider.transport.Request,
    info: *provider.transport.AttemptInfo,
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

/// Build the request for one round. A retry re-sends these bytes, so the cached prefix still matches.
fn roundRequest(engine: *Engine, arena: std.mem.Allocator, slot: *RunSlot, streamer: *Streamer) !provider.transport.Request {
    const model = slot.config.model;

    // The catalog must resolve the model. An unresolved selector is an operating error, not a bug.
    const resolved = engine.deps.providers.merged.resolveModel(model) orelse return error.UnknownModel;

    // Project the resident transcript for this round. The model window sets the history budget.
    const budget = turn_context.Budget.forModel(resolved.model.limits.context_window, resolved.model.limits.max_output_tokens);
    const ctx = try turn_context.project(arena, &streamer.session.transcript, budget);
    return resolvedRequest(arena, engine, slot, ctx.slice(), resolved);
}

/// Open the response and stream it into the draft, in a child so a cancel can interrupt a blocked read.
fn streamChild(engine: *Engine, arena: std.mem.Allocator, slot: *RunSlot, streamer: *Streamer, request: provider.transport.Request, info: *provider.transport.AttemptInfo) !void {
    defer slot.wake_event.set(engine.deps.io);
    try checkCanceled(engine.deps.io, slot);
    const body = try engine.deps.route_transport.open(arena, request, info);
    std.debug.assert(slot.body == null); // one body per run
    slot.body = body;
    defer {
        slot.body = null;
        body.deinit();
    }
    try checkCanceled(engine.deps.io, slot);
    try streamWithReducer(engine, body, streamer, slot.protocol);
}

/// Resolve the session level against the model. An unset level omits the control.
fn reasoningFor(
    model: *const registry.ModelSpec,
    level: []const u8,
    output_limit: u32,
) !provider.ir.ReasoningControl {
    if (level.len == 0) return .default;
    if (std.mem.eql(u8, level, "off")) return .off;
    if (model.reasoning_levels.len != 0 and !hasReasoningLevel(model.reasoning_levels, level))
        return error.UnsupportedReasoning;
    if (model.dialect.anthropic_adaptive) return .adaptive;
    if (thinkingBudget(model, level, output_limit)) |tokens| return .{ .budget = tokens };
    const effort = std.meta.stringToEnum(provider.ir.Effort, level) orelse return error.UnsupportedReasoning;
    return .{ .effort = effort };
}

fn hasReasoningLevel(levels: []const provider.model.ReasoningLevel, wanted: []const u8) bool {
    for (levels) |level| switch (level) {
        .none => {},
        .named => |name| if (std.mem.eql(u8, name, wanted)) return true,
    };
    return false;
}

/// The smallest budget an Anthropic-shaped endpoint accepts.
const thinking_budget_min: u64 = 1024;

/// Size the budget for a level. Thinking shares the output ceiling, so the answer keeps a part.
fn thinkingBudget(model: *const registry.ModelSpec, level: []const u8, output_limit: u32) ?u64 {
    const bounds = switch (model.dialect.reasoning_budget) {
        .unsupported => return null,
        .range => |range| range,
    };

    const cap: u64 = output_limit;
    var budget: u64 = if (std.mem.eql(u8, level, "max")) cap / 4 * 3 else cap / 2;
    if (bounds.max) |maximum| budget = @min(budget, maximum);
    if (bounds.min) |minimum| {
        if (minimum > 0) budget = @max(budget, @as(u64, @intCast(minimum)));
    }
    budget = @max(budget, thinking_budget_min);

    return if (budget >= cap) null else budget;
}

/// Build the real provider request. It sets the run protocol, the endpoint URL, and the auth headers.
fn resolvedRequest(
    arena: std.mem.Allocator,
    engine: *Engine,
    slot: *RunSlot,
    transcript: []const proto.message.Message,
    r: registry.Match,
) !provider.transport.Request {
    // A provider the merge could not complete has no route, so it cannot serve a turn.
    const route = switch (r.provider.availability) {
        .ready => |ready| ready,
        .unavailable => return error.UnknownModel,
    };
    slot.protocol = provider.protocolToProto(route.instance.protocol);

    const output_limit = if (r.model.limits.max_output_tokens) |limit|
        std.math.cast(u32, limit) orelse max_output_tokens
    else
        max_output_tokens;

    const body_bytes = try provider.requestBody(arena, transcript, route.instance.protocol, .{
        .model = r.model.upstream_id,
        .system = slot.config.system_prompt,
        .tools = engine.deps.tools.getDecls(engine.deps.tools.ctx),
        .max_output_tokens = output_limit,
        .reasoning = try reasoningFor(r.model, slot.config.reasoning, output_limit),
        .thinking_format = r.model.dialect.thinking_format,
        .reasoning_replay = r.model.dialect.reasoning_replay,
        .max_tokens_field = r.model.dialect.max_tokens_field,
        .responses_dialect = route.instance.responses_dialect,
        .cache = route.instance.cache != .unsupported,
    }, .{ .protocol = slot.protocol, .model = slot.config.model });

    // Read the credential and the clock here, so a rotated key or a lapsed grant needs no rebuild.
    const secret = registry.credential(route.credential, engine.deps.env, engine.nowMillis()) orelse return error.MissingCredential;
    var auth: std.ArrayList(provider.transport.Header) = .empty;
    try provider.resolve.authHeaders(arena, &route.instance, secret, &auth);

    return .{
        .url = try provider.resolve.endpointUrl(arena, &route.instance),
        .headers = auth.items,
        .body = body_bytes,
    };
}

/// Reduce the response stream with the reducer for `protocol`.
fn streamWithReducer(engine: *Engine, body: provider.transport.ResponseBody, streamer: *Streamer, protocol: proto.enums.ProviderProtocol) !void {
    switch (provider.protocolFromProto(protocol)) {
        inline else => |p| {
            var reducer = provider.Adapter(p).Reducer.init(engine.deps.gpa);
            defer reducer.deinit();
            try provider.transport.stream(engine.deps.gpa, body, &reducer, streamer, Streamer.onEvent);
        },
    }
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

/// Commit the current round's assistant message. A final round also appends run.done and terminalizes
/// the slot. An intermediate round keeps the run open (phase `.running`).
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
    const done: ?proto.run.RunDoneData = if (completion == .final) try run_store.appendOpenDone(engine.deps.db, arena, engine.newId(), ended_at, .{
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
    if (done) |run_done| session_events.emitDurable(engine, rt, .{ .method = .@"run.done", .params = .{ .run_done_data = run_done } });
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
    const done = try run_store.appendOpenDone(engine.deps.db, arena, engine.newId(), ended_at, .{
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
    session_events.emitDurable(engine, rt, .{ .method = .@"run.done", .params = .{ .run_done_data = done } });
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
    std.log.err("run {d} could not commit its terminal engine: {t}", .{ slot.runId(), err });
}

fn finishSlot(engine: *Engine, session_id: ids.SessionId, slot: *RunSlot) void {
    std.debug.assert(slot.body == null);
    std.debug.assert(slot.phase == .terminalized or slot.phase == .faulted);
    const rt = engine.sessions.get(session_id) orelse unreachable;
    std.debug.assert(rt.active_run == slot);
    const can_drain = slot.phase == .terminalized and !engine.closing and !rt.faulted;
    rt.active_run = null;
    slot.destroy();

    if (can_drain and rt.queueDepth() > 0) {
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
    std.debug.assert(rt.active_run == null);
    std.debug.assert(rt.queueDepth() > 0);

    var arena_state = std.heap.ArenaAllocator.init(engine.deps.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const session_id = rt.id;
    const snapshot = (try session_store.snapshot(engine.deps.db, arena, session_id.raw)) orelse return error.UnknownSession;
    const prompt = try session_store.prompt(engine.deps.db, arena, session_id.raw);
    const slot = try RunSlot.prepare(engine.deps.gpa, snapshot.model, snapshot.reasoning, prompt orelse "", snapshot.max_rounds);
    errdefer slot.destroy();
    const started = try run.beginQueuedTurn(engine.deps.db, engine.deps.io, arena, session_id.raw, snapshot.config_rev);
    slot.bind(started.handle, started.first_round);
    // Fold each durable event in sequence order: the drained user messages, then run.started.
    // The commit fold retires each drained input from the queue.
    session_events.publishUserCommits(engine, rt, started.user_commits);
    std.debug.assert(rt.queueDepth() == 0);
    rt.active_run = slot;
    session_events.emitDurable(engine, rt, .{ .method = .@"run.started", .params = .{ .run_started_data = started.handle.started } });
    return slot;
}

/// Hydrate each queued session and start its run after the catalog loads.
/// Restart durable work when a view opens a session; cross-process ownership stays undefined.
pub fn resumeSession(engine: *Engine, rt: *Session) !void {
    if (rt.active_run != null) return;
    if (rt.queueDepth() == 0) return;
    try startQueued(engine, rt);
}

fn checkCanceled(io: std.Io, slot: *const RunSlot) !void {
    try io.checkCancel();
    if (slot.cancel_requested) return error.Canceled;
}

/// Map each provider StreamEvent to a canonical broadcast. Fold it into the session, then publish it.
/// The reducer is the peer boundary. It emits dense, ordered, kind-checked events. So the fold trusts them.
/// Report whether an event carries model output. An empty delta carries none, so it does not close
/// the retry window.
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
        try runOneTool(engine, arena, slot, streamer, workspace_root.?, pt);
    }
}

/// Run one tool in a child task, so a cancel can interrupt a blocked call.
fn runOneTool(engine: *Engine, arena: std.mem.Allocator, slot: *RunSlot, streamer: *Streamer, workspace_root: []const u8, pt: PendingTool) !void {
    return switch (runChild(engine, slot, toolChild, .{ engine, arena, slot, streamer, workspace_root, pt })) {
        .canceled => {}, // The child settled its part canceled. The next part still settles.
        .aborted => error.Canceled,
        .returned => |result| result,
    };
}

/// Run one tool and emit exactly one terminal state despite cancellation.
fn toolChild(engine: *Engine, arena: std.mem.Allocator, slot: *RunSlot, streamer: *Streamer, workspace_root: []const u8, pt: PendingTool) !void {
    std.debug.assert(slot.phase == .running); // the run loop owns the slot for this round
    std.debug.assert(slot.progress.current != null); // the round opened the message
    defer slot.wake_event.set(engine.deps.io);
    const started = engine.nowMillis();
    {
        const old = engine.deps.io.swapCancelProtection(.blocked);
        defer _ = engine.deps.io.swapCancelProtection(old);
        try streamer.emitToolState(pt.part_id, .{ .running = .{ .started_at_ms = started } });
    }
    const tools = engine.deps.tools;
    const res = tools.run(tools.ctx, arena, pt.name, pt.arguments, workspace_root); // The cancel point.
    const duration = engine.nowMillis() -| started; // Saturate; the wall clock can move backward.
    const old = engine.deps.io.swapCancelProtection(.blocked);
    defer _ = engine.deps.io.swapCancelProtection(old);
    const settled: proto.tool.ToolState = if (slot.cancel_requested)
        .{ .canceled = .{} }
    else if (res.is_error)
        .{ .@"error" = .{ .@"error" = res.output, .view = res.view, .duration_ms = duration } }
    else
        .{ .completed = .{ .output = res.output, .view = res.view, .duration_ms = duration } };
    try streamer.emitToolState(pt.part_id, settled);
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

test "an unset level omits the control and off disables it" {
    const model: registry.ModelSpec = .{ .id = "m", .upstream_id = "m", .name = "m" };
    try std.testing.expectEqual(provider.ir.ReasoningControl.default, try reasoningFor(&model, "", 8192));
    try std.testing.expectEqual(provider.ir.ReasoningControl.off, try reasoningFor(&model, "off", 8192));
}

test "an adaptive row resolves to adaptive for every level that is not off" {
    const model: registry.ModelSpec = .{ .id = "m", .upstream_id = "m", .name = "m", .reasoning_levels = &.{.{ .named = "high" }}, .dialect = .{ .anthropic_adaptive = true } };
    try std.testing.expectEqual(provider.ir.ReasoningControl.adaptive, try reasoningFor(&model, "high", 8192));
    try std.testing.expectEqual(provider.ir.ReasoningControl.off, try reasoningFor(&model, "off", 8192));
}

test "a budget row sizes the budget from the output ceiling" {
    const model: registry.ModelSpec = .{
        .id = "m",
        .upstream_id = "m",
        .name = "m",
        .reasoning_levels = &.{ .{ .named = "max" }, .{ .named = "high" } },
        .dialect = .{ .reasoning_budget = .from(1024, 32000) },
    };
    try std.testing.expectEqual(@as(u64, 6144), (try reasoningFor(&model, "max", 8192)).budget);
    try std.testing.expectEqual(@as(u64, 4096), (try reasoningFor(&model, "high", 8192)).budget);
}

test "a budget is clamped by the feed bounds and refused when it reaches the ceiling" {
    const capped: registry.ModelSpec = .{ .id = "m", .upstream_id = "m", .name = "m", .reasoning_levels = &.{.{ .named = "high" }}, .dialect = .{ .reasoning_budget = .from(null, 2000) } };
    try std.testing.expectEqual(@as(u64, 2000), (try reasoningFor(&capped, "high", 8192)).budget);

    // A budget that reaches the ceiling falls back to the effort control.
    const tiny: registry.ModelSpec = .{ .id = "m", .upstream_id = "m", .name = "m", .reasoning_levels = &.{.{ .named = "high" }}, .dialect = .{ .reasoning_budget = .from(1024, null) } };
    try std.testing.expectEqual(provider.ir.Effort.high, (try reasoningFor(&tiny, "high", 1024)).effort);
}

test "a selected level outside the model list is unsupported" {
    const model: registry.ModelSpec = .{ .id = "m", .upstream_id = "m", .name = "m", .reasoning_levels = &.{.{ .named = "high" }} };
    try std.testing.expectError(error.UnsupportedReasoning, reasoningFor(&model, "turbo", 8192));
    try std.testing.expectEqual(provider.ir.Effort.high, (try reasoningFor(&model, "high", 8192)).effort);

    const unlisted: registry.ModelSpec = .{ .id = "m", .upstream_id = "m", .name = "m" };
    try std.testing.expectError(error.UnsupportedReasoning, reasoningFor(&unlisted, "turbo", 8192));
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
var stream_test_transport = provider.transport.CannedTransport{ .bytes = provider.transport.canned_reply };

/// Drive `Streamer.onEvent` over a real engine, session, and draft. The caller reads the draft parts.
const StreamerFixture = struct {
    runtime: *zio.Runtime,
    db: database.Database,
    store: provider_store,
    engine: Engine,
    slot: *RunSlot,
    session: *Session,

    const session_id = [_]u8{9} ** 16;

    fn init(self: *StreamerFixture) !void {
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
        self.slot = try RunSlot.prepare(std.testing.allocator, "mock", "", "", null);
        errdefer self.slot.destroy();
        self.slot.bind(
            .{ .input_id = 1, .started = .{ .session_id = .bytes(session_id), .seq = 1, .run_id = 1, .kind = .turn, .config_rev = 0, .started_at_ms = 1 } },
            .{ .number = 1, .message_id = 1 },
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
        self.session.active_run = null;
        self.slot.destroy();
        self.engine.close();
        self.db.deinit();
        self.store.deinit();
        self.runtime.deinit();
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
