//! A bounded cache of recent committed messages and the configs they reference.
//! The daemon hydrates this from SQLite on runtime activation. SQLite stays authoritative.
//! The window drops the oldest message when it passes a count or a byte bound. Then `has_more` is true.

const std = @import("std");
const wire = @import("wire");

const ids = wire.ids;
const message = wire.message;
const run = wire.run;

pub const Error = error{OutOfMemory};

/// The default message-count bound. It matches the resync page size.
pub const default_max_messages: usize = 500;
/// The default byte bound. One large message can dominate, so bound bytes too.
pub const default_max_bytes: usize = 4 * 1024 * 1024;

/// A recent committed message plus its serialized byte size. Each entry owns an arena for its clone.
const Entry = struct {
    arena: std.heap.ArenaAllocator,
    message: message.Message,
    bytes: usize,

    fn deinit(self: *Entry) void {
        self.arena.deinit();
    }
};

/// Store recent committed messages in oldest-first order. Bound the window by count and by bytes.
pub const Window = struct {
    gpa: std.mem.Allocator,
    list: std.ArrayList(Entry) = .empty,
    total_bytes: usize = 0,
    has_more: bool = false,
    max_messages: usize = default_max_messages,
    max_bytes: usize = default_max_bytes,

    pub fn init(gpa: std.mem.Allocator) Window {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Window) void {
        for (self.list.items) |*e| e.deinit();
        self.list.deinit(self.gpa);
        self.* = undefined;
    }

    /// Append a committed message. Clone it into its own arena. Drop the oldest over a bound.
    pub fn append(self: *Window, m: message.Message) Error!void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        errdefer arena.deinit();
        const owned = try wire.dupe(arena.allocator(), m);
        const size = try messageBytes(m);
        try self.list.append(self.gpa, .{ .arena = arena, .message = owned, .bytes = size });
        self.total_bytes += size;
        self.evict();
    }

    /// Drop windowed messages with an id at or above `first_removed_id`. Truncation removes them.
    /// The window stays oldest-first, so the removed messages form the tail.
    pub fn trimFrom(self: *Window, first_removed_id: ids.MessageId) void {
        while (self.list.items.len > 0 and self.list.items[self.list.items.len - 1].message.id() >= first_removed_id) {
            var removed = self.list.pop().?;
            self.total_bytes -= removed.bytes;
            removed.deinit();
        }
    }

    /// Return the messages oldest-first. The slice borrows `scratch`. The entries own their content.
    /// A later append, trim, or deinit invalidates the returned view.
    pub fn messages(self: *const Window, scratch: std.mem.Allocator) Error![]const message.Message {
        const out = try scratch.alloc(message.Message, self.list.items.len);
        for (self.list.items, 0..) |*e, i| out[i] = e.message;
        return out;
    }

    /// Return the newest committed id in the window, or null. Resync uses it as the finalized high-water.
    pub fn newestId(self: *const Window) ?ids.MessageId {
        if (self.list.items.len == 0) return null;
        return self.list.items[self.list.items.len - 1].message.id();
    }

    // Drop the oldest messages until the window fits both bounds. Keep at least one message.
    // The byte bound is soft. One message over `max_bytes` stays, so resync always holds the newest tail.
    fn evict(self: *Window) void {
        while (self.list.items.len > 1 and (self.list.items.len > self.max_messages or self.total_bytes > self.max_bytes)) {
            var oldest = self.list.orderedRemove(0);
            self.total_bytes -= oldest.bytes;
            oldest.deinit();
            self.has_more = true; // an older message left the window, so more history exists
        }
    }
};

