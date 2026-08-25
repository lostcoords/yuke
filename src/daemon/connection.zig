//! One WebSocket connection's outbound path and the daemon's connection registry. A writer coroutine
//! owns socket.output and drains a bounded outbox. A reader coroutine enqueues pre-framed WS bytes.
//! The registry routes a session broadcast to every subscribed connection.

const std = @import("std");
const zio = @import("zio");
const wire = @import("wire");
const wss = @import("websocket").server;
const ids = wire.ids;

/// One queued outbound WS frame. `bytes` is gpa-owned; the writer frees it after the write.
/// `terminal` marks a close frame, after which the writer stops.
pub const OutboxItem = struct {
    bytes: []u8,
    terminal: bool = false,
};

/// The outbox capacity bounds how far the writer falls behind before the reader blocks.
const outbox_capacity = 256;

/// A broadcast delivery guarantee. A live delta may drop under backpressure; every other event must arrive.
pub const DeliveryClass = enum { must_deliver, shed_able };

/// Classify a broadcast. Only a live delta is shed-able; the committed snapshot restores the dropped bytes.
pub fn classOf(method: wire.enums.BroadcastName) DeliveryClass {
    return switch (method) {
        .@"message.part_delta", .@"tool.output_delta" => .shed_able,
        else => .must_deliver,
    };
}

/// Per-session shed accounting on one connection. A resync marker follows once the client catches up.
const ShedState = struct {
    count: u64 = 0, // The total number of dropped deltas.
    notified: u64 = 0, // The count reported by the last delivered marker.
};

pub const Connection = struct {
    gpa: std.mem.Allocator,
    id: u64 = 0, // The registry assigns a nonzero id. 0 means unregistered.
    closing: bool = false, // A must-deliver overflow forced a close; publish skips this connection.
    teardown_context: ?*anyopaque = null,
    teardown_callback: ?*const fn (*anyopaque) void = null,
    buffer: [outbox_capacity]OutboxItem = undefined,
    outbox: zio.Channel(OutboxItem) = undefined,
    subscribed: std.AutoHashMapUnmanaged(ids.SessionId, void) = .empty, // sessions this connection follows
    shed: std.AutoHashMapUnmanaged(ids.SessionId, ShedState) = .empty, // sessions with dropped deltas

    /// Initialize in place. The channel borrows `buffer`, so the Connection address must stay stable.
    pub fn init(self: *Connection, gpa: std.mem.Allocator) void {
        self.* = .{ .gpa = gpa };
        self.outbox = zio.Channel(OutboxItem).init(self.buffer[0..]);
    }

    /// Register the non-blocking callback that wakes the WebSocket supervisor.
    pub fn setTeardown(self: *Connection, context: *anyopaque, callback: *const fn (*anyopaque) void) void {
        self.teardown_context = context;
        self.teardown_callback = callback;
    }

    /// Clear the registry callback before the connection leaves the registry.
    pub fn clearTeardown(self: *Connection) void {
        self.teardown_context = null;
        self.teardown_callback = null;
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
        self.clearTeardown();
        self.subscribed.deinit(self.gpa);
        self.shed.deinit(self.gpa);
    }

    /// Record one dropped delta for a session. Return false when the shed cannot be tracked.
    fn recordShed(self: *Connection, session_id: ids.SessionId) bool {
        const gop = self.shed.getOrPut(self.gpa, session_id) catch return false;
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.count += 1;
        return true;
    }

    /// Write a resync marker for each session with new dropped deltas. The writer calls this once it catches up.
    /// The marker frames use `w`, which must not yield, so the shed map stays stable during the write.
    pub fn drainShedMarkers(self: *Connection, w: *std.Io.Writer) !void {
        var it = self.shed.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.count == e.value_ptr.notified) continue;
            const marker = try frameShedMarker(self.gpa, e.key_ptr.*, e.value_ptr.count);
            defer self.gpa.free(marker);
            try w.writeAll(marker);
            e.value_ptr.notified = e.value_ptr.count;
        }
    }
};

