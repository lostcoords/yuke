//! HTTP requests run on worker tasks; only the owner reads or creates JavaScript values. The head answers first, and the body waits for reads.

const std = @import("std");
const ai = @import("ai");
const quickjs = @import("quickjs");
const Host = @import("../host.zig").Host;
const module = @import("module.zig");
const pending = @import("../pending.zig");
const cancellation = @import("cancellation.zig");
const utf8 = @import("../../utf8.zig");
const Context = quickjs.Context;
const Value = quickjs.Value;

const default_timeout_ms: u32 = 30_000;
/// A slow tool call answers its head late, and a quiet event stream reads late, so both wait up to ten minutes.
const max_timeout_ms: u32 = 600_000;
/// `text()` refuses a body above this; a chunk read has no total cap.
pub const max_response_bytes: usize = 256 * 1024;
const default_read_bytes: u32 = 64 * 1024;
const max_read_bytes: u32 = 1024 * 1024;
/// Every parked body holds one connection, so the count is bounded like the sockets.
const max_bodies = 64;
const max_response_headers = 64;
const max_response_header_bytes = 8 * 1024;

/// The host's single-executor workers share the pool, root bundle, and certificate clock.
pub const Client = struct {
    inner: ?std.http.Client = null,

    /// Move the clock `std` pins at its first handshake, so a certificate that rotates mid-process still verifies.
    pub fn acquire(self: *Client, gpa: std.mem.Allocator, io: std.Io) *std.http.Client {
        if (self.inner == null) self.inner = .{ .allocator = gpa, .io = io, .read_buffer_size = 16 * 1024, .connection_pool = .{ .free_size = 8 } };
        const client = &self.inner.?;
        // A concurrent first load can write a clock one rescan older, far under the one-second certificate grain.
        if (client.now != null) client.now = std.Io.Clock.real.now(io);
        return client;
    }

    /// All workers must join before the pool and root bundle leave the host.
    pub fn deinit(self: *Client) void {
        if (self.inner) |*client| client.deinit();
        self.inner = null;
    }
};

pub fn install(host: *Host) void {
    module.installFunctions(host, "yuke:http-native", &.{
        .{ .name = "fetch", .arity = 2, .call = jsFetch },
        .{ .name = "read", .arity = 2, .call = jsRead },
        .{ .name = "readAll", .arity = 2, .call = jsReadAll },
        .{ .name = "close", .arity = 1, .call = jsClose },
    });
}

