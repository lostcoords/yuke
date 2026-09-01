//! Accept HTTP connections and dispatch requests.
//! A proxy terminates TLS before remote clients connect.

const std = @import("std");
const zio = @import("zio");
const wire = @import("wire");
const wss = @import("websocket").server;
const rpc = @import("rpc.zig");
const State = @import("State.zig");
const provider = @import("../provider/provider.zig");
const connection = @import("connection.zig");
const Connection = connection.Connection;
const OutboxItem = connection.OutboxItem;
const run_task = @import("run_task.zig");
const shutdown = @import("shutdown.zig");

// Limit each request head to 64 KiB. The decoder rejects a larger head.
const max_head_bytes = 64 * 1024;
const write_buffer_bytes = 4096;

// Respect the wire frame limit as the bound for each WebSocket message.
const max_ws_message_bytes: usize = @intCast(wire.meta.limits.max_frame_bytes);

const text_plain = [_]std.http.Header{
    .{ .name = "content-type", .value = "text/plain; charset=utf-8" },
};

const text_plain_allow_get = [_]std.http.Header{
    .{ .name = "content-type", .value = "text/plain; charset=utf-8" },
    .{ .name = "allow", .value = "GET" },
};

/// Accept until the caller cancels this task. The caller owns the listener, so a bind fails startup.
pub fn serve(state: *State, listener: *std.Io.net.Server, stop: *shutdown.Watcher) void {
    var group: std.Io.Group = .init;
    defer group.cancel(state.io);

    while (true) {
        const stream = listener.accept(state.io) catch |err| switch (err) {
            error.Canceled => return, // The shutdown cancels this task.
            else => {
                // The daemon must not survive without a front door, so end the park too.
                std.log.err("the front door stopped accepting: {t}", .{err});
                stop.reportFault();
                return;
            },
        };
        group.concurrent(state.io, handleConnection, .{ state, stream }) catch |err| {
            std.log.err("a connection task did not start: {t}", .{err});
            stream.close(state.io);
        };
    }
}

fn handleConnection(state: *State, stream: std.Io.net.Stream) void {
    defer stream.close(state.io);
    dispatch(state, stream) catch |err| switch (err) {
        // Treat a clean keep-alive close, a dropped client, or shutdown as normal.
        error.HttpConnectionClosing, error.HttpRequestTruncated, error.Canceled => return,
        else => std.log.err("connection task failed: {t}", .{err}),
    };
}

fn dispatch(state: *State, stream: std.Io.net.Stream) !void {
    var head_buffer: [max_head_bytes]u8 = undefined;
    var reader = stream.reader(state.io, &head_buffer);
    var write_buffer: [write_buffer_bytes]u8 = undefined;
    var writer = stream.writer(state.io, &write_buffer);
    var server = std.http.Server.init(&reader.interface, &writer.interface);

    while (true) {
        var request = server.receiveHead() catch |err| switch (err) {
            error.ReadFailed => return reader.err orelse err,
            else => |e| return e,
        };
        // Reject a body before a route or the protocol upgrade can see it.
        if (!try screenFraming(&request)) {
            try stream.shutdown(state.io, .both);
            return;
        }
        // Admit before the upgrade, because CORS never blocks a WebSocket handshake.
        if (!try admit(state.config.listen, state.config.allowed_origins, &request)) {
            try stream.shutdown(state.io, .both);
            return;
        }
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
        try route(state, &request);
        if (!request.head.keep_alive) {
            try stream.shutdown(state.io, .both);
            return;
        }
    }
}

const close_drain_timeout: std.Io.Timeout = .{
    .duration = .{
        .clock = .awake,
        .raw = std.Io.Duration.fromMilliseconds(250),
    },
};

/// Track the persistent close signal and terminal drain state.
const WebSocketLifecycle = struct {
    io: std.Io,
    close: std.Io.Event = .unset,
    writer_done: std.Io.Event = .unset,
    // The daemon runtime uses one executor. The parent reads this after close wakes it.
    terminal_close_queued: bool = false,

    fn init(io: std.Io) WebSocketLifecycle {
        return .{ .io = io };
    }

    fn signalClose(self: *WebSocketLifecycle) void {
        self.close.set(self.io);
    }
};

