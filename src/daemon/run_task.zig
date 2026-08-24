//! The daemon-side run coroutine. It streams one turn into a live Draft, broadcasts each delta, and commits
//! the reply. This uses a mock provider; the real streaming transport replaces it later.

const std = @import("std");
const wire = @import("wire");
const wss = @import("websocket").server;
const State = @import("State.zig");
const run = @import("../engine/run.zig");
const provider = @import("../provider/provider.zig");
const draft = @import("../domain/draft.zig");
const database = @import("../database/database.zig");

const ids = wire.ids;
const message = wire.message;
const message_store = database.message;
const event = provider.event;

const agent_name = "claude";
const max_output_tokens: u32 = 8192;
const max_transcript_messages: usize = 1000;

fn frame(comptime json: []const u8) []const u8 {
    return "data: " ++ json ++ "\n\n";
}

// A fixed mock reply. The real provider transport replaces it later.
const canned_reply =
    frame(
        \\{"type":"message_start","message":{"usage":{"input_tokens":0}}}
    ) ++ frame(
        \\{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}
    ) ++ frame(
        \\{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello from the yuke mock provider."}}
    ) ++ frame(
        \\{"type":"content_block_stop","index":0}
    ) ++ frame(
        \\{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":8}}
    ) ++ frame(
        \\{"type":"message_stop"}
    );

/// Run one turn to completion. The task is detached from the request. `config.model` is gpa-owned; free it.
pub fn runSession(state: *State, session_id: ids.SessionId, handle: run.RunHandle, config: run.Config) void {
    var arena_state = std.heap.ArenaAllocator.init(state.gpa);
    defer arena_state.deinit();
    defer state.gpa.free(config.model);

    streamTurn(state, arena_state.allocator(), session_id, handle, config) catch |err| {
        std.log.warn("run {d} did not finish: {t}", .{ handle.run_id, err });
    };
    clearActive(state, session_id);
}

/// Build the request, stream the reply into a Draft, broadcast each delta, then commit the reply.
fn streamTurn(state: *State, arena: std.mem.Allocator, session_id: ids.SessionId, handle: run.RunHandle, config: run.Config) !void {
    const transcript = (try message_store.historyPage(&state.db, arena, session_id.raw, 0, max_transcript_messages)).messages;
    const body = try provider.requestBody(arena, transcript, .{
        .model = config.model,
        .system = config.system_prompt,
        .max_output_tokens = max_output_tokens,
    });

    var mock = provider.transport.MockTransport.init(canned_reply, 0);
    var stream_body = try mock.open(arena, .{ .body = body });
    defer stream_body.deinit();

    const created_at = state.nowMillis();
    const started: message.MessageStartedData = .{
        .session_id = session_id,
        .message_id = handle.assistant_message_id,
        .run_id = handle.run_id,
        .config_rev = config.config_rev,
        .agent = agent_name,
        .created_at_ms = created_at,
    };
    var streamer: Streamer = .{
        .state = state,
        .session_id = session_id,
        .message_id = handle.assistant_message_id,
        .live = try draft.Draft.init(state.gpa, started),
    };
    defer streamer.live.deinit();
    defer streamer.offsets.deinit(state.gpa);
    try publish(state, session_id, .{ .method = .@"message.started", .params = .{ .message_started_data = started } });

    var reducer = provider.anthropic.Reducer.init(state.gpa);
    defer reducer.deinit();
    try provider.transport.stream(state.gpa, stream_body, &reducer, &streamer, Streamer.onEvent);

    // Build the committed message from the Draft, then commit it. Broadcast it after the commit.
    const active = try streamer.live.toActiveDraft(arena);
    const committed: message.Message = .{ .assistant = .{
        .id = handle.assistant_message_id,
        .run_id = handle.run_id,
        .config_rev = config.config_rev,
        .agent = agent_name,
        .content = active.message.content,
        .finish = streamer.stop_reason,
        .tokens = streamer.usage,
        .cost = null,
        .time = .{ .created_at_ms = created_at },
        .provenance = .{ .protocol = .@"anthropic-messages", .model = config.model },
    } };

    const committed_at = state.nowMillis();
    try state.db.conn.execNoArgs("BEGIN IMMEDIATE");
    errdefer state.db.conn.execNoArgs("ROLLBACK") catch {};
    const seq = try message_store.appendCommittedMessage(&state.db, arena, session_id.raw, state.newId(), committed_at, committed);
    try state.db.conn.execNoArgs("COMMIT");

    try publish(state, session_id, .{ .method = .@"message.committed", .params = .{ .message_committed_data = .{
        .session_id = session_id,
        .seq = seq,
        .message = committed,
    } } });
}

/// Maps each provider StreamEvent to a wire broadcast and folds it into the live Draft.
const Streamer = struct {
    state: *State,
    session_id: ids.SessionId,
    message_id: ids.MessageId,
    live: draft.Draft,
    offsets: std.ArrayListUnmanaged(u64) = .empty, // The streamed byte length of each part.
    open: usize = 0, // The count of blocks that started and did not stop.
    stop_reason: ?wire.enums.StopReason = null,
    usage: ?message.TokenUsage = null,

    fn onEvent(self: *Streamer, ev: event.StreamEvent) !void {
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
            .block_stopped => {
                // Drop the stop result. A reasoning signature and redacted data are not captured yet.
                if (self.open == 0) return error.Protocol; // a stop needs an open block
                self.open -= 1;
            },
            .done => |d| {
                if (self.open != 0) return error.Protocol; // done closes every block
                self.stop_reason = d.stop_reason;
                self.usage = d.usage;
            },
        }
    }

    fn partDelta(self: *Streamer, part_id: event.BlockId, text: []const u8) !void {
        const delta: message.PartDelta = .{
            .session_id = self.session_id,
            .message_id = self.message_id,
            .part_id = part_id,
            .delta = text,
            .offset = self.offsets.items[part_id],
        };
        const outcome = try self.live.applyPartDelta(delta);
        std.debug.assert(outcome == .applied); // the daemon sends the current offset, so it always appends
        self.offsets.items[part_id] += text.len;
        try publish(self.state, self.session_id, .{ .method = .@"message.part_delta", .params = .{ .message_part_delta_data = delta } });
    }
};

/// Build an empty streamed part of the block kind. A tool block is not supported yet.
fn emptyPart(part_id: event.BlockId, kind: event.BlockKind) !message.AssistantPart {
    return switch (kind) {
        .text => .{ .text = .{ .id = part_id, .text = "" } },
        .reasoning => .{ .reasoning = .{ .id = part_id, .text = "", .signature = "" } },
        .redacted_reasoning => .{ .redacted_reasoning = .{ .id = part_id, .data = "" } },
        .tool => error.ToolUnsupported,
    };
}

/// Clear the active run and reclaim the runtime once it is idle.
fn clearActive(state: *State, session_id: ids.SessionId) void {
    const rt = state.sessions.get(session_id) orelse return;
    rt.active = null;
    state.sessions.evictIfIdle(session_id);
}

/// Serialize a notification and fan it out to the session's subscribers. The registry copies the frame per
/// connection, so a short arena holds it and frees it at once.
fn publish(state: *State, session_id: ids.SessionId, note: wire.rpc.Notification) !void {
    var arena_state = std.heap.ArenaAllocator.init(state.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var body: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(note, .{ .emit_null_optional_fields = false }, &body.writer);
    var ws_frame: std.Io.Writer.Allocating = .init(arena);
    try wss.writeMessage(&ws_frame.writer, .text, body.written());
    state.registry.publish(session_id, ws_frame.written());
}
