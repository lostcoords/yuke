//! The `read` built-in. Read a file and return it with 1-indexed line numbers.

const std = @import("std");
const t = @import("tool.zig");

const Error = error{InvalidToolArgs};

pub const tool: t.Tool = .{
    .name = "read",
    .description = "Read a file with 1-indexed line numbers. Optionally pass start/end for a line range.",
    .input_schema =
    \\{"type":"object","properties":{"path":{"type":"string"},"start":{"type":"integer","minimum":1},"end":{"type":"integer","minimum":1}},"required":["path"],"additionalProperties":false}
    ,
    .execute = execute,
};

fn execute(arena: std.mem.Allocator, host: t.ToolHost, args: std.json.Value) anyerror!t.ToolResult {
    const obj = switch (args) {
        .object => |o| o,
        else => return Error.InvalidToolArgs,
    };
    const path = switch (obj.get("path") orelse return Error.InvalidToolArgs) {
        .string => |s| s,
        else => return Error.InvalidToolArgs,
    };
    const start = try optLine(obj, "start");
    const end = try optLine(obj, "end");
    // The schema is closed: reject any key other than path/start/end.
    var it = obj.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (!std.mem.eql(u8, key, "path") and !std.mem.eql(u8, key, "start") and !std.mem.eql(u8, key, "end")) {
            return Error.InvalidToolArgs;
        }
    }

    const text = try host.readFile(arena, path, start, end);
    return .{ .text = try number(arena, text, start orelse 1) };
}

/// Read an optional 1-indexed line field. Reject a non-integer or a value below 1.
fn optLine(obj: std.json.ObjectMap, key: []const u8) Error!?usize {
    const n = switch (obj.get(key) orelse return null) {
        .integer => |i| i,
        else => return Error.InvalidToolArgs,
    };
    if (n < 1) return Error.InvalidToolArgs;
    return std.math.cast(usize, n) orelse return Error.InvalidToolArgs;
}

/// Prefix each line with its number. Start at `first`. Remove one final newline. The caller owns the
/// result.
fn number(arena: std.mem.Allocator, text: []const u8, first: usize) ![]const u8 {
    if (text.len == 0) return "";
    const body = if (text[text.len - 1] == '\n') text[0 .. text.len - 1] else text;
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, body, '\n');
    var n = first;
    while (it.next()) |line| {
        try out.print(arena, "{d}: {s}", .{ n, line });
        if (it.peek() != null) try out.append(arena, '\n');
        n += 1;
    }
    return out.items;
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

    fn readFile(ctx: *anyopaque, arena: std.mem.Allocator, path: []const u8, start: ?usize, end: ?usize) anyerror![]const u8 {
        _ = path;
        const self: *FakeHost = @ptrCast(@alignCast(ctx));
        self.seen_start = start;
        self.seen_end = end;
        return arena.dupe(u8, self.text);
    }
};

fn parseArgs(arena: std.mem.Allocator, json: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{});
}

test "read numbers lines from the given start" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: FakeHost = .{ .text = "alpha\nbeta\ngamma\n" };
    const res = try tool.execute(a, fake.host(), try parseArgs(a, "{\"path\":\"x\",\"start\":10}"));
    try testing.expectEqualStrings("10: alpha\n11: beta\n12: gamma", res.text);
    try testing.expect(res.view == null);
}

test "read numbers from line 1 when start is absent" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: FakeHost = .{ .text = "one\ntwo" };
    const res = try tool.execute(a, fake.host(), try parseArgs(a, "{\"path\":\"x\"}"));
    try testing.expectEqualStrings("1: one\n2: two", res.text);
}

test "read numbers an empty file as empty and a single newline as one line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var empty: FakeHost = .{ .text = "" };
    const r0 = try tool.execute(a, empty.host(), try parseArgs(a, "{\"path\":\"p\"}"));
    try testing.expectEqualStrings("", r0.text);

    var newline: FakeHost = .{ .text = "\n" };
    const r1 = try tool.execute(a, newline.host(), try parseArgs(a, "{\"path\":\"p\"}"));
    try testing.expectEqualStrings("1: ", r1.text);
}

test "read forwards the line range to the host" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: FakeHost = .{ .text = "x" };
    _ = try tool.execute(a, fake.host(), try parseArgs(a, "{\"path\":\"p\",\"start\":3,\"end\":7}"));
    try testing.expectEqual(@as(?usize, 3), fake.seen_start);
    try testing.expectEqual(@as(?usize, 7), fake.seen_end);
}

test "read rejects bad arguments" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: FakeHost = .{ .text = "" };
    try testing.expectError(Error.InvalidToolArgs, tool.execute(a, fake.host(), try parseArgs(a, "{}")));
    try testing.expectError(Error.InvalidToolArgs, tool.execute(a, fake.host(), try parseArgs(a, "{\"path\":5}")));
    try testing.expectError(Error.InvalidToolArgs, tool.execute(a, fake.host(), try parseArgs(a, "{\"path\":\"x\",\"start\":0}")));
    try testing.expectError(Error.InvalidToolArgs, tool.execute(a, fake.host(), try parseArgs(a, "{\"path\":\"x\",\"extra\":1}")));
}
