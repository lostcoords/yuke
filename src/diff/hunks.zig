//! Group the edit runs into hunks. A hunk holds the changed lines plus the context lines around them.

const std = @import("std");
const diff = @import("diff.zig");
const myers = @import("myers.zig");

const Op = myers.Op;
const Edit = myers.Edit;

/// One display line of a hunk. `text` borrows the old text or the new text.
pub const Line = struct {
    op: Op,
    text: []const u8,
};

/// One hunk has 1-based start values as a unified difference states them; a side with no line has start 0 and count 0.
pub const Hunk = struct {
    old_start: u32,
    old_lines: u32,
    new_start: u32,
    new_lines: u32,
    lines: []const Line,
};

/// One display line before the group step. It names its line on each side it uses.
const Record = struct {
    op: Op,
    old_index: u32,
    new_index: u32,
};

/// Build the hunks of `edits`; `context` sets unchanged lines on each side, two changes join when at most `2 * context` unchanged lines separate them, and the result borrows `arena`, `old_text`, and `new_text`.
pub fn group(
    arena: std.mem.Allocator,
    edits: []const Edit,
    old_text: []const []const u8,
    new_text: []const []const u8,
    context: u32,
) error{OutOfMemory}![]const Hunk {
    const records = try expand(arena, edits);
    const span: usize = 2 * @as(usize, context); // widen, so a large context cannot overflow
    var out: std.ArrayList(Hunk) = .empty;

    var at: usize = 0;
    while (at < records.len) {
        if (records[at].op == .keep) {
            at += 1;
            continue;
        }
        // The group starts at the first changed record and grows over every short unchanged gap.
        const first = at;
        var last = at;
        var scan = at + 1;
        while (scan < records.len) {
            if (records[scan].op != .keep) {
                last = scan;
                scan += 1;
                continue;
            }
            const gap = keepRun(records, scan);
            std.debug.assert(gap > 0 and gap <= records.len - scan);
            if (scan + gap >= records.len or gap > span) break;
            scan += gap;
        }
        at = last + 1;

        const start = first - @min(first, @as(usize, context));
        const stop = @min(records.len, last + 1 + @as(usize, context));
        std.debug.assert(start <= first and last < stop); // the window holds the whole group
        try out.append(arena, try build(arena, records[start..stop], old_text, new_text));
    }
    return out.items;
}

fn keepRun(records: []const Record, at: usize) usize {
    std.debug.assert(at < records.len);
    std.debug.assert(records[at].op == .keep);
    var stop = at;
    while (stop < records.len and records[stop].op == .keep) stop += 1;
    return stop - at;
}

/// Turn one record window into a hunk.
fn build(
    arena: std.mem.Allocator,
    window: []const Record,
    old_text: []const []const u8,
    new_text: []const []const u8,
) error{OutOfMemory}!Hunk {
    std.debug.assert(window.len > 0);
    var hunk: Hunk = .{ .old_start = 0, .old_lines = 0, .new_start = 0, .new_lines = 0, .lines = &.{} };
    const lines = try arena.alloc(Line, window.len);

    for (window, lines) |record, *line| {
        std.debug.assert(record.op == .insert or record.old_index < old_text.len);
        std.debug.assert(record.op == .delete or record.new_index < new_text.len);
        const text = switch (record.op) {
            .insert => new_text[record.new_index],
            .keep, .delete => old_text[record.old_index],
        };
        if (record.op != .insert) {
            if (hunk.old_lines == 0) hunk.old_start = record.old_index + 1;
            hunk.old_lines += 1;
        }
        if (record.op != .delete) {
            if (hunk.new_lines == 0) hunk.new_start = record.new_index + 1;
            hunk.new_lines += 1;
        }
        line.* = .{
            .op = record.op,
            .text = text,
        };
    }

    std.debug.assert(hunk.old_lines > 0 or hunk.new_lines > 0); // a hunk shows at least one line
    hunk.lines = lines;
    return hunk;
}

fn expand(arena: std.mem.Allocator, edits: []const Edit) error{OutOfMemory}![]const Record {
    var total: usize = 0;
    for (edits) |edit| total += edit.len;

    const out = try arena.alloc(Record, total);
    var at: usize = 0;
    for (edits) |edit| {
        std.debug.assert(edit.len > 0); // a run always covers at least one line
        var step: u32 = 0;
        while (step < edit.len) : (step += 1) {
            out[at] = .{
                .op = edit.op,
                .old_index = edit.old_start + step,
                .new_index = edit.new_start + step,
            };
            at += 1;
        }
    }
    std.debug.assert(at == total); // every run contributes its whole length
    return out;
}

const testing = std.testing;

