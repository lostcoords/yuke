//! The native `yuke:client-native` module: a per-daemon connection map with an async request path.
const std = @import("std");
const zio = @import("zio");
const quickjs = @import("quickjs");
const websocket = @import("websocket");
const host_mod = @import("../host.zig");
const Host = host_mod.Host;
const owner = @import("../owner.zig");

const Context = quickjs.Context;
const Value = quickjs.Value;
const Module = Context.Module;

/// The connection key of the single local daemon. A remote is "remote:" ++ device_id.
pub const local_key = "local";
const ws_path = "/ws";
const read_buf_bytes = 16 * 1024;
const write_buf_bytes = 16 * 1024;
/// Cap each inbound message so a hostile peer cannot exhaust memory.
const max_message_bytes = 8 * 1024 * 1024;
/// Bound the TCP dial. A finite handshake deadline waits for R4.
const connect_timeout: std.Io.Timeout = .{ .duration = .{ .clock = .awake, .raw = std.Io.Duration.fromMilliseconds(10_000) } };

pub const State = enum { disconnected, connecting, ready, closing };

/// The transport is the only part that differs local and remote. R1 builds `local`; `relay` waits.
pub const Transport = union(enum) { none, local, relay };

/// A pending JS promise: the two resolver functions held as GC roots until it settles.
const Pending = struct { resolve: Value, reject: Value };

/// The heap stores each daemon connection at a stable address. A task holds its pointer.
pub const Connection = struct {
    client: *Client,
    key: []const u8, // owned
    state: State,
    transport: Transport,

    host_buf: [64]u8,
    host_len: usize,
    port: u16,

    // The transport is valid when has_transport is true. The reader task and the owner share the fd.
    stream: std.Io.net.Stream,
    reader: std.Io.net.Stream.Reader,
    writer: std.Io.net.Stream.Writer,
    read_buf: []u8, // the connection owns this buffer
    write_buf: []u8, // the connection owns this buffer
    has_transport: bool,

    next_id: u64,
    pending: std.AutoHashMapUnmanaged(u64, Pending),
    connect_pending: ?Pending,

    fn create(gpa: std.mem.Allocator, client: *Client, key: []const u8) !*Connection {
        const self = try gpa.create(Connection);
        errdefer gpa.destroy(self);
        self.* = .{
            .client = client,
            .key = try gpa.dupe(u8, key),
            .state = .disconnected,
            .transport = .none,
            .host_buf = undefined,
            .host_len = 0,
            .port = 0,
            .stream = undefined,
            .reader = undefined,
            .writer = undefined,
            .read_buf = &.{},
            .write_buf = &.{},
            .has_transport = false,
            .next_id = 1,
            .pending = .empty,
            .connect_pending = null,
        };
        return self;
    }

    /// Free the transport. The caller guarantees no reader task still uses it.
    fn teardownTransport(self: *Connection) void {
        if (!self.has_transport) return;
        self.has_transport = false;
        self.stream.close(self.client.io);
        self.client.gpa.free(self.read_buf);
        self.client.gpa.free(self.write_buf);
        self.read_buf = &.{};
        self.write_buf = &.{};
    }

    fn destroy(self: *Connection, gpa: std.mem.Allocator) void {
        self.teardownTransport();
        self.pending.deinit(gpa);
        gpa.free(self.key);
        gpa.destroy(self);
    }
};

