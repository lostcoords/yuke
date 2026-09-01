//! One JSON request and one bounded JSON response. The caller owns the response buffer.

const std = @import("std");
const zio = @import("zio");

/// Size the buffer for a control-plane document. The catalog caller sizes its own.
pub const max_response_bytes = 64 * 1024;

pub const Error = error{
    /// The `--cloud` value is not a URL that this client can request.
    BadUrl,
    /// The server sent more than `max_response_bytes`.
    ResponseTooLarge,
    /// The request passed its timeout. The caller degrades, because the control plane is optional.
    CloudTimeout,
    /// The request never left this host. Only this error lets a refresh retry the same token.
    PreFlight,
    /// The server may already hold the request, so a refresh must never repeat it.
    Ambiguous,
};

/// Bound one OAuth response. A token document is small, so a larger body is a fault.
pub const max_oauth_response_bytes = 256 * 1024;

/// This timeout covers one control-plane request, from the name lookup to the last body byte.
pub const default_timeout: std.Io.Timeout = .{
    .duration = .{ .clock = .awake, .raw = .fromMilliseconds(60_000) },
};

pub const Response = struct {
    status: u16,
    /// The body borrows the buffer that the caller supplied.
    body: []const u8,
};

/// One conditional GET. The caller owns both buffers, so it decides the response bound.
pub const GetRequest = struct {
    url: []const u8,
    /// Send this as `If-None-Match`. An empty value asks for the whole document.
    if_none_match: []const u8 = "",
    /// Send this credential as an authorization bearer. An empty value sends no credential.
    bearer: []const u8 = "",
    /// The body lands here. Its length bounds the response.
    body_out: []u8,
    /// The response ETag lands here, before the body reader invalidates the header strings.
    etag_out: []u8,
};

pub const Get = struct {
    status: u16,
    /// The body borrows `body_out`. A 304 response carries none.
    body: []const u8,
    /// The ETag borrows `etag_out`. It is empty when the response carries none.
    etag: []const u8,
};

/// The status of a response that repeats the document the caller already holds.
pub const status_not_modified = 304;

/// One name and value of a urlencoded form.
pub const Field = struct { name: []const u8, value: []const u8 };

pub const FormRequest = struct {
    url: []const u8,
    fields: []const Field,
    /// The body lands here. Its length bounds the response.
    body_out: []u8,
    /// One deadline covers the whole request. The connect marker, not the clock, classifies it.
    timeout: std.Io.Timeout = .{ .duration = .{ .clock = .awake, .raw = .fromMilliseconds(30_000) } },
};

const FormLeg = struct {
    /// The child sets this once the connect ends, so a failure after it may have reached the server.
    connected: std.Io.Event = .unset,
    done: std.Io.Event = .unset,
};

