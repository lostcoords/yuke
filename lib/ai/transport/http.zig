//! Stream one SSE response through `std.http.Client` with caller-supplied `std.Io`.

const std = @import("std");
const route = @import("../route.zig");
const transport = @import("../transport.zig");
const answer = @import("../answer.zig");

const Allocator = std.mem.Allocator;

/// Define stable classes for provider answers and transport failures; the caller decides the outcome.
pub const Error = answer.Error || error{
    IdleTimeout, // The read stalled past the deadline. The request may already be held.
    RedirectRefused, // The client must not follow a 3xx response.
    BadUrl,
    InvalidHeaders,
    ConnectFailed, // The socket or the TLS handshake never carried a request.
    DnsFailed, // The provider host did not resolve.
    ConnectionLost, // An open connection broke during the exchange.
    MalformedResponse, // The peer sent a head, a chunk, or an encoding the client refuses.
    CertificateBundleLoadFailure, // `std` names this failure, so the transport keeps the name.
};

/// One executor drives every call on this shared client, because `std.http.Client` reads `now` outside its own lock.
pub const HttpTransport = struct {
    client: std.http.Client,
    idle_timeout: ?std.Io.Duration,
    /// The client sends this value on every request, so a gateway can identify the agent.
    user_agent: []const u8,

    /// The client dials and reads through `io`, and borrows `user_agent` until `deinit`.
    pub fn init(gpa: Allocator, io: std.Io, idle_timeout: ?std.Io.Duration, user_agent: []const u8) HttpTransport {
        std.debug.assert(route.validHeaders(&.{.{ .name = "user-agent", .value = user_agent }}));
        return .{ .client = .{ .allocator = gpa, .io = io }, .idle_timeout = idle_timeout, .user_agent = user_agent };
    }

    /// Deinitialize the client. Every response body must deinit first.
    pub fn deinit(self: *HttpTransport) void {
        self.client.deinit();
    }

    /// Move the clock `std` pins at its first handshake, so a certificate that rotates mid-process still verifies.
    fn refreshCertificateClock(self: *HttpTransport) void {
        const io = self.client.io;
        // `std` writes the clock under this lock, so this write takes it too.
        self.client.ca_bundle_lock.lockUncancelable(io);
        defer self.client.ca_bundle_lock.unlock(io);
        if (self.client.now != null) self.client.now = std.Io.Clock.real.now(io);
    }

    pub fn transportFor(self: *HttpTransport) transport.Transport {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable: transport.Transport.VTable = .{ .open = open };

    fn open(ctx: *anyopaque, arena: Allocator, request: transport.Request, info: *transport.AttemptInfo) anyerror!transport.ResponseBody {
        const self: *HttpTransport = @ptrCast(@alignCast(ctx));
        if (!route.validHeaders(request.headers)) return Error.InvalidHeaders;
        const uri = std.Uri.parse(request.url) catch return Error.BadUrl;
        self.refreshCertificateClock();

        // The provider sends SSE, so request it. The transport owns Accept and User-Agent, so a route copy is dropped.
        const extra = try arena.alloc(std.http.Header, request.headers.len + 1);
        extra[0] = .{ .name = "accept", .value = "text/event-stream" };
        var extra_len: usize = 1;
        for (request.headers) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "accept") or std.ascii.eqlIgnoreCase(h.name, "user-agent")) continue;
            extra[extra_len] = .{ .name = h.name, .value = h.value };
            extra_len += 1;
        }

        // The body borrows the arena, and every caller deinits it before that arena dies.
        const hb = try arena.create(HttpBody);
        hb.* = .{
            .io = self.client.io,
            .idle_timeout = if (self.idle_timeout) |timeout| .{ .duration = .{
                .clock = .awake,
                .raw = timeout,
            } } else .none,
            .request = undefined,
            .response = undefined,
            .transfer_buffer = undefined,
            .reader = undefined,
        };

        // Connect, send, and the head wait share the idle deadline, so a silent peer never holds the call.
        try hb.bounded(HttpBody.exchangeHead, .{ &self.client, uri, extra[0..extra_len], request.body, self.user_agent, info }, HttpBody.abandon);
        errdefer hb.abandon();
        try readHeaders(hb.response.head, arena, info); // The reader below invalidates these slices.
        if (hb.response.head.status != .ok) {
            const status: u16 = @intFromEnum(hb.response.head.status);
            info.status = status;
            info.body = try readErrorBody(hb, arena);
            return answer.fromStatus(arena, status, info.body);
        }

        hb.reader = hb.response.reader(&hb.transfer_buffer); // This invalidates the head string slices.
        return .{ .ctx = hb, .vtable = &HttpBody.vtable };
    }
};

