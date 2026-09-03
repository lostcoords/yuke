//! The engine hands each event to every in-process subscriber.
//! One process has few readers, so an event travels as a value and never as JSON bytes.

const std = @import("std");
const proto = @import("proto");

/// One subscriber. Its context must outlive every emit until the set removes it.
pub const Sink = struct {
    ctx: *anyopaque,
    on_event: *const fn (ctx: *anyopaque, note: proto.rpc.Notification) void,
};

/// The frontends one process runs at once. The TUI takes one, and an RPC stream takes another.
pub const max_sinks: usize = 4;

/// Every subscriber of the engine. The engine owns one set and fans each event out to all of them.
/// The set holds no allocation, because the count is small and bounded.
pub const Sinks = struct {
    entries: [max_sinks]Sink = undefined,
    len: usize = 0,
    /// Set while `emit` walks the set. A callback must not add or remove a subscriber.
    emitting: bool = false,

    /// Add one subscriber. A frontend attaches once.
    pub fn add(self: *Sinks, sink: Sink) void {
        std.debug.assert(!self.emitting); // a callback must not change the set it runs from
        std.debug.assert(self.len < max_sinks); // a frontend over the cap is a wiring bug
        std.debug.assert(self.indexOf(sink.ctx) == null); // one attach for each frontend
        self.entries[self.len] = sink;
        self.len += 1;
    }

    /// Remove one subscriber before its context dies. The order of the others does not change.
    pub fn remove(self: *Sinks, ctx: *anyopaque) void {
        std.debug.assert(!self.emitting); // a callback must not change the set it runs from
        const i = self.indexOf(ctx).?; // a detach without an attach is a wiring bug
        std.mem.copyForwards(Sink, self.entries[i .. self.len - 1], self.entries[i + 1 .. self.len]);
        self.len -= 1;
    }

    /// Deliver one event to every subscriber. An empty set drops it, which is what a headless run wants.
    /// The note borrows the caller's arena, so a subscriber must copy what it keeps.
    pub fn emit(self: *Sinks, note: proto.rpc.Notification) void {
        std.debug.assert(!self.emitting); // an event never re-enters the fan-out
        self.emitting = true;
        defer self.emitting = false;
        for (self.entries[0..self.len]) |sink| sink.on_event(sink.ctx, note);
    }

    fn indexOf(self: *const Sinks, ctx: *anyopaque) ?usize {
        for (self.entries[0..self.len], 0..) |sink, i| if (sink.ctx == ctx) return i;
        return null;
    }
};

const testing = std.testing;

fn removedNote() proto.rpc.Notification {
    return .{ .method = .@"session.removed", .params = .{ .session_removed_data = .{
        .revision = 1,
        .session_id = proto.ids.SessionId.bytes([_]u8{0} ** 16),
    } } };
}

const Counter = struct {
    seen: usize = 0,
    fn onEvent(ctx: *anyopaque, _: proto.rpc.Notification) void {
        const self: *Counter = @ptrCast(@alignCast(ctx));
        self.seen += 1;
    }
    fn sink(self: *Counter) Sink {
        return .{ .ctx = @ptrCast(self), .on_event = onEvent };
    }
};

test "an empty set drops an event" {
    var sinks: Sinks = .{};
    sinks.emit(removedNote()); // a headless run has no subscriber
    try testing.expectEqual(@as(usize, 0), sinks.len);
}

test "every subscriber receives the same event" {
    var sinks: Sinks = .{};
    var tui: Counter = .{};
    var rpc: Counter = .{};
    sinks.add(tui.sink());
    sinks.add(rpc.sink());

    sinks.emit(removedNote());
    try testing.expectEqual(@as(usize, 1), tui.seen);
    try testing.expectEqual(@as(usize, 1), rpc.seen);
}

test "a removed subscriber stops receiving, and the others continue" {
    var sinks: Sinks = .{};
    var first: Counter = .{};
    var second: Counter = .{};
    var third: Counter = .{};
    sinks.add(first.sink());
    sinks.add(second.sink());
    sinks.add(third.sink());

    sinks.remove(@ptrCast(&second));
    sinks.emit(removedNote());
    try testing.expectEqual(@as(usize, 1), first.seen);
    try testing.expectEqual(@as(usize, 0), second.seen); // it left before the emit
    try testing.expectEqual(@as(usize, 1), third.seen);
    try testing.expectEqual(@as(usize, 2), sinks.len);
}

test "a re-added subscriber receives events again" {
    var sinks: Sinks = .{};
    var only: Counter = .{};
    sinks.add(only.sink());
    sinks.remove(@ptrCast(&only));
    sinks.emit(removedNote());
    try testing.expectEqual(@as(usize, 0), only.seen);

    sinks.add(only.sink());
    sinks.emit(removedNote());
    try testing.expectEqual(@as(usize, 1), only.seen);
}