/// Serve one WebSocket. Reader and writer tasks own socket.input and socket.output respectively.
/// This function supervises and owns both task handles.
fn serveWebSocket(state: *State, request: *std.http.Server.Request, key: []const u8) !void {
    var socket = try request.respondWebSocket(.{ .key = key });
    try socket.output.flush();

    var conn: Connection = undefined;
    conn.init(state.gpa, state.io);
    defer conn.deinit();

    var lifecycle = WebSocketLifecycle.init(state.io);
    conn.setTeardown(&lifecycle, signalWebSocketClose);
    try state.registry.register(&conn);
    defer state.registry.unregister(&conn); // The defer runs before `conn.deinit`, so no publish targets a dead outbox.

    var reader = try state.io.concurrent(readerTask, .{ state, &conn, socket.input, &lifecycle });
    errdefer reader.cancel(state.io) catch {};

    var writer = try state.io.concurrent(writerTask, .{ &conn, socket.output, &lifecycle });

    superviseWebSocket(&lifecycle, close_drain_timeout);
    reader.cancel(state.io) catch {};
    writer.cancel(state.io);
}

/// Signal the persistent close event when the registry closes a connection.
fn signalWebSocketClose(context: *anyopaque) void {
    const lifecycle: *WebSocketLifecycle = @ptrCast(@alignCast(context));
    lifecycle.signalClose();
}

/// Wait for the first terminal condition. The parent owns all cancellation and joins.
fn superviseWebSocket(lifecycle: *WebSocketLifecycle, drain_timeout: std.Io.Timeout) void {
    lifecycle.close.wait(lifecycle.io) catch return;
    if (!lifecycle.terminal_close_queued) return;
    // A writer-first wake leaves writer_done set, so this wait returns at once.
    lifecycle.writer_done.waitTimeout(lifecycle.io, drain_timeout) catch {};
}

/// Read WebSocket frames and signal teardown on exit.
fn readerTask(
    state: *State,
    conn: *Connection,
    input: *std.Io.Reader,
    lifecycle: *WebSocketLifecycle,
) anyerror!void {
    defer {
        conn.close();
        lifecycle.signalClose();
    }
    lifecycle.terminal_close_queued = try readerLoop(state, conn, input);
}

/// Write queued WebSocket frames and signal teardown on exit.
fn writerTask(conn: *Connection, output: *std.Io.Writer, lifecycle: *WebSocketLifecycle) void {
    defer {
        conn.close();
        lifecycle.writer_done.set(lifecycle.io);
        lifecycle.signalClose();
    }
    writerLoop(conn, output);
}

/// Drain the outbox to socket.output. Stop after a terminal close frame. The task owns socket.output.
fn writerLoop(conn: *Connection, output: *std.Io.Writer) void {
    var pending: ?OutboxItem = null;
    defer if (pending) |item| conn.gpa.free(item.bytes);

    while (true) {
        const item = if (pending) |queued| blk: {
            pending = null;
            break :blk queued;
        } else conn.receive() catch return; // closed and drained
        defer conn.gpa.free(item.bytes);
        // A stuck peer can block this write indefinitely. A proxy deadline or task cancel frees it.
        output.writeAll(item.bytes) catch return;
        output.flush() catch return;
        if (item.terminal) return;
        // Prefetch one item to find the empty or closed boundary without a queue peek.
        pending = conn.tryReceive() catch return;
        if (pending == null) flushShedMarkers(conn, output) catch return;
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
    return respondFinal(request, .bad_request, "bad request\n", &text_plain);
}

/// Answer and close. This keeps peer input clear of the asserts in `discardBody`.
fn respondFinal(
    request: *std.http.Server.Request,
    status: std.http.Status,
    body: []const u8,
    extra: []const std.http.Header,
) !void {
    return request.respond(body, .{ .status = status, .keep_alive = false, .extra_headers = extra });
}

const Framing = enum { none, present, conflict };

/// Classify the body framing that a head declares. A sender must not send both length fields.
fn classify(request: *const std.http.Server.Request) Framing {
    // `Head.parse` files a non-chunked transfer coding under `transfer_compression`, so read the header.
    var has_transfer_encoding = false;
    var headers = request.iterateHeaders();
    while (headers.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "transfer-encoding")) {
            has_transfer_encoding = true;
            break;
        }
    }
    const content_length = request.head.content_length;
    if (has_transfer_encoding and content_length != null) return .conflict;
    if (has_transfer_encoding or (content_length orelse 0) > 0) return .present;
    return .none;
}

