//! This provider transport streams an SSE response body through one std.http.Client request.
//! A run task can cancel a blocked read because the client dials through zio std.Io.

const std = @import("std");
const zio = @import("zio");
const transport = @import("../transport.zig");
const json = @import("../stream/json.zig");

const Allocator = std.mem.Allocator;

/// This error set defines stable classes for non-200 statuses and transport failures. The run task decides the outcome.
pub const Error = error{
    AuthFailed, // 401
    PermissionDenied, // 403
    RateLimited, // 429 with a body and no quota code
    QuotaExhausted, // 429 with a quota or spend code
    RateLimitUnknown, // 429 the engine could not read or decode
    ServerError, // 5xx
    BadStatus, // Any other non-200 status.
    Timeout, // 408 or 504. The provider answered.
    IdleTimeout, // The read stalled past the deadline. The request may already be held.
    RedirectRefused, // The client must not follow a 3xx response.
    BadUrl,
};

/// The App owns one shared client and injects its borrowed transport into the engine.
pub const HttpTransport = struct {
    client: std.http.Client,
    idle_timeout: ?std.Io.Duration,

    /// The client dials and reads through `io`. Pass the zio reactor io so a cancel reaches the socket.
    pub fn init(gpa: Allocator, io: std.Io, idle_timeout: ?std.Io.Duration) HttpTransport {
        return .{ .client = .{ .allocator = gpa, .io = io }, .idle_timeout = idle_timeout };
    }

    /// Deinitialize the client. Every response body must deinit first.
    pub fn deinit(self: *HttpTransport) void {
        self.client.deinit();
    }

    pub fn transportFor(self: *HttpTransport) transport.Transport {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable: transport.Transport.VTable = .{ .open = open };

    fn open(ctx: *anyopaque, arena: Allocator, request: transport.Request, info: *transport.AttemptInfo) anyerror!transport.ResponseBody {
        const self: *HttpTransport = @ptrCast(@alignCast(ctx));
        const uri = std.Uri.parse(request.url) catch return Error.BadUrl;

        // The provider sends SSE, so request it. This Accept header overrides a caller Accept header.
        const extra = try arena.alloc(std.http.Header, request.headers.len + 1);
        extra[0] = .{ .name = "accept", .value = "text/event-stream" };
        var extra_len: usize = 1;
        for (request.headers) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "accept")) continue;
            extra[extra_len] = .{ .name = h.name, .value = h.value };
            extra_len += 1;
        }

        const hb = try self.client.allocator.create(HttpBody);
        errdefer self.client.allocator.destroy(hb);
        hb.* = .{
            .gpa = self.client.allocator,
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

        hb.request = try self.client.request(.POST, uri, .{
            .redirect_behavior = .not_allowed, // Never resend the key to another origin.
            .keep_alive = false, // The client sends one request. A mid-stream connection never returns to the pool.
            .headers = .{ .content_type = .{ .override = "application/json" }, .accept_encoding = .omit },
            .extra_headers = extra[0..extra_len],
        });
        // A failed send or read leaves a partial exchange. Close the connection so the pool never reuses it.
        errdefer {
            if (hb.request.connection) |c| c.closing = true;
            hb.request.deinit();
        }

        // The provider may hold the request from this point. A later transport fault is ambiguous.
        info.delivery = .possibly_sent;
        try hb.request.sendBodyComplete(request.body);
        hb.response = hb.request.receiveHead(&.{}) catch |err| switch (err) {
            error.TooManyHttpRedirects => return Error.RedirectRefused, // Never follow a redirect.
            else => return err,
        };
        readRetryHeaders(hb.response.head, info); // The reader below invalidates these slices.
        if (hb.response.head.status != .ok) {
            if (@intFromEnum(hb.response.head.status) == 429) return classify429(hb, arena);
            return mapStatus(hb.response.head.status);
        }

        hb.reader = hb.response.reader(&hb.transfer_buffer); // This invalidates the head string slices.
        return .{ .ctx = hb, .vtable = &HttpBody.vtable };
    }
};