/// The module state on the Host: the map of connections plus the reactor plumbing.
pub const Client = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    conns: std.StringHashMapUnmanaged(*Connection),
    owner_ch: ?*owner.Channel,
    group: std.Io.Group,
    /// The JS sink for `conn`/`session`/`index` events, or undefined. A GC root while set.
    event_sink: Value,

    pub fn create(gpa: std.mem.Allocator, io: std.Io) !*Client {
        const self = try gpa.create(Client);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .conns = .empty,
            .owner_ch = null,
            .group = .init,
            .event_sink = quickjs.UNDEFINED,
        };
        return self;
    }

    pub fn destroy(self: *Client) void {
        var it = self.conns.valueIterator();
        while (it.next()) |conn| conn.*.destroy(self.gpa);
        self.conns.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    /// Wire the owner channel. The reader tasks copy frames here.
    pub fn bind(self: *Client, ch: *owner.Channel) void {
        self.owner_ch = ch;
    }

    /// Cancel and join every reader and connect task. Idempotent and a no-op with no tasks.
    pub fn stopReaders(self: *Client) void {
        self.group.cancel(self.io);
    }

    /// Phase 1 teardown while the VM is valid: stop tasks, reject pending, free every JS root.
    pub fn shutdown(self: *Client, host: *Host) void {
        self.stopReaders();
        const ctx = host.ctx;
        var it = self.conns.valueIterator();
        while (it.next()) |cp| {
            const conn = cp.*;
            self.rejectAll(ctx, conn, "closed");
            conn.teardownTransport();
            conn.state = .disconnected;
        }
        if (!ctx.isUndefined(self.event_sink)) {
            ctx.freeValue(self.event_sink);
            self.event_sink = quickjs.UNDEFINED;
        }
    }

    fn ensure(self: *Client, key: []const u8) !*Connection {
        if (self.conns.get(key)) |conn| return conn;
        const conn = try Connection.create(self.gpa, self, key);
        errdefer conn.destroy(self.gpa);
        try self.conns.put(self.gpa, conn.key, conn);
        return conn;
    }

    /// Handle one daemon frame on the owner. It settles promises and emits events.
    pub fn onDaemon(self: *Client, host: *Host, d: *owner.Daemon) host_mod.Error!void {
        const conn = self.conns.get(d.key) orelse return;
        const ctx = host.ctx;
        switch (d.body) {
            .connected => {
                conn.state = .ready;
                self.resolveConnect(ctx, conn);
                self.emitConn(ctx, conn.key, "ready");
            },
            .connect_failed => |code| {
                conn.state = .disconnected;
                self.rejectConnect(ctx, conn, code);
            },
            .message => |bytes| self.route(ctx, conn, bytes),
            .closed => {
                self.rejectAll(ctx, conn, "closed");
                conn.state = .disconnected;
                conn.teardownTransport();
                self.emitConn(ctx, conn.key, "close");
            },
        }
        try host.drainJobs();
    }

    /// Route a response to its pending promise. R2 handles a frame without an id as a broadcast.
    fn route(self: *Client, ctx: Context, conn: *Connection, bytes: []u8) void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const v = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), bytes, .{}) catch return;
        const obj = switch (v) {
            .object => |o| o,
            else => return,
        };
        const id_val = obj.get("id") orelse return;
        const id_str = switch (id_val) {
            .string => |s| s,
            else => return,
        };
        // The id is an opaque string. Match the exact canonical decimal we sent, so "01" never aliases 1.
        const id = std.fmt.parseInt(u64, id_str, 10) catch return;
        var id_buf: [20]u8 = undefined;
        const canonical = std.fmt.bufPrint(&id_buf, "{d}", .{id}) catch return;
        if (!std.mem.eql(u8, id_str, canonical)) return;
        const entry = conn.pending.fetchRemove(id) orelse return;
        const p = entry.value;
        const text = ctx.newString(bytes);
        if (ctx.isException(text)) {
            ctx.freeValue(ctx.call(p.reject, quickjs.UNDEFINED, &.{}));
        } else {
            ctx.freeValue(ctx.call(p.resolve, quickjs.UNDEFINED, &.{text}));
            ctx.freeValue(text);
        }
        ctx.freeValue(p.resolve);
        ctx.freeValue(p.reject);
    }

    fn resolveConnect(_: *Client, ctx: Context, conn: *Connection) void {
        const p = conn.connect_pending orelse return;
        conn.connect_pending = null;
        ctx.freeValue(ctx.call(p.resolve, quickjs.UNDEFINED, &.{}));
        ctx.freeValue(p.resolve);
        ctx.freeValue(p.reject);
    }

    fn rejectConnect(_: *Client, ctx: Context, conn: *Connection, code: []const u8) void {
        const p = conn.connect_pending orelse return;
        conn.connect_pending = null;
        rejectRoot(ctx, p.reject, code);
        ctx.freeValue(p.resolve);
        ctx.freeValue(p.reject);
    }

    /// Reject every pending request and the connect promise, then free their roots.
    fn rejectAll(self: *Client, ctx: Context, conn: *Connection, code: []const u8) void {
        var it = conn.pending.valueIterator();
        while (it.next()) |p| {
            rejectRoot(ctx, p.reject, code);
            ctx.freeValue(p.resolve);
            ctx.freeValue(p.reject);
        }
        conn.pending.clearRetainingCapacity();
        self.rejectConnect(ctx, conn, code);
    }

    fn emitConn(self: *Client, ctx: Context, key: []const u8, kind: []const u8) void {
        if (ctx.isUndefined(self.event_sink)) return;
        const ev = ctx.newObject();
        if (ctx.isException(ev)) return;
        ctx.setPropertyStr(ev, "type", ctx.newString("conn")) catch {};
        ctx.setPropertyStr(ev, "key", ctx.newString(key)) catch {};
        ctx.setPropertyStr(ev, "kind", ctx.newString(kind)) catch {};
        ctx.freeValue(ctx.call(self.event_sink, quickjs.UNDEFINED, &.{ev}));
        ctx.freeValue(ev);
    }
};

