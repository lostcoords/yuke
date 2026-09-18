//! Socket tasks use the host reactor; only the owner enters JavaScript.

const std = @import("std");
const quickjs = @import("quickjs");
const Host = @import("../host.zig").Host;
const module = @import("module.zig");
const pending = @import("../pending.zig");
const cancellation = @import("cancellation.zig");
const Context = quickjs.Context;
const Value = quickjs.Value;

pub const max_connections = 64;
pub const max_bytes = 1024 * 1024;
const default_read_bytes = 64 * 1024;
const default_timeout_ms = 5000;
const max_timeout_ms = 600_000;

const canceled: pending.Failure = .{ .message = "the socket operation was canceled", .code = "CANCELED" };
const closed: pending.Failure = .{ .message = "the socket is closed", .code = "CLOSED" };
const timed_out: pending.Failure = .{ .message = "the socket operation timed out", .code = "TIMED_OUT" };
const io_failed: pending.Failure = .{ .message = "the socket operation failed", .code = "IO_ERROR" };

// The host has one executor, so tasks share this state only across suspension points.
const Connection = struct {
    host: *Host,
    id: u32,
    stream: ?std.Io.net.Stream = null,
    closed: bool = false,
    finished: bool = false,
    read_busy: bool = false,
    write_busy: bool = false,
    connect_op: ?*pending.Op = null,
    read_op: ?*pending.Op = null,
    write_op: ?*pending.Op = null,
    changed: std.Io.Event = .unset,

    fn close(self: *Connection) void {
        if (self.closed) return;
        self.closed = true;
        for ([_]?*pending.Op{ self.connect_op, self.read_op, self.write_op }) |maybe| {
            if (maybe) |op| op.cancel.request(self.host.io);
        }
        self.changed.set(self.host.io);
    }
};

pub const Connections = struct {
    live: std.ArrayList(*Connection) = .empty,
    last_id: u32 = 0,

    fn find(self: *Connections, id: u32) ?*Connection {
        for (self.live.items) |connection| if (connection.id == id) return connection;
        return null;
    }

    pub fn reap(self: *Connections, gpa: std.mem.Allocator) void {
        var i: usize = 0;
        while (i < self.live.items.len) {
            const connection = self.live.items[i];
            if (!connection.finished) {
                i += 1;
                continue;
            }
            std.debug.assert(connection.closed and connection.stream == null);
            std.debug.assert(!connection.read_busy and !connection.write_busy);
            _ = self.live.swapRemove(i);
            gpa.destroy(connection);
        }
    }

    pub fn closeAll(self: *Connections) void {
        for (self.live.items) |connection| connection.close();
    }

    pub fn deinit(self: *Connections, gpa: std.mem.Allocator) void {
        self.reap(gpa);
        std.debug.assert(self.live.items.len == 0);
        self.live.deinit(gpa);
        self.* = .{};
    }
};

pub fn install(host: *Host) void {
    module.installFunctions(host, "yuke:net-native", &.{
        .{ .name = "connect", .arity = 1, .call = jsConnect },
        .{ .name = "read", .arity = 2, .call = jsRead },
        .{ .name = "write", .arity = 3, .call = jsWrite },
        .{ .name = "close", .arity = 1, .call = jsClose },
    });
}

const Options = struct {
    signal: Value,
    deadline: std.Io.Clock.Timestamp,
    max_bytes: u32,

    fn parse(host: *Host, value: Value, read: bool) !Options {
        const ctx = host.ctx;
        if (!ctx.isUndefined(value) and (!ctx.isObject(value) or ctx.isArray(value))) return error.InvalidOption;
        const timeout_ms = (try module.optionalInteger(ctx, value, "timeoutMs", default_timeout_ms, max_timeout_ms)).?;
        const limit = if (read) (try module.optionalInteger(ctx, value, "maxBytes", default_read_bytes, max_bytes)).? else 0;
        const signal = if (ctx.isObject(value)) ctx.getPropertyStr(value, "signal") else quickjs.UNDEFINED;
        if (ctx.isException(signal)) return error.InvalidOption;
        errdefer ctx.freeValue(signal);
        if (!ctx.isUndefined(signal) and cancellation.get(ctx, signal) == null) return error.InvalidOption;
        return .{
            .signal = signal,
            .deadline = .fromNow(host.io, .{ .clock = .awake, .raw = .fromMilliseconds(timeout_ms) }),
            .max_bytes = limit,
        };
    }
};

