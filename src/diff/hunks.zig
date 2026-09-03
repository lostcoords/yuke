//! Group the edit runs into hunks. A hunk holds the changed lines plus the context lines around them.

const std = @import("std");
const line_source = @import("lines.zig");
const myers = @import("myers.zig");

const Op = myers.Op;
const Edit = myers.Edit;

/// One display line of a hunk. `text` borrows the old text or the new text.
pub const Line = struct {
    op: Op,
    text: []const u8,
};

/// One hunk. The start values are 1-based, as a unified difference states them. A side with no line
/// has start 0 and count 0.
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

/// Build the hunks of `edits`. `context` sets how many unchanged lines stay on each side of a change.
/// Two changes join into one hunk when at most `2 * context` unchanged lines separate them.
/// The result borrows `arena`, `old_text`, and `new_text`.
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
        switch (record.op) {
            .keep, .delete => {
                if (hunk.old_lines == 0) hunk.old_start = record.old_index + 1;
                hunk.old_lines += 1;
            },
            .insert => {},
        }
        switch (record.op) {
            .keep, .insert => {
                if (hunk.new_lines == 0) hunk.new_start = record.new_index + 1;
                hunk.new_lines += 1;
            },
            .delete => {},
        }
        line.* = .{
            .op = record.op,
            .text = if (record.op == .insert) new_text[record.new_index] else old_text[record.old_index],
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

const Fixture = struct {
    arena: std.heap.ArenaAllocator,

    fn init() Fixture {
        return .{ .arena = std.heap.ArenaAllocator.init(testing.allocator) };
    }
    fn deinit(self: *Fixture) void {
        self.arena.deinit();
    }
};

/// Build the hunks of two texts. It runs the whole path, so a test states real text.
fn hunksOf(arena: std.mem.Allocator, old: []const []const u8, new: []const []const u8, context: u32) ![]const Hunk {
    var table: line_source.Table = .{};
    defer table.deinit(arena);

    const old_lines = try line_source.split(arena, &table, try join(arena, old));
    const new_lines = try line_source.split(arena, &table, try join(arena, new));
    const edits = try myers.script(arena, old_lines.ids, new_lines.ids, 1000);
    return group(arena, edits, old_lines.text, new_lines.text, context);
}

/// Join the test lines into one text. Each line gets a line feed.
fn join(arena: std.mem.Allocator, list: []const []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (list) |line| {
        try out.appendSlice(arena, line);
        try out.append(arena, '\n');
    }
    return out.items;
}

test "an equal text gives no hunk" {
    var f = Fixture.init();
    defer f.deinit();
    const lines = [_][]const u8{ "a", "b", "c" };
    try testing.expectEqual(@as(usize, 0), (try hunksOf(f.arena.allocator(), &lines, &lines, 3)).len);
}

test "one changed line gives one hunk with context on both sides" {
    var f = Fixture.init();
    defer f.deinit();
    const old = [_][]const u8{ "a", "b", "c", "d", "e" };
    const new = [_][]const u8{ "a", "b", "X", "d", "e" };

    // The change is at line 3. One context line on each side gives the range 2..4, so `@@ -2,3 +2,3 @@`.
    const hunks = try hunksOf(f.arena.allocator(), &old, &new, 1);
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

test "a change at the first line clamps the context" {
    var f = Fixture.init();
    defer f.deinit();
    const old = [_][]const u8{ "a", "b", "c" };
    const new = [_][]const u8{ "X", "b", "c" };

    const hunks = try hunksOf(f.arena.allocator(), &old, &new, 3);
    try testing.expectEqual(@as(usize, 1), hunks.len);
    try testing.expectEqual(@as(u32, 1), hunks[0].old_start);
    try testing.expectEqual(@as(u32, 1), hunks[0].new_start);
}

test "a new file gives one hunk with an empty old side" {
    var f = Fixture.init();
    defer f.deinit();
    const new = [_][]const u8{ "a", "b" };

    const hunks = try hunksOf(f.arena.allocator(), &.{}, &new, 3);
    try testing.expectEqual(@as(usize, 1), hunks.len);
    try testing.expectEqual(@as(u32, 0), hunks[0].old_start);
    try testing.expectEqual(@as(u32, 0), hunks[0].old_lines);
    try testing.expectEqual(@as(u32, 1), hunks[0].new_start);
    try testing.expectEqual(@as(u32, 2), hunks[0].new_lines);
}

test "a deleted file gives one hunk with an empty new side" {
    var f = Fixture.init();
    defer f.deinit();
    const old = [_][]const u8{ "a", "b" };

    const hunks = try hunksOf(f.arena.allocator(), &old, &.{}, 3);
    try testing.expectEqual(@as(usize, 1), hunks.len);
    try testing.expectEqual(@as(u32, 1), hunks[0].old_start);
    try testing.expectEqual(@as(u32, 2), hunks[0].old_lines);
    try testing.expectEqual(@as(u32, 0), hunks[0].new_start);
    try testing.expectEqual(@as(u32, 0), hunks[0].new_lines);
}

test "a context of zero shows the changed lines only" {
    var f = Fixture.init();
    defer f.deinit();
    const old = [_][]const u8{ "a", "b", "c" };
    const new = [_][]const u8{ "a", "X", "c" };

    const hunks = try hunksOf(f.arena.allocator(), &old, &new, 0);
    try testing.expectEqual(@as(usize, 1), hunks.len);
    try testing.expectEqual(@as(usize, 2), hunks[0].lines.len);
    try testing.expectEqual(Op.delete, hunks[0].lines[0].op);
    try testing.expectEqual(Op.insert, hunks[0].lines[1].op);
}

test "a gap of two times the context joins and one more splits" {
    var f = Fixture.init();
    defer f.deinit();
    const a = f.arena.allocator();

    // Two changes with exactly 2 * context unchanged lines between them stay in one hunk.
    var old: [12][]const u8 = undefined;
    for (&old, 0..) |*line, i| line.* = switch (i) {
        0 => "0",
        1 => "1",
        2 => "2",
        3 => "3",
        4 => "4",
        5 => "5",
        6 => "6",
        7 => "7",
        8 => "8",
        9 => "9",
        10 => "10",
        else => "11",
    };

    var joined = old;
    joined[2] = "X";
    joined[7] = "Y"; // four unchanged lines between, and 2 * context is four
    try testing.expectEqual(@as(usize, 1), (try hunksOf(a, &old, &joined, 2)).len);

    var split = old;
    split[2] = "X";
    split[8] = "Y"; // five unchanged lines between, so the hunks split
    try testing.expectEqual(@as(usize, 2), (try hunksOf(a, &old, &split, 2)).len);
}

test "a change on the last line clamps the trailing context" {
    var f = Fixture.init();
    defer f.deinit();
    const old = [_][]const u8{ "a", "b", "c" };
    const new = [_][]const u8{ "a", "b", "X" };

    const hunks = try hunksOf(f.arena.allocator(), &old, &new, 10);
    try testing.expectEqual(@as(usize, 1), hunks.len);
    try testing.expectEqual(@as(u32, 1), hunks[0].old_start);
    try testing.expectEqual(@as(u32, 3), hunks[0].old_lines);
}

test "one window reaches the first and the last record" {
    var f = Fixture.init();
    defer f.deinit();
    const old = [_][]const u8{ "a", "b", "c", "d" };
    const new = [_][]const u8{ "X", "b", "c", "Y" };

    const hunks = try hunksOf(f.arena.allocator(), &old, &new, 10);
    try testing.expectEqual(@as(usize, 1), hunks.len);
    try testing.expectEqual(@as(u32, 1), hunks[0].old_start);
    try testing.expectEqual(@as(u32, 4), hunks[0].old_lines);
    try testing.expectEqual(@as(u32, 4), hunks[0].new_lines);
}

test "a very large context does not overflow the merge limit" {
    var f = Fixture.init();
    defer f.deinit();
    const old = [_][]const u8{ "a", "b", "c" };
    const new = [_][]const u8{ "X", "b", "Y" };

    const hunks = try hunksOf(f.arena.allocator(), &old, &new, @as(u32, 1) << 31);
    try testing.expectEqual(@as(usize, 1), hunks.len);
}
