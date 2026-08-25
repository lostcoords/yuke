//! Accept HTTP connections and dispatch requests.
//! A proxy terminates TLS before remote clients connect.

const std = @import("std");
const zio = @import("zio");
const wire = @import("wire");
const wss = @import("websocket").server;
const rpc = @import("rpc.zig");
const State = @import("State.zig");
const Connection = @import("connection.zig").Connection;
const run_task = @import("run_task.zig");

// Limit each request head to 64 KiB. The decoder rejects a larger head.
const max_head_bytes = 64 * 1024;
const write_buffer_bytes = 4096;
// Use the wire frame limit as the bound for each WebSocket message.
// The wire frame limit is the only source of truth.
const max_ws_message_bytes: usize = @intCast(wire.meta.limits.max_frame_bytes);

const text_plain = [_]std.http.Header{
    .{ .name = "content-type", .value = "text/plain; charset=utf-8" },
};

/// Accept connections forever. Run each connection in its own task.
pub fn serve(state: *State) !void {
    try run_task.resumePendingInputs(state);
    const listener = try state.config.listen.listen(.{});
    defer listener.close();
    std.log.info("front door on http://{f}", .{listener.socket.address});

    var group: zio.Group = .init;
    defer group.cancel();

    while (true) {
        const stream = try listener.accept(.{});
        errdefer stream.close();
        try group.spawn(handleConnection, .{ state, stream });
    }
}

fn handleConnection(state: *State, stream: zio.net.Stream) !void {
    defer stream.close();
    dispatch(state, stream) catch |err| switch (err) {
        // Treat a clean keep-alive close, a dropped client, or shutdown as normal.
        error.HttpConnectionClosing, error.HttpRequestTruncated, error.Canceled => return,
        else => return err,
    };
}

fn dispatch(state: *State, stream: zio.net.Stream) !void {
    var head_buffer: [max_head_bytes]u8 = undefined;
    var reader = stream.reader(&head_buffer);
    var write_buffer: [write_buffer_bytes]u8 = undefined;
    var writer = stream.writer(&write_buffer);
    var server = std.http.Server.init(&reader.interface, &writer.interface);

    while (true) {
        var request = server.receiveHead() catch |err| switch (err) {
            error.ReadFailed => return reader.err orelse err,
            else => |e| return e,
        };
        if (request.head.method == .GET and std.mem.eql(u8, request.head.target, "/ws")) {
            switch (request.upgradeRequested()) {
                .websocket => |maybe_key| {
                    const key = maybe_key orelse return badRequest(&request);
                    if (!validUpgrade(&request, key)) return badRequest(&request);
                    return serveWebSocket(state, &request, key);
                },
                else => {},
            }
        }
        try route(&request);
        if (!request.head.keep_alive) {
            try stream.shutdown(.both);
            return;
        }
    }
}

const ReaderTask = zio.JoinHandle(anyerror!void);
const WriterTask = zio.JoinHandle(void);
const close_drain_timeout = zio.Timeout.fromMilliseconds(250);

/// Track the persistent close signal and terminal drain state.
const WebSocketLifecycle = struct {
    close: zio.ResetEvent = .init,
    // The daemon runtime uses one executor. The parent reads this after close wakes it.
    terminal_close_queued: bool = false,
};

/// Serve one WebSocket. Reader and writer tasks own socket.input and socket.output respectively.
/// This function supervises and owns both task handles.
fn serveWebSocket(state: *State, request: *std.http.Server.Request, key: []const u8) !void {
    var socket = try request.respondWebSocket(.{ .key = key });
    try socket.output.flush();

    var conn: Connection = undefined;
    conn.init(state.gpa);
    defer conn.deinit();

    var lifecycle: WebSocketLifecycle = .{};
    conn.setTeardown(&lifecycle.close, signalWebSocketClose);
    try state.registry.register(&conn);
    defer state.registry.unregister(&conn); // The defer runs before `conn.deinit`, so no publish targets a dead outbox.

    var reader = try zio.spawn(readerTask, .{ state, &conn, socket.input, &lifecycle });
    errdefer reader.cancel();

    var writer = try zio.spawn(writerTask, .{ &conn, socket.output, &lifecycle });

    superviseWebSocket(&reader, &writer, &lifecycle, close_drain_timeout);
    reader.cancel();
    writer.cancel();
}

/// Signal the persistent close event when the registry closes a connection.
fn signalWebSocketClose(context: *anyopaque) void {
    const close: *zio.ResetEvent = @ptrCast(@alignCast(context));
    close.set();
}

