const std = @import("std");
const builtin = @import("builtin");
const xvaxis = @import("xvaxis/main.zig");
const Tty = @import("tty.zig").Tty;

pub const Event = xvaxis.Event;
pub const Key = xvaxis.Key;

/// The end marker of a bracketed paste. The terminal must not send this marker inside paste data.
const paste_end = "\x1b[201~";

/// Decode terminal bytes into events.
pub const Input = struct {
    parser: xvaxis.Parser = .{},
    buffer: [capacity]u8 = undefined,
    len: usize = 0,
    /// Keep key text across buffer compaction.
    text_buf: [128]u8 = undefined,
    /// Set the allocator for paste text. A null allocator drops the paste text.
    gpa: ?std.mem.Allocator = null,
    /// The bytes between the paste markers. `next` returns them as one `paste` event.
    paste_buf: std.ArrayList(u8) = .empty,
    in_paste: bool = false,

    pub const capacity = 4096;

    /// The paste keeps this many bytes. `Input` counts and discards the bytes after the cap.
    /// A large log or a generated source file stays below this size.
    pub const paste_max = 2 << 20;

    pub fn deinit(self: *Input) void {
        const gpa = self.gpa orelse return;
        self.paste_buf.deinit(gpa);
        self.paste_buf = .empty;
    }

    /// Drop the buffered bytes and the partial paste. The caller uses this after a decode error.
    pub fn reset(self: *Input) void {
        self.len = 0;
        self.in_paste = false;
        self.paste_buf.clearRetainingCapacity();
    }

    /// Append bytes. Return `error.Overflow` when the buffer is full.
    pub fn push(self: *Input, bytes: []const u8) error{Overflow}!void {
        if (bytes.len > self.buffer.len - self.len) return error.Overflow;
        @memcpy(self.buffer[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }

    /// Read the next event from the TTY. The reactor waits when no event exists.
    /// The Windows console gives decoded events, so a paste stays one key event per character.
    pub fn readEvent(self: *Input, tty: *Tty) !Event {
        switch (builtin.os.tag) {
            .windows => {
                const event = try tty.nextEvent(&self.parser, self.gpa);
                return self.stabilizeText(event);
            },
            else => {
                while (true) {
                    if (try self.next()) |event| return event;
                    var buf: [512]u8 = undefined;
                    const n = try tty.read(&buf);
                    if (n == 0) return error.EndOfStream;
                    try self.push(buf[0..n]);
                }
            },
        }
    }

    /// Return the next complete event. Skip unknown sequences and keep incomplete bytes.
    /// The paste markers stay inside `Input`. A bracketed paste becomes one `paste` event.
    pub fn next(self: *Input) !?Event {
        while (self.len > 0) {
            if (self.in_paste) {
                if (!try self.collectPaste()) return null;
                const gpa = self.gpa orelse continue;
                sanitize(&self.paste_buf);
                return .{ .paste = try self.paste_buf.toOwnedSlice(gpa) };
            }
            const result = try self.parser.parse(self.buffer[0..self.len], self.gpa);
            if (result.n == 0) return null;
            const event = if (result.event) |e| self.stabilizeText(e) else null;
            self.consume(result.n);
            const ev = event orelse continue;
            switch (ev) {
                .paste_start => {
                    self.in_paste = true;
                    self.paste_buf.clearRetainingCapacity();
                },
                .paste_end => {},
                else => return ev,
            }
        }
        return null;
    }

    /// Copy the paste bytes up to the end marker. Return false when the buffer has no end marker.
    /// Only the end marker ends a paste, so paste data can never decode as a key.
    fn collectPaste(self: *Input) !bool {
        std.debug.assert(self.in_paste);
        const buf = self.buffer[0..self.len];
        if (std.mem.find(u8, buf, paste_end)) |i| {
            try self.appendPaste(buf[0..i]);
            self.consume(i + paste_end.len);
            self.in_paste = false;
            return true;
        }
        // Keep the last bytes, because they can be the start of the end marker.
        const keep = @min(buf.len, paste_end.len - 1);
        try self.appendPaste(buf[0 .. buf.len - keep]);
        self.consume(buf.len - keep);
        return false;
    }

    /// Append the paste bytes up to the cap. The function drops the bytes over it.
    fn appendPaste(self: *Input, bytes: []const u8) !void {
        const gpa = self.gpa orelse return;
        const room = paste_max - @min(paste_max, self.paste_buf.items.len);
        try self.paste_buf.appendSlice(gpa, bytes[0..@min(bytes.len, room)]);
    }

    /// Drop the first `n` bytes of the buffer.
    fn consume(self: *Input, n: usize) void {
        std.debug.assert(n <= self.len);
        @memmove(self.buffer[0 .. self.len - n], self.buffer[n..self.len]);
        self.len -= n;
    }

    /// Copy key text before buffer compaction. The parser borrows this text.
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

/// Replace CR and CRLF with LF, and drop the other control bytes.
/// The renderer writes cell bytes to the terminal, so a control byte can damage the screen.
fn sanitize(buf: *std.ArrayList(u8)) void {
    var w: usize = 0;
    var i: usize = 0;
    while (i < buf.items.len) : (i += 1) {
        const b = buf.items[i];
        if (b == '\r' and i + 1 < buf.items.len and buf.items[i + 1] == '\n') i += 1;
        const out: u8 = if (b == '\r') '\n' else b;
        // Keep the tab and the line feed. A byte over 0x7F is part of a UTF-8 sequence.
        if (out < 0x20 and out != '\t' and out != '\n') continue;
        if (out == 0x7f) continue;
        buf.items[w] = out;
        w += 1;
    }
    std.debug.assert(w <= buf.items.len);
    buf.shrinkRetainingCapacity(w);
}

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

test "a bracketed paste is one event" {
    var input: Input = .{ .gpa = std.testing.allocator };
    defer input.deinit();
    try input.push("\x1b[200~hello world\x1b[201~");
    const event = (try input.next()).?;
    defer std.testing.allocator.free(event.paste);
    try std.testing.expectEqualStrings("hello world", event.paste);
    try std.testing.expectEqual(@as(?Event, null), try input.next());
}

test "a key after a paste still decodes" {
    var input: Input = .{ .gpa = std.testing.allocator };
    defer input.deinit();
    try input.push("\x1b[200~x\x1b[201~y");
    const event = (try input.next()).?;
    std.testing.allocator.free(event.paste);
    try std.testing.expectEqual(@as(u21, 'y'), (try input.next()).?.key_press.codepoint);
}

test "a paste that splits across reads keeps every byte" {
    var input: Input = .{ .gpa = std.testing.allocator };
    defer input.deinit();
    // The last push splits the end marker, so the scan must hold the partial marker.
    try input.push("\x1b[200~one");
    try std.testing.expectEqual(@as(?Event, null), try input.next());
    try input.push(" two\x1b[2");
    try std.testing.expectEqual(@as(?Event, null), try input.next());
    try input.push("01~");
    const event = (try input.next()).?;
    defer std.testing.allocator.free(event.paste);
    try std.testing.expectEqualStrings("one two", event.paste);
}

test "a paste turns CR and CRLF into LF" {
    var input: Input = .{ .gpa = std.testing.allocator };
    defer input.deinit();
    try input.push("\x1b[200~a\rb\r\nc\nd\x1b[201~");
    const event = (try input.next()).?;
    defer std.testing.allocator.free(event.paste);
    try std.testing.expectEqualStrings("a\nb\nc\nd", event.paste);
}

test "a paste over the cap keeps the first bytes and drops the rest" {
    var input: Input = .{ .gpa = std.testing.allocator };
    defer input.deinit();
    try input.push("\x1b[200~");
    try std.testing.expectEqual(@as(?Event, null), try input.next());

    const chunk = [_]u8{'a'} ** 4000;
    var sent: usize = 0;
    while (sent < Input.paste_max + chunk.len) : (sent += chunk.len) {
        try input.push(&chunk);
        // The cap never ends the paste. Only the end marker does.
        try std.testing.expectEqual(@as(?Event, null), try input.next());
        try std.testing.expect(input.in_paste);
    }

    try input.push("\x1b[201~q");
    const event = (try input.next()).?;
    defer std.testing.allocator.free(event.paste);
    try std.testing.expectEqual(Input.paste_max, event.paste.len);
    try std.testing.expectEqual(@as(u21, 'q'), (try input.next()).?.key_press.codepoint);
}

test "a paste without an allocator is dropped" {
    var input: Input = .{};
    defer input.deinit();
    try input.push("\x1b[200~hello\x1b[201~z");
    try std.testing.expectEqual(@as(u21, 'z'), (try input.next()).?.key_press.codepoint);
}

test "a paste without an allocator holds no memory" {
    var input: Input = .{};
    defer input.deinit();
    try input.push("\x1b[200~");
    try std.testing.expectEqual(@as(?Event, null), try input.next());

    const chunk = [_]u8{'a'} ** 4000;
    try input.push(&chunk);
    try std.testing.expectEqual(@as(?Event, null), try input.next());
    try std.testing.expectEqual(@as(usize, 0), input.paste_buf.items.len);

    try input.push("\x1b[201~q");
    try std.testing.expectEqual(@as(u21, 'q'), (try input.next()).?.key_press.codepoint);
}

test "a paste drops the control bytes and keeps the tab" {
    var input: Input = .{ .gpa = std.testing.allocator };
    defer input.deinit();
    try input.push("\x1b[200~a\x1b[31mb\tc\x07\x7fd\x1b[201~");
    const event = (try input.next()).?;
    defer std.testing.allocator.free(event.paste);
    try std.testing.expectEqualStrings("a[31mb\tcd", event.paste);
}

test "a paste keeps multi-byte UTF-8" {
    var input: Input = .{ .gpa = std.testing.allocator };
    defer input.deinit();
    try input.push("\x1b[200~héllo 🙂\x1b[201~");
    const event = (try input.next()).?;
    defer std.testing.allocator.free(event.paste);
    try std.testing.expectEqualStrings("héllo 🙂", event.paste);
}

test "reset drops a partial paste" {
    var input: Input = .{ .gpa = std.testing.allocator };
    defer input.deinit();
    try input.push("\x1b[200~partial");
    try std.testing.expectEqual(@as(?Event, null), try input.next());
    try std.testing.expect(input.in_paste);
    input.reset();
    try std.testing.expect(!input.in_paste);
    try input.push("q");
    try std.testing.expectEqual(@as(u21, 'q'), (try input.next()).?.key_press.codepoint);
}

test "push rejects an overflow" {
    var input: Input = .{};
    const big = [_]u8{'a'} ** (Input.capacity + 1);
    try std.testing.expectError(error.Overflow, input.push(&big));
}
