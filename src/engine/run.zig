//! The run loop: one non-tool turn. Commit the user message, call the provider, fold the response, and
//! commit the assistant message. E1 uses an injected transport and the Anthropic provider only.

const std = @import("std");
const wire = @import("wire");
const provider = @import("../provider/provider.zig");
const database = @import("../database/database.zig");
const fold = @import("fold.zig");
const id = @import("../id.zig");

const Database = database.Database;
const session_store = database.session;
const message_store = database.message;
const event_store = database.event;
const transport = provider.transport;

// E1 targets one provider and a fixed output cap. E2 resolves both from the model binding.
const max_output_tokens: u32 = 8192;
const agent_name = "claude";
// A temporary full-transcript window. The compaction slice replaces it with a real context rule.
const max_transcript_messages: usize = 1000;

/// The run config, frozen at run start. A mid-run change applies to the next run.
pub const Config = struct {
    model: []const u8,
    config_rev: wire.ids.ConfigRev,
    system_prompt: []const u8,
};

/// Run one turn. `transport_impl` opens the provider stream: it has `open(arena, Request) !ResponseBody`.
/// The user input and the assembled messages borrow `arena`.
pub fn runTurn(
    db: *Database,
    io: std.Io,
    arena: std.mem.Allocator,
    session_id: [16]u8,
    input: []const wire.content.ContentPart,
    config: Config,
    transport_impl: anytype,
) !void {
    // Tx1: allocate the ids and commit the user message. The block scopes the rollback to the commit.
    const alloc = blk: {
        try db.conn.execNoArgs("BEGIN IMMEDIATE");
        errdefer db.conn.execNoArgs("ROLLBACK") catch {};
        const input_id = try event_store.allocInputId(db, arena, session_id);
        const run_id = try event_store.allocRunId(db, arena, session_id);
        const user_message_id = try event_store.allocMessageId(db, arena, session_id);
        const assistant_message_id = try event_store.allocMessageId(db, arena, session_id);
        const user_now = nowMillis(io);
        const user_message: wire.message.Message = .{ .user = .{
            .id = user_message_id,
            .content = input,
            .input_id = input_id,
            .time = .{ .created_at_ms = user_now },
        } };
        _ = try message_store.appendCommittedMessage(db, arena, session_id, newEventId(io), user_now, user_message);
        try db.conn.execNoArgs("COMMIT");
        break :blk .{ .run_id = run_id, .assistant_message_id = assistant_message_id };
    };

    // Build the request from the committed transcript, which now includes the user message.
    const transcript = (try message_store.historyPage(db, arena, session_id, 0, max_transcript_messages)).messages;
    const request_ir = try provider.build.build(arena, transcript, .{});
    var body: std.Io.Writer.Allocating = .init(arena);
    defer body.deinit();
    try provider.request_anthropic.serialize(&body.writer, .{
        .model = config.model,
        .system = config.system_prompt,
        .max_output_tokens = max_output_tokens,
    }, request_ir, .{});

    // Stream the response and fold it into an assistant message.
    var stream_body = try transport_impl.open(arena, .{ .body = body.written() });
    defer stream_body.deinit();
    var reducer = provider.anthropic.Reducer.init(arena);
    defer reducer.deinit();
    var events: std.ArrayList(provider.event.StreamEvent) = .empty;
    defer events.deinit(arena);
    try transport.drain(arena, arena, stream_body, &reducer, &events);

    const assistant_now = nowMillis(io);
    const assistant = try fold.assistant(arena, events.items, .{
        .id = alloc.assistant_message_id,
        .run_id = alloc.run_id,
        .config_rev = config.config_rev,
        .agent = agent_name,
        .created_at_ms = assistant_now,
        .model = config.model,
        .protocol = .@"anthropic-messages",
    });

    // Tx2: commit the assistant message.
    {
        try db.conn.execNoArgs("BEGIN IMMEDIATE");
        errdefer db.conn.execNoArgs("ROLLBACK") catch {};
        _ = try message_store.appendCommittedMessage(db, arena, session_id, newEventId(io), assistant_now, .{ .assistant = assistant });
        try db.conn.execNoArgs("COMMIT");
    }
}

/// Wall-clock milliseconds. Clamp a pre-1970 time to 0.
fn nowMillis(io: std.Io) u64 {
    return @intCast(@max(std.Io.Timestamp.now(io, .real).toMilliseconds(), 0));
}

/// Mint a fresh event id.
fn newEventId(io: std.Io) [16]u8 {
    var rand: [10]u8 = undefined;
    io.random(&rand);
    return id.v7(nowMillis(io), rand);
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
