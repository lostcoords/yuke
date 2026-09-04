//! Convert SSE bytes into `data` payloads, joined with a newline and emitted on a blank line.

const std = @import("std");

/// This bound is transport, not protocol, because a frame holds an escaped JSON envelope. Larger peer input returns an error.
pub const max_bytes = 1 << 20;

pub const Error = error{ LineTooLong, EventTooLarge, OutOfMemory };

/// The framer owns two buffers across calls. It copies each complete payload into the caller's arena.
pub const Sse = struct {
    gpa: std.mem.Allocator,
    line: std.ArrayList(u8) = .empty,
    data: std.ArrayList(u8) = .empty,
    /// This flag is true when the current event has a `data:` field.
    data_seen: bool = false,
    /// This flag is true before the first complete line. The first line may start with a BOM.
    at_start: bool = true,
    /// This flag is true when the previous byte was a CR. The next LF completes the CRLF terminator.
    saw_cr: bool = false,

    pub fn init(gpa: std.mem.Allocator) Sse {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Sse) void {
        self.line.deinit(self.gpa);
        self.data.deinit(self.gpa);
        self.* = undefined;
    }

    /// Append complete payloads to `out` in input order. `arena` owns the payloads.
    pub fn push(
        self: *Sse,
        bytes: []const u8,
        arena: std.mem.Allocator,
        out: *std.ArrayList([]const u8),
    ) Error!void {
        for (bytes) |b| {
            // A CR ends a line. The next LF is the second half of a CRLF terminator.
            if (self.saw_cr) {
                self.saw_cr = false;
                if (b == '\n') continue;
            }
            switch (b) {
                '\r' => {
                    self.saw_cr = true;
                    try self.completeLine(arena, out);
                },
                '\n' => try self.completeLine(arena, out),
                else => {
                    if (self.line.items.len >= max_bytes) return error.LineTooLong;
                    try self.line.append(self.gpa, b);
                    std.debug.assert(self.line.items.len <= max_bytes);
                },
            }
        }
    }

    /// Complete the final line at EOF. Drop an event without a blank terminator.
    pub fn finish(
        self: *Sse,
        arena: std.mem.Allocator,
        out: *std.ArrayList([]const u8),
    ) Error!void {
        if (self.line.items.len != 0) try self.completeLine(arena, out);
    }

    fn completeLine(
        self: *Sse,
        arena: std.mem.Allocator,
        out: *std.ArrayList([]const u8),
    ) Error!void {
        var line: []const u8 = self.line.items;
        if (self.at_start and std.mem.startsWith(u8, line, "\xEF\xBB\xBF")) line = line[3..];
        self.at_start = false;

        try self.processFields(line, arena, out);
        self.line.clearRetainingCapacity();
    }

    fn processFields(
        self: *Sse,
        line: []const u8,
        arena: std.mem.Allocator,
        out: *std.ArrayList([]const u8),
    ) Error!void {
        if (line.len == 0) {
            if (self.data_seen) {
                try out.append(arena, try arena.dupe(u8, self.data.items));
                self.data.clearRetainingCapacity();
                self.data_seen = false;
            }
            return;
        }
        if (line[0] == ':') return; // Ignore an SSE comment line.

        const colon = std.mem.indexOfScalar(u8, line, ':');
        const field = if (colon) |c| line[0..c] else line;
        var value = if (colon) |c| line[c + 1 ..] else line[line.len..];
        if (value.len != 0 and value[0] == ' ') value = value[1..];

        if (!std.mem.eql(u8, field, "data")) return; // Ignore a non-data field.

        if (self.data_seen) try self.appendData("\n");
        try self.appendData(value);
        self.data_seen = true;
    }

    fn appendData(self: *Sse, bytes: []const u8) Error!void {
        if (bytes.len > max_bytes - self.data.items.len) return error.EventTooLarge;
        try self.data.appendSlice(self.gpa, bytes);
        std.debug.assert(self.data.items.len <= max_bytes);
    }
};

const testing = std.testing;

/// Return payloads from `chunks` in input order.
fn frame(chunks: []const []const u8, arena: std.mem.Allocator) ![]const []const u8 {
    var sse = Sse.init(testing.allocator);
    defer sse.deinit();
    var out: std.ArrayList([]const u8) = .empty;
    for (chunks) |c| try sse.push(c, arena, &out);
    try sse.finish(arena, &out);
    return out.items;
}

test "event: line is ignored, type read from data" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const events = try frame(&.{"event: message_start\ndata: {\"a\":1}\n\n"}, arena.allocator());
    try testing.expectEqual(@as(usize, 1), events.len);
    try testing.expectEqualStrings("{\"a\":1}", events[0]);
}

test "split at every byte boundary, including CRLF" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const whole = "data: {\"x\":1}\r\n\r\ndata: {\"y\":2}\r\n\r\ndata: [DONE]\r\n\r\n";
    var singles: [whole.len][]const u8 = undefined;
    for (whole, 0..) |_, i| {
        singles[i] = whole[i .. i + 1];
    }
    const events = try frame(&singles, arena.allocator());
    try testing.expectEqual(@as(usize, 3), events.len);
    try testing.expectEqualStrings("{\"x\":1}", events[0]);
    try testing.expectEqualStrings("{\"y\":2}", events[1]);
    try testing.expectEqualStrings("[DONE]", events[2]);
}

test "two CRLF data lines join with a newline" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Every other CRLF fixture holds one data line, where a dropped CR state reads the same.
    const events = try frame(&.{"data: a\r\ndata: b\r\n\r\n"}, arena.allocator());
    try testing.expectEqual(@as(usize, 1), events.len);
    try testing.expectEqualStrings("a\nb", events[0]);
}

test "a lone CR ends a line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const events = try frame(&.{"data: {\"x\":1}\r\rdata: {\"y\":2}\r\r"}, arena.allocator());
    try testing.expectEqual(@as(usize, 2), events.len);
    try testing.expectEqualStrings("{\"x\":1}", events[0]);
    try testing.expectEqualStrings("{\"y\":2}", events[1]);
}

test "a CR and LF split across pushes is one ending" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const events = try frame(&.{ "data: hi\r", "\n\r\n" }, arena.allocator());
    try testing.expectEqual(@as(usize, 1), events.len);
    try testing.expectEqualStrings("hi", events[0]);
}

test "multi-line data concatenates with newline" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const events = try frame(&.{"data: a\ndata: b\n\n"}, arena.allocator());
    try testing.expectEqual(@as(usize, 1), events.len);
    try testing.expectEqualStrings("a\nb", events[0]);
}

test "leading BOM is stripped once" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const events = try frame(&.{"\xEF\xBB\xBFdata: hi\n\n"}, arena.allocator());
    try testing.expectEqual(@as(usize, 1), events.len);
    try testing.expectEqualStrings("hi", events[0]);
}

test "incomplete trailing event is dropped at finish" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const events = try frame(&.{"data: {\"done\":1}\n\ndata: partial"}, arena.allocator());
    try testing.expectEqual(@as(usize, 1), events.len);
    try testing.expectEqualStrings("{\"done\":1}", events[0]);
}

test "an oversized line degrades to an error, never a crash" {
    var sse = Sse.init(testing.allocator);
    defer sse.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var out: std.ArrayList([]const u8) = .empty;
    const big = "data: " ++ ("x" ** (max_bytes + 8));
    try testing.expectError(error.LineTooLong, sse.push(big, arena.allocator(), &out));
}
