//! Define the built-in tools. A Tool declares itself to the provider and runs a handler over a Host.

const std = @import("std");
const wire = @import("wire");
const Host = @import("../host/host.zig").Host;
const HostError = @import("../host/host.zig").HostError;
pub const schema = @import("schema.zig");

pub const ToolError = HostError || error{
    MalformedArgs,
    MissingArg,
    UnknownArg,
    DuplicateArg,
    InvalidArg,
    NoMatch,
    Ambiguous,
    NoChange,
};

/// A handler result carries model-visible `text` and an optional display `view`, for example a diff.
/// Both come from `out`. The owner of `out` must keep it alive until the commit ends.
pub const ToolResult = struct {
    text: []const u8,
    view: ?[]const wire.view.View = null,
};

pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    input_schema: []const u8,
    execute: *const fn (out: std.mem.Allocator, scratch: std.mem.Allocator, host: Host, arguments: []const u8) ToolError!ToolResult,
};

/// Define a tool from its argument struct. The schema comes from `Args`. The parser uses the same
/// fields. `docs` names one `schema.Field` per argument.
pub fn define(
    comptime name: []const u8,
    comptime description: []const u8,
    comptime Args: type,
    comptime docs: schema.Docs(Args),
    comptime handler: fn (out: std.mem.Allocator, scratch: std.mem.Allocator, host: Host, args: Args) ToolError!ToolResult,
) Tool {
    const thunk = struct {
        fn execute(out: std.mem.Allocator, scratch: std.mem.Allocator, host: Host, arguments: []const u8) ToolError!ToolResult {
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

const testing = std.testing;

test "define derives the schema from the argument struct" {
    const Args = struct { path: schema.Str, keep: ?bool = null };
    const H = struct {
        fn run(out: std.mem.Allocator, scratch: std.mem.Allocator, host: Host, args: Args) ToolError!ToolResult {
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
    const dummy: Host = .{ .ctx = undefined, .vtable = undefined };
    const res = try tool.execute(a, a, dummy, "{\"path\":\"x\"}");
    try testing.expectEqualStrings("x", res.text);
}

test "define maps each decode error to its argument error" {
    const Args = struct { path: schema.Str, start: ?usize = null };
    const H = struct {
        fn run(out: std.mem.Allocator, scratch: std.mem.Allocator, host: Host, args: Args) ToolError!ToolResult {
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
    const dummy: Host = .{ .ctx = undefined, .vtable = undefined };

    try testing.expectError(error.MissingArg, tool.execute(a, a, dummy, "{}"));
    try testing.expectError(error.UnknownArg, tool.execute(a, a, dummy, "{\"path\":\"x\",\"extra\":1}"));
    try testing.expectError(error.DuplicateArg, tool.execute(a, a, dummy, "{\"path\":\"a\",\"path\":\"b\"}"));
    try testing.expectError(error.InvalidArg, tool.execute(a, a, dummy, "{\"path\":5}"));
    try testing.expectError(error.InvalidArg, tool.execute(a, a, dummy, "{\"path\":\"x\",\"start\":-1}"));
    try testing.expectError(error.MalformedArgs, tool.execute(a, a, dummy, "not json"));
}
