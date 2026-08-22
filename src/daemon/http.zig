//! The front door accepts connections and dispatches HTTP requests.
//! A proxy terminates TLS for remote clients.

const std = @import("std");
const zio = @import("zio");
const wss = @import("websocket").server;
const rpc = @import("rpc.zig");

// The header buffer bounds one request head. The decoder rejects a larger head.
const max_head_bytes = 64 * 1024;
const write_buffer_bytes = 4096;
// The message cap limits the reassembly buffer to one megabyte.
const max_ws_message_bytes = 1 << 20;

const text_plain = [_]std.http.Header{
    .{ .name = "content-type", .value = "text/plain; charset=utf-8" },
};

/// Accept connections forever. Each connection runs on its own task.
pub fn serve(gpa: std.mem.Allocator, address: zio.net.IpAddress) !void {
    const listener = try address.listen(.{});
    defer listener.close();
    std.log.info("front door on http://{f}", .{listener.socket.address});

    var group: zio.Group = .init;
    defer group.cancel();

    while (true) {
        const stream = try listener.accept(.{});
        errdefer stream.close();
        try group.spawn(handleConnection, .{ gpa, stream });
    }
}

fn handleConnection(gpa: std.mem.Allocator, stream: zio.net.Stream) !void {
    defer stream.close();
    dispatch(gpa, stream) catch |err| switch (err) {
        // A clean keep-alive close, a dropped client, or shutdown is not a failure.
        error.HttpConnectionClosing, error.HttpRequestTruncated, error.Canceled => return,
        else => return err,
    };
}

fn dispatch(gpa: std.mem.Allocator, stream: zio.net.Stream) !void {
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
                    return serveWebSocket(gpa, &request, key);
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

/// Read wire requests from a WebSocket and answer control frames.
fn serveWebSocket(gpa: std.mem.Allocator, request: *std.http.Server.Request, key: []const u8) !void {
    var socket = try request.respondWebSocket(.{ .key = key });
    try socket.output.flush();

    var reader: wss.MessageReader = .init(max_ws_message_bytes);
    defer reader.deinit(gpa);

    while (true) {
        var message = reader.next(gpa, socket.input) catch |err| switch (err) {
            error.EndOfStream => return,
            error.MessageTooBig, error.FrameTooBig => return closeWith(&socket, .message_too_big),
            error.InvalidUtf8 => return closeWith(&socket, .invalid_frame_payload_data),
            error.Unmasked,
            error.ReservedBitSet,
            error.UnrecognizedOpcode,
            error.ControlFrameFragmented,
            error.ControlFrameTooBig,
            error.NonMinimalLength,
            error.BadClose,
            error.InvalidContinuation,
            error.Interrupted,
            => return closeWith(&socket, .protocol_error),
            else => return err,
        };
        defer message.deinit(gpa);
        switch (message.opcode) {
            // Wire frames are text JSON. A binary frame is a protocol error.
            .text => switch (try rpc.handleRequest(gpa, socket.output, message.data)) {
                .keep_open => {},
                .close => return,
            },
            .binary => return closeWith(&socket, .unsupported_data),
            .ping => {
                try wss.writePong(socket.output, message.data);
                try socket.output.flush();
            },
            .connection_close => {
                const parsed = wss.checkedClose(message.data) catch return closeWith(&socket, .protocol_error);
                const echo = if (parsed.code == .no_status_rcvd) .normal_closure else parsed.code;
                return closeWith(&socket, echo);
            },
            .pong => continue,
            // MessageReader resolves a continuation into its message opcode.
            .continuation => unreachable,
        }
    }
}

/// Send a close frame with the code, then stop.
fn closeWith(socket: *std.http.Server.WebSocket, code: wss.CloseCode) !void {
    try wss.writeClose(socket.output, code);
    try socket.output.flush();
}

/// Validate the WebSocket handshake fields that upgradeRequested does not check.
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

/// Return true when a comma-separated header value holds the token.
fn headerHasToken(value: []const u8, token: []const u8) bool {
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |part| {
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, part, " \t"), token)) return true;
    }
    return false;
}

/// The Sec-WebSocket-Key must decode to exactly 16 bytes.
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
    try std.testing.expect(validKey("dGhlIHNhbXBsZSBub25jZQ==")); // 16 bytes
    try std.testing.expect(!validKey("dGhlIHNhbXBsZQ==")); // 10 bytes
    try std.testing.expect(!validKey("################========")); // bad charset
    try std.testing.expect(!validKey("")); // empty
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
