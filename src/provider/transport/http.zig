//! This provider transport streams an SSE response body through one std.http.Client request.
//! The client dials through the zio std.Io, so a run-task cancel interrupts a blocked read.

const std = @import("std");
const zio = @import("zio");
const transport = @import("../transport.zig");

const Allocator = std.mem.Allocator;

/// This error set defines stable classes for non-200 statuses and transport failures. The run task decides the outcome.
pub const Error = error{
    AuthFailed, // 401 or 403
    RateLimited, // 429
    ServerError, // 5xx
    BadStatus, // any other non-200
    Timeout, // an idle read passed the deadline
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

        // sendBodyComplete uses the body as a writer buffer, so give it a mutable copy.
        const body = try arena.dupe(u8, request.body);
        // The provider streams SSE, so ask for it. This Accept wins over a caller Accept.
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

        try hb.request.sendBodyComplete(body);
        hb.response = try hb.request.receiveHead(&.{});
        if (hb.response.head.status != .ok) return mapStatus(hb.response.head.status);

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

        // Bound each read. The timer cancels this task. ac.check distinguishes a timeout from user cancellation.
        var ac: zio.AutoCancel = .init;
        ac.set(self.idle_timeout);
        defer ac.clear();

        // readSliceShort returns 0 only at end of stream, which matches the ResponseBody contract.
        return self.reader.readSliceShort(buf) catch |err| switch (err) {
            error.ReadFailed => {
                // A malformed or truncated body sets bodyErr and no socket error. Return it as a peer error.
                if (self.response.bodyErr()) |be| {
                    if (self.request.connection) |c| c.closing = true;
                    return be;
                }
                // A socket failure sets the read error. getReadError is now safe to unwrap.
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
        401, 403 => Error.AuthFailed,
        429 => Error.RateLimited,
        500...599 => Error.ServerError,
        else => Error.BadStatus,
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
    location: ?[]const u8 = null, // This field holds a redirect target. The client must never follow it.
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
    const body = try http.transportFor().open(arena.allocator(), .{ .url = url, .headers = &headers, .body = "" });
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
    // The client must reject a 302 response to another origin. Otherwise, the key would leak to the target.
    var srv: Server = .{ .listener = &listener, .body = "", .status = .found, .location = "http://evil.example/steal" };

    var server = try rt.spawn(serveOnce, .{&srv});
    var client = try rt.spawn(clientTask, .{&out});
    client.join();
    server.join();

    // receiveHead rejects the 3xx rather than following it, so the key never reaches the target.
    try testing.expectEqual(@as(?anyerror, error.TooManyHttpRedirects), out.err);
    try testing.expectEqual(@as(usize, 0), out.bytes.items.len);
}
