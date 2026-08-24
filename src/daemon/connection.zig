//! One WebSocket connection's outbound path. A writer coroutine owns socket.output and drains this
//! bounded outbox. A reader coroutine enqueues pre-framed WS bytes. Only the writer writes the socket.

const std = @import("std");
const zio = @import("zio");

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
    buffer: [outbox_capacity]OutboxItem = undefined,
    outbox: zio.Channel(OutboxItem) = undefined,

    /// Initialize in place. The channel borrows `buffer`, so the Connection address must stay stable.
    pub fn init(self: *Connection, gpa: std.mem.Allocator) void {
        self.gpa = gpa;
        self.outbox = zio.Channel(OutboxItem).init(self.buffer[0..]);
    }

    /// Hand owned frame bytes to the writer. Free them when the outbox no longer accepts them.
    pub fn send(self: *Connection, item: OutboxItem) !void {
        self.outbox.send(item) catch |err| {
            self.gpa.free(item.bytes);
            return err;
        };
    }

    /// Drain and free every unsent frame, then close the outbox. Call after the writer joins.
    pub fn deinit(self: *Connection) void {
        while (self.outbox.tryReceive()) |item| {
            self.gpa.free(item.bytes);
        } else |_| {}
        self.outbox.close(.graceful);
    }
};
