//! The native `yuke:client-native` module. It backs the `yuke:client` facade with a per-daemon
//! connection map. R0 is the skeleton; the ws transport and the async request land in R1.
const std = @import("std");
const quickjs = @import("quickjs");
const Host = @import("../host.zig").Host;

const Context = quickjs.Context;
const Value = quickjs.Value;
const Module = Context.Module;

/// The connection key of the single local daemon. A remote is "remote:" ++ device_id.
pub const local_key = "local";

/// A connection's lifecycle. Only the dial produces a transport; the rest is shared local and remote.
pub const State = enum { disconnected, connecting, ready, closing };

/// The transport is the only part that differs local and remote. R1 builds `local`; `relay` waits.
pub const Transport = union(enum) {
    none,
    local, // R1: a WebSocket over a loopback TCP link
    relay, // later: a Noise IK link over the relay
};

/// One daemon connection. Heap-allocated and address-pinned, so a task can hold it by pointer.
pub const Connection = struct {
    key: []const u8, // owned
    state: State,
    transport: Transport,

    fn create(gpa: std.mem.Allocator, key: []const u8) !*Connection {
        const self = try gpa.create(Connection);
        errdefer gpa.destroy(self);
        self.* = .{ .key = try gpa.dupe(u8, key), .state = .disconnected, .transport = .none };
        return self;
    }

    fn destroy(self: *Connection, gpa: std.mem.Allocator) void {
        gpa.free(self.key);
        gpa.destroy(self);
    }
};