/// This response owns the request and the transfer buffer until the caller invokes deinit.
const HttpBody = struct {
    gpa: Allocator,
    io: std.Io,
    idle_timeout: std.Io.Timeout,
    request: std.http.Client.Request,
    response: std.http.Client.Response,
    transfer_buffer: [4096]u8,
    reader: *std.Io.Reader,

    const vtable: transport.ResponseBody.VTable = .{ .read = read, .deinit = deinit };

    fn read(ctx: *anyopaque, buf: []u8) anyerror!usize {
        std.debug.assert(buf.len > 0);
        const self: *HttpBody = @ptrCast(@alignCast(ctx));
        return self.readWithIdleTimeout(buf);
    }

    /// Bound each read with the idle deadline. A read past the deadline maps to Error.Timeout.
    /// A run cancel yields error.Canceled. The child read separates it from the deadline.
    fn readWithIdleTimeout(self: *HttpBody, buf: []u8) anyerror!usize {
        switch (self.idle_timeout) {
            .none => return self.readRaw(buf),
            else => {},
        }
        // The reader already holds bytes, so no child task is needed.
        if (self.reader.bufferedLen() > 0) return self.readRaw(buf);

        var done: std.Io.Event = .unset;
        var future = try self.io.concurrent(readLeg, .{ self, buf, &done });
        done.waitTimeout(self.io, self.idle_timeout) catch |err| {
            _ = future.cancel(self.io) catch 0; // Cancel joins the child before this function returns, so the child cannot access buf.
            return switch (err) {
                error.Timeout => Error.IdleTimeout,
                else => err,
            };
        };
        return future.await(self.io);
    }

    /// Read one chunk in a child task. Set `done` after the read.
    fn readLeg(self: *HttpBody, buf: []u8, done: *std.Io.Event) anyerror!usize {
        defer done.set(self.io);
        return self.readRaw(buf);
    }

    /// Return the bytes the stream has now, never a full buffer.
    /// `readSliceShort` returns short only at end of stream, so it would hold each SSE event until 4 KiB arrived.
    fn readAvailable(self: *HttpBody, buf: []u8) std.Io.Reader.Error!usize {
        self.reader.fill(1) catch |err| switch (err) {
            error.EndOfStream => return 0,
            else => |e| return e,
        };
        const have = self.reader.buffered();
        const n = @min(have.len, buf.len);
        @memcpy(buf[0..n], have[0..n]);
        self.reader.toss(n);
        std.debug.assert(n > 0); // fill(1) returned, so the reader holds at least one byte
        return n;
    }

    /// Return zero only at end of stream, as ResponseBody requires.
    fn readRaw(self: *HttpBody, buf: []u8) anyerror!usize {
        return self.readAvailable(buf) catch |err| switch (err) {
            error.ReadFailed => {
                // A malformed or truncated body sets bodyErr without a socket error. Return it as a peer error.
                if (self.response.bodyErr()) |be| {
                    if (self.request.connection) |c| c.closing = true;
                    return be;
                }
                // A socket failure sets the read error. The getReadError call can now unwrap it safely.
                const cause = if (self.request.connection) |c| c.getReadError() else null;
                if (cause) |ce| return ce;
                return error.ReadFailed;
            },
            else => |e| return e,
        };
    }

    fn deinit(ctx: *anyopaque) void {
        const self: *HttpBody = @ptrCast(@alignCast(ctx));
        self.request.deinit();
        self.gpa.destroy(self);
    }
};

/// Map a non-200 status to a stable class. A 429 never reaches here; `classify429` reads its body.
/// The 505...599 range covers Anthropic's 529 overloaded status, which must stay repeatable.
/// Read the retry headers into `info`. The caller must call this before `response.reader()`.
/// That call invalidates every head string slice.
fn readRetryHeaders(head: std.http.Client.Response.Head, info: *transport.AttemptInfo) void {
    var it = head.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "retry-after-ms")) {
            // The millisecond form wins. Both SDK families read it first.
            if (std.fmt.parseInt(u64, std.mem.trim(u8, h.value, " "), 10)) |ms| info.retry_after_ms = ms else |_| {}
        } else if (std.ascii.eqlIgnoreCase(h.name, "retry-after")) {
            if (info.retry_after_ms != null) continue;
            if (std.fmt.parseInt(u64, std.mem.trim(u8, h.value, " "), 10)) |secs| {
                info.retry_after_ms = secs *| 1000;
            } else |_| {} // An HTTP-date form needs a clock, so the caller uses its own delay.
        } else if (std.ascii.eqlIgnoreCase(h.name, "x-should-retry")) {
            const v = std.mem.trim(u8, h.value, " ");
            if (std.ascii.eqlIgnoreCase(v, "true")) info.should_retry = true;
            if (std.ascii.eqlIgnoreCase(v, "false")) info.should_retry = false;
        }
    }
}

fn mapStatus(status: std.http.Status) Error {
    return switch (@intFromEnum(status)) {
        401 => Error.AuthFailed,
        402 => Error.QuotaExhausted,
        403 => Error.PermissionDenied,
        408, 504 => Error.Timeout,
        500...503, 505...599 => Error.ServerError,
        else => Error.BadStatus,
    };
}

