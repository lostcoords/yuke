//! The built-in tool registry. It lists the daemon's native tools and builds their provider declarations.

const std = @import("std");
const t = @import("tool.zig");
const ir = @import("../provider/request/ir.zig");
const read = @import("read.zig");

/// The built-in tools in advertisement order. Version 1 ships `read`. The `write`, `edit`, and `exec`
/// tools follow.
const builtins = [_]t.Tool{read.tool};

/// Return the built-in with `name`, or null.
pub fn find(name: []const u8) ?t.Tool {
    for (builtins) |tool| {
        if (std.mem.eql(u8, tool.name, name)) return tool;
    }
    return null;
}

/// Build the provider declarations for the built-in tools. The caller owns the slice.
pub fn declarations(arena: std.mem.Allocator) ![]const ir.Tool {
    const out = try arena.alloc(ir.Tool, builtins.len);
    for (builtins, 0..) |tool, i| out[i] = .{ .name = tool.name, .description = tool.description, .input_schema = tool.input_schema };
    return out;
}

const testing = std.testing;

test "find returns a built-in by name" {
    try testing.expect(find("read") != null);
    try testing.expect(find("nope") == null);
}

test "declarations mirror the built-ins" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const decls = try declarations(arena.allocator());
    try testing.expectEqual(builtins.len, decls.len);
    try testing.expectEqualStrings("read", decls[0].name);
}
