//! The committed messages of one session: every message the model reads, and recent older messages for the view.

const std = @import("std");
const proto = @import("proto");

const ids = proto.ids;
const message = proto.message;

/// A history fails only when it cannot copy a message.
pub const Error = error{OutOfMemory};

/// The view bound on messages the model no longer reads. Compaction bounds the tokens of the model range, but not its bytes: a diff counts no tokens.
pub const default_max_messages: usize = 1000;
/// The byte bound on messages the model no longer reads. One large message can dominate, so bound bytes too.
const default_max_bytes: usize = 8 * 1024 * 1024;

/// One committed message. Its strings and slices live in `block`, one allocation of the exact copy size.
const Entry = struct {
    message: message.Message,
    block: []align(proto.clone.max_alignment) u8,
};

/// Store committed messages oldest-first. Keep every message from `keep_from`, and bound the older ones by count and bytes.
pub const History = struct {
    gpa: std.mem.Allocator,
    list: std.ArrayList(Entry) = .empty,
    /// The first message id the model reads: the first kept id of the newest checkpoint, or 0 without one.
    keep_from: ids.MessageId = 0,
    total_bytes: usize = 0,
    max_messages: usize = default_max_messages,
    max_bytes: usize = default_max_bytes,

    /// Return an empty history. `gpa` owns each message block.
    pub fn init(gpa: std.mem.Allocator) History {
        return .{ .gpa = gpa };
    }

    /// Free every message block.
    pub fn deinit(self: *History) void {
        for (self.list.items) |e| self.gpa.free(e.block);
        self.list.deinit(self.gpa);
        self.* = undefined;
    }

    /// Append a committed message in one exact-size copy. A checkpoint moves `keep_from`, then older messages over a bound leave.
    pub fn append(self: *History, m: message.Message) Error!void {
        std.debug.assert(self.list.items.len == 0 or m.id() > self.list.items[self.list.items.len - 1].message.id());
        try self.list.ensureUnusedCapacity(self.gpa, 1);
        const block = try self.gpa.alignedAlloc(u8, .fromByteUnits(proto.clone.max_alignment), proto.clone.size(m));
        var fixed = std.heap.FixedBufferAllocator.init(block);
        const owned = proto.dupe(fixed.allocator(), m) catch unreachable; // `size` measured each allocation of this copy.
        std.debug.assert(fixed.end_index == block.len);
        self.list.appendAssumeCapacity(.{ .message = owned, .block = block });
        self.total_bytes += block.len;
        if (owned == .compaction) {
            std.debug.assert(owned.compaction.first_kept_id >= self.keep_from); // a checkpoint covers the older one
            std.debug.assert(owned.compaction.first_kept_id < owned.compaction.id); // the newest checkpoint stays at or above keep_from
            self.keep_from = owned.compaction.first_kept_id;
        }
        self.evict();
    }

    /// Return the newest checkpoint, or null without one. It borrows its entry, which eviction keeps because its id is above `keep_from`.
    pub fn head(self: *const History) ?message.CompactionMessage {
        var i = self.list.items.len;
        while (i > 0) {
            i -= 1;
            const m = self.list.items[i].message;
            if (m == .compaction) return m.compaction;
            if (m.id() < self.keep_from) return null;
        }
        return null;
    }

    /// Return the newest checkpoint, then every other message from `keep_from` up to `stop_id`, exclusive. The slice belongs to `arena`; the messages borrow the history.
    pub fn model(self: *const History, arena: std.mem.Allocator, stop_id: ?ids.MessageId) Error![]const message.Message {
        // The ids rise, so the model range starts at the first id at or above `keep_from`.
        const first = std.sort.partitionPoint(Entry, self.list.items, self.keep_from, struct {
            fn below(keep: ids.MessageId, e: Entry) bool {
                return e.message.id() < keep;
            }
        }.below);
        var out: std.ArrayList(message.Message) = try .initCapacity(arena, self.list.items.len - first + 1);
        if (self.head()) |h| out.appendAssumeCapacity(.{ .compaction = h });
        for (self.list.items[first..]) |e| {
            if (stop_id) |stop| if (e.message.id() >= stop) break;
            if (e.message != .compaction) out.appendAssumeCapacity(e.message);
        }
        return out.items;
    }

    // Drop the oldest messages over a bound, but only below `keep_from`, because the model reads the rest.
    fn evict(self: *History) void {
        var dropped: usize = 0;
        var bytes = self.total_bytes;
        for (self.list.items) |e| {
            if (e.message.id() >= self.keep_from) break;
            if (self.list.items.len - dropped <= self.max_messages and bytes <= self.max_bytes) break;
            bytes -= e.block.len;
            self.gpa.free(e.block);
            dropped += 1;
        }
        if (dropped == 0) return;
        self.list.replaceRangeAssumeCapacity(0, dropped, &.{});
        self.total_bytes = bytes;
    }
};

const testing = std.testing;

fn userMessage(id: ids.MessageId, comptime text: []const u8) message.Message {
    return .{ .user = .{ .id = id, .content = &.{.{ .text = .{ .text = text } }}, .input_id = id, .time = .{ .created_at_ms = 1 } } };
}

test "the bounds drop only messages the model no longer reads" {
    var h = History.init(testing.allocator);
    defer h.deinit();
    h.max_messages = 1;
    try h.append(userMessage(1, "a"));
    try h.append(userMessage(2, "b"));
    try h.append(userMessage(3, "c"));
    // Without a checkpoint the model reads every message, so the bound drops none.
    try testing.expectEqual(@as(usize, 3), h.list.items.len);
    try h.append(.{ .compaction = .{ .id = 4, .run_id = 1, .reason = .manual, .summary = "s", .first_kept_id = 3, .tokens_before = 2, .tokens_after = 1, .time = .{ .created_at_ms = 1 } } });
    try testing.expectEqual(@as(ids.MessageId, 3), h.list.items[0].message.id());
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const read = try h.model(arena.allocator(), null);
    try testing.expectEqual(@as(usize, 2), read.len);
    try testing.expectEqualStrings("s", read[0].compaction.summary);
    try testing.expectEqualStrings("c", read[1].user.content[0].text.text);
    try testing.expectEqual(h.list.items[0].block.len + h.list.items[1].block.len, h.total_bytes);
}