// The supervisor owns this arena until its worker joins.
const Request = struct {
    arena: std.heap.ArenaAllocator,
    url: []u8,
    method: std.http.Method,
    headers: std.http.Client.Request.Headers = .{ .accept_encoding = .omit },
    extra_headers: []const std.http.Header,
    body: ?[]u8,

    const ParseError = error{ UrlType, Url, Options, Option, Method, Body, BodyMethod, Headers, Header };

    fn parse(ctx: Context, gpa: std.mem.Allocator, url_value: Value, options: Value) ParseError!Request {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        const url = module.owned(ctx, a, url_value) orelse return error.UrlType;
        if (url.len == 0) return error.Url;
        for (url) |byte| if (byte <= ' ' or byte == 0x7f) return error.Url;
        const uri = std.Uri.parse(url) catch return error.Url;
        if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") and !std.ascii.eqlIgnoreCase(uri.scheme, "https")) return error.Url;
        _ = std.ascii.lowerString(url[0..uri.scheme.len], uri.scheme);
        if (uri.user != null or uri.password != null) return error.Url;
        var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
        _ = uri.getHost(&host_buf) catch return error.Url;

        if (!ctx.isUndefined(options)) {
            if (!plainObject(ctx, options)) return error.Options;
            const keys = ctx.getOwnPropertyNames(options, .{}) catch return error.Options;
            defer ctx.freePropertyEnum(keys);
            for (keys) |key| {
                const name = ctx.atomToCStringLen(key.atom) catch return error.Options;
                defer ctx.freeCString(name.ptr);
                var known = false;
                inline for (.{ "method", "headers", "body", "timeoutMs", "signal" }) |field| {
                    if (std.mem.eql(u8, name, field)) known = true;
                }
                if (!known) return error.Option;
            }
        }

        const method_text = module.optionalString(ctx, a, options, "method") catch return error.Method;
        var method: std.http.Method = .GET;
        if (method_text) |name| {
            method = std.meta.stringToEnum(std.http.Method, name) orelse return error.Method;
            switch (method) {
                .GET, .POST, .PUT, .PATCH, .HEAD, .DELETE => {},
                else => return error.Method,
            }
        }
        const body = module.optionalString(ctx, a, options, "body") catch return error.Body;
        if (body != null and !method.requestHasBody()) return error.BodyMethod;
        var headers: std.http.Client.Request.Headers = .{ .accept_encoding = .omit };
        var extra: std.ArrayList(std.http.Header) = .empty;
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        const input = if (ctx.isUndefined(options)) quickjs.UNDEFINED else ctx.getPropertyStr(options, "headers");
        defer ctx.freeValue(input);
        if (!ctx.isUndefined(input)) {
            if (!plainObject(ctx, input)) return error.Headers;
            const keys = ctx.getOwnPropertyNames(input, .{ .enum_only = true }) catch return error.Headers;
            defer ctx.freePropertyEnum(keys);
            for (keys) |key| {
                const raw_name = ctx.atomToCStringLen(key.atom) catch return error.Header;
                defer ctx.freeCString(raw_name.ptr);
                if (!ai.route.validHeaderName(raw_name)) return error.Header;
                const name = a.alloc(u8, raw_name.len) catch unreachable;
                _ = std.ascii.lowerString(name, raw_name);
                const entry = seen.getOrPut(a, name) catch unreachable;
                if (entry.found_existing) return error.Header;
                inline for (.{ "host", "connection", "content-length", "transfer-encoding" }) |managed| {
                    if (std.mem.eql(u8, name, managed)) return error.Header;
                }
                const raw_value = ctx.getProperty(input, key.atom);
                defer ctx.freeValue(raw_value);
                const value = module.owned(ctx, a, raw_value) orelse return error.Header;
                if (!ai.route.validHeaderValue(value)) return error.Header;
                if (std.mem.eql(u8, name, "accept-encoding")) continue;
                if (std.mem.eql(u8, name, "content-type")) {
                    headers.content_type = .{ .override = value };
                } else if (std.mem.eql(u8, name, "authorization")) {
                    headers.authorization = .{ .override = value };
                } else if (std.mem.eql(u8, name, "user-agent")) {
                    headers.user_agent = .{ .override = value };
                } else {
                    extra.append(a, .{ .name = name, .value = value }) catch unreachable;
                }
            }
        }
        return .{ .arena = arena, .url = url, .method = method, .headers = headers, .extra_headers = extra.items, .body = body };
    }

    pub fn free(self: Request, _: std.mem.Allocator) void {
        var arena = self.arena;
        arena.deinit();
    }
};

fn plainObject(ctx: Context, value: Value) bool {
    if (!ctx.isObject(value)) return false;
    const object = ctx.newObject();
    defer ctx.freeValue(object);
    if (ctx.isException(object) or ctx.getClassID(value) != ctx.getClassID(object)) return false;
    const proto = ctx.getPrototype(value);
    defer ctx.freeValue(proto);
    if (ctx.isException(proto)) return false;
    if (ctx.isNull(proto)) return true;
    const expected = ctx.getPrototype(object);
    defer ctx.freeValue(expected);
    return !ctx.isException(expected) and ctx.isStrictEqual(proto, expected);
}

