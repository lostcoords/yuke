//! A run retains its slot until each native operation with its signal ends.

const std = @import("std");

const Work = @This();
pending: usize = 0,
done: std.Io.Event = .unset,
operations: std.DoublyLinkedList = .{},

pub const Operation = struct {
    node: std.DoublyLinkedList.Node = .{},
    cancel: *const fn (*Operation) void,
};

pub fn retain(self: *Work, operation: *Operation) void {
    self.operations.append(&operation.node);
    self.pending += 1;
}

pub fn release(self: *Work, io: std.Io, operation: *Operation) void {
    std.debug.assert(self.pending > 0);
    self.operations.remove(&operation.node);
    self.pending -= 1;
    if (self.pending == 0) self.done.set(io);
}

pub fn drain(self: *Work, io: std.Io) void {
    const previous = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(previous);
    var node = self.operations.first;
    while (node) |held| {
        const operation: *Operation = @fieldParentPtr("node", held);
        operation.cancel(operation);
        node = held.next;
    }
    while (self.pending > 0) {
        self.done.reset();
        self.done.wait(io) catch unreachable;
    }
    std.debug.assert(self.operations.first == null);
}