/// Classify a 429 as a rate limit or a quota error. Bound the body read with the idle timeout.
/// An unreadable body gives `RateLimitUnknown`. A spend cap and a rate limit share the status.
fn classify429(hb: *HttpBody, arena: Allocator) anyerror {
    hb.reader = hb.response.reader(&hb.transfer_buffer);
    var buf: [2048]u8 = undefined;
    const n = hb.readWithIdleTimeout(&buf) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return Error.RateLimitUnknown,
    };
    if (bodyIsQuota(arena, buf[0..n])) return Error.QuotaExhausted;
    // A rate limit must PROVE itself. A body the engine cannot decode may still name a spend cap.
    return if (bodyIsRateLimit(arena, buf[0..n])) Error.RateLimited else Error.RateLimitUnknown;
}

/// Report whether the error body names an exhausted quota. OpenAI marks it in `error.code` or
/// `error.type`. Anthropic marks a tier spend cap in `error.details.error_code`.
/// Report whether the error body names a temporary rate limit. Absence of proof is not proof.
fn bodyIsRateLimit(arena: Allocator, body: []const u8) bool {
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch return false;
    const err = json.fieldGet(value, "error") orelse return false;
    if (json.fieldStr(err, "code")) |code| if (std.mem.eql(u8, code, "rate_limit_exceeded")) return true;
    if (json.fieldStr(err, "type")) |t| if (std.mem.eql(u8, t, "rate_limit_error")) return true;
    return false;
}

fn bodyIsQuota(arena: Allocator, body: []const u8) bool {
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch return false;
    const err = json.fieldGet(value, "error") orelse return false;
    if (json.fieldStr(err, "code")) |code| if (isQuotaCode(code)) return true;
    if (json.fieldStr(err, "type")) |t| if (std.mem.eql(u8, t, "insufficient_quota")) return true;
    if (json.fieldGet(err, "details")) |details| if (json.fieldStr(details, "error_code")) |dc| {
        if (std.mem.eql(u8, dc, "enforced_spend_limit_reached")) return true;
    };
    return false;
}

/// Report whether a provider error code names an exhausted quota, credit, or spend limit.
fn isQuotaCode(code: []const u8) bool {
    if (std.mem.eql(u8, code, "insufficient_quota")) return true;
    if (std.mem.eql(u8, code, "credit_balance_exhausted")) return true;
    if (std.mem.eql(u8, code, "organization_usage_limit_exceeded")) return true;
    return std.mem.endsWith(u8, code, "_spend_limit_exceeded");
}

const testing = std.testing;

const canned_sse =
    "data: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const Server = struct {
    listener: *zio.net.Server = undefined, // `exchange` binds this.
    body: []const u8,
    status: std.http.Status,
    location: ?[]const u8 = null, // A redirect target. The client must never follow it.
    stall: bool = false, // Send the body, then wait on `release`. Keep the stream open.
    release: ?*zio.ResetEvent = null,
    err: ?anyerror = null,
};

/// Accept one connection and stream `body` with `status`. A test drives this on the run's executor.
fn serveOnce(server: *Server) void {
    serveOnceInner(server) catch |err| {
        server.err = err;
    };
}

fn serveOnceInner(s: *Server) !void {
    const stream = try s.listener.accept(.{});
    defer stream.close();
    var read_buf: [8192]u8 = undefined;
    var write_buf: [8192]u8 = undefined;
    var reader = stream.reader(&read_buf);
    var writer = stream.writer(&write_buf);
    var server = std.http.Server.init(&reader.interface, &writer.interface);
    var request = try server.receiveHead();

    var header_storage: [2]std.http.Header = .{
        .{ .name = "content-type", .value = "text/event-stream" },
        undefined,
    };
    var header_len: usize = 1;
    if (s.location) |loc| {
        header_storage[1] = .{ .name = "location", .value = loc };
        header_len = 2;
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
        if (s.release) |r| r.wait() catch {}; // The client releases the server after the read times out.
    }
    try resp.end();
}

const ClientOut = struct {
    gpa: Allocator = undefined, // `exchange` binds gpa, io, and port.
    io: std.Io = undefined,
    port: u16 = undefined,
    idle: ?std.Io.Duration = null,
    release: ?*zio.ResetEvent = null, // Signal the stalled server to end after the read returns.
    bytes: std.ArrayList(u8) = .empty,
    err: ?anyerror = null,
};