const head_limits: module.IoLimits = .{ .default_timeout_ms = default_timeout_ms, .max_timeout_ms = max_timeout_ms };
const read_limits: module.IoLimits = .{ .default_timeout_ms = default_timeout_ms, .max_timeout_ms = max_timeout_ms, .min_bytes = 4, .default_bytes = default_read_bytes, .max_bytes = max_read_bytes };
const canceled: pending.Result = .{ .failed = .{ .message = "the request was canceled" } };
const timed_out: pending.Result = .{ .failed = .{ .message = "the request timed out" } };
const io_failed: pending.Result = .{ .failed = .{ .message = "the host could not complete the request" } };
const too_long: pending.Result = .{ .failed = .{ .message = "the response exceeds the size limit" } };
const failures: pending.Failures = .{ .canceled = canceled, .timed_out = timed_out, .failed = .{ .failed = .{ .message = "the host cannot start another operation" } } };

/// One response, tabled from the request on. The std response points at the request, so both live here, pinned.
const Body = struct {
    host: *Host,
    id: u32 = 0,
    /// The parsed request owns the header bytes std borrows for the whole exchange.
    parsed: Request,
    /// The head deadline. A body read brings its own.
    deadline: std.Io.Clock.Timestamp,
    /// Null once the connection went back to the client.
    request: ?std.http.Client.Request = null,
    response: std.http.Client.Response = undefined,
    reader: ?*std.Io.Reader = null,
    /// The bytes of one character a chunk cut, kept for the next read.
    carry: [3]u8 = undefined,
    carry_len: u8 = 0,
    /// True after a read saw the end of the stream, so the read task ends the body.
    eof: bool = false,
    /// True once no read may start.
    ended: bool = false,
    /// The head or read task retains the record from submission until return.
    busy: bool = true,
    op: ?*pending.Op = null,

    /// Give the connection back. A failed exchange or a body short of its end must not return to the pool.
    fn release(self: *Body, failed: bool) void {
        // The close is an I/O call that can suspend, so the request leaves the body before it, and a second caller finds none.
        var request = self.request orelse return;
        self.request = null;
        if (failed or request.reader.state != .ready) if (request.connection) |connection| {
            connection.closing = true;
        };
        request.deinit();
    }

    fn end(self: *Body) void {
        self.ended = true;
        self.release(false);
    }

    /// An active task releases its own request after its worker returns.
    pub fn close(self: *Body) void {
        if (self.ended) return;
        if (self.busy) {
            if (self.op) |op| op.cancel.request(self.host.io) else self.ended = true;
        } else {
            std.debug.assert(self.op == null);
            self.end();
        }
    }

    fn finish(self: *Body) void {
        std.debug.assert(self.busy);
        self.op = null;
        self.busy = false;
        self.host.wake.set(self.host.io);
    }

    pub fn done(self: *const Body) bool {
        return self.ended and !self.busy;
    }

    /// The head task payload path: a task that never starts ends the body, and the table reaps it.
    pub fn free(self: *Body, _: std.mem.Allocator) void {
        std.debug.assert(self.busy and self.op == null);
        self.end();
        self.finish();
    }

    pub fn deinit(self: *Body, gpa: std.mem.Allocator) void {
        std.debug.assert(self.done() and self.op == null);
        std.debug.assert(self.request == null);
        self.parsed.free(gpa);
    }
};

pub const Bodies = module.Table(Body);

fn jsFetch(ctx: Context, _: Value, args: []const Value) Value {
    const host = Host.fromContext(ctx);
    if (!host.acceptsIo()) return pending.rejected(ctx, "the host is closed");
    if (args.len == 0) return pending.rejected(ctx, "fetch needs a url");
    const options = if (args.len > 1) args[1] else quickjs.UNDEFINED;
    const request = Request.parse(ctx, host.gpa, args[0], options) catch |err| return pending.rejected(ctx, switch (err) {
        error.UrlType => "the url must be a string",
        error.Url => "the url is invalid",
        error.Options => "the fetch options must be an object",
        error.Option => "a fetch option is not supported",
        error.Method => "the method must be GET, POST, PUT, PATCH, HEAD, or DELETE",
        error.Body => "the body must be a string",
        error.BodyMethod => "this method must not have a body",
        error.Headers => "headers must be an object",
        error.Header => "a request header is invalid",
    });
    const io_options = module.ioOptions(host, options, head_limits) catch {
        request.free(host.gpa);
        return pending.rejected(ctx, "a fetch option is invalid");
    };
    defer ctx.freeValue(io_options.signal);
    if (host.bodies.full(host.gpa, max_bodies)) {
        request.free(host.gpa);
        return pending.rejected(ctx, "the host holds 64 open response bodies");
    }
    const body = host.bodies.add(host.gpa, .{ .host = host, .parsed = request, .deadline = io_options.deadline });
    return host.startTask(*Body, httpTask, body, .{ .signal = io_options.signal });
}

