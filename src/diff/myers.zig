//! The Myers algorithm uses a greedy search over interned line identifiers. It returns the shortest
//! edit script. Reference: Eugene W. Myers, "An O(ND) Difference Algorithm and Its Variations", 1986.

const std = @import("std");

pub const Op = enum { keep, delete, insert };

/// One run of adjacent lines with the same operation. The indexes are 0-based. A `keep` run advances
/// both sides. A `delete` run advances the old side. An `insert` run advances the new side.
pub const Edit = struct {
    op: Op,
    old_start: u32,
    new_start: u32,
    len: u32,
};

pub const Error = error{ TooDifferent, OutOfMemory };

/// One step of the backtrack, before the runs join.
const Step = struct { op: Op, old_index: u32, new_index: u32 };

/// Return the shortest edit script from `old` to `new`. The trace costs about
/// `max_edits * max_edits / 2` words, so `max_edits` bounds the memory. The result borrows `arena`.
pub fn script(arena: std.mem.Allocator, old: []const u32, new: []const u32, max_edits: u32) Error![]const Edit {
    // The search adds both lengths, so the sum must also fit in a u32.
    std.debug.assert(old.len + new.len <= std.math.maxInt(u32));

    // Trim the common prefix and suffix. One small change in a large file leaves a small middle.
    var prefix: u32 = 0;
    while (prefix < old.len and prefix < new.len and old[prefix] == new[prefix]) prefix += 1;
    var suffix: u32 = 0;
    while (suffix < old.len - prefix and suffix < new.len - prefix and
        old[old.len - 1 - suffix] == new[new.len - 1 - suffix]) suffix += 1;

    const a = old[prefix .. old.len - suffix];
    const b = new[prefix .. new.len - suffix];
    // The trim is maximal, so the middle has no first line and no last line.
    if (a.len > 0 and b.len > 0) {
        std.debug.assert(a[0] != b[0]);
        std.debug.assert(a[a.len - 1] != b[b.len - 1]);
    }

    var out: std.ArrayList(Edit) = .empty;
    if (prefix > 0) try out.append(arena, .{ .op = .keep, .old_start = 0, .new_start = 0, .len = prefix });
    try middle(arena, &out, a, b, prefix, max_edits);
    if (suffix > 0) try out.append(arena, .{
        .op = .keep,
        .old_start = @intCast(old.len - suffix),
        .new_start = @intCast(new.len - suffix),
        .len = suffix,
    });
    return out.items;
}

/// Append the edit runs for the trimmed middle. `offset` shifts every index back to the full texts.
fn middle(arena: std.mem.Allocator, out: *std.ArrayList(Edit), a: []const u32, b: []const u32, offset: u32, max_edits: u32) Error!void {
    const n: u32 = @intCast(a.len);
    const m: u32 = @intCast(b.len);
    if (n == 0 and m == 0) return;
    // One empty side needs no search and no trace, so `max_edits` does not apply here.
    if (n == 0) return out.append(arena, .{ .op = .insert, .old_start = offset, .new_start = offset, .len = m });
    if (m == 0) return out.append(arena, .{ .op = .delete, .old_start = offset, .new_start = offset, .len = n });

    const depth = @min(n + m, max_edits);
    // The `k` value runs from -d to d, and the search reads `k - 1` and `k + 1`. Add two more slots.
    const center: usize = depth + 1;
    const frontier = try arena.alloc(u32, 2 * center + 1);
    @memset(frontier, 0);
    // The trace holds `d + 1` frontier values after step `d`, so it is triangular.
    var trace: std.ArrayList(u32) = .empty;

    var d: u32 = 0;
    while (d <= depth) : (d += 1) {
        var k: i64 = -@as(i64, d);
        while (k <= d) : (k += 2) {
            const at: usize = @intCast(k + @as(i64, @intCast(center)));
            // A move down inserts a new line. A move right deletes an old line.
            var x: u32 = if (k == -@as(i64, d) or (k != d and frontier[at - 1] < frontier[at + 1]))
                frontier[at + 1]
            else
                frontier[at - 1] + 1;
            var y: u32 = @intCast(@as(i64, x) - k);
            while (x < n and y < m and a[x] == b[y]) { // the snake runs along equal lines
                x += 1;
                y += 1;
            }
            frontier[at] = x;
            if (x >= n and y >= m) {
                std.debug.assert(x == n and y == m); // the frontier stops exactly at both ends
                return backtrack(arena, out, trace.items, d, a, b, offset);
            }
        }
        // Save the frontier for `k` in -d..d. The backtrack of step d + 1 reads it.
        try trace.ensureUnusedCapacity(arena, d + 1);
        var save: i64 = -@as(i64, d);
        while (save <= d) : (save += 2) {
            trace.appendAssumeCapacity(frontier[@intCast(save + @as(i64, @intCast(center)))]);
        }
    }
    return error.TooDifferent;
}

