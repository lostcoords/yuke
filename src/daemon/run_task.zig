//! Own daemon run tasks. Each exit commits one assistant message and one terminal run event.

const std = @import("std");
const zio = @import("zio");
const wire = @import("wire");
const State = @import("State.zig");
const connection = @import("connection.zig");
const session_runtime = @import("session_runtime.zig");
const run = @import("../engine/run.zig");
const provider = @import("../provider/provider.zig");
const draft = @import("../domain/draft.zig");
const database = @import("../database/database.zig");

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

/// Launch one prepared run.
pub fn launchSlot(state: *State, slot: *RunSlot) !void {
    std.debug.assert(slot.phase == .pending_start);
    if (!slot.started_published) {
        publishBestEffort(state, slot.handle.started.session_id, .{ .method = .@"run.started", .params = .{
            .run_started_data = slot.handle.started,
        } });
        slot.started_published = true;
    }
    const run_id = slot.handle.run_id;
    const session_id = slot.handle.started.session_id;
    slot.phase = .running;
    state.run_group.spawn(runSession, .{ state, slot }) catch |err| {
        std.log.err("cannot launch run {d}: {t}", .{ run_id, err });
        const created_at = @max(state.nowMillis(), slot.handle.started.started_at_ms);
        var terminal_arena = std.heap.ArenaAllocator.init(state.gpa);
        defer terminal_arena.deinit();
        terminalize(state, terminal_arena.allocator(), slot, created_at, null, null, .{ .failed = .{
            .code = .internal,
            .message = "the daemon could not launch the run task",
        } }) catch |terminal_err| faultSlot(state, session_id, slot, terminal_err);
        finishSlot(state, session_id, slot);
        return err;
    };
}

