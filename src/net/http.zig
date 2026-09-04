//! One JSON request and one bounded JSON response. The caller owns the response buffer.

const std = @import("std");
const zio = @import("zio");

pub const Error = error{
    /// The value is not a URL that this client can request.
    BadUrl,
    /// The response did not fit the buffer the caller owns.
    ResponseTooLarge,
    /// The request never left this host. Only this error lets a refresh retry the same token.
    PreFlight,
    /// The server may already hold the request, so a refresh must never repeat it.
    Ambiguous,
};

/// Bound one OAuth response. A token document is small, so a larger body is a fault.
pub const max_oauth_response_bytes = 256 * 1024;

pub const Response = struct {
    status: u16,
    /// The body borrows the buffer that the caller supplied.
    body: []const u8,
};

/// One name and value of a urlencoded form.
pub const Field = struct { name: []const u8, value: []const u8 };

/// What one OAuth request sends. Codex mixes both encodings between its own calls.
pub const Payload = union(enum) {
    form: []const Field,
    json: []const u8,

    fn contentType(self: Payload) []const u8 {
        return switch (self) {
            .form => "application/x-www-form-urlencoded",
            .json => "application/json",
        };
    }
};

pub const PostRequest = struct {
    url: []const u8,
    payload: Payload,
    /// The body lands here. Its length bounds the response.
    body_out: []u8,
    /// One deadline covers the whole request. The connect marker, not the clock, classifies it.
    timeout: std.Io.Timeout = .{ .duration = .{ .clock = .awake, .raw = .fromMilliseconds(30_000) } },
};

const PostLeg = struct {
    /// The child sets this once the connect ends, so a failure after it may have reached the server.
    connected: std.Io.Event = .unset,
    done: std.Io.Event = .unset,
};

/// One HTTPS client for the whole login. It keeps the connection alive between the polls.
pub const Client = struct {
    inner: std.http.Client,
    pub fn init(gpa: std.mem.Allocator, io: std.Io) Client {
        return .{ .inner = .{ .allocator = gpa, .io = io } };
    }

    pub fn deinit(self: *Client) void {
        self.inner.deinit();
    }

    /// POST one OAuth request. Only a failure before the send reports `PreFlight`.
    pub fn post(self: *Client, req: PostRequest) !Response {
        std.debug.assert(req.body_out.len != 0); // The caller owns a response buffer.
        std.debug.assert(req.body_out.len <= max_oauth_response_bytes);
        const io = self.inner.io;
        // Only a form needs encoding. The join below keeps a borrowed json body valid.
        const encoded: ?[]u8 = switch (req.payload) {
            .form => |fields| try encodeForm(self.inner.allocator, fields),
            .json => null,
        };
        defer if (encoded) |owned| self.inner.allocator.free(owned);
        const body = encoded orelse @constCast(req.payload.json);

        var leg: PostLeg = .{};
        var future = try io.concurrent(postGrantLeg, .{ self, req, body, &leg });
        leg.done.waitTimeout(io, req.timeout) catch |err| {
            // The cancel joins the child, so the connect marker now holds its final value.
            _ = future.cancel(io) catch undefined;
            if (err != error.Timeout) return err;
            // A connected child may have begun the send, so only an unconnected one is retryable.
            return if (leg.connected.isSet()) Error.Ambiguous else Error.PreFlight;
        };
        return future.await(io);
    }

    /// The client refuses a redirect, because a credential must never reach another origin.
    fn sendGrant(self: *Client, req: PostRequest, body: []u8, leg: *PostLeg) !Response {
        const io = self.inner.io;
        const uri = std.Uri.parse(req.url) catch {
            leg.connected.set(io);
            return error.BadUrl;
        };

        var request = request: {
            const opened = self.inner.request(.POST, uri, .{
                .redirect_behavior = .not_allowed,
                // A failed write leaves the pooled connection dirty, so never reuse this one.
                .keep_alive = false,
                .headers = .{
                    .content_type = .{ .override = req.payload.contentType() },
                    .accept_encoding = .omit,
                },
                .extra_headers = &.{.{ .name = "accept", .value = "application/json" }},
            }) catch |err| return switch (err) {
                error.UnsupportedUriScheme, error.UriMissingHost => error.BadUrl,
                error.OutOfMemory, error.Canceled => err,
                // The handshake ends before the request, so the server read no bytes here either.
                error.TlsInitializationFailed => error.PreFlight,
                // `request` only connects, so the server never read these bytes.
                else => error.PreFlight,
            };
            // The connect ended, so the read timeout owns every later failure. A cancel during the
            // connect must leave this unset, or the parent reads a send that never happened.
            leg.connected.set(io);
            break :request opened;
        };
        defer request.deinit();

        try request.sendBodyComplete(body);
        var response = try request.receiveHead(&.{});

        var transfer: [4096]u8 = undefined;
        var writer: std.Io.Writer = .fixed(req.body_out);
        _ = response.reader(&transfer).streamRemaining(&writer) catch |err| return switch (err) {
            // A full buffer is the only way the fixed writer fails.
            error.WriteFailed => error.ResponseTooLarge,
            else => err,
        };
        return .{ .status = @intFromEnum(response.head.status), .body = writer.buffered() };
    }
};

