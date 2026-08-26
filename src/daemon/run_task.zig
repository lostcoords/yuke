//! Own daemon run tasks. Each round commits one assistant message. The final round also commits run.done.

const std = @import("std");
const wire = @import("wire");
const State = @import("State.zig");
const connection = @import("connection.zig");
const session_runtime = @import("session_runtime.zig");
const run = @import("../engine/run.zig");
const provider = @import("../provider/provider.zig");
const draft = @import("../domain/draft.zig");
const Session = @import("../domain/session.zig").Session;
const database = @import("../database/database.zig");
const turn_context = @import("turn_context.zig");

const ids = wire.ids;
const message = wire.message;
const RunSlot = session_runtime.RunSlot;
const message_store = database.message;
const run_store = database.run;
const session_store = database.session;
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
    // The caller already folded and published run.started. This spawns the run task.
    const run_id = slot.handle.started.run_id;
    const session_id = slot.handle.started.session_id;
    slot.phase = .running;
    state.run_group.concurrent(state.io, runSession, .{ state, slot }) catch |err| {
        std.log.err("cannot launch run {d}: {t}", .{ run_id, err });
        // The run task never ran, so set the round timestamp here before the commit.
        slot.progress.current.?.created_at_ms = @max(state.nowMillis(), slot.handle.started.started_at_ms);
        var terminal_arena = std.heap.ArenaAllocator.init(state.gpa);
        defer terminal_arena.deinit();
        commitRound(state, terminal_arena.allocator(), slot, null, null, .{ .failed = .{
            .code = .internal,
            .message = "the daemon could not launch the run task",
        } }, .final) catch |terminal_err| faultSlot(state, session_id, slot, terminal_err);
        finishSlot(state, session_id, slot);
        return err;
    };
}

