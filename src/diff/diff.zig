//! Compare two texts line by line and return the changed hunks. The caller draws them; this module
//! keeps no output format. The result borrows both input texts, so they must outlive it.

const std = @import("std");
const lines = @import("lines.zig");
const myers = @import("myers.zig");
const hunks = @import("hunks.zig");

pub const Op = myers.Op;
pub const Edit = myers.Edit;
pub const Line = hunks.Line;
pub const Hunk = hunks.Hunk;

pub const Error = error{ TooDifferent, OutOfMemory };

pub const Options = struct {
    /// The hunk keeps this many unchanged lines on each side of a change. Three is the usual default.
    context: u32 = 3,
    /// The search depth cap. It bounds the trace only; the caller must bound the input byte size.
    max_edits: u32 = 1000,
};

/// Compare `old` and `new` and return their hunks. An equal pair gives an empty slice. The result
/// borrows `arena`, `old`, and `new`, so all three must outlive it.
pub fn compare(arena: std.mem.Allocator, old: []const u8, new: []const u8, options: Options) Error![]const Hunk {
    var table: lines.Table = .{};
    defer table.deinit(arena);

    const old_lines = try lines.split(arena, &table, old);
    const new_lines = try lines.split(arena, &table, new);
    const edits = try myers.script(arena, old_lines.ids, new_lines.ids, options.max_edits);
    return hunks.group(arena, edits, old_lines.text, new_lines.text, options.context);
}

/// Count the changed lines in the hunk list.
pub fn changedLines(list: []const Hunk) usize {
    var total: usize = 0;
    for (list) |hunk| {
        for (hunk.lines) |line| {
            if (line.op != .keep) total += 1;
        }
    }
    return total;
}

const testing = std.testing;

test "compare returns no hunk for an equal text" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const text = "alpha\nbeta\ngamma\n";
    try testing.expectEqual(@as(usize, 0), (try compare(arena.allocator(), text, text, .{})).len);
}

test "compare reports one changed line with its context" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const old = "one\ntwo\nthree\nfour\nfive\n";
    const new = "one\ntwo\nCHANGED\nfour\nfive\n";
    const list = try compare(arena.allocator(), old, new, .{ .context = 1 });

    try testing.expectEqual(@as(usize, 1), list.len);
    try testing.expectEqual(@as(usize, 2), changedLines(list));
    try testing.expectEqual(@as(u32, 2), list[0].old_start);
    try testing.expectEqualStrings("three", list[0].lines[1].text);
    try testing.expectEqual(Op.delete, list[0].lines[1].op);
    try testing.expectEqualStrings("CHANGED", list[0].lines[2].text);
    try testing.expectEqual(Op.insert, list[0].lines[2].op);
}

test "compare treats a new file as one insert hunk" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const list = try compare(arena.allocator(), "", "a\nb\n", .{});
    try testing.expectEqual(@as(usize, 1), list.len);
    try testing.expectEqual(@as(u32, 0), list[0].old_start);
    try testing.expectEqual(@as(u32, 0), list[0].old_lines);
    try testing.expectEqual(@as(usize, 2), changedLines(list));
}

test "compare reports a line-ending change as a changed line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const list = try compare(arena.allocator(), "a\nb\n", "a\r\nb\r\n", .{});
    try testing.expectEqual(@as(usize, 1), list.len);
    try testing.expectEqual(@as(usize, 4), changedLines(list));
}

test "compare fails above the edit cap" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const old = "a\nb\nc\nd\ne\nf\n";
    const new = "1\n2\n3\n4\n5\n6\n";
    try testing.expectError(error.TooDifferent, compare(arena.allocator(), old, new, .{ .max_edits = 4 }));
}

test "compare handles a missing final line feed on one side" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // The final line feed does not create a changed line.
    const list = try compare(arena.allocator(), "a\nb\n", "a\nb", .{});
    try testing.expectEqual(@as(usize, 0), list.len);
}

test "compare handles a one-line file with no final line feed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const list = try compare(arena.allocator(), "old", "new", .{});
    try testing.expectEqual(@as(usize, 1), list.len);
    try testing.expectEqual(@as(u32, 1), list[0].old_start);
    try testing.expectEqual(@as(u32, 1), list[0].old_lines);
    try testing.expectEqualStrings("old", list[0].lines[0].text);
    try testing.expectEqualStrings("new", list[0].lines[1].text);
}

test "compare reports a changed final line with no line feed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const list = try compare(arena.allocator(), "a\nb", "a\nc", .{});
    try testing.expectEqual(@as(usize, 1), list.len);
    try testing.expectEqual(@as(usize, 2), changedLines(list));
    try testing.expectEqual(@as(u32, 2), list[0].old_lines);
}