/// This response owns the request and the transfer buffer until the caller invokes deinit.
const HttpBody = struct {
    io: std.Io,
    idle_timeout: std.Io.Timeout,
    request: std.http.Client.Request,
    response: std.http.Client.Response,
    /// The transfer chunk for the body reader. The SSE parser copies any line that passes it.
    transfer_buffer: [8192]u8,
    reader: *std.Io.Reader,

    const vtable: transport.ResponseBody.VTable = .{ .peek = peek, .toss = toss, .deinit = deinit };

    fn peek(ctx: *anyopaque) anyerror![]const u8 {
        const self: *HttpBody = @ptrCast(@alignCast(ctx));
        return self.peekWithIdleTimeout();
    }

    /// Close the connection so the pool never reuses a partial exchange, then release the request.
    fn abandon(self: *HttpBody) void {
        if (self.request.connection) |c| c.closing = true;
        self.request.deinit();
    }

    /// Drop what the parser read. The reader keeps the peeked bytes until the next fill.
    fn toss(ctx: *anyopaque, count: usize) void {
        const self: *HttpBody = @ptrCast(@alignCast(ctx));
        std.debug.assert(count <= self.reader.bufferedLen()); // A toss never passes the last peek.
        self.reader.toss(count);
    }

    /// Bound each fill with the idle deadline.
    fn peekWithIdleTimeout(self: *HttpBody) anyerror![]const u8 {
        // The reader already holds bytes, so this call needs no fill and no child task.
        if (self.reader.bufferedLen() > 0) return self.reader.buffered();
        return self.bounded(peekRaw, .{}, null);
    }

    /// Run `leg` in a child task under the idle deadline. The child separates a cancel from a timeout.
    fn bounded(self: *HttpBody, comptime leg: anytype, args: anytype, comptime late: ?fn (*HttpBody) void) anyerror!Payload(leg) {
        if (self.idle_timeout == .none) return @call(.auto, leg, .{self} ++ args);
        const Leg = struct {
            fn run(body: *HttpBody, done: *std.Io.Event, leg_args: @TypeOf(args)) anyerror!Payload(leg) {
                defer done.set(body.io);
                return @call(.auto, leg, .{body} ++ leg_args);
            }
        };
        var done: std.Io.Event = .unset;
        var future = try self.io.concurrent(Leg.run, .{ self, &done, args });
        done.waitTimeout(self.io, self.idle_timeout) catch |err| {
            // Cancel joins the child. A leg that finished anyway releases what it made.
            if (future.cancel(self.io)) |_| {
                if (late) |release| release(self);
            } else |_| {}
            return switch (err) {
                error.Timeout => Error.IdleTimeout,
                else => err,
            };
        };
        return future.await(self.io);
    }

    fn Payload(comptime leg: anytype) type {
        return @typeInfo(@typeInfo(@TypeOf(leg)).@"fn".return_type.?).error_union.payload;
    }

    /// Open the connection, send the body, and read the head. A failure releases the request.
    fn exchangeHead(self: *HttpBody, client: *std.http.Client, uri: std.Uri, headers: []const std.http.Header, body: []u8, user_agent: []const u8, info: *transport.AttemptInfo) anyerror!void {
        self.request = client.request(.POST, uri, .{
            .redirect_behavior = .not_allowed, // Never resend the key to another origin.
            .keep_alive = false, // The client sends one request. A mid-stream connection never returns to the pool.
            .headers = .{
                .content_type = .{ .override = "application/json" },
                .accept_encoding = .omit,
                .user_agent = .{ .override = user_agent },
            },
            .extra_headers = headers,
        }) catch |err| return mapExchange(null, err);
        errdefer self.abandon();
        // The provider may hold the request from this point. A later transport fault is ambiguous.
        info.delivery = .possibly_sent;
        self.request.sendBodyComplete(body) catch |err| return mapExchange(self.request.connection, err);
        self.response = self.request.receiveHead(&.{}) catch |err| return mapExchange(self.request.connection, err);
    }

    /// Return an empty slice only at the end of the stream, as ResponseBody requires.
    fn peekRaw(self: *HttpBody) anyerror![]const u8 {
        self.reader.fill(1) catch |err| switch (err) {
            error.EndOfStream => return "",
            error.ReadFailed => {
                // A malformed or truncated body sets bodyErr without a socket error. Return it as a peer error.
                if (self.response.bodyErr()) |be| {
                    if (self.request.connection) |c| c.closing = true;
                    return switch (be) {
                        error.HttpChunkTruncated => Error.ConnectionLost,
                        error.HttpChunkInvalid, error.HttpHeadersOversize => Error.MalformedResponse,
                    };
                }
                return readCause(self.request.connection.?); // A socket failure sets the read error instead.
            },
        };
        const have = self.reader.buffered();
        std.debug.assert(have.len > 0); // fill(1) returned, so the reader holds at least one byte
        return have;
    }

    fn deinit(ctx: *anyopaque) void {
        const self: *HttpBody = @ptrCast(@alignCast(ctx));
        self.request.deinit(); // The arena owns the struct, so only the request needs a release.
    }
};

