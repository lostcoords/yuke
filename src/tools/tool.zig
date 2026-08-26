//! Define the built-in tools and their host interface. A Tool declares itself to the provider and runs
//! a native handler over a ToolHost. The backend runs each op locally or, later, in a container.

const std = @import("std");
const wire = @import("wire");

/// A handler result carries model-visible `text` and an optional display `view` (e.g. a diff).
/// The slices borrow the handler arena. They must outlive the tool event fold, publish, and commit.
pub const ToolResult = struct {
    text: []const u8,
    view: ?[]const wire.view.View = null,
};

/// A ToolHost provides the native primitives a handler calls. The backend decides where they run.
/// The `ctx` and its borrowed data (e.g. the workspace root) must outlive every call.
pub const ToolHost = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Read a file. Use `start`/`end` for a 1-indexed line range. A null range reads the whole file.
        readFile: *const fn (ctx: *anyopaque, arena: std.mem.Allocator, path: []const u8, start: ?usize, end: ?usize) anyerror![]const u8,
    };

    pub fn readFile(self: ToolHost, arena: std.mem.Allocator, path: []const u8, start: ?usize, end: ?usize) anyerror![]const u8 {
        return self.vtable.readFile(self.ctx, arena, path, start, end);
    }
};

/// A built-in tool has a provider declaration and a native handler.
pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    input_schema: []const u8,
    execute: *const fn (arena: std.mem.Allocator, host: ToolHost, args: std.json.Value) anyerror!ToolResult,
};

/// Return lines `start`..`end` (1-indexed, inclusive). A null start or end selects the first or last
/// line. A start past the last line returns an empty slice. The result borrows `text`.
pub fn sliceLines(text: []const u8, start: ?usize, end: ?usize) []const u8 {
    if (start == null and end == null) return text;
    const from = start orelse 1;
    var begin: usize = 0;
    var line: usize = 1;
    while (line < from) : (line += 1) {
        const nl = std.mem.indexOfScalarPos(u8, text, begin, '\n') orelse return "";
        begin = nl + 1;
    }
    const last = end orelse return text[begin..];
    if (last < from) return "";
    var stop: usize = begin;
    line = from;
    while (true) : (line += 1) {
        const nl = std.mem.indexOfScalarPos(u8, text, stop, '\n') orelse return text[begin..];
        stop = nl + 1;
        if (line == last) return text[begin..stop];
    }
}

const testing = std.testing;

test "sliceLines selects an inclusive 1-indexed range" {
    const text = "a\nb\nc\nd\n";
    try testing.expectEqualStrings(text, sliceLines(text, null, null));
    try testing.expectEqualStrings("b\nc\n", sliceLines(text, 2, 3));
    try testing.expectEqualStrings("c\nd\n", sliceLines(text, 3, null));
    try testing.expectEqualStrings("a\n", sliceLines(text, null, 1));
    try testing.expectEqualStrings("", sliceLines(text, 10, null)); // A start past the last line is empty.
    try testing.expectEqualStrings("", sliceLines(text, 3, 1)); // A start after the end is empty.

    // A file without a final newline still yields its last line.
    try testing.expectEqualStrings("y", sliceLines("x\ny", 2, 2));
}
