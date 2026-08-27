//! Define the built-in tools and their host interface. A Tool declares itself to the provider and runs
//! a native handler over a ToolHost. The backend runs each op locally or, later, in a container.

const std = @import("std");
const wire = @import("wire");
pub const schema = @import("schema.zig");

/// Backends map their native errors into this closed set. No backend-specific error reaches the
/// tool engine.
pub const HostError = error{
    NotFound,
    NotAFile,
    AccessDenied,
    TooLarge,
    InvalidUtf8,
    HostFailure,
    Canceled,
    OutOfMemory,
};

/// A handler adds argument errors and semantic refusals to `HostError`.
/// Each `ToolError` maps to one model-visible sentence.
pub const ToolError = HostError || error{
    MalformedArgs,
    MissingArg,
    UnknownArg,
    DuplicateArg,
    InvalidArg,
    NoMatch,
    Ambiguous,
};

/// A handler result carries model-visible `text` and an optional display `view`, for example a diff.
/// Both come from `out`. The owner of `out` must keep it alive until the commit ends.
pub const ToolResult = struct {
    text: []const u8,
    view: ?[]const wire.view.View = null,
};

/// A ToolHost provides the native primitives a handler calls. The backend decides where they run.
/// The `ctx` and its borrowed data, for example the workspace root, must outlive every call.
pub const ToolHost = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Read a file. Use `start`/`end` for a 1-indexed line range. A null range reads the whole file.
        /// The result comes from `scratch`. The handler must copy the data it keeps into `out`.
        readFile: *const fn (ctx: *anyopaque, scratch: std.mem.Allocator, path: []const u8, start: ?usize, end: ?usize) HostError![]const u8,
    };

    pub fn readFile(self: ToolHost, scratch: std.mem.Allocator, path: []const u8, start: ?usize, end: ?usize) HostError![]const u8 {
        return self.vtable.readFile(self.ctx, scratch, path, start, end);
    }
};

/// A built-in tool has a provider declaration and a native handler. Build one with `define`.
/// The `scratch` allocator holds temporary data. The `out` allocator holds the result.
pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    input_schema: []const u8,
    execute: *const fn (out: std.mem.Allocator, scratch: std.mem.Allocator, host: ToolHost, arguments: []const u8) ToolError!ToolResult,
};

/// Define a tool from its argument struct. The schema comes from `Args`. The parser uses the same
/// fields. `docs` names one `schema.Field` per argument.
pub fn define(
    comptime name: []const u8,
    comptime description: []const u8,
    comptime Args: type,
    comptime docs: schema.Docs(Args),
    comptime handler: fn (out: std.mem.Allocator, scratch: std.mem.Allocator, host: ToolHost, args: Args) ToolError!ToolResult,
) Tool {
    const thunk = struct {
        fn execute(out: std.mem.Allocator, scratch: std.mem.Allocator, host: ToolHost, arguments: []const u8) ToolError!ToolResult {
            // The provider is a peer. A malformed argument must return an error. It must not assert.
            // A parsed string borrows `arguments` or `scratch`. The handler must copy what it keeps into `out`.
            const args = std.json.parseFromSliceLeaky(Args, scratch, arguments, .{}) catch |err| return argError(err);
            return handler(out, scratch, host, args);
        }
    }.execute;
    return .{
        .name = name,
        .description = description,
        .input_schema = schema.of(Args, docs),
        .execute = thunk,
    };
}

/// Map a JSON decode error to the matching argument error. An unlisted error means malformed input.
fn argError(err: std.json.ParseError(std.json.Scanner)) ToolError {
    return switch (err) {
        error.UnknownField => error.UnknownArg,
        error.MissingField => error.MissingArg,
        error.DuplicateField => error.DuplicateArg,
        error.Overflow, error.InvalidNumber, error.InvalidCharacter, error.UnexpectedToken => error.InvalidArg,
        error.OutOfMemory => error.OutOfMemory,
        else => error.MalformedArgs,
    };
}

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

test "define derives the schema from the argument struct" {
    const Args = struct { path: schema.Str, keep: ?bool = null };
    const H = struct {
        fn run(out: std.mem.Allocator, scratch: std.mem.Allocator, host: ToolHost, args: Args) ToolError!ToolResult {
            _ = scratch;
            _ = host;
            return .{ .text = try out.dupe(u8, args.path.bytes) };
        }
    };
    const tool = define("t", "a test tool", Args, .{
        .path = .{ .description = "The path." },
        .keep = .{ .description = "Keep it." },
    }, H.run);

    try testing.expect(std.mem.indexOf(u8, tool.input_schema, "\"required\":[\"path\"]") != null);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dummy: ToolHost = .{ .ctx = undefined, .vtable = undefined };
    const res = try tool.execute(a, a, dummy, "{\"path\":\"x\"}");
    try testing.expectEqualStrings("x", res.text);
}

test "define maps each decode error to its argument error" {
    const Args = struct { path: schema.Str, start: ?usize = null };
    const H = struct {
        fn run(out: std.mem.Allocator, scratch: std.mem.Allocator, host: ToolHost, args: Args) ToolError!ToolResult {
            _ = .{ scratch, host, args };
            return .{ .text = try out.dupe(u8, "ok") };
        }
    };
    const tool = define("t", "d", Args, .{
        .path = .{ .description = "The path." },
        .start = .{ .description = "The first line.", .minimum = 1 },
    }, H.run);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dummy: ToolHost = .{ .ctx = undefined, .vtable = undefined };

    try testing.expectError(error.MissingArg, tool.execute(a, a, dummy, "{}"));
    try testing.expectError(error.UnknownArg, tool.execute(a, a, dummy, "{\"path\":\"x\",\"extra\":1}"));
    try testing.expectError(error.DuplicateArg, tool.execute(a, a, dummy, "{\"path\":\"a\",\"path\":\"b\"}"));
    try testing.expectError(error.InvalidArg, tool.execute(a, a, dummy, "{\"path\":5}"));
    try testing.expectError(error.InvalidArg, tool.execute(a, a, dummy, "{\"path\":\"x\",\"start\":-1}"));
    try testing.expectError(error.MalformedArgs, tool.execute(a, a, dummy, "not json"));
}