/// Read the retry hints and the request id. The id is copied, because the body reader invalidates the head.
fn readHeaders(head: std.http.Client.Response.Head, arena: Allocator, info: *transport.AttemptInfo) !void {
    var it = head.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "request-id") or std.ascii.eqlIgnoreCase(h.name, "x-request-id")) {
            if (info.request_id == null) info.request_id = try arena.dupe(u8, std.mem.trim(u8, h.value, " "));
        } else if (std.ascii.eqlIgnoreCase(h.name, "retry-after-ms")) {
            // The millisecond form wins. Both SDK families read it first.
            if (std.fmt.parseInt(u64, std.mem.trim(u8, h.value, " "), 10)) |ms| info.retry_after_ms = ms else |_| {}
        } else if (std.ascii.eqlIgnoreCase(h.name, "retry-after")) {
            if (info.retry_after_ms != null) continue;
            if (std.fmt.parseInt(u64, std.mem.trim(u8, h.value, " "), 10)) |secs| {
                info.retry_after_ms = secs *| 1000;
            } else |_| {} // An HTTP-date form needs a clock, so the caller uses its own delay.
        } else if (std.ascii.eqlIgnoreCase(h.name, "x-should-retry")) {
            if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, h.value, " "), "false")) info.no_retry = true;
        }
    }
}

/// Name one exchange failure through an exhaustive switch, so a `std` rename breaks the build.
fn mapExchange(conn: ?*std.http.Client.Connection, err: std.http.Client.Request.ReceiveHeadError) anyerror {
    return switch (err) {
        error.OutOfMemory, error.Canceled => |e| e,
        error.UnsupportedUriScheme, error.UriMissingHost => Error.BadUrl,
        error.CertificateBundleLoadFailure => Error.CertificateBundleLoadFailure,
        // The client never follows a redirect, so every redirect step is one refusal.
        error.TooManyHttpRedirects,
        error.RedirectRequiresResend,
        error.HttpRedirectLocationMissing,
        error.HttpRedirectLocationOversize,
        error.HttpRedirectLocationInvalid,
        => Error.RedirectRefused,
        error.UnknownHostName,
        error.NoAddressReturned,
        error.NameServerFailure,
        error.ResolvConfParseFailed,
        error.InvalidDnsARecord,
        error.InvalidDnsAAAARecord,
        error.InvalidDnsCnameRecord,
        error.DetectingNetworkConfigurationFailed,
        => Error.DnsFailed,
        error.HttpHeadersOversize,
        error.HttpHeadersInvalid,
        error.HttpContentEncodingUnsupported,
        error.HttpChunkInvalid,
        => Error.MalformedResponse,
        error.HttpRequestTruncated,
        error.HttpConnectionClosing,
        error.HttpChunkTruncated,
        error.WriteFailed,
        => Error.ConnectionLost,
        error.ReadFailed => readCause(conn.?), // Only an open connection reads, so one exists here.
        // Nothing below reaches the provider, whatever stops the connect.
        error.Timeout,
        error.SystemResources,
        error.ConnectionResetByPeer,
        error.WouldBlock,
        error.AccessDenied,
        error.Unexpected,
        error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded,
        error.NetworkDown,
        error.AddressInUse,
        error.AddressUnavailable,
        error.AddressFamilyUnsupported,
        error.ProtocolUnsupportedBySystem,
        error.ProtocolUnsupportedByAddressFamily,
        error.SocketModeUnsupported,
        error.OptionUnsupported,
        error.ConnectionPending,
        error.ConnectionRefused,
        error.HostUnreachable,
        error.NetworkUnreachable,
        error.TlsInitializationFailed,
        => Error.ConnectFailed,
    };
}