/// Run one turn. The State task group owns this task. The session owns `slot` until cleanup.
fn runSession(state: *State, slot: *RunSlot) void {
    const session_id = slot.handle.started.session_id;
    defer finishSlot(state, session_id, slot);

    var arena_state = std.heap.ArenaAllocator.init(state.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const created_at = state.nowMillis();
    const started: message.MessageStartedData = .{
        .session_id = session_id,
        .message_id = slot.handle.assistant_message_id,
        .run_id = slot.handle.run_id,
        .config_rev = slot.config.config_rev,
        .agent = agent_name,
        .created_at_ms = created_at,
    };

    var live = draft.Draft.init(state.gpa, started) catch |err| {
        terminalize(state, arena, slot, created_at, null, null, .{ .failed = failure(err) }) catch |terminal_err| {
            faultSlot(state, session_id, slot, terminal_err);
        };
        return;
    };
    defer live.deinit();
    var streamer: Streamer = .{
        .state = state,
        .slot = slot,
        .session_id = session_id,
        .message_id = slot.handle.assistant_message_id,
        .live = &live,
    };
    defer streamer.offsets.deinit(state.gpa);
    publishBestEffort(state, session_id, .{ .method = .@"message.started", .params = .{ .message_started_data = started } });

    // Stream on a child task and wait for it or a cancel signal. The child owns the body, so a
    // blocked read stops through child cancellation and the body deinits before this run terminalizes.
    const terminal: Terminal = blk: {
        var reader = zio.spawn(streamChild, .{ state, arena, slot, &streamer }) catch |err| {
            break :blk .{ .failed = failure(err) };
        };
        const winner = zio.select(.{ .reader = &reader, .cancel = &slot.cancel_event }) catch {
            reader.cancel(); // this run task was canceled at shutdown; stop the reader
            break :blk .canceled;
        };
        switch (winner) {
            .reader => {
                reader.join() catch |err| {
                    if (err == error.Canceled or slot.cancel_requested) break :blk .canceled;
                    break :blk .{ .failed = failure(err) };
                };
                if (slot.cancel_requested) break :blk .canceled;
                break :blk .{ .success = streamer.stop_reason orelse {
                    break :blk .{ .failed = .{ .code = .protocol, .message = "the provider stream has no stop reason" } };
                } };
            },
            .cancel => {
                reader.cancel(); // request cancellation and join the reader
                break :blk .canceled;
            },
        }
    };

    terminalize(state, arena, slot, created_at, &live, streamer.usage, terminal) catch |err| {
        faultSlot(state, session_id, slot, err);
    };
}

/// Open the response and stream it into the draft. The run task runs this as a child so a cancel can
/// interrupt a blocked read. The child owns the body and deinits it before it returns.
fn streamChild(state: *State, arena: std.mem.Allocator, slot: *RunSlot, streamer: *Streamer) !void {
    try checkCanceled(slot);
    const session_id = slot.handle.started.session_id;
    const transcript = (try message_store.historyPage(&state.db, arena, session_id.raw, 0, max_transcript_messages)).messages;
    const model = slot.config.model;

    const resolved = if (state.providers) |p| provider.config.resolveModel(p, model) else null;
    // A configured daemon rejects an unknown model. An unconfigured daemon uses the placeholder transport.
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
    try checkCanceled(slot);
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
    var auth: std.ArrayList(provider.instance.Header) = .empty;
    try provider.resolve.authHeaders(arena, r.provider, secret, &auth);
    const headers = try arena.alloc(provider.transport.Header, auth.items.len);
    for (auth.items, headers) |h, *out| out.* = .{ .name = h.name, .value = h.value };

    return .{
        .url = try provider.resolve.endpointUrl(arena, r.provider),
        .headers = headers,
        .body = body_bytes,
    };
}

/// Reduce the response stream with the reducer for `protocol`.
fn streamWithReducer(state: *State, body: provider.transport.ResponseBody, streamer: *Streamer, protocol: wire.enums.ProviderProtocol) !void {
    switch (protocol) {
        .@"anthropic-messages" => {
            var reducer = provider.anthropic.Reducer.init(state.gpa);
            defer reducer.deinit();
            try provider.transport.stream(state.gpa, body, &reducer, streamer, Streamer.onEvent);
        },
        .@"openai-completions" => {
            var reducer = provider.openai_chat.Reducer.init(state.gpa);
            defer reducer.deinit();
            try provider.transport.stream(state.gpa, body, &reducer, streamer, Streamer.onEvent);
        },
        .@"openai-responses" => {
            var reducer = provider.openai_responses.Reducer.init(state.gpa);
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

fn failure(err: anyerror) Failure {
    return switch (err) {
        error.OutOfMemory => .{ .code = .internal, .message = @errorName(err) },
        error.UnknownModel => .{ .code = .unknown_model, .message = @errorName(err) },
        error.AuthFailed => .{ .code = .auth, .message = @errorName(err) },
        error.RateLimited => .{ .code = .rate_limited, .message = @errorName(err) },
        error.Timeout => .{ .code = .timeout, .message = @errorName(err) },
        error.IncompleteStream, error.Protocol, error.InvalidCharacter, error.HttpChunkTruncated, error.HttpChunkInvalid => .{ .code = .protocol, .message = @errorName(err) },
        error.ConnectionRefused, error.ConnectionResetByPeer, error.EndOfStream => .{ .code = .network, .message = @errorName(err) },
        else => .{ .code = .provider, .message = @errorName(err) },
    };
}

fn terminalize(
    state: *State,
    arena: std.mem.Allocator,
    slot: *RunSlot,
    created_at: u64,
    live: ?*const draft.Draft,
    usage: ?message.TokenUsage,
    terminal: Terminal,
) !void {
    std.debug.assert(slot.phase == .running);
    std.debug.assert(slot.body == null);
    zio.beginShield();
    defer zio.endShield();

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
        .id = slot.handle.assistant_message_id,
        .run_id = slot.handle.run_id,
        .config_rev = slot.config.config_rev,
        .agent = agent_name,
        .content = content,
        .finish = finish,
        .tokens = usage,
        .cost = null,
        .time = .{ .created_at_ms = created_at, .completed_at_ms = ended_at },
        .@"error" = message_error,
        .provenance = .{ .protocol = slot.protocol, .model = slot.config.model },
    } };
    const outcome: wire.run.RunOutcome = switch (terminal) {
        .success => |reason| .{ .turn = .{ .finish = reason, .rounds = 1 } },
        .canceled => .{ .canceled = .{} },
        .failed => |item| .{ .failed = .{ .code = item.code, .message = item.message } },
    };

    try state.db.conn.execNoArgs("BEGIN IMMEDIATE");
    errdefer state.db.conn.execNoArgs("ROLLBACK") catch {};
    const seq = try message_store.appendCommittedMessage(
        &state.db,
        arena,
        slot.handle.started.session_id.raw,
        state.newId(),
        ended_at,
        committed,
    );
    const done = try run_store.appendOpenDone(&state.db, arena, state.newId(), ended_at, .{
        .session_id = slot.handle.started.session_id,
        .seq = 0,
        .run_id = slot.handle.run_id,
        .kind = slot.handle.started.kind,
        .timing = .{ .started_at_ms = slot.handle.started.started_at_ms, .ended_at_ms = ended_at },
        .outcome = outcome,
    });
    try state.db.conn.execNoArgs("COMMIT");
    slot.phase = .terminalized;

    publishBestEffort(state, slot.handle.started.session_id, .{ .method = .@"message.committed", .params = .{
        .message_committed_data = .{ .session_id = slot.handle.started.session_id, .seq = seq, .message = committed },
    } });
    publishBestEffort(state, slot.handle.started.session_id, .{ .method = .@"run.done", .params = .{
        .run_done_data = done,
    } });
}

/// Preserve the open marker when Tx2 fails. Startup recovery closes the durable obligation.
fn faultSlot(state: *State, session_id: ids.SessionId, slot: *RunSlot, err: anyerror) void {
    slot.phase = .faulted;
    if (state.sessions.get(session_id)) |rt| rt.faulted = true;
    std.log.err("run {d} could not commit its terminal state: {t}", .{ slot.handle.run_id, err });
}

fn finishSlot(state: *State, session_id: ids.SessionId, slot: *RunSlot) void {
    std.debug.assert(slot.body == null);
    std.debug.assert(slot.phase == .terminalized or slot.phase == .faulted);
    const rt = state.sessions.get(session_id) orelse unreachable;
    std.debug.assert(rt.active == slot);
    const can_drain = slot.phase == .terminalized and !state.shutting_down and !rt.faulted;
    rt.active = null;
    slot.destroy();

    if (can_drain and rt.queue.depth() > 0) {
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
    std.debug.assert(rt.queue.depth() > 0);

    var arena_state = std.heap.ArenaAllocator.init(state.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const snapshot = (try session_store.snapshot(&state.db, arena, rt.session_id.raw)) orelse return error.UnknownSession;
    const prompt = try session_store.prompt(&state.db, arena, rt.session_id.raw);
    const slot = try RunSlot.prepare(state.gpa, snapshot.model, prompt orelse "");
    errdefer slot.destroy();
    const handle = try run.beginQueuedTurn(&state.db, state.io, arena, rt.session_id.raw, snapshot.config_rev);
    slot.bind(handle);
    while (rt.queue.depth() > 0) {
        const input_id = rt.queue.entries()[0].input_id;
        std.debug.assert(rt.queue.retire(input_id) == .changed);
    }
    rt.active = slot;
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
        if (rt.active == null and rt.queue.depth() > 0) try startQueued(state, rt);
    }
}

fn checkCanceled(slot: *const RunSlot) !void {
    try zio.checkCancel();
    if (slot.cancel_requested) return error.Canceled;
}

/// Maps each provider StreamEvent to a wire broadcast and folds it into the live Draft.
const Streamer = struct {
    state: *State,
    slot: *RunSlot,
    session_id: ids.SessionId,
    message_id: ids.MessageId,
    live: *draft.Draft,
    offsets: std.ArrayList(u64) = .empty,
    open: usize = 0,
    stop_reason: ?wire.enums.StopReason = null,
    usage: ?message.TokenUsage = null,

    fn onEvent(self: *Streamer, ev: event.StreamEvent) !void {
        try checkCanceled(self.slot);
        try zio.maybeYield();
        try checkCanceled(self.slot);
        switch (ev) {
            .block_started => |b| {
                const added: message.MessagePartAddedData = .{
                    .session_id = self.session_id,
                    .message_id = self.message_id,
                    .part = try emptyPart(b.block, b.kind),
                };
                try self.live.addPart(added);
                try self.offsets.append(self.state.gpa, 0);
                self.open += 1;
                try publish(self.state, self.session_id, .{ .method = .@"message.part_added", .params = .{ .message_part_added_data = added } });
            },
            .text_delta => |d| try self.partDelta(d.block, d.text),
            .reasoning_delta => |d| try self.partDelta(d.block, d.text),
            .tool_input_delta => return error.ToolUnsupported,
            .block_stopped => |b| {
                if (self.open == 0) return error.Protocol;
                self.open -= 1;
                switch (b.result) {
                    .reasoning => |r| try self.live.finalizeReasoning(b.block, r.signature),
                    .redacted_reasoning => |r| try self.live.finalizeRedacted(b.block, r.data),
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
        const index = std.math.cast(usize, part_id) orelse return error.Protocol;
        if (index >= self.offsets.items.len) return error.Protocol;
        const delta: message.PartDelta = .{
            .session_id = self.session_id,
            .message_id = self.message_id,
            .part_id = part_id,
            .delta = text,
            .offset = self.offsets.items[index],
        };
        try applyProviderDelta(self.live, delta);
        self.offsets.items[index] += text.len;
        try publish(self.state, self.session_id, .{ .method = .@"message.part_delta", .params = .{ .message_part_delta_data = delta } });
    }
};

fn applyProviderDelta(live: *draft.Draft, delta: message.PartDelta) !void {
    const outcome = try live.applyPartDelta(delta);
    return switch (outcome) {
        .applied => {},
        .gap => error.ResponseTooLarge,
        .stale => error.Protocol,
    };
}

fn emptyPart(part_id: event.BlockId, kind: event.BlockKind) !message.AssistantPart {
    return switch (kind) {
        .text => .{ .text = .{ .id = part_id, .text = "" } },
        .reasoning => .{ .reasoning = .{ .id = part_id, .text = "", .signature = "" } },
        .redacted_reasoning => .{ .redacted_reasoning = .{ .id = part_id, .data = "" } },
        .tool => error.ToolUnsupported,
    };
}

pub fn publishBestEffort(state: *State, session_id: ids.SessionId, note: wire.rpc.Notification) void {
    publish(state, session_id, note) catch |err| {
        std.log.warn("cannot publish {t}: {t}", .{ note.method, err });
    };
}

fn publish(state: *State, session_id: ids.SessionId, note: wire.rpc.Notification) !void {
    const bytes = try connection.frameNotification(state.gpa, note);
    defer state.gpa.free(bytes);
    state.registry.publish(session_id, bytes, connection.classOf(note.method));
}

test "an oversized provider delta returns an error" {
    const started: message.MessageStartedData = .{
        .session_id = .bytes([_]u8{1} ** 16),
        .message_id = 1,
        .run_id = 1,
        .config_rev = 0,
        .agent = "test",
        .created_at_ms = 1,
    };
    var live = try draft.Draft.init(std.testing.allocator, started);
    defer live.deinit();
    try live.addPart(.{
        .session_id = started.session_id,
        .message_id = started.message_id,
        .part = .{ .text = .{ .id = 0, .text = "" } },
    });
    const oversized = try std.testing.allocator.alloc(u8, @as(usize, @intCast(wire.meta.limits.max_message_string_bytes)) + 1);
    defer std.testing.allocator.free(oversized);
    try std.testing.expectError(error.ResponseTooLarge, applyProviderDelta(&live, .{
        .session_id = started.session_id,
        .message_id = started.message_id,
        .part_id = 0,
        .delta = oversized,
        .offset = 0,
    }));
}