/// The daemon-global connection registry. It tracks live connections and a reverse subscription index.
/// A monotonic connection id is never reused, so a stale id fails lookup and publish skips it safely.
pub const Registry = struct {
    gpa: std.mem.Allocator,
    next_id: u64 = 1,
    connections: std.AutoHashMapUnmanaged(u64, *Connection) = .empty,
    subscribers: std.AutoHashMapUnmanaged(ids.SessionId, std.ArrayList(u64)) = .empty,

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
        std.debug.assert(conn.id == 0); // A fresh connection is unregistered.
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
        conn.clearTeardown();
        conn.id = 0;
    }

    /// Replace the connection's subscription set with `sessions`. Reject an oversized set. Reserve
    /// every allocation first, so the swap cannot fail. Any failure leaves the old state unchanged.
    pub fn setSubscriptions(self: *Registry, conn: *Connection, sessions: []const ids.SessionId) !void {
        if (sessions.len > wire.meta.limits.max_subscriptions) return error.TooManySubscriptions;

        // Build the deduplicated new set on the side. A duplicate in the request collapses.
        var next: std.AutoHashMapUnmanaged(ids.SessionId, void) = .empty;
        errdefer next.deinit(self.gpa);
        for (sessions) |sid| try next.put(self.gpa, sid, {});

        // Collect the added sessions. The set is bounded, so a stack array holds them.
        var added: [wire.meta.limits.max_subscriptions]ids.SessionId = undefined;
        var added_len: usize = 0;
        var scan = next.keyIterator();
        while (scan.next()) |sid| if (!conn.subscribed.contains(sid.*)) {
            added[added_len] = sid.*;
            added_len += 1;
        };

        // Reserve one reverse-index slot for each added session. Drop a created entry on failure.
        var reserved: usize = 0;
        errdefer while (reserved > 0) {
            reserved -= 1;
            const list = self.subscribers.getPtr(added[reserved]).?;
            if (list.items.len == 0) {
                list.deinit(self.gpa);
                _ = self.subscribers.remove(added[reserved]);
            }
        };
        for (added[0..added_len]) |sid| {
            const list = try self.subscribers.getOrPut(self.gpa, sid);
            if (!list.found_existing) list.value_ptr.* = .empty;
            reserved += 1; // count the entry before ensureUnusedCapacity, so the rollback covers it
            try list.value_ptr.ensureUnusedCapacity(self.gpa, 1);
        }

        // Commit with no allocation. Remove the dropped sessions, add the new ones, then swap the set.
        var old = conn.subscribed.keyIterator();
        while (old.next()) |sid| if (!next.contains(sid.*)) self.removeSubscriber(sid.*, conn.id);
        for (added[0..added_len]) |sid| self.subscribers.getPtr(sid).?.appendAssumeCapacity(conn.id);
        conn.subscribed.deinit(self.gpa);
        conn.subscribed = next;
        next = .empty;
    }

    /// Fan out framed bytes to every subscriber of a session. Copy the bytes per connection.
    /// The caller owns `bytes`. A must-deliver overflow closes the connection. A shed-able overflow drops the frame.
    pub fn publish(self: *Registry, session_id: ids.SessionId, bytes: []const u8, class: DeliveryClass) void {
        const list = self.subscribers.getPtr(session_id) orelse return;
        for (list.items) |cid| {
            const conn = self.connections.get(cid) orelse continue;
            if (conn.closing) continue;
            const copy = self.gpa.dupe(u8, bytes) catch {
                onLostFrame(conn, session_id, class); // an OOM loses the frame before the outbox
                continue;
            };
            if (conn.tryEnqueue(.{ .bytes = copy })) continue; // tryEnqueue frees the copy on a full outbox
            onLostFrame(conn, session_id, class);
        }
    }

    /// Account for a frame that did not reach the outbox. A lost must-deliver frame closes the connection.
    /// An untracked shed also closes it, so the client always learns about the gap.
    fn onLostFrame(conn: *Connection, session_id: ids.SessionId, class: DeliveryClass) void {
        switch (class) {
            .must_deliver => beginClose(conn),
            .shed_able => if (!conn.recordShed(session_id)) beginClose(conn),
        }
    }

    /// Stop sending to a hopelessly slow connection and request both task cancellations.
    fn beginClose(conn: *Connection) void {
        if (conn.closing) return;
        conn.closing = true;
        conn.outbox.close(.graceful);
        if (conn.teardown_callback) |callback| callback(conn.teardown_context.?);
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

/// Serialize a notification to a WebSocket text frame. The returned bytes use the allocator's storage.
pub fn frameNotification(gpa: std.mem.Allocator, note: wire.rpc.Notification) ![]u8 {
    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    try std.json.Stringify.value(note, .{ .emit_null_optional_fields = false }, &body.writer);
    var ws_frame: std.Io.Writer.Allocating = .init(gpa);
    defer ws_frame.deinit();
    try wss.writeMessage(&ws_frame.writer, .text, body.written());
    return ws_frame.toOwnedSlice();
}

/// Frame a `session.deltas_shed` marker. It tells the client to resync after dropped deltas.
fn frameShedMarker(gpa: std.mem.Allocator, session_id: ids.SessionId, count: u64) ![]u8 {
    return frameNotification(gpa, .{ .method = .@"session.deltas_shed", .params = .{
        .session_deltas_shed_data = .{ .session_id = session_id, .count = count },
    } });
}

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

    registry.publish(sid, "hello", .must_deliver);
    // Only a follows the session, so only a's outbox holds the frame.
    const item_a = try a.outbox.tryReceive();
    defer testing.allocator.free(item_a.bytes);
    try testing.expectEqualStrings("hello", item_a.bytes);
    try testing.expectError(error.ChannelEmpty, b.outbox.tryReceive());

    // Unregister removes a from the index, so a later publish reaches nobody.
    registry.unregister(&a);
    registry.publish(sid, "again", .must_deliver);
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

    registry.publish(one, "x", .must_deliver);
    try testing.expectError(error.ChannelEmpty, c.outbox.tryReceive());
    registry.publish(two, "y", .must_deliver);
    const item = try c.outbox.tryReceive();
    defer testing.allocator.free(item.bytes);
    try testing.expectEqualStrings("y", item.bytes);
}