/// Unwrap a read fault, where every socket and TLS cause names one broken connection.
fn readCause(conn: *std.http.Client.Connection) anyerror {
    return switch (conn.getReadError().?) { // A read fault always records its cause.
        error.Canceled => error.Canceled,
        else => Error.ConnectionLost,
    };
}

/// Read the first bytes of an error body into `arena`. A read fault answers null; only a cancel propagates.
fn readErrorBody(hb: *HttpBody, arena: Allocator) error{ OutOfMemory, Canceled }!?[]const u8 {
    hb.reader = hb.response.reader(&hb.transfer_buffer);
    var buf: [transport.AttemptInfo.max_error_body_bytes]u8 = undefined;
    var len: usize = 0;
    // One peek can hold part of the body only.
    while (len < buf.len) {
        const chunk = hb.peekWithIdleTimeout() catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => return null,
        };
        if (chunk.len == 0) break;
        const take = @min(chunk.len, buf.len - len);
        @memcpy(buf[len..][0..take], chunk[0..take]);
        len += take;
        hb.reader.toss(take);
    }
    return try arena.dupe(u8, buf[0..len]);
}

const testing = std.testing;

const test_user_agent = "ai-test/0";

const canned_sse =
    "data: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const Server = struct {
    io: std.Io = undefined,
    listener: *std.Io.net.Server = undefined,
    body: []const u8,
    status: std.http.Status,
    location: ?[]const u8 = null, // A redirect target. The client must never follow it.
    request_id: ?[]const u8 = null, // Sent as `request-id` when set.
    stall: bool = false, // Send the body, then wait on `release`. Keep the stream open.
    silent: bool = false, // Read the request, then wait on `release` and send no head.
    release: ?*std.Io.Event = null,
    err: ?anyerror = null,
    user_agent: ?[]const u8 = null, // The last User-Agent value the client sent, stored in `user_agent_buf`.
    user_agent_buf: [64]u8 = undefined,
    user_agent_count: usize = 0,
};

/// Accept one connection and stream `body` with `status`. A test drives this on the run's executor.
fn serveOnce(server: *Server) void {
    serveOnceInner(server) catch |err| {
        server.err = err;
    };
}

fn serveOnceInner(s: *Server) !void {
    const stream = try s.listener.accept(s.io);
    defer stream.close(s.io);
    var read_buf: [8192]u8 = undefined;
    var write_buf: [8192]u8 = undefined;
    var reader = stream.reader(s.io, &read_buf);
    var writer = stream.writer(s.io, &write_buf);
    var server = std.http.Server.init(&reader.interface, &writer.interface);
    var request = try server.receiveHead();
    var it = request.iterateHeaders();
    while (it.next()) |h| if (std.ascii.eqlIgnoreCase(h.name, "user-agent")) {
        s.user_agent = s.user_agent_buf[0..h.value.len];
        @memcpy(s.user_agent_buf[0..h.value.len], h.value);
        s.user_agent_count += 1;
    };
    if (s.silent) {
        if (s.release) |r| r.wait(s.io) catch {};
        return;
    }

    var header_storage: [3]std.http.Header = .{
        .{ .name = "content-type", .value = "text/event-stream" },
        undefined,
        undefined,
    };
    var header_len: usize = 1;
    if (s.location) |loc| {
        header_storage[header_len] = .{ .name = "location", .value = loc };
        header_len += 1;
    }
    if (s.request_id) |id| {
        header_storage[header_len] = .{ .name = "request-id", .value = id };
        header_len += 1;
    }

    var body_buf: [1024]u8 = undefined;
    var resp = try request.respondStreaming(&body_buf, .{ .respond_options = .{
        .status = s.status,
        .keep_alive = false,
        .extra_headers = header_storage[0..header_len],
    } });
    try resp.writer.writeAll(s.body);
    try resp.flush();
    if (s.stall) {
        if (s.release) |r| r.wait(s.io) catch {}; // The client releases the server after the read times out.
    }
    try resp.end();
}