/// One HTTPS client for the whole login. It keeps the connection alive between the polls.
pub const Client = struct {
    inner: std.http.Client,
    /// This timeout applies to every request. `.none` removes it, which suits a local-server test.
    timeout: std.Io.Timeout,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, timeout: std.Io.Timeout) Client {
        return .{ .inner = .{ .allocator = gpa, .io = io }, .timeout = timeout };
    }

    pub fn deinit(self: *Client) void {
        self.inner.deinit();
    }

    /// POST `body` as JSON to `url` and read the response into `out`, under the client timeout.
    pub fn postJson(self: *Client, url: []const u8, body: []const u8, out: []u8) !Response {
        switch (self.timeout) {
            .none => return self.sendJson(url, body, out),
            else => {},
        }
        const io = self.inner.io;
        var done: std.Io.Event = .unset;
        var future = try io.concurrent(postLeg, .{ self, url, body, out, &done });
        done.waitTimeout(io, self.timeout) catch |err| {
            // The cancel joins the child, so the child cannot write `out` after this returns.
            _ = future.cancel(io) catch undefined;
            return if (err == error.Timeout) Error.CloudTimeout else err;
        };
        return future.await(io);
    }

    /// GET `req.url` under the client timeout, and send `If-None-Match` when the caller holds a document.
    pub fn get(self: *Client, req: GetRequest) !Get {
        switch (self.timeout) {
            .none => return self.sendGet(req),
            else => {},
        }
        const io = self.inner.io;
        var done: std.Io.Event = .unset;
        var future = try io.concurrent(getLeg, .{ self, req, &done });
        done.waitTimeout(io, self.timeout) catch |err| {
            // The cancel joins the child, so the child cannot write the caller buffers after this returns.
            _ = future.cancel(io) catch undefined;
            return if (err == error.Timeout) Error.CloudTimeout else err;
        };
        return future.await(io);
    }

    /// POST a urlencoded form. Only a failure before the send reports `PreFlight`.
    pub fn postForm(self: *Client, req: FormRequest) !Response {
        std.debug.assert(req.body_out.len != 0); // The caller owns a response buffer.
        std.debug.assert(req.body_out.len <= max_oauth_response_bytes);
        const io = self.inner.io;
        const body = try encodeForm(self.inner.allocator, req.fields);
        defer self.inner.allocator.free(body);

        var leg: FormLeg = .{};
        var future = try io.concurrent(formLeg, .{ self, req, body, &leg });
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
    fn sendForm(self: *Client, req: FormRequest, body: []u8, leg: *FormLeg) !Response {
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
                    .content_type = .{ .override = "application/x-www-form-urlencoded" },
                    .accept_encoding = .omit,
                },
                .extra_headers = &.{.{ .name = "accept", .value = "application/json" }},
            });
            // The connect phase ended, so the read timeout owns every later failure.
            leg.connected.set(io);
            break :request opened catch |err| return switch (err) {
                error.UnsupportedUriScheme, error.UriMissingHost => error.BadUrl,
                error.OutOfMemory, error.Canceled => err,
                // The reference stops on any TLS error, so this port does too.
                error.TlsInitializationFailed => error.Ambiguous,
                // `request` only connects, so the server never read these bytes.
                else => error.PreFlight,
            };
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

    /// The client refuses a redirect, because a credential must never reach another origin.
    fn sendJson(self: *Client, url: []const u8, body: []const u8, out: []u8) !Response {
        std.debug.assert(out.len != 0); // The caller owns a response buffer.

        const uri = std.Uri.parse(url) catch return error.BadUrl;

        var writer: std.Io.Writer = .fixed(out);
        const result = self.inner.fetch(.{
            .location = .{ .uri = uri },
            .method = .POST,
            .payload = body,
            .redirect_behavior = .not_allowed,
            .headers = .{
                .content_type = .{ .override = "application/json" },
                .accept_encoding = .omit,
            },
            .extra_headers = &.{
                .{ .name = "accept", .value = "application/json, application/problem+json" },
            },
            .response_writer = &writer,
        }) catch |err| return switch (err) {
            // A full buffer is the only way the fixed writer fails.
            error.WriteFailed => error.ResponseTooLarge,
            error.UnsupportedUriScheme, error.UriMissingHost => error.BadUrl,
            else => err,
        };

        return .{ .status = @intFromEnum(result.status), .body = writer.buffered() };
    }

    /// The client advertises gzip, so a compressed document inflates here.
    fn sendGet(self: *Client, req: GetRequest) !Get {
        std.debug.assert(req.body_out.len != 0); // The caller owns a response buffer.

        const uri = std.Uri.parse(req.url) catch return error.BadUrl;

        const authorization = if (req.bearer.len != 0)
            try std.mem.concat(self.inner.allocator, u8, &.{ "Bearer ", req.bearer })
        else
            null;
        defer if (authorization) |value| self.inner.allocator.free(value);

        var extra: [3]std.http.Header = undefined;
        extra[0] = .{ .name = "accept", .value = "application/json, application/problem+json" };
        var extra_len: usize = 1;
        if (req.if_none_match.len != 0) {
            extra[extra_len] = .{ .name = "if-none-match", .value = req.if_none_match };
            extra_len += 1;
        }
        if (authorization) |value| {
            extra[extra_len] = .{ .name = "authorization", .value = value };
            extra_len += 1;
        }

        var request = self.inner.request(.GET, uri, .{
            .redirect_behavior = .not_allowed, // Never send the credential to another origin.
            // A short decompressed stream stalls the next request on a pooled connection.
            .keep_alive = false,
            .extra_headers = extra[0..extra_len],
        }) catch |err| return mapRequestError(err);
        defer request.deinit();

        try request.sendBodiless();
        var response = try request.receiveHead(&.{});
        const status: u16 = @intFromEnum(response.head.status);

        // The body reader invalidates every header string, so copy the ETag first.
        const etag = copyHeader(&response.head, "etag", req.etag_out);
        if (status == status_not_modified) return .{ .status = status, .body = &.{}, .etag = etag };

        // The gzip window is too large for a task stack, so it comes from the client allocator.
        const window = try self.inner.allocator.alloc(u8, std.compress.flate.max_window_len);
        defer self.inner.allocator.free(window);

        var transfer: [4096]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        const body = response.readerDecompressing(&transfer, &decompress, window);

        var writer: std.Io.Writer = .fixed(req.body_out);
        _ = body.streamRemaining(&writer) catch |err| return switch (err) {
            // A full buffer is the only way the fixed writer fails.
            error.WriteFailed => error.ResponseTooLarge,
            else => err,
        };

        return .{ .status = status, .body = writer.buffered(), .etag = etag };
    }
};