/// Run one OAuth POST in a child task. The parent waits for it, so the caller buffers stay valid.
fn postGrantLeg(self: *Client, req: PostRequest, body: []u8, leg: *PostLeg) !Response {
    defer leg.done.set(self.inner.io);
    return self.sendGrant(req, body, leg);
}

/// Encode `fields` as `application/x-www-form-urlencoded`. The caller owns the result.
fn encodeForm(gpa: std.mem.Allocator, fields: []const Field) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    for (fields, 0..) |field, index| {
        if (index != 0) try out.writer.writeByte('&');
        try encodeValue(&out.writer, field.name);
        try out.writer.writeByte('=');
        try encodeValue(&out.writer, field.value);
    }
    return out.toOwnedSlice();
}

/// Write one form value. A space becomes `+`, and every other reserved byte becomes %XX.
fn encodeValue(w: *std.Io.Writer, raw: []const u8) !void {
    for (raw) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => try w.writeByte(c),
        ' ' => try w.writeByte('+'),
        else => try w.print("%{X:0>2}", .{c}),
    };
}

const testing = std.testing;

test "a form body percent-encodes every reserved and UTF-8 byte" {
    const body = try encodeForm(testing.allocator, &.{
        .{ .name = "grant_type", .value = "refresh_token" },
        .{ .name = "scope", .value = "openid profile grok-cli:access" },
        .{ .name = "note", .value = "caf\u{e9}&=+" },
    });
    defer testing.allocator.free(body);

    // A space becomes `+`, and every byte of the UTF-8 sequence encodes on its own.
    try testing.expectEqualStrings(
        "grant_type=refresh_token" ++
            "&scope=openid+profile+grok-cli%3Aaccess" ++
            "&note=caf%C3%A9%26%3D%2B",
        body,
    );
}

const FormServer = struct {
    listener: *zio.net.Server = undefined,
    mode: enum { reply, redirect, oversize, stall },
    seen_type: [64]u8 = undefined,
    seen_type_len: usize = 0,
    err: ?anyerror = null,
};

fn serveFormOnce(s: *FormServer) void {
    serveFormOnceInner(s) catch |err| {
        s.err = err;
    };
}

fn serveFormOnceInner(s: *FormServer) !void {
    const stream = try s.listener.accept(.{});
    defer stream.close();
    var read_buf: [4096]u8 = undefined;
    var write_buf: [4096]u8 = undefined;
    var reader = stream.reader(&read_buf);
    var writer = stream.writer(&write_buf);
    var server = std.http.Server.init(&reader.interface, &writer.interface);
    var request = try server.receiveHead();

    var headers = request.iterateHeaders();
    while (headers.next()) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, "content-type")) continue;
        if (header.value.len > s.seen_type.len) break;
        @memcpy(s.seen_type[0..header.value.len], header.value);
        s.seen_type_len = header.value.len;
    }

    switch (s.mode) {
        .reply => try request.respond("{\"ok\":true}", .{ .status = .ok, .keep_alive = false }),
        .redirect => try request.respond("", .{
            .status = .found,
            .keep_alive = false,
            .extra_headers = &.{.{ .name = "location", .value = "https://elsewhere.invalid/token" }},
        }),
        .oversize => try request.respond("x" ** 512, .{ .status = .bad_request, .keep_alive = false }),
        // Read the request, then never answer, so the client times out after it sent the body.
        .stall => try zio.sleep(.fromMilliseconds(400)),
    }
}

const FormClient = struct {
    gpa: std.mem.Allocator = undefined,
    io: std.Io = undefined,
    port: u16 = undefined,
    out_len: usize = 4096,
    payload: Payload = .{ .form = &.{.{ .name = "grant_type", .value = "refresh_token" }} },
    timeout: std.Io.Timeout = .{ .duration = .{ .clock = .awake, .raw = .fromMilliseconds(30_000) } },
    status: u16 = 0,
    err: ?anyerror = null,
};

fn postFormOnce(c: *FormClient) void {
    postFormOnceInner(c) catch |err| {
        c.err = err;
    };
}

fn postFormOnceInner(c: *FormClient) !void {
    var client: Client = .init(c.gpa, c.io);
    defer client.deinit();
    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/token", .{c.port});
    const out = try c.gpa.alloc(u8, c.out_len);
    defer c.gpa.free(out);
    const response = try client.post(.{
        .url = url,
        .payload = c.payload,
        .body_out = out,
        .timeout = c.timeout,
    });
    c.status = response.status;
}