/// Wait for the first terminal condition. The parent owns all cancellation and joins.
fn superviseWebSocket(
    reader: *ReaderTask,
    writer: *WriterTask,
    lifecycle: *WebSocketLifecycle,
    drain_timeout: zio.Timeout,
) void {
    const result = zio.select(.{
        .reader = reader,
        .writer = writer,
        .close = &lifecycle.close,
    }) catch return;

    switch (result) {
        .reader, .close => if (lifecycle.terminal_close_queued) {
            _ = zio.select(.{
                .writer = writer,
                .timeout = drain_timeout,
            }) catch {};
        },
        .writer => {},
    }
}

/// Read WebSocket frames and signal teardown on exit.
fn readerTask(
    state: *State,
    conn: *Connection,
    input: *std.Io.Reader,
    lifecycle: *WebSocketLifecycle,
) anyerror!void {
    defer {
        conn.outbox.close(.graceful);
        lifecycle.close.set();
    }
    lifecycle.terminal_close_queued = try readerLoop(state, conn, input);
}

/// Write queued WebSocket frames and signal teardown on exit.
fn writerTask(conn: *Connection, output: *std.Io.Writer, lifecycle: *WebSocketLifecycle) void {
    defer {
        conn.outbox.close(.graceful);
        lifecycle.close.set();
    }
    writerLoop(conn, output);
}

/// Drain the outbox to socket.output. Stop after a terminal close frame. The task owns socket.output.
fn writerLoop(conn: *Connection, output: *std.Io.Writer) void {
    while (true) {
        const item = conn.outbox.receive() catch return; // closed and drained
        defer conn.gpa.free(item.bytes);
        // A stuck peer can block this write indefinitely. A proxy deadline or task cancel frees it.
        output.writeAll(item.bytes) catch return;
        output.flush() catch return;
        if (item.terminal) return;
        // The outbox is empty. Send a resync marker for newly reported dropped deltas.
        if (conn.outbox.isEmpty()) flushShedMarkers(conn, output) catch return;
    }
}

/// Frame the queued resync markers, then write them to the socket in one pass.
fn flushShedMarkers(conn: *Connection, output: *std.Io.Writer) !void {
    var buf: std.Io.Writer.Allocating = .init(conn.gpa);
    defer buf.deinit();
    try conn.drainShedMarkers(&buf.writer);
    if (buf.written().len == 0) return;
    try output.writeAll(buf.written());
    try output.flush();
}

/// Decode client frames and enqueue framed replies, pongs, and closes. Give all socket writes to the writer task.
fn readerLoop(state: *State, conn: *Connection, input: *std.Io.Reader) !bool {
    const gpa = state.gpa;
    var reader: wss.MessageReader = .init(max_ws_message_bytes);
    defer reader.deinit(gpa);

    while (true) {
        var message = reader.next(gpa, input) catch |err| switch (err) {
            error.EndOfStream => return false,
            error.MessageTooBig, error.FrameTooBig => return enqueueClose(conn, .message_too_big),
            error.InvalidUtf8 => return enqueueClose(conn, .invalid_frame_payload_data),
            error.Unmasked,
            error.ReservedBitSet,
            error.UnrecognizedOpcode,
            error.ControlFrameFragmented,
            error.ControlFrameTooBig,
            error.NonMinimalLength,
            error.BadClose,
            error.InvalidContinuation,
            error.Interrupted,
            => return enqueueClose(conn, .protocol_error),
            else => return err,
        };
        defer message.deinit(gpa);
        switch (message.opcode) {
            // Wire frames carry text JSON. Treat a binary frame as a protocol error.
            .text => {
                const reply = try frameReply(state, conn, gpa, message.data);
                var launch = reply.launch;
                defer run_task.Launch.release(&launch, state);
                if (reply.terminal) {
                    return conn.tryEnqueue(.{ .bytes = reply.bytes, .terminal = true });
                }
                try conn.send(.{ .bytes = reply.bytes });
            },
            .binary => return enqueueClose(conn, .unsupported_data),
            .ping => try conn.send(.{ .bytes = try framePong(gpa, message.data) }),
            .connection_close => {
                const parsed = wss.checkedClose(message.data) catch return enqueueClose(conn, .protocol_error);
                const echo = if (parsed.code == .no_status_rcvd) .normal_closure else parsed.code;
                return enqueueClose(conn, echo);
            },
            .pong => continue,
            // MessageReader resolves continuations to the message opcode.
            .continuation => unreachable,
        }
    }
}

