//! OAuth helpers for MCP sign-in: secure random values, SHA-256 for PKCE, and one loopback callback.

const std = @import("std");
const quickjs = @import("quickjs");
const Host = @import("../host.zig").Host;
const module = @import("module.zig");
const pending = @import("../pending.zig");

const Context = quickjs.Context;
const Value = quickjs.Value;
const Sha256 = std.crypto.hash.sha2.Sha256;
const base64url = std.base64.url_safe_no_pad.Encoder;

/// One sign-in holds one listener, so a small bound is enough.
const max_listeners = 4;
const default_timeout_ms = 300_000;
const max_timeout_ms = 900_000;
/// A browser opens and closes some connections that carry no callback, so the listener skips at most this many.
const max_stray_requests = 32;

const canceled: pending.Failure = .{ .message = "the sign-in was canceled", .code = "CANCELED" };
const timed_out: pending.Failure = .{ .message = "the sign-in timed out", .code = "TIMED_OUT" };
const io_failed: pending.Failure = .{ .message = "the sign-in callback failed", .code = "IO_ERROR" };
const failures: pending.Failures = .{ .canceled = .{ .failed = canceled }, .timed_out = .{ .failed = timed_out }, .failed = .{ .failed = io_failed } };
const limits: module.IoLimits = .{ .default_timeout_ms = default_timeout_ms, .max_timeout_ms = max_timeout_ms };

const page = "<!doctype html><title>yuke</title><p>The sign-in is complete. You can close this window.</p>";

/// A loopback server that takes one callback. The host has one executor, so tasks share this state only across suspension points.
pub const Listener = struct {
    host: *Host,
    id: u32 = 0,
    server: ?std.Io.net.Server,
    closed: bool = false,
    busy: bool = false,
    op: ?*pending.Op = null,

    pub fn close(self: *Listener) void {
        if (self.closed) return;
        self.closed = true;
        if (self.op) |op| op.cancel.request(self.host.io);
        if (!self.busy) self.release();
    }

    /// Remove the record before the socket closes, so reap never sees a half-closed listener.
    fn release(self: *Listener) void {
        var server = self.server orelse return;
        self.server = null;
        server.deinit(self.host.io);
    }

    pub fn done(self: *const Listener) bool {
        return self.closed and !self.busy;
    }

    pub fn deinit(self: *Listener, _: std.mem.Allocator) void {
        std.debug.assert(self.server == null);
    }
};

pub const Listeners = module.Table(Listener);

pub fn install(host: *Host) void {
    module.installFunctions(host, "yuke:oauth-native", &.{
        .{ .name = "random", .arity = 1, .call = jsRandom },
        .{ .name = "sha256", .arity = 1, .call = jsSha256 },
        .{ .name = "listen", .arity = 0, .call = jsListen },
        .{ .name = "accept", .arity = 2, .call = jsAccept },
        .{ .name = "close", .arity = 1, .call = jsClose },
    });
}

/// Answer `count` secure random bytes as base64url without padding, for a PKCE verifier or a state value.
fn jsRandom(ctx: Context, _: Value, args: []const Value) Value {
    const count = (if (args.len == 1) module.integer(ctx, args[0], 16, 64) else null) orelse return ctx.throwTypeError("random needs a byte count from 16 to 64");
    var bytes: [64]u8 = undefined;
    Host.fromContext(ctx).io.randomSecure(bytes[0..@intCast(count)]) catch return ctx.throwTypeError("the system has no secure random source");
    var text: [base64url.calcSize(64)]u8 = undefined;
    return ctx.newString(base64url.encode(&text, bytes[0..@intCast(count)]));
}

/// Answer the SHA-256 of the UTF-8 text as base64url without padding, the PKCE S256 challenge.
fn jsSha256(ctx: Context, _: Value, args: []const Value) Value {
    if (args.len != 1) return ctx.throwTypeError("sha256 needs a string");
    const text = module.string(ctx, args[0]) orelse return ctx.throwTypeError("sha256 needs a string");
    defer ctx.freeCString(text.ptr);
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(text, &digest, .{});
    var encoded: [base64url.calcSize(Sha256.digest_length)]u8 = undefined;
    return ctx.newString(base64url.encode(&encoded, &digest));
}

