//! The run loop: one non-tool turn. Commit the user message, call the provider, fold the response, and
//! commit the assistant message. This uses an injected transport and the Anthropic provider only.

const std = @import("std");
const wire = @import("wire");
const provider = @import("../provider/provider.zig");
const database = @import("../database/database.zig");
const fold = @import("fold.zig");
const util = @import("../util.zig");

const Database = database.Database;
const session_store = database.session;
const message_store = database.message;
const event_store = database.event;
const transport = provider.transport;

// This targets one provider and a fixed output cap. A later change resolves both from the model binding.
const max_output_tokens: u32 = 8192;
const agent_name = "claude";
// A temporary full-transcript window. A later context rule replaces it.
const max_transcript_messages: usize = 1000;

/// The run config, frozen at run start. A mid-run change applies to the next run.
pub const Config = struct {
    model: []const u8,
    config_rev: wire.ids.ConfigRev,
    system_prompt: []const u8,
};

/// The ids a started run owns. session.send_input returns run_id and input_id at once.
pub const RunHandle = struct {
    run_id: wire.ids.RunId,
    input_id: wire.ids.InputId,
    user_message_id: wire.ids.MessageId,
    assistant_message_id: wire.ids.MessageId,
};

/// Tx1: allocate the ids and commit the user message. The daemon runs this before it spawns the run,
/// so send_input returns the run id at once. `input` borrows `arena`.
pub fn beginTurn(
    db: *Database,
    io: std.Io,
    arena: std.mem.Allocator,
    session_id: [16]u8,
    input: []const wire.content.ContentPart,
) !RunHandle {
    try db.conn.execNoArgs("BEGIN IMMEDIATE");
    errdefer db.conn.execNoArgs("ROLLBACK") catch {};
    const handle: RunHandle = .{
        .input_id = try event_store.allocInputId(db, arena, session_id),
        .run_id = try event_store.allocRunId(db, arena, session_id),
        .user_message_id = try event_store.allocMessageId(db, arena, session_id),
        .assistant_message_id = try event_store.allocMessageId(db, arena, session_id),
    };
    const user_now = util.nowMillis(io);
    const user_message: wire.message.Message = .{ .user = .{
        .id = handle.user_message_id,
        .content = input,
        .input_id = handle.input_id,
        .time = .{ .created_at_ms = user_now },
    } };
    _ = try message_store.appendCommittedMessage(db, arena, session_id, util.newId(io), user_now, user_message);
    try db.conn.execNoArgs("COMMIT");
    return handle;
}

/// Build the request from the committed transcript, stream the reply, fold it, and commit it in Tx2.
/// The committed reply. `message` borrows `arena`, so the caller broadcasts it before it frees the arena.
pub const TurnResult = struct {
    seq: wire.ids.Seq,
    message: wire.message.Message,
};

/// The daemon runs this in the run coroutine. `handle` comes from `beginTurn`.
pub fn finishTurn(
    db: *Database,
    io: std.Io,
    arena: std.mem.Allocator,
    session_id: [16]u8,
    handle: RunHandle,
    config: Config,
    transport_impl: anytype,
) !TurnResult {
    const transcript = (try message_store.historyPage(db, arena, session_id, 0, max_transcript_messages)).messages;
    const body = try provider.requestBody(arena, transcript, .{
        .model = config.model,
        .system = config.system_prompt,
        .max_output_tokens = max_output_tokens,
    });

    // Stream the response and fold it into an assistant message.
    var stream_body = try transport_impl.open(arena, .{ .body = body });
    defer stream_body.deinit();
    var reducer = provider.anthropic.Reducer.init(arena);
    defer reducer.deinit();
    var events: std.ArrayList(provider.event.StreamEvent) = .empty;
    defer events.deinit(arena);
    try transport.drain(arena, arena, stream_body, &reducer, &events);

    const assistant_now = util.nowMillis(io);
    const assistant = try fold.assistant(arena, events.items, .{
        .id = handle.assistant_message_id,
        .run_id = handle.run_id,
        .config_rev = config.config_rev,
        .agent = agent_name,
        .created_at_ms = assistant_now,
        .model = config.model,
        .protocol = .@"anthropic-messages",
    });

    // Tx2: commit the assistant message.
    const message: wire.message.Message = .{ .assistant = assistant };
    try db.conn.execNoArgs("BEGIN IMMEDIATE");
    errdefer db.conn.execNoArgs("ROLLBACK") catch {};
    const seq = try message_store.appendCommittedMessage(db, arena, session_id, util.newId(io), assistant_now, message);
    try db.conn.execNoArgs("COMMIT");
    return .{ .seq = seq, .message = message };
}

