//! The native `yuke:client-native` module: a per-daemon connection map with an async request path.
const std = @import("std");
const zio = @import("zio");
const quickjs = @import("quickjs");
const websocket = @import("websocket");
const wire = @import("wire");
const domain = @import("domain");
const host_mod = @import("../host.zig");
const Host = host_mod.Host;
const owner = @import("../owner.zig");

const Context = quickjs.Context;
const Value = quickjs.Value;
const Module = Context.Module;
const SessionId = wire.ids.SessionId;

/// The connection key of the single local daemon. A remote is "remote:" ++ device_id.
pub const local_key = "local";
const ws_path = "/ws";
const read_buf_bytes = 16 * 1024;
const write_buf_bytes = 16 * 1024;
/// Cap each inbound message so a hostile peer cannot exhaust memory.
const max_message_bytes = 8 * 1024 * 1024;
/// The daemon rejects an oversized subscription set, so cap it on the client.
const max_subscriptions = wire.meta.limits.max_subscriptions;
/// Retry a failed resync a few times before it waits for the next reconnect.
const max_resync_attempts = 3;
/// Bound the TCP dial. A finite handshake deadline waits for R4.
const connect_timeout: std.Io.Timeout = .{ .duration = .{ .clock = .awake, .raw = std.Io.Duration.fromMilliseconds(10_000) } };

pub const State = enum { disconnected, connecting, ready, closing };

/// The transport is the only part that differs local and remote. R1 builds `local`; `relay` waits.
pub const Transport = union(enum) { none, local, relay };

/// A pending JS promise: the two resolver functions held as GC roots until it settles.
/// A non-null `resync` marks a `session.resync` response that seeds the named replica.
const Pending = struct { resolve: Value, reject: Value, resync: ?ResyncTag = null };

/// Bind a resync response to the exact mount that requested it.
const ResyncTag = struct { sid: SessionId, gen: u64 };

/// The fold gate for one replica. A broadcast folds only in `synced`.
const SyncState = enum { needs_resync, resyncing, synced };