test "setSubscriptions rejects an oversized set and keeps the previous one" {
    var registry = Registry.init(testing.allocator);
    defer registry.deinit();

    var c: Connection = undefined;
    c.init(testing.allocator);
    defer c.deinit();
    try registry.register(&c);

    const keep: ids.SessionId = .bytes([_]u8{7} ** 16);
    try registry.setSubscriptions(&c, &.{keep});

    // A set past the wire limit is rejected, and the previous subscription stays intact.
    var many: [wire.meta.limits.max_subscriptions + 1]ids.SessionId = undefined;
    for (&many, 0..) |*sid, i| sid.* = .bytes([_]u8{@intCast(i)} ** 16);
    try testing.expectError(error.TooManySubscriptions, registry.setSubscriptions(&c, &many));

    registry.publish(keep, "y", .must_deliver);
    const item = try c.outbox.tryReceive();
    defer testing.allocator.free(item.bytes);
    try testing.expectEqualStrings("y", item.bytes);
}

fn fillOutbox(conn: *Connection) !void {
    while (!conn.outbox.isFull()) {
        const b = try testing.allocator.dupe(u8, "x");
        try testing.expect(conn.tryEnqueue(.{ .bytes = b }));
    }
}

fn markTeardown(context: *anyopaque) void {
    const marked: *bool = @ptrCast(@alignCast(context));
    marked.* = true;
}

test "a must-deliver overflow closes the connection" {
    var registry = Registry.init(testing.allocator);
    defer registry.deinit();
    var c: Connection = undefined;
    c.init(testing.allocator);
    defer c.deinit();
    try registry.register(&c);
    var teardown = false;
    c.setTeardown(&teardown, markTeardown);
    const sid: ids.SessionId = .bytes([_]u8{3} ** 16);
    try registry.setSubscriptions(&c, &.{sid});

    try fillOutbox(&c);
    registry.publish(sid, "committed", .must_deliver);
    try testing.expect(c.closing);
    try testing.expect(teardown);
    registry.publish(sid, "more", .must_deliver); // a closing connection is skipped
}

test "a terminal close aborts without waiting on a full outbox" {
    var c: Connection = undefined;
    c.init(testing.allocator);
    defer c.deinit();

    try fillOutbox(&c);
    const bytes = try testing.allocator.dupe(u8, "close");
    try testing.expect(!c.tryEnqueue(.{ .bytes = bytes, .terminal = true }));
}

test "a shed-able overflow drops the delta; the writer drains a resync marker" {
    var registry = Registry.init(testing.allocator);
    defer registry.deinit();
    var c: Connection = undefined;
    c.init(testing.allocator);
    defer c.deinit();
    try registry.register(&c);
    const sid: ids.SessionId = .bytes([_]u8{4} ** 16);
    try registry.setSubscriptions(&c, &.{sid});

    try fillOutbox(&c);
    registry.publish(sid, "delta", .shed_able); // the outbox is full, so the delta drops
    try testing.expect(!c.closing);
    try testing.expectEqual(@as(u64, 1), c.shed.get(sid).?.count);

    // The writer drains a marker once it catches up.
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try c.drainShedMarkers(&buf.writer);
    try testing.expect(std.mem.indexOf(u8, buf.written(), "session.deltas_shed") != null);
    try testing.expectEqual(@as(u64, 1), c.shed.get(sid).?.notified);

    // No new sheds, so a second drain writes nothing.
    var buf2: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf2.deinit();
    try c.drainShedMarkers(&buf2.writer);
    try testing.expectEqual(@as(usize, 0), buf2.written().len);
}