/// Reject a promise with a string code. Fall back to an undefined reason under memory pressure.
fn rejectRoot(ctx: Context, reject: Value, code: []const u8) void {
    const e = ctx.newString(code);
    if (ctx.isException(e)) {
        ctx.freeValue(ctx.call(reject, quickjs.UNDEFINED, &.{}));
        return;
    }
    ctx.freeValue(ctx.call(reject, quickjs.UNDEFINED, &.{e}));
    ctx.freeValue(e);
}

/// Connect to the daemon, complete the handshake, deliver `.connected`, then read frames.
/// One task keeps `.connected` before any `.closed`. It never calls QuickJS.
fn connectionTask(conn: *Connection) void {
    const client = conn.client;
    const io = client.io;
    const gpa = client.gpa;

    const addr = std.Io.net.IpAddress.parse(conn.host_buf[0..conn.host_len], conn.port) catch
        return deliverFail(conn, "bad_address");
    const stream = addr.connect(io, .{ .mode = .stream, .timeout = connect_timeout }) catch
        return deliverFail(conn, "connect_failed");

    const rbuf = gpa.alloc(u8, read_buf_bytes) catch {
        stream.close(io);
        return deliverFail(conn, "oom");
    };
    const wbuf = gpa.alloc(u8, write_buf_bytes) catch {
        gpa.free(rbuf);
        stream.close(io);
        return deliverFail(conn, "oom");
    };
    conn.stream = stream;
    conn.read_buf = rbuf;
    conn.write_buf = wbuf;
    conn.reader = stream.reader(io, rbuf);
    conn.writer = stream.writer(io, wbuf);
    conn.has_transport = true;

    if (!handshake(conn)) {
        conn.teardownTransport();
        return deliverFail(conn, "handshake_failed");
    }
    deliver(conn, .connected);
    readLoop(conn);
}

/// Send the client handshake with the mandatory Host header. Return true on an `.ok` upgrade.
fn handshake(conn: *Connection) bool {
    var key: [16]u8 = undefined;
    zio.random(&key);
    var hdr_buf: [96]u8 = undefined;
    const host_header = std.fmt.bufPrint(&hdr_buf, "host: {s}:{d}\r\n", .{ conn.host_buf[0..conn.host_len], conn.port }) catch return false;
    const hs = websocket.handshake(&conn.reader.interface, &conn.writer.interface, &key, ws_path, .{ .extra_headers = host_header }) catch return false;
    return hs.result == .ok;
}