/// Run one turn. The State task group owns this task. The session owns `slot` until cleanup.
fn runSession(state: *State, slot: *RunSlot) void {
    const session_id = slot.handle.started.session_id;
    defer finishSlot(state, session_id, slot);

    const rt = state.sessions.get(session_id) orelse unreachable;
    std.debug.assert(rt.active == slot);

    var arena_state = std.heap.ArenaAllocator.init(state.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const created_at = state.nowMillis();
    std.debug.assert(slot.progress.current != null); // bind opened round 1
    const round = &slot.progress.current.?;
    round.created_at_ms = created_at;
    const started: message.MessageStartedData = .{
        .session_id = session_id,
        .message_id = round.message_id,
        .run_id = slot.handle.started.run_id,
        .config_rev = slot.handle.started.config_rev,
        .agent = agent_name,
        .created_at_ms = created_at,
    };

    // The session owns the live draft. A synchronous resync can read it from the runtime.
    std.debug.assert(rt.session.active == null); // one draft per session at a time
    const started_note: wire.rpc.Notification = .{ .method = .@"message.started", .params = .{ .message_started_data = started } };
    // Fold the start into the session, then publish the same value. The fold opens the draft.
    rt.session.applyAuthoritative(started_note.params) catch |err| {
        commitRound(state, arena, slot, null, null, .{ .failed = failure(err) }, .final) catch |terminal_err| {
            faultSlot(state, session_id, slot, terminal_err);
        };
        return;
    };
    // Clear the draft before finishSlot drains a queued run. A later commit fold may null it first.
    defer if (rt.session.active != null) {
        rt.session.active.?.deinit();
        rt.session.active = null;
    };
    const live = &rt.session.active.?;
    var streamer: Streamer = .{
        .state = state,
        .slot = slot,
        .session = &rt.session,
    };
    defer streamer.offsets.deinit(state.gpa);
    publishBestEffort(state, session_id, started_note);

    // Load the model context once for the turn. Later rounds append to it in memory.
    var ctx = turn_context.TurnContext.load(arena, &state.db, session_id.raw, context_budget, max_transcript_messages) catch |err| {
        const term: Terminal = if (slot.cancel_requested) .canceled else .{ .failed = failure(err) };
        commitRound(state, arena, slot, live, streamer.usage, term, .final) catch |terminal_err| {
            faultSlot(state, session_id, slot, terminal_err);
        };
        return;
    };

    // Stream on a child task and wait for it or a cancel signal. The child owns the body.
    // Child cancellation stops a blocked read and deinits the body before this run reaches its terminal state.
    const terminal: Terminal = blk: {
        var reader = state.io.concurrent(streamChild, .{ state, arena, slot, &streamer, &ctx }) catch |err| {
            break :blk .{ .failed = failure(err) };
        };
        slot.wake_event.wait(state.io) catch {
            reader.cancel(state.io) catch {}; // Shutdown canceled this run task; stop the reader.
            break :blk .canceled;
        };
        if (slot.cancel_requested) {
            reader.cancel(state.io) catch {}; // Request cancellation, then join the reader.
            break :blk .canceled;
        }
        const result = reader.await(state.io);
        if (result) |_| {
            if (slot.cancel_requested) break :blk .canceled;
            break :blk .{ .success = streamer.stop_reason orelse {
                break :blk .{ .failed = .{ .code = .protocol, .message = "the provider stream has no stop reason" } };
            } };
        } else |err| {
            if (err == error.Canceled or slot.cancel_requested) break :blk .canceled;
            break :blk .{ .failed = failure(err) };
        }
    };

    commitRound(state, arena, slot, live, streamer.usage, terminal, .final) catch |err| {
        faultSlot(state, session_id, slot, err);
    };
}

/// Open the response and stream it into the draft. The run task uses a child so cancellation can interrupt a blocked read.
/// The child owns the body and deinits it before it returns.
fn streamChild(state: *State, arena: std.mem.Allocator, slot: *RunSlot, streamer: *Streamer, ctx: *const turn_context.TurnContext) !void {
    defer slot.wake_event.set(state.io);
    try checkCanceled(state.io, slot);
    const transcript = ctx.slice();
    const model = slot.config.model;

    const resolved = if (state.providers) |*p| provider.config.resolveModel(p, model) else null;
    // A daemon with providers rejects an unknown model. A daemon without providers uses the placeholder transport.
    if (resolved == null and state.providers != null) return error.UnknownModel;
    const request = if (resolved) |r| try resolvedRequest(state, arena, slot, transcript, r) else fallback: {
        // The fallback uses the injected or placeholder transport.
        break :fallback provider.transport.Request{ .body = try provider.requestBody(arena, transcript, .@"anthropic-messages", .{
            .model = model,
            .system = slot.config.system_prompt,
            .max_output_tokens = max_output_tokens,
        }, .{ .protocol = .@"anthropic-messages", .model = model }) };
    };

    const body = try state.transport.open(arena, request);
    std.debug.assert(slot.body == null); // one body per run
    slot.body = body;
    defer {
        slot.body = null;
        body.deinit();
    }
    try checkCanceled(state.io, slot);
    try streamWithReducer(state, body, streamer, slot.protocol);
}

/// Build the real provider request. It sets the run protocol, the endpoint URL, and the auth headers.
fn resolvedRequest(
    state: *State,
    arena: std.mem.Allocator,
    slot: *RunSlot,
    transcript: []const wire.message.Message,
    r: provider.config.Resolved,
) !provider.transport.Request {
    slot.protocol = r.provider.protocol;
    const body_bytes = try provider.requestBody(arena, transcript, r.provider.protocol, .{
        .model = r.binding.upstream_id,
        .system = slot.config.system_prompt,
        .max_output_tokens = std.math.cast(u32, r.binding.limits.max_output_tokens) orelse max_output_tokens,
    }, .{ .protocol = r.provider.protocol, .model = slot.config.model });

    const secret = try provider.config.resolveApiKey(r.provider, state.env);
    var auth: std.ArrayList(provider.transport.Header) = .empty;
    try provider.resolve.authHeaders(arena, r.provider, secret, &auth);

    return .{
        .url = try provider.resolve.endpointUrl(arena, r.provider),
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

/// Map a run failure to a wire error code and one short sentence. The wire message exposes no
/// internal error name. Each message stays well under `wire.meta.limits.max_error_message_bytes`.
fn failure(err: anyerror) Failure {
    return switch (err) {
        error.OutOfMemory => .{ .code = .internal, .message = "the daemon ran out of memory" },
        error.UnknownModel => .{ .code = .unknown_model, .message = "the model is not configured" },
        error.AuthFailed => .{ .code = .auth, .message = "the provider rejected the API key" },
        error.PermissionDenied => .{ .code = .auth, .message = "the provider denied permission for this request" },
        error.RateLimited => .{ .code = .rate_limited, .message = "the provider rate limit was reached" },
        error.QuotaExhausted => .{ .code = .quota_exhausted, .message = "the provider account quota is exhausted" },
        error.Timeout => .{ .code = .timeout, .message = "the provider stream timed out" },
        error.ServerError => .{ .code = .provider, .message = "the provider returned a server error" },
        error.BadStatus => .{ .code = .provider, .message = "the provider returned an unexpected status" },
        error.BadUrl => .{ .code = .provider, .message = "the provider endpoint URL is invalid" },
        error.RedirectRefused => .{ .code = .protocol, .message = "the provider attempted a redirect" },
        error.IncompleteStream, error.Protocol, error.InvalidCharacter, error.HttpChunkTruncated, error.HttpChunkInvalid => .{ .code = .protocol, .message = "the provider stream was malformed" },
        error.ConnectionRefused, error.ConnectionResetByPeer, error.EndOfStream => .{ .code = .network, .message = "the provider connection failed" },
        else => .{ .code = .provider, .message = "the provider request failed" },
    };
}

/// A round is intermediate (a tool round; the run continues) or final (the run ends).
const RoundCompletion = enum { intermediate, final };

/// Commit the current round's assistant message. A final round also appends run.done in the same
/// transaction, emits it after COMMIT, and terminalizes the slot. An intermediate round keeps the run
/// open (phase `.running`).
fn commitRound(
    state: *State,
    arena: std.mem.Allocator,
    slot: *RunSlot,
    live: ?*const draft.Draft,
    usage: ?message.TokenUsage,
    terminal: Terminal,
    completion: RoundCompletion,
) !void {
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
        .run_id = slot.handle.started.run_id,
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
    const session_id = slot.handle.started.session_id;

    try state.db.conn.execNoArgs("BEGIN IMMEDIATE");
    errdefer state.db.conn.execNoArgs("ROLLBACK") catch {};
    const seq = try message_store.appendCommittedMessage(&state.db, arena, session_id.raw, state.newId(), ended_at, owned);
    const done: ?wire.run.RunDoneData = if (completion == .final) try run_store.appendOpenDone(&state.db, arena, state.newId(), ended_at, .{
        .session_id = session_id,
        .seq = 0,
        .run_id = slot.handle.started.run_id,
        .kind = slot.handle.started.kind,
        .timing = .{ .started_at_ms = slot.handle.started.started_at_ms, .ended_at_ms = ended_at },
        .outcome = outcome,
    }) else null;
    try state.db.conn.execNoArgs("COMMIT");
    if (completion == .final) slot.phase = .terminalized;

    const rt = state.sessions.get(session_id) orelse unreachable;
    emitDurable(state, rt, .{ .method = .@"message.committed", .params = .{
        .message_committed_data = .{ .session_id = session_id, .seq = seq, .message = owned },
    } });
    if (done) |run_done| emitDurable(state, rt, .{ .method = .@"run.done", .params = .{ .run_done_data = run_done } });
}

/// Preserve the open marker when Tx2 fails. Startup recovery closes the durable obligation.
fn faultSlot(state: *State, session_id: ids.SessionId, slot: *RunSlot, err: anyerror) void {
    slot.phase = .faulted;
    if (state.sessions.get(session_id)) |rt| rt.faulted = true;
    std.log.err("run {d} could not commit its terminal state: {t}", .{ slot.handle.started.run_id, err });
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
    const slot = try RunSlot.prepare(state.gpa, snapshot.model, prompt orelse "");
    errdefer slot.destroy();
    const started = try run.beginQueuedTurn(&state.db, state.io, arena, session_id.raw, snapshot.config_rev);
    slot.bind(started.handle, started.first_round);
    // Fold each durable event in sequence order: the drained user messages, then run.started.
    // The commit fold retires each drained input from the queue.
    publishUserCommits(state, rt, started.user_commits);
    std.debug.assert(rt.session.queue.depth() == 0);
    rt.active = slot;
    emitDurable(state, rt, .{ .method = .@"run.started", .params = .{ .run_started_data = started.handle.started } });
    return slot;
}

/// Resume durable queue entries before the daemon accepts new connections.
pub fn resumePendingInputs(state: *State) !void {
    var arena_state = std.heap.ArenaAllocator.init(state.gpa);
    defer arena_state.deinit();
    const session_ids = try database.input.sessionIds(&state.db, arena_state.allocator());
    for (session_ids) |raw| {
        const session_id = ids.SessionId.bytes(raw);
        const rt = state.sessions.get(session_id) orelse return error.CorruptRuntime;
        if (rt.active == null and rt.session.queue.depth() > 0) try startQueued(state, rt);
    }
}

fn checkCanceled(io: std.Io, slot: *const RunSlot) !void {
    try io.checkCancel();
    if (slot.cancel_requested) return error.Canceled;
}

/// Map each provider StreamEvent to a canonical broadcast. Fold it into the session, then publish it.
/// The reducer is the peer boundary. It emits dense, ordered, kind-checked events. So the fold trusts them.
const Streamer = struct {
    state: *State,
    slot: *RunSlot,
    session: *Session,
    offsets: std.ArrayList(u64) = .empty,
    open: usize = 0,
    stop_reason: ?wire.enums.StopReason = null,
    usage: ?message.TokenUsage = null,

    /// Fold the canonical value first, then publish the same value. The daemon never folds its own output.
    fn emit(self: *Streamer, note: wire.rpc.Notification) !void {
        try self.session.applyAuthoritative(note.params);
        try publish(self.state, self.slot.handle.started.session_id, note);
    }

    fn onEvent(self: *Streamer, ev: event.StreamEvent) !void {
        // Check cancellation after each SSE event.
        try checkCanceled(self.state.io, self.slot);
        switch (ev) {
            .block_started => |b| {
                try self.emit(.{ .method = .@"message.part_added", .params = .{ .message_part_added_data = .{
                    .session_id = self.slot.handle.started.session_id,
                    .message_id = self.slot.progress.current.?.message_id,
                    .part = try emptyPart(b.block, b.kind),
                } } });
                try self.offsets.append(self.state.gpa, 0);
                self.open += 1;
            },
            .text_delta => |d| try self.partDelta(d.block, d.text),
            .reasoning_delta => |d| try self.partDelta(d.block, d.text),
            .tool_input_delta => return error.ToolUnsupported,
            .block_stopped => |b| {
                if (self.open == 0) return error.Protocol;
                self.open -= 1;
                switch (b.result) {
                    .reasoning => |r| try self.emitFinalized(b.block, .{ .reasoning = .{ .signature = r.signature } }),
                    .redacted_reasoning => |r| try self.emitFinalized(b.block, .{ .redacted_reasoning = .{ .data = r.data } }),
                    .text, .tool => {},
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
            .session_id = self.slot.handle.started.session_id,
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
            .session_id = self.slot.handle.started.session_id,
            .message_id = self.slot.progress.current.?.message_id,
            .part_id = part_id,
            .final = final,
        } } });
    }
};

/// Reject a provider payload that would exceed the stream cap. This is peer input. Return an error.
fn checkStreamCap(offset: u64, len: usize) error{ResponseTooLarge}!void {
    const cap: u64 = @intCast(wire.meta.limits.max_message_string_bytes);
    if (offset > cap or len > cap - offset) return error.ResponseTooLarge;
}

fn emptyPart(part_id: event.BlockId, kind: event.BlockKind) !message.AssistantPart {
    return switch (kind) {
        .text => .{ .text = .{ .id = part_id, .text = "" } },
        .reasoning => .{ .reasoning = .{ .id = part_id, .text = "", .signature = "" } },
        .redacted_reasoning => .{ .redacted_reasoning = .{ .id = part_id, .data = "" } },
        .tool => error.ToolUnsupported,
    };
}

/// Fold a durable daemon event into the session, then publish the same value. The daemon never folds its output.
/// The session sequence must track the store. A fold failure leaves the cache behind the log, so fail fast.
/// A restart rehydrates the projection from SQLite, which stays authoritative.
pub fn emitDurable(state: *State, rt: *session_runtime.SessionRuntime, note: wire.rpc.Notification) void {
    rt.session.applyAuthoritative(note.params) catch |err| {
        std.debug.panic("cannot fold the durable event {t}: {t}", .{ note.method, err });
    };
    publishBestEffort(state, rt.session.id, note);
}

/// Fold and publish each committed user message. A publish failure leaves the durable event for client resync.
pub fn publishUserCommits(state: *State, rt: *session_runtime.SessionRuntime, commits: []const wire.message.MessageCommittedData) void {
    for (commits) |c| emitDurable(state, rt, .{ .method = .@"message.committed", .params = .{ .message_committed_data = c } });
}

pub fn publishBestEffort(state: *State, session_id: ids.SessionId, note: wire.rpc.Notification) void {
    publish(state, session_id, note) catch |err| {
        std.log.warn("cannot publish {t}: {t}", .{ note.method, err });
    };
}

fn publish(state: *State, session_id: ids.SessionId, note: wire.rpc.Notification) !void {
    const bytes = try connection.frameNotification(state.gpa, note);
    defer state.gpa.free(bytes);
    if (state.broadcast_tap) |tap| try tap.record(note.params); // A conformance test records the published output.
    state.registry.publish(session_id, bytes, connection.classOf(note.method));
}

test "the stream cap rejects an oversized provider delta" {
    const max = wire.meta.limits.max_message_string_bytes;
    try checkStreamCap(0, max); // A delta up to the cap is allowed.
    try std.testing.expectError(error.ResponseTooLarge, checkStreamCap(0, max + 1));
    try std.testing.expectError(error.ResponseTooLarge, checkStreamCap(max, 1));
    try std.testing.expectError(error.ResponseTooLarge, checkStreamCap(max + 1, 0));
}
