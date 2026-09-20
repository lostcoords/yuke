//! Bounded HTTP requests use worker tasks; only the owner reads or creates JavaScript values.

const std = @import("std");
const quickjs = @import("quickjs");
const Host = @import("../host.zig").Host;
const module = @import("module.zig");
const pending = @import("../pending.zig");
const utf8 = @import("../../utf8.zig");
const Context = quickjs.Context;
const Value = quickjs.Value;

pub const default_timeout_ms: u32 = 30_000;
pub const max_timeout_ms: u32 = 120_000;
pub const max_response_bytes: usize = 256 * 1024;
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
    module.installFunctions(host, "yuke:http-native", &.{.{ .name = "fetch", .arity = 2, .call = jsFetch }});
}

// The supervisor owns this arena until its worker joins.
const Request = struct {
    arena: std.heap.ArenaAllocator,
    url: []u8,
    method: std.http.Method,
    headers: std.http.Client.Request.Headers = .{ .accept_encoding = .omit },
    extra_headers: []const std.http.Header,
    body: ?[]u8,
    timeout_ms: u32,

    const ParseError = error{ UrlType, Url, Options, Option, Method, Body, BodyMethod, Headers, Header, Timeout };

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

        const method_text = optionalString(ctx, a, options, "method") catch return error.Method;
        var method: std.http.Method = .GET;
        if (method_text) |name| {
            method = std.meta.stringToEnum(std.http.Method, name) orelse return error.Method;
            switch (method) {
                .GET, .POST, .PUT, .PATCH, .HEAD, .DELETE => {},
                else => return error.Method,
            }
        }
        const body = optionalString(ctx, a, options, "body") catch return error.Body;
        if (body != null and !method.requestHasBody()) return error.BodyMethod;
        const timeout = if (ctx.isUndefined(options)) quickjs.UNDEFINED else ctx.getPropertyStr(options, "timeoutMs");
        defer ctx.freeValue(timeout);
        const timeout_ms: u32 = if (ctx.isUndefined(timeout)) default_timeout_ms else @intCast(module.integer(ctx, timeout, 1, max_timeout_ms) orelse return error.Timeout);
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
                if (!validHeaderName(raw_name)) return error.Header;
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
                if (!validHeaderValue(value)) return error.Header;
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
        return .{ .arena = arena, .url = url, .method = method, .headers = headers, .extra_headers = extra.items, .body = body, .timeout_ms = timeout_ms };
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

fn optionalString(ctx: Context, gpa: std.mem.Allocator, options: Value, name: [:0]const u8) error{InvalidOption}!?[]u8 {
    const value = if (ctx.isUndefined(options)) quickjs.UNDEFINED else ctx.getPropertyStr(options, name);
    defer ctx.freeValue(value);
    if (ctx.isUndefined(value)) return null;
    return module.owned(ctx, gpa, value) orelse error.InvalidOption;
}

fn validHeaderName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |byte| switch (byte) {
        '0'...'9', 'A'...'Z', 'a'...'z', '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => {},
        else => return false,
    };
    return true;
}

fn validHeaderValue(value: []const u8) bool {
    for (value) |byte| if (byte != '\t' and std.ascii.isControl(byte)) return false;
    return true;
}

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
        error.Timeout => "timeoutMs must be a whole number of milliseconds up to 120000",
    });
    const signal = if (ctx.isUndefined(options)) quickjs.UNDEFINED else ctx.getPropertyStr(options, "signal");
    defer ctx.freeValue(signal);
    if (ctx.isException(signal)) {
        request.free(host.gpa);
        return pending.rejected(ctx, "the fetch signal could not be read");
    }
    return host.startTaskWithSignal(Request, httpTask, request, signal);
}

const canceled: pending.Result = .{ .failed = .{ .message = "the request was canceled" } };

fn httpTask(host: *Host, op: *pending.Op, request: Request) void {
    defer request.free(host.gpa);
    std.debug.assert(op.result == null);
    if (op.cancel.isRequested()) return op.finish(canceled);
    var result: pending.Result = canceled;
    const timeout: std.Io.Timeout = .{ .duration = .{ .clock = .awake, .raw = .fromMilliseconds(request.timeout_ms) } };
    const outcome = op.cancel.runChildTimeout(host.io, timeout, httpWorker, .{ host, op, request, &result }) catch {
        result.deinit(host.gpa);
        return op.finish(.{ .failed = .{ .message = "the request timed out" } });
    };
    switch (outcome) {
        .returned => |started| started catch {
            result.deinit(host.gpa);
            return op.finish(.{ .failed = .{ .message = "the host cannot start another operation" } });
        },
        .canceled, .aborted => {
            result.deinit(host.gpa);
            result = canceled;
        },
    }
    op.finish(result);
}

