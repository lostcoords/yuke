const std = @import("std");
const vaxis = @import("vaxis");

pub const Event = vaxis.Event;
pub const Key = vaxis.Key;

/// A byte-to-event decoder over the libvaxis parser. The caller pushes terminal
/// bytes, then drains events.
pub const Input = struct {
    parser: vaxis.Parser = .{},
    buffer: [capacity]u8 = undefined,
    len: usize = 0,
    /// Owns key text so it survives buffer compaction and the next parse.
    text_buf: [128]u8 = undefined,
    /// Set this allocator for OSC 52 paste. A null value drops the paste text.
    paste_allocator: ?std.mem.Allocator = null,

    pub const capacity = 4096;

    /// Append bytes to the input buffer. Return error.Overflow when it is full.
    pub fn push(self: *Input, bytes: []const u8) error{Overflow}!void {
        if (bytes.len > self.buffer.len - self.len) return error.Overflow;
        @memcpy(self.buffer[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }

    /// Return the next event, or null when the buffer holds no complete event.
    /// It skips an unknown sequence and keeps an incomplete tail.
    pub fn next(self: *Input) !?Event {
        while (self.len > 0) {
            const result = try self.parser.parse(self.buffer[0..self.len], self.paste_allocator);
            if (result.n == 0) return null;
            const event = if (result.event) |e| self.stabilizeText(e) else null;
            std.mem.copyForwards(u8, self.buffer[0..], self.buffer[result.n..self.len]);
            self.len -= result.n;
            if (event) |e| return e;
        }
        return null;
    }

    /// Copy borrowed key text into the owned buffer. The parser points key text
    /// into the input, so a copy must precede buffer compaction.
    fn stabilizeText(self: *Input, event: Event) Event {
        const key: Key = switch (event) {
            .key_press, .key_release => |k| k,
            else => return event,
        };
        const text = key.text orelse return event;
        const n = @min(text.len, self.text_buf.len);
        @memcpy(self.text_buf[0..n], text[0..n]);
        var stable = key;
        stable.text = self.text_buf[0..n];
        return switch (event) {
            .key_press => .{ .key_press = stable },
            .key_release => .{ .key_release = stable },
            else => unreachable,
        };
    }
};

test "push and decode an ascii key" {
    var input: Input = .{};
    try input.push("a");
    const event = (try input.next()).?;
    try std.testing.expectEqual(@as(u21, 'a'), event.key_press.codepoint);
    try std.testing.expectEqual(@as(?Event, null), try input.next());
}

test "key text survives buffer compaction" {
    var input: Input = .{};
    try input.push("ab");
    const event = (try input.next()).?;
    try std.testing.expectEqual(@as(u21, 'a'), event.key_press.codepoint);
    try std.testing.expectEqualStrings("a", event.key_press.text.?);
}

test "decode a csi arrow key" {
    var input: Input = .{};
    try input.push("\x1b[A");
    const event = (try input.next()).?;
    try std.testing.expectEqual(Key.up, event.key_press.codepoint);
}

test "an incomplete sequence waits for more bytes" {
    var input: Input = .{};
    try input.push("\x1b[");
    try std.testing.expectEqual(@as(?Event, null), try input.next());
    try input.push("A");
    const event = (try input.next()).?;
    try std.testing.expectEqual(Key.up, event.key_press.codepoint);
}

test "drain two keys from one push" {
    var input: Input = .{};
    try input.push("ab");
    try std.testing.expectEqual(@as(u21, 'a'), (try input.next()).?.key_press.codepoint);
    try std.testing.expectEqual(@as(u21, 'b'), (try input.next()).?.key_press.codepoint);
    try std.testing.expectEqual(@as(?Event, null), try input.next());
}

test "push rejects an overflow" {
    var input: Input = .{};
    const big = [_]u8{'a'} ** (Input.capacity + 1);
    try std.testing.expectError(error.Overflow, input.push(&big));
}