/// Read WebSocket messages and copy each text frame to the owner. It ends on a close or an error.
fn readLoop(conn: *Connection) void {
    const gpa = conn.client.gpa;
    var iter = websocket.AllocatingMessageIterator.init(max_message_bytes, max_message_bytes);
    defer iter.deinit(gpa);
    while (true) {
        const msg = iter.next(gpa, &conn.reader.interface) catch {
            deliver(conn, .closed);
            return;
        };
        switch (msg.opcode) {
            // RFC 6455: a text message must hold valid UTF-8. Fail the connection otherwise.
            .text => {
                if (!std.unicode.utf8ValidateSlice(msg.data)) {
                    gpa.free(msg.data);
                    deliver(conn, .closed);
                    return;
                }
                // `deliverMessage` gives the owner the payload. On failure the owner is gone.
                if (!deliverMessage(conn, msg.data)) {
                    gpa.free(msg.data);
                    return;
                }
            },
            // A binary frame is not a JSON response, so it fails the connection.
            .binary, .connection_close => {
                gpa.free(msg.data);
                deliver(conn, .closed);
                return;
            },
            else => gpa.free(msg.data), // ping and pong wait for R4.
        }
    }
}

fn deliver(conn: *Connection, body: owner.Daemon.Body) void {
    const ch = conn.client.owner_ch orelse return;
    ch.send(.{ .daemon = .{ .key = conn.key, .body = body } }) catch {};
}

fn deliverFail(conn: *Connection, code: []const u8) void {
    deliver(conn, .{ .connect_failed = code });
}

/// Hand an owned message to the owner. Return false when the owner is gone, so the caller frees it.
fn deliverMessage(conn: *Connection, data: []u8) bool {
    const ch = conn.client.owner_ch orelse return false;
    ch.send(.{ .daemon = .{ .key = conn.key, .body = .{ .message = data } } }) catch return false;
    return true;
}

fn writeRequest(conn: *Connection, payload: []const u8) !void {
    var mask_bytes: [4]u8 = undefined;
    zio.random(&mask_bytes);
    const mask: u32 = @bitCast(mask_bytes);
    try websocket.writeFrame(&conn.writer.interface, true, .text, payload, mask);
    try conn.writer.interface.flush();
}

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
    bind(ctx, native, "setEventSink", 1, jsSetEventSink) catch return -1;
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

// A settled Promise for a synchronous outcome. The async paths keep the resolvers instead.
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

/// Clear a pending exception from a throwing getter or an allocation, then reject with a code.
/// The owner drains jobs after this call, so a stale exception must not linger in the context.
fn rejectClearing(ctx: Context, code: [*:0]const u8) Value {
    ctx.freeValue(ctx.getException());
    return rejectedPromise(ctx, code);
}

/// Mark the connection closing and shut the socket down. The reader ends and reports `closed`.
fn failConnection(client: *Client, conn: *Connection) void {
    if (!conn.has_transport) return;
    conn.state = .closing;
    conn.stream.shutdown(client.io, .both) catch {};
}

fn jsSetEventSink(ctx: Context, _: Value, args: []const Value) Value {
    const client = Host.fromContext(ctx).client;
    if (!ctx.isUndefined(client.event_sink)) ctx.freeValue(client.event_sink);
    client.event_sink = if (args.len > 0) ctx.dupValue(args[0]) else quickjs.UNDEFINED;
    return quickjs.UNDEFINED;
}

