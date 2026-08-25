//! One WebSocket connection's outbound path and the daemon's connection registry. A writer task owns socket.output and drains a bounded outbox.
//! A reader task enqueues pre-framed WS bytes. The registry routes a session broadcast to every subscribed connection.

const std = @import("std");
const wire = @import("wire");
const wss = @import("websocket").server;
const ids = wire.ids;

/// Queue one outbound WS frame. The writer frees gpa-owned bytes after the write.
/// The `terminal` flag marks a close frame. The writer stops after that frame.
pub const OutboxItem = struct {
    bytes: []u8,
    terminal: bool = false,
};

/// The outbox capacity bounds how far the writer falls behind before the reader blocks.
const outbox_capacity = 256;

/// Classify broadcast delivery. A live delta may drop under backpressure; every other event must arrive.
pub const DeliveryClass = enum { must_deliver, shed_able };

/// Classify a broadcast. Only a live delta is shed-able; the committed snapshot restores the dropped bytes.
pub fn classOf(method: wire.enums.BroadcastName) DeliveryClass {
    return switch (method) {
        .@"message.part_delta", .@"tool.output_delta" => .shed_able,
        else => .must_deliver,
    };
}

test "only the two deltas are shed-able" {
    try std.testing.expectEqual(DeliveryClass.shed_able, classOf(.@"message.part_delta"));
    try std.testing.expectEqual(DeliveryClass.shed_able, classOf(.@"tool.output_delta"));
    try std.testing.expectEqual(DeliveryClass.must_deliver, classOf(.@"message.part_finalized"));
    try std.testing.expectEqual(DeliveryClass.must_deliver, classOf(.@"message.committed"));
}

/// Track shed counts for one session on one connection. A resync marker follows once the client catches up.
const ShedState = struct {
    count: u64 = 0, // The total number of dropped deltas.
    notified: u64 = 0, // The last delivered marker reports this count.
};

pub const Connection = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    id: u64 = 0, // The registry assigns a nonzero id. Zero means unregistered.
    closing: bool = false, // A must-deliver overflow forces a close. The publish step skips this connection.
    teardown_context: ?*anyopaque = null,
    teardown_callback: ?*const fn (*anyopaque) void = null,
    buffer: [outbox_capacity]OutboxItem = undefined,
    outbox: std.Io.Queue(OutboxItem) = undefined,
    subscribed: std.AutoHashMapUnmanaged(ids.SessionId, void) = .empty, // The sessions that this connection follows.
    shed: std.AutoHashMapUnmanaged(ids.SessionId, ShedState) = .empty, // The sessions with dropped deltas.

    /// Initialize in place. The queue borrows `buffer`, so the Connection address must stay stable.
    pub fn init(self: *Connection, gpa: std.mem.Allocator, io: std.Io) void {
        self.* = .{ .gpa = gpa, .io = io };
        self.outbox = std.Io.Queue(OutboxItem).init(self.buffer[0..]);
    }

    /// Register the callback that wakes the WebSocket supervisor. The callback must return at once.
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
        self.outbox.putOne(self.io, item) catch |err| {
            self.gpa.free(item.bytes);
            return err;
        };
    }

    /// Try to enqueue owned bytes immediately. Return false and free them when the outbox is full.
    pub fn tryEnqueue(self: *Connection, item: OutboxItem) bool {
        const n = self.outbox.putUncancelable(self.io, &.{item}, 0) catch {
            self.gpa.free(item.bytes);
            return false;
        };
        std.debug.assert(n <= 1);
        if (n == 1) return true;
        self.gpa.free(item.bytes);
        return false;
    }

    /// Drain and free every unsent frame, then close the outbox. Call after the writer joins.
    pub fn deinit(self: *Connection) void {
        while (true) {
            const item = self.tryReceive() catch |err| {
                std.debug.assert(err == error.Closed);
                break;
            };
            const queued = item orelse break;
            self.gpa.free(queued.bytes);
        }
        self.close();
        self.clearTeardown();
        self.subscribed.deinit(self.gpa);
        self.shed.deinit(self.gpa);
    }

    /// Try to receive one item without blocking. Null means the open queue is empty.
    pub fn tryReceive(self: *Connection) error{Closed}!?OutboxItem {
        var item: [1]OutboxItem = undefined;
        const n = try self.outbox.getUncancelable(self.io, &item, 0);
        if (n == 0) return null;
        std.debug.assert(n == 1);
        return item[0];
    }

    /// Close the outbox and let the writer drain its buffered items.
    pub fn close(self: *Connection) void {
        self.outbox.close(self.io);
    }

    /// Record one dropped delta for a session. Return false when the connection lacks shed capacity.
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

