//! One JSON request and one bounded JSON response. The caller owns the response buffer.

const std = @import("std");

/// Size the buffer for a control-plane document. The catalog caller sizes its own.
pub const max_response_bytes = 64 * 1024;

pub const Error = error{
    /// The `--cloud` value is not a URL that this client can request.
    BadUrl,
    /// The server sent more than `max_response_bytes`.
    ResponseTooLarge,
    /// The request passed its timeout. The caller degrades, because the control plane is optional.
    CloudTimeout,
};

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

test "postJson rejects a url that is not a request target" {
    var client: Client = .init(testing.allocator, testing.io, .none);
    defer client.deinit();

    var out: [64]u8 = undefined;
    try testing.expectError(error.BadUrl, client.postJson("not a url", "{}", &out));
    try testing.expectError(error.BadUrl, client.postJson("mailto:a@b.example", "{}", &out));
}