/// The official web client. A stock daemon serves it without configuration.
const official_origin = "https://client.yuke.sh";

/// Whether `origin` is the official client or an operator entry.
fn originAllowed(allowed: []const []const u8, origin: []const u8) bool {
    if (std.mem.eql(u8, origin, official_origin)) return true;
    for (allowed) |entry| {
        if (std.mem.eql(u8, entry, origin)) return true;
    }
    return false;
}

/// Whether `address` reaches a server bound to `bind`. A wildcard is a bind address, never a target.
fn addressIsLocal(bind: std.Io.net.IpAddress, address: std.Io.net.IpAddress) bool {
    switch (address) {
        .ip4 => |a| {
            if (std.mem.allEqual(u8, &a.bytes, 0)) return false;
            if (a.bytes[0] == 127) return true;
            return switch (bind) {
                .ip4 => |b| std.mem.eql(u8, &a.bytes, &b.bytes),
                .ip6 => false,
            };
        },
        // The listen socket is IPv4, so loopback is the whole legitimate IPv6 set.
        .ip6 => |a| {
            if (std.mem.allEqual(u8, &a.bytes, 0)) return false;
            if (std.mem.eql(u8, a.bytes[0..15], &[_]u8{0} ** 15) and a.bytes[15] == 1) return true;
            return std.mem.eql(u8, a.bytes[0..10], &[_]u8{0} ** 10) and
                a.bytes[10] == 0xff and a.bytes[11] == 0xff and a.bytes[12] == 127;
        },
    }
}

/// Whether `host` addresses the bind by literal. `localhost` is the one name a browser cannot rebind.
fn hostIsLiteral(bind: std.Io.net.IpAddress, host: []const u8) bool {
    // Brackets enclose a literal only, so `[localhost]` earns no name exemption.
    if (host.len != 0 and host[0] != '[') {
        const name_end = std.mem.findScalar(u8, host, ':') orelse host.len;
        if (std.ascii.eqlIgnoreCase(host[0..name_end], "localhost")) {
            if (name_end == host.len) return true;
            // A trailing value that is not a port makes this an authority we cannot check.
            _ = std.fmt.parseInt(u16, host[name_end + 1 ..], 10) catch return false;
            return true;
        }
    }
    const address = std.Io.net.IpAddress.parseLiteral(host) catch return false;
    return addressIsLocal(bind, address);
}

/// Refuse a browser-driven or rebound request. Return true when the request may reach a route.
/// CORS does not guard the WebSocket handshake, so admission refuses the shape instead.
fn admit(
    bind: std.Io.net.IpAddress,
    allowed: []const []const u8,
    request: *std.http.Server.Request,
) !bool {
    // Only a proxy sends an absolute-form target, and its authority overrides `Host`. Refuse it,
    // rather than keep two authorities that can disagree.
    if (!std.mem.startsWith(u8, request.head.target, "/")) {
        try respondFinal(request, .forbidden, "forbidden\n", &text_plain);
        return false;
    }

    var origins: usize = 0;
    var hosts: usize = 0;
    var origin: []const u8 = "";
    var host: []const u8 = "";
    var headers = request.iterateHeaders();
    while (headers.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "origin")) {
            origins += 1;
            origin = header.value;
        } else if (std.ascii.eqlIgnoreCase(header.name, "host")) {
            hosts += 1;
            host = header.value;
        }
    }

    // A duplicate holds no single value to check, so it falls through to the refusal.
    if (origins == 1 and originAllowed(allowed, origin)) return true;
    if (origins == 0 and hosts == 1 and hostIsLiteral(bind, host)) return true;

    try respondFinal(request, .forbidden, "forbidden\n", &text_plain);
    return false;
}