/// Read the saved frontier of step `step` at diagonal `k`. The caller must pass a valid range and parity.
fn traceAt(trace: []const u32, step: i64, k: i64) u32 {
    std.debug.assert(step >= 0);
    std.debug.assert(k >= -step and k <= step);
    std.debug.assert(@rem(k - step, 2) == 0); // k and step share their parity
    const base: usize = @intCast(@divExact(step * (step + 1), 2));
    const index: usize = @intCast(@divExact(k + step, 2));
    std.debug.assert(base + index < trace.len);
    return trace[base + index];
}

/// Read the trace in reverse from the end of both texts. Append the edit runs in forward order.
fn backtrack(
    arena: std.mem.Allocator,
    out: *std.ArrayList(Edit),
    trace: []const u32,
    depth: u32,
    a: []const u32,
    b: []const u32,
    offset: u32,
) Error!void {
    var steps: std.ArrayList(Step) = .empty;
    defer steps.deinit(arena);

    var x: i64 = @intCast(a.len);
    var y: i64 = @intCast(b.len);
    var d: i64 = depth;
    while (d > 0) : (d -= 1) {
        const prev = d - 1;
        const k = x - y;
        std.debug.assert(k >= -d and k <= d);
        std.debug.assert(@rem(k - d, 2) == 0); // k and d share their parity
        const prev_k = if (k == -d or (k != d and traceAt(trace, prev, k - 1) < traceAt(trace, prev, k + 1)))
            k + 1
        else
            k - 1;
        const prev_x: i64 = traceAt(trace, prev, prev_k);
        const prev_y: i64 = prev_x - prev_k;
        std.debug.assert(prev_x >= 0 and prev_y >= 0);
        std.debug.assert(x >= prev_x and y >= prev_y); // the walk never moves forward

        while (x > prev_x and y > prev_y) { // the snake, walked backward
            x -= 1;
            y -= 1;
            try steps.append(arena, .{ .op = .keep, .old_index = @intCast(x), .new_index = @intCast(y) });
        }
        // Exactly one side advances, so the step is one insert or one delete.
        std.debug.assert((x == prev_x and y > prev_y) or (x > prev_x and y == prev_y));
        if (x == prev_x) {
            y -= 1;
            try steps.append(arena, .{ .op = .insert, .old_index = @intCast(x), .new_index = @intCast(y) });
        } else {
            x -= 1;
            try steps.append(arena, .{ .op = .delete, .old_index = @intCast(x), .new_index = @intCast(y) });
        }
        std.debug.assert(x == prev_x and y == prev_y);
    }
    std.debug.assert(x == y); // step 0 ends on diagonal 0
    while (x > 0 and y > 0) { // the leading snake of step 0
        x -= 1;
        y -= 1;
        try steps.append(arena, .{ .op = .keep, .old_index = @intCast(x), .new_index = @intCast(y) });
    }
    std.debug.assert(x == 0 and y == 0);

    // The steps are in reverse order. Join the adjacent steps that share an operation.
    var i: usize = steps.items.len;
    while (i > 0) {
        i -= 1;
        const step = steps.items[i];
        const last = if (out.items.len == 0) null else &out.items[out.items.len - 1];
        if (last) |run| {
            if (run.op == step.op and joins(run.*, step, offset)) {
                run.len += 1;
                continue;
            }
        }
        try out.append(arena, .{
            .op = step.op,
            .old_start = step.old_index + offset,
            .new_start = step.new_index + offset,
            .len = 1,
        });
    }
}

