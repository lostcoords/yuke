//! The `read` built-in. Read a file and return it with 1-indexed line numbers.

const std = @import("std");
const t = @import("tool.zig");
const test_host = @import("test_host.zig");

/// A line number fits in u32. The bound also keeps `number` clear of an unsigned overflow.
const max_line = std.math.maxInt(u32);

/// The read limits. These limits keep one result within the transcript. opencode and Cline use the
/// same line numbers.
const limits: t.ReadLimits = .{
    .max_lines = 2000,
    .max_line_bytes = 8000, // the limit allows at least 2000 four-byte codepoints
    .max_bytes = 64 * 1024,
};

const Args = struct {
    path: t.schema.Str,
    start: ?u32 = null,
    end: ?u32 = null,
};

pub const tool = t.define(
    "read",
    "Read a file with 1-indexed line numbers. Pass the start and end values for a line range.",
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
    if (args.start) |s| if (s < 1) return error.InvalidArg;
    if (args.end) |e| if (e < 1) return error.InvalidArg;
    const got = try host.readRange(scratch, args.path.bytes, .{ .start = args.start, .end = args.end }, limits);
    return .{ .text = try render(out, got, args.start orelse 1) };
}

/// Number each line. Add one notice for each limit the read reached. The result comes from `out`. It
/// outlives the `scratch` allocator that holds the file bytes.
fn render(out: std.mem.Allocator, got: t.RangeRead, first_line: u32) error{OutOfMemory}![]const u8 {
    std.debug.assert(first_line >= 1 and first_line <= max_line); // execute validated the range
    var buf: std.ArrayList(u8) = .empty;
    if (got.text.len != 0) {
        // The backend returns newline-terminated lines. Remove the final newline before the join.
        var it = std.mem.splitScalar(u8, got.text[0 .. got.text.len - 1], '\n');
        var n: u64 = first_line;
        while (it.next()) |line| {
            try buf.print(out, "{d}: {s}", .{ n, line });
            if (it.peek() != null) try buf.append(out, '\n');
            n += 1;
        }
    }
    if (got.long_lines != 0) {
        try buf.print(out, "\n[The tool cut {d} line(s) at {d} bytes.]", .{ got.long_lines, limits.max_line_bytes });
    }
    if (got.next_line) |next| {
        try buf.print(out, "\n[The tool capped the output. Read again with the start value set to {d}.]", .{next});
    }
    return buf.toOwnedSlice(out);
}

const testing = std.testing;

/// This host returns a fixed result for handler tests without a file system. It records the request.
const FakeHost = struct {
    result: t.RangeRead,
    seen: ?t.Range = null,
    seen_limits: ?t.ReadLimits = null,

    const vtable: t.ToolHost.VTable = blk: {
        var v = test_host.unsupported;
        v.readRange = readRange;
        break :blk v;
    };

    fn host(self: *FakeHost) t.ToolHost {
        return .{ .ctx = self, .vtable = &vtable };
    }

    fn readRange(ctx: *anyopaque, scratch: std.mem.Allocator, path: []const u8, range: t.Range, lim: t.ReadLimits) t.HostError!t.RangeRead {
        _ = path;
        const self: *FakeHost = @ptrCast(@alignCast(ctx));
        self.seen = range;
        self.seen_limits = lim;
        // The real backend returns text that borrows `scratch`, so the fake must do the same.
        var copy = self.result;
        copy.text = try scratch.dupe(u8, self.result.text);
        return copy;
    }
};

fn run(a: std.mem.Allocator, fake: *FakeHost, args: []const u8) t.ToolError![]const u8 {
    return (try tool.execute(a, a, fake.host(), args)).text;
}

test "read numbers lines from the first returned line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: FakeHost = .{ .result = .{ .text = "alpha\nbeta\ngamma\n" } };
    try testing.expectEqualStrings("10: alpha\n11: beta\n12: gamma", try run(a, &fake, "{\"path\":\"x\",\"start\":10}"));

    var one: FakeHost = .{ .result = .{ .text = "one\ntwo\n" } };
    try testing.expectEqualStrings("1: one\n2: two", try run(a, &one, "{\"path\":\"x\"}"));

    var empty: FakeHost = .{ .result = .{ .text = "" } };
    try testing.expectEqualStrings("", try run(a, &empty, "{\"path\":\"p\"}"));

    var blank: FakeHost = .{ .result = .{ .text = "\n" } };
    try testing.expectEqualStrings("1: ", try run(a, &blank, "{\"path\":\"p\"}"));
}

test "read forwards the range and the limits to the host" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: FakeHost = .{ .result = .{ .text = "" } };
    _ = try run(a, &fake, "{\"path\":\"p\",\"start\":3,\"end\":7}");
    try testing.expectEqual(@as(?u32, 3), fake.seen.?.start);
    try testing.expectEqual(@as(?u32, 7), fake.seen.?.end);
    try testing.expectEqual(limits, fake.seen_limits.?);
}

test "read reports each bound the host reached" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var capped: FakeHost = .{ .result = .{ .text = "a\n", .next_line = 2 } };
    try testing.expectEqualStrings("1: a\n[The tool capped the output. Read again with the start value set to 2.]", try run(a, &capped, "{\"path\":\"p\"}"));

    var cut: FakeHost = .{ .result = .{ .text = "a\n", .long_lines = 3 } };
    try testing.expectEqualStrings("1: a\n[The tool cut 3 line(s) at 8000 bytes.]", try run(a, &cut, "{\"path\":\"p\"}"));
}

test "read rejects bad arguments" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: FakeHost = .{ .result = .{ .text = "" } };
    const h = fake.host();
    try testing.expectError(error.MissingArg, tool.execute(a, a, h, "{}"));
    try testing.expectError(error.InvalidArg, tool.execute(a, a, h, "{\"path\":5}"));
    try testing.expectError(error.InvalidArg, tool.execute(a, a, h, "{\"path\":\"x\",\"start\":0}"));
    try testing.expectError(error.InvalidArg, tool.execute(a, a, h, "{\"path\":\"x\",\"start\":4294967296}"));
    try testing.expectError(error.UnknownArg, tool.execute(a, a, h, "{\"path\":\"x\",\"extra\":1}"));
    try testing.expectError(error.InvalidArg, tool.execute(a, a, h, "{\"path\":[120]}")); // the byte-array form
}

test "read passes the result out of the scratch allocator" {
    var out = std.heap.ArenaAllocator.init(testing.allocator);
    defer out.deinit();
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);

    var fake: FakeHost = .{ .result = .{ .text = "alpha\nbeta\n" } };
    const res = try tool.execute(out.allocator(), scratch.allocator(), fake.host(), "{\"path\":\"x\"}");
    scratch.deinit(); // The test frees `scratch`. The result must survive.
    try testing.expectEqualStrings("1: alpha\n2: beta", res.text);
}