const FramedReply = struct { bytes: []u8, terminal: bool, launch: ?run_task.Launch };

/// Frame one wire reply as WS bytes. handleRequest writes the frame. A close outcome ends the connection.
fn frameReply(state: *State, conn: *Connection, gpa: std.mem.Allocator, data: []const u8) !FramedReply {
    var buf: std.Io.Writer.Allocating = .init(gpa);
    errdefer buf.deinit();
    const reply = try rpc.handleRequest(state, conn, &buf.writer, data);
    var launch = reply.launch;
    errdefer run_task.Launch.release(&launch, state);
    return .{ .bytes = try buf.toOwnedSlice(), .terminal = reply.outcome == .close, .launch = launch };
}

/// Frame a pong that echoes the ping payload.
fn framePong(gpa: std.mem.Allocator, payload: []const u8) ![]u8 {
    var buf: std.Io.Writer.Allocating = .init(gpa);
    errdefer buf.deinit();
    try wss.writePong(&buf.writer, payload);
    return buf.toOwnedSlice();
}

/// Enqueue a terminal close frame with the code.
fn enqueueClose(conn: *Connection, code: wss.CloseCode) !bool {
    var buf: std.Io.Writer.Allocating = .init(conn.gpa);
    errdefer buf.deinit();
    try wss.writeClose(&buf.writer, code);
    return conn.tryEnqueue(.{ .bytes = try buf.toOwnedSlice(), .terminal = true });
}

/// Validate handshake fields that `upgradeRequested` leaves unchecked.
fn validUpgrade(request: *std.http.Server.Request, key: []const u8) bool {
    if (!validKey(key)) return false;

    var has_connection_upgrade = false;
    var has_version_13 = false;
    var it = request.iterateHeaders();
    while (it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "connection")) {
            if (headerHasToken(header.value, "upgrade")) has_connection_upgrade = true;
        } else if (std.ascii.eqlIgnoreCase(header.name, "sec-websocket-version")) {
            if (std.mem.eql(u8, std.mem.trim(u8, header.value, " \t"), "13")) has_version_13 = true;
        }
    }
    return has_connection_upgrade and has_version_13;
}

/// Return true when a comma-separated header value contains the token.
fn headerHasToken(value: []const u8, token: []const u8) bool {
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |part| {
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, part, " \t"), token)) return true;
    }
    return false;
}

/// Return true when `Sec-WebSocket-Key` decodes to exactly 16 bytes.
fn validKey(key: []const u8) bool {
    var decoded: [16]u8 = undefined;
    const len = std.base64.standard.Decoder.calcSizeForSlice(key) catch return false;
    if (len != decoded.len) return false;
    std.base64.standard.Decoder.decode(&decoded, key) catch return false;
    return true;
}

test headerHasToken {
    try std.testing.expect(headerHasToken("keep-alive, Upgrade", "upgrade"));
    try std.testing.expect(headerHasToken("Upgrade", "upgrade"));
    try std.testing.expect(!headerHasToken("keep-alive", "upgrade"));
    try std.testing.expect(!headerHasToken("upgraded", "upgrade"));
}

test validKey {
    try std.testing.expect(validKey("dGhlIHNhbXBsZSBub25jZQ=="));
    try std.testing.expect(!validKey("dGhlIHNhbXBsZQ=="));
    try std.testing.expect(!validKey("################========"));
    try std.testing.expect(!validKey(""));
}

fn badRequest(request: *std.http.Server.Request) !void {
    return request.respond("bad request\n", .{ .status = .bad_request, .extra_headers = &text_plain });
}

/// Route the health check and the root page. Return 404 for other requests.
fn route(request: *std.http.Server.Request) !void {
    const target = request.head.target;
    if (request.head.method == .GET and std.mem.eql(u8, target, "/up")) {
        return request.respond("ok\n", .{ .extra_headers = &text_plain });
    }
    if (request.head.method == .GET and std.mem.eql(u8, target, "/")) {
        return request.respond("yuke daemon\n", .{ .extra_headers = &text_plain });
    }
    return request.respond("not found\n", .{ .status = .not_found, .extra_headers = &text_plain });
}

const testing = std.testing;
const zqlite = @import("zqlite");
const database = @import("../database/database.zig");
const handlers = @import("handlers.zig");