fn httpWorker(host: *Host, op: *pending.Op, request: Request, result: *pending.Result) error{}!void {
    defer op.cancel.finish(host.io);
    std.debug.assert(result.* == .failed);
    result.* = .{ .http = exchange(host, request) catch |err| {
        result.* = .{ .failed = .{ .message = switch (err) {
            error.Canceled => "the request was canceled",
            error.Redirect => "the request was redirected",
            error.StreamTooLong, error.HttpHeadersOversize => "the response exceeds the size limit",
            else => "the host could not complete the request",
        } } };
        return;
    } };
}

fn exchange(host: *Host, req: Request) !pending.Http {
    const uri = std.Uri.parse(req.url) catch unreachable;
    const client = host.http.acquire(host.gpa, host.io);
    var reused = false;
    return exchangeOnce(client, req, uri, &reused) catch |err| {
        // A stale idle connection may retry a safe method, but never replay a body or a partial response.
        if (!reused or (req.method != .GET and req.method != .HEAD)) return err;
        switch (err) {
            error.WriteFailed, error.ReadFailed, error.EndOfStream, error.HttpConnectionClosing => return exchangeOnce(client, req, uri, &reused),
            else => return err,
        }
    };
}

fn exchangeOnce(client: *std.http.Client, req: Request, uri: std.Uri, reused: *bool) !pending.Http {
    const gpa = client.allocator;
    const io = client.io;
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
    var request = client.request(req.method, uri, .{ .connection = connection, .redirect_behavior = .unhandled, .handle_continue = false, .headers = req.headers, .extra_headers = req.extra_headers }) catch |err| {
        if (connection) |held| {
            held.closing = true;
            client.connection_pool.release(held, io);
        }
        return err;
    };
    defer request.deinit();
    errdefer if (request.connection) |held| {
        held.closing = true;
    };
    // Check content encoding after the status, so a compressed redirect still reports a redirect.
    request.accept_encoding = @splat(true);
    if (req.method.requestHasBody()) try request.sendBodyComplete(req.body orelse &.{}) else try request.sendBodiless();
    var response = response: while (true) {
        // Validate digits before the standard parser converts the untrusted status to u10.
        const prefix = try request.connection.?.reader().peekArray(12);
        if (prefix[9] < '1' or prefix[9] > '5' or !std.ascii.isDigit(prefix[10]) or !std.ascii.isDigit(prefix[11])) return error.BadStatus;
        const head = try request.receiveHead(&.{});
        if (@intFromEnum(head.head.status) >= 200) break :response head;
        if (head.head.status == .switching_protocols) return error.BadStatus;
        try io.checkCancel();
    };
    reused.* = false;
    const status: u16 = @intFromEnum(response.head.status);
    if (status >= 300 and status < 400) return error.Redirect;
    const has_body = req.method != .HEAD and status != 204 and status != 205;
    if (has_body and response.head.content_encoding != .identity) return error.UnsupportedEncoding;
    const content_length = if (has_body and response.head.transfer_encoding == .none) response.head.content_length else null;
    if (content_length) |length| if (length > max_response_bytes) return error.StreamTooLong;

    // The body reader invalidates the head slices, so copy the bounded headers first.
    var headers: std.ArrayList(pending.Http.Header) = .empty;
    errdefer {
        for (headers.items) |header| header.free(gpa);
        headers.deinit(gpa);
    }
    var total: usize = 0;
    var it = response.head.iterateHeaders();
    next_header: while (it.next()) |header| {
        if (!validHeaderName(header.name) or !validHeaderValue(header.value)) return error.BadHeader;
        for (headers.items) |held| if (std.ascii.eqlIgnoreCase(held.name, header.name)) continue :next_header;
        const size = header.name.len + header.value.len;
        if (headers.items.len == max_response_headers or size > max_response_header_bytes - total) return error.StreamTooLong;
        const name = try gpa.dupeZ(u8, header.name);
        errdefer gpa.free(name);
        _ = std.ascii.lowerString(name, name);
        const value = try utf8.sanitize(gpa, header.value);
        errdefer gpa.free(value);
        try headers.append(gpa, .{ .name = name, .value = value });
        total += size;
    }
    var transfer: [4096]u8 = undefined;
    const raw = if (!has_body) try gpa.alloc(u8, 0) else body: {
        const reader = response.reader(&transfer);
        if (content_length) |length| {
            const bytes = try gpa.alloc(u8, @intCast(length));
            errdefer gpa.free(bytes);
            try reader.readSliceAll(bytes);
            break :body bytes;
        }
        // The reader's limit is exclusive, so one extra byte distinguishes the cap from overflow.
        break :body try reader.allocRemaining(gpa, .limited(max_response_bytes + 1));
    };
    if (!has_body) request.reader.state = .ready;
    const body = if (std.unicode.utf8ValidateSlice(raw)) raw else body: {
        defer gpa.free(raw);
        break :body try utf8.sanitize(gpa, raw);
    };
    errdefer gpa.free(body);
    return .{ .status = status, .body = body, .headers = try headers.toOwnedSlice(gpa) };
}