/// A replica holds the shared reducer, a monotonic revision, and the fold gate.
/// `resync_gen` names the in-flight resync, so a stale response never seeds the wrong cut.
const Replica = struct {
    session: domain.session.Session,
    rev: i32,
    sync: SyncState,
    resync_gen: u64,
    resync_attempts: u32,
    resync_pending: ?u64, // the request id of the in-flight resync, or null

    fn create(gpa: std.mem.Allocator, sid: SessionId) !*Replica {
        const self = try gpa.create(Replica);
        self.* = .{ .session = domain.session.Session.init(gpa, sid), .rev = 0, .sync = .needs_resync, .resync_gen = 0, .resync_attempts = 0, .resync_pending = null };
        return self;
    }

    fn destroy(self: *Replica, gpa: std.mem.Allocator) void {
        self.session.deinit();
        gpa.destroy(self);
    }

    /// Reset to a fresh projection under generation `gen`, so the next resync result installs cleanly.
    fn reset(self: *Replica, gen: u64) void {
        const gpa = self.session.gpa;
        const id = self.session.id;
        self.session.deinit();
        self.session = domain.session.Session.init(gpa, id);
        self.sync = .resyncing;
        self.resync_gen = gen;
    }
};

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
    replicas: std.AutoHashMapUnmanaged(SessionId, *Replica),
    resync_seq: u64,

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
            .replicas = .empty,
            .resync_seq = 0,
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
        var it = self.replicas.valueIterator();
        while (it.next()) |r| r.*.destroy(gpa);
        self.replicas.deinit(gpa);
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
        // Join every task before the free, so no task holds a freed connection pointer.
        self.stopReaders();
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

    /// Mount a fresh replica for `sid`. Return false when it is present already or the cap is full.
    fn mount(self: *Client, conn: *Connection, sid: SessionId) bool {
        if (conn.replicas.contains(sid)) return false;
        if (conn.replicas.count() >= max_subscriptions) return false;
        const replica = Replica.create(self.gpa, sid) catch return false;
        conn.replicas.put(self.gpa, sid, replica) catch {
            replica.destroy(self.gpa);
            return false;
        };
        return true;
    }

    /// Handle one daemon frame on the owner. It settles promises, folds broadcasts, and emits events.
    pub fn onDaemon(self: *Client, host: *Host, d: *owner.Daemon) host_mod.Error!void {
        const conn = self.conns.get(d.key) orelse return;
        const ctx = host.ctx;
        switch (d.body) {
            .connected => {
                conn.state = .ready;
                // A restore write can fail the connection, so resolve ready only when it holds.
                self.restoreReplicas(ctx, conn);
                if (conn.state == .ready) {
                    self.resolveConnect(ctx, conn);
                    self.emitConn(ctx, conn.key, "ready");
                } else {
                    self.rejectConnect(ctx, conn, "closed");
                }
            },
            .connect_failed => |code| {
                conn.state = .disconnected;
                self.rejectConnect(ctx, conn, code);
            },
            .message => |bytes| self.onMessage(ctx, conn, bytes),
            .ping => |payload| self.pong(conn, payload),
            .closed => {
                self.rejectAll(ctx, conn, "closed");
                self.staleReplicas(conn);
                conn.state = .disconnected;
                conn.teardownTransport();
                self.emitConn(ctx, conn.key, "close");
            },
        }
        try host.drainJobs();
    }

    /// A response carries an id; a broadcast carries a method and no id.
    fn onMessage(self: *Client, ctx: Context, conn: *Connection, bytes: []u8) void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const v = std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{}) catch return;
        const obj = switch (v) {
            .object => |o| o,
            else => return,
        };
        if (obj.get("id")) |id_val| {
            self.onResponse(ctx, conn, a, obj, id_val, bytes);
        } else if (obj.contains("method")) {
            if (!self.foldBroadcast(ctx, conn, a, v)) self.emitIndex(ctx, conn.key, bytes);
        }
    }

    /// Settle the pending promise for a response id, or seed a replica for a resync response.
    fn onResponse(self: *Client, ctx: Context, conn: *Connection, a: std.mem.Allocator, obj: std.json.ObjectMap, id_val: std.json.Value, bytes: []u8) void {
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
        if (p.resync) |tag| {
            self.finishResync(ctx, conn, a, obj, p, tag);
            return;
        }
        const text = ctx.newString(bytes);
        if (ctx.isException(text)) settleReject(ctx, p.reject) else settleResolve(ctx, p.resolve, text);
        ctx.freeValue(p.resolve);
        ctx.freeValue(p.reject);
    }

    /// Install a resync result into its replica, then settle the resync promise.
    fn finishResync(self: *Client, ctx: Context, conn: *Connection, a: std.mem.Allocator, obj: std.json.ObjectMap, p: Pending, tag: ResyncTag) void {
        defer {
            ctx.freeValue(p.resolve);
            ctx.freeValue(p.reject);
        }
        const replica = conn.replicas.get(tag.sid) orelse return settleResolveVoid(ctx, p.resolve);
        // A newer resync or a reopen replaced this request.
        if (replica.sync != .resyncing or replica.resync_gen != tag.gen) return settleResolveVoid(ctx, p.resolve);
        // The daemon lost the session. Unmount the replica and tell the shell.
        if (errorCode(obj)) |code| {
            if (code == @intFromEnum(wire.enums.ErrorCode.unknown_session)) {
                _ = conn.replicas.remove(tag.sid);
                replica.destroy(self.gpa);
                self.sendSubscriptions(conn);
                self.emitSession(ctx, conn.key, tag.sid, "gone", null);
                return rejectRoot(ctx, p.reject, "unknown_session");
            }
            return self.resyncFailed(ctx, conn, tag.sid, replica, p.reject);
        }
        const result = obj.get("result") orelse return self.resyncFailed(ctx, conn, tag.sid, replica, p.reject);
        const rr = wire.rpc.resultFromValue(a, .@"session.resync", result, .{}) catch
            return self.resyncFailed(ctx, conn, tag.sid, replica, p.reject);
        const sr = switch (rr) {
            .session_resync_result => |x| x,
            else => return self.resyncFailed(ctx, conn, tag.sid, replica, p.reject),
        };
        replica.session.installResync(sr) catch
            return self.resyncFailed(ctx, conn, tag.sid, replica, p.reject);
        replica.sync = .synced;
        replica.resync_attempts = 0;
        replica.rev +|= 1;
        self.emitSession(ctx, conn.key, tag.sid, "reload", null);
        settleResolveVoid(ctx, p.resolve);
    }

    /// A resync failed. Retry a few times on a live connection, else wait for the next reconnect.
    fn resyncFailed(self: *Client, ctx: Context, conn: *Connection, sid: SessionId, replica: *Replica, reject: Value) void {
        replica.sync = .needs_resync;
        rejectRoot(ctx, reject, "resync_failed");
        if (conn.state == .ready and replica.resync_attempts < max_resync_attempts) {
            replica.resync_attempts += 1;
            self.startResync(ctx, conn, sid, replica, quickjs.UNDEFINED, quickjs.UNDEFINED);
        }
    }

    /// Fold one broadcast into its replica. R4 emits an index broadcast to JavaScript.
    /// Return true when the broadcast folds into a replica. Return false for an index event to forward.
    fn foldBroadcast(self: *Client, ctx: Context, conn: *Connection, a: std.mem.Allocator, v: std.json.Value) bool {
        const notif = wire.rpc.Notification.jsonParseFromValue(a, v, .{}) catch return true; // drop a malformed frame
        const sid = domain.session.replicaSession(notif.params) orelse return false; // an index event
        const replica = conn.replicas.get(sid) orelse return true;
        // The gate stays closed until a resync installs the cut.
        if (replica.sync != .synced) return true;
        const applied = replica.session.applyBroadcast(notif.params) catch {
            self.startResync(ctx, conn, sid, replica, quickjs.UNDEFINED, quickjs.UNDEFINED);
            return true;
        };
        switch (applied) {
            .changed => {
                replica.rev +|= 1;
                self.emitSessionChange(ctx, conn.key, sid, notif.method, replica);
            },
            .ignored => {},
            .gap => self.startResync(ctx, conn, sid, replica, quickjs.UNDEFINED, quickjs.UNDEFINED),
        }
        return true;
    }

    /// Forward an index or workspace broadcast to JavaScript. The shell folds it into the sidebar.
    fn emitIndex(self: *Client, ctx: Context, key: []const u8, bytes: []u8) void {
        if (ctx.isUndefined(self.event_sink)) return;
        const ev = ctx.parseJSON(bytes, "index");
        if (ctx.isException(ev)) {
            ctx.freeValue(ctx.getException());
            return;
        }
        ctx.setPropertyStr(ev, "type", ctx.newString("index")) catch {};
        ctx.setPropertyStr(ev, "connKey", ctx.newString(key)) catch {};
        self.emitEvent(ctx, ev);
    }

    /// Call the JS sink with `ev`, then clear any exception a handler threw and free `ev`.
    fn emitEvent(self: *Client, ctx: Context, ev: Value) void {
        ctx.freeValue(ctx.call(self.event_sink, quickjs.UNDEFINED, &.{ev}));
        ctx.freeValue(ctx.getException());
        ctx.freeValue(ev);
    }

    /// After a reconnect, resend the subscriptions and resync every stale replica.
    fn restoreReplicas(self: *Client, ctx: Context, conn: *Connection) void {
        if (conn.replicas.count() == 0) return;
        self.sendSubscriptions(conn);
        var it = conn.replicas.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.*.sync == .needs_resync) {
                e.value_ptr.*.resync_attempts = 0; // a reconnect earns a fresh retry budget
                self.startResync(ctx, conn, e.key_ptr.*, e.value_ptr.*, quickjs.UNDEFINED, quickjs.UNDEFINED);
            }
        }
    }

    /// Reset the replica and send `session.resync`. `resolve`/`reject` are undefined for an auto-resync.
    fn startResync(self: *Client, ctx: Context, conn: *Connection, sid: SessionId, replica: *Replica, resolve: Value, reject: Value) void {
        // Supersede an in-flight resync for this replica, so its roots do not linger.
        if (replica.resync_pending) |old| {
            if (conn.pending.fetchRemove(old)) |e| {
                settleResolveVoid(ctx, e.value.resolve);
                ctx.freeValue(e.value.resolve);
                ctx.freeValue(e.value.reject);
            }
            replica.resync_pending = null;
        }
        conn.resync_seq += 1;
        const gen = conn.resync_seq;
        replica.reset(gen);
        const id = conn.next_id;
        const hex = std.fmt.bytesToHex(sid.raw, .lower);
        var pbuf: [64]u8 = undefined;
        const params = std.fmt.bufPrint(&pbuf, "{{\"session_id\":\"{s}\"}}", .{hex[0..]}) catch unreachable;
        conn.pending.put(self.gpa, id, .{ .resolve = resolve, .reject = reject, .resync = .{ .sid = sid, .gen = gen } }) catch {
            replica.sync = .needs_resync;
            rejectRoot(ctx, reject, "oom");
            ctx.freeValue(resolve);
            ctx.freeValue(reject);
            return;
        };
        conn.next_id += 1;
        replica.resync_pending = id;
        sendFrame(conn, self.gpa, id, "session.resync", params) catch {
            replica.sync = .needs_resync;
            replica.resync_pending = null;
            if (conn.pending.fetchRemove(id)) |e| {
                rejectRoot(ctx, e.value.reject, "write_failed");
                ctx.freeValue(e.value.resolve);
                ctx.freeValue(e.value.reject);
            }
            failConnection(self, conn);
        };
    }

    /// Send `subscription.set` with the union of the mounted session ids. Fire and forget.
    fn sendSubscriptions(self: *Client, conn: *Connection) void {
        if (conn.state != .ready) return;
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.gpa);
        buf.appendSlice(self.gpa, "{\"sessions\":[") catch return;
        var i: usize = 0;
        var it = conn.replicas.keyIterator();
        while (it.next()) |sid| : (i += 1) {
            if (i == max_subscriptions) break;
            if (i > 0) buf.append(self.gpa, ',') catch return;
            const hex = std.fmt.bytesToHex(sid.raw, .lower);
            buf.append(self.gpa, '"') catch return;
            buf.appendSlice(self.gpa, hex[0..]) catch return;
            buf.append(self.gpa, '"') catch return;
        }
        buf.appendSlice(self.gpa, "]}") catch return;
        const id = conn.next_id;
        conn.next_id += 1;
        sendFrame(conn, self.gpa, id, "subscription.set", buf.items) catch failConnection(self, conn);
    }

    /// Reply to a server ping. The owner writes it, so socket writes stay serialized on one side.
    /// A failed write leaves a partial frame, so it fails the connection.
    fn pong(self: *Client, conn: *Connection, payload: []const u8) void {
        if (!conn.has_transport) return;
        var mask: [4]u8 = undefined;
        zio.random(&mask);
        websocket.writeFrame(&conn.writer.interface, true, .pong, payload, @bitCast(mask)) catch return failConnection(self, conn);
        conn.writer.interface.flush() catch failConnection(self, conn);
    }

    /// Mark every replica for a resync after the transport drops.
    fn staleReplicas(_: *Client, conn: *Connection) void {
        var it = conn.replicas.valueIterator();
        while (it.next()) |r| r.*.sync = .needs_resync;
    }

    fn resolveConnect(_: *Client, ctx: Context, conn: *Connection) void {
        const p = conn.connect_pending orelse return;
        conn.connect_pending = null;
        settleResolveVoid(ctx, p.resolve);
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
        self.emitEvent(ctx, ev);
    }

    /// A structure change reloads the transcript. A draft delta refreshes the active message.
    fn emitSessionChange(self: *Client, ctx: Context, key: []const u8, sid: SessionId, method: wire.enums.BroadcastName, replica: *Replica) void {
        const streaming = switch (method) {
            .@"message.started", .@"message.part_added", .@"message.part_delta", .@"message.part_finalized", .@"tool.output_delta", .@"tool.state_changed" => true,
            else => false,
        };
        if (streaming) if (replica.session.active) |draft| return self.emitSession(ctx, key, sid, "active", draft.message_id);
        self.emitSession(ctx, key, sid, "reload", null);
    }

    fn emitSession(self: *Client, ctx: Context, key: []const u8, sid: SessionId, kind: []const u8, id: ?u64) void {
        if (ctx.isUndefined(self.event_sink)) return;
        const ev = ctx.newObject();
        if (ctx.isException(ev)) return;
        const hex = std.fmt.bytesToHex(sid.raw, .lower);
        ctx.setPropertyStr(ev, "type", ctx.newString("session")) catch {};
        ctx.setPropertyStr(ev, "connKey", ctx.newString(key)) catch {};
        ctx.setPropertyStr(ev, "sessionId", ctx.newString(hex[0..])) catch {};
        ctx.setPropertyStr(ev, "kind", ctx.newString(kind)) catch {};
        if (id) |mid| ctx.setPropertyStr(ev, "id", ctx.newFloat64(@floatFromInt(mid))) catch {};
        self.emitEvent(ctx, ev);
    }
};