fn enqueueReplyAndLaunch(state: *State, conn: *Connection, reply: FramedReply) !void {
    var launch = reply.launch;
    defer run_task.Launch.release(&launch, state);
    if (reply.terminal) {
        _ = conn.tryEnqueue(.{ .bytes = reply.bytes, .terminal = true });
    } else {
        try conn.send(.{ .bytes = reply.bytes });
    }
}

fn blockedReader(started: *zio.ResetEvent, release: *zio.ResetEvent) anyerror!void {
    started.set();
    try release.wait();
}

fn blockedWriter(started: *zio.ResetEvent, release: *zio.ResetEvent) void {
    started.set();
    release.wait() catch return;
}

test "websocket close signal supervises both tasks" {
    var rt = try zio.Runtime.init(testing.allocator, .{ .executors = .exact(1) });
    defer rt.deinit();

    var lifecycle: WebSocketLifecycle = .{};
    var reader_started: zio.ResetEvent = .init;
    var writer_started: zio.ResetEvent = .init;
    var release: zio.ResetEvent = .init;
    var reader = try rt.spawn(blockedReader, .{ &reader_started, &release });
    var writer = try rt.spawn(blockedWriter, .{ &writer_started, &release });
    try reader_started.wait();
    try writer_started.wait();

    signalWebSocketClose(&lifecycle.close);
    superviseWebSocket(&reader, &writer, &lifecycle, close_drain_timeout);
    reader.cancel();
    writer.cancel();
    try testing.expect(reader.hasResult());
    try testing.expect(writer.hasResult());
}

fn completedReader() anyerror!void {}

test "websocket terminal drain stops at its timeout" {
    var rt = try zio.Runtime.init(testing.allocator, .{ .executors = .exact(1) });
    defer rt.deinit();

    var lifecycle: WebSocketLifecycle = .{};
    lifecycle.terminal_close_queued = true;
    var writer_started: zio.ResetEvent = .init;
    var release: zio.ResetEvent = .init;
    var reader = try rt.spawn(completedReader, .{});
    var writer = try rt.spawn(blockedWriter, .{ &writer_started, &release });

    superviseWebSocket(&reader, &writer, &lifecycle, .fromMilliseconds(1));
    try testing.expect(!writer.hasResult());
    reader.cancel();
    writer.cancel();
}

test "the user commit and run.started precede the send_input response" {
    const rt = try zio.Runtime.init(testing.allocator, .{ .executors = .exact(1) });
    defer rt.deinit();
    const listen = try zio.net.IpAddress.parseIp4("127.0.0.1", 0);
    const sqlite = try zqlite.open(":memory:", zqlite.OpenFlags.Create | zqlite.OpenFlags.NoMutex | zqlite.OpenFlags.EXResCode);
    var state = try State.init(testing.allocator, rt.io(), try database.Database.open(sqlite), .{ .listen = listen }, "/home/test");
    defer state.deinit();

    var conn: Connection = undefined;
    conn.init(testing.allocator);
    defer conn.deinit();
    try state.registry.register(&conn);
    defer state.registry.unregister(&conn);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const created = try handlers.sessionCreate(&state, arena, .{ .workspace_path = "/order", .model = "mock" });
    try state.registry.setSubscriptions(&conn, &.{created.session.id});
    const request: wire.rpc.Request = .{
        .id = "request-1",
        .method = .@"session.send_input",
        .params = .{ .session_send_input_params = .{
            .session_id = created.session.id,
            .input = .{ .content = .{ .content = &.{.{ .text = .{ .text = "hello" } }} } },
        } },
    };
    const request_bytes = try std.json.Stringify.valueAlloc(arena, request, .{ .emit_null_optional_fields = false });
    const reply = try frameReply(&state, &conn, testing.allocator, request_bytes);
    try testing.expect(reply.launch != null);

    var launch = try rt.spawn(enqueueReplyAndLaunch, .{ &state, &conn, reply });
    try launch.join();

    // Drain the outbox. The daemon folds and publishes each durable event in order, then the response.
    var saw_user_commit = false;
    var saw_run_started = false;
    var response_after_broadcasts = false;
    while (conn.outbox.tryReceive()) |item| {
        defer testing.allocator.free(item.bytes);
        if (std.mem.indexOf(u8, item.bytes, "\"id\":\"request-1\"") != null) {
            try testing.expect(saw_user_commit and saw_run_started); // The broadcasts precede the response.
            try testing.expect(std.mem.indexOf(u8, item.bytes, "\"result\"") != null);
            response_after_broadcasts = true;
        } else if (std.mem.indexOf(u8, item.bytes, "\"method\":\"run.started\"") != null) {
            saw_run_started = true;
        } else if (std.mem.indexOf(u8, item.bytes, "message.committed") != null and std.mem.indexOf(u8, item.bytes, "\"type\":\"user\"") != null) {
            saw_user_commit = true;
        }
    } else |_| {}
    try testing.expect(saw_user_commit and saw_run_started and response_after_broadcasts);
}