/// Refuse a request that carries a body. Return true when the request may reach a route.
fn screenFraming(request: *std.http.Server.Request) !bool {
    switch (classify(request)) {
        .conflict => {
            try respondFinal(request, .bad_request, "bad framing\n", &text_plain);
            return false;
        },
        .present => {
            try respondFinal(request, .bad_request, "unexpected body\n", &text_plain);
            return false;
        },
        .none => {
            if (!request.head.method.requestHasBody()) return true;
            try respondFinal(request, .method_not_allowed, "method not allowed\n", &text_plain_allow_get);
            return false;
        },
    }
}

/// The `/identity` body. A daemon before enrollment omits `device_id`.
const Identity = struct {
    service: []const u8 = "yuke",
    version: []const u8 = State.daemon_version,
    device_id: ?[]const u8 = null,
};

/// Answer the discovery probe. It carries no secret, so it needs no credential.
/// Admission already vetted the origin, so the echo reflects an allowed value.
fn routeIdentity(state: *State, request: *std.http.Server.Request) !void {
    // The device id has no length bound, so a fixed buffer could refuse to answer at all.
    var body: std.Io.Writer.Allocating = .init(state.gpa);
    defer body.deinit();
    try std.json.Stringify.value(
        Identity{ .device_id = state.device_id },
        .{ .emit_null_optional_fields = false },
        &body.writer,
    );

    var headers: [3]std.http.Header = undefined;
    headers[0] = .{ .name = "content-type", .value = "application/json" };
    var count: usize = 1;
    if (requestOrigin(request)) |origin| {
        headers[1] = .{ .name = "access-control-allow-origin", .value = origin };
        headers[2] = .{ .name = "vary", .value = "Origin" };
        count = 3;
    }
    return request.respond(body.written(), .{ .extra_headers = headers[0..count] });
}

/// Return the one `Origin` value. A duplicate carries no single value to echo.
fn requestOrigin(request: *const std.http.Server.Request) ?[]const u8 {
    var found: ?[]const u8 = null;
    var headers = request.iterateHeaders();
    while (headers.next()) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, "origin")) continue;
        if (found != null) return null;
        found = header.value;
    }
    return found;
}

/// Route discovery, the health check, and the root page. Return 404 for other requests.
fn route(state: *State, request: *std.http.Server.Request) !void {
    const target = request.head.target;
    if (request.head.method != .GET) {
        return respondFinal(request, .method_not_allowed, "method not allowed\n", &text_plain_allow_get);
    }
    if (std.mem.eql(u8, target, "/identity")) return routeIdentity(state, request);
    if (std.mem.eql(u8, target, "/up")) {
        return request.respond("ok\n", .{ .extra_headers = &text_plain });
    }
    if (std.mem.eql(u8, target, "/")) {
        return request.respond("yuke daemon\n", .{ .extra_headers = &text_plain });
    }
    return request.respond("not found\n", .{ .status = .not_found, .extra_headers = &text_plain });
}

const testing = std.testing;
const database = @import("../database/database.zig");
const handlers = @import("handlers.zig");

const test_bind = std.Io.net.IpAddress{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = 9853 } };

/// Run admission over one head. Return the refusal, or null when the request may reach a route.
fn admitHead(request_bytes: []const u8, allowed: []const []const u8, out: []u8) !?[]const u8 {
    var in: std.Io.Reader = .fixed(request_bytes);
    var writer: std.Io.Writer = .fixed(out);
    var server = std.http.Server.init(&in, &writer);
    var request = try server.receiveHead();
    if (try admit(test_bind, allowed, &request)) return null;
    return writer.buffered();
}

fn expectAdmitted(request_bytes: []const u8, allowed: []const []const u8) !void {
    var out: [512]u8 = undefined;
    try testing.expect(try admitHead(request_bytes, allowed, &out) == null);
}

fn expectForbidden(request_bytes: []const u8, allowed: []const []const u8) !void {
    var out: [512]u8 = undefined;
    const refusal = (try admitHead(request_bytes, allowed, &out)) orelse return error.TestUnexpectedResult;
    try testing.expect(std.mem.startsWith(u8, refusal, "HTTP/1.1 403 Forbidden\r\n"));
}