/// Call `resolve(value)` unless it is undefined. Always free `value`.
fn settleResolve(ctx: Context, resolve: Value, value: Value) void {
    if (ctx.isUndefined(resolve)) return ctx.freeValue(value);
    ctx.freeValue(ctx.call(resolve, quickjs.UNDEFINED, &.{value}));
    ctx.freeValue(value);
}

/// Call `resolve()` unless it is undefined.
fn settleResolveVoid(ctx: Context, resolve: Value) void {
    if (ctx.isUndefined(resolve)) return;
    ctx.freeValue(ctx.call(resolve, quickjs.UNDEFINED, &.{}));
}

/// Call `reject(undefined)` unless it is undefined.
fn settleReject(ctx: Context, reject: Value) void {
    if (ctx.isUndefined(reject)) return;
    ctx.freeValue(ctx.call(reject, quickjs.UNDEFINED, &.{}));
}

/// Reject a promise with a string code. Fall back to an undefined reason under memory pressure.
fn rejectRoot(ctx: Context, reject: Value, code: []const u8) void {
    if (ctx.isUndefined(reject)) return;
    const e = ctx.newString(code);
    if (ctx.isException(e)) {
        ctx.freeValue(ctx.call(reject, quickjs.UNDEFINED, &.{}));
        return;
    }
    ctx.freeValue(ctx.call(reject, quickjs.UNDEFINED, &.{e}));
    ctx.freeValue(e);
}

