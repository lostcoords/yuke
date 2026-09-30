const std = @import("std");
const term = @import("term");

/// Rows use the native Int32Array layout; soft is zero or one.
pub const Row = extern struct { start: i32, end: i32, soft: i32 };
pub const Result = struct {
    rows: std.ArrayList(Row) = .empty,
    omitted: bool = false,
    graphemes: u64 = 0,
};

/// A zero head retains every row; a positive head retains that prefix and an optional tail.
pub fn wrap(gpa: std.mem.Allocator, source: []const u8, width: i32, head: usize, tail: usize) !Result {
    std.debug.assert(head > 0 or tail == 0);
    var result: Result = .{};
    errdefer result.rows.deinit(gpa);
    var tail_index: usize = 0;
    if (width <= 0) {
        _ = try emit(gpa, &result, .{ .start = 0, .end = utf16Len(source), .soft = 0 }, head, tail, &tail_index);
        return result;
    }
    var start: i32 = 0;
    var offset: i32 = 0;
    var cells: i64 = 0;
    var break_at: i32 = -1;
    var break_cells: i64 = 0;
    var i: usize = 0;
    while (i < source.len) {
        const g = graphemeAt(source, i);
        const bytes = source[i .. i + g.len];
        i += g.len;
        const len = utf16Len(bytes);
        result.graphemes += 1;
        if (std.mem.eql(u8, bytes, "\n")) {
            if (!try emit(gpa, &result, .{ .start = start, .end = offset, .soft = 0 }, head, tail, &tail_index)) return result;
            start = offset + len;
            cells = 0;
            break_at = -1;
        } else {
            const space = std.mem.eql(u8, bytes, " ");
            const cell_width = g.width;
            if (!space and cells + cell_width > width and offset > start) {
                const end = if (break_at > start) break_at else offset;
                if (!try emit(gpa, &result, .{ .start = start, .end = end, .soft = 1 }, head, tail, &tail_index)) return result;
                cells = if (break_at > start) cells - break_cells else 0;
                start = end;
                break_at = -1;
            }
            cells += cell_width;
            if (space) {
                break_at = offset + len;
                break_cells = cells;
            }
        }
        offset += len;
    }
    _ = try emit(gpa, &result, .{ .start = start, .end = offset, .soft = 0 }, head, tail, &tail_index);
    if (tail_index > 0) std.mem.rotate(Row, result.rows.items[head..], tail_index);
    std.debug.assert(head == 0 or result.rows.items.len <= head + tail);
    return result;
}

fn emit(gpa: std.mem.Allocator, result: *Result, row: Row, head: usize, tail: usize, tail_index: *usize) !bool {
    std.debug.assert(row.start >= 0 and row.end >= row.start);
    std.debug.assert(row.soft == 0 or row.soft == 1);
    if (head == 0 or result.rows.items.len < head + tail) {
        try result.rows.append(gpa, row);
        return true;
    }
    result.omitted = true;
    if (tail == 0) return false;
    std.debug.assert(tail_index.* < tail);
    result.rows.items[head + tail_index.*] = row;
    tail_index.* = (tail_index.* + 1) % tail;
    return true;
}

/// One grapheme: its length in bytes and its width in terminal cells.
pub const Grapheme = struct { len: usize, width: u16 };

/// The grapheme that starts at byte `i` of `source`. The caller keeps `i` on a grapheme boundary.
/// Printable ASCII before an ASCII byte or the end is a grapheme of one cell, because no rule joins two ASCII bytes but CR LF, so it skips the Unicode tables.
pub fn graphemeAt(source: []const u8, i: usize) Grapheme {
    std.debug.assert(i < source.len);
    const c = source[i];
    if (c >= 0x20 and c < 0x7f and (i + 1 == source.len or source[i + 1] < 0x80)) return .{ .len = 1, .width = 1 };
    const rest = source[i..];
    var it = term.unicode.graphemeIterator(rest);
    // A text that is not empty starts with a grapheme.
    const g = it.next() orelse unreachable;
    return .{ .len = g.len, .width = term.gwidth.gwidth(g.bytes(rest), .unicode) };
}

pub fn utf16Len(source: []const u8) i32 {
    var len: i32 = 0;
    var it: std.unicode.Utf8Iterator = .{ .bytes = source, .i = 0 };
    while (it.nextCodepoint()) |cp| len += if (cp > 0xffff) 2 else 1;
    return len;
}

test "prefix and tail wraps preserve full row offsets with bounded storage" {
    const gpa = std.testing.allocator;
    for ([_][]const u8{ "", "one two three\nlast", "a  b\n\n", "世界 é 👩‍💻\nend", "a\r\nb\t c", "    end " }) |source| {
        for (1..9) |width| {
            var full = try wrap(gpa, source, @intCast(width), 0, 0);
            defer full.rows.deinit(gpa);
            for (1..4) |head| {
                for (0..4) |tail| {
                    var bounded = try wrap(gpa, source, @intCast(width), head, tail);
                    defer bounded.rows.deinit(gpa);
                    const count = full.rows.items.len;
                    try std.testing.expectEqual(count > head + tail, bounded.omitted);
                    const prefix = @min(count, head);
                    try std.testing.expectEqualSlices(Row, full.rows.items[0..prefix], bounded.rows.items[0..prefix]);
                    const suffix = @min(count - prefix, tail);
                    try std.testing.expectEqualSlices(Row, full.rows.items[count - suffix ..], bounded.rows.items[prefix..]);
                }
            }
        }
    }
}

test "the ASCII fast path finds the graphemes and widths of the Unicode rules" {
    var ascii: [0x5f]u8 = undefined;
    for (&ascii, 0..) |*c, k| c.* = @intCast(0x20 + k);
    for ([_][]const u8{ &ascii, "a\r\nb\tc", "e\u{301}x", "x\u{200d}y", "ab 世界 é 👩‍💻.", "A\u{1f1ef}\u{1f1f5}B", "\x1b[0mz" }) |source| {
        var it = term.unicode.graphemeIterator(source);
        var i: usize = 0;
        while (it.next()) |want| {
            const got = graphemeAt(source, i);
            try std.testing.expectEqual(want.start, i);
            try std.testing.expectEqual(want.len, got.len);
            try std.testing.expectEqual(term.gwidth.gwidth(want.bytes(source), .unicode), got.width);
            i += got.len;
        }
        try std.testing.expectEqual(source.len, i);
    }
}