const Kind = enum { connect, read, write };
const Request = struct {
    connection: *Connection,
    kind: Kind,
    bytes: []u8 = &.{},
    max_bytes: u32 = 0,
    deadline: std.Io.Clock.Timestamp,

    pub fn free(self: Request, gpa: std.mem.Allocator) void {
        const connection = self.connection;
        gpa.free(self.bytes);
        switch (self.kind) {
            .connect => {
                std.debug.assert(connection.stream == null);
                connection.connect_op = null;
                connection.closed = true;
                connection.finished = true;
            },
            .read => {
                std.debug.assert(connection.read_busy);
                connection.read_op = null;
                connection.read_busy = false;
            },
            .write => {
                std.debug.assert(connection.write_busy);
                connection.write_op = null;
                connection.write_busy = false;
            },
        }
        connection.changed.set(connection.host.io);
        connection.host.wake.set(connection.host.io);
    }
};

fn invalid(ctx: Context) Value {
    return pending.rejectedWith(ctx, .{ .message = "invalid socket arguments", .code = "INVALID_ARGUMENT" });
}

fn jsConnect(ctx: Context, _: Value, args: []const Value) Value {
    const host = Host.fromContext(ctx);
    if (!host.acceptsIo()) return pending.rejectedWith(ctx, closed);
    if (args.len == 0 or !ctx.isObject(args[0]) or ctx.isArray(args[0])) return invalid(ctx);
    const options = Options.parse(host, args[0], false) catch return invalid(ctx);
    defer ctx.freeValue(options.signal);
    const path_value = ctx.getPropertyStr(args[0], "path");
    defer ctx.freeValue(path_value);
    const path = module.string(ctx, path_value) orelse return invalid(ctx);
    defer ctx.freeCString(path.ptr);
    if (path.len == 0 or path.len > std.Io.net.UnixAddress.max_len or std.mem.indexOfScalar(u8, path, 0) != null) return invalid(ctx);
    if (isAborted(ctx, options.signal)) return pending.rejectedWith(ctx, canceled);
    host.net.reap(host.gpa);
    if (host.net.live.items.len == max_connections or host.net.last_id == std.math.maxInt(u32))
        return pending.rejectedWith(ctx, .{ .message = "the socket limit was reached", .code = "LIMIT" });
    const connection = host.gpa.create(Connection) catch unreachable;
    host.net.last_id += 1;
    connection.* = .{ .host = host, .id = host.net.last_id };
    host.net.live.append(host.gpa, connection) catch unreachable;
    const request: Request = .{ .connection = connection, .kind = .connect, .bytes = host.gpa.dupe(u8, path) catch unreachable, .deadline = options.deadline };
    return host.startTaskWithSignal(Request, connectTask, request, options.signal);
}

fn isAborted(ctx: Context, signal: Value) bool {
    return if (cancellation.get(ctx, signal)) |token| token.aborted else false;
}

fn connectionArg(host: *Host, args: []const Value) ?*Connection {
    if (args.len == 0) return null;
    const id = module.integer(host.ctx, args[0], 1, std.math.maxInt(u32)) orelse return null;
    const connection = host.net.find(@intCast(id)) orelse return null;
    if (connection.closed or connection.stream == null) return null;
    return connection;
}

fn jsRead(ctx: Context, _: Value, args: []const Value) Value {
    const host = Host.fromContext(ctx);
    if (!host.acceptsIo()) return pending.rejectedWith(ctx, closed);
    const options = Options.parse(host, if (args.len > 1) args[1] else quickjs.UNDEFINED, true) catch return invalid(ctx);
    defer ctx.freeValue(options.signal);
    const connection = connectionArg(host, args) orelse return pending.rejectedWith(ctx, closed);
    if (isAborted(ctx, options.signal)) {
        connection.close();
        return pending.rejectedWith(ctx, canceled);
    }
    if (connection.read_busy) return pending.rejectedWith(ctx, .{ .message = "a socket read is already pending", .code = "BUSY" });
    connection.read_busy = true;
    return host.startTaskWithSignal(Request, ioTask, .{ .connection = connection, .kind = .read, .max_bytes = options.max_bytes, .deadline = options.deadline }, options.signal);
}