/// Return true when the step continues the run on its advancing side with no gap.
fn joins(run: Edit, step: Step, offset: u32) bool {
    std.debug.assert(run.len > 0);
    std.debug.assert(run.op == step.op);
    return switch (run.op) {
        .keep => run.old_start + run.len == step.old_index + offset and run.new_start + run.len == step.new_index + offset,
        .delete => run.old_start + run.len == step.old_index + offset,
        .insert => run.new_start + run.len == step.new_index + offset,
    };
}

const testing = std.testing;

fn scriptOf(arena: std.mem.Allocator, old: []const u32, new: []const u32) ![]const Edit {
    return script(arena, old, new, 1000);
}

fn expectScript(arena: std.mem.Allocator, old: []const u32, new: []const u32) !void {
    const edits = try scriptOf(arena, old, new);
    var rebuilt: std.ArrayList(u32) = .empty;
    var old_at: u32 = 0;
    var new_at: u32 = 0;
    for (edits) |edit| {
        try testing.expect(edit.len > 0);
        switch (edit.op) {
            .keep => {
                try testing.expectEqual(old_at, edit.old_start);
                try testing.expectEqual(new_at, edit.new_start);
                try rebuilt.appendSlice(arena, old[edit.old_start .. edit.old_start + edit.len]);
                old_at += edit.len;
                new_at += edit.len;
            },
            .delete => {
                try testing.expectEqual(old_at, edit.old_start);
                old_at += edit.len;
            },
            .insert => {
                try testing.expectEqual(new_at, edit.new_start);
                try rebuilt.appendSlice(arena, new[edit.new_start .. edit.new_start + edit.len]);
                new_at += edit.len;
            },
        }
    }
    try testing.expectEqual(@as(u32, @intCast(old.len)), old_at); // The script consumes the old text.
    try testing.expectEqual(@as(u32, @intCast(new.len)), new_at); // The script produces the new text.
    try testing.expectEqualSlices(u32, new, rebuilt.items);
}

test "an equal text gives one keep run" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const edits = try scriptOf(a, &.{ 1, 2, 3 }, &.{ 1, 2, 3 });
    try testing.expectEqual(@as(usize, 1), edits.len);
    try testing.expectEqual(Op.keep, edits[0].op);
    try testing.expectEqual(@as(u32, 3), edits[0].len);
}

test "two empty texts give no run" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(@as(usize, 0), (try scriptOf(arena.allocator(), &.{}, &.{})).len);
}

test "an empty old text gives one insert run" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const edits = try scriptOf(a, &.{}, &.{ 7, 8 });
    try testing.expectEqual(@as(usize, 1), edits.len);
    try testing.expectEqual(Op.insert, edits[0].op);
    try testing.expectEqual(@as(u32, 2), edits[0].len);
    try testing.expectEqual(@as(u32, 0), edits[0].new_start);
}

test "an empty new text gives one delete run" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const edits = try scriptOf(a, &.{ 7, 8 }, &.{});
    try testing.expectEqual(@as(usize, 1), edits.len);
    try testing.expectEqual(Op.delete, edits[0].op);
    try testing.expectEqual(@as(u32, 2), edits[0].len);
}

test "one changed line in the middle keeps both sides" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const old = [_]u32{ 1, 2, 3, 4, 5 };
    const new = [_]u32{ 1, 2, 9, 4, 5 };
    try expectScript(a, &old, &new);

    const edits = try scriptOf(a, &old, &new);
    try testing.expectEqual(@as(usize, 4), edits.len);
    try testing.expectEqual(Op.keep, edits[0].op);
    try testing.expectEqual(@as(u32, 2), edits[0].len);
    try testing.expectEqual(Op.keep, edits[3].op);
    try testing.expectEqual(@as(u32, 2), edits[3].len);
}

