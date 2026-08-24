//! Accept HTTP connections and dispatch requests.
//! A proxy terminates TLS before remote clients connect.

const std = @import("std");
const zio = @import("zio");
const wss = @import("websocket").server;
const rpc = @import("rpc.zig");
const State = @import("State.zig");
const Connection = @import("connection.zig").Connection;

// Limit each request head to 64 KiB. The decoder rejects a larger head.
const max_head_bytes = 64 * 1024;
const write_buffer_bytes = 4096;
// Limit each WebSocket message to 1 MiB.
const max_ws_message_bytes = 1 << 20;

const text_plain = [_]std.http.Header{
    .{ .name = "content-type", .value = "text/plain; charset=utf-8" },
};

/// Accept connections forever. Run each connection in its own task.
pub fn serve(state: *State) !void {
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

/// Serve one WebSocket. A reader coroutine decodes client frames and enqueues framed replies. A writer
/// coroutine owns socket.output and drains the outbox, so two writes never race on the socket.
fn serveWebSocket(state: *State, request: *std.http.Server.Request, key: []const u8) !void {
    var socket = try request.respondWebSocket(.{ .key = key });
    try socket.output.flush();

    var conn: Connection = undefined;
    conn.init(state.gpa);
    defer conn.deinit();

    var writer = try zio.spawn(writerLoop, .{ &conn, &socket });
    readerLoop(state, &conn, &socket) catch {};
    conn.outbox.close(.graceful); // let the writer flush queued frames, then stop
    writer.join();
}

/// Drain the outbox to socket.output. The writer owns socket.output after the handshake. Stop after a
/// terminal close frame. On any exit, close the outbox so a reader blocked on a full send unwinds.
fn writerLoop(conn: *Connection, socket: *std.http.Server.WebSocket) void {
    defer conn.outbox.close(.graceful);
    while (true) {
        const item = conn.outbox.receive() catch return; // closed and drained
        defer conn.gpa.free(item.bytes);
        // A stuck peer can block this write with no timeout. A proxy deadline or task cancel frees it.
        socket.output.writeAll(item.bytes) catch return;
        socket.output.flush() catch return;
        if (item.terminal) return;
    }
}

/// Decode client frames and enqueue framed replies, pongs, and closes. Never write to the socket.
fn readerLoop(state: *State, conn: *Connection, socket: *std.http.Server.WebSocket) !void {
    const gpa = state.gpa;
    var reader: wss.MessageReader = .init(max_ws_message_bytes);
    defer reader.deinit(gpa);

    while (true) {
        var message = reader.next(gpa, socket.input) catch |err| switch (err) {
            error.EndOfStream => return,
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
                const reply = try frameReply(state, gpa, message.data);
                try conn.send(.{ .bytes = reply.bytes, .terminal = reply.terminal });
                if (reply.terminal) return;
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

const FramedReply = struct { bytes: []u8, terminal: bool };

/// Frame one wire reply as WS bytes. handleRequest writes the frame. A close outcome ends the connection.
fn frameReply(state: *State, gpa: std.mem.Allocator, data: []const u8) !FramedReply {
    var buf: std.Io.Writer.Allocating = .init(gpa);
    errdefer buf.deinit();
    const outcome = try rpc.handleRequest(state, &buf.writer, data);
    return .{ .bytes = try buf.toOwnedSlice(), .terminal = outcome == .close };
}

/// Frame a pong that echoes the ping payload.
fn framePong(gpa: std.mem.Allocator, payload: []const u8) ![]u8 {
    var buf: std.Io.Writer.Allocating = .init(gpa);
    errdefer buf.deinit();
    try wss.writePong(&buf.writer, payload);
    return buf.toOwnedSlice();
}

/// Enqueue a terminal close frame with the code.
fn enqueueClose(conn: *Connection, code: wss.CloseCode) !void {
    var buf: std.Io.Writer.Allocating = .init(conn.gpa);
    errdefer buf.deinit();
    try wss.writeClose(&buf.writer, code);
    try conn.send(.{ .bytes = try buf.toOwnedSlice(), .terminal = true });
}

/// Validate handshake fields that `upgradeRequested` does not check.
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
