//! Split a text into lines and intern each line to an identifier. Myers compares the identifiers.

const std = @import("std");

/// The lines of one text. `text[i]` holds the bytes of line `i` without the line feed. Two entries of
/// `ids` are equal only when the two lines hold the same bytes. Both slices borrow the allocator.
pub const Lines = struct {
    text: []const []const u8,
    ids: []const u32,
};

/// The intern table. It maps a line to one identifier across both texts, so the two identifier arrays
/// compare directly. The keys borrow the input texts, so both texts must outlive the table.
pub const Table = struct {
    map: std.StringHashMapUnmanaged(u32) = .empty,
    next: u32 = 0,

    pub fn deinit(self: *Table, gpa: std.mem.Allocator) void {
        self.map.deinit(gpa);
    }

    fn intern(self: *Table, gpa: std.mem.Allocator, line: []const u8) !u32 {
        std.debug.assert(self.next < std.math.maxInt(u32));
        const entry = try self.map.getOrPut(gpa, line);
        if (!entry.found_existing) {
            entry.value_ptr.* = self.next;
            self.next += 1;
        }
        std.debug.assert(entry.value_ptr.* < self.next); // every identifier is below the next free one
        return entry.value_ptr.*;
    }
};

/// Split `text` on a line feed and intern each line. A carriage return stays in the line, so a
/// line-ending change shows as a changed line. A final line feed adds no empty last line.
pub fn split(gpa: std.mem.Allocator, table: *Table, text: []const u8) !Lines {
    var out_text: std.ArrayList([]const u8) = .empty;
    var out_ids: std.ArrayList(u32) = .empty;

    var start: usize = 0;
    while (start < text.len) {
        const stop = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
        const line = text[start..stop];
        try out_text.append(gpa, line);
        try out_ids.append(gpa, try table.intern(gpa, line));
        start = stop + 1;
    }

    std.debug.assert(out_text.items.len == out_ids.items.len); // one id per line
    return .{ .text = out_text.items, .ids = out_ids.items };
}

/// Count the lines of `text` without an allocation. `split` returns the same count.
pub fn count(text: []const u8) usize {
    if (text.len == 0) return 0;
    var n: usize = 1;
    for (text) |c| {
        if (c == '\n') n += 1;
    }
    return if (text[text.len - 1] == '\n') n - 1 else n;
}

const testing = std.testing;

test "split returns one line per line feed and drops the final empty line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var table: Table = .{};
    defer table.deinit(a);

    const lines = try split(a, &table, "one\ntwo\nthree\n");
    try testing.expectEqual(@as(usize, 3), lines.text.len);
    try testing.expectEqualStrings("one", lines.text[0]);
    try testing.expectEqualStrings("three", lines.text[2]);
}

test "split keeps a last line without a line feed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var table: Table = .{};
    defer table.deinit(a);

    const lines = try split(a, &table, "one\ntwo");
    try testing.expectEqual(@as(usize, 2), lines.text.len);
    try testing.expectEqualStrings("two", lines.text[1]);
}

test "split gives an empty text no lines and a single line feed one empty line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var table: Table = .{};
    defer table.deinit(a);

    try testing.expectEqual(@as(usize, 0), (try split(a, &table, "")).text.len);
    const one = try split(a, &table, "\n");
    try testing.expectEqual(@as(usize, 1), one.text.len);
    try testing.expectEqualStrings("", one.text[0]);
}

test "split keeps a carriage return in the line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var table: Table = .{};
    defer table.deinit(a);

    const lines = try split(a, &table, "one\r\ntwo\r\n");
    try testing.expectEqualStrings("one\r", lines.text[0]);
    // A line-ending change gives a different identifier, so the result reports a changed line.
    const plain = try split(a, &table, "one\n");
    try testing.expect(lines.ids[0] != plain.ids[0]);
}

test "the table gives one identifier to equal lines across both texts" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var table: Table = .{};
    defer table.deinit(a);

    const old = try split(a, &table, "alpha\nbeta\n");
    const new = try split(a, &table, "beta\nalpha\n");
    try testing.expectEqual(old.ids[0], new.ids[1]);
    try testing.expectEqual(old.ids[1], new.ids[0]);
    try testing.expect(old.ids[0] != old.ids[1]);
}

test "count matches the split line count" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var table: Table = .{};
    defer table.deinit(a);

    for ([_][]const u8{ "", "\n", "a", "a\n", "a\nb", "a\nb\n", "\n\n" }) |text| {
        const lines = try split(a, &table, text);
        try testing.expectEqual(lines.text.len, count(text));
    }
}

test "a text of line feeds gives one empty line for each feed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var table: Table = .{};
    defer table.deinit(a);

    const three = try split(a, &table, "\n\n\n");
    try testing.expectEqual(@as(usize, 3), three.text.len);
    // Every empty line shares one identifier.
    try testing.expectEqual(three.ids[0], three.ids[1]);
    try testing.expectEqual(three.ids[0], three.ids[2]);
}