const ClientOut = struct {
    gpa: Allocator = undefined, // `exchange` binds gpa, io, and port.
    io: std.Io = undefined,
    port: u16 = undefined,
    idle: ?std.Io.Duration = null,
    release: ?*std.Io.Event = null, // Signal the stalled server to end after the read returns.
    bytes: std.ArrayList(u8) = .empty,
    err: ?anyerror = null,
    status: ?u16 = null, // Copies of the attempt info, because its arena dies with the client task.
    request_id: std.ArrayList(u8) = .empty,
    error_body: std.ArrayList(u8) = .empty,
};

fn clientTask(out: *ClientOut) void {
    defer if (out.release) |r| r.set(out.io);
    runClient(out) catch |err| {
        out.err = err;
    };
}

fn runClient(out: *ClientOut) !void {
    var http = HttpTransport.init(out.gpa, out.io, out.idle, test_user_agent);
    defer http.deinit();
    var arena = std.heap.ArenaAllocator.init(out.gpa);
    defer arena.deinit();
    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/messages", .{out.port});
    // A route that pins its own User-Agent must not produce a second header line.
    const headers = [_]route.Header{
        .{ .name = "x-api-key", .value = "test-key" },
        .{ .name = "User-Agent", .value = "pinned/9" },
    };
    var request_body: [0]u8 = .{};
    var info: transport.AttemptInfo = .{};
    const opened = http.transportFor().open(arena.allocator(), .{ .url = url, .headers = &headers, .body = &request_body }, &info);
    out.status = info.status;
    if (info.request_id) |id| try out.request_id.appendSlice(out.gpa, id);
    if (info.body) |text| try out.error_body.appendSlice(out.gpa, text);
    const body = try opened;
    defer body.deinit();
    while (true) {
        const chunk = try body.peek();
        if (chunk.len == 0) break;
        try out.bytes.appendSlice(out.gpa, chunk);
        body.toss(chunk.len);
    }
}

/// Run one server and one client exchange on a private loopback port. The test reads `srv` and `out`.
fn exchange(srv: *Server, out: *ClientOut) !void {
    const io = testing.io;
    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try addr.listen(io, .{});
    defer listener.deinit(io);
    srv.io = io;
    srv.listener = &listener;
    out.gpa = testing.allocator;
    out.io = io;
    out.port = listener.socket.address.getPort();

    var server = try io.concurrent(serveOnce, .{srv});
    var client = try io.concurrent(clientTask, .{out});
    client.await(io);
    server.await(io);
}

test "the transport moves the certificate clock but leaves the first bundle load to std" {
    var t: HttpTransport = .init(testing.allocator, testing.io, null, test_user_agent);
    defer t.deinit();

    // A clock set here stops `std` from ever loading the root bundle, so a fresh client keeps none.
    t.refreshCertificateClock();
    try testing.expectEqual(@as(?std.Io.Timestamp, null), t.client.now);

    // A pin that outlives the certificate it verified rejects every later rotation.
    t.client.now = .fromNanoseconds(1);
    t.refreshCertificateClock();
    try testing.expect(t.client.now.?.toSeconds() > 1_700_000_000);
}

test "streams an SSE response body over http" {
    var srv: Server = .{ .body = canned_sse, .status = .ok };
    var out: ClientOut = .{};
    defer out.bytes.deinit(testing.allocator);
    try exchange(&srv, &out);

    if (srv.err) |err| return err;
    if (out.err) |err| return err;
    try testing.expectEqualStrings(canned_sse, out.bytes.items);
    // The transport names the agent once, whatever the route pins, so a gateway does not read the traffic as a script.
    try testing.expectEqualStrings(test_user_agent, srv.user_agent.?);
    try testing.expectEqual(@as(usize, 1), srv.user_agent_count);
}

test "a non-200 status maps to a transport error" {
    var srv: Server = .{ .body = "", .status = .unauthorized };
    var out: ClientOut = .{};
    defer out.bytes.deinit(testing.allocator);
    defer out.request_id.deinit(testing.allocator);
    defer out.error_body.deinit(testing.allocator);
    try exchange(&srv, &out);

    try testing.expectEqual(@as(?anyerror, Error.AuthFailed), out.err);
    try testing.expectEqual(@as(usize, 0), out.bytes.items.len);
    try testing.expectEqual(@as(?u16, 401), out.status);
    try testing.expectEqual(@as(usize, 0), out.request_id.items.len);
    try testing.expectEqual(@as(usize, 0), out.error_body.items.len);
}