test "one changed line gives one hunk with context on both sides" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // The change is at line 3. One context line on each side gives the range 2..4, so `@@ -2,3 +2,3 @@`.
    const hunks = try diff.compare(arena.allocator(), "a\nb\nc\nd\ne\n", "a\nb\nX\nd\ne\n", .{ .context = 1 });
    try testing.expectEqual(@as(usize, 1), hunks.len);
    const h = hunks[0];
    try testing.expectEqual(@as(u32, 2), h.old_start);
    try testing.expectEqual(@as(u32, 3), h.old_lines);
    try testing.expectEqual(@as(u32, 2), h.new_start);
    try testing.expectEqual(@as(u32, 3), h.new_lines);

    try testing.expectEqual(@as(usize, 4), h.lines.len);
    try testing.expectEqual(Op.keep, h.lines[0].op);
    try testing.expectEqualStrings("b", h.lines[0].text);
    try testing.expectEqual(Op.delete, h.lines[1].op);
    try testing.expectEqualStrings("c", h.lines[1].text);
    try testing.expectEqual(Op.insert, h.lines[2].op);
    try testing.expectEqualStrings("X", h.lines[2].text);
    try testing.expectEqual(Op.keep, h.lines[3].op);
    try testing.expectEqualStrings("d", h.lines[3].text);
}

test "a new file gives one hunk with an empty old side" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const hunks = try diff.compare(arena.allocator(), "", "a\nb\n", .{});
    try testing.expectEqual(@as(usize, 1), hunks.len);
    try testing.expectEqual(@as(u32, 0), hunks[0].old_start);
    try testing.expectEqual(@as(u32, 0), hunks[0].old_lines);
    try testing.expectEqual(@as(u32, 1), hunks[0].new_start);
    try testing.expectEqual(@as(u32, 2), hunks[0].new_lines);
}

test "a deleted file gives one hunk with an empty new side" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const hunks = try diff.compare(arena.allocator(), "a\nb\n", "", .{});
    try testing.expectEqual(@as(usize, 1), hunks.len);
    try testing.expectEqual(@as(u32, 1), hunks[0].old_start);
    try testing.expectEqual(@as(u32, 2), hunks[0].old_lines);
    try testing.expectEqual(@as(u32, 0), hunks[0].new_start);
    try testing.expectEqual(@as(u32, 0), hunks[0].new_lines);
}

test "a context of zero shows the changed lines only" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const hunks = try diff.compare(arena.allocator(), "a\nb\nc\n", "a\nX\nc\n", .{ .context = 0 });
    try testing.expectEqual(@as(usize, 1), hunks.len);
    try testing.expectEqual(@as(usize, 2), hunks[0].lines.len);
    try testing.expectEqual(Op.delete, hunks[0].lines[0].op);
    try testing.expectEqual(Op.insert, hunks[0].lines[1].op);
}

test "a gap of two times the context joins and one more splits" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const old = "0\n1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n";

    // Four unchanged lines between the changes equal 2 * context, so the hunks join.
    const joined = "0\n1\nX\n3\n4\n5\n6\nY\n8\n9\n10\n11\n";
    try testing.expectEqual(@as(usize, 1), (try diff.compare(a, old, joined, .{ .context = 2 })).len);

    // Five unchanged lines exceed 2 * context, so the hunks split.
    const split = "0\n1\nX\n3\n4\n5\n6\n7\nY\n9\n10\n11\n";
    try testing.expectEqual(@as(usize, 2), (try diff.compare(a, old, split, .{ .context = 2 })).len);
}

test "a change on the last line clamps the trailing context" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const hunks = try diff.compare(arena.allocator(), "a\nb\nc\n", "a\nb\nX\n", .{ .context = 10 });
    try testing.expectEqual(@as(usize, 1), hunks.len);
    try testing.expectEqual(@as(u32, 1), hunks[0].old_start);
    try testing.expectEqual(@as(u32, 3), hunks[0].old_lines);
}

test "one window reaches the first and the last record" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const hunks = try diff.compare(arena.allocator(), "a\nb\nc\nd\n", "X\nb\nc\nY\n", .{ .context = 10 });
    try testing.expectEqual(@as(usize, 1), hunks.len);
    try testing.expectEqual(@as(u32, 1), hunks[0].old_start);
    try testing.expectEqual(@as(u32, 1), hunks[0].new_start);
    try testing.expectEqual(@as(u32, 4), hunks[0].old_lines);
    try testing.expectEqual(@as(u32, 4), hunks[0].new_lines);
}

test "a very large context does not overflow the merge limit" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const hunks = try diff.compare(arena.allocator(), "a\nb\nc\n", "X\nb\nY\n", .{ .context = @as(u32, 1) << 31 });
    try testing.expectEqual(@as(usize, 1), hunks.len);
}