test "a request without an origin passes on a literal host" {
    try expectAdmitted("GET /up HTTP/1.1\r\nHost: 127.0.0.1:9853\r\n\r\n", &.{});
}

test "localhost is the one name that passes" {
    try expectAdmitted("GET /up HTTP/1.1\r\nHost: localhost:9853\r\n\r\n", &.{});
    try expectForbidden("GET /up HTTP/1.1\r\nHost: evil.com\r\n\r\n", &.{});
}

test "an origin refuses unless the allowlist holds it" {
    const head = "GET /up HTTP/1.1\r\nHost: 127.0.0.1:9853\r\nOrigin: https://evil.com\r\n\r\n";
    try expectForbidden(head, &.{});
    try expectAdmitted(head, &.{"https://evil.com"});
}

test "the official origin passes a rebound host" {
    try expectAdmitted("GET /up HTTP/1.1\r\nHost: evil.com\r\nOrigin: " ++ official_origin ++ "\r\n\r\n", &.{});
}

test "a duplicate origin refuses" {
    const head = "GET /up HTTP/1.1\r\nHost: 127.0.0.1:9853\r\nOrigin: " ++ official_origin ++
        "\r\nOrigin: https://evil.com\r\n\r\n";
    try expectForbidden(head, &.{});
}

test "the wildcard address is a bind, never a destination" {
    // `0.0.0.0` reaches a loopback socket but escapes the browser gating that `127.0.0.1` receives.
    try testing.expect(!hostIsLiteral(test_bind, "0.0.0.0:9853"));
    try testing.expect(!hostIsLiteral(test_bind, "[::]"));
    try testing.expect(!hostIsLiteral(test_bind, "[localhost]"));
    try testing.expect(hostIsLiteral(test_bind, "[::1]:9853"));
    try testing.expect(hostIsLiteral(test_bind, "[::ffff:127.0.0.1]:9853"));
}

test "a localhost authority holds a port or nothing" {
    try testing.expect(hostIsLiteral(test_bind, "localhost"));
    try testing.expect(!hostIsLiteral(test_bind, "localhost:"));
    try testing.expect(!hostIsLiteral(test_bind, "localhost:9853@evil.example"));
    try testing.expect(!hostIsLiteral(test_bind, "localhost.evil.example"));
}

/// Accept one connection and dispatch it. The test owns the listener.
fn serveOnce(state: *State, listener: *std.Io.net.Server) void {
    const stream = listener.accept(state.io) catch return;
    defer stream.close(state.io);
    dispatch(state, stream) catch {};
}

/// Read only the status line, so a wrong upgrade fails the assertion instead of a blocked read.
const status_line_len = "HTTP/1.1 000".len;

/// Drive one request through the real `dispatch` over a loopback socket. `out` bounds the read,
/// so a caller that wants the body must also ask the route to end the connection.
fn frontDoor(request_bytes: []const u8, out: []u8) ![]const u8 {
    const rt = try zio.Runtime.init(testing.allocator, .{ .executors = .exact(1) });
    defer rt.deinit();
    const io = rt.io();

    const listen = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var state = try State.init(.{
        .gpa = testing.allocator,
        .io = io,
        .db = try database.Database.openTest(),
        .config = .{ .listen = listen },
        .home = "/home/test",
        .env = &test_env,
        .route_transport = test_transport.transport(),
        .device_id = "device-1",
    });
    defer state.deinit();

    var listener = try listen.listen(io, .{});
    defer listener.deinit(io);

    var task = try rt.spawn(serveOnce, .{ &state, &listener });
    const stream = try listener.socket.address.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    var write_buf: [1024]u8 = undefined;
    var client_writer = stream.writer(io, &write_buf);
    try client_writer.interface.writeAll(request_bytes);
    try client_writer.interface.flush();

    var read_buf: [2048]u8 = undefined;
    var client_reader = stream.reader(io, &read_buf);
    const n = client_reader.interface.readSliceShort(out) catch 0;
    // Close first, so a serve task that wrongly upgraded reaches an end of stream and joins.
    stream.shutdown(io, .both) catch {};
    task.join();
    return out[0..n];
}

