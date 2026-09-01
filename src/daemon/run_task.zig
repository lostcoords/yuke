//! Own daemon run tasks. Each round commits one assistant message. The final round also commits run.done.

const std = @import("std");
const wire = @import("wire");
const State = @import("State.zig");
const session_runtime = @import("session_runtime.zig");
const session_events = @import("session_events.zig");
const run = @import("../engine/run.zig");
const provider = @import("../provider/provider.zig");
const draft = @import("domain").draft;
const Session = @import("domain").session.Session;
const database = @import("../database/database.zig");
const turn_context = @import("turn_context.zig");
const registry = @import("registry.zig");
const tools = @import("../tools/tool.zig");
const tool_registry = @import("../tools/registry.zig");
const retry = @import("../provider/retry.zig");
const host_mod = @import("../host/host.zig");
const local_host = @import("../host/local.zig");

const ids = wire.ids;
const message = wire.message;
const RunSlot = session_runtime.RunSlot;
const message_store = database.message;
const run_store = database.run;
const session_store = database.session;
const workspace_store = database.workspace;
const event_store = database.event;
const event = provider.event;

const agent_name = "claude";
const max_output_tokens: u32 = 8192;
const max_transcript_messages: usize = 1000;
// The model context is loaded once per turn and bounded. These defaults are generous; a model-window
// aware budget can refine them later.
const context_budget: turn_context.Budget = .{ .max_bytes = 8 * 1024 * 1024, .max_tokens = 1_000_000 };

/// The response gate must launch a prepared run exactly once. Callers hold the token as `?Launch`.
/// `release` clears the token before launch. `launchSlot` asserts the slot phase to catch a re-launch.
pub const Launch = struct {
    slot: *RunSlot,

    /// Launch the prepared slot. Return when another path consumed the token.
    pub fn release(self: *?Launch, state: *State) void {
        const launch = self.* orelse return;
        self.* = null;
        launchSlot(state, launch.slot) catch |err| {
            std.log.err("cannot release the run launch gate: {t}", .{err});
        };
    }
};

/// Launch one prepared run.
pub fn launchSlot(state: *State, slot: *RunSlot) !void {
    std.debug.assert(slot.phase == .pending_start);
    std.debug.assert(slot.progress.current != null); // bind must open round 1 before launch
    slot.retry_budget = state.retry_budget; // The budget covers this run, not one request.
    // The caller already folded and published run.started. This spawns the run task.
    const run_id = slot.runId();
    const session_id = slot.sessionId();
    slot.phase = .running;
    state.tasks.concurrent(state.io, runSession, .{ state, slot }) catch |err| {
        std.log.err("cannot launch run {d}: {t}", .{ run_id, err });
        // The run task never ran, so set the round timestamp here before the commit.
        slot.progress.current.?.created_at_ms = @max(state.nowMillis(), slot.handle.started.started_at_ms);
        var terminal_arena = std.heap.ArenaAllocator.init(state.gpa);
        defer terminal_arena.deinit();
        commitFinal(state, terminal_arena.allocator(), slot, null, null, .{ .failed = .{
            .code = .internal,
            .message = "the daemon could not launch the run task",
        } });
        finishSlot(state, session_id, slot);
        return err;
    };
}

