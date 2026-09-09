//! A bounded resident transcript caches the recent committed messages of one session.

const std = @import("std");
const proto = @import("proto");

const ids = proto.ids;
const message = proto.message;

pub const Error = error{OutOfMemory};

/// The default message-count bound. It covers the model context, which is the larger reader.
pub const default_max_messages: usize = 1000;
/// The default byte bound. One large message can dominate, so bound bytes too.
pub const default_max_bytes: usize = 8 * 1024 * 1024;

/// A recent committed message plus its serialized byte size. Each entry owns an arena for its clone.
const Entry = struct {
    arena: std.heap.ArenaAllocator,
    message: message.Message,
    bytes: usize,

    fn deinit(self: *Entry) void {
        self.arena.deinit();
    }
};

/// One resident message beside the serialized size the transcript measured when it arrived.
pub const Sized = struct {
    message: message.Message,
    bytes: usize,
};

/// Store recent committed messages in oldest-first order. Bound it by count and by bytes.
pub const Transcript = struct {
    gpa: std.mem.Allocator,
    list: std.ArrayList(Entry) = .empty,
    total_bytes: usize = 0,
    has_more: bool = false,
    max_messages: usize = default_max_messages,
    max_bytes: usize = default_max_bytes,

    pub fn init(gpa: std.mem.Allocator) Transcript {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Transcript) void {
        for (self.list.items) |*e| e.deinit();
        self.list.deinit(self.gpa);
        self.* = undefined;
    }

    /// Append a committed message. Clone it into its own arena. Drop the oldest over a bound.
    pub fn append(self: *Transcript, m: message.Message) Error!void {
        return self.appendSized(m, try messageBytes(m));
    }

    /// Append a message whose serialized size the caller already knows, as the store does.
    pub fn appendSized(self: *Transcript, m: message.Message, size: usize) Error!void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        errdefer arena.deinit();
        const owned = try proto.dupe(arena.allocator(), m);
        try self.list.append(self.gpa, .{ .arena = arena, .message = owned, .bytes = size });
        self.total_bytes += size;
        self.evict();
    }

    /// Drop resident messages with an id at or above `first_removed_id`. Truncation removes them.
    /// The transcript stays oldest-first, so the removed messages form the tail.
    pub fn trimFrom(self: *Transcript, first_removed_id: ids.MessageId) void {
        while (self.list.items.len > 0 and self.list.items[self.list.items.len - 1].message.id() >= first_removed_id) {
            var removed = self.list.pop().?;
            self.total_bytes -= removed.bytes;
            removed.deinit();
        }
    }

    /// Return the messages with the size each one measured on append. A reader that budgets by
    /// size reads it here, because a second measurement would serialize every message again.
    pub fn sized(self: *const Transcript, scratch: std.mem.Allocator) Error![]const Sized {
        const out = try scratch.alloc(Sized, self.list.items.len);
        for (self.list.items, 0..) |*e, i| out[i] = .{ .message = e.message, .bytes = e.bytes };
        return out;
    }

    // Drop the oldest messages until the transcript fits both bounds. Keep at least one message.
    // The byte bound is soft. One message over `max_bytes` stays, so the newest tail always remains.
    fn evict(self: *Transcript) void {
        while (self.list.items.len > 1 and (self.list.items.len > self.max_messages or self.total_bytes > self.max_bytes)) {
            var oldest = self.list.orderedRemove(0);
            self.total_bytes -= oldest.bytes;
            oldest.deinit();
            self.has_more = true; // an older message left the transcript, so more history exists
        }
    }
};

/// Return the serialized byte size of a committed message. Both readers bound themselves by it.
pub fn messageBytes(m: message.Message) Error!usize {
    var buffer: [0]u8 = .{};
    var discarding = std.Io.Writer.Discarding.init(&buffer);
    std.json.Stringify.value(m, .{ .emit_null_optional_fields = false }, &discarding.writer) catch return error.OutOfMemory;
    return std.math.cast(usize, discarding.fullCount()) orelse error.OutOfMemory;
}

const testing = std.testing;

fn userMessage(id: ids.MessageId, comptime text: []const u8) message.Message {
    return .{ .user = .{ .id = id, .content = &.{.{ .text = .{ .text = text } }}, .input_id = id, .time = .{ .created_at_ms = 1 } } };
}

test "the transcript keeps committed messages oldest-first" {
    var w = Transcript.init(testing.allocator);
    defer w.deinit();
    try w.append(userMessage(1, "a"));
    try w.append(userMessage(2, "b"));
    try testing.expectEqual(@as(ids.MessageId, 2), w.list.items[1].message.id());

    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const out = try w.sized(scratch.allocator());
    try testing.expectEqual(@as(usize, 2), out.len);
    try testing.expectEqual(@as(ids.MessageId, 1), out[0].message.user.id);
    try testing.expectEqualStrings("b", out[1].message.user.content[0].text.text);
}

test "the count bound drops the oldest and marks has_more" {
    var w = Transcript.init(testing.allocator);
    w.max_messages = 2;
    defer w.deinit();
    try w.append(userMessage(1, "a"));
    try w.append(userMessage(2, "b"));
    try w.append(userMessage(3, "c"));
    try testing.expectEqual(@as(usize, 2), w.list.items.len);
    try testing.expect(w.has_more);
    try testing.expectEqual(@as(ids.MessageId, 3), w.list.items[1].message.id());
    try testing.expectEqual(@as(ids.MessageId, 2), w.list.items[0].message.id());
}

test "trimFrom removes truncated ids and keeps older ones" {
    var w = Transcript.init(testing.allocator);
    defer w.deinit();
    try w.append(userMessage(1, "a"));
    try w.append(userMessage(2, "b"));
    try w.append(userMessage(3, "c"));
    w.trimFrom(2); // remove ids 2 and 3
    try testing.expectEqual(@as(usize, 1), w.list.items.len);
    try testing.expectEqual(@as(ids.MessageId, 1), w.list.items[0].message.id());
}

test "total_bytes tracks append, eviction, and trim" {
    var w = Transcript.init(testing.allocator);
    w.max_messages = 2;
    defer w.deinit();
    try w.append(userMessage(1, "a"));
    try w.append(userMessage(2, "b"));
    try w.append(userMessage(3, "c")); // evicts id 1
    try testing.expectEqual(@as(usize, 2), w.list.items.len);
    try testing.expectEqual(w.list.items[0].bytes + w.list.items[1].bytes, w.total_bytes);
    w.trimFrom(3); // remove id 3
    try testing.expectEqual(@as(usize, 1), w.list.items.len);
    try testing.expectEqual(w.list.items[0].bytes, w.total_bytes);
}

test "a message over the soft byte bound stays as the only entry" {
    var w = Transcript.init(testing.allocator);
    w.max_bytes = 1;
    defer w.deinit();
    try w.append(userMessage(1, "hello"));
    try testing.expectEqual(@as(usize, 1), w.list.items.len); // keep at least one; the byte bound is soft
    try w.append(userMessage(2, "world"));
    try testing.expectEqual(@as(usize, 1), w.list.items.len); // the older message left the transcript
    try testing.expect(w.has_more);
    try testing.expectEqual(@as(ids.MessageId, 2), w.list.items[0].message.id());
}