test "a non-200 answer keeps its status, request id, and a bounded body" {
    const long = "{\"error\":{\"type\":\"invalid_request_error\",\"message\":\"" ++ "x" ** 5000 ++ "\"}}";
    var srv: Server = .{ .body = long, .status = .bad_request, .request_id = "req_123" };
    var out: ClientOut = .{};
    defer out.bytes.deinit(testing.allocator);
    defer out.request_id.deinit(testing.allocator);
    defer out.error_body.deinit(testing.allocator);
    try exchange(&srv, &out);

    try testing.expectEqual(@as(?anyerror, Error.BadStatus), out.err);
    try testing.expectEqual(@as(?u16, 400), out.status);
    try testing.expectEqualStrings("req_123", out.request_id.items);
    try testing.expectEqual(transport.AttemptInfo.max_error_body_bytes, out.error_body.items.len);
    try testing.expectEqualStrings(long[0..transport.AttemptInfo.max_error_body_bytes], out.error_body.items);
}

test "a stalled stream returns an idle timeout" {
    var release: std.Io.Event = .unset;
    // The server sends the head, then holds the stream open with no body until the client releases it.
    var srv: Server = .{ .body = "", .status = .ok, .stall = true, .release = &release };
    var out: ClientOut = .{ .idle = std.Io.Duration.fromMilliseconds(50), .release = &release };
    defer out.bytes.deinit(testing.allocator);
    try exchange(&srv, &out);

    try testing.expectEqual(@as(?anyerror, Error.IdleTimeout), out.err);
}

test "a peer that never sends a head returns an idle timeout" {
    var release: std.Io.Event = .unset;
    var srv: Server = .{ .body = "", .status = .ok, .silent = true, .release = &release };
    var out: ClientOut = .{ .idle = std.Io.Duration.fromMilliseconds(50), .release = &release };
    defer out.bytes.deinit(testing.allocator);
    try exchange(&srv, &out);

    try testing.expectEqual(@as(?anyerror, Error.IdleTimeout), out.err);
}

test "a redirect is rejected without following it" {
    // The client must reject a 302 response to another origin to keep the key private.
    var srv: Server = .{ .body = "", .status = .found, .location = "http://evil.example/steal" };
    var out: ClientOut = .{};
    defer out.bytes.deinit(testing.allocator);
    try exchange(&srv, &out);

    // The receiveHead call rejects the 3xx, so the key stays on the original connection.
    try testing.expectEqual(@as(?anyerror, Error.RedirectRefused), out.err);
    try testing.expectEqual(@as(usize, 0), out.bytes.items.len);
}

test "invalid headers return an error before std HTTP sees them" {
    var client = HttpTransport.init(testing.allocator, testing.io, null, test_user_agent);
    defer client.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var body: [0]u8 = .{};
    var info: transport.AttemptInfo = .{};

    try testing.expectError(Error.InvalidHeaders, client.transportFor().open(arena.allocator(), .{
        .url = "https://example.com/v1/messages",
        .headers = &.{.{ .name = "bad:name", .value = "x" }},
        .body = &body,
    }, &info));
    try testing.expectEqual(transport.AttemptInfo.Delivery.definitely_unsent, info.delivery);
}

test "a 429 body distinguishes quota, rate limit, and unknown failures" {
    const cases = [_]struct { body: []const u8, expected: anyerror }{
        .{ .body = "{\"error\":{\"code\":\"insufficient_quota\"}}", .expected = Error.QuotaExhausted },
        .{ .body = "{\"type\":\"error\",\"error\":{\"type\":\"rate_limit_error\",\"details\":{\"error_code\":\"enforced_spend_limit_reached\"}}}", .expected = Error.QuotaExhausted },
        .{ .body = "", .expected = Error.RateLimitUnknown },
        .{ .body = "{\"error\":{\"code\":\"rate_limit_exceeded\"}}", .expected = Error.RateLimited },
    };

    for (cases) |case| {
        var srv: Server = .{ .body = case.body, .status = .too_many_requests };
        var out: ClientOut = .{};
        defer out.bytes.deinit(testing.allocator);
        defer out.request_id.deinit(testing.allocator);
        defer out.error_body.deinit(testing.allocator);
        try exchange(&srv, &out);
        try testing.expectEqual(@as(?anyerror, case.expected), out.err);
        try testing.expectEqual(@as(?u16, 429), out.status);
        try testing.expectEqualStrings(case.body, out.error_body.items);
    }
}