/// Run the head exchange under the deadline. End the body for every answer but a head, because no reader can use it.
fn httpTask(host: *Host, op: *pending.Op, body: *Body) void {
    defer body.finish();
    std.debug.assert(body.busy and body.op == null);
    std.debug.assert(body.request == null);
    body.op = op;
    const result = if (body.ended) canceled else pending.runTimed(host, op, .{ .deadline = body.deadline }, httpWorker, body, failures);
    if (result != .http) body.end();
    op.finish(result);
}

fn httpWorker(host: *Host, body: *Body, result: *pending.Result) error{}!void {
    const head = exchange(host, body) catch |err| {
        body.release(true);
        result.* = switch (err) {
            error.Canceled => canceled,
            error.StreamTooLong, error.HttpHeadersOversize => too_long,
            else => io_failed,
        };
        return;
    };
    result.* = .{ .http = head };
}

fn exchange(host: *Host, body: *Body) !pending.Http {
    std.debug.assert(body.request == null);
    const uri = std.Uri.parse(body.parsed.url) catch unreachable;
    const client = host.http.acquire(host.gpa, host.io);
    var reused = false;
    return exchangeOnce(client, body, uri, &reused) catch |err| {
        body.release(true);
        // A stale idle connection may retry a safe method, but never replay a body or a partial response.
        if (!reused or (body.parsed.method != .GET and body.parsed.method != .HEAD)) return err;
        return switch (err) {
            error.WriteFailed, error.ReadFailed, error.EndOfStream, error.HttpConnectionClosing => exchangeOnce(client, body, uri, &reused),
            else => err,
        };
    };
}