/// The module state on the Host: the map of connections, keyed by connKey.
pub const Client = struct {
    gpa: std.mem.Allocator,
    conns: std.StringHashMapUnmanaged(*Connection),

    pub fn create(gpa: std.mem.Allocator) !*Client {
        const self = try gpa.create(Client);
        self.* = .{ .gpa = gpa, .conns = .empty };
        return self;
    }

    pub fn destroy(self: *Client) void {
        var it = self.conns.valueIterator();
        while (it.next()) |conn| conn.*.destroy(self.gpa);
        self.conns.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    /// Return the connection for `key`, or create a fresh disconnected one.
    fn ensure(self: *Client, key: []const u8) !*Connection {
        if (self.conns.get(key)) |conn| return conn;
        const conn = try Connection.create(self.gpa, key);
        errdefer conn.destroy(self.gpa);
        try self.conns.put(self.gpa, conn.key, conn);
        return conn;
    }
};

/// Register the closed `yuke:client-native` module and export `native`.
pub fn install(host: *Host) error{OutOfMemory}!void {
    std.debug.assert(host.phase == .open);
    const m = host.ctx.newModule("yuke:client-native", init) orelse return error.OutOfMemory;
    host.ctx.addModuleExport(m, "native") catch return error.OutOfMemory;
}

fn init(ctx: Context, m: Module) c_int {
    const host = Host.fromContext(ctx);
    std.debug.assert(host.phase == .open);

    const native = ctx.newObject();
    if (ctx.isException(native)) return -1;
    if (bindAll(ctx, native) != 0) {
        ctx.freeValue(native);
        return -1;
    }
    // `setModuleExport` consumes `native` on success and on failure, so the catch must not free it.
    ctx.setModuleExport(m, "native", native) catch return -1;
    return 0;
}

fn bindAll(ctx: Context, native: Value) c_int {
    bind(ctx, native, "connect", 1, jsConnect) catch return -1;
    bind(ctx, native, "disconnect", 1, jsDisconnect) catch return -1;
    bind(ctx, native, "state", 1, jsState) catch return -1;
    bind(ctx, native, "connections", 0, jsConnections) catch return -1;
    bind(ctx, native, "devices", 0, jsDevices) catch return -1;
    bind(ctx, native, "request", 3, jsRequest) catch return -1;
    bind(ctx, native, "sessionOpen", 2, jsSessionOpen) catch return -1;
    bind(ctx, native, "sessionClose", 2, jsSessionClose) catch return -1;
    bind(ctx, native, "sessionRev", 2, jsSessionRev) catch return -1;
    bind(ctx, native, "sessionResync", 2, jsSessionResync) catch return -1;
    bind(ctx, native, "sessionOutline", 2, jsSessionOutline) catch return -1;
    bind(ctx, native, "sessionText", 3, jsSessionText) catch return -1;
    return 0;
}

fn bind(ctx: Context, obj: Value, name: [*:0]const u8, length: c_int, comptime fn_: fn (Context, Value, []const Value) Value) !void {
    try ctx.setPropertyStr(obj, name, ctx.newFunction(name, length, fn_));
}

// A settled Promise the caller returns to JS. R1 keeps the resolvers instead, to settle later.
fn resolvedPromise(ctx: Context, value: Value) Value {
    var funcs: [2]Value = undefined;
    const promise = ctx.newPromiseCapability(&funcs);
    if (ctx.isException(promise)) {
        ctx.freeValue(value);
        return promise;
    }
    ctx.freeValue(ctx.call(funcs[0], quickjs.UNDEFINED, &.{value}));
    ctx.freeValue(funcs[0]);
    ctx.freeValue(funcs[1]);
    ctx.freeValue(value);
    return promise;
}

fn rejectedPromise(ctx: Context, code: [*:0]const u8) Value {
    var funcs: [2]Value = undefined;
    const promise = ctx.newPromiseCapability(&funcs);
    if (ctx.isException(promise)) return promise;
    const err = ctx.newString(std.mem.span(code));
    if (ctx.isException(err)) {
        ctx.freeValue(funcs[0]);
        ctx.freeValue(funcs[1]);
        ctx.freeValue(promise);
        return err;
    }
    ctx.freeValue(ctx.call(funcs[1], quickjs.UNDEFINED, &.{err}));
    ctx.freeValue(err);
    ctx.freeValue(funcs[0]);
    ctx.freeValue(funcs[1]);
    return promise;
}

// R0 has no transport, so connect fails and every read reports an absent connection. R1 dials.

fn jsConnect(ctx: Context, _: Value, _: []const Value) Value {
    return rejectedPromise(ctx, "not_implemented");
}

fn jsDisconnect(_: Context, _: Value, _: []const Value) Value {
    return quickjs.UNDEFINED;
}

fn jsState(ctx: Context, _: Value, _: []const Value) Value {
    return ctx.newString("disconnected");
}

fn jsConnections(ctx: Context, _: Value, _: []const Value) Value {
    return ctx.newArray();
}

fn jsDevices(ctx: Context, _: Value, _: []const Value) Value {
    return resolvedPromise(ctx, ctx.newArray());
}

fn jsRequest(ctx: Context, _: Value, _: []const Value) Value {
    return rejectedPromise(ctx, "not_connected");
}

fn jsSessionOpen(_: Context, _: Value, _: []const Value) Value {
    return quickjs.UNDEFINED;
}

fn jsSessionClose(_: Context, _: Value, _: []const Value) Value {
    return quickjs.UNDEFINED;
}

fn jsSessionRev(ctx: Context, _: Value, _: []const Value) Value {
    return ctx.newInt32(-1);
}

fn jsSessionResync(ctx: Context, _: Value, _: []const Value) Value {
    return rejectedPromise(ctx, "not_connected");
}

fn jsSessionOutline(ctx: Context, _: Value, _: []const Value) Value {
    return ctx.newString("null");
}

fn jsSessionText(ctx: Context, _: Value, _: []const Value) Value {
    return ctx.newString("");
}

test "client map creates and destroys connections" {
    const gpa = std.testing.allocator;
    const client = try Client.create(gpa);
    defer client.destroy();
    const a = try client.ensure("local");
    const b = try client.ensure("local");
    try std.testing.expectEqual(a, b);
    try std.testing.expectEqual(State.disconnected, a.state);
    _ = try client.ensure("remote:d1");
    try std.testing.expectEqual(@as(usize, 2), client.conns.count());
}