/// Bind a loopback port for one redirect and answer `{ id, port }`. The port is random, as RFC 8252 asks of a native client.
fn jsListen(ctx: Context, _: Value, _: []const Value) Value {
    const host = Host.fromContext(ctx);
    if (!host.acceptsIo()) return ctx.throwTypeError("the host is closed");
    if (host.oauth.full(host.gpa, max_listeners)) return ctx.throwTypeError("the host holds 4 sign-in listeners");
    const address = std.Io.net.IpAddress.parseIp4("127.0.0.1", 0) catch unreachable;
    const server = address.listen(host.io, .{}) catch return ctx.throwTypeError("the sign-in callback could not listen on a loopback port");
    const port = server.socket.address.getPort();
    const listener = host.oauth.add(host.gpa, .{ .host = host, .server = server });
    return module.toJs(ctx, .{ .id = listener.id, .port = port });
}

const Accept = struct {
    listener: *Listener,
    deadline: std.Io.Clock.Timestamp,

    pub fn free(self: Accept, _: std.mem.Allocator) void {
        const listener = self.listener;
        std.debug.assert(listener.busy);
        listener.op = null;
        // One listener takes one callback, so it closes after its only accept; it stays busy until the socket is closed.
        listener.closed = true;
        listener.release();
        listener.busy = false;
        listener.host.wake.set(listener.host.io);
    }
};

/// Wait for the redirect to `/callback` and answer its request target. The page tells the user to close the window.
fn jsAccept(ctx: Context, _: Value, args: []const Value) Value {
    const host = Host.fromContext(ctx);
    if (!host.acceptsIo()) return pending.rejectedWith(ctx, canceled);
    const listener = host.oauth.findArg(ctx, args) orelse return pending.rejected(ctx, "the sign-in listener is closed");
    if (listener.closed or listener.busy) return pending.rejected(ctx, "the sign-in listener is closed or busy");
    const options = module.ioOptions(host, if (args.len > 1) args[1] else quickjs.UNDEFINED, limits) catch return pending.rejected(ctx, "a sign-in option is invalid");
    defer ctx.freeValue(options.signal);
    listener.busy = true;
    return host.startTask(Accept, acceptTask, .{ .listener = listener, .deadline = options.deadline }, .{ .signal = options.signal });
}

fn acceptTask(host: *Host, op: *pending.Op, request: Accept) void {
    defer request.free(host.gpa);
    const listener = request.listener;
    listener.op = op;
    const result = if (listener.closed) failures.canceled else pending.runTimed(host, op, .{ .deadline = request.deadline }, acceptWorker, listener, failures);
    op.finish(result);
}

fn acceptWorker(host: *Host, listener: *Listener, result: *pending.Result) error{}!void {
    var server = &listener.server.?;
    for (0..max_stray_requests) |_| {
        const stream = server.accept(host.io) catch {
            result.* = .{ .failed = io_failed };
            return;
        };
        defer stream.close(host.io);
        if (answer(host, stream) catch null) |target| {
            result.* = .{ .text = target };
            return;
        }
    }
    result.* = .{ .failed = io_failed };
}

/// Serve one request. A GET to `/callback` answers its target; any other request gets 404 and null.
fn answer(host: *Host, stream: std.Io.net.Stream) !?[]u8 {
    var read_buf: [8192]u8 = undefined;
    var write_buf: [1024]u8 = undefined;
    var reader = stream.reader(host.io, &read_buf);
    var writer = stream.writer(host.io, &write_buf);
    var server = std.http.Server.init(&reader.interface, &writer.interface);
    var request = try server.receiveHead();
    const target = request.head.target;
    const path_end = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    if (request.head.method != .GET or !std.mem.eql(u8, target[0..path_end], "/callback")) {
        try request.respond("", .{ .status = .not_found, .keep_alive = false });
        return null;
    }
    // The reader reuses its buffer, so the target is copied before the answer.
    const owned = try host.gpa.dupe(u8, target);
    errdefer host.gpa.free(owned);
    try request.respond(page, .{ .keep_alive = false, .extra_headers = &.{.{ .name = "content-type", .value = "text/html; charset=utf-8" }} });
    return owned;
}

fn jsClose(ctx: Context, _: Value, args: []const Value) Value {
    if (Host.fromContext(ctx).oauth.findArg(ctx, args)) |listener| listener.close();
    return quickjs.UNDEFINED;
}