/// Run one turn. The State task group owns this task. The session owns `slot` until cleanup.
fn runSession(state: *State, slot: *RunSlot) void {
    const session_id = slot.sessionId();
    defer finishSlot(state, session_id, slot);

    const rt = state.sessions.get(session_id) orelse unreachable;
    std.debug.assert(rt.active == slot);

    var arena_state = std.heap.ArenaAllocator.init(state.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Clear a live draft on an early return. A commit fold nulls it first on the normal path.
    defer if (rt.session.active != null) {
        rt.session.active.?.deinit();
        rt.session.active = null;
    };

    var streamer: Streamer = .{ .state = state, .slot = slot, .rt = rt, .session = &rt.session };
    defer streamer.offsets.deinit(state.gpa);

    // Load the model context once for the turn. Each round appends its committed message.
    var ctx = turn_context.TurnContext.load(arena, &state.db, session_id.raw, context_budget, max_transcript_messages) catch |err| {
        const term: Terminal = if (slot.cancel_requested) .canceled else .{ .failed = failure(err) };
        commitFinal(state, arena, slot, null, streamer.usage, term);
        return;
    };

    while (true) {
        // Open this round. message.started opens a fresh draft. streamRound resets the streamer.
        const created_at = state.nowMillis();
        std.debug.assert(slot.progress.current != null); // bind or beginRound opened the round
        slot.progress.current.?.created_at_ms = created_at;
        std.debug.assert(rt.session.active == null); // one draft per round
        const started_note: wire.rpc.Notification = .{ .method = .@"message.started", .params = .{ .message_started_data = .{
            .session_id = session_id,
            .message_id = slot.progress.current.?.message_id,
            .run_id = slot.runId(),
            .config_rev = slot.handle.started.config_rev,
            .agent = agent_name,
            .created_at_ms = created_at,
        } } };
        // Fold the start into the session, then publish. The fold opens the draft.
        rt.session.applyAuthoritative(started_note.params) catch |err| {
            commitFinal(state, arena, slot, null, streamer.usage, .{ .failed = failure(err) });
            return;
        };
        const live = &rt.session.active.?;
        session_events.publishBestEffort(state, session_id, started_note);
        session_events.announceActivity(state, rt); // `run.started` says a run exists, not what it does.

        const terminal = streamRound(state, arena, slot, &streamer, &ctx);

        // Settle any tool parts into a terminal state. The request builder rejects a pending tool.
        const has_tools = hasToolPart(live);
        if (has_tools) {
            if (terminal == .success and terminal.success == .tool_calls) {
                // Acquire the tool host. A test injects one; production resolves the workspace root.
                var host_backend: local_host.LocalHost = undefined;
                const host: ?host_mod.Host = state.tool_host orelse resolveHost(state, arena, session_id.raw, &host_backend);
                // A null host settles every part canceled; the run then faults on the unresolved workspace.
                settlePendingTools(state, arena, slot, &streamer, host, live) catch |err| {
                    faultSlot(state, session_id, slot, err);
                    return;
                };
                if (host == null) {
                    commitFinal(state, arena, slot, live, streamer.usage, .{ .failed = .{ .code = .internal, .message = "cannot resolve the workspace" } });
                    return;
                }
            } else {
                // Cancel any pending tool part; a canceled/failed stream or a malformed tool_use lands here.
                settlePendingTools(state, arena, slot, &streamer, null, live) catch |err| {
                    faultSlot(state, session_id, slot, err);
                    return;
                };
                if (terminal == .success) {
                    commitFinal(state, arena, slot, live, streamer.usage, .{ .failed = .{ .code = .protocol, .message = "a tool part without a tool_calls stop reason" } });
                    return;
                }
            }
        }

        // A cancel forces the canceled terminal. A failed stream or a plain answer also ends the turn.
        const commit_terminal: Terminal = if (slot.cancel_requested) .canceled else terminal;
        if (commit_terminal != .success or !has_tools) {
            commitFinal(state, arena, slot, live, streamer.usage, commit_terminal);
            return;
        }

        // A tool round: commit it, append it to the context, and start the next round.
        const committed = commitRound(state, arena, slot, live, streamer.usage, terminal, .intermediate) catch |err| {
            faultSlot(state, session_id, slot, err);
            return;
        };
        ctx.appendCommitted(committed) catch |err| {
            faultSlot(state, session_id, slot, err);
            return;
        };
        // A cancel at the round boundary ends the run without a new empty round.
        if (slot.cancel_requested) {
            finishRunOpen(state, arena, slot, .{ .canceled = .{} }) catch |err| faultSlot(state, session_id, slot, err);
            return;
        }
        // A finite max_rounds ends the turn after the capped tool round. null is unlimited.
        if (slot.config.max_rounds) |cap| {
            if (slot.progress.rounds_committed >= cap) {
                finishRunOpen(state, arena, slot, .{ .failed = .{ .code = .max_rounds, .message = "the run reached its max_rounds limit" } }) catch |err| faultSlot(state, session_id, slot, err);
                return;
            }
        }
        beginRound(state, slot) catch |err| {
            faultSlot(state, session_id, slot, err);
            return;
        };
    }
}

/// Commit the final round and fault the slot on a commit error.
fn commitFinal(state: *State, arena: std.mem.Allocator, slot: *RunSlot, live: ?*const draft.Draft, usage: ?message.TokenUsage, terminal: Terminal) void {
    _ = commitRound(state, arena, slot, live, usage, terminal, .final) catch |err| {
        faultSlot(state, slot.sessionId(), slot, err);
        return;
    };
}

/// Stream one round, and repeat the request while the classifier allows it. A repeat uses a fresh
/// body and a fresh reducer. `docs/plan.md` "Retry / backoff policy" holds the rules.
fn streamRound(state: *State, arena: std.mem.Allocator, slot: *RunSlot, streamer: *Streamer, ctx: *const turn_context.TurnContext) Terminal {
    var number: u8 = 1;
    while (true) : (number += 1) {
        streamer.reset();
        var info: provider.transport.AttemptInfo = .{};
        const outcome = streamAttempt(state, arena, slot, streamer, ctx, &info);
        const err = switch (outcome) {
            .failed => |e| e,
            else => return outcome.terminal,
        };

        const decision = retry.decide(state.retry_policy, .{
            .err = err,
            .info = info,
            // A published event outranks every other gate. The client already folded that output.
            .saw_semantic = streamer.saw_semantic,
            .number = number,
            .budget_left = slot.retry_budget,
        }, state.jitter());
        const delay_ms = switch (decision) {
            .stop => return .{ .failed = failure(err) },
            .retry_in_ms => |ms| ms,
        };

        std.debug.assert(slot.retry_budget > 0); // the classifier refuses a retry at zero
        slot.retry_budget -= 1;
        publishRetrying(state, slot, number, err, delay_ms);
        defer slot.retry_state = null;
        // Wait on the slot event, NOT on a plain sleep. `cancel_run` sets this event, and a plain
        // sleep would hold the run for the whole delay because the flag alone never wakes it.
        slot.wake_event.reset();
        const waited: std.Io.Clock.Duration = .{ .raw = .fromMilliseconds(@intCast(delay_ms)), .clock = .awake };
        if (slot.wake_event.waitTimeout(state.io, .{ .duration = waited })) |_| {
            return .canceled; // The event fired, so a cancel arrived during the delay.
        } else |wait_err| switch (wait_err) {
            error.Timeout => {}, // The delay elapsed. Open the next attempt.
            error.Canceled => return .canceled,
        }
        if (slot.cancel_requested) return .canceled;
    }
}

/// Record the wait on the slot, then tell every client. A resync reads the same state, so a client
/// that reconnects during the wait sees the retry instead of a silent pause.
fn publishRetrying(state: *State, slot: *RunSlot, number: u8, err: anyerror, delay_ms: u64) void {
    // @todo(xyaman): log one line per attempt. Record the attempt number, provider, model, status, the
    // normalized code, the provider request id, the delivery state, the delay source, and the budget
    // left. Never log the API key. A user report of odd retry behavior has nothing to read today.
    const detail = failure(err);
    slot.retry_state = .{
        .run_id = slot.runId(),
        .attempt = number,
        .max_attempts = state.retry_policy.max_attempts,
        .next_at_ms = state.nowMillis() + delay_ms,
        .code = detail.code,
        .message = detail.message,
    };
    // Announce the whole activity, so the context gauge, the config and the queue stay true.
    // `residentActivity` reads the retry state that this function just set.
    const rt = state.sessions.get(slot.sessionId()) orelse return;
    session_events.announceActivity(state, rt);
}

/// The outcome of one attempt. A failure carries its error for the classifier.
const AttemptOutcome = union(enum) {
    terminal: Terminal,
    failed: anyerror,

    fn ok(t: Terminal) AttemptOutcome {
        return .{ .terminal = t };
    }
};

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
fn runChild(state: *State, slot: *RunSlot, comptime f: anytype, args: anytype) ChildResult {
    slot.wake_event.reset(); // A one-shot event. The next child waits again.
    var child = state.io.concurrent(f, args) catch |err| return .{ .returned = err };
    slot.wake_event.wait(state.io) catch {
        child.cancel(state.io) catch {}; // Shutdown canceled this run task. Stop the child.
        return .aborted;
    };
    if (slot.cancel_requested) {
        child.cancel(state.io) catch {}; // Interrupt a blocked call, then join the child.
        return .canceled;
    }
    return .{ .returned = child.await(state.io) };
}

/// Run one attempt. The child owns the body and cancellation.
fn streamAttempt(
    state: *State,
    arena: std.mem.Allocator,
    slot: *RunSlot,
    streamer: *Streamer,
    ctx: *const turn_context.TurnContext,
    info: *provider.transport.AttemptInfo,
) AttemptOutcome {
    const result = switch (runChild(state, slot, streamChild, .{ state, arena, slot, streamer, ctx, info })) {
        .canceled, .aborted => return .ok(.canceled),
        .returned => |r| r,
    };
    if (result) |_| {
        if (slot.cancel_requested) return .ok(.canceled);
        const reason = streamer.stop_reason orelse
            return .ok(.{ .failed = .{ .code = .protocol, .message = "the provider stream has no stop reason" } });
        return .ok(.{ .success = reason });
    } else |err| {
        if (err == error.Canceled or slot.cancel_requested) return .ok(.canceled);
        return .{ .failed = err };
    }
}

/// Open the response and stream it into the draft. The run task uses a child so cancellation can interrupt a blocked read.
/// The child owns the body and deinits it before it returns.
fn streamChild(state: *State, arena: std.mem.Allocator, slot: *RunSlot, streamer: *Streamer, ctx: *const turn_context.TurnContext, info: *provider.transport.AttemptInfo) !void {
    defer slot.wake_event.set(state.io);
    try checkCanceled(state.io, slot);
    const transcript = ctx.slice();
    const model = slot.config.model;

    // The catalog must resolve the model. An unresolved selector is an operating error, not a bug.
    const resolved = state.store.merged.resolveModel(model) orelse return error.UnknownModel;
    const request = try resolvedRequest(arena, state, slot, transcript, resolved);
    const body = try state.route_transport.open(arena, request, info);
    std.debug.assert(slot.body == null); // one body per run
    slot.body = body;
    defer {
        slot.body = null;
        body.deinit();
    }
    try checkCanceled(state.io, slot);
    try streamWithReducer(state, body, streamer, slot.protocol);
}

/// Resolve the session level against the model. An unset level omits the control.
fn reasoningFor(
    model: *const registry.ModelSpec,
    level: []const u8,
    output_limit: u32,
) provider.ir.ReasoningControl {
    if (level.len == 0) return .default;
    if (std.mem.eql(u8, level, "off")) return .off;
    if (model.dialect.anthropic_adaptive) return .adaptive;
    if (thinkingBudget(model, level, output_limit)) |tokens| return .{ .budget = tokens };
    return if (std.meta.stringToEnum(provider.ir.Effort, level)) |effort| .{ .effort = effort } else .default;
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
    if (bounds.max.optional()) |maximum| budget = @min(budget, maximum);
    if (bounds.min.optional()) |minimum| {
        if (minimum > 0) budget = @max(budget, @as(u64, @intCast(minimum)));
    }
    budget = @max(budget, thinking_budget_min);

    return if (budget >= cap) null else budget;
}

/// Build the real provider request. It sets the run protocol, the endpoint URL, and the auth headers.
fn resolvedRequest(
    arena: std.mem.Allocator,
    state: *State,
    slot: *RunSlot,
    transcript: []const wire.message.Message,
    r: registry.Match,
) !provider.transport.Request {
    // A provider the merge could not complete has no route, so it cannot serve a turn.
    const route = switch (r.provider.availability) {
        .ready => |ready| ready,
        .unavailable => return error.UnknownModel,
    };
    slot.protocol = route.instance.protocol;

    const output_limit = if (r.model.limits.max_output_tokens.optional()) |limit|
        std.math.cast(u32, limit) orelse max_output_tokens
    else
        max_output_tokens;

    const body_bytes = try provider.requestBody(arena, transcript, route.instance.protocol, .{
        .model = r.model.upstream_id,
        .system = slot.config.system_prompt,
        .tools = tool_registry.declarations,
        .max_output_tokens = output_limit,
        .reasoning = reasoningFor(r.model, slot.config.reasoning, output_limit),
        .thinking_format = r.model.dialect.thinking_format,
        .reasoning_replay = r.model.dialect.reasoning_replay,
        .max_tokens_field = r.model.dialect.max_tokens_field,
        .responses_dialect = route.instance.responses_dialect,
    }, .{ .protocol = route.instance.protocol, .model = slot.config.model });

    // Read the credential and the clock here, so a rotated key or a lapsed grant needs no rebuild.
    const secret = registry.credential(route.credential, state.env, state.nowMillis()) orelse return error.MissingCredential;
    var auth: std.ArrayList(provider.transport.Header) = .empty;
    try provider.resolve.authHeaders(arena, &route.instance, secret, &auth);

    return .{
        .url = try provider.resolve.endpointUrl(arena, &route.instance),
        .headers = auth.items,
        .body = body_bytes,
    };
}

/// Reduce the response stream with the reducer for `protocol`.
fn streamWithReducer(state: *State, body: provider.transport.ResponseBody, streamer: *Streamer, protocol: wire.enums.ProviderProtocol) !void {
    switch (protocol) {
        inline else => |p| {
            var reducer = provider.Adapter(p).Reducer.init(state.gpa);
            defer reducer.deinit();
            try provider.transport.stream(state.gpa, body, &reducer, streamer, Streamer.onEvent);
        },
    }
}

const Terminal = union(enum) {
    success: wire.enums.StopReason,
    canceled,
    failed: Failure,
};

const Failure = struct {
    code: wire.enums.RunErrorCode,
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
    state: *State,
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
    const old_cancel_protection = state.io.swapCancelProtection(.blocked);
    defer _ = state.io.swapCancelProtection(old_cancel_protection);

    const round = &slot.progress.current.?;
    const content = if (live) |value| (try value.toActiveDraft(arena)).message.content else &.{};
    const ended_at = @max(state.nowMillis(), slot.handle.started.started_at_ms);
    const finish: wire.enums.StopReason = switch (terminal) {
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
    const outcome: wire.run.RunOutcome = switch (terminal) {
        .success => |reason| .{ .turn = .{ .finish = reason, .rounds = slot.progress.rounds_committed } },
        .canceled => .{ .canceled = .{} },
        .failed => |item| .{ .failed = .{ .code = item.code, .message = item.message } },
    };
    // The committed content borrows the draft. The commit fold frees the draft, so own a copy first.
    // Copy before the transaction, so an allocation failure consumes no durable sequence.
    const owned = try wire.dupe(arena, committed);
    const session_id = slot.sessionId();

    var tx = try state.db.begin();
    defer tx.deinit();
    const seq = try message_store.appendCommittedMessage(&state.db, arena, session_id.raw, state.newId(), ended_at, owned);
    const done: ?wire.run.RunDoneData = if (completion == .final) try run_store.appendOpenDone(&state.db, arena, state.newId(), ended_at, .{
        .session_id = session_id,
        .seq = 0,
        .run_id = slot.runId(),
        .kind = slot.handle.started.kind,
        .timing = .{ .started_at_ms = slot.handle.started.started_at_ms, .ended_at_ms = ended_at },
        .outcome = outcome,
    }) else null;
    try tx.commit();
    if (completion == .final) slot.phase = .terminalized;

    const rt = state.sessions.get(session_id) orelse unreachable;
    session_events.emitDurable(state, rt, .{ .method = .@"message.committed", .params = .{
        .message_committed_data = .{ .session_id = session_id, .seq = seq, .message = owned },
    } });
    session_events.announceSummary(state, session_id); // The commit moved the count, the lifetime usage, and the order.
    if (done) |run_done| session_events.emitDurable(state, rt, .{ .method = .@"run.done", .params = .{ .run_done_data = run_done } });
    return owned;
}

/// Close an open run at a round boundary with `outcome`. The last round is already committed.
fn finishRunOpen(state: *State, arena: std.mem.Allocator, slot: *RunSlot, outcome: wire.run.RunOutcome) !void {
    std.debug.assert(slot.phase == .running);
    const old_cancel_protection = state.io.swapCancelProtection(.blocked);
    defer _ = state.io.swapCancelProtection(old_cancel_protection);

    const session_id = slot.sessionId();
    const ended_at = @max(state.nowMillis(), slot.handle.started.started_at_ms);
    var tx = try state.db.begin();
    defer tx.deinit();
    const done = try run_store.appendOpenDone(&state.db, arena, state.newId(), ended_at, .{
        .session_id = session_id,
        .seq = 0,
        .run_id = slot.runId(),
        .kind = slot.handle.started.kind,
        .timing = .{ .started_at_ms = slot.handle.started.started_at_ms, .ended_at_ms = ended_at },
        .outcome = outcome,
    });
    try tx.commit();
    slot.phase = .terminalized;

    const rt = state.sessions.get(session_id) orelse unreachable;
    session_events.emitDurable(state, rt, .{ .method = .@"run.done", .params = .{ .run_done_data = done } });
}

/// Allocate the next round: allocate a message id, then advance the progress state.
fn beginRound(state: *State, slot: *RunSlot) !void {
    var arena_state = std.heap.ArenaAllocator.init(state.gpa);
    defer arena_state.deinit();
    var tx = try state.db.begin();
    defer tx.deinit();
    const message_id = try event_store.allocMessageId(&state.db, arena_state.allocator(), slot.sessionId().raw);
    try tx.commit();
    slot.progress.rounds_started += 1;
    slot.progress.current = .{ .number = slot.progress.rounds_started, .message_id = message_id };
}

/// Preserve the open marker when Tx2 fails. Startup recovery closes the durable obligation.
fn faultSlot(state: *State, session_id: ids.SessionId, slot: *RunSlot, err: anyerror) void {
    slot.phase = .faulted;
    if (state.sessions.get(session_id)) |rt| rt.faulted = true;
    std.log.err("run {d} could not commit its terminal state: {t}", .{ slot.runId(), err });
}

fn finishSlot(state: *State, session_id: ids.SessionId, slot: *RunSlot) void {
    std.debug.assert(slot.body == null);
    std.debug.assert(slot.phase == .terminalized or slot.phase == .faulted);
    const rt = state.sessions.get(session_id) orelse unreachable;
    std.debug.assert(rt.active == slot);
    const can_drain = slot.phase == .terminalized and !state.shutting_down and !rt.faulted;
    rt.active = null;
    slot.destroy();

    if (can_drain and rt.session.queue.depth() > 0) {
        startQueued(state, rt) catch |err| {
            if (state.sessions.get(session_id)) |current| current.faulted = true;
            std.log.err("cannot start a queued run: {t}", .{err});
        };
    }
    // A nested finishSlot can evict the session, so look the runtime up again before it is read.
    if (state.sessions.get(session_id)) |settled| session_events.announceActivity(state, settled);
    state.sessions.evictIfIdle(session_id);
}

fn startQueued(state: *State, rt: *session_runtime.SessionRuntime) !void {
    const slot = try prepareQueued(state, rt);
    try launchSlot(state, slot);
}

/// Commit one run for all queued inputs.
pub fn prepareQueued(state: *State, rt: *session_runtime.SessionRuntime) !*RunSlot {
    std.debug.assert(rt.active == null);
    std.debug.assert(rt.session.queue.depth() > 0);

    var arena_state = std.heap.ArenaAllocator.init(state.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const session_id = rt.session.id;
    const snapshot = (try session_store.snapshot(&state.db, arena, session_id.raw)) orelse return error.UnknownSession;
    const prompt = try session_store.prompt(&state.db, arena, session_id.raw);
    const slot = try RunSlot.prepare(state.gpa, snapshot.model, snapshot.reasoning, prompt orelse "", snapshot.max_rounds);
    errdefer slot.destroy();
    const started = try run.beginQueuedTurn(&state.db, state.io, arena, session_id.raw, snapshot.config_rev);
    slot.bind(started.handle, started.first_round);
    // Fold each durable event in sequence order: the drained user messages, then run.started.
    // The commit fold retires each drained input from the queue.
    session_events.publishUserCommits(state, rt, started.user_commits);
    std.debug.assert(rt.session.queue.depth() == 0);
    rt.active = slot;
    session_events.emitDurable(state, rt, .{ .method = .@"run.started", .params = .{ .run_started_data = started.handle.started } });
    return slot;
}

/// Hydrate each queued session and start its run after the catalog loads.
pub fn resumeSessions(state: *State) !void {
    var arena_state = std.heap.ArenaAllocator.init(state.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const session_ids = try database.input.sessionIds(&state.db, arena);

    // Hydrate every session before any run starts, so a late failure consumes no queue.
    const runtimes = try arena.alloc(*session_runtime.SessionRuntime, session_ids.len);
    for (session_ids, runtimes) |raw, *slot| slot.* = try state.activate(.bytes(raw));
    for (runtimes) |rt| {
        if (rt.active == null and rt.session.queue.depth() > 0) try startQueued(state, rt);
    }
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

const Streamer = struct {
    state: *State,
    slot: *RunSlot,
    rt: *session_runtime.SessionRuntime,
    session: *Session,
    offsets: std.ArrayList(u64) = .empty,
    open: usize = 0,
    stop_reason: ?wire.enums.StopReason = null,
    usage: ?message.TokenUsage = null,
    /// A semantic event reached the client. A repeat of the request would duplicate it.
    saw_semantic: bool = false,

    /// Reset the per-round stream state before a new round.
    fn reset(self: *Streamer) void {
        self.offsets.clearRetainingCapacity();
        self.open = 0;
        self.stop_reason = null;
        self.usage = null;
        self.saw_semantic = false;
    }

    /// Fold the canonical value first, then publish the same value. The daemon never folds its own output.
    fn emit(self: *Streamer, note: wire.rpc.Notification) !void {
        try self.session.applyAuthoritative(note.params);
        try session_events.publish(self.state, self.slot.sessionId(), note);
    }

    fn onEvent(self: *Streamer, ev: event.StreamEvent) !void {
        // Check cancellation after each SSE event.
        try checkCanceled(self.state.io, self.slot);
        // Latch the boundary before the emit below. The latch then blocks a replay of this output.
        if (isSemantic(ev)) self.saw_semantic = true;
        switch (ev) {
            .block_started => |b| {
                // Blocks are sequential; a new block requires the previous one to stop. This keeps the
                // deferred tool part_added in ascending id order, so a peer never trips the fold assert.
                if (self.open != 0) return error.Protocol;
                // A tool block has no metadata yet. Open its part at block_stopped instead.
                if (b.kind != .tool) {
                    try self.emit(.{ .method = .@"message.part_added", .params = .{ .message_part_added_data = .{
                        .session_id = self.slot.sessionId(),
                        .message_id = self.slot.progress.current.?.message_id,
                        .part = emptyPart(b.block, b.kind),
                    } } });
                    // A block boundary is the only point in a turn that moves the phase. A delta never does.
                    session_events.announceActivity(self.state, self.rt);
                }
                try self.offsets.append(self.state.gpa, 0);
                self.open += 1;
            },
            .text_delta => |d| try self.partDelta(d.block, d.text),
            .reasoning_delta => |d| try self.partDelta(d.block, d.text),
            .tool_input_delta => {}, // The reducer joins fragments; the whole call arrives at block_stopped.
            .block_stopped => |b| {
                if (self.open == 0) return error.Protocol;
                self.open -= 1;
                switch (b.result) {
                    .reasoning => |r| try self.emitFinalized(b.block, .{ .reasoning = .{ .signature = r.signature } }),
                    .redacted_reasoning => |r| try self.emitFinalized(b.block, .{ .redacted_reasoning = .{ .data = r.data } }),
                    .text => {},
                    .tool => |call| try self.emitToolPart(b.block, call),
                }
            },
            .done => |d| {
                if (self.open != 0) return error.Protocol;
                self.stop_reason = d.stop_reason;
                self.usage = d.usage;
            },
        }
    }

    fn partDelta(self: *Streamer, part_id: event.BlockId, text: []const u8) !void {
        const index: usize = @intCast(part_id); // The reducer emits dense ids, so this fits a part index.
        std.debug.assert(index < self.offsets.items.len); // The reducer opens the block before it emits the delta.
        const offset = self.offsets.items[index];
        try checkStreamCap(offset, text.len); // The provider is a peer. Return an error for an oversized delta.
        try self.emit(.{ .method = .@"message.part_delta", .params = .{ .message_part_delta_data = .{
            .session_id = self.slot.sessionId(),
            .message_id = self.slot.progress.current.?.message_id,
            .part_id = part_id,
            .delta = text,
            .offset = offset,
        } } });
        self.offsets.items[index] += text.len;
    }

    fn emitFinalized(self: *Streamer, part_id: event.BlockId, final: message.PartFinal) !void {
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
        session_events.announceActivity(self.state, self.rt); // A closed reasoning part ends the reasoning phase.
    }

    /// Open a pending tool part when its block stops. The provider is a peer, so cap the metadata sizes.
    /// The part stays pending until the run settles it into a terminal state.
    fn emitToolPart(self: *Streamer, part_id: event.BlockId, call: event.ToolCall) !void {
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
        session_events.announceActivity(self.state, self.rt);
    }

    /// Fold and publish a tool state transition for one part.
    fn emitToolState(self: *Streamer, part_id: wire.ids.PartId, state: wire.tool.ToolState) !void {
        try self.emit(.{ .method = .@"tool.state_changed", .params = .{ .tool_state_changed_data = .{
            .session_id = self.slot.sessionId(),
            .message_id = self.slot.progress.current.?.message_id,
            .part_id = part_id,
            .state = state,
        } } });
        session_events.announceActivity(self.state, self.rt);
    }
};

/// A native tool result mapped for a tool state. `is_error` selects the completed or error state.
const ToolExec = struct { output: []const u8, view: ?[]const wire.view.View = null, is_error: bool };

/// Run one built-in tool. The `scratch` allocator holds temporary data. The `out` allocator holds
/// the result for the turn. A tool error gives the model a correction for the next round.
fn runTool(out: std.mem.Allocator, scratch: std.mem.Allocator, host: host_mod.Host, name: []const u8, arguments: []const u8) ToolExec {
    const t = tool_registry.find(name) orelse return .{
        .output = std.fmt.allocPrint(out, "The tool \"{s}\" is unknown.", .{name}) catch "The requested tool is unknown.",
        .is_error = true,
    };
    const res = t.execute(out, scratch, host, arguments) catch |err| return .{ .output = toolErrorMessage(out, t, err), .is_error = true };
    return .{ .output = res.text, .view = res.view, .is_error = false };
}

/// Map a `ToolError` to model text. The switch is exhaustive, so every new error needs a message.
/// The request already carries the schema, so the message does not repeat it.
fn toolErrorMessage(out: std.mem.Allocator, t: tools.Tool, err: tools.ToolError) []const u8 {
    const text: []const u8 = switch (err) {
        error.MalformedArgs => "the arguments hold invalid JSON",
        error.MissingArg => "the request lacks a required argument",
        error.UnknownArg => "the schema lacks the argument",
        error.DuplicateArg => "an argument appears two times",
        error.InvalidArg => "the argument has the wrong type or range",
        error.NotFound => "the path does not exist",
        error.NotAFile => "the path names a directory or a special file",
        error.AccessDenied => "the file system denied access to the path",
        error.TooLarge => "the file exceeds the size limit",
        error.InvalidUtf8 => "the file holds invalid UTF-8",
        error.NoMatch => "the file lacks old_string",
        error.Ambiguous => "old_string appears more than one time. You must add context or set replace_all",
        error.NoChange => "old_string and new_string match. The edit changes nothing",
        error.Canceled => "cancellation stopped the call",
        error.HostFailure => "the tool host returned an error",
        error.OutOfMemory => "memory allocation failed",
    };
    return std.fmt.allocPrint(out, "{s}: {s}", .{ t.name, text }) catch text;
}

/// Build a local tool host for the session workspace. Return null when the workspace lookup fails.
fn resolveHost(state: *State, arena: std.mem.Allocator, session_id: [16]u8, backend: *local_host.LocalHost) ?host_mod.Host {
    const root = workspaceRoot(state, arena, session_id) catch return null;
    backend.* = .{ .io = state.io, .root = root, .env = state.env };
    return backend.host();
}

/// Return the canonical workspace root for a session. The built-in tools resolve paths against it.
fn workspaceRoot(state: *State, arena: std.mem.Allocator, session_id: [16]u8) ![]const u8 {
    const snap = (try session_store.snapshot(&state.db, arena, session_id)) orelse return error.UnknownSession;
    const ws = (try workspace_store.byId(&state.db, arena, snap.workspace_id)) orelse return error.UnknownSession;
    return ws.root;
}

/// True when the draft holds any tool part.
fn hasToolPart(live: *const draft.Draft) bool {
    for (live.parts.items) |*p| if (p.* == .tool) return true;
    return false;
}

/// One pending tool call. A snapshot frees the tool call from the draft parts array.
const PendingTool = struct { part_id: wire.ids.PartId, name: []const u8, arguments: []const u8 };

/// Settle every pending tool part into a terminal state. The tools run ONE AT A TIME in provider
/// order. Without a host, and after a cancel, each remaining part settles canceled and no tool runs.
fn settlePendingTools(state: *State, arena: std.mem.Allocator, slot: *RunSlot, streamer: *Streamer, host: ?host_mod.Host, live: *const draft.Draft) !void {
    var pending: std.ArrayList(PendingTool) = .empty;
    for (live.parts.items) |*p| {
        if (p.* != .tool or std.meta.activeTag(p.tool.state) != .pending) continue;
        try pending.append(arena, .{ .part_id = p.tool.id, .name = p.tool.name, .arguments = p.tool.arguments });
    }
    for (pending.items) |pt| {
        if (host == null or slot.cancel_requested) {
            try streamer.emitToolState(pt.part_id, .{ .canceled = .{} });
            continue;
        }
        try runOneTool(state, arena, slot, streamer, host.?, pt);
    }
}

/// Run one tool in a child task, so a cancel can interrupt a blocked call.
fn runOneTool(state: *State, arena: std.mem.Allocator, slot: *RunSlot, streamer: *Streamer, host: host_mod.Host, pt: PendingTool) !void {
    return switch (runChild(state, slot, toolChild, .{ state, arena, slot, streamer, host, pt })) {
        .canceled => {}, // The child settled its part canceled. The next part still settles.
        .aborted => error.Canceled,
        .returned => |result| result,
    };
}

/// Run one tool and emit its running -> terminal lifecycle. A cancel during the call settles the part
/// canceled. Each state emit blocks cancelation, so exactly one terminal state lands.
fn toolChild(state: *State, arena: std.mem.Allocator, slot: *RunSlot, streamer: *Streamer, host: host_mod.Host, pt: PendingTool) !void {
    std.debug.assert(slot.phase == .running); // the run loop owns the slot for this round
    std.debug.assert(slot.progress.current != null); // the round opened the message
    defer slot.wake_event.set(state.io);
    const started = state.nowMillis();
    {
        const old = state.io.swapCancelProtection(.blocked);
        defer _ = state.io.swapCancelProtection(old);
        try streamer.emitToolState(pt.part_id, .{ .running = .{ .started_at_ms = started } });
    }
    // The `scratch` allocator holds the file bytes and the decoded arguments. It frees per call.
    // The `out` allocator keeps the result for the turn.
    var scratch = std.heap.ArenaAllocator.init(state.gpa);
    defer scratch.deinit();
    const res = runTool(arena, scratch.allocator(), host, pt.name, pt.arguments); // The cancel point.
    const duration = state.nowMillis() -| started; // Saturate; the wall clock can move backward.
    const old = state.io.swapCancelProtection(.blocked);
    defer _ = state.io.swapCancelProtection(old);
    const settled: wire.tool.ToolState = if (slot.cancel_requested)
        .{ .canceled = .{} }
    else if (res.is_error)
        .{ .@"error" = .{ .@"error" = res.output, .view = res.view, .duration_ms = duration } }
    else
        .{ .completed = .{ .output = res.output, .view = res.view, .duration_ms = duration } };
    try streamer.emitToolState(pt.part_id, settled);
}

/// Reject a provider payload that would exceed the stream cap. This is peer input. Return an error.
fn checkStreamCap(offset: u64, len: usize) error{ResponseTooLarge}!void {
    const cap: u64 = @intCast(wire.meta.limits.max_message_string_bytes);
    if (offset > cap or len > cap - offset) return error.ResponseTooLarge;
}

fn emptyPart(part_id: event.BlockId, kind: event.BlockKind) message.AssistantPart {
    return switch (kind) {
        .text => .{ .text = .{ .id = part_id, .text = "" } },
        .reasoning => .{ .reasoning = .{ .id = part_id, .text = "", .signature = "" } },
        .redacted_reasoning => .{ .redacted_reasoning = .{ .id = part_id, .data = "" } },
        .tool => unreachable, // A tool part opens at block_stopped, not block_started.
    };
}

test "an unset level omits the control and off disables it" {
    const model: registry.ModelSpec = .{ .id = "m", .upstream_id = "m", .name = "m" };
    try std.testing.expectEqual(provider.ir.ReasoningControl.default, reasoningFor(&model, "", 8192));
    try std.testing.expectEqual(provider.ir.ReasoningControl.off, reasoningFor(&model, "off", 8192));
}

test "an adaptive row resolves to adaptive for every level that is not off" {
    const model: registry.ModelSpec = .{ .id = "m", .upstream_id = "m", .name = "m", .dialect = .{ .anthropic_adaptive = true } };
    try std.testing.expectEqual(provider.ir.ReasoningControl.adaptive, reasoningFor(&model, "high", 8192));
    try std.testing.expectEqual(provider.ir.ReasoningControl.off, reasoningFor(&model, "off", 8192));
}

test "a budget row sizes the budget from the output ceiling" {
    const model: registry.ModelSpec = .{
        .id = "m",
        .upstream_id = "m",
        .name = "m",
        .dialect = .{ .reasoning_budget = .from(1024, 32000) },
    };
    try std.testing.expectEqual(@as(u64, 6144), reasoningFor(&model, "max", 8192).budget);
    try std.testing.expectEqual(@as(u64, 4096), reasoningFor(&model, "high", 8192).budget);
}

test "a budget is clamped by the feed bounds and refused when it reaches the ceiling" {
    const capped: registry.ModelSpec = .{ .id = "m", .upstream_id = "m", .name = "m", .dialect = .{ .reasoning_budget = .from(null, 2000) } };
    try std.testing.expectEqual(@as(u64, 2000), reasoningFor(&capped, "high", 8192).budget);

    // A budget that reaches the ceiling falls back to the effort control.
    const tiny: registry.ModelSpec = .{ .id = "m", .upstream_id = "m", .name = "m", .dialect = .{ .reasoning_budget = .from(1024, null) } };
    try std.testing.expectEqual(provider.ir.Effort.high, reasoningFor(&tiny, "high", 1024).effort);
}

test "a level the model never listed omits the control" {
    const model: registry.ModelSpec = .{ .id = "m", .upstream_id = "m", .name = "m" };
    try std.testing.expectEqual(provider.ir.ReasoningControl.default, reasoningFor(&model, "turbo", 8192));
    try std.testing.expectEqual(provider.ir.Effort.high, reasoningFor(&model, "high", 8192).effort);
}

test "the stream cap rejects an oversized provider delta" {
    const max = wire.meta.limits.max_message_string_bytes;
    try checkStreamCap(0, max); // A delta up to the cap is allowed.
    try std.testing.expectError(error.ResponseTooLarge, checkStreamCap(0, max + 1));
    try std.testing.expectError(error.ResponseTooLarge, checkStreamCap(max, 1));
    try std.testing.expectError(error.ResponseTooLarge, checkStreamCap(max + 1, 0));
}