fn exchangeForm(server: *FormServer, client: *FormClient) !void {
    const rt = try zio.Runtime.init(testing.allocator, .{ .executors = .exact(1) });
    defer rt.deinit();
    const address = try zio.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try address.listen(.{});
    defer listener.close();
    server.listener = &listener;
    client.gpa = testing.allocator;
    client.io = rt.io();
    client.port = listener.socket.address.ip.getPort();

    var server_task = try rt.spawn(serveFormOnce, .{server});
    var client_task = try rt.spawn(postFormOnce, .{client});
    client_task.join();
    server_task.join();
}

test "a form post sends the urlencoded content type" {
    var server: FormServer = .{ .mode = .reply };
    var client: FormClient = .{};
    try exchangeForm(&server, &client);

    try testing.expectEqual(@as(?anyerror, null), server.err);
    try testing.expectEqual(@as(?anyerror, null), client.err);
    try testing.expectEqual(@as(u16, 200), client.status);
    try testing.expectEqualStrings("application/x-www-form-urlencoded", server.seen_type[0..server.seen_type_len]);
}

test "a json post sends its own content type and classifies the same way" {
    var server: FormServer = .{ .mode = .reply };
    var client: FormClient = .{ .payload = .{ .json = "{\"grant_type\":\"refresh_token\"}" } };
    try exchangeForm(&server, &client);

    try testing.expectEqual(@as(?anyerror, null), client.err);
    try testing.expectEqual(@as(u16, 200), client.status);
    try testing.expectEqualStrings("application/json", server.seen_type[0..server.seen_type_len]);
}

test "a form post refuses a redirect instead of sending the credential onward" {
    var server: FormServer = .{ .mode = .redirect };
    var client: FormClient = .{};
    try exchangeForm(&server, &client);

    // `not_allowed` names the refusal this way. The credential never reaches the other origin.
    try testing.expectEqual(@as(?anyerror, error.TooManyHttpRedirects), client.err);
}

test "a form post bounds an oversized error body" {
    var server: FormServer = .{ .mode = .oversize };
    var client: FormClient = .{ .out_len = 64 };
    try exchangeForm(&server, &client);

    try testing.expectEqual(@as(?anyerror, Error.ResponseTooLarge), client.err);
}

test "a refused connection is a pre-flight failure, so a refresh may retry it" {
    const rt = try zio.Runtime.init(testing.allocator, .{ .executors = .exact(1) });
    defer rt.deinit();
    const address = try zio.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try address.listen(.{});
    const port = listener.socket.address.ip.getPort();
    listener.close(); // Nothing listens on this port now, so the connect is refused.

    var client: FormClient = .{ .gpa = testing.allocator, .io = rt.io(), .port = port };
    var task = try rt.spawn(postFormOnce, .{&client});
    task.join();

    // The server never read a byte, so repeating this request cannot look like token reuse.
    try testing.expectEqual(@as(?anyerror, Error.PreFlight), client.err);
}

/// Fill the listener accept queue. The kernel then drops the next SYN, so that connect never ends.
const QueueFiller = struct {
    port: u16,
    held: [8]?zio.net.Stream = @splat(null),

    fn fill(self: *QueueFiller) void {
        const address = zio.net.IpAddress.parseIp4("127.0.0.1", self.port) catch return;
        for (&self.held) |*slot| {
            // The first connect the queue cannot take blocks, so a short timeout ends the fill.
            slot.* = address.connect(.{ .timeout = .fromMilliseconds(100) }) catch return;
        }
    }

    fn close(self: *QueueFiller) void {
        for (&self.held) |*slot| if (slot.*) |*stream| stream.close();
    }
};

test "a connect the timeout cancels is a pre-flight failure, never an ambiguous send" {
    const rt = try zio.Runtime.init(testing.allocator, .{ .executors = .exact(1) });
    defer rt.deinit();
    const address = try zio.net.IpAddress.parseIp4("127.0.0.1", 0);
    // Nothing ever accepts here, so the queue stays full once the filler below saturates it.
    var listener = try address.listen(.{ .kernel_backlog = 1 });
    defer listener.close();

    var filler: QueueFiller = .{ .port = listener.socket.address.ip.getPort() };
    var fill_task = try rt.spawn(QueueFiller.fill, .{&filler});
    fill_task.join();
    defer filler.close();

    var client: FormClient = .{
        .gpa = testing.allocator,
        .io = rt.io(),
        .port = filler.port,
        .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromMilliseconds(150) } },
    };
    var task = try rt.spawn(postFormOnce, .{&client});
    task.join();

    // The connect never ended, so no request byte reached the server and a repeat spends no token.
    try testing.expectEqual(@as(?anyerror, Error.PreFlight), client.err);
}

test "a timeout after the send reports ambiguity, never a pre-flight failure" {
    var server: FormServer = .{ .mode = .stall };
    var client: FormClient = .{
        .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromMilliseconds(50) } },
    };
    try exchangeForm(&server, &client);

    // A retry here could look like token reuse and cost the whole grant.
    try testing.expectEqual(@as(?anyerror, Error.Ambiguous), client.err);
}
