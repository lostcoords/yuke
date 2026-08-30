//! Map a line diff to the wire view. The model does not read the view.

const std = @import("std");
const wire = @import("wire");
const diff = @import("diff");

/// One mapped diff. A null `views` means the texts match, or the pair is above the search cap.
pub const Rendered = struct {
    views: ?[]const wire.view.View = null,
    changed_lines: usize = 0,
};

/// The largest side the mapper compares. A line table costs about 20 bytes for each line.
pub const max_side_bytes = 1024 * 1024;

/// Build a one-file diff view. The tool result still states the change when the view is absent.
/// The hunks come from `scratch`. The returned view comes from `out`.
pub fn diffView(
    out: std.mem.Allocator,
    scratch: std.mem.Allocator,
    path: []const u8,
    old: []const u8,
    new: []const u8,
) error{OutOfMemory}!Rendered {
    // The line tables come before the edit cap, so a large side must stop the mapper here.
    if (old.len > max_side_bytes or new.len > max_side_bytes) return .{};
    // `compare` borrows `old` and `new` until the mapping ends. The view copies the borrowed text.
    const hunks = diff.compare(scratch, old, new, .{}) catch |err| switch (err) {
        error.TooDifferent => return .{}, // The change is too large for a reader-friendly view.
        error.OutOfMemory => |e| return e,
    };
    if (hunks.len == 0) return .{};

    const mapped = try out.alloc(wire.view.DiffHunk, hunks.len);
    for (hunks, mapped) |hunk, *target| {
        const lines = try out.alloc([]const u8, hunk.lines.len);
        for (hunk.lines, lines) |line, *text| {
            // The wire carries plain strings. The mark identifies the operation.
            const mark: u8 = switch (line.op) {
                .keep => ' ',
                .delete => '-',
                .insert => '+',
            };
            text.* = try std.fmt.allocPrint(out, "{c}{s}", .{ mark, line.text });
        }
        target.* = .{
            .old_start = hunk.old_start,
            .old_lines = hunk.old_lines,
            .new_start = hunk.new_start,
            .new_lines = hunk.new_lines,
            .lines = lines,
        };
    }

    const files = try out.alloc(wire.view.DiffFile, 1);
    files[0] = .{ .path = try out.dupe(u8, path), .hunks = mapped };
    const views = try out.alloc(wire.view.View, 1);
    views[0] = .{ .diff = .{ .files = files } };
    // `diff.changedLines` counts the op enum. A scan of the marked strings would repeat the walk.
    return .{ .views = views, .changed_lines = diff.changedLines(hunks) };
}

const testing = std.testing;

fn build(a: std.mem.Allocator, old: []const u8, new: []const u8) !Rendered {
    return diffView(a, a, "a.txt", old, new);
}

test "diffView marks each line with its operation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const rendered = try build(a, "one\ntwo\n", "one\ntwo changed\n");
    const views = rendered.views.?;
    const hunks = views[0].diff.files[0].hunks;
    try testing.expectEqual(@as(usize, 1), hunks.len);
    try testing.expectEqualStrings("a.txt", views[0].diff.files[0].path);
    try testing.expectEqualStrings(" one", hunks[0].lines[0]);
    try testing.expectEqualStrings("-two", hunks[0].lines[1]);
    try testing.expectEqualStrings("+two changed", hunks[0].lines[2]);
    try testing.expectEqual(@as(usize, 2), rendered.changed_lines);
}

test "diffView returns null for an equal pair" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expect((try build(arena.allocator(), "same\n", "same\n")).views == null);
}

test "diffView states a new file with an empty old side" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const views = (try build(arena.allocator(), "", "fresh\n")).views.?;
    const hunk = views[0].diff.files[0].hunks[0];
    // The empty side has start 0 and count 0. The wire needs no extra field.
    try testing.expectEqual(@as(u64, 0), hunk.old_start);
    try testing.expectEqual(@as(u64, 0), hunk.old_lines);
    try testing.expectEqualStrings("+fresh", hunk.lines[0]);
}

test "diffView outlives the scratch allocator" {
    var out = std.heap.ArenaAllocator.init(testing.allocator);
    defer out.deinit();
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);

    const old = try scratch.allocator().dupe(u8, "a\n");
    const new = try scratch.allocator().dupe(u8, "b\n");
    const views = (try diffView(out.allocator(), scratch.allocator(), "p", old, new)).views.?;
    scratch.deinit(); // The hunk text borrows `scratch`. The view copies that data.
    try testing.expectEqualStrings("-a", views[0].diff.files[0].hunks[0].lines[0]);
}
