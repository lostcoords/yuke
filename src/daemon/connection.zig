//! One WebSocket connection's outbound path and the daemon's connection registry. A writer coroutine
//! owns socket.output and drains a bounded outbox. A reader coroutine enqueues pre-framed WS bytes.
//! The registry routes a session broadcast to every subscribed connection.

const std = @import("std");
const zio = @import("zio");
const ids = @import("wire").ids;

/// One queued outbound WS frame. `bytes` is gpa-owned; the writer frees it after the write.
/// `terminal` marks a close frame, after which the writer stops.
pub const OutboxItem = struct {
    bytes: []u8,
    terminal: bool = false,
};

/// The outbox capacity bounds how far the writer falls behind before the reader blocks.
const outbox_capacity = 256;

pub const Connection = struct {
    gpa: std.mem.Allocator,
    id: u64 = 0, // The registry assigns a nonzero id. 0 means unregistered.
    buffer: [outbox_capacity]OutboxItem = undefined,
    outbox: zio.Channel(OutboxItem) = undefined,
    subscribed: std.AutoHashMapUnmanaged(ids.SessionId, void) = .empty, // sessions this connection follows

    /// Initialize in place. The channel borrows `buffer`, so the Connection address must stay stable.
    pub fn init(self: *Connection, gpa: std.mem.Allocator) void {
        self.* = .{ .gpa = gpa };
        self.outbox = zio.Channel(OutboxItem).init(self.buffer[0..]);
    }

    /// Hand owned frame bytes to the writer. Free them when the outbox no longer accepts them.
    pub fn send(self: *Connection, item: OutboxItem) !void {
        self.outbox.send(item) catch |err| {
            self.gpa.free(item.bytes);
            return err;
        };
    }

    /// Try to enqueue owned bytes without blocking. Return false and free the bytes when the outbox is full.
    pub fn tryEnqueue(self: *Connection, item: OutboxItem) bool {
        self.outbox.trySend(item) catch {
            self.gpa.free(item.bytes);
            return false;
        };
        return true;
    }

    /// Drain and free every unsent frame, then close the outbox. Call after the writer joins.
    pub fn deinit(self: *Connection) void {
        while (self.outbox.tryReceive()) |item| {
            self.gpa.free(item.bytes);
        } else |_| {}
        self.outbox.close(.graceful);
        self.subscribed.deinit(self.gpa);
    }
};

/// The daemon-global connection registry. It tracks live connections and a reverse subscription index.
/// A monotonic connection id is never reused, so a stale id fails lookup and publish skips it safely.
pub const Registry = struct {
    gpa: std.mem.Allocator,
    next_id: u64 = 1,
    connections: std.AutoHashMapUnmanaged(u64, *Connection) = .empty,
    subscribers: std.AutoHashMapUnmanaged(ids.SessionId, std.ArrayListUnmanaged(u64)) = .empty,

    pub fn init(gpa: std.mem.Allocator) Registry {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Registry) void {
        var it = self.subscribers.valueIterator();
        while (it.next()) |list| list.deinit(self.gpa);
        self.subscribers.deinit(self.gpa);
        self.connections.deinit(self.gpa);
        self.* = undefined;
    }

    /// Assign a monotonic id and track the connection.
    pub fn register(self: *Registry, conn: *Connection) !void {
        try self.connections.put(self.gpa, self.next_id, conn);
        conn.id = self.next_id;
        self.next_id += 1;
    }

    /// Drop the connection from every session it followed, then forget it.
    pub fn unregister(self: *Registry, conn: *Connection) void {
        if (conn.id == 0) return;
        var it = conn.subscribed.keyIterator();
        while (it.next()) |sid| self.removeSubscriber(sid.*, conn.id);
        _ = self.connections.remove(conn.id);
        conn.id = 0;
    }

    /// Replace the connection's subscription set with `sessions`.
    pub fn setSubscriptions(self: *Registry, conn: *Connection, sessions: []const ids.SessionId) !void {
        var it = conn.subscribed.keyIterator();
        while (it.next()) |sid| self.removeSubscriber(sid.*, conn.id);
        conn.subscribed.clearRetainingCapacity();

        for (sessions) |sid| {
            const gop = try conn.subscribed.getOrPut(self.gpa, sid);
            if (gop.found_existing) continue; // ignore a duplicate in the request
            const list = try self.subscribers.getOrPut(self.gpa, sid);
            if (!list.found_existing) list.value_ptr.* = .empty;
            try list.value_ptr.append(self.gpa, conn.id);
        }
    }

    /// Fan out framed bytes to every subscriber of a session. Copy the bytes per connection.
    /// The caller owns `bytes`. A must-deliver overflow drops the frame; a later change adds the shed and close rules.
    pub fn publish(self: *Registry, session_id: ids.SessionId, bytes: []const u8) void {
        const list = self.subscribers.getPtr(session_id) orelse return;
        for (list.items) |cid| {
            const conn = self.connections.get(cid) orelse continue;
            const copy = self.gpa.dupe(u8, bytes) catch continue;
            _ = conn.tryEnqueue(.{ .bytes = copy });
        }
    }

    fn removeSubscriber(self: *Registry, session_id: ids.SessionId, conn_id: u64) void {
        const list = self.subscribers.getPtr(session_id) orelse return;
        for (list.items, 0..) |cid, i| {
            if (cid == conn_id) {
                _ = list.swapRemove(i);
                break;
            }
        }
        if (list.items.len == 0) {
            list.deinit(self.gpa);
            _ = self.subscribers.remove(session_id);
        }
    }
};

const testing = std.testing;

test "registry routes a broadcast only to subscribers" {
    var registry = Registry.init(testing.allocator);
    defer registry.deinit();

    var a: Connection = undefined;
    a.init(testing.allocator);
    defer a.deinit();
    var b: Connection = undefined;
    b.init(testing.allocator);
    defer b.deinit();
    try registry.register(&a);
    try registry.register(&b);
    try testing.expect(a.id != 0 and b.id != 0 and a.id != b.id);

    const sid: ids.SessionId = .bytes([_]u8{7} ** 16);
    try registry.setSubscriptions(&a, &.{sid});

    registry.publish(sid, "hello");
    // Only a follows the session, so only a's outbox holds the frame.
    const item_a = try a.outbox.tryReceive();
    defer testing.allocator.free(item_a.bytes);
    try testing.expectEqualStrings("hello", item_a.bytes);
    try testing.expectError(error.ChannelEmpty, b.outbox.tryReceive());

    // Unregister removes a from the index, so a later publish reaches nobody.
    registry.unregister(&a);
    registry.publish(sid, "again");
    try testing.expectError(error.ChannelEmpty, a.outbox.tryReceive());
}

test "setSubscriptions replaces the previous set" {
    var registry = Registry.init(testing.allocator);
    defer registry.deinit();

    var c: Connection = undefined;
    c.init(testing.allocator);
    defer c.deinit();
    try registry.register(&c);

    const one: ids.SessionId = .bytes([_]u8{1} ** 16);
    const two: ids.SessionId = .bytes([_]u8{2} ** 16);
    try registry.setSubscriptions(&c, &.{ one, one, two }); // a duplicate collapses
    try registry.setSubscriptions(&c, &.{two}); // now only two remains

    registry.publish(one, "x");
    try testing.expectError(error.ChannelEmpty, c.outbox.tryReceive());
    registry.publish(two, "y");
    const item = try c.outbox.tryReceive();
    defer testing.allocator.free(item.bytes);
    try testing.expectEqualStrings("y", item.bytes);
}
