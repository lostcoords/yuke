//! The daemon-side run coroutine. It runs one turn, commits the reply, and broadcasts message.committed
//! to the session's subscribers. This uses a mock provider; the real streaming transport replaces it later.

const std = @import("std");
const wire = @import("wire");
const wss = @import("websocket").server;
const State = @import("State.zig");
const run = @import("../engine/run.zig");
const transport = @import("../provider/transport.zig");

const ids = wire.ids;

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

/// Run one turn to completion, then broadcast the committed reply. The task is detached from the request
/// that started it. `config.model` is gpa-owned, so this frees it.
pub fn runSession(state: *State, session_id: ids.SessionId, handle: run.RunHandle, config: run.Config) void {
    var arena_state = std.heap.ArenaAllocator.init(state.gpa);
    defer arena_state.deinit();
    defer state.gpa.free(config.model);
    const arena = arena_state.allocator();

    var mock = transport.MockTransport.init(canned_reply, 0);
    const result = run.finishTurn(&state.db, state.io, arena, session_id, handle, config, &mock) catch |err| {
        std.log.warn("run {d} did not finish: {t}", .{ handle.run_id, err });
        clearActive(state, session_id);
        return;
    };

    publishCommitted(state, arena, session_id, result) catch |err| {
        std.log.warn("broadcast for run {d} failed: {t}", .{ handle.run_id, err });
    };
    clearActive(state, session_id);
}

/// Clear the active run and reclaim the runtime once it is idle.
fn clearActive(state: *State, session_id: ids.SessionId) void {
    const rt = state.sessions.get(session_id) orelse return;
    rt.active = null;
    state.sessions.evictIfIdle(session_id);
}

/// Serialize the message.committed notification and fan it out to the session's subscribers.
fn publishCommitted(state: *State, arena: std.mem.Allocator, session_id: ids.SessionId, result: run.TurnResult) !void {
    const note: wire.rpc.Notification = .{ .method = .@"message.committed", .params = .{ .message_committed_data = .{
        .session_id = session_id,
        .seq = result.seq,
        .message = result.message,
    } } };
    var body: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(note, .{ .emit_null_optional_fields = false }, &body.writer);
    var ws_frame: std.Io.Writer.Allocating = .init(arena);
    try wss.writeMessage(&ws_frame.writer, .text, body.written());
    state.registry.publish(session_id, ws_frame.written());
}