/// Run one GET in a child task. The parent waits for it, so the caller buffers stay valid.
fn getLeg(self: *Client, req: GetRequest, done: *std.Io.Event) !Get {
    defer done.set(self.inner.io);
    return self.sendGet(req);
}

/// Run one POST in a child task. The parent waits for it, so `out` stays valid.
fn postLeg(self: *Client, url: []const u8, body: []const u8, out: []u8, done: *std.Io.Event) !Response {
    defer done.set(self.inner.io);
    return self.sendJson(url, body, out);
}

/// Run one form POST in a child task. The parent waits for it, so the caller buffers stay valid.
fn formLeg(self: *Client, req: FormRequest, body: []u8, leg: *FormLeg) !Response {
    defer leg.done.set(self.inner.io);
    return self.sendForm(req, body, leg);
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

/// Copy the first value of `name` into `out`. An absent or oversize header gives an empty value.
fn copyHeader(head: *const std.http.Client.Response.Head, name: []const u8, out: []u8) []const u8 {
    var it = head.iterateHeaders();
    while (it.next()) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, name)) continue;
        if (header.value.len > out.len) return &.{};
        @memcpy(out[0..header.value.len], header.value);
        return out[0..header.value.len];
    }
    return &.{};
}

fn mapRequestError(err: anyerror) anyerror {
    return switch (err) {
        error.UnsupportedUriScheme, error.UriMissingHost => error.BadUrl,
        else => err,
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
    var client: Client = .init(c.gpa, c.io, .none);
    defer client.deinit();
    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/token", .{c.port});
    const out = try c.gpa.alloc(u8, c.out_len);
    defer c.gpa.free(out);
    const response = try client.postForm(.{
        .url = url,
        .fields = &.{.{ .name = "grant_type", .value = "refresh_token" }},
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

test "a form post refuses a redirect instead of sending the credential onward" {
    var server: FormServer = .{ .mode = .redirect };
    var client: FormClient = .{};
    try exchangeForm(&server, &client);

    // `not_allowed` names the refusal this way. The credential never reaches the other origin.
    try testing.expectEqual(@as(?anyerror, error.TooManyHttpRedirects), client.err);
    try testing.expect(client.err.? != Error.PreFlight); // A refusal must never look retryable.
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

test "a timeout after the send reports ambiguity, never a pre-flight failure" {
    var server: FormServer = .{ .mode = .stall };
    var client: FormClient = .{
        .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromMilliseconds(50) } },
    };
    try exchangeForm(&server, &client);

    // A retry here could look like token reuse and cost the whole grant.
    try testing.expectEqual(@as(?anyerror, Error.Ambiguous), client.err);
}

test "postJson rejects a url that is not a request target" {
    var client: Client = .init(testing.allocator, testing.io, .none);
    defer client.deinit();

    var out: [64]u8 = undefined;
    try testing.expectError(error.BadUrl, client.postJson("not a url", "{}", &out));
    try testing.expectError(error.BadUrl, client.postJson("mailto:a@b.example", "{}", &out));
}