/// Return the numeric `error.code` of a response, or null for a missing or invalid code.
/// The wire serializes `ErrorCode` as its integer value (`unknown_session` = -31000).
fn errorCode(obj: std.json.ObjectMap) ?i64 {
    const err = obj.get("error") orelse return null;
    const eobj = switch (err) {
        .object => |o| o,
        else => return null,
    };
    const code = eobj.get("code") orelse return null;
    return switch (code) {
        .integer => |n| n,
        else => null,
    };
}

/// Build a JSON-RPC envelope and write it as a masked text frame.
fn sendFrame(conn: *Connection, gpa: std.mem.Allocator, id: u64, method: []const u8, params: []const u8) !void {
    const envelope = try std.fmt.allocPrint(gpa, "{{\"id\":\"{d}\",\"method\":\"{s}\",\"params\":{s}}}", .{ id, method, params });
    defer gpa.free(envelope);
    try writeRequest(conn, envelope);
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
            // The owner writes the pong, so writes stay serialized on one side.
            .ping => {
                if (!deliverBody(conn, .{ .ping = msg.data })) {
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
            else => gpa.free(msg.data), // a pong needs no reply
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

/// Hand an owned body to the owner. Return false when the owner is gone, so the caller frees it.
fn deliverBody(conn: *Connection, body: owner.Daemon.Body) bool {
    const ch = conn.client.owner_ch orelse return false;
    ch.send(.{ .daemon = .{ .key = conn.key, .body = body } }) catch return false;
    return true;
}

fn deliverMessage(conn: *Connection, data: []u8) bool {
    return deliverBody(conn, .{ .message = data });
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
    // A dial cannot cancel per connection yet, so a disconnect while connecting is a no-op.
    if (conn.state == .connecting) return quickjs.UNDEFINED;
    // A user disconnect abandons the open sessions and the in-flight requests.
    var it = conn.replicas.valueIterator();
    while (it.next()) |r| r.*.destroy(client.gpa);
    conn.replicas.clearRetainingCapacity();
    client.rejectAll(ctx, conn, "closed");
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
    sendFrame(conn, client.gpa, id, method, params) catch {
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

fn jsSessionOpen(ctx: Context, _: Value, args: []const Value) Value {
    const client = Host.fromContext(ctx).client;
    const key = keyArg(ctx, args) orelse return quickjs.UNDEFINED;
    defer ctx.freeCString(key.ptr);
    const sid = sidArg(ctx, args, 1) orelse return quickjs.UNDEFINED;
    const conn = client.conns.get(key) orelse return quickjs.UNDEFINED;
    if (client.mount(conn, sid)) client.sendSubscriptions(conn);
    return quickjs.UNDEFINED;
}

fn jsSessionClose(ctx: Context, _: Value, args: []const Value) Value {
    const client = Host.fromContext(ctx).client;
    const key = keyArg(ctx, args) orelse return quickjs.UNDEFINED;
    defer ctx.freeCString(key.ptr);
    const sid = sidArg(ctx, args, 1) orelse return quickjs.UNDEFINED;
    const conn = client.conns.get(key) orelse return quickjs.UNDEFINED;
    if (conn.replicas.fetchRemove(sid)) |kv| {
        kv.value.destroy(client.gpa);
        client.sendSubscriptions(conn);
    }
    return quickjs.UNDEFINED;
}

fn jsSessionRev(ctx: Context, _: Value, args: []const Value) Value {
    const client = Host.fromContext(ctx).client;
    const key = keyArg(ctx, args) orelse return ctx.newInt32(-1);
    defer ctx.freeCString(key.ptr);
    const sid = sidArg(ctx, args, 1) orelse return ctx.newInt32(-1);
    const conn = client.conns.get(key) orelse return ctx.newInt32(-1);
    const replica = conn.replicas.get(sid) orelse return ctx.newInt32(-1);
    return ctx.newInt32(replica.rev);
}

fn jsSessionResync(ctx: Context, _: Value, args: []const Value) Value {
    const client = Host.fromContext(ctx).client;
    const key = keyArg(ctx, args) orelse return rejectedPromise(ctx, "bad_request");
    defer ctx.freeCString(key.ptr);
    const sid = sidArg(ctx, args, 1) orelse return rejectedPromise(ctx, "bad_request");
    const conn = client.conns.get(key) orelse return rejectedPromise(ctx, "not_connected");
    if (conn.state != .ready) return rejectedPromise(ctx, "not_connected");
    const replica = conn.replicas.get(sid) orelse return rejectedPromise(ctx, "not_open");

    var funcs: [2]Value = undefined;
    const promise = ctx.newPromiseCapability(&funcs);
    if (ctx.isException(promise)) return promise;
    replica.resync_attempts = 0; // a shell request earns a fresh retry budget
    client.startResync(ctx, conn, sid, replica, funcs[0], funcs[1]);
    return promise;
}

fn jsSessionOutline(ctx: Context, _: Value, args: []const Value) Value {
    const client = Host.fromContext(ctx).client;
    const replica = replicaArg(ctx, client, args) orelse return ctx.newString("null");
    var aw: std.Io.Writer.Allocating = .init(client.gpa);
    defer aw.deinit();
    writeOutline(&aw.writer, &replica.session) catch return ctx.newString("null");
    return ctx.newString(aw.written());
}

fn jsSessionText(ctx: Context, _: Value, args: []const Value) Value {
    const client = Host.fromContext(ctx).client;
    const replica = replicaArg(ctx, client, args) orelse return ctx.newString("");
    if (args.len < 3) return ctx.newString("");
    const mid: u64 = std.math.lossyCast(u64, ctx.toFloat64(args[2]) catch return ctx.newString(""));
    var aw: std.Io.Writer.Allocating = .init(client.gpa);
    defer aw.deinit();
    writeMessageText(&aw.writer, &replica.session, mid) catch return ctx.newString("");
    return ctx.newString(aw.written());
}

/// Convert the first argument to an owned C string, or null when absent. The caller frees it.
fn keyArg(ctx: Context, args: []const Value) ?[:0]const u8 {
    if (args.len < 1) return null;
    return ctx.toCStringLen(args[0]) catch null;
}

/// Decode a hex session id from argument `idx`.
fn sidArg(ctx: Context, args: []const Value, idx: usize) ?SessionId {
    if (args.len <= idx) return null;
    const text = ctx.toCStringLen(args[idx]) catch return null;
    defer ctx.freeCString(text.ptr);
    if (text.len != SessionId.byte_len * 2) return null;
    var raw: [SessionId.byte_len]u8 = undefined;
    _ = std.fmt.hexToBytes(&raw, text) catch return null;
    return SessionId.bytes(raw);
}

/// Resolve (connKey, sessionId) from arguments 0 and 1 to a mounted replica, or null.
fn replicaArg(ctx: Context, client: *Client, args: []const Value) ?*Replica {
    const key = keyArg(ctx, args) orelse return null;
    defer ctx.freeCString(key.ptr);
    const sid = sidArg(ctx, args, 1) orelse return null;
    const conn = client.conns.get(key) orelse return null;
    return conn.replicas.get(sid);
}

/// Serialize the message-id/role list, a failed message's error, and the draft descriptor.
fn writeOutline(w: *std.Io.Writer, s: *domain.session.Session) !void {
    try w.writeAll("{\"messages\":[");
    for (s.committed.list.items, 0..) |entry, i| {
        if (i > 0) try w.writeByte(',');
        const role = switch (entry.message) {
            .user => "user",
            else => "assistant",
        };
        try w.print("{{\"id\":{d},\"type\":\"{s}\"", .{ entry.message.id(), role });
        if (messageError(entry.message)) |e| {
            try w.writeAll(",\"error\":{\"type\":");
            try std.json.Stringify.encodeJsonString(e.type, .{}, w);
            try w.writeAll(",\"message\":");
            try std.json.Stringify.encodeJsonString(e.message, .{}, w);
            try w.writeByte('}');
        }
        try w.writeByte('}');
    }
    try w.writeAll("],\"active\":");
    if (s.active) |d| try w.print("{{\"id\":{d},\"type\":\"assistant\"}}", .{d.message_id}) else try w.writeAll("null");
    try w.writeByte('}');
}

/// Return the error from a failed assistant message, or null. The daemon sets it with `finish: "error"`.
fn messageError(m: wire.message.Message) ?wire.message.MessageError {
    return switch (m) {
        .assistant => |a| a.@"error",
        else => null,
    };
}

/// Write the concatenated visible text of one message, from the draft or the committed window.
fn writeMessageText(w: *std.Io.Writer, s: *domain.session.Session, mid: u64) !void {
    if (s.active) |d| if (d.message_id == mid) return appendDraftText(w, d);
    for (s.committed.list.items) |entry| {
        if (entry.message.id() == mid) return appendMessageText(w, entry.message);
    }
}

fn appendMessageText(w: *std.Io.Writer, m: wire.message.Message) !void {
    switch (m) {
        .user => |u| for (u.content) |c| switch (c) {
            .text => |t| try w.writeAll(t.text),
            else => {},
        },
        .assistant => |a| for (a.content) |p| switch (p) {
            .text => |t| try w.writeAll(t.text),
            else => {},
        },
        .compaction => |c| try w.writeAll(c.summary),
    }
}

fn appendDraftText(w: *std.Io.Writer, d: domain.draft.Draft) !void {
    for (d.parts.items) |p| switch (p) {
        .text => |t| try w.writeAll(t.text.items),
        else => {},
    };
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

test "mount is idempotent and caps the subscription set" {
    const client = try Client.create(std.testing.allocator, std.testing.io);
    defer client.destroy();
    const conn = try client.ensure("local");
    var i: u32 = 0;
    while (i < max_subscriptions) : (i += 1) {
        var raw: [16]u8 = @splat(0);
        std.mem.writeInt(u32, raw[0..4], i, .little);
        try std.testing.expect(client.mount(conn, SessionId.bytes(raw)));
    }
    // A repeated open has no effect, and a new id past the cap is rejected.
    try std.testing.expect(!client.mount(conn, SessionId.bytes(@splat(0))));
    var over: [16]u8 = @splat(0);
    std.mem.writeInt(u32, over[0..4], 9999, .little);
    try std.testing.expect(!client.mount(conn, SessionId.bytes(over)));
    try std.testing.expectEqual(@as(u32, @intCast(max_subscriptions)), conn.replicas.count());
}

test "the outline carries a failed message error" {
    const gpa = std.testing.allocator;
    var sess = domain.session.Session.init(gpa, SessionId.bytes([_]u8{0} ** 16));
    defer sess.deinit();
    const messages = [_]wire.message.Message{.{ .assistant = .{
        .id = 2,
        .run_id = 1,
        .config_rev = 0,
        .agent = "claude",
        .content = &.{},
        .time = .{ .created_at_ms = 1 },
        .finish = .@"error",
        .@"error" = .{ .type = "rate_limited", .message = "429 \"too many\"" },
    } }};
    try sess.installSnapshot(.{ .base_seq = 1, .finalized_message_id = 2, .messages = &messages, .configs = &.{}, .has_more = false });

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try writeOutline(&aw.writer, &sess);
    try std.testing.expectEqualStrings(
        "{\"messages\":[{\"id\":2,\"type\":\"assistant\",\"error\":{\"type\":\"rate_limited\",\"message\":\"429 \\\"too many\\\"\"}}],\"active\":null}",
        aw.written(),
    );
}

test "the outline and text project a streaming draft" {
    const gpa = std.testing.allocator;
    const sid = SessionId.bytes([_]u8{0} ** 16);
    var sess = domain.session.Session.init(gpa, sid);
    defer sess.deinit();
    // Fold a streaming assistant turn: start the message, add a text part, then stream two deltas.
    _ = try sess.applyBroadcast(.{ .message_started_data = .{ .session_id = sid, .message_id = 1, .run_id = 1, .config_rev = 0, .agent = "claude", .created_at_ms = 1 } });
    _ = try sess.applyBroadcast(.{ .message_part_added_data = .{ .session_id = sid, .message_id = 1, .part = .{ .text = .{ .id = 0, .text = "" } } } });
    _ = try sess.applyBroadcast(.{ .message_part_delta_data = .{ .session_id = sid, .message_id = 1, .part_id = 0, .delta = "hi ", .offset = 0 } });
    _ = try sess.applyBroadcast(.{ .message_part_delta_data = .{ .session_id = sid, .message_id = 1, .part_id = 0, .delta = "there", .offset = 3 } });

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try writeOutline(&aw.writer, &sess);
    try std.testing.expectEqualStrings("{\"messages\":[],\"active\":{\"id\":1,\"type\":\"assistant\"}}", aw.written());

    var tw: std.Io.Writer.Allocating = .init(gpa);
    defer tw.deinit();
    try writeMessageText(&tw.writer, &sess, 1);
    try std.testing.expectEqualStrings("hi there", tw.written());
}

test "outline and text serialize a folded transcript" {
    const gpa = std.testing.allocator;
    var sess = domain.session.Session.init(gpa, SessionId.bytes([_]u8{0} ** 16));
    defer sess.deinit();
    const messages = [_]wire.message.Message{
        .{ .user = .{ .id = 1, .content = &.{.{ .text = .{ .text = "hi" } }}, .input_id = 1, .time = .{ .created_at_ms = 1 } } },
        .{ .assistant = .{ .id = 2, .run_id = 1, .config_rev = 0, .agent = "claude", .content = &.{.{ .text = .{ .id = 1, .text = "hello" } }}, .time = .{ .created_at_ms = 1 } } },
    };
    try sess.installSnapshot(.{ .base_seq = 5, .finalized_message_id = 2, .messages = &messages, .configs = &.{}, .has_more = false });

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try writeOutline(&aw.writer, &sess);
    try std.testing.expectEqualStrings(
        "{\"messages\":[{\"id\":1,\"type\":\"user\"},{\"id\":2,\"type\":\"assistant\"}],\"active\":null}",
        aw.written(),
    );

    var tw: std.Io.Writer.Allocating = .init(gpa);
    defer tw.deinit();
    try writeMessageText(&tw.writer, &sess, 2);
    try std.testing.expectEqualStrings("hello", tw.written());
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