fn expectStatus(request_bytes: []const u8, status: []const u8) !void {
    var out: [status_line_len]u8 = undefined;
    try testing.expectEqualStrings(status, try frontDoor(request_bytes, &out));
}

// The handshake is valid, so only the screen or admission can stop the upgrade.
const ws_upgrade_headers = "Upgrade: websocket\r\nConnection: Upgrade\r\n" ++
    "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n";

test "admission runs before the websocket upgrade" {
    const request = "GET /ws HTTP/1.1\r\nHost: 127.0.0.1\r\nOrigin: https://evil.example\r\n" ++
        ws_upgrade_headers ++ "\r\n";
    try expectStatus(request, "HTTP/1.1 403");
}

test "the body screen runs before the websocket upgrade" {
    const request = "GET /ws HTTP/1.1\r\nHost: 127.0.0.1\r\n" ++ ws_upgrade_headers ++
        "Content-Length: 4\r\n\r\nbody";
    try expectStatus(request, "HTTP/1.1 400");
}

test "identity reports the service, the version, and the device" {
    var out: [2048]u8 = undefined;
    const request = "GET /identity HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n";
    const response = try frontDoor(request, &out);
    try testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(std.mem.containsAtLeast(u8, response, 1, "content-type: application/json\r\n"));
    try testing.expect(std.mem.endsWith(u8, response, "{\"service\":\"yuke\",\"version\":\"" ++
        State.daemon_version ++ "\",\"device_id\":\"device-1\"}"));
}

test "identity echoes an admitted origin so a browser can read it" {
    var out: [2048]u8 = undefined;
    const request = "GET /identity HTTP/1.1\r\nHost: 127.0.0.1\r\nOrigin: " ++ official_origin ++
        "\r\nConnection: close\r\n\r\n";
    const response = try frontDoor(request, &out);
    try testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(std.mem.containsAtLeast(u8, response, 1, //
        "access-control-allow-origin: " ++ official_origin ++ "\r\n"));
    try testing.expect(std.mem.containsAtLeast(u8, response, 1, "vary: Origin\r\n"));
}

test "an absolute-form target refuses" {
    try expectForbidden("GET http://evil.example/up HTTP/1.1\r\nHost: 127.0.0.1:9853\r\n\r\n", &.{});
}

/// Screen one head. Return the refusal, or null when the request may reach a route.
fn screenHead(request_bytes: []const u8, out: []u8) !?[]const u8 {
    var in: std.Io.Reader = .fixed(request_bytes);
    var writer: std.Io.Writer = .fixed(out);
    var server = std.http.Server.init(&in, &writer);
    var request = try server.receiveHead();
    if (try screenFraming(&request)) return null;
    return writer.buffered();
}

fn expectScreened(request_bytes: []const u8, status: []const u8) !void {
    var out: [512]u8 = undefined;
    const refusal = (try screenHead(request_bytes, &out)) orelse return error.TestUnexpectedResult;
    try testing.expect(std.mem.startsWith(u8, refusal, status));
    try testing.expect(std.mem.containsAtLeast(u8, refusal, 1, "connection: close\r\n"));
}

fn expectPassesScreen(request_bytes: []const u8) !void {
    var out: [512]u8 = undefined;
    try testing.expect(try screenHead(request_bytes, &out) == null);
}

test "a body-bearing method without framing answers instead of asserting" {
    var out: [512]u8 = undefined;
    const refusal = (try screenHead("POST / HTTP/1.1\r\nHost: x\r\n\r\n", &out)).?;
    try testing.expect(std.mem.startsWith(u8, refusal, "HTTP/1.1 405 Method Not Allowed\r\n"));
    try testing.expect(std.mem.containsAtLeast(u8, refusal, 1, "connection: close\r\n"));
    try testing.expect(std.mem.containsAtLeast(u8, refusal, 1, "allow: GET\r\n"));
}

test "a declared body is refused before any discard" {
    try expectScreened("POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 10\r\n\r\nabc", "HTTP/1.1 400");
}

test "a body on a method that reads none closes the connection" {
    try expectScreened("GET /up HTTP/1.1\r\nHost: x\r\nContent-Length: 4\r\n\r\nGET ", "HTTP/1.1 400");
}

