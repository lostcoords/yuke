//! This provider transport streams an SSE response body through one std.http.Client request.
//! A run task can cancel a blocked read because the client dials through zio std.Io.

const std = @import("std");
const zio = @import("zio");
const transport = @import("../transport.zig");

const Allocator = std.mem.Allocator;

/// This error set defines stable classes for non-200 statuses and transport failures. The run task decides the outcome.
pub const Error = error{
    AuthFailed, // 401
    PermissionDenied, // 403
    RateLimited, // 429 without a quota signal
    QuotaExhausted, // 429 with a quota or spend code
    ServerError, // 5xx
    BadStatus, // Any other non-200 status.
    Timeout, // 408, 504, or an idle read past the deadline
    RedirectRefused, // The client must not follow a 3xx response.
    BadUrl,
};

/// The daemon owns one shared client for its lifetime. It injects `transport()` into State.
pub const HttpTransport = struct {
    client: std.http.Client,
    idle_timeout: zio.Timeout,

    /// The client dials and reads through `io`. Pass the zio reactor io so a cancel reaches the socket.
    pub fn init(gpa: Allocator, io: std.Io, idle_timeout: zio.Timeout) HttpTransport {
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

    fn open(ctx: *anyopaque, arena: Allocator, request: transport.Request) anyerror!transport.ResponseBody {
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
            .idle_timeout = self.idle_timeout,
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

        try hb.request.sendBodyComplete(request.body);
        hb.response = hb.request.receiveHead(&.{}) catch |err| switch (err) {
            error.TooManyHttpRedirects => return Error.RedirectRefused, // Never follow a redirect.
            else => return err,
        };
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
    idle_timeout: zio.Timeout,
    request: std.http.Client.Request,
    response: std.http.Client.Response,
    transfer_buffer: [4096]u8,
    reader: *std.Io.Reader,

    const vtable: transport.ResponseBody.VTable = .{ .read = read, .deinit = deinit };

    fn read(ctx: *anyopaque, buf: []u8) anyerror!usize {
        std.debug.assert(buf.len > 0);
        const self: *HttpBody = @ptrCast(@alignCast(ctx));

        // Bound each read. The timer cancels this task. The ac.check call distinguishes a timeout from user cancellation.
        var ac: zio.AutoCancel = .init;
        ac.set(self.idle_timeout);
        defer ac.clear();

        // The readSliceShort call returns 0 only at end of stream, which matches the ResponseBody contract.
        return self.reader.readSliceShort(buf) catch |err| switch (err) {
            error.ReadFailed => {
                // A malformed or truncated body sets bodyErr without a socket error. Return it as a peer error.
                if (self.response.bodyErr()) |be| {
                    if (self.request.connection) |c| c.closing = true;
                    return be;
                }
                // A socket failure sets the read error. The getReadError call can now unwrap it safely.
                const cause = if (self.request.connection) |c| c.getReadError() else null;
                if (cause) |ce| {
                    if (ce == error.Canceled) return if (ac.check(error.Canceled)) Error.Timeout else error.Canceled;
                    return ce;
                }
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

fn mapStatus(status: std.http.Status) Error {
    return switch (@intFromEnum(status)) {
        401 => Error.AuthFailed,
        403 => Error.PermissionDenied,
        408, 504 => Error.Timeout,
        500...503, 505...599 => Error.ServerError,
        else => Error.BadStatus,
    };
}

/// Classify a 429 as a rate limit or a quota error. Bound the body read with the idle timeout.
/// Propagate a user cancel. Use a rate limit when the body is missing or unreadable.
fn classify429(hb: *HttpBody, arena: Allocator) anyerror {
    hb.reader = hb.response.reader(&hb.transfer_buffer);
    var ac: zio.AutoCancel = .init;
    ac.set(hb.idle_timeout);
    defer ac.clear();
    var buf: [2048]u8 = undefined;
    const n = hb.reader.readSliceShort(&buf) catch |err| {
        // A user cancel propagates. Default to a rate limit for a malformed body, idle timeout, or other failure.
        // Check bodyErr first, so getReadError only runs for a real socket failure.
        if (err == error.ReadFailed and hb.response.bodyErr() == null) {
            if (hb.request.connection) |c| if (c.getReadError()) |ce| {
                if (ce == error.Canceled and !ac.check(error.Canceled)) return error.Canceled;
            };
        }
        return Error.RateLimited;
    };
    return if (bodyIsQuota(arena, buf[0..n])) Error.QuotaExhausted else Error.RateLimited;
}

/// Report whether the error body names an exhausted quota. OpenAI marks it in `error.code` or
/// `error.type`. Anthropic marks a tier spend cap in `error.details.error_code`.
fn bodyIsQuota(arena: Allocator, body: []const u8) bool {
    const parsed = std.json.parseFromSlice(std.json.Value, arena, body, .{}) catch return false;
    defer parsed.deinit();
    const err = objField(parsed.value, "error") orelse return false;
    if (strField(err, "code")) |code| if (isQuotaCode(code)) return true;
    if (strField(err, "type")) |t| if (std.mem.eql(u8, t, "insufficient_quota")) return true;
    if (objField(err, "details")) |details| if (strField(details, "error_code")) |dc| {
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

fn objField(value: std.json.Value, name: []const u8) ?std.json.Value {
    const obj = switch (value) {
        .object => |o| o,
        else => return null,
    };
    return obj.get(name);
}

fn strField(value: std.json.Value, name: []const u8) ?[]const u8 {
    return switch (objField(value, name) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

const testing = std.testing;

const canned_sse =
    "data: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const Server = struct {
    listener: *zio.net.Server,
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
    gpa: Allocator,
    io: std.Io,
    port: u16,
    idle: zio.Timeout = .none,
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
    const body = try http.transportFor().open(arena.allocator(), .{ .url = url, .headers = &headers, .body = &request_body });
    defer body.deinit();
    var buf: [128]u8 = undefined;
    while (true) {
        const n = try body.read(&buf);
        if (n == 0) break;
        try out.bytes.appendSlice(out.gpa, buf[0..n]);
    }
}

test "streams an SSE response body over http" {
    const rt = try zio.Runtime.init(testing.allocator, .{ .executors = .exact(1) });
    defer rt.deinit();
    const addr = try zio.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try addr.listen(.{});
    defer listener.close();
    const port = listener.socket.address.ip.getPort();

    var out: ClientOut = .{ .gpa = testing.allocator, .io = rt.io(), .port = port };
    defer out.bytes.deinit(testing.allocator);
    var srv: Server = .{ .listener = &listener, .body = canned_sse, .status = .ok };

    var server = try rt.spawn(serveOnce, .{&srv});
    var client = try rt.spawn(clientTask, .{&out});
    client.join();
    server.join();

    if (srv.err) |err| return err;
    if (out.err) |err| return err;
    try testing.expectEqualStrings(canned_sse, out.bytes.items);
}

test "a non-200 status maps to a transport error" {
    const rt = try zio.Runtime.init(testing.allocator, .{ .executors = .exact(1) });
    defer rt.deinit();
    const addr = try zio.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try addr.listen(.{});
    defer listener.close();
    const port = listener.socket.address.ip.getPort();

    var out: ClientOut = .{ .gpa = testing.allocator, .io = rt.io(), .port = port };
    defer out.bytes.deinit(testing.allocator);
    var srv: Server = .{ .listener = &listener, .body = "", .status = .unauthorized };

    var server = try rt.spawn(serveOnce, .{&srv});
    var client = try rt.spawn(clientTask, .{&out});
    client.join();
    server.join();

    try testing.expectEqual(@as(?anyerror, Error.AuthFailed), out.err);
    try testing.expectEqual(@as(usize, 0), out.bytes.items.len);
}

test "a stalled stream returns a timeout" {
    const rt = try zio.Runtime.init(testing.allocator, .{ .executors = .exact(1) });
    defer rt.deinit();
    const addr = try zio.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try addr.listen(.{});
    defer listener.close();
    const port = listener.socket.address.ip.getPort();

    var release: zio.ResetEvent = .init;
    var out: ClientOut = .{
        .gpa = testing.allocator,
        .io = rt.io(),
        .port = port,
        .idle = zio.Timeout.fromMilliseconds(50),
        .release = &release,
    };
    defer out.bytes.deinit(testing.allocator);
    // The server sends the head, then holds the stream open with no body until the client releases it.
    var srv: Server = .{ .listener = &listener, .body = "", .status = .ok, .stall = true, .release = &release };

    var server = try rt.spawn(serveOnce, .{&srv});
    var client = try rt.spawn(clientTask, .{&out});
    client.join();
    server.join();

    try testing.expectEqual(@as(?anyerror, Error.Timeout), out.err);
}

test "a redirect is rejected without following it" {
    const rt = try zio.Runtime.init(testing.allocator, .{ .executors = .exact(1) });
    defer rt.deinit();
    const addr = try zio.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try addr.listen(.{});
    defer listener.close();
    const port = listener.socket.address.ip.getPort();

    var out: ClientOut = .{ .gpa = testing.allocator, .io = rt.io(), .port = port };
    defer out.bytes.deinit(testing.allocator);
    // The client must reject a 302 response to another origin to keep the key private.
    var srv: Server = .{ .listener = &listener, .body = "", .status = .found, .location = "http://evil.example/steal" };

    var server = try rt.spawn(serveOnce, .{&srv});
    var client = try rt.spawn(clientTask, .{&out});
    client.join();
    server.join();

    // The receiveHead call rejects the 3xx, so the key stays on the original connection.
    try testing.expectEqual(@as(?anyerror, Error.RedirectRefused), out.err);
    try testing.expectEqual(@as(usize, 0), out.bytes.items.len);
}

test "a 429 with a quota code maps to QuotaExhausted" {
    const rt = try zio.Runtime.init(testing.allocator, .{ .executors = .exact(1) });
    defer rt.deinit();
    const addr = try zio.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try addr.listen(.{});
    defer listener.close();
    const port = listener.socket.address.ip.getPort();

    var out: ClientOut = .{ .gpa = testing.allocator, .io = rt.io(), .port = port };
    defer out.bytes.deinit(testing.allocator);
    var srv: Server = .{ .listener = &listener, .body = "{\"error\":{\"code\":\"insufficient_quota\"}}", .status = .too_many_requests };

    var server = try rt.spawn(serveOnce, .{&srv});
    var client = try rt.spawn(clientTask, .{&out});
    client.join();
    server.join();

    try testing.expectEqual(@as(?anyerror, Error.QuotaExhausted), out.err);
}

test "an Anthropic spend-cap 429 maps to QuotaExhausted" {
    const rt = try zio.Runtime.init(testing.allocator, .{ .executors = .exact(1) });
    defer rt.deinit();
    const addr = try zio.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try addr.listen(.{});
    defer listener.close();
    const port = listener.socket.address.ip.getPort();

    var out: ClientOut = .{ .gpa = testing.allocator, .io = rt.io(), .port = port };
    defer out.bytes.deinit(testing.allocator);
    const spend_cap = "{\"type\":\"error\",\"error\":{\"type\":\"rate_limit_error\",\"details\":{\"error_code\":\"enforced_spend_limit_reached\"}}}";
    var srv: Server = .{ .listener = &listener, .body = spend_cap, .status = .too_many_requests };

    var server = try rt.spawn(serveOnce, .{&srv});
    var client = try rt.spawn(clientTask, .{&out});
    client.join();
    server.join();

    try testing.expectEqual(@as(?anyerror, Error.QuotaExhausted), out.err);
}

test "a 429 without a quota code maps to RateLimited" {
    const rt = try zio.Runtime.init(testing.allocator, .{ .executors = .exact(1) });
    defer rt.deinit();
    const addr = try zio.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try addr.listen(.{});
    defer listener.close();
    const port = listener.socket.address.ip.getPort();

    var out: ClientOut = .{ .gpa = testing.allocator, .io = rt.io(), .port = port };
    defer out.bytes.deinit(testing.allocator);
    var srv: Server = .{ .listener = &listener, .body = "{\"error\":{\"code\":\"rate_limit_exceeded\"}}", .status = .too_many_requests };

    var server = try rt.spawn(serveOnce, .{&srv});
    var client = try rt.spawn(clientTask, .{&out});
    client.join();
    server.join();

    try testing.expectEqual(@as(?anyerror, Error.RateLimited), out.err);
}
