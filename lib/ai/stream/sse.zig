//! Convert SSE bytes into `data` payloads, joined with a newline and emitted on a blank line.

const std = @import("std");

/// This bound is transport, not protocol, because a frame holds an escaped JSON envelope. Larger peer input returns an error.
pub const max_bytes = 1 << 20;

pub const Error = error{ LineTooLong, EventTooLarge, ResponseTooLarge, OutOfMemory };

/// Return the index of the next line terminator. A chunk that holds none answers its length.
fn lineEnd(bytes: []const u8) usize {
    // A single-byte search uses SIMD, so two passes cost less than one search for both terminators.
    const lf = std.mem.findScalar(u8, bytes, '\n') orelse
        return std.mem.findScalar(u8, bytes, '\r') orelse bytes.len;
    return std.mem.findScalar(u8, bytes[0..lf], '\r') orelse lf;
}

/// The parser holds one line buffer and one payload buffer across calls. It borrows the source bytes.
pub const Sse = struct {
    gpa: std.mem.Allocator,
    /// Cap the whole response so one turn cannot grow memory without bound.
    max_total: usize,
    line: std.ArrayList(u8) = .empty,
    data: std.ArrayList(u8) = .empty,
    /// This field counts the bytes the parser read from the source.
    total: usize = 0,
    /// This flag is true before the first complete line. The first line may start with a BOM.
    at_start: bool = true,
    /// This flag is true when the previous byte was a CR. The next LF completes the CRLF terminator.
    saw_cr: bool = false,

    pub fn init(gpa: std.mem.Allocator, max_total: usize) Sse {
        std.debug.assert(max_total != 0);
        return .{ .gpa = gpa, .max_total = max_total };
    }

    pub fn deinit(self: *Sse) void {
        self.line.deinit(self.gpa);
        self.data.deinit(self.gpa);
        self.* = undefined;
    }

    /// Return the next payload, or null at the end of the stream. The bytes stay valid until the next call.
    pub fn next(self: *Sse, source: anytype) !?[]const u8 {
        self.data.clearRetainingCapacity();
        var data_seen = false;
        while (true) {
            const line = (try self.readLine(source)) orelse {
                // The end of the stream is not an event boundary, so the parser drops a payload without a blank line.
                return null;
            };
            if (line.len == 0) {
                if (data_seen) return self.data.items;
                continue;
            }
            if (line[0] == ':') continue; // Ignore an SSE comment line.

            const colon = std.mem.findScalar(u8, line, ':');
            const field = if (colon) |c| line[0..c] else line;
            var value = if (colon) |c| line[c + 1 ..] else line[line.len..];
            if (value.len != 0 and value[0] == ' ') value = value[1..];
            if (!std.mem.eql(u8, field, "data")) continue; // Ignore a non-data field.

            if (data_seen) try self.appendData("\n");
            try self.appendData(value);
            data_seen = true;
        }
    }

    /// Return one line without its terminator, or null at the end of the stream.
    fn readLine(self: *Sse, source: anytype) !?[]const u8 {
        self.line.clearRetainingCapacity();
        while (true) {
            var bytes = try source.peek();
            if (bytes.len == 0) return null; // The source reached the end of the stream.

            // A CR ended the previous line. The next LF is the second half of a CRLF terminator.
            if (self.saw_cr) {
                self.saw_cr = false;
                if (bytes[0] == '\n') {
                    try self.consume(source, 1);
                    bytes = bytes[1..];
                    if (bytes.len == 0) continue;
                }
            }

            const end = lineEnd(bytes);
            if (end > max_bytes - self.line.items.len) return error.LineTooLong;
            if (end == bytes.len) {
                // The line runs past the source bytes, so the parser must copy it into the line buffer.
                try self.line.appendSlice(self.gpa, bytes);
                try self.consume(source, bytes.len);
                continue;
            }
            self.saw_cr = bytes[end] == '\r';
            // Only the next peek can replace the peeked bytes, so a toss keeps them readable.
            try self.consume(source, end + 1);
            if (self.line.items.len == 0) return self.strip(bytes[0..end]);
            try self.line.appendSlice(self.gpa, bytes[0..end]);
            return self.strip(self.line.items);
        }
    }

    /// Drop the byte-order mark that can lead the first line of a response.
    fn strip(self: *Sse, line: []const u8) []const u8 {
        defer self.at_start = false;
        if (self.at_start and std.mem.startsWith(u8, line, "\xEF\xBB\xBF")) return line[3..];
        return line;
    }

    fn consume(self: *Sse, source: anytype, count: usize) !void {
        if (count > self.max_total - self.total) return error.ResponseTooLarge;
        self.total += count;
        source.toss(count);
    }

    fn appendData(self: *Sse, bytes: []const u8) Error!void {
        if (bytes.len > max_bytes - self.data.items.len) return error.EventTooLarge;
        try self.data.appendSlice(self.gpa, bytes);
        std.debug.assert(self.data.items.len <= max_bytes);
    }
};

const testing = std.testing;

/// This test source answers every peek with the bytes of its current chunk.
const ChunkSource = struct {
    chunks: []const []const u8,
    index: usize = 0,
    offset: usize = 0,

    fn peek(self: *ChunkSource) ![]const u8 {
        while (self.index < self.chunks.len) : (self.index += 1) {
            const chunk = self.chunks[self.index];
            if (self.offset < chunk.len) return chunk[self.offset..];
            self.offset = 0;
        }
        return "";
    }

    fn toss(self: *ChunkSource, count: usize) void {
        std.debug.assert(self.offset + count <= self.chunks[self.index].len);
        self.offset += count;
    }
};

/// Return payloads from `chunks` in input order. This helper copies each payload, because `next` reuses its buffer.
fn frame(chunks: []const []const u8, arena: std.mem.Allocator) ![]const []const u8 {
    var source: ChunkSource = .{ .chunks = chunks };
    var sse = Sse.init(testing.allocator, std.math.maxInt(usize));
    defer sse.deinit();
    var out: std.ArrayList([]const u8) = .empty;
    while (try sse.next(&source)) |payload| try out.append(arena, try arena.dupe(u8, payload));
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

test "a CR and LF split across peeks is one ending" {
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

test "incomplete trailing event is dropped at end of stream" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const events = try frame(&.{"data: {\"done\":1}\n\ndata: partial"}, arena.allocator());
    try testing.expectEqual(@as(usize, 1), events.len);
    try testing.expectEqualStrings("{\"done\":1}", events[0]);
}

test "an oversized line degrades to an error, never a crash" {
    var sse = Sse.init(testing.allocator, std.math.maxInt(usize));
    defer sse.deinit();
    const big = "data: " ++ ("x" ** (max_bytes + 8));
    var source: ChunkSource = .{ .chunks = &.{big} };
    try testing.expectError(error.LineTooLong, sse.next(&source));
}

test "a response above the total cap stops instead of growing" {
    var sse = Sse.init(testing.allocator, 8);
    defer sse.deinit();
    var source: ChunkSource = .{ .chunks = &.{"data: 0123456789\n\n"} };
    try testing.expectError(error.ResponseTooLarge, sse.next(&source));
}

test "one payload split over many peeks reads as one line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Each chunk ends mid-line, so every payload needs the line buffer.
    const events = try frame(&.{ "data: {\"a\":", "1,\"b\":", "2}\n", "\n" }, arena.allocator());
    try testing.expectEqual(@as(usize, 1), events.len);
    try testing.expectEqualStrings("{\"a\":1,\"b\":2}", events[0]);
}