test "a queued drain publishes its commits and run.started before a send_input error" {
    const rt = try zio.Runtime.init(testing.allocator, .{ .executors = .exact(1) });
    defer rt.deinit();
    const listen = try zio.net.IpAddress.parseIp4("127.0.0.1", 0);
    const sqlite = try zqlite.open(":memory:", zqlite.OpenFlags.Create | zqlite.OpenFlags.NoMutex | zqlite.OpenFlags.EXResCode);
    var state = try State.init(testing.allocator, rt.io(), try database.Database.open(sqlite), .{ .listen = listen }, "/home/test");
    defer state.deinit();

    var conn: Connection = undefined;
    conn.init(testing.allocator);
    defer conn.deinit();
    try state.registry.register(&conn);
    defer state.registry.unregister(&conn);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const created = try handlers.sessionCreate(&state, arena, .{ .workspace_path = "/error-order", .model = "mock" });
    try state.registry.setSubscriptions(&conn, &.{created.session.id});
    try state.db.conn.execNoArgs("BEGIN IMMEDIATE");
    const old = try database.input.enqueue(&state.db, arena, created.session.id.raw, state.newId(), 100, &.{.{ .text = .{ .text = "old" } }}, 100);
    const old2 = try database.input.enqueue(&state.db, arena, created.session.id.raw, state.newId(), 100, &.{.{ .text = .{ .text = "old2" } }}, 101);
    try state.db.conn.execNoArgs("COMMIT");
    // The durable inputs load into the queue when the runtime activates on the send below.
    try state.db.conn.execNoArgs(
        \\CREATE TRIGGER fail_new_input BEFORE INSERT ON events
        \\WHEN NEW.name = 'input.queued'
        \\BEGIN SELECT RAISE(ABORT, 'test failure'); END
    );

    const request: wire.rpc.Request = .{
        .id = "request-error",
        .method = .@"session.send_input",
        .params = .{ .session_send_input_params = .{
            .session_id = created.session.id,
            .input = .{ .content = .{ .content = &.{.{ .text = .{ .text = "new" } }} } },
        } },
    };
    const request_bytes = try std.json.Stringify.valueAlloc(arena, request, .{ .emit_null_optional_fields = false });
    const reply = try frameReply(&state, &conn, testing.allocator, request_bytes);
    try testing.expect(reply.launch != null);
    // The queued drain folded both old commits and run.started, so they are already in the outbox in order.
    {
        const first_id = try std.fmt.allocPrint(arena, "\"input_id\":{d}", .{old.input.input_id});
        const second_id = try std.fmt.allocPrint(arena, "\"input_id\":{d}", .{old2.input.input_id});
        const first = try conn.outbox.tryReceive();
        defer testing.allocator.free(first.bytes);
        try testing.expect(std.mem.indexOf(u8, first.bytes, "message.committed") != null and std.mem.indexOf(u8, first.bytes, first_id) != null);
        const second = try conn.outbox.tryReceive();
        defer testing.allocator.free(second.bytes);
        try testing.expect(std.mem.indexOf(u8, second.bytes, "message.committed") != null and std.mem.indexOf(u8, second.bytes, second_id) != null);
        const started = try conn.outbox.tryReceive();
        defer testing.allocator.free(started.bytes);
        try testing.expect(std.mem.indexOf(u8, started.bytes, "\"method\":\"run.started\"") != null);
    }
    try testing.expectError(error.ChannelEmpty, conn.outbox.tryReceive());

    var launch = try rt.spawn(enqueueReplyAndLaunch, .{ &state, &conn, reply });
    try launch.join();
    const response_item = try conn.outbox.tryReceive();
    defer testing.allocator.free(response_item.bytes);
    try testing.expect(std.mem.indexOf(u8, response_item.bytes, "\"id\":\"request-error\"") != null);
    try testing.expect(std.mem.indexOf(u8, response_item.bytes, "\"error\"") != null);
}