/// Send the request and read the head. The body stays tabled when the response has one, and ends now when it has none.
fn exchangeOnce(client: *std.http.Client, body: *Body, uri: std.Uri, reused: *bool) !pending.Http {
    const gpa = client.allocator;
    const io = client.io;
    const req = &body.parsed;
    try io.checkCancel();
    var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    const protocol = std.http.Client.Protocol.fromUri(uri).?;
    const connection = client.connection_pool.findConnection(io, .{
        .host = try uri.getHost(&host_buf),
        .port = uri.port orelse @as(u16, if (protocol == .tls) 443 else 80),
        .protocol = protocol,
    });
    reused.* = connection != null;
    // An unhandled redirect returns its head without a body drain or a second request.
    body.request = client.request(req.method, uri, .{ .connection = connection, .redirect_behavior = .unhandled, .handle_continue = false, .headers = req.headers, .extra_headers = req.extra_headers }) catch |err| {
        if (connection) |held| {
            held.closing = true;
            client.connection_pool.release(held, io);
        }
        return err;
    };
    const request = &body.request.?;
    request.accept_encoding = @splat(true);
    if (req.method.requestHasBody()) try request.sendBodyComplete(req.body orelse &.{}) else try request.sendBodiless();
    body.response = response: while (true) {
        // Validate digits before the standard parser converts the untrusted status to u10.
        const prefix = try request.connection.?.reader().peekArray(12);
        if (prefix[9] < '1' or prefix[9] > '5' or !std.ascii.isDigit(prefix[10]) or !std.ascii.isDigit(prefix[11])) return error.BadStatus;
        const head = try request.receiveHead(&.{});
        if (@intFromEnum(head.head.status) >= 200) break :response head;
        if (head.head.status == .switching_protocols) return error.BadStatus;
        try io.checkCancel();
    };
    reused.* = false;
    const head = &body.response.head;
    const status: u16 = @intFromEnum(head.status);
    // A redirect answers its head alone, so the caller decides whether a new origin sees the request.
    const redirect = status >= 300 and status < 400;
    const has_body = req.method != .HEAD and status != 204 and status != 205 and !(head.transfer_encoding == .none and head.content_length == 0);
    if (has_body and !redirect and head.content_encoding != .identity) return error.UnsupportedEncoding;

    // The body reader invalidates the head slices, so copy the bounded headers first.
    var headers: std.ArrayList(pending.Http.Header) = .empty;
    errdefer {
        for (headers.items) |header| header.free(gpa);
        headers.deinit(gpa);
    }
    var total: usize = 0;
    var it = head.iterateHeaders();
    next_header: while (it.next()) |header| {
        if (!ai.route.validHeaderName(header.name) or !ai.route.validHeaderValue(header.value)) return error.BadHeader;
        // The repair of an invalid byte can grow the value, so the budget counts the repaired bytes.
        const value = try utf8.sanitize(gpa, header.value);
        var kept = false;
        defer if (!kept) gpa.free(value);
        // Fetch `get` joins a repeated field with a comma, so a second challenge stays visible.
        for (headers.items) |*held| if (std.ascii.eqlIgnoreCase(held.name, header.name)) {
            if (value.len + 2 > max_response_header_bytes - total) return error.StreamTooLong;
            const joined = try std.mem.concat(gpa, u8, &.{ held.value, ", ", value });
            gpa.free(held.value);
            held.value = joined;
            total += value.len + 2;
            continue :next_header;
        };
        const size = header.name.len + value.len;
        if (headers.items.len == max_response_headers or size > max_response_header_bytes - total) return error.StreamTooLong;
        const name = try gpa.dupeZ(u8, header.name);
        errdefer gpa.free(name);
        _ = std.ascii.lowerString(name, name);
        try headers.append(gpa, .{ .name = name, .value = value });
        kept = true;
        total += size;
    }
    if (!has_body) {
        // Nothing follows the head, so the connection is ready for the pool now.
        request.reader.state = .ready;
        body.end();
    } else if (redirect) {
        // The unread body marks the connection for close.
        body.end();
    }
    return .{ .status = status, .headers = try headers.toOwnedSlice(gpa), .body = if (body.ended) 0 else body.id };
}

/// One body read. `all` takes the rest under the text cap; a chunk read takes at most `max_bytes`.
const Read = struct {
    body: *Body,
    all: bool,
    max_bytes: u32,
    deadline: std.Io.Clock.Timestamp,

    pub fn free(self: Read, _: std.mem.Allocator) void {
        self.body.finish();
    }
};

fn jsRead(ctx: Context, _: Value, args: []const Value) Value {
    return startRead(ctx, args, false);
}

fn jsReadAll(ctx: Context, _: Value, args: []const Value) Value {
    return startRead(ctx, args, true);
}

fn startRead(ctx: Context, args: []const Value, all: bool) Value {
    const host = Host.fromContext(ctx);
    if (!host.acceptsIo()) return pending.rejected(ctx, "the host is closed");
    const options = module.ioOptions(host, if (args.len > 1) args[1] else quickjs.UNDEFINED, read_limits) catch return pending.rejected(ctx, "a read option is invalid");
    defer ctx.freeValue(options.signal);
    const body = bodyArg(host, args) orelse return pending.rejected(ctx, "the response body is closed");
    if (cancellation.aborted(ctx, options.signal)) {
        body.close();
        return pending.rejected(ctx, "the operation was canceled");
    }
    if (body.busy) return pending.rejected(ctx, "a body read is already pending");
    body.busy = true;
    return host.startTask(Read, readTask, .{ .body = body, .all = all, .max_bytes = options.max_bytes, .deadline = options.deadline }, .{ .signal = options.signal });
}

fn bodyArg(host: *Host, args: []const Value) ?*Body {
    const body = host.bodies.findArg(host.ctx, args) orelse return null;
    return if (body.ended) null else body;
}

fn jsClose(ctx: Context, _: Value, args: []const Value) Value {
    if (Host.fromContext(ctx).bodies.findArg(ctx, args)) |body| body.close();
    return quickjs.UNDEFINED;
}