fn jsWrite(ctx: Context, _: Value, args: []const Value) Value {
    const host = Host.fromContext(ctx);
    if (!host.acceptsIo()) return pending.rejectedWith(ctx, closed);
    const options = Options.parse(host, if (args.len > 2) args[2] else quickjs.UNDEFINED, false) catch return invalid(ctx);
    defer ctx.freeValue(options.signal);
    if (args.len < 2) return invalid(ctx);
    const kind = ctx.getTypedArrayType(args[1]) catch return invalid(ctx);
    if (kind != .Uint8Array) return invalid(ctx);
    const bytes = ctx.getUint8Array(args[1]) catch return invalid(ctx);
    if (bytes.len > max_bytes) return invalid(ctx);
    const connection = connectionArg(host, args) orelse return pending.rejectedWith(ctx, closed);
    if (isAborted(ctx, options.signal)) {
        connection.close();
        return pending.rejectedWith(ctx, canceled);
    }
    if (connection.write_busy) return pending.rejectedWith(ctx, .{ .message = "a socket write is already pending", .code = "BUSY" });
    connection.write_busy = true;
    return host.startTaskWithSignal(Request, ioTask, .{ .connection = connection, .kind = .write, .bytes = host.gpa.dupe(u8, bytes) catch unreachable, .deadline = options.deadline }, options.signal);
}

fn jsClose(ctx: Context, _: Value, args: []const Value) Value {
    const host = Host.fromContext(ctx);
    if (args.len > 0) if (module.integer(ctx, args[0], 1, std.math.maxInt(u32))) |id| {
        if (host.net.find(@intCast(id))) |connection| connection.close();
    };
    return quickjs.UNDEFINED;
}

fn run(host: *Host, op: *pending.Op, request: Request) pending.Result {
    var result: pending.Result = .{ .failed = canceled };
    if (request.connection.closed or op.cancel.isRequested()) return result;
    if (request.deadline.durationFromNow(host.io).raw.nanoseconds <= 0) return .{ .failed = timed_out };
    const outcome = op.cancel.runChildTimeout(host.io, .{ .deadline = request.deadline }, worker, .{ host, op, request, &result }) catch {
        result.deinit(host.gpa);
        return .{ .failed = timed_out };
    };
    switch (outcome) {
        .returned => |returned| returned catch {
            result.deinit(host.gpa);
            return .{ .failed = io_failed };
        },
        .canceled, .aborted => {
            result.deinit(host.gpa);
            return .{ .failed = canceled };
        },
    }
    return result;
}

fn connectTask(host: *Host, op: *pending.Op, request: Request) void {
    const connection = request.connection;
    defer request.free(host.gpa);
    connection.connect_op = op;
    const result = run(host, op, request);
    connection.connect_op = null;
    if (result == .failed) {
        if (connection.stream) |stream| stream.close(host.io);
        connection.stream = null;
        op.finish(result);
        return;
    }
    std.debug.assert(connection.stream != null and result == .number);
    op.finish(result);
    while (!connection.closed) {
        connection.changed.reset();
        connection.changed.wait(host.io) catch connection.close();
    }
    while (connection.read_busy or connection.write_busy) {
        connection.changed.reset();
        connection.changed.waitUncancelable(host.io);
    }
    connection.stream.?.close(host.io);
    connection.stream = null;
}

fn ioTask(host: *Host, op: *pending.Op, request: Request) void {
    defer request.free(host.gpa);
    const connection = request.connection;
    switch (request.kind) {
        .read => connection.read_op = op,
        .write => connection.write_op = op,
        .connect => unreachable,
    }
    const result = run(host, op, request);
    if (result == .failed) connection.close();
    op.finish(result);
}

fn worker(host: *Host, op: *pending.Op, request: Request, result: *pending.Result) error{}!void {
    defer op.cancel.finish(host.io);
    host.io.checkCancel() catch return;
    const connection = request.connection;
    switch (request.kind) {
        .connect => {
            const address = std.Io.net.UnixAddress.init(request.bytes) catch unreachable;
            connection.stream = address.connect(host.io) catch {
                result.* = .{ .failed = io_failed };
                return;
            };
            result.* = .{ .number = connection.id };
        },
        .read => {
            std.debug.assert(connection.stream != null and request.max_bytes > 0);
            const buffer = host.gpa.alloc(u8, request.max_bytes) catch unreachable;
            var reader = connection.stream.?.reader(host.io, &.{});
            var slices = [_][]u8{buffer};
            const n = reader.interface.readVec(&slices) catch |err| {
                host.gpa.free(buffer);
                result.* = if (err == error.EndOfStream) .null_value else .{ .failed = io_failed };
                return;
            };
            std.debug.assert(n > 0 and n <= buffer.len);
            result.* = .{ .bytes = .{ .buffer = buffer, .len = n } };
        },
        .write => {
            std.debug.assert(connection.stream != null);
            var writer = connection.stream.?.writer(host.io, &.{});
            writer.interface.writeAll(request.bytes) catch {
                result.* = .{ .failed = io_failed };
                return;
            };
            result.* = .undefined;
        },
    }
}