fn jsConnect(ctx: Context, _: Value, args: []const Value) Value {
    const client = Host.fromContext(ctx).client;
    if (args.len < 1 or !ctx.isObject(args[0])) return rejectedPromise(ctx, "bad_options");
    const opts = args[0];

    const remote = ctx.getPropertyStr(opts, "remote");
    defer ctx.freeValue(remote);
    if (ctx.isException(remote)) return rejectClearing(ctx, "bad_options");
    if (ctx.toBool(remote) catch false) return rejectedPromise(ctx, "not_implemented");

    const host_val = ctx.getPropertyStr(opts, "host");
    defer ctx.freeValue(host_val);
    if (ctx.isException(host_val)) return rejectClearing(ctx, "bad_options");
    const port_val = ctx.getPropertyStr(opts, "port");
    defer ctx.freeValue(port_val);
    if (ctx.isException(port_val)) return rejectClearing(ctx, "bad_options");
    const host_str = ctx.toCStringLen(host_val) catch return rejectClearing(ctx, "bad_options");
    defer ctx.freeCString(host_str.ptr);
    const port = ctx.toInt32(port_val) catch return rejectClearing(ctx, "bad_options");
    if (host_str.len == 0 or host_str.len > 63 or port <= 0 or port > 65535) return rejectedPromise(ctx, "bad_options");

    if (client.owner_ch == null) return rejectedPromise(ctx, "no_owner");
    const conn = client.ensure(local_key) catch return rejectedPromise(ctx, "oom");
    if (conn.state != .disconnected) return rejectedPromise(ctx, "busy");

    @memcpy(conn.host_buf[0..host_str.len], host_str);
    conn.host_len = host_str.len;
    conn.port = @intCast(port);
    conn.transport = .local;

    var funcs: [2]Value = undefined;
    const promise = ctx.newPromiseCapability(&funcs);
    if (ctx.isException(promise)) return promise;
    conn.connect_pending = .{ .resolve = funcs[0], .reject = funcs[1] };
    conn.state = .connecting;

    client.group.concurrent(client.io, connectionTask, .{conn}) catch {
        conn.connect_pending = null;
        conn.state = .disconnected;
        rejectRoot(ctx, funcs[1], "spawn_failed");
        ctx.freeValue(funcs[0]);
        ctx.freeValue(funcs[1]);
        return promise;
    };
    return promise;
}

fn jsDisconnect(ctx: Context, _: Value, args: []const Value) Value {
    const client = Host.fromContext(ctx).client;
    const key = keyArg(ctx, args) orelse return quickjs.UNDEFINED;
    defer ctx.freeCString(key.ptr);
    const conn = client.conns.get(key) orelse return quickjs.UNDEFINED;
    failConnection(client, conn);
    return quickjs.UNDEFINED;
}

fn jsState(ctx: Context, _: Value, args: []const Value) Value {
    const client = Host.fromContext(ctx).client;
    const key = keyArg(ctx, args) orelse return ctx.newString("disconnected");
    defer ctx.freeCString(key.ptr);
    const conn = client.conns.get(key) orelse return ctx.newString("disconnected");
    return ctx.newString(@tagName(conn.state));
}

fn jsConnections(ctx: Context, _: Value, _: []const Value) Value {
    const client = Host.fromContext(ctx).client;
    const arr = ctx.newArray();
    if (ctx.isException(arr)) return arr;
    var i: u32 = 0;
    var it = client.conns.iterator();
    while (it.next()) |e| : (i += 1) {
        const o = ctx.newObject();
        ctx.setPropertyStr(o, "key", ctx.newString(e.key_ptr.*)) catch {};
        ctx.setPropertyStr(o, "state", ctx.newString(@tagName(e.value_ptr.*.state))) catch {};
        ctx.setPropertyUint32(arr, i, o) catch {};
    }
    return arr;
}

fn jsDevices(ctx: Context, _: Value, _: []const Value) Value {
    return resolvedPromise(ctx, ctx.newArray());
}