/// Run one turn end to end. The engine test uses this; the daemon calls beginTurn then finishTurn.
pub fn runTurn(
    db: *Database,
    io: std.Io,
    arena: std.mem.Allocator,
    session_id: [16]u8,
    input: []const wire.content.ContentPart,
    config: Config,
    transport_impl: anytype,
) !void {
    const handle = try beginTurn(db, io, arena, session_id, input);
    _ = try finishTurn(db, io, arena, session_id, handle, config, transport_impl);
}

const testing = std.testing;
const zio = @import("zio");
const zqlite = @import("zqlite");
const workspace_store = database.workspace;

fn frame(comptime json: []const u8) []const u8 {
    return "data: " ++ json ++ "\n\n";
}

const canned_reply =
    frame(
        \\{"type":"message_start","message":{"usage":{"input_tokens":42}}}
    ) ++ frame(
        \\{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}
    ) ++ frame(
        \\{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hi there"}}
    ) ++ frame(
        \\{"type":"content_block_stop","index":0}
    ) ++ frame(
        \\{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":7}}
    ) ++ frame(
        \\{"type":"message_stop"}
    );

test "runTurn commits the user input and the folded assistant reply" {
    const rt = try zio.Runtime.init(testing.allocator, .{ .executors = .exact(1) });
    defer rt.deinit();
    const conn = try zqlite.open(":memory:", zqlite.OpenFlags.Create | zqlite.OpenFlags.NoMutex | zqlite.OpenFlags.EXResCode);
    var db = try Database.open(conn);
    defer db.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const ws = try workspace_store.resolve(&db, a, [_]u8{7} ** 16, "/w", "w", "/w");
    const sid = [_]u8{3} ** 16;
    try session_store.create(&db, .{
        .id = sid,
        .workspace_id = ws.id,
        .origin = "root",
        .profile = "default",
        .model = "opus",
        .reasoning = "high",
        .config_rev = 0,
        .permission = "normal",
        .title = "t",
        .created_at_ms = 100,
        .updated_at_ms = 100,
    });

    const input = [_]wire.content.ContentPart{.{ .text = .{ .text = "hello" } }};
    var mock = transport.MockTransport.init(canned_reply, 0);
    try runTurn(&db, rt.io(), a, sid, &input, .{ .model = "claude-opus-4-8", .config_rev = 0, .system_prompt = "" }, &mock);

    // The transcript now holds the user message then the assistant reply.
    const page = try message_store.historyPage(&db, a, sid, 0, 10);
    try testing.expectEqual(@as(usize, 2), page.messages.len);
    try testing.expectEqual(@as(u64, 1), page.messages[0].user.id); // ids start at 1
    try testing.expectEqual(@as(u64, 2), page.messages[1].assistant.id);
    try testing.expectEqualStrings("hi there", page.messages[1].assistant.content[0].text.text);
    try testing.expectEqual(@as(u64, 42), page.messages[1].assistant.tokens.?.input);

    // The session summary counts both messages and adds the assistant usage.
    const snap = (try session_store.snapshot(&db, a, sid)).?;
    try testing.expectEqual(@as(u64, 2), snap.message_count);
    try testing.expectEqual(@as(u64, 42), snap.usage_input_total);
    try testing.expectEqual(@as(u64, 7), snap.usage_output_total);

    // The run assembled a real request body carrying the model.
    try testing.expect(mock.captured != null);
    try testing.expect(std.mem.indexOf(u8, mock.captured.?, "claude-opus-4-8") != null);
}