/// Store one config for each revision the window or the active draft references. Key by revision.
pub const ConfigSet = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    map: std.AutoHashMapUnmanaged(ids.ConfigRev, run.RunConfig) = .empty,

    pub fn init(gpa: std.mem.Allocator) ConfigSet {
        return .{ .gpa = gpa, .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn deinit(self: *ConfigSet) void {
        self.map.deinit(self.gpa);
        self.arena.deinit();
        self.* = undefined;
    }

    /// Return the recorded config for a revision, or null.
    pub fn get(self: *const ConfigSet, rev: ids.ConfigRev) ?run.RunConfig {
        return self.map.get(rev);
    }

    /// Record a config revision. Clone it into the arena. Keep the first value for a revision.
    pub fn record(self: *ConfigSet, config: run.RunConfig) Error!void {
        const gop = try self.map.getOrPut(self.gpa, config.config_rev);
        if (gop.found_existing) return;
        errdefer _ = self.map.remove(config.config_rev); // A failed clone must not leave a dead key.
        gop.value_ptr.* = try wire.dupe(self.arena.allocator(), config);
    }
};

/// Return the serialized byte size of a committed message. The window bounds itself by this size.
fn messageBytes(m: message.Message) Error!usize {
    var buffer: [0]u8 = .{};
    var discarding = std.Io.Writer.Discarding.init(&buffer);
    std.json.Stringify.value(m, .{ .emit_null_optional_fields = false }, &discarding.writer) catch return error.OutOfMemory;
    return std.math.cast(usize, discarding.fullCount()) orelse error.OutOfMemory;
}

const testing = std.testing;

fn userMessage(id: ids.MessageId, comptime text: []const u8) message.Message {
    return .{ .user = .{ .id = id, .content = &.{.{ .text = .{ .text = text } }}, .input_id = id, .time = .{ .created_at_ms = 1 } } };
}

test "the window keeps committed messages oldest-first and reports the newest id" {
    var w = Window.init(testing.allocator);
    defer w.deinit();
    try w.append(userMessage(1, "a"));
    try w.append(userMessage(2, "b"));
    try testing.expectEqual(@as(?ids.MessageId, 2), w.newestId());

    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const out = try w.messages(scratch.allocator());
    try testing.expectEqual(@as(usize, 2), out.len);
    try testing.expectEqual(@as(ids.MessageId, 1), out[0].user.id);
    try testing.expectEqualStrings("b", out[1].user.content[0].text.text);
}

test "the count bound drops the oldest and marks has_more" {
    var w = Window.init(testing.allocator);
    w.max_messages = 2;
    defer w.deinit();
    try w.append(userMessage(1, "a"));
    try w.append(userMessage(2, "b"));
    try w.append(userMessage(3, "c"));
    try testing.expectEqual(@as(usize, 2), w.list.items.len);
    try testing.expect(w.has_more);
    try testing.expectEqual(@as(?ids.MessageId, 3), w.newestId());
    try testing.expectEqual(@as(ids.MessageId, 2), w.list.items[0].message.id());
}

test "trimFrom removes truncated ids and keeps older ones" {
    var w = Window.init(testing.allocator);
    defer w.deinit();
    try w.append(userMessage(1, "a"));
    try w.append(userMessage(2, "b"));
    try w.append(userMessage(3, "c"));
    w.trimFrom(2); // remove ids 2 and 3
    try testing.expectEqual(@as(usize, 1), w.list.items.len);
    try testing.expectEqual(@as(?ids.MessageId, 1), w.newestId());
}

test "total_bytes tracks append, eviction, and trim" {
    var w = Window.init(testing.allocator);
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
    var w = Window.init(testing.allocator);
    w.max_bytes = 1;
    defer w.deinit();
    try w.append(userMessage(1, "hello"));
    try testing.expectEqual(@as(usize, 1), w.list.items.len); // keep at least one; the byte bound is soft
    try w.append(userMessage(2, "world"));
    try testing.expectEqual(@as(usize, 1), w.list.items.len); // the older message left the window
    try testing.expect(w.has_more);
    try testing.expectEqual(@as(?ids.MessageId, 2), w.newestId());
}

test "the config set keeps the first value for a revision" {
    var c = ConfigSet.init(testing.allocator);
    defer c.deinit();
    try c.record(.{ .config_rev = 1, .model = "opus", .reasoning = "high" });
    try c.record(.{ .config_rev = 1, .model = "changed", .reasoning = "low" }); // The record keeps the first value.
    try c.record(.{ .config_rev = 2, .model = "sonnet", .reasoning = "off" });
    try testing.expectEqualStrings("opus", c.get(1).?.model);
    try testing.expect(c.get(2) != null);
    try testing.expect(c.get(3) == null);
}

test "record removes the key when the clone fails" {
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 1 });
    var c = ConfigSet.init(failing.allocator());
    defer c.deinit();
    // The map insert succeeds, then the clone fails. The dead key must not survive.
    try testing.expectError(error.OutOfMemory, c.record(.{ .config_rev = 1, .model = "opus", .reasoning = "high" }));
    try testing.expect(c.get(1) == null);
}