fn jsRequest(ctx: Context, _: Value, args: []const Value) Value {
    const client = Host.fromContext(ctx).client;
    if (args.len < 3) return rejectedPromise(ctx, "bad_request");
    const key = ctx.toCStringLen(args[0]) catch return rejectClearing(ctx, "bad_request");
    defer ctx.freeCString(key.ptr);
    const method = ctx.toCStringLen(args[1]) catch return rejectClearing(ctx, "bad_request");
    defer ctx.freeCString(method.ptr);
    const params = ctx.toCStringLen(args[2]) catch return rejectClearing(ctx, "bad_request");
    defer ctx.freeCString(params.ptr);

    const conn = client.conns.get(key) orelse return rejectedPromise(ctx, "not_connected");
    if (conn.state != .ready) return rejectedPromise(ctx, "not_connected");

    const id = conn.next_id;
    const envelope = std.fmt.allocPrint(client.gpa, "{{\"id\":\"{d}\",\"method\":\"{s}\",\"params\":{s}}}", .{ id, method, params }) catch
        return rejectedPromise(ctx, "oom");
    defer client.gpa.free(envelope);

    // Store the pending entry before the write, so a response never arrives without a claim.
    var funcs: [2]Value = undefined;
    const promise = ctx.newPromiseCapability(&funcs);
    if (ctx.isException(promise)) return promise;
    conn.pending.put(client.gpa, id, .{ .resolve = funcs[0], .reject = funcs[1] }) catch {
        rejectRoot(ctx, funcs[1], "oom");
        ctx.freeValue(funcs[0]);
        ctx.freeValue(funcs[1]);
        return promise;
    };
    conn.next_id += 1;
    writeRequest(conn, envelope) catch {
        // The write failed. Reject this request and fail the connection, so no partial stream is reused.
        if (conn.pending.fetchRemove(id)) |e| {
            rejectRoot(ctx, e.value.reject, "write_failed");
            ctx.freeValue(e.value.resolve);
            ctx.freeValue(e.value.reject);
        }
        failConnection(client, conn);
    };
    return promise;
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

/// Convert the first argument to an owned C string, or null when absent. The caller frees it.
fn keyArg(ctx: Context, args: []const Value) ?[:0]const u8 {
    if (args.len < 1) return null;
    return ctx.toCStringLen(args[0]) catch null;
}

test "client map creates and destroys connections" {
    const client = try Client.create(std.testing.allocator, std.testing.io);
    defer client.destroy();
    const a = try client.ensure("local");
    const b = try client.ensure("local");
    try std.testing.expectEqual(a, b);
    try std.testing.expectEqual(State.disconnected, a.state);
    _ = try client.ensure("remote:d1");
    try std.testing.expectEqual(@as(usize, 2), client.conns.count());
}

const wss = websocket.server;

/// A one-shot mock daemon: accept, upgrade, then echo every request id in a minimal result.
fn mockServer(io: std.Io, server: *std.Io.net.Server, gpa: std.mem.Allocator) void {
    const stream = server.accept(io) catch return;
    defer stream.close(io);
    var rbuf: [8192]u8 = undefined;
    var wbuf: [8192]u8 = undefined;
    var reader = stream.reader(io, &rbuf);
    var writer = stream.writer(io, &wbuf);
    var http_server = std.http.Server.init(&reader.interface, &writer.interface);
    var request = http_server.receiveHead() catch return;
    const key = switch (request.upgradeRequested()) {
        .websocket => |maybe_key| maybe_key orelse return,
        else => return,
    };
    var socket = request.respondWebSocket(.{ .key = key }) catch return;
    socket.output.flush() catch return;

    var mr = wss.MessageReader.init(1 << 20);
    defer mr.deinit(gpa);
    while (true) {
        var msg = mr.next(gpa, socket.input) catch return;
        defer msg.deinit(gpa);
        if (msg.opcode != .text) continue;
        const reply = mockReply(gpa, msg.data) catch return;
        defer gpa.free(reply);
        wss.writeMessage(socket.output, .text, reply) catch return;
        socket.output.flush() catch return;
    }
}

fn mockReply(gpa: std.mem.Allocator, request: []const u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), request, .{});
    const obj = switch (v) {
        .object => |o| o,
        else => return error.BadRequest,
    };
    const id = switch (obj.get("id") orelse return error.BadRequest) {
        .string => |s| s,
        else => return error.BadRequest,
    };
    return std.fmt.allocPrint(gpa, "{{\"id\":\"{s}\",\"result\":{{\"ok\":true}}}}", .{id});
}