/// Track live connections and a reverse subscription index in a daemon-global registry.
/// The registry assigns each connection a new monotonic id. A stale id fails lookup, so publish skips it safely.
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
        std.debug.assert(conn.id == 0); // A fresh connection has no registry id.
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
    /// every allocation first, so the swap then needs no allocation. Any failure preserves the old state.
    pub fn setSubscriptions(self: *Registry, conn: *Connection, sessions: []const ids.SessionId) !void {
        if (sessions.len > wire.meta.limits.max_subscriptions) return error.TooManySubscriptions;

        // Build the deduplicated new set on the side. A duplicate in the request collapses.
        var next: std.AutoHashMapUnmanaged(ids.SessionId, void) = .empty;
        errdefer next.deinit(self.gpa);
        for (sessions) |sid| try next.put(self.gpa, sid, {});

        // Collect the added sessions. The set has a bound, so a stack array holds them.
        var added: [wire.meta.limits.max_subscriptions]ids.SessionId = undefined;
        var added_len: usize = 0;
        var scan = next.keyIterator();
        while (scan.next()) |sid| if (!conn.subscribed.contains(sid.*)) {
            added[added_len] = sid.*;
            added_len += 1;
        };

        // Reserve one reverse-index slot for each added session. Drop a created entry after a failure.
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
            reserved += 1; // Count the entry before ensureUnusedCapacity, so the rollback covers it.
            try list.value_ptr.ensureUnusedCapacity(self.gpa, 1);
        }

        // Commit from the reserved storage. Remove the dropped sessions, add the new ones, then swap the set.
        var old = conn.subscribed.keyIterator();
        while (old.next()) |sid| if (!next.contains(sid.*)) {
            self.removeSubscriber(sid.*, conn.id);
            _ = conn.shed.remove(sid.*);
        };
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
                onLostFrame(conn, session_id, class); // An OOM loses the frame before it reaches the outbox.
                continue;
            };
            if (conn.tryEnqueue(.{ .bytes = copy })) continue; // The tryEnqueue call frees the copy when the outbox is full.
            onLostFrame(conn, session_id, class);
        }
    }

    /// Account for a frame that missed the outbox. A lost must-deliver frame closes the connection.
    /// An untracked shed also closes it, so the client always learns about the gap.
    fn onLostFrame(conn: *Connection, session_id: ids.SessionId, class: DeliveryClass) void {
        switch (class) {
            .must_deliver => beginClose(conn),
            .shed_able => if (!conn.recordShed(session_id)) beginClose(conn),
        }
    }

    /// Close a connection that falls behind. Request cancellation for both tasks.
    fn beginClose(conn: *Connection) void {
        if (conn.closing) return;
        conn.closing = true;
        conn.close();
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
    a.init(testing.allocator, testing.io);
    defer a.deinit();
    var b: Connection = undefined;
    b.init(testing.allocator, testing.io);
    defer b.deinit();
    try registry.register(&a);
    try registry.register(&b);
    try testing.expect(a.id != 0 and b.id != 0 and a.id != b.id);

    const sid: ids.SessionId = .bytes([_]u8{7} ** 16);
    try registry.setSubscriptions(&a, &.{sid});

    registry.publish(sid, "hello", .must_deliver);
    // Only connection a follows the session, so its outbox holds the frame.
    const item_a = (try a.tryReceive()).?;
    defer testing.allocator.free(item_a.bytes);
    try testing.expectEqualStrings("hello", item_a.bytes);
    try testing.expect((try b.tryReceive()) == null);

    // Unregister removes connection a from the index, so a later publish reaches an empty subscriber set.
    registry.unregister(&a);
    registry.publish(sid, "again", .must_deliver);
    try testing.expect((try a.tryReceive()) == null);
}