fn clientTask(out: *ClientOut) void {
    defer if (out.release) |r| r.set();
    runClient(out) catch |err| {
        out.err = err;
    };
}

fn runClient(out: *ClientOut) !void {
    var http = HttpTransport.init(out.gpa, out.io, out.idle);
    defer http.deinit();
    var arena = std.heap.ArenaAllocator.init(out.gpa);
    defer arena.deinit();
    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/messages", .{out.port});
    const headers = [_]transport.Header{.{ .name = "x-api-key", .value = "test-key" }};
    var request_body: [0]u8 = .{};
    var info: transport.AttemptInfo = .{};
    const body = try http.transportFor().open(arena.allocator(), .{ .url = url, .headers = &headers, .body = &request_body }, &info);
    defer body.deinit();
    var buf: [128]u8 = undefined;
    while (true) {
        const n = try body.read(&buf);
        if (n == 0) break;
        try out.bytes.appendSlice(out.gpa, buf[0..n]);
    }
}

/// Run one server and one client exchange on a private loopback port. The test reads `srv` and `out`.
fn exchange(srv: *Server, out: *ClientOut) !void {
    const rt = try zio.Runtime.init(testing.allocator, .{ .executors = .exact(1) });
    defer rt.deinit();
    const addr = try zio.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try addr.listen(.{});
    defer listener.close();
    srv.listener = &listener;
    out.gpa = testing.allocator;
    out.io = rt.io();
    out.port = listener.socket.address.ip.getPort();

    var server = try rt.spawn(serveOnce, .{srv});
    var client = try rt.spawn(clientTask, .{out});
    client.join();
    server.join();
}

test "streams an SSE response body over http" {
    var srv: Server = .{ .body = canned_sse, .status = .ok };
    var out: ClientOut = .{};
    defer out.bytes.deinit(testing.allocator);
    try exchange(&srv, &out);

    if (srv.err) |err| return err;
    if (out.err) |err| return err;
    try testing.expectEqualStrings(canned_sse, out.bytes.items);
}

test "a non-200 status maps to a transport error" {
    var srv: Server = .{ .body = "", .status = .unauthorized };
    var out: ClientOut = .{};
    defer out.bytes.deinit(testing.allocator);
    try exchange(&srv, &out);

    try testing.expectEqual(@as(?anyerror, Error.AuthFailed), out.err);
    try testing.expectEqual(@as(usize, 0), out.bytes.items.len);
}

test "a stalled stream returns an idle timeout" {
    var release: zio.ResetEvent = .init;
    // The server sends the head, then holds the stream open with no body until the client releases it.
    var srv: Server = .{ .body = "", .status = .ok, .stall = true, .release = &release };
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

test "a 429 with a quota code maps to QuotaExhausted" {
    var srv: Server = .{ .body = "{\"error\":{\"code\":\"insufficient_quota\"}}", .status = .too_many_requests };
    var out: ClientOut = .{};
    defer out.bytes.deinit(testing.allocator);
    try exchange(&srv, &out);

    try testing.expectEqual(@as(?anyerror, Error.QuotaExhausted), out.err);
}

test "an Anthropic spend-cap 429 maps to QuotaExhausted" {
    const spend_cap = "{\"type\":\"error\",\"error\":{\"type\":\"rate_limit_error\",\"details\":{\"error_code\":\"enforced_spend_limit_reached\"}}}";
    var srv: Server = .{ .body = spend_cap, .status = .too_many_requests };
    var out: ClientOut = .{};
    defer out.bytes.deinit(testing.allocator);
    try exchange(&srv, &out);

    try testing.expectEqual(@as(?anyerror, Error.QuotaExhausted), out.err);
}

test "a 429 with an empty body maps to RateLimitUnknown" {
    var srv: Server = .{ .body = "", .status = .too_many_requests };
    var out: ClientOut = .{};
    defer out.bytes.deinit(testing.allocator);
    try exchange(&srv, &out);

    // A guess of RateLimited would retry a spend cap that can never succeed.
    try testing.expectEqual(@as(?anyerror, Error.RateLimitUnknown), out.err);
}

test "a 429 without a quota code maps to RateLimited" {
    var srv: Server = .{ .body = "{\"error\":{\"code\":\"rate_limit_exceeded\"}}", .status = .too_many_requests };
    var out: ClientOut = .{};
    defer out.bytes.deinit(testing.allocator);
    try exchange(&srv, &out);

    try testing.expectEqual(@as(?anyerror, Error.RateLimited), out.err);
}
