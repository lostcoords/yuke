//! One JSON request and one bounded JSON response over HTTPS. The control plane answers with a
//! small document, so the caller owns the response buffer and the transport never allocates it.

const std = @import("std");

/// Size the buffer for a control-plane document that carries no catalog.
/// A problem document and a credential stay far below this. The catalog caller sizes its own buffer.
pub const max_response_bytes = 64 * 1024;

pub const Error = error{
    /// The `--cloud` value is not a URL that this client can request.
    BadUrl,
    /// The server sent more than `max_response_bytes`.
    ResponseTooLarge,
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

    pub fn init(gpa: std.mem.Allocator, io: std.Io) Client {
        return .{ .inner = .{ .allocator = gpa, .io = io } };
    }

    pub fn deinit(self: *Client) void {
        self.inner.deinit();
    }

    /// POST `body` as JSON to `url` and read the response into `out`.
    /// The client refuses a redirect, because a credential must never reach another origin.
    pub fn postJson(self: *Client, url: []const u8, body: []const u8, out: []u8) !Response {
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

    /// GET `req.url`, and send `If-None-Match` when the caller holds a document.
    /// The client advertises gzip, so a compressed document inflates here.
    pub fn get(self: *Client, req: GetRequest) !Get {
        std.debug.assert(req.body_out.len != 0); // The caller owns a response buffer.

        const uri = std.Uri.parse(req.url) catch return error.BadUrl;

        var extra: [2]std.http.Header = undefined;
        extra[0] = .{ .name = "accept", .value = "application/json, application/problem+json" };
        var extra_len: usize = 1;
        if (req.if_none_match.len != 0) {
            extra[extra_len] = .{ .name = "if-none-match", .value = req.if_none_match };
            extra_len += 1;
        }

        var request = self.inner.request(.GET, uri, .{
            .redirect_behavior = .not_allowed, // Never send the credential to another origin.
            // A decompressed body can leave the transfer stream short of its end, and a pooled
            // connection then stalls the next request. One connection per check costs nothing here.
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
    var client: Client = .init(testing.allocator, testing.io);
    defer client.deinit();

    var out: [64]u8 = undefined;
    try testing.expectError(error.BadUrl, client.postJson("not a url", "{}", &out));
    try testing.expectError(error.BadUrl, client.postJson("mailto:a@b.example", "{}", &out));
}