/// Run one read under its deadline. A failure or the end of the stream releases the connection.
fn readTask(host: *Host, op: *pending.Op, read: Read) void {
    defer read.free(host.gpa);
    const body = read.body;
    std.debug.assert(body.busy and body.op == null);
    body.op = op;
    const result = if (body.ended) canceled else pending.runTimed(host, op, .{ .deadline = read.deadline }, readWorker, read, failures);
    if (result == .failed or body.eof) body.end();
    op.finish(result);
}

fn readWorker(host: *Host, read: Read, result: *pending.Result) error{}!void {
    host.io.checkCancel() catch return;
    const body = read.body;
    std.debug.assert(body.op != null and body.request != null);
    const gpa = host.gpa;
    // The body reader needs no buffer of its own; a read streams into the caller's bytes.
    const reader = body.reader orelse blk: {
        body.reader = body.response.reader(&.{});
        break :blk body.reader.?;
    };
    if (read.all) {
        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(gpa);
        // A declared length sizes the list once, so a complete body needs no second allocation.
        const head = &body.response.head;
        const expected: usize = if (head.transfer_encoding == .none) @intCast(@min(head.content_length orelse 0, max_response_bytes + 1)) else 0;
        list.ensureTotalCapacityPrecise(gpa, @max(expected, body.carry_len)) catch unreachable;
        list.appendSliceAssumeCapacity(body.carry[0..body.carry_len]);
        body.carry_len = 0;
        // The limit is exclusive, so one extra byte distinguishes the cap from overflow.
        reader.appendRemaining(gpa, &list, .limited(max_response_bytes + 1 - list.items.len)) catch |err| {
            result.* = switch (err) {
                error.StreamTooLong => too_long,
                error.OutOfMemory => unreachable,
                else => io_failed,
            };
            return;
        };
        body.eof = true;
        if (!complete(body)) {
            result.* = io_failed;
            return;
        }
        // Valid text moves out of the list; only a repair copies.
        result.* = .{ .text = if (std.unicode.utf8ValidateSlice(list.items)) list.toOwnedSlice(gpa) catch unreachable else utf8.sanitize(gpa, list.items) catch unreachable };
        return;
    }
    const buffer = gpa.alloc(u8, read.max_bytes) catch unreachable;
    var filled: usize = body.carry_len;
    @memcpy(buffer[0..filled], body.carry[0..filled]);
    while (true) {
        var slices = [_][]u8{buffer[filled..]};
        // Zero bytes is not the end; the reader may have filled its own buffer, and the next call copies it.
        const n = reader.readVec(&slices) catch |err| {
            gpa.free(buffer);
            if (err != error.EndOfStream) {
                result.* = io_failed;
                return;
            }
            // A stream that ends inside a character answers the repaired bytes now and its end on the next read.
            if (filled > 0) {
                result.* = .{ .text = utf8.sanitize(gpa, body.carry[0..body.carry_len]) catch unreachable };
                body.carry_len = 0;
                return;
            }
            body.eof = true;
            result.* = if (complete(body)) .null_value else io_failed;
            return;
        };
        std.debug.assert(n <= buffer.len - filled);
        if (n == 0) continue;
        filled += n;
        const cut = utf8.whole(buffer[0..filled]);
        if (cut > 0) {
            body.carry_len = @intCast(filled - cut);
            @memcpy(body.carry[0..body.carry_len], buffer[cut..filled]);
            defer gpa.free(buffer);
            result.* = .{ .text = utf8.sanitize(gpa, buffer[0..cut]) catch unreachable };
            return;
        }
        // Fewer than four bytes of one character wait for the rest, so the next read always fits.
        std.debug.assert(filled <= body.carry.len);
    }
}

/// A stream that ended with declared bytes or chunks still due was cut short.
fn complete(body: *const Body) bool {
    return switch (body.request.?.reader.state) {
        .received_head, .body_remaining_content_length, .body_remaining_chunk_len => false,
        .ready, .body_none, .closing => true,
    };
}
