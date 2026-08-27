//! The `read` built-in. Read a file and return it with 1-indexed line numbers.

const std = @import("std");
const t = @import("tool.zig");

/// A line number fits in u32. The bound also keeps `number` clear of an unsigned overflow.
const max_line = std.math.maxInt(u32);

const Args = struct {
    path: t.schema.Str,
    start: ?usize = null,
    end: ?usize = null,
};

pub const tool = t.define(
    "read",
    "Read a file with 1-indexed line numbers. Pass start and end for a line range.",
    Args,
    .{
        .path = .{ .description = "The file path. A relative path resolves against the workspace root." },
        .start = .{ .description = "The first line to read, 1-indexed.", .minimum = 1, .maximum = max_line },
        .end = .{ .description = "The last line to read, 1-indexed and inclusive.", .minimum = 1, .maximum = max_line },
    },
    execute,
);

fn execute(out: std.mem.Allocator, scratch: std.mem.Allocator, host: t.ToolHost, args: Args) t.ToolError!t.ToolResult {
    // The schema sets the bounds. The decoder does not enforce them. Line 0 does not exist.
    if (args.start) |s| if (s < 1 or s > max_line) return error.InvalidArg;
    if (args.end) |e| if (e < 1 or e > max_line) return error.InvalidArg;
    const text = try host.readFile(scratch, args.path.bytes, args.start, args.end);
    return .{ .text = try number(out, text, args.start orelse 1) };
}

/// Prefix each line with its number. Start at `first`. Remove one final newline. The result comes
/// from `out`. It outlives the `scratch` allocator that holds the file bytes.
fn number(out: std.mem.Allocator, text: []const u8, first: usize) error{OutOfMemory}![]const u8 {
    std.debug.assert(first >= 1 and first <= max_line); // execute validated the range
    if (text.len == 0) return "";
    const body = if (text[text.len - 1] == '\n') text[0 .. text.len - 1] else text;
    var buf: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, body, '\n');
    var n = first;
    while (it.next()) |line| {
        try buf.print(out, "{d}: {s}", .{ n, line });
        if (it.peek() != null) try buf.append(out, '\n');
        n += 1;
    }
    return buf.toOwnedSlice(out);
}

const testing = std.testing;

/// This host returns fixed bytes for handler tests without a file system. It records the range.
const FakeHost = struct {
    text: []const u8,
    seen_start: ?usize = null,
    seen_end: ?usize = null,

    const vtable: t.ToolHost.VTable = .{ .readFile = readFile };

    fn host(self: *FakeHost) t.ToolHost {
        return .{ .ctx = self, .vtable = &vtable };
    }

    fn readFile(ctx: *anyopaque, scratch: std.mem.Allocator, path: []const u8, start: ?usize, end: ?usize) t.HostError![]const u8 {
        _ = path;
        const self: *FakeHost = @ptrCast(@alignCast(ctx));
        self.seen_start = start;
        self.seen_end = end;
        return scratch.dupe(u8, self.text);
    }
};

test "read numbers lines from the given start" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: FakeHost = .{ .text = "alpha\nbeta\ngamma\n" };
    const res = try tool.execute(a, a, fake.host(), "{\"path\":\"x\",\"start\":10}");
    try testing.expectEqualStrings("10: alpha\n11: beta\n12: gamma", res.text);
    try testing.expect(res.view == null);
}

test "read numbers from line 1 when start is absent" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: FakeHost = .{ .text = "one\ntwo" };
    const res = try tool.execute(a, a, fake.host(), "{\"path\":\"x\"}");
    try testing.expectEqualStrings("1: one\n2: two", res.text);
}

test "read numbers an empty file as empty and a single newline as one line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var empty: FakeHost = .{ .text = "" };
    const r0 = try tool.execute(a, a, empty.host(), "{\"path\":\"p\"}");
    try testing.expectEqualStrings("", r0.text);

    var newline: FakeHost = .{ .text = "\n" };
    const r1 = try tool.execute(a, a, newline.host(), "{\"path\":\"p\"}");
    try testing.expectEqualStrings("1: ", r1.text);
}

test "read forwards the line range to the host" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: FakeHost = .{ .text = "x" };
    _ = try tool.execute(a, a, fake.host(), "{\"path\":\"p\",\"start\":3,\"end\":7}");
    try testing.expectEqual(@as(?usize, 3), fake.seen_start);
    try testing.expectEqual(@as(?usize, 7), fake.seen_end);
}

test "read rejects bad arguments" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: FakeHost = .{ .text = "" };
    const h = fake.host();
    try testing.expectError(error.MissingArg, tool.execute(a, a, h, "{}"));
    try testing.expectError(error.InvalidArg, tool.execute(a, a, h, "{\"path\":5}"));
    try testing.expectError(error.InvalidArg, tool.execute(a, a, h, "{\"path\":\"x\",\"start\":0}"));
    try testing.expectError(error.UnknownArg, tool.execute(a, a, h, "{\"path\":\"x\",\"extra\":1}"));
    try testing.expectError(error.InvalidArg, tool.execute(a, a, h, "{\"path\":\"x\",\"start\":4294967296}"));
    try testing.expectError(error.InvalidArg, tool.execute(a, a, h, "{\"path\":[120]}")); // the byte-array form
}

test "read passes the result out of the scratch allocator" {
    var out = std.heap.ArenaAllocator.init(testing.allocator);
    defer out.deinit();
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);

    var fake: FakeHost = .{ .text = "alpha\nbeta\n" };
    const res = try tool.execute(out.allocator(), scratch.allocator(), fake.host(), "{\"path\":\"x\"}");
    scratch.deinit(); // The test frees `scratch`. The result must survive.
    try testing.expectEqualStrings("1: alpha\n2: beta", res.text);
}
