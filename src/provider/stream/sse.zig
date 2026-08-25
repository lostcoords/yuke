//! The SSE framer converts raw bytes into `data` payloads. A blank line emits a payload.
//! It joins `data:` fields with a newline and ignores `event:` because providers encode the type in JSON.
//!
//! Line endings are LF, CRLF, and a lone CR, per the SSE specification.

const std = @import("std");

/// Maximum size for one line and one event payload. Larger peer input returns an error.
pub const max_bytes = 1 << 20;

pub const Error = error{ LineTooLong, EventTooLarge, OutOfMemory };

/// The framer owns two buffers across calls. It copies each complete payload into the caller's arena.
pub const Sse = struct {
    gpa: std.mem.Allocator,
    line: std.ArrayList(u8) = .empty,
    data: std.ArrayList(u8) = .empty,
    /// True when the current event has a `data:` field.
    data_seen: bool = false,
    /// True before the first complete line. The first line may start with a BOM.
    at_start: bool = true,
    /// True when the previous byte was a CR. A following LF completes the CRLF ending.
    saw_cr: bool = false,

    pub fn init(gpa: std.mem.Allocator) Sse {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Sse) void {
        self.line.deinit(self.gpa);
        self.data.deinit(self.gpa);
        self.* = undefined;
    }

    /// Appends complete payloads to `out` in input order. `arena` owns the payloads.
    pub fn push(
        self: *Sse,
        bytes: []const u8,
        arena: std.mem.Allocator,
        out: *std.ArrayList([]const u8),
    ) Error!void {
        for (bytes) |b| {
            // A CR ends a line. A following LF is the second half of a CRLF ending.
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

    /// Completes the final line at EOF. It drops an event without a blank terminator.
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
        if (line[0] == ':') return; // SSE comment line

        const colon = std.mem.indexOfScalar(u8, line, ':');
        const field = if (colon) |c| line[0..c] else line;
        var value = if (colon) |c| line[c + 1 ..] else line[line.len..];
        if (value.len != 0 and value[0] == ' ') value = value[1..];

        if (!std.mem.eql(u8, field, "data")) return; // Ignore non-data fields

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

/// Returns payloads from `chunks` in input order.
fn frame(chunks: []const []const u8, arena: std.mem.Allocator) ![]const []const u8 {
    var sse = Sse.init(testing.allocator);
    defer sse.deinit();
    var out: std.ArrayList([]const u8) = .empty;
    for (chunks) |c| try sse.push(c, arena, &out);
    try sse.finish(arena, &out);
    return out.items;
}

test "one event, one push" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const events = try frame(&.{"data: {\"type\":\"ping\"}\n\n"}, arena.allocator());
    try testing.expectEqual(@as(usize, 1), events.len);
    try testing.expectEqualStrings("{\"type\":\"ping\"}", events[0]);
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
    const whole = "data: {\"x\":1}\r\n\r\ndata: {\"y\":2}\r\n\r\n";
    var singles: [whole.len][]const u8 = undefined;
    for (whole, 0..) |_, i| {
        singles[i] = whole[i .. i + 1];
    }
    const events = try frame(&singles, arena.allocator());
    try testing.expectEqual(@as(usize, 2), events.len);
    try testing.expectEqualStrings("{\"x\":1}", events[0]);
    try testing.expectEqualStrings("{\"y\":2}", events[1]);
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

test "[DONE] sentinel surfaces as a data payload" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const events = try frame(&.{"data: [DONE]\n\n"}, arena.allocator());
    try testing.expectEqual(@as(usize, 1), events.len);
    try testing.expectEqualStrings("[DONE]", events[0]);
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

test "output is identical across every split point" {
    const whole = "data: {\"a\":1}\n\ndata: {\"b\":2}\n\ndata: [DONE]\n\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const one_shot = try frame(&.{whole}, arena.allocator());

    for (0..whole.len + 1) |k| {
        var split_arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer split_arena.deinit();
        const split = try frame(&.{ whole[0..k], whole[k..] }, split_arena.allocator());
        try testing.expectEqual(one_shot.len, split.len);
        for (one_shot, split) |a, b| try testing.expectEqualStrings(a, b);
    }
}