test "the classic Myers example rebuilds the new text" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // ABCABBA -> CBABAC, the example of the Myers paper.
    const old = [_]u32{ 'A', 'B', 'C', 'A', 'B', 'B', 'A' };
    const new = [_]u32{ 'C', 'B', 'A', 'B', 'A', 'C' };
    try expectScript(arena.allocator(), &old, &new);
}

test "a full rewrite rebuilds the new text" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try expectScript(arena.allocator(), &.{ 1, 2, 3 }, &.{ 4, 5, 6 });
}

test "an insert at the start and at the end rebuilds the new text" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectScript(a, &.{ 1, 2 }, &.{ 0, 1, 2 });
    try expectScript(a, &.{ 1, 2 }, &.{ 1, 2, 3 });
    try expectScript(a, &.{ 1, 2 }, &.{ 0, 1, 2, 3 });
}

test "repeated lines rebuild the new text" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectScript(a, &.{ 1, 1, 1, 1 }, &.{ 1, 1 });
    try expectScript(a, &.{ 1, 1 }, &.{ 1, 1, 1, 1 });
    try expectScript(a, &.{ 1, 2, 1, 2, 1 }, &.{ 2, 1, 2 });
}

test "many random pairs rebuild the new text" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var prng = std.Random.DefaultPrng.init(0x5eed);
    const rand = prng.random();
    var trial: usize = 0;
    while (trial < 200) : (trial += 1) {
        var scratch = std.heap.ArenaAllocator.init(testing.allocator);
        defer scratch.deinit();
        const a = scratch.allocator();

        const old = try a.alloc(u32, rand.uintLessThan(usize, 40));
        const new = try a.alloc(u32, rand.uintLessThan(usize, 40));
        for (old) |*v| v.* = rand.uintLessThan(u32, 6); // a small alphabet forces repeated lines
        for (new) |*v| v.* = rand.uintLessThan(u32, 6);
        try expectScript(a, old, new);
    }
}

test "script fails above the edit cap" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const old = [_]u32{ 1, 2, 3, 4 };
    const new = [_]u32{ 5, 6, 7, 8 };
    try testing.expectError(error.TooDifferent, script(a, &old, &new, 2));
    _ = try script(a, &old, &new, 8); // the same pair fits under a large enough cap
}

test "a large equal text costs one run and no search" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const big = try a.alloc(u32, 20_000);
    for (big, 0..) |*v, i| v.* = @intCast(i % 512);
    // The prefix trim removes everything, so a tiny cap still works.
    const edits = try script(a, big, big, 1);
    try testing.expectEqual(@as(usize, 1), edits.len);
    try testing.expectEqual(@as(u32, 20_000), edits[0].len);
}

test "a small change between a long prefix and a long suffix needs one edit pair" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const old = try a.alloc(u32, 10_000);
    for (old, 0..) |*v, i| v.* = @intCast(i);
    const new = try a.dupe(u32, old);
    new[5_000] = 999_999;

    // The trim removes both sides, so a cap of two edits is enough.
    const edits = try script(a, old, new, 2);
    try expectScript(a, old, new);
    try testing.expectEqual(@as(usize, 4), edits.len);
}

test "the edit cap accepts the exact depth and refuses one less" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // One replaced line costs one delete plus one insert.
    const old = [_]u32{ 1, 2, 3 };
    const new = [_]u32{ 1, 9, 3 };
    _ = try script(a, &old, &new, 2);
    try testing.expectError(error.TooDifferent, script(a, &old, &new, 1));
}

test "an empty side needs no search depth" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The fast path uses no trace, so a zero cap still returns one run.
    const edits = try script(a, &.{}, &.{ 1, 2, 3 }, 0);
    try testing.expectEqual(@as(usize, 1), edits.len);
    try testing.expectEqual(@as(u32, 3), edits[0].len);
}