test "both length fields together are a framing conflict" {
    const head = "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\nTransfer-Encoding: chunked\r\n\r\n";
    try expectScreened(head, "HTTP/1.1 400");
}

test "a transfer coding that is not chunked still declares a body" {
    try expectScreened("GET /ws HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: gzip\r\n\r\nbody", "HTTP/1.1 400");
}

test "a request without a body passes the screen" {
    try expectPassesScreen("GET /up HTTP/1.1\r\nHost: x\r\n\r\n");
    try expectPassesScreen("GET / HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n");
}

fn enqueueReplyAndLaunch(state: *State, conn: *Connection, reply: FramedReply) !void {
    var launch = reply.launch;
    defer run_task.Launch.release(&launch, state);
    if (reply.terminal) {
        _ = conn.tryEnqueue(.{ .bytes = reply.bytes, .terminal = true });
    } else {
        try conn.send(.{ .bytes = reply.bytes });
    }
}

/// The test dependencies. An empty environment allocates nothing, so no test frees it.
var test_env: std.process.Environ.Map = .init(std.testing.allocator);
var test_transport = provider.transport.CannedTransport{ .bytes = provider.transport.canned_reply };

test "the user commit and run.started precede the send_input response" {
    const rt = try zio.Runtime.init(testing.allocator, .{ .executors = .exact(1) });
    defer rt.deinit();
    const listen = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var state = try State.init(.{ .gpa = testing.allocator, .io = rt.io(), .db = try database.Database.openTest(), .config = .{ .listen = listen }, .home = "/home/test", .env = &test_env, .route_transport = test_transport.transport() });
    defer state.deinit();

    var conn: Connection = undefined;
    conn.init(testing.allocator, rt.io());
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
    while (true) {
        const item = (try conn.tryReceive()) orelse break;
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
    }
    try testing.expect(saw_user_commit and saw_run_started and response_after_broadcasts);
}

/// Take the next session-stream frame. An index broadcast has no place in one session's order.
fn nextStreamFrame(conn: *Connection) !?connection.OutboxItem {
    const index_events = [_][]const u8{ "session.summary_changed", "workspace.created" };
    outer: while (try conn.tryReceive()) |item| {
        for (index_events) |name| if (std.mem.indexOf(u8, item.bytes, name) != null) {
            testing.allocator.free(item.bytes);
            continue :outer;
        };
        return item;
    }
    return null;
}

test "a queued drain publishes its commits and run.started before a send_input error" {
    const rt = try zio.Runtime.init(testing.allocator, .{ .executors = .exact(1) });
    defer rt.deinit();
    const listen = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var state = try State.init(.{ .gpa = testing.allocator, .io = rt.io(), .db = try database.Database.openTest(), .config = .{ .listen = listen }, .home = "/home/test", .env = &test_env, .route_transport = test_transport.transport() });
    defer state.deinit();

    var conn: Connection = undefined;
    conn.init(testing.allocator, rt.io());
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
        const first = (try nextStreamFrame(&conn)).?;
        defer testing.allocator.free(first.bytes);
        try testing.expect(std.mem.indexOf(u8, first.bytes, "message.committed") != null and std.mem.indexOf(u8, first.bytes, first_id) != null);
        const second = (try nextStreamFrame(&conn)).?;
        defer testing.allocator.free(second.bytes);
        try testing.expect(std.mem.indexOf(u8, second.bytes, "message.committed") != null and std.mem.indexOf(u8, second.bytes, second_id) != null);
        const started = (try nextStreamFrame(&conn)).?;
        defer testing.allocator.free(started.bytes);
        try testing.expect(std.mem.indexOf(u8, started.bytes, "\"method\":\"run.started\"") != null);
    }
    try testing.expect((try nextStreamFrame(&conn)) == null);

    var launch = try rt.spawn(enqueueReplyAndLaunch, .{ &state, &conn, reply });
    try launch.join();
    const response_item = (try nextStreamFrame(&conn)).?;
    defer testing.allocator.free(response_item.bytes);
    try testing.expect(std.mem.indexOf(u8, response_item.bytes, "\"id\":\"request-error\"") != null);
    try testing.expect(std.mem.indexOf(u8, response_item.bytes, "\"error\"") != null);
}
