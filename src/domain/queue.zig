//! Session input-queue projection. Store pending user inputs in FIFO order.
//! The daemon and client fold the same input events into this queue.
//!
//! Each item owns an arena for cloned content. Removing an item frees that content at once.
//! Keep the queue for the session because it changes often. See draft.zig for the same pattern.

const std = @import("std");
const wire = @import("wire");

const ids = wire.ids;
const content = wire.content;
const input = wire.input;
const misc = wire.misc;

pub const Error = error{OutOfMemory};

/// Result of folding a queue event. The daemon produces events and asserts `changed`.
pub const Applied = enum {
    /// Mark an item as changed when the fold adds or removes it.
    changed,
    /// Return `noop` for duplicate events or absent items. Leave the queue unchanged.
    noop,
};

/// Keep each item's content in `arena` after cloning it from the source frame.
pub const Item = struct {
    arena: std.heap.ArenaAllocator,
    input_id: ids.InputId,
    content: []const content.ContentPart,
    queued_at_ms: u64,

    fn clone(gpa: std.mem.Allocator, qi: misc.QueuedInput) Error!Item {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const owned = try wire.dupe(arena.allocator(), qi.content);
        return .{ .arena = arena, .input_id = qi.input_id, .content = owned, .queued_at_ms = qi.queued_at_ms };
    }

    fn deinit(self: *Item) void {
        self.arena.deinit();
    }
};

/// Store pending inputs in oldest-first FIFO order.
pub const Queue = struct {
    gpa: std.mem.Allocator,
    list: std.ArrayList(Item) = .empty,

    pub fn init(gpa: std.mem.Allocator) Queue {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Queue) void {
        for (self.list.items) |*it| it.deinit();
        self.list.deinit(self.gpa);
        self.* = undefined;
    }

    /// Fold `input.queued` at the queue tail. Treat duplicate `input_id` values as no-ops so an
    /// optimistic entry merges with its broadcast. Enforce `max_queued_inputs` before `send_input`.
    pub fn onQueued(self: *Queue, d: input.InputQueuedData) Error!Applied {
        if (self.indexOf(d.input.input_id) != null) return .noop;
        var item = try Item.clone(self.gpa, d.input);
        errdefer item.deinit();
        try self.list.append(self.gpa, item);
        return .changed;
    }

    /// Fold `input.canceled` by removing the input with its id.
    pub fn onCanceled(self: *Queue, d: input.InputCanceledData) Applied {
        return self.removeById(d.input_id);
    }

    /// Remove a queued input when its user message commits. Use the same rule as cancellation.
    pub fn retire(self: *Queue, input_id: ids.InputId) Applied {
        return self.removeById(input_id);
    }

    /// Return the pending-input count. It equals `SessionActivity.queued`.
    pub fn depth(self: *const Queue) usize {
        return self.list.items.len;
    }

    /// Return a read-only view of pending inputs in oldest-first order.
    pub fn entries(self: *const Queue) []const Item {
        return self.list.items;
    }

    fn removeById(self: *Queue, input_id: ids.InputId) Applied {
        const i = self.indexOf(input_id) orelse return .noop;
        var it = self.list.orderedRemove(i);
        it.deinit();
        return .changed;
    }

    fn indexOf(self: *const Queue, input_id: ids.InputId) ?usize {
        for (self.list.items, 0..) |*it, i| if (it.input_id == input_id) return i;
        return null;
    }
};

const testing = std.testing;
const zero_session: ids.SessionId = .bytes(@splat(0));

// `text` is comptime so the content literal promotes to a static const. A runtime
// value would make `&.{...}` a dangling pointer to this frame.
fn queued(input_id: ids.InputId, comptime text: []const u8) input.InputQueuedData {
    return .{
        .session_id = zero_session,
        .input = .{
            .input_id = input_id,
            .content = &.{.{ .text = .{ .text = text } }},
            .queued_at_ms = 100,
        },
    };
}

fn canceled(input_id: ids.InputId) input.InputCanceledData {
    return .{ .session_id = zero_session, .input_id = input_id };
}

test "onQueued clones content and appends; deinit frees it" {
    var q = Queue.init(testing.allocator);
    defer q.deinit();
    try testing.expectEqual(Applied.changed, try q.onQueued(queued(1, "hello")));
    try testing.expectEqual(@as(usize, 1), q.depth());
    try testing.expectEqualStrings("hello", q.entries()[0].content[0].text.text);
}

test "a duplicate input_id is a noop" {
    var q = Queue.init(testing.allocator);
    defer q.deinit();
    _ = try q.onQueued(queued(1, "a"));
    try testing.expectEqual(Applied.noop, try q.onQueued(queued(1, "a")));
    try testing.expectEqual(@as(usize, 1), q.depth());
}

test "cancel and retire remove by id; an absent id is a noop" {
    var q = Queue.init(testing.allocator);
    defer q.deinit();
    _ = try q.onQueued(queued(1, "a"));
    _ = try q.onQueued(queued(2, "b"));
    try testing.expectEqual(Applied.changed, q.onCanceled(canceled(1)));
    try testing.expectEqual(Applied.noop, q.onCanceled(canceled(1)));
    try testing.expectEqual(Applied.changed, q.retire(2));
    try testing.expectEqual(@as(usize, 0), q.depth());
}

test "order stays oldest first after a middle removal" {
    var q = Queue.init(testing.allocator);
    defer q.deinit();
    _ = try q.onQueued(queued(1, "a"));
    _ = try q.onQueued(queued(2, "b"));
    _ = try q.onQueued(queued(3, "c"));
    _ = q.onCanceled(canceled(2));
    try testing.expectEqual(@as(usize, 2), q.depth());
    try testing.expectEqual(@as(ids.InputId, 1), q.entries()[0].input_id);
    try testing.expectEqual(@as(ids.InputId, 3), q.entries()[1].input_id);
}