/// Process daemon frames until `flag` becomes true, as the serve loop does. A bound stops a runaway.
fn pumpUntil(host: *Host, ch: *owner.Channel, gpa: std.mem.Allocator, flag: [:0]const u8) !void {
    var guard: u32 = 0;
    while ((try host.evalInt(flag)) == 0) {
        guard += 1;
        if (guard > 200) return error.PumpTimeout;
        var msg = try ch.receive();
        defer msg.deinit(gpa);
        switch (msg) {
            .daemon => |*d| try host.client.onDaemon(host, d),
            else => {},
        }
    }
}

test "a connect to a closed port rejects" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const alloc = gpa.allocator();

    var rt = try zio.Runtime.init(alloc, .{ .executors = .exact(1) });
    defer rt.deinit();
    const io = rt.io();

    // Bind a port, then close it, so the dial is refused.
    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try addr.listen(io, .{});
    const port = server.socket.address.getPort();
    server.deinit(io);

    const host = try Host.createWith(alloc, io, .{});
    defer host.destroy();
    var slot: [1]owner.Msg = undefined;
    var ch = owner.Channel.init(&slot);
    host.client.bind(&ch);

    const boot = try std.fmt.allocPrintSentinel(alloc,
        \\import * as client from "yuke:client";
        \\globalThis.failed = 0;
        \\client.connect({{ host: "127.0.0.1", port: {d} }}).then(
        \\  () => {{ globalThis.failed = 2; }},
        \\  (e) => {{ globalThis.failed = e.code === "connect_failed" ? 1 : 3; }},
        \\);
    , .{port}, 0);
    defer alloc.free(boot);
    try host.evalModule(boot, "boot.js");

    try pumpUntil(host, &ch, alloc, "globalThis.failed");
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.failed"));

    host.client.stopReaders();
    while (ch.tryReceive()) |m| {
        var mm = m;
        mm.deinit(alloc);
    } else |_| {}
}

test "connect and request round-trip over a mock daemon" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const alloc = gpa.allocator();

    var rt = try zio.Runtime.init(alloc, .{ .executors = .exact(1) });
    defer rt.deinit();
    const io = rt.io();

    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try addr.listen(io, .{});
    defer server.deinit(io);
    const port = server.socket.address.getPort();

    var mock_group: std.Io.Group = .init;
    defer mock_group.cancel(io);
    try mock_group.concurrent(io, mockServer, .{ io, &server, alloc });

    const host = try Host.createWith(alloc, io, .{});
    defer host.destroy();

    var slot: [1]owner.Msg = undefined;
    var ch = owner.Channel.init(&slot);
    host.client.bind(&ch);

    const boot = try std.fmt.allocPrintSentinel(alloc,
        \\import * as client from "yuke:client";
        \\globalThis.connected = 0;
        \\globalThis.listOk = 0;
        \\globalThis.stateReady = () => (client.connectionState("local") === "ready" ? 1 : 0);
        \\globalThis.sendList = () => client.sessionList("local").then((r) => {{ globalThis.listOk = r && r.ok ? 1 : 0; }});
        \\client.connect({{ host: "127.0.0.1", port: {d} }}).then(() => {{ globalThis.connected = 1; }});
    , .{port}, 0);
    defer alloc.free(boot);
    try host.evalModule(boot, "boot.js");

    try pumpUntil(host, &ch, alloc, "globalThis.connected");
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.stateReady()"));

    try host.eval("globalThis.sendList();", "req.js");
    try pumpUntil(host, &ch, alloc, "globalThis.listOk");

    host.client.stopReaders();
    while (ch.tryReceive()) |m| {
        var mm = m;
        mm.deinit(alloc);
    } else |_| {}
}