test "setSubscriptions replaces the previous set" {
    var registry = Registry.init(testing.allocator);
    defer registry.deinit();

    var c: Connection = undefined;
    c.init(testing.allocator, testing.io);
    defer c.deinit();
    try registry.register(&c);

    const one: ids.SessionId = .bytes([_]u8{1} ** 16);
    const two: ids.SessionId = .bytes([_]u8{2} ** 16);
    try registry.setSubscriptions(&c, &.{ one, one, two }); // The duplicate collapses.

    try fillOutbox(&c);
    registry.publish(one, "delta", .shed_able);
    try testing.expect(c.shed.contains(one));

    try registry.setSubscriptions(&c, &.{two}); // The set now contains only two.
    try testing.expect(!c.shed.contains(one));

    var markers: std.Io.Writer.Allocating = .init(testing.allocator);
    defer markers.deinit();
    try c.drainShedMarkers(&markers.writer);
    try testing.expectEqual(@as(usize, 0), markers.written().len);

    while (true) {
        const queued = (try c.tryReceive()) orelse break;
        testing.allocator.free(queued.bytes);
    }

    registry.publish(one, "x", .must_deliver);
    try testing.expect((try c.tryReceive()) == null);
    registry.publish(two, "y", .must_deliver);
    const item = (try c.tryReceive()).?;
    defer testing.allocator.free(item.bytes);
    try testing.expectEqualStrings("y", item.bytes);
}

test "setSubscriptions rejects an oversized set and keeps the previous one" {
    var registry = Registry.init(testing.allocator);
    defer registry.deinit();

    var c: Connection = undefined;
    c.init(testing.allocator, testing.io);
    defer c.deinit();
    try registry.register(&c);

    const keep: ids.SessionId = .bytes([_]u8{7} ** 16);
    try registry.setSubscriptions(&c, &.{keep});

    // The registry rejects a set past the wire limit and preserves the previous set.
    var many: [wire.meta.limits.max_subscriptions + 1]ids.SessionId = undefined;
    for (&many, 0..) |*sid, i| sid.* = .bytes([_]u8{@intCast(i)} ** 16);
    try testing.expectError(error.TooManySubscriptions, registry.setSubscriptions(&c, &many));

    registry.publish(keep, "y", .must_deliver);
    const item = (try c.tryReceive()).?;
    defer testing.allocator.free(item.bytes);
    try testing.expectEqualStrings("y", item.bytes);
}

fn fillOutbox(conn: *Connection) !void {
    while (true) {
        const b = try testing.allocator.dupe(u8, "x");
        if (!conn.tryEnqueue(.{ .bytes = b })) break;
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
    c.init(testing.allocator, testing.io);
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
    registry.publish(sid, "more", .must_deliver); // The publish step skips a closing connection.
}

test "a terminal close aborts without waiting on a full outbox" {
    var c: Connection = undefined;
    c.init(testing.allocator, testing.io);
    defer c.deinit();

    try fillOutbox(&c);
    const bytes = try testing.allocator.dupe(u8, "close");
    try testing.expect(!c.tryEnqueue(.{ .bytes = bytes, .terminal = true }));
}

test "a closed outbox drains its buffered items before it reports closed" {
    var c: Connection = undefined;
    c.init(testing.allocator, testing.io);
    defer c.deinit();

    try c.send(.{ .bytes = try testing.allocator.dupe(u8, "one") });
    try c.send(.{ .bytes = try testing.allocator.dupe(u8, "two") });
    c.close();

    const one = (try c.tryReceive()).?;
    defer testing.allocator.free(one.bytes);
    try testing.expectEqualStrings("one", one.bytes);
    const two = (try c.tryReceive()).?;
    defer testing.allocator.free(two.bytes);
    try testing.expectEqualStrings("two", two.bytes);
    try testing.expectError(error.Closed, c.tryReceive());
}

test "a shed-able overflow drops the delta; the writer drains a resync marker" {
    var registry = Registry.init(testing.allocator);
    defer registry.deinit();
    var c: Connection = undefined;
    c.init(testing.allocator, testing.io);
    defer c.deinit();
    try registry.register(&c);
    const sid: ids.SessionId = .bytes([_]u8{4} ** 16);
    try registry.setSubscriptions(&c, &.{sid});

    try fillOutbox(&c);
    registry.publish(sid, "delta", .shed_able); // The full outbox drops the delta.
    try testing.expect(!c.closing);
    try testing.expectEqual(@as(u64, 1), c.shed.get(sid).?.count);

    // The writer drains the marker after it catches up.
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try c.drainShedMarkers(&buf.writer);
    try testing.expect(std.mem.indexOf(u8, buf.written(), "session.deltas_shed") != null);
    try testing.expectEqual(@as(u64, 1), c.shed.get(sid).?.notified);

    // The second drain finds no new sheds and writes nothing.
    var buf2: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf2.deinit();
    try c.drainShedMarkers(&buf2.writer);
    try testing.expectEqual(@as(usize, 0), buf2.written().len);
}
